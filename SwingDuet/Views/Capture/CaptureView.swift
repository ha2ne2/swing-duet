import SwiftUI
import AVFoundation

/// 撮影画面（全画面）。プレビューの上に、縁の色（灰 = まだ見えていない / 緑 = 見えている / 白の点滅 = ショット / 橙 = 警告）、
/// 大きな球数、状態の文字、警告の帯、取れたショットの帯（右が新しい。タップで削除）、録画ボタンを重ねる。
/// 打席に届く合図は音（`CaptureSounds`）で、画面は録画を押すときと、近づいて止める・見るときのもの。
/// 「…」でカメラ・フレームレート・音を切り替える（録画中は音だけ）。設計は docs/design/260912_2251-capture-screen.md §3
struct CaptureView: View {
    @EnvironmentObject private var store: ClipStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @StateObject private var controller: CaptureController
    @State private var deleting: ShotPipeline.Item?
    /// 帯でタップしてリプレイ中のショット
    @State private var replaying: ShotPipeline.Item?

    /// 止めたときの結果（ホームの帯に出す）
    let onFinish: (CaptureController.Summary) -> Void

    init(store: ClipStore, onFinish: @escaping (CaptureController.Summary) -> Void) {
        _controller = StateObject(wrappedValue: CaptureController(store: store))
        self.onFinish = onFinish
    }

    private var isRecording: Bool { controller.state == .recording }
    private var isBusy: Bool { controller.state == .recording || controller.state == .stopping }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CameraPreviewView(session: controller.capture.session) { layer in
                controller.attach(previewLayer: layer)
            }
            .ignoresSafeArea()
            edgeOverlay
            if verticalSizeClass == .compact {
                landscapeLayout
            } else {
                portraitLayout
            }
            if let error = controller.setupError {
                setupErrorView(error)
            }
            if let item = replaying, let clipID = item.clipID, let clip = store.clip(id: clipID) {
                ReplayOverlay(clip: clip, number: (controller.shots.firstIndex { $0.id == item.id } ?? 0) + 1, isRecording: isRecording) {
                    deleting = item
                } onClose: {
                    replaying = nil
                }
            }
        }
        .preferredColorScheme(.dark)
        .task { await controller.prepare() }
        .onDisappear { controller.teardown() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { controller.appDidEnterBackground() }
        }
        .onChange(of: controller.summary) { _, summary in
            guard let summary else { return }
            onFinish(summary)
            dismiss()
        }
        .onChange(of: store.capture) { old, new in
            // カメラかフレームレートが変わったらセッションを組み直す（音や動画を残す設定は組み直さない）
            if old.camera != new.camera || old.frameRate != new.frameRate {
                Task { await controller.configure() }
            }
        }
        .confirmationDialog("このショットを削除しますか？", isPresented: $deleting.isPresent(), titleVisibility: .visible, presenting: deleting) { item in
            Button("削除", role: .destructive) {
                controller.delete(item)
                replaying = nil
            }
        }
        .onChange(of: controller.shots) { _, shots in
            if let item = replaying, !shots.contains(where: { $0.id == item.id }) { replaying = nil }   // 素振りと判定されて消えた
        }
    }

    // MARK: - 配置

    /// 縦でも横でも同じ並び（上のバー・球数・状態・帯）。違うのは録画ボタンの置き場所と、上下の余白だけ
    private func infoColumn(countTop: CGFloat, stripBottom: CGFloat) -> some View {
        VStack(spacing: 0) {
            topBar
                .padding(.horizontal, 16)
                .padding(.top, 6)
            countArea
                .padding(.top, countTop)
            statusView
            bannerView
            Spacer()
            strip
                .padding(.bottom, stripBottom)
        }
    }

    private var portraitLayout: some View {
        VStack(spacing: 0) {
            infoColumn(countTop: 18, stripBottom: 14)
            recordButton
                .padding(.bottom, 26)
        }
    }

    /// 横向きは録画ボタンを右の列に出す（打席から見て手が届く側）
    private var landscapeLayout: some View {
        HStack(spacing: 0) {
            infoColumn(countTop: 0, stripBottom: 12)
            VStack {
                Spacer()
                recordButton
                Spacer()
            }
            .frame(width: 110)
        }
    }

    /// 画面の縁の色
    private var edgeOverlay: some View {
        let color: Color = switch controller.edge {
        case .idle: .gray.opacity(0.55)
        case .seen: .green
        case .cutOff, .warning: .orange
        case .hit: .white
        }
        return RoundedRectangle(cornerRadius: 44, style: .continuous)
            .strokeBorder(color, lineWidth: controller.edge == .hit ? 14 : 8)
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .animation(.easeOut(duration: 0.2), value: controller.edge)
            .accessibilityHidden(true)
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Button(action: close) {
                Image(systemName: "xmark")
                    .barButton()
            }
            .disabled(controller.state == .stopping)
            .accessibilityLabel("閉じる")
            .accessibilityIdentifier("capture.close")
            if isBusy {
                HStack(spacing: 5) {
                    Circle().fill(.red).frame(width: 9, height: 9)
                    Text(controller.elapsed.clockLabel)
                        .monospacedDigit()
                }
                .videoChip(font: .footnote.weight(.semibold))
                .accessibilityLabel("録画中 \(controller.elapsed.clockLabel)")
            }
            Spacer()
            if controller.frameRate > 0 {
                Text("\(controller.frameRate) fps")
                    .font(.caption.weight(.semibold))
                    .videoChip(font: .footnote.weight(.semibold))
            }
            settingsMenu
        }
        .foregroundStyle(.white)
    }

    /// 「…」：カメラ・フレームレート（録画中は変えられない）・音
    private var settingsMenu: some View {
        Menu {
            Picker("カメラ", selection: Binding(get: { store.capture.camera }, set: { store.capture.camera = $0 })) {
                ForEach(CaptureSettings.Camera.allCases, id: \.self) { camera in
                    Text(camera == .back ? "背面（240fps まで）" : "前面（120fps まで・打席から画面が見える）").tag(camera)
                }
            }
            .disabled(isBusy)
            Picker("フレームレート", selection: Binding(get: { store.capture.frameRate }, set: { store.capture.frameRate = $0 })) {
                ForEach(CaptureSettings.frameRates, id: \.self) { fps in
                    Text("\(fps) fps").tag(fps)
                }
            }
            .disabled(isBusy || store.capture.camera == .front)
            Toggle("合図の音", isOn: Binding(get: { store.capture.soundEnabled }, set: { store.capture.soundEnabled = $0 }))
            Toggle("全体の動画も残す（調査用）", isOn: Binding(get: { store.capture.keepsFullTake }, set: { store.capture.keepsFullTake = $0 }))
                .disabled(isBusy)
        } label: {
            Image(systemName: store.capture.soundEnabled ? "ellipsis" : "speaker.slash")
                .barButton()
        }
        .accessibilityLabel("撮影の設定")
        .accessibilityIdentifier("capture.settings")
    }

    /// 大きな球数（ショットの直後は「＋1」）。数は帯に並ぶショットの数で、切り出し中も含む。
    /// 「＋1」は候補を登録した時点で出すので、数もその時点で増えていないと、「＋1」が消えた後に前の数が一瞬見える
    private var countArea: some View {
        let count = controller.shots.count
        return ZStack {
            if isBusy {
                if controller.showsPlusOne {
                    Text("＋1")
                        .font(.system(size: 92, weight: .heavy, design: .rounded))
                        .transition(.scale.combined(with: .opacity))
                } else {
                    HStack(alignment: .lastTextBaseline, spacing: 4) {
                        Text("\(count)")
                            .font(.system(size: 74, weight: .heavy, design: .rounded))
                            .monospacedDigit()
                        Text("球")
                            .font(.system(size: 22, weight: .bold))
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(count) 球")
                    .accessibilityIdentifier("capture.count")
                }
            }
        }
        .frame(height: 96)
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.6), radius: 8)
        .animation(.easeOut(duration: 0.2), value: controller.showsPlusOne)
    }

    private var statusView: some View {
        Group {
            if !controller.statusText.isEmpty {
                Text(controller.statusText)
                    .font(isBusy ? .subheadline.weight(.semibold) : .body.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, isBusy ? 7 : 11)
                    .background(.black.opacity(Scrim.light), in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 24)
                    .accessibilityIdentifier("capture.status")
            }
        }
    }

    private var bannerView: some View {
        Group {
            if let banner = controller.banner {
                Text(banner)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.black)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity)
                    .background(.orange.opacity(0.92), in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            }
        }
    }

    /// 取れたショットの帯（右が新しい。切り出し中は点線の枠）
    private var strip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 6) {
                    ForEach(Array(controller.shots.enumerated()), id: \.element.id) { index, item in
                        thumbnail(item, number: index + 1)
                            .id(item.id)
                    }
                }
                .padding(.horizontal, 16)
            }
            .frame(height: 54)
            .onChange(of: controller.shots.count) { _, _ in
                if let last = controller.shots.last { withAnimation { proxy.scrollTo(last.id, anchor: .trailing) } }
            }
        }
        .accessibilityIdentifier("capture.strip")
    }

    private func thumbnail(_ item: ShotPipeline.Item, number: Int) -> some View {
        ZStack(alignment: .bottom) {
            if let clipID = item.clipID, let clip = store.clip(id: clipID) {
                ClipThumbnail(clip: clip, phase: .impact, aspect: 40 / 54)
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [3]))
                    .foregroundStyle(.white.opacity(0.7))
                ProgressView()
                    .controlSize(.mini)
                    .tint(.white)
                    .frame(maxHeight: .infinity)
            }
            Text("\(number)")
                .font(.system(size: 9, weight: .semibold))
                .monospacedDigit()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 1)
                .background(.black.opacity(Scrim.light))
        }
        .frame(width: 40, height: 54)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture {
            if item.clipID != nil { replaying = item }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.clipID == nil ? "\(number) 球目 切り出し中" : "\(number) 球目")
        .accessibilityHint(item.clipID == nil ? "" : "タップでリプレイ")
    }

    private var recordButton: some View {
        Button {
            if isRecording {
                Task { await controller.stop() }
            } else {
                controller.record()
            }
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(.white, lineWidth: 4)
                    .frame(width: 72, height: 72)
                if controller.state == .stopping {
                    ProgressView()
                        .tint(.white)
                } else if isRecording {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.red)
                        .frame(width: 30, height: 30)
                } else {
                    Circle()
                        .fill(.red)
                        .frame(width: 58, height: 58)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(controller.state != .ready && controller.state != .recording)
        .opacity(controller.state == .preparing || controller.setupError != nil ? 0.4 : 1)
        .accessibilityLabel(isRecording ? "止める" : "録画")
        .accessibilityIdentifier("capture.record")
    }

    private func setupErrorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "video.slash")
                .font(.system(size: 44, weight: .light))
            Text(message)
                .font(.subheadline)
                .multilineTextAlignment(.center)
            if controller.isPermissionDenied {
                OpenSettingsButton()
                    .buttonStyle(.borderedProminent)
            }
            Button("閉じる") { dismiss() }
        }
        .foregroundStyle(.white)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(Scrim.heavy))
        .ignoresSafeArea()
    }

    /// ✕：録画中なら止めてから閉じる（止めた結果が入ったら閉じる）
    private func close() {
        switch controller.state {
        case .recording:
            Task { await controller.stop() }
        case .stopping:
            break
        default:
            dismiss()
        }
    }
}

private extension View {
    /// 上のバーの丸いボタン（閉じる・設定）
    func barButton() -> some View {
        font(.system(size: 16, weight: .bold))
            .frame(width: 40, height: 40)
            .background(.black.opacity(Scrim.light), in: Circle())
    }
}

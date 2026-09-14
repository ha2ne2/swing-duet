import SwiftUI

/// ステージ：左のスイング 1 本と、その相手（右のお手本）。両方の解析が済んでいれば比較（`ComparisonView`）、
/// そうでなければ待ちの状態（解析中・お手本なし・失敗）を出す。ツールバーは軌跡のオン・オフと ★ だけ（名前・削除・再解析は一覧の「…」から）。
/// 左右どちらの「替える」からも「動画を選ぶ」シートを開く（左は「動画」タブ、右は「お手本」タブで始まる）。
/// 一覧へは左上の「<」で戻る。左端からのスワイプで戻る操作は止めている（シークバーの左端のつまみのドラッグと衝突するため）
struct StageView: View {
    @EnvironmentObject private var store: ClipStore

    /// いま左に入っているクリップ。左を選び直すとここが替わる（一覧に戻れば新しい行がある）
    @State private var currentID: UUID
    @State private var picking: VideoSide?
    @State private var errorMessage: String?
    /// 部位の軌跡を動画に重ねるか（アプリ全体で 1 つ。`ComparisonView` が同じキーを読む）
    @AppStorage(JointTrailOverlay.isEnabledKey) private var showTrails = false
    /// 隠している部位の組（`TrailPartGroup.bit` の和）
    @AppStorage(JointTrailOverlay.hiddenPartsKey) private var hiddenParts = 0

    /// 軌跡を区間近似で滑らかにするか
    @AppStorage(JointTrailOverlay.smoothingKey) private var smoothTrails = true

    init(swingID: UUID) {
        _currentID = State(initialValue: swingID)
    }

    private var clip: Clip? { store.clip(id: currentID) }
    private var partner: Clip? { clip.flatMap { store.partner(of: $0) } }

    var body: some View {
        ZStack {
            if let clip {
                if clip.isAnalyzed, let partner, partner.isAnalyzed {
                    ComparisonView(left: clip, right: partner) { side in
                        picking = side
                    }
                    .id([clip.videoIdentity, partner.videoIdentity])   // ID を引き継ぐ分割や保存先の変更でも動画を読み直す
                } else {
                    SetupStageView(left: clip, right: partner) { side in
                        picking = side
                    }
                }
            } else {
                ContentUnavailableView("スイングがありません", systemImage: "figure.golf", description: Text("削除されました。"))
            }
        }
        // 枝（比較前 / 比較）が替わっても付け直されない容器に置く。枝ごとに付け直すと、新しい方が付いた後で古い方が外れて戻し、スワイプが復活する
        .background(InteractivePopGestureBlocker())
        .navigationTitle(clip?.displayName ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                trailsButton
                if showTrails { trailPartsMenu }   // 軌跡を出しているときだけ。出していなければ選ぶものが無い
                if let clip {
                    FavoriteButton(clip: clip, identifier: "stage.favorite")
                }
            }
        }
        .sheet(item: $picking) { side in
            VideoPickerSheet(
                destination: side,
                initialTab: side == .mine ? .library : .models,
                currentPartnerID: side == .model ? partner?.id : nil
            ) { picked in
                handle(picked, into: side)
            }
            .environmentObject(store)
        }
        .errorAlert($errorMessage)
    }

    private var trailsButton: some View {
        Button {
            showTrails.toggle()
        } label: {
            Image(systemName: showTrails
                  ? "point.topleft.down.to.point.bottomright.curvepath.fill"
                  : "point.topleft.down.to.point.bottomright.curvepath")
                .foregroundStyle(showTrails ? Color.accentColor : Color.secondary)
        }
        .accessibilityLabel("軌跡")
        .accessibilityValue(showTrails ? "オン" : "オフ")
        .accessibilityHint("手・頭・左右の肩・左右の股関節の軌跡を動画に重ねる")
        .accessibilityIdentifier("stage.trails")
    }

    /// どの部位の軌跡を出すか。左右の対はまとめて 1 項目
    private var trailPartsMenu: some View {
        Menu {
            ForEach(TrailPartGroup.allCases) { group in
                Toggle(group.label, isOn: isShown(group))
            }
            Divider()
            Toggle("軌跡を滑らかにする", isOn: $smoothTrails)
                .accessibilityIdentifier("stage.smoothTrails")
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuOrder(.fixed)
        .accessibilityLabel("軌跡の設定")
        .accessibilityIdentifier("stage.trailParts")
    }

    /// その部位を出しているか（`hiddenParts` は隠している側を持つので反転する）
    private func isShown(_ group: TrailPartGroup) -> Binding<Bool> {
        Binding(
            get: { hiddenParts & group.bit == 0 },
            set: { isOn in hiddenParts = isOn ? hiddenParts & ~group.bit : hiddenParts | group.bit })
    }

    /// ピッカーで選んだ動画をその側に入れる。
    /// 左：ライブラリの動画なら新しいスイング（相手は引き継ぐ）、既存のクリップならそれを開く。
    /// 右：ライブラリの動画なら新しいお手本（名前があれば棚に登録、無ければこの比較にだけ使う）、既存のクリップならそれを相手にする
    private func handle(_ picked: PickedVideo, into side: VideoSide) {
        switch picked {
        case .existing(let chosen):
            if side == .mine {
                currentID = chosen.id
            } else {
                store.setPartner(of: currentID, to: chosen.id)
            }
        case .library(let source, let modelName):
            let partnerID = partner?.id
            Task {
                do {
                    if side == .mine {
                        let swing = try await store.obtain(role: .swing, source: source, partnerID: partnerID)
                        currentID = swing.id
                    } else {
                        let model = try await store.obtain(role: .model, name: modelName ?? "", source: source, registered: modelName != nil)
                        store.setPartner(of: currentID, to: model.id)
                    }
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

/// 比較になる前のステージ。左は解析中か失敗、右は空か解析中。操作パネルは操作できない飾りとして薄く出す
private struct SetupStageView: View {
    let left: Clip
    let right: Clip?
    let onSelect: (VideoSide) -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 2) {
                SlotPane(side: .mine, clip: left) { onSelect(.mine) }
                SlotPane(side: .model, clip: right) { onSelect(.model) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)

            ControlPanelView(controller: .placeholder)
                .opacity(0.35)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

/// 1 つのペイン（空・解析待ち・解析中・失敗・準備済み）。右上の「替える」は比較画面と同じ `PaneSwapButton`
private struct SlotPane: View {
    @EnvironmentObject private var store: ClipStore
    let side: VideoSide
    let clip: Clip?
    let onTap: () -> Void

    var body: some View {
        ZStack {
            Color.black
            if let clip {
                ClipThumbnail(clip: clip, phase: .address, maxSize: 800)
                status(of: clip)
            } else {
                Button(action: onTap) {
                    VStack(spacing: 12) {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 64, weight: .light))
                        Text("お手本を選ぶ")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("お手本の動画を選ぶ")
                .accessibilityIdentifier("slot.\(side.rawValue).add")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)   // 左右のペインは常に同じ幅
        .overlay(alignment: .topTrailing) {
            if let clip {
                PaneSwapButton(side: side, title: clip.paneTitle, onSwap: onTap)
            }
        }
    }

    @ViewBuilder
    private func status(of clip: Clip) -> some View {
        switch clip.analysis {
        case .done:
            EmptyView()
        case .pending:
            AnalyzingOverlay(isRunning: store.analyzingID == clip.id, controlSize: .large)
                .accessibilityIdentifier("slot.\(side.rawValue).analyzing")
        case .failed(let message):
            Color.black.opacity(Scrim.medium)
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title)
                Text("解析できませんでした")
                    .font(.caption.bold())
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("解析をやり直す") { store.retryAnalysis(clip.id) }
                    .frame(minHeight: 44)
            }
            .padding(.horizontal, 14)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("slot.\(side.rawValue).failed")
        }
    }
}

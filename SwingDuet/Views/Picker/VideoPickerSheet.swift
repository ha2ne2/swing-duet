import SwiftUI

/// ピッカーで選ばれた動画（`VideoPickerSheet` の結果）
enum PickedVideo {
    /// 既にあるクリップ（登録済みお手本か ★ ベスト）
    case existing(Clip)
    /// ライブラリの動画。右ペインに入れるときは名前を付ける（左では name は nil）
    case library(LibrarySource, name: String?)
}

/// ペインに入れる動画を選ぶシート。上に「動画」「お手本」の 2 タブがあり、どちらから選んでも `destination` の側に入る。
/// 左の＋からは「動画」タブ、右の＋からは「お手本」タブで開く。「動画」タブはセルをタップ → プレビュー → 使う（右ならさらに名前を付ける）
struct VideoPickerSheet: View {
    /// 上の 2 タブ
    enum Tab: Hashable {
        /// 写真ライブラリの動画（1 本選んでプレビュー → 使う）
        case library
        /// 登録済みのお手本と ★ ベスト（そのまま使う）
        case models
    }

    @Environment(\.dismiss) private var dismiss
    /// 選んだ動画を入れる側
    let destination: VideoSide
    /// 右ペインにいま入っているクリップ（「お手本」タブで「いま右に」と示す）
    var currentPartnerID: UUID? = nil
    let onPick: (PickedVideo) -> Void

    @State private var tab: Tab
    @State private var steps: [Step] = []

    /// 「動画」タブの中の段階（プレビュー → 名前付け）
    private enum Step: Hashable {
        case preview(LibrarySource)
        case naming(LibrarySource)
    }

    init(destination: VideoSide, initialTab: Tab, currentPartnerID: UUID? = nil, onPick: @escaping (PickedVideo) -> Void) {
        self.destination = destination
        self.currentPartnerID = currentPartnerID
        self.onPick = onPick
        _tab = State(initialValue: initialTab)
    }

    var body: some View {
        NavigationStack(path: $steps) {
            VStack(spacing: 0) {
                Picker("タブ", selection: $tab) {
                    Text("動画").tag(Tab.library)
                    Text("お手本").tag(Tab.models)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .accessibilityIdentifier("picker.tab")

                destinationNote
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)

                switch tab {
                case .library:
                    LibraryGridView { source in
                        steps.append(.preview(source))
                    }
                case .models:
                    ModelShelfView(currentPartnerID: currentPartnerID) { clip in
                        finish(.existing(clip))
                    }
                }
            }
            .navigationTitle("動画を選ぶ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
            .navigationDestination(for: Step.self) { step in
                switch step {
                case .preview(let source):
                    LibraryPreviewView(source: source, destination: destination) {
                        if destination == .model {
                            steps.append(.naming(source))
                        } else {
                            finish(.library(source, name: nil))
                        }
                    }
                case .naming(let source):
                    NewModelNameStep(source: source) { name in
                        finish(.library(source, name: name))
                    }
                }
            }
        }
    }

    private var destinationNote: Text {
        Text("選んだ動画は ") + Text(destination == .mine ? "自分（左）" : "お手本（右）").bold() + Text(" に入ります")
    }

    private func finish(_ picked: PickedVideo) {
        onPick(picked)
        dismiss()
    }
}

/// ライブラリから選んだお手本に名前を付けるステップ
private struct NewModelNameStep: View {
    let source: LibrarySource
    let onConfirm: (String) -> Void

    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 20) {
            SourceThumbnail(source: source)
                .frame(width: 140, height: 186)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .padding(.top, 12)
            TextField("名前（例: マキロイ・アイアン・正面）", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .submitLabel(.done)
                .onSubmit(confirm)
                .accessibilityIdentifier("modelName")
            Text("次回から「お手本」タブに並びます。名前が空なら日時を付けます。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)   // キーボードで縦が詰まっても 1 行に潰さない
            Button(action: confirm) {
                Text("この名前で使う")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
        .padding(.horizontal, 20)
        .navigationTitle("新しいお手本")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { focused = true }
    }

    private func confirm() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        onConfirm(trimmed.isEmpty ? "お手本 \(Date().compactLabel)" : trimmed)
    }
}

/// 名前を付けるステップに出す、選んだ動画のサムネイル（出どころに応じて PhotoKit か AVFoundation で描く）
private struct SourceThumbnail: View {
    let source: LibrarySource

    var body: some View {
        switch source {
        case .asset(let asset):
            AssetThumbnail(asset: asset, targetSize: CGSize(width: 140, height: 186))
        case .file(let url):
            VideoThumbnail(url: url, time: 0.5, aspect: 140 / 186)
        }
    }
}

import SwiftUI

/// ピッカーで選ばれた動画（`VideoPickerSheet` の結果）
enum PickedVideo {
    /// 既にあるクリップ（登録済みお手本か ★ お気に入り）
    case existing(Clip)
    /// ライブラリの動画。`modelName` は右ペインに入れるときの名前（空なら撮影日時が表示名になる。nil なら棚に加えない。左では常に nil）
    case library(LibrarySource, modelName: String?)
}

/// ペインに入れる動画を選ぶシート。上に「動画」「お手本」の 2 タブがあり、どちらから選んでも `destination` の側に入る。
/// 左の＋からは「動画」タブ、右の＋からは「お手本」タブで開く。「動画」タブはセルをタップ → プレビュー → 使う
/// （右ならさらに名前を付けて棚に加えるか、「今回だけ使う」で加えずに使う）
struct VideoPickerSheet: View {
    /// 上の 2 タブ
    enum Tab: Hashable {
        /// 写真ライブラリの動画（1 本選んでプレビュー → 使う）
        case library
        /// 登録済みのお手本と ★ お気に入り（そのまま使う）
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
                            finish(.library(source, modelName: nil))
                        }
                    }
                case .naming(let source):
                    NewModelNameStep(source: source) { name in
                        finish(.library(source, modelName: name))
                    } onSkip: {
                        finish(.library(source, modelName: nil))
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

/// ライブラリから選んだお手本に名前を付けて棚に加えるステップ。「今回だけ使う」なら棚には加えず、この比較にだけ使う
private struct NewModelNameStep: View {
    let source: LibrarySource
    let onConfirm: (String) -> Void
    let onSkip: () -> Void

    @State private var name = ""
    /// 名前を空のまま確定したときの表示名（撮影日時。`Clip.displayName` と同じ）。プレースホルダーとして見せる
    @State private var fallbackName = ""
    @FocusState private var focused: Bool

    var body: some View {
        // NOTE: 決定のボタンはスクロールする中身の末尾に置かず、下端に固定する。キーボードは safe area に含まれるので、
        //       ボタンはキーボードの上に乗ったまま押せる。中身（サムネイル・入力欄）はキーボードの分だけ縮んでスクロールする
        ScrollView {
            VStack(spacing: 20) {
                SourceThumbnail(source: source)
                    .frame(width: 120, height: 160)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .padding(.top, 12)
                TextField(fallbackName, text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .submitLabel(.done)
                    .onSubmit(confirm)
                    .accessibilityLabel("名前")
                    .accessibilityIdentifier("modelName")
            }
            .padding(.horizontal, 20)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 4) {
                Button(action: confirm) {
                    Text("お手本に追加")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Button("今回だけ使う", action: onSkip)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .accessibilityIdentifier("modelName.skip")
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .background(.bar)
        }
        .navigationTitle("新しいお手本")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            focused = true
            fallbackName = (await source.creationDate ?? Date()).compactLabel
        }
    }

    private func confirm() {
        onConfirm(name.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// 名前を付けるステップに出す、選んだ動画のサムネイル（出どころに応じて PhotoKit か AVFoundation で描く）
private struct SourceThumbnail: View {
    let source: LibrarySource

    var body: some View {
        switch source {
        case .asset(let asset):
            AssetThumbnail(asset: asset, targetSize: CGSize(width: 120, height: 160))
        case .file(let url):
            VideoThumbnail(url: url, time: 0.5, aspect: 120 / 160)
        }
    }
}

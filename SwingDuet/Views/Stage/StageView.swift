import SwiftUI

/// ステージ：左のスイング 1 本と、その相手（右のお手本）。両方の解析が済んでいれば比較（`ComparisonView`）、
/// そうでなければ待ちの状態（解析中・お手本なし・失敗）を出す。
/// 左右どちらのラベルからも「動画を選ぶ」シートを開く（左は「動画」タブ、右は「お手本」タブで始まる）
struct StageView: View {
    @EnvironmentObject private var store: ClipStore
    @Environment(\.dismiss) private var dismiss

    /// いま左に入っているクリップ。左を選び直すとここが替わる（一覧に戻れば新しい行がある）
    @State private var currentID: UUID
    @State private var picking: VideoSide?
    @State private var renaming: Clip?
    @State private var errorMessage: String?

    init(swingID: UUID) {
        _currentID = State(initialValue: swingID)
    }

    private var clip: Clip? { store.clip(id: currentID) }
    private var partner: Clip? { clip.flatMap { store.partner(of: $0) } }

    var body: some View {
        Group {
            if let clip {
                if clip.isAnalyzed, let partner, partner.isAnalyzed {
                    ComparisonView(left: clip, right: partner) { side in
                        picking = side
                    }
                    .id("\(clip.id)-\(partner.id)")   // どちらかが替わったらプレーヤーごと作り直す
                } else {
                    SetupStageView(left: clip, right: partner) { side in
                        picking = side
                    }
                }
            } else {
                ContentUnavailableView("スイングがありません", systemImage: "figure.golf", description: Text("削除されました。"))
            }
        }
        .navigationTitle(clip?.displayName ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                favoriteButton
                menu
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
        .renameAlert($renaming)
        .errorAlert($errorMessage)
    }

    private var favoriteButton: some View {
        let isFavorite = clip?.isFavorite ?? false
        return Button {
            if let clip { store.setFavorite(clip.id, !clip.isFavorite) }
        } label: {
            Image(systemName: isFavorite ? "star.fill" : "star")
                .foregroundStyle(.yellow)
                .symbolEffect(.bounce, value: isFavorite)
        }
        .disabled(clip?.isAnalyzed != true)
        .accessibilityLabel("★ ベスト")
        .accessibilityValue(isFavorite ? "オン" : "オフ")
        .accessibilityIdentifier("stage.favorite")
    }

    private var menu: some View {
        Menu {
            if case .failed = clip?.analysis {
                Button("もう一度解析", systemImage: "arrow.clockwise") { store.retryAnalysis(currentID) }
            } else {
                Button("名前を付ける", systemImage: "pencil") { renaming = clip }
            }
            Button("削除", systemImage: "trash", role: .destructive) {
                store.delete([currentID])
                dismiss()
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .disabled(clip == nil)
        .accessibilityLabel("その他")
        .accessibilityIdentifier("stage.menu")
    }

    /// ピッカーで選んだ動画をその側に入れる。
    /// 左：ライブラリの動画なら新しいスイング（相手は引き継ぐ）、既存のクリップならそれを開く。
    /// 右：ライブラリの動画なら名前付きの新しいお手本、既存のクリップならそれを相手にする
    private func handle(_ picked: PickedVideo, into side: VideoSide) {
        switch picked {
        case .existing(let chosen):
            if side == .mine {
                currentID = chosen.id
            } else {
                store.setPartner(of: currentID, to: chosen.id)
            }
        case .library(let source, let name):
            let partnerID = partner?.id
            Task {
                do {
                    if side == .mine {
                        let swing = try await store.obtain(role: .swing, source: source, partnerID: partnerID)
                        currentID = swing.id
                    } else {
                        let model = try await store.obtain(role: .model, name: name ?? "", source: source)
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

            ControlPanelView(controller: .placeholder, reference: .constant(.model))
                .opacity(0.35)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

/// 1 つのペイン（空・解析待ち・解析中・失敗・準備済み）。上端のラベルは比較画面（VideoPaneView）と同じ位置・見た目
private struct SlotPane: View {
    @EnvironmentObject private var store: ClipStore
    let side: VideoSide
    let clip: Clip?
    let onTap: () -> Void

    var body: some View {
        ZStack {
            Color.black
            if let clip {
                VideoThumbnail(url: store.videoURL(for: clip.fileName), time: clip.isAnalyzed ? clip.video.phases.address : 0, maxSize: 800)
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
        .overlay(alignment: .topLeading) {
            PaneTitleButton(side: side, title: clip?.paneTitle, action: onTap)
        }
    }

    @ViewBuilder
    private func status(of clip: Clip) -> some View {
        switch clip.analysis {
        case .done:
            EmptyView()
        case .pending:
            Color.black.opacity(0.55)
            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                Text(store.analyzingID == clip.id ? "解析中…" : "解析待ち")
                    .font(.caption.bold())
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("slot.\(side.rawValue).analyzing")
        case .failed(let message):
            Color.black.opacity(0.7)
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title)
                Text("解析できませんでした")
                    .font(.caption.bold())
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Text("右上のメニューからやり直すか、削除できます")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("slot.\(side.rawValue).failed")
        }
    }
}

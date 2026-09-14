import SwiftUI
import AVFoundation

/// フェーズ検出結果の手動修正。
/// タイムライン上の 4 つのマーカー（アドレス / トップ / インパクト / フィニッシュ）を
/// ドラッグして調整し、プレビューで確認する。コマ単位の微調整ボタン付き。
/// 動画に複数のスイングが検出されていれば、どのスイングを使うかも切り替えられる。動画の速さ（焼き込みスローの倍率）もここで直す。
/// プレビューは常に「選択中のフェーズの時刻」を映す（その値が変わるたびにシークする）ので、操作側はフェーズと時刻を変えるだけでよい
struct PhaseEditView: View {
    let config: VideoConfig
    let onSave: (PhaseSet, Double?) -> Void
    let asset: AVAsset
    let side: VideoSide

    @Environment(\.dismiss) private var dismiss

    @State private var phases: PhaseSet
    /// ユーザーが選んだ動画の速さ。nil なら推定に従う（セグメントは推定値を示し、フェーズを直すと追従する）
    @State private var manualSlowFactor: Double?
    @State private var selectedPhase: SwingPhase = .impact
    @State private var player: AVPlayer?

    init(config: VideoConfig, asset: AVAsset, side: VideoSide, onSave: @escaping (PhaseSet, Double?) -> Void) {
        self.config = config
        self.onSave = onSave
        self.asset = asset
        self.side = side
        self._phases = State(initialValue: config.phases)
        self._manualSlowFactor = State(initialValue: config.slowFactor)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                ZStack {
                    Color.black
                    if let player { PlayerLayerView(player: player) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                VStack(spacing: 6) {
                    timeline
                        .frame(height: 56)
                        .padding(.horizontal, 14)

                    Text("マーカーをドラッグしてフェーズ位置を調整できます")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if config.candidates.count > 1 {
                    candidateRow
                }

                slowFactorRow

                Picker("フェーズ", selection: $selectedPhase) {
                    ForEach(SwingPhase.allCases) { phase in
                        Text(phase.label).tag(phase)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                // コマ単位の微調整
                HStack(spacing: 14) {
                    stepButton(frames: -10)
                    stepButton(frames: -1)
                    VStack(spacing: 2) {
                        Text(String(format: "%.3f 秒", phases.time(of: selectedPhase)))
                            .font(.callout.monospacedDigit())
                        Text("テンポ \(phases.tempoText)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(minWidth: 110)
                    stepButton(frames: 1)
                    stepButton(frames: 10)
                }
                .padding(.bottom, 8)
            }
            .navigationTitle("\(side.label)のフェーズ調整")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        // 推定と同じ値を選んだら、フェーズの変更に追従する自動推定へ戻す
                        onSave(phases, manualSlowFactor == estimatedSlowFactor ? nil : manualSlowFactor)
                        dismiss()
                    }
                    .bold()
                }
            }
            .task {
                // NOTE: 映像だけの合成が作れなければプレビューは黒のまま（動画は比較画面で既に読めている）。フェーズの操作はできる
                let player = AVPlayer(playerItem: try? await VideoImporter.playerItem(for: asset))
                guard !Task.isCancelled else { return }
                player.isMuted = true
                self.player = player
                seek(to: phases.time(of: selectedPhase))
            }
            .onChange(of: phases.time(of: selectedPhase)) { _, time in
                seek(to: time)
            }
            .onDisappear {
                player?.pause()
            }
        }
    }

    // MARK: - タイムライン

    private var timeline: some View {
        GeometryReader { geo in
            let scale = TimeScale(duration: config.duration, width: geo.size.width)
            ZStack(alignment: .leading) {
                // 背景：スイング区間の色分け（動画全体に対する位置）
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(.systemGray5))
                    .frame(height: 10)
                    .frame(maxHeight: .infinity, alignment: .center)

                ForEach(SwingSegment.allCases) { segment in
                    segmentBar(segment, scale: scale)
                }

                // マーカー
                ForEach(SwingPhase.allCases) { phase in
                    marker(for: phase, scale: scale)
                }
            }
            .coordinateSpace(name: "timeline")
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        phases.assign(selectedPhase, to: scale.time(atX: value.location.x), duration: config.duration)
                    })
        }
    }

    private func segmentBar(_ segment: SwingSegment, scale: TimeScale) -> some View {
        let x0 = scale.x(of: phases.time(of: segment.start))
        let x1 = scale.x(of: phases.time(of: segment.end))
        return Rectangle()
            .fill(segment.color.opacity(0.8))
            .frame(width: max(x1 - x0, 0), height: 10)
            .frame(maxHeight: .infinity, alignment: .center)
            .offset(x: x0)
    }

    private func marker(for phase: SwingPhase, scale: TimeScale) -> some View {
        let isSelected = phase == selectedPhase
        return VStack(spacing: 1) {
            Text(phase.shortLabel)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .frame(width: 18, height: 18)
                .background(
                    Circle().fill(isSelected ? Color.accentColor : Color(.systemGray4)))
            Rectangle()
                .fill(isSelected ? Color.accentColor : Color(.systemGray2))
                .frame(width: 2, height: 26)
        }
        .offset(x: scale.x(of: phases.time(of: phase)) - 9)
        .onTapGesture {
            selectedPhase = phase
        }
        .highPriorityGesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .named("timeline"))
                .onChanged { value in
                    selectedPhase = phase
                    phases.assign(phase, to: scale.time(atX: value.location.x), duration: config.duration)
                })
    }

    // MARK: - スイング候補

    /// 動画に複数のスイング（素振りなど）が写っているとき、どれを使うか選ぶ。ボタンの数字は候補の順番、カッコ内はインパクト時刻
    private var candidateRow: some View {
        HStack(spacing: 8) {
            Text("スイング候補")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(Array(config.candidates.enumerated()), id: \.offset) { index, candidate in
                // マーカーを微調整しても選択中の候補が分かるように、インパクト時刻が近ければ同じ候補とみなす
                let isCurrent = abs(candidate.impact - phases.impact) < 0.03
                Button {
                    phases = candidate
                } label: {
                    Text(String(format: "%d (%.1f秒)", index + 1, candidate.impact))
                        .capsuleChip(font: .caption.monospacedDigit(), selected: isCurrent,
                                     selectedStyle: AnyShapeStyle(Color.accentColor.opacity(0.4)))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("candidate.\(index)")
            }
            Spacer()
        }
        .padding(.horizontal)
    }

    // MARK: - 動画の速さ

    /// 編集中のフェーズからの推定（検出失敗の仮のフェーズのままなら実速）
    private var estimatedSlowFactor: Double {
        config.estimatedSlowFactor(for: phases)
    }

    /// 焼き込みスローの倍率。選ぶまでは推定に従い（「推定」と示す）、フェーズを直すと追従する。違っていれば選び直す（比較画面の x1 が実速になる）
    private var slowFactorRow: some View {
        HStack(spacing: 8) {
            Text(manualSlowFactor == nil ? "動画の速さ（推定）" : "動画の速さ")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize()
            Picker("動画の速さ", selection: Binding(get: { manualSlowFactor ?? estimatedSlowFactor }, set: { manualSlowFactor = $0 })) {
                ForEach(SlowFactor.choices, id: \.self) { factor in
                    Text(SlowFactor.label(factor)).tag(factor)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("slowFactor")
        }
        .padding(.horizontal)
    }

    // MARK: - 操作

    /// 選択中のフェーズを frames コマ動かす（負なら戻す）
    private func stepButton(frames: Int) -> some View {
        Button {
            let t = phases.time(of: selectedPhase) + Double(frames) * config.frameDuration
            phases.assign(selectedPhase, to: t, duration: config.duration)
        } label: {
            Text(String(format: "%+dコマ", frames))
                .capsuleChip()
        }
        .buttonStyle(.plain)
    }

    private func seek(to time: Double) {
        guard let player else { return }
        player.pause()
        player.seek(
            to: CMTime(seconds: time, preferredTimescale: 6000),
            toleranceBefore: .zero, toleranceAfter: .zero)
    }
}

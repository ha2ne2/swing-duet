import SwiftUI

/// 再生ボタンを中心にしたジョグホイール。帯を回すと基準側動画の 1 コマ単位で進み（時計回りが進む）、帯の左右をタップすると ±1 コマ。
/// 回した量が移動量、回した速さが速さで、指を置いたまま往復できる。回し続けると 1 周ごとに 1 目盛りのコマ数が倍になる
/// （`JogRotation.framesPerDetent`。逆回転や指を止めると 1 コマに戻る）ので、1 周目は 1 コマずつ、3 周目からは 4 コマずつ動かせる
/// （設計は docs/design/260911_0741-jog-wheel-frame-stepping.md、根拠は docs/research/260911_1226-jog-wheel-acceleration-survey.md）。
///
/// 触覚は 3 種類だけ：1 コマごとに軽く、トップ / インパクトを通過したら中くらい、ループ範囲の端に当たったら重く。
/// 触覚は回転を数えた時点で返し、シークの完了は待たない（待つと速く回したとき遅れて、指で数えた数と合わなくなる）
struct JogWheelView: View {
    let controller: PlaybackController
    /// 外径（pt）。帯の幅と再生ボタンはこれに比例する（132 で帯 32・再生 52。横画面は 96 に縮める）
    var diameter: CGFloat = 132

    /// 1 周のコマ数（30fps の動画なら 1 周 = 基準側の 1 秒）
    private static let framesPerTurn = 30
    private static let degreesPerFrame = 360.0 / Double(framesPerTurn)
    /// 帯の左右のタップ領域（中心からの角度 ±60°）。`cos` がこの値以上なら右、以下の負なら左
    private static let tapZoneCosine = 0.5

    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @State private var rotation = JogRotation(degreesPerDetent: degreesPerFrame)
    // 触覚のトリガー。値が変わるたびに 1 回鳴る
    @State private var ticks = 0
    @State private var bumps = 0
    /// ループ範囲の端に当たっている。true になった瞬間だけ鳴らす（当たり続けても鳴らし続けない）
    @State private var atEnd = false

    private var bandWidth: CGFloat { diameter * 32 / 132 }
    private var playDiameter: CGFloat { diameter * 52 / 132 }

    var body: some View {
        ZStack {
            band
            playButton
        }
        .frame(width: diameter, height: diameter)
    }

    // MARK: - 帯

    private var band: some View {
        Band(width: bandWidth)
            .fill(.quaternary, style: FillStyle(eoFill: true))
            .overlay(marks)
            .contentShape(Band(width: bandWidth), eoFill: true)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let detents = rotation.update(angle: angle(of: value.location), at: value.time)
                        if detents != 0 { step(detents * rotation.framesPerDetent) }
                    }
                    .onEnded { value in
                        // 回さずに離したらタップ。左右のタップ領域なら ±1 コマ
                        let moved = hypot(value.translation.width, value.translation.height)
                        if abs(rotation.totalDegrees) < Self.degreesPerFrame / 2, moved < 10 {
                            let cosine = cos(angle(of: value.startLocation))
                            if cosine <= -Self.tapZoneCosine { step(-1) } else if cosine >= Self.tapZoneCosine { step(1) }
                        }
                        rotation.end()
                    })
            .sensoryFeedback(.selection, trigger: ticks)
            .sensoryFeedback(.impact(weight: .medium), trigger: bumps)
            .sensoryFeedback(.impact(weight: .heavy), trigger: atEnd) { _, hit in hit }
            // ギアは画面に出さず、上がった瞬間の触覚だけで伝える（戻るのは離す・止める・逆回転なので鳴らさない）
            .sensoryFeedback(.increase, trigger: rotation.framesPerDetent) { old, new in new > old }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("コマ送り")
            // NOTE: `commonTime` を body で読むと再生中に毎 tick 描き直されるので、読み上げが要る VoiceOver のときだけ読む
            .accessibilityValue(voiceOverEnabled ? String(format: "%.2f 秒", controller.commonTime) : "")
            .accessibilityHint("上下にスワイプで 1 コマ")
            .accessibilityAdjustableAction { direction in
                step(direction == .increment ? 1 : -1)
            }
            .accessibilityIdentifier("transport.jog")
    }

    /// 帯の外縁の刻み（1 コマごと。回しても動かない）と、左右のタップ領域の印
    private var marks: some View {
        ZStack {
            ForEach(0..<Self.framesPerTurn, id: \.self) { i in
                Capsule()
                    .fill(.secondary)
                    .frame(width: 1.5, height: 6)
                    .offset(y: -(diameter / 2 - 6))
                    .rotationEffect(.degrees(Double(i) * Self.degreesPerFrame))
            }
            HStack {
                Image(systemName: "backward.frame.fill")
                Spacer()
                Image(systemName: "forward.frame.fill")
            }
            .font(.system(size: bandWidth * 0.36))
            .foregroundStyle(.secondary)
            .padding(.horizontal, bandWidth * 0.32)
        }
    }

    /// 帯の上の点の、中心から見た角度（ラジアン。画面座標は y が下向きなので時計回りが正）
    private func angle(of point: CGPoint) -> Double {
        atan2(point.y - diameter / 2, point.x - diameter / 2)
    }

    /// frames コマ動かし、結果に応じた触覚を鳴らす
    private func step(_ frames: Int) {
        let before = controller.commonTime
        controller.stepFrame(by: frames)
        let after = controller.commonTime
        atEnd = after == before
        guard !atEnd else { return }
        let crossed = [SwingPhase.top, .impact].contains { phase in
            let t = controller.sync.commonTime(of: phase)
            return (before >= t) != (after >= t)
        }
        if crossed { bumps += 1 } else { ticks += 1 }
    }

    // MARK: - 再生ボタン

    private var playButton: some View {
        Button {
            controller.togglePlay()
        } label: {
            Image(systemName: controller.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                .font(.system(size: playDiameter))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(controller.isPlaying ? "一時停止" : "再生")
        .accessibilityIdentifier("transport.play")
    }
}

/// ドーナツ形（外周の円から幅 `width` の帯）。塗りと当たり判定は even-odd で穴を抜く
private struct Band: Shape {
    var width: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path(ellipseIn: rect)
        path.addPath(Path(ellipseIn: rect.insetBy(dx: width, dy: width)))
        return path
    }
}

/// ジョグホイールの回転を目盛りに数え、回し続けた周回で「ギア」（1 目盛りのコマ数）を上げる。
/// 指の角度を渡すたびに前回からの回転を積み、目盛り（`degreesPerDetent`）を越えた数を返す。角度は ±π をまたいで飛ぶので、差を −π〜π に折り返してから積む。
///
/// ギアを瞬間の速さで決めない理由：親指で円を描くと、伸ばす区間（右下 → 左上）だけが速いという手の構造上の偏りがあり、
/// 速さで決めると 1 周の中で目盛りの重さが脈打つ。回した量なら 1 周の中は一定で、「回した周の数で段が上がる」と言葉で説明できる
struct JogRotation {
    let degreesPerDetent: Double
    /// ギアが 1 段上がるのに要する回転（1 周）
    private static let degreesPerGear = 360.0
    /// これ以上ギアは上がらない（×8 は速すぎて狙った場所を通り過ぎる）
    private static let maxGear = 4
    /// この時間（秒）指が止まったら別の回しとみなし、ギアを 1 に戻す
    private static let pauseInterval = 0.3

    /// 前回の指の角度（ラジアン）と時刻。指を置いた直後は nil
    private var lastAngle: Double?
    private var lastTime: Date?
    /// 目盛りに満たない持ち越し（度）
    private var carry = 0.0
    /// いまの「回し」（止めたり逆回転したりせずに回し続けている分）の累積回転（度）。ギアの根拠
    private var runDegrees = 0.0
    /// いまの回しの向き（+1 時計回り / −1 反時計回り / 0 まだ目盛りを越えていない）
    private var runDirection = 0
    /// 指を置いてからの回転量（度）。回さずに離した（タップ）かどうかの判定に使う
    private(set) var totalDegrees = 0.0

    init(degreesPerDetent: Double) {
        self.degreesPerDetent = degreesPerDetent
    }

    /// 1 目盛りあたりのコマ数。1 周目 1、2 周目 2、3 周目以降 4
    var framesPerDetent: Int {
        let laps = Int(abs(runDegrees) / Self.degreesPerGear)
        return min(1 << laps, Self.maxGear)
    }

    /// 指の角度（ラジアン、時計回りが正）と時刻を更新し、越えた目盛りの数を返す（時計回りが正。1 回の更新で複数越えることもある）
    mutating func update(angle: Double, at time: Date) -> Int {
        defer {
            lastAngle = angle
            lastTime = time
        }
        guard let lastAngle, let lastTime else { return 0 }
        var delta = angle - lastAngle
        if delta > .pi { delta -= 2 * .pi } else if delta < -.pi { delta += 2 * .pi }
        let degrees = delta * 180 / .pi
        totalDegrees += degrees
        carry += degrees
        if time.timeIntervalSince(lastTime) > Self.pauseInterval { resetRun() }

        let detents = Int((carry / degreesPerDetent).rounded(.towardZero))
        carry -= Double(detents) * degreesPerDetent
        if detents != 0 {
            // 逆回転は目盛りを越えた時点で判定する（指の揺れで目盛りに満たない分は無視）
            let direction = detents > 0 ? 1 : -1
            if runDirection != 0, direction != runDirection { resetRun() }
            runDirection = direction
        }
        runDegrees += degrees
        return detents
    }

    /// 指が離れた
    mutating func end() {
        lastAngle = nil
        lastTime = nil
        carry = 0
        totalDegrees = 0
        resetRun()
    }

    private mutating func resetRun() {
        runDegrees = 0
        runDirection = 0
    }
}

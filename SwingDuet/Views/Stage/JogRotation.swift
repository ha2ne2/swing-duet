import Foundation

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

import Testing
import Foundation
import CoreGraphics
@testable import SwingDuet

/// 部位の軌跡（保存する範囲・平滑化・線の切れ目・今いる点・旧データの読み込み）を固定する
struct JointTrailsTests {

    /// 手の点列だけを持つサンプル（30fps 相当の時刻）
    private func trails(hands: [CGPoint?], start: Double = 0) -> JointTrails {
        JointTrails(samples: hands.enumerated().map { i, point in
            JointTrailSample(time: start + Double(i) / 30, hands: point)
        })
    }

    /// 肩（ほとんど動かない部位）の点列だけを持つサンプル
    private func trails(shoulder: [CGPoint?]) -> JointTrails {
        JointTrails(samples: shoulder.enumerated().map { i, point in
            JointTrailSample(time: Double(i) / 30, leftShoulder: point)
        })
    }

    private func phases(_ address: Double) -> PhaseSet {
        PhaseSet(address: address, top: address + 1, impact: address + 1.3, finish: address + 2)
    }

    // MARK: - 保存する範囲

    @Test func sampleRangeCoversOtherCandidatesOnlyWhenTheWholeSpanIsShort() {
        let chosen = phases(10)
        #expect(JointTrails.sampleRange(chosen: chosen, candidates: [chosen]) == 9.0...13.0)   // 前後 1 秒
        let near = phases(3)
        #expect(JointTrails.sampleRange(chosen: chosen, candidates: [near, chosen]) == 2.0...13.0)   // 11 秒に収まるので候補全体
        let far = phases(100)
        #expect(JointTrails.sampleRange(chosen: chosen, candidates: [near, chosen, far]) == 9.0...13.0)   // 収まらないので採用スイングだけ
    }

    // MARK: - 平滑化

    @Test func smoothingHalvesZigzagAndLeavesEndsAndGapsAlone() {
        // 直線に ±0.02 のジグザグを乗せる。5 点目は欠け
        var points: [CGPoint?] = (0..<12).map { i in CGPoint(x: 0.05 * Double(i), y: 0.5 + (i % 2 == 0 ? 0.02 : -0.02)) }
        points[8] = nil
        let smoothed = trails(hands: points).smoothed(swingSamples: points.count)
        let ys = smoothed.samples.map { $0.hands?.y }
        #expect(ys[0] == 0.52 && ys[1] == 0.48)              // 端の 2 点はそのまま
        #expect(abs(ys[3]! - 0.5) < 0.01)                    // 中の点は揺れが 0.02 → 0.01 未満
        #expect(ys[8] == nil)                                // 欠けは埋めない
        #expect(ys[6] == 0.52 && ys[7] == 0.48 && ys[10] == 0.52)   // 欠けが窓に掛かる点はそのまま
        #expect(smoothed.samples.map(\.time) == trails(hands: points).samples.map(\.time))
    }

    @Test func smoothingKeepsAStraightLineStraight() {
        let points: [CGPoint?] = (0..<9).map { i in CGPoint(x: 0.1 * Double(i), y: 0.2 + 0.05 * Double(i)) }
        let smoothed = trails(hands: points).smoothed(swingSamples: points.count)
        for (before, after) in zip(points, smoothed.samples.map(\.hands)) {
            #expect(abs(before!.x - after!.x) < 1e-9 && abs(before!.y - after!.y) < 1e-9)
        }
    }

    /// ほとんど動かない部位（肩・股関節・頭）は、手より強く均す。
    /// 手はスイングの弧そのものなので形を残す 5 点で、肩はコマ数に比例した窓の移動平均になる
    @Test func bodyPartsAreSmoothedHarderThanTheHands() {
        // 150 コマ（5 秒）の直線に ±0.02 のジグザグ。窓はコマ数に比例するので 11 点になる
        let zigzag: [CGPoint?] = (0..<150).map { i in CGPoint(x: 0.003 * Double(i), y: 0.5 + (i % 2 == 0 ? 0.02 : -0.02)) }
        #expect(JointTrails.bodyWindow(samples: 150) == 11)
        let shoulder = trails(shoulder: zigzag).smoothed(swingSamples: zigzag.count).samples[75].leftShoulder
        let hand = trails(hands: zigzag).smoothed(swingSamples: zigzag.count).samples[75].hands
        let shoulderResidual = abs((shoulder?.y ?? 0) - 0.5)
        let handResidual = abs((hand?.y ?? 0) - 0.5)
        #expect(shoulderResidual < 0.004)              // 11 点の移動平均でほぼ消える
        #expect(handResidual > shoulderResidual * 3)   // 手は形を残すので揺れも残る
        #expect(trails(shoulder: zigzag).smoothed(swingSamples: zigzag.count).samples[0].leftShoulder?.y == 0.52)   // 端はそのまま
    }

    /// 均す窓は保存範囲のコマ数ではなく、**採用スイングのコマ数**で決まる
    /// （同じスイングでも、前に素振りがあって保存範囲が広いだけで平滑化の強さが変わってはいけない）
    @Test func theWindowFollowsTheSwingNotTheSavedRange() {
        // 300 コマ（10 秒）ぶん保存するが、スイングは真ん中の 60 コマ（2 秒）だけ
        let zigzag: [CGPoint?] = (0..<300).map { i in CGPoint(x: 0.001 * Double(i), y: 0.5 + (i % 2 == 0 ? 0.02 : -0.02)) }
        let wide = trails(shoulder: zigzag).smoothed(swingSamples: 300).samples[150].leftShoulder
        let narrow = trails(shoulder: zigzag).smoothed(swingSamples: 60).samples[150].leftShoulder
        #expect(JointTrails.bodyWindow(samples: 300) == 21 && JointTrails.bodyWindow(samples: 60) == 5)
        #expect(abs((wide?.y ?? 0) - 0.5) < abs((narrow?.y ?? 0) - 0.5))   // 窓が広いほど残る揺れが小さい
    }

    // MARK: - 線の切れ目

    @Test func strokesBreakOnLongGapsAndJumpsButBridgeShortGaps() {
        var points: [CGPoint?] = (0..<40).map { i in CGPoint(x: 0.01 * Double(i), y: 0.5) }
        points[5] = nil                                 // 1 コマの欠け → つなぐ
        for i in 10..<25 { points[i] = nil }            // 0.5 秒の欠け → 切る
        points[32] = CGPoint(x: 0.9, y: 0.9)            // 飛び → その前後で切る
        let strokes = trails(hands: points).strokes(of: .hands, in: 0...10)
        #expect(strokes.map(\.count) == [9, 7, 7])      // 0〜9（5 を飛ばす）/ 25〜31 / 33〜39。飛んだ 1 点だけの線は返さない
        #expect(strokes[0].map(\.time).contains(4.0 / 30) && !strokes[0].map(\.time).contains(5.0 / 30))
        #expect(strokes[2].first?.time == 33.0 / 30)
    }

    /// 隠れている間に 1 コマだけ現れる誤検出は、線にも丸にも使わない
    @Test func aLoneObservationBetweenTwoGapsIsIgnored() {
        var points: [CGPoint?] = (0..<12).map { i in CGPoint(x: 0.01 * Double(i), y: 0.5) }
        points[5] = nil
        points[6] = CGPoint(x: 0.8, y: 0.9)             // 前後が欠測の誤検出
        points[7] = nil
        let trails = trails(hands: points)
        let strokes = trails.strokes(of: .hands, in: 0...10)
        #expect(strokes.map(\.count) == [9])            // 0〜4 と 8〜11 が 1 本につながる（誤検出の 6 は入らない）
        #expect(strokes[0].allSatisfy { $0.point.x < 0.5 })
        #expect(JointTrails.position(on: strokes, at: 6.0 / 30)?.x != 0.8)
    }

    /// 保存範囲の端は「隣のコマが無い」だけで欠測ではないので、孤立点として落とさない
    @Test func theFirstAndLastObservationsAreKeptEvenWithAGapNextToThem() {
        var points: [CGPoint?] = (0..<12).map { i in CGPoint(x: 0.01 * Double(i), y: 0.5) }
        points[1] = nil
        points[10] = nil
        let strokes = trails(hands: points).strokes(of: .hands, in: 0...10)
        #expect(strokes.map(\.count) == [10])
        #expect(strokes[0].first?.time == 0 && strokes[0].last?.time == 11.0 / 30)
    }

    /// 後方視点のフォローでは手が数コマ体に隠れる。その間も動くので、1 コマぶんの距離より離れて出てくる。
    /// 出てきた先が同じくらいの速さで動いていればつなぐ
    @Test func aShortOcclusionIsBridgedWhenTheMotionMatches() {
        /// 1 コマ 0.08（＝ 2.4/秒）で進み、5 コマ隠れてから `moved` だけ離れたところに出てくる
        func strokes(moved: Double) -> [[TrailPoint]] {
            var points: [CGPoint?] = (0..<5).map { i in CGPoint(x: 0.02 + 0.08 * Double(i), y: 0.5) }
            points += Array(repeating: nil, count: 4)
            points += (0..<3).map { i in CGPoint(x: 0.34 + moved + 0.08 * Double(i), y: 0.5) }
            return trails(hands: points).strokes(of: .hands, in: 0...10)
        }
        #expect(strokes(moved: 0.40).count == 1)   // 隠れている間も同じ速さ → つなぐ（1 コマぶん 0.25 より遠い）
        #expect(strokes(moved: 0.60).count == 2)   // 上限（0.25 × 2）を超えたら切る
    }

    /// 隠れている間に別の場所へ貼り付いた誤検出へは、線を伸ばさない。
    /// 距離と時間だけ見るとつながってしまうので、またいだ区間の速さが前後の速さと釣り合うかで判断する
    @Test func aJumpToSomethingThatIsNotMovingIsNotBridged() {
        /// 隠れている間の移動は 0.40 で固定し、その前後 1 コマの動き（`step`）だけを変える
        func strokes(step: Double) -> [[TrailPoint]] {
            var points: [CGPoint?] = (0..<5).map { i in CGPoint(x: 0.50 - step * Double(4 - i), y: 0.5) }
            points += Array(repeating: nil, count: 4)
            points += (0..<3).map { i in CGPoint(x: 0.10 + step * Double(i), y: 0.5) }
            return trails(hands: points).strokes(of: .hands, in: 0...10)
        }
        #expect(strokes(step: 0.001).count == 2)   // 前後とも止まっている → つながない
        #expect(strokes(step: 0.080).count == 1)   // 前後とも動いている → つなぐ
    }

    @Test func strokesAreLimitedToTheRange() {
        let points: [CGPoint?] = (0..<30).map { i in CGPoint(x: 0.01 * Double(i), y: 0.5) }
        let strokes = trails(hands: points).strokes(of: .hands, in: 0.2...0.5)
        #expect(strokes.count == 1)
        #expect(strokes[0].first?.time == 6.0 / 30 && strokes[0].last?.time == 15.0 / 30)
        #expect(trails(hands: points).strokes(of: .head, in: 0...1).isEmpty)   // 無い部位は線なし
    }

    /// 出し分けは 4 つ。左右の対はひとつにまとめる
    @Test func partsAreGroupedIntoFourSwitchesWithLeftAndRightTogether() {
        #expect(TrailPartGroup.allCases.map(\.label) == ["頭", "肩", "手", "腰"])
        // 並べ替えても保存に使う桁は動かさない（残っている選択が別の部位にずれるため）
        #expect(TrailPartGroup.hands.bit == 1 && TrailPartGroup.head.bit == 2)
        #expect(TrailPartGroup.shoulders.bit == 4 && TrailPartGroup.hips.bit == 8)
        #expect(BodyPart.leftShoulder.group == .shoulders && BodyPart.rightShoulder.group == .shoulders)
        #expect(BodyPart.leftHip.group == .hips && BodyPart.rightHip.group == .hips)
    }

    /// 隠す組は数 1 つで持つ。0 なら全部出す。組を足しても既定は表示のまま
    @Test func hiddenGroupsAreKeptAsBitsAndDefaultToShown() {
        #expect(TrailPartGroup.shownParts(hidden: 0) == BodyPart.allCases)
        #expect(TrailPartGroup.shownParts(hidden: TrailPartGroup.hips.bit) == [.leftShoulder, .rightShoulder, .head, .hands])
        let onlyHands = TrailPartGroup.allCases.filter { $0 != .hands }.reduce(0) { $0 | $1.bit }
        #expect(TrailPartGroup.shownParts(hidden: onlyHands) == [.hands])
        #expect(TrailPartGroup.shownParts(hidden: TrailPartGroup.allCases.reduce(0) { $0 | $1.bit }).isEmpty)
    }

    /// 部位の並びは描く順（股関節が下、手が一番上）
    @Test func partsAreDrawnFromHipsUpToHands() {
        #expect(BodyPart.allCases == [.leftHip, .rightHip, .leftShoulder, .rightShoulder, .head, .hands])
    }

    /// 線の上の位置は、コマの間を補間して返す（線が一定の速さで伸びるように）
    @Test func positionOnAStrokeIsInterpolatedBetweenSamples() {
        // x はコマ番号 ÷ 8（2 進で誤差なく表せる値にして、比較を厳密にする）
        let points: [CGPoint?] = (0..<10).map { i in CGPoint(x: Double(i) / 8, y: 0.5) }
        let strokes = trails(hands: points).strokes(of: .hands, in: 0...10)
        #expect(JointTrails.position(on: strokes, at: 0.1)?.x == 3.0 / 8)   // 4 コマ目（0.1 秒）ちょうど
        let between = try? #require(JointTrails.position(on: strokes, at: 3.5 / 30)?.x)
        #expect(abs((between ?? 0) - 3.5 / 8) < 1e-9)                       // 4 コマ目と 5 コマ目の中間
        #expect(JointTrails.position(on: strokes, at: 2.0) == nil)          // 線から 0.1 秒より離れている
        #expect(JointTrails.position(on: [], at: 0.1) == nil)               // 線が無い
    }

    /// 隠れている間も、線の先は一定の速さで進む（欠測のところで止まって、見えた瞬間に飛ばない）
    @Test func theTipKeepsMovingWhileThePartIsHidden() {
        var points: [CGPoint?] = (0..<5).map { i in CGPoint(x: 0.1 * Double(i), y: 0.5) }
        points += Array(repeating: nil, count: 3)                          // 0.1 秒隠れる
        points += (0..<4).map { i in CGPoint(x: 0.8 + 0.1 * Double(i), y: 0.5) }
        let strokes = trails(hands: points).strokes(of: .hands, in: 0...10)
        #expect(strokes.count == 1)                                        // 欠測をまたいで 1 本
        let steps = (0...6).compactMap { JointTrails.position(on: strokes, at: (4.0 + Double($0) * 0.5) / 30)?.x }
        #expect(steps.count == 7)
        let deltas = zip(steps, steps.dropFirst()).map { $1 - $0 }
        #expect(deltas.allSatisfy { abs($0 - deltas[0]) < 1e-9 })          // 進み方が一定
    }

    /// 線が切れているところでは、近い方の線の端に置く（無い線の上に丸を浮かせない）
    @Test func positionFallsBackToTheNearestEndAcrossABreak() {
        let before = (0..<5).map { TrailPoint(time: Double($0) / 30, point: CGPoint(x: 0.1, y: 0.5)) }
        let after = (16..<21).map { TrailPoint(time: Double($0) / 30, point: CGPoint(x: 0.9, y: 0.5)) }
        #expect(JointTrails.position(on: [before, after], at: 5.0 / 30)?.x == 0.1)    // 前の線の端が近い
        #expect(JointTrails.position(on: [before, after], at: 15.0 / 30)?.x == 0.9)   // 後の線の端が近い
        #expect(JointTrails.position(on: [before, after], at: 10.0 / 30) == nil)      // どちらからも 0.1 秒より遠い
    }

    /// ほとんど動かない部位に掛ける移動平均の窓。コマ数に比例させ、5〜21 の奇数に収める
    /// （実速の短いスイングで弧を潰さず、スローでは実時間で同じくらい均すため）
    @Test func bodyWindowGrowsWithTheSwingAndStaysAnOddNumberInRange() {
        #expect(JointTrails.bodyWindow(samples: 39) == 5)      // 実速の短いスイングは最小
        #expect(JointTrails.bodyWindow(samples: 108) == 7)
        #expect(JointTrails.bodyWindow(samples: 235) == 15)
        #expect(JointTrails.bodyWindow(samples: 567) == 21)    // 1/8 スローでも上限で止める
        for count in [0, 1, 30, 100, 300, 1000, 5000] {
            let window = JointTrails.bodyWindow(samples: count)
            #expect((5...21).contains(window) && window % 2 == 1)
        }
    }

    // MARK: - 追跡結果からの変換

    @Test func poseTrackBecomesTrailsOfTheRangeWithJointsMapped() {
        let frames = (0..<10).map { i in
            PoseFrame(
                time: Double(i) / 10,
                wrist: CGPoint(x: 0.4, y: 0.3),
                head: CGPoint(x: 0.5, y: 0.9),
                leftShoulder: i == 5 ? nil : CGPoint(x: 0.55, y: 0.7),
                rightShoulder: CGPoint(x: 0.45, y: 0.7),
                leftHip: CGPoint(x: 0.53, y: 0.5),
                rightHip: CGPoint(x: 0.47, y: 0.5),
                root: CGPoint(x: 0.5, y: 0.5),
                neck: CGPoint(x: 0.5, y: 0.7),
                bodyBounds: nil)
        }
        let trails = PoseTrack(frames: frames).jointTrails(in: 0.2...0.5, swing: 0.2...0.5)
        #expect(trails.samples.map(\.time) == [0.2, 0.3, 0.4, 0.5])   // 範囲の中のコマだけ
        let first = trails.samples[0]
        #expect(first.hands == CGPoint(x: 0.4, y: 0.3))                 // 手首の中点 → 手
        #expect(first.head == CGPoint(x: 0.5, y: 0.9))
        #expect(first.leftShoulder == CGPoint(x: 0.55, y: 0.7))
        #expect(first.rightShoulder == CGPoint(x: 0.45, y: 0.7))
        #expect(first.leftHip == CGPoint(x: 0.53, y: 0.5))
        #expect(first.rightHip == CGPoint(x: 0.47, y: 0.5))
        #expect(trails.samples[3].leftShoulder == nil)                  // 見えなかったコマは無いまま
    }

    // MARK: - 保存

    @Test func videoConfigWithoutTrailsStillDecodes() throws {
        let json = """
        {"fileName":"a.mov","duration":3,"frameRate":30,"phases":{"address":0.2,"top":0.8,"impact":1.0,"finish":1.5}}
        """
        let config = try JSONDecoder().decode(VideoConfig.self, from: Data(json.utf8))
        #expect(config.jointTrails == nil)
    }

    @Test func trailsRoundTripThroughJSON() throws {
        var config = VideoConfig(fileName: "a.mov", duration: 3, frameRate: 30, phases: phases(0.5))
        config.jointTrails = JointTrails(samples: [
            JointTrailSample(time: 0.5, hands: CGPoint(x: 0.4, y: 0.3), head: CGPoint(x: 0.5, y: 0.8),
                             leftShoulder: nil, rightShoulder: CGPoint(x: 0.45, y: 0.7), leftHip: CGPoint(x: 0.53, y: 0.5), rightHip: nil),
            JointTrailSample(time: 0.533, hands: nil, head: CGPoint(x: 0.5, y: 0.81),
                             leftShoulder: CGPoint(x: 0.55, y: 0.7), rightShoulder: nil, leftHip: nil, rightHip: CGPoint(x: 0.47, y: 0.5)),
        ])
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(VideoConfig.self, from: data)
        #expect(decoded == config)
        #expect(decoded.jointTrails?.isCurrent == true)
    }

    /// 版を書く前（首と腰の中心で作った）軌跡は「古い」と分かり、比較画面が作り直す
    @Test func trailsWithoutAVersionAreStale() throws {
        let current = JointTrails(samples: [JointTrailSample(time: 0.5, hands: CGPoint(x: 0.4, y: 0.3))])
        #expect(current.isCurrent)
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as! [String: Any]
        object.removeValue(forKey: "version")   // 版を書く前の保存データ
        let legacy = try JSONDecoder().decode(JointTrails.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(legacy.version == 0)
        #expect(legacy.isCurrent == false)
        // 版を上げたら、その版より前に作った軌跡はすべて作り直しの対象になる
        #expect(JointTrails(version: JointTrails.currentVersion - 1, samples: []).isCurrent == false)
    }
}

# TODO

フェーズ計画（[ROADMAP.md](./ROADMAP.md)）に乗らない、個別の未対応事項を書き留める場所。
対応したら項目ごと消すか、経緯が重要なら研究・設計ドキュメントへ昇格させる。

## ステータス一覧

- [ ] A. PhotosPicker 経由のスローモーション動画が 30fps レンダリング版になる（2026-09-06 起票）
- [ ] B. テストターゲットが無い（2026-09-06 起票）
- [ ] C. 再生速度スライダーが自動 E2E で未検証（2026-09-06 起票）
- [ ] D. 30fps 動画でトップ〜インパクトがブレで欠測すると位置が粗い（2026-09-06 起票）

---

### A. PhotosPicker 経由のスローモーション動画が 30fps レンダリング版になる（2026-09-06 起票）

- **背景**: 2026-09-06 のシミュレータ検証で、240fps・3.0 秒の動画を選ぶとアプリには **30fps・14.67 秒**（スロー効果が焼き込まれた再エンコード版）が渡された。
  写真アプリは 240fps 動画を「スローモーション」として扱い、`FileRepresentation(contentType: .movie)` は編集適用済みの現行バージョンを返すため。
  README / [SPEC.md](./SPEC.md) §2.1 の「実フレームレート単位でコマ送り」が成り立たず、スロー区間の伸縮でフェーズ時間・テンポ比も歪む。
  シミュレータの写真アプリでの再現が根拠で、実機の PhotosPicker でも同じ挙動と見込んでいるが未確認。
- **対象**: `SwingDuet/Services/VideoImporter.swift`（`ImportedMovie`）、`SwingDuet/Views/NewComparisonView.swift`（`PhotosPicker` / `loadMovie`）
- **やること**: `PhotosPicker(..., photoLibrary: .shared())` にして `PhotosPickerItem.itemIdentifier` を取得 →
  `PHAsset.fetchAssets(withLocalIdentifiers:)` → `PHImageManager.requestAVAsset(forVideo:options:)`（`version = .original`）で
  元の 240fps ファイルを取り出す。写真ライブラリの読み取り権限（`NSPhotoLibraryUsageDescription` は設定済み）が必要になるので、
  拒否時は現行の PhotosPicker 経路（30fps 版）にフォールバックし、その旨を表示する（[AGENTS.md](../AGENTS.md) §6.3）。
- **やらない理由（今）**: 実機での挙動確認と権限 UX の設計が先。
- **参照**: [research/260906_1531-simulator-verification.md](./research/260906_1531-simulator-verification.md) §4.1

### B. テストターゲットが無い（2026-09-06 起票）

- **背景**: MVP はテスト無しで作られた。[AGENTS.md](../AGENTS.md) §5.1 は「最初からテストを書く」前提。
- **対象**: `SwingDuet.xcodeproj/project.pbxproj`（テストターゲットの追加）、
  `SwingDuet/Models/SyncEngine.swift`、`SwingDuet/Models/SwingModels.swift`（`PhaseSet.sanitize` / `assign` / `fallback`）、
  `SwingDuet/Services/SwingAnalyzer.swift`（`speedSeries` / `motionSegments` / `detectSwings`）
- **やること**: Swift Testing のテストターゲット `SwingDuetTests` を pbxproj に追加し、上記の純粋ロジックから着手する。
  検出ロジックは合成した速度系列（静止 → 加速 → 減速 → 最大 → 静止）で境界条件を固定する。
- **やらない理由（今）**: pbxproj が手書き管理でターゲット追加の影響が大きい。ユーザーと合意してから着手する。
- **参照**: [ROADMAP.md](./ROADMAP.md) フェーズ 3

### C. 再生速度スライダーが自動 E2E で未検証（2026-09-06 起票）

- **背景**: XCUITest の `adjust(toNormalizedSliderPosition:)` が SwiftUI の `Slider` に効かず、値が 0.3 のまま変わらなかった。
  実装は `$controller.speed` への直接バインドなので不具合の可能性は低いが、自動では確認できていない。
- **対象**: `SwingDuet/Views/TransportControlsView.swift`、`.claude/skills/e2e-simulator/FlowTests.swift`
- **やること**: 実機・シミュレータで手動確認するか、E2E をつまみの座標ドラッグ方式に変える。
- **やらない理由（今）**: 優先度低。
- **参照**: [research/260906_1531-simulator-verification.md](./research/260906_1531-simulator-verification.md) §4.3

### D. 30fps 動画でトップ〜インパクトがブレで欠測すると位置が粗い（2026-09-06 起票）

- **背景**: Golfboy の自分の動画（30fps）では 1.6〜2.3 秒の 0.8 秒間、手首がブレで検出できず、トップは欠測直前（1.59 秒）、
  インパクトは欠測直後（2.56 秒）になってテンポが 0.8 : 1 と過小になる。現状は `lowConfidence` で警告し手動修正に頼っている。
- **対象**: `SwingDuet/Services/SwingAnalyzer.swift`（`swingCandidate` のトップ・インパクト決定、`SwingCandidate.downswingGap`）
- **やること**: 欠測区間があるときの推定を入れる。案: (1) 欠測直前のバックスイング速度の減速から静止（トップ）時刻を外挿し、
  欠測直後の位置とアドレス位置の距離からインパクト通過時刻を逆算する。(2) 手首以外の関節（肘・肩）で欠測を埋める。
  (3) 240fps の元ファイル取得（A）でそもそも欠測を減らす。`build/analyze-swing --series docs/data/*.mp4` で検証する。
- **やらない理由（今）**: A（元ファイル取得）で解決する見込みが大きく、先に実機で 240fps 撮影の欠測率を確認したい。
- **参照**: [research/260906_1641-multi-swing-detection.md](./research/260906_1641-multi-swing-detection.md) §2.2

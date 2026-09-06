---
name: e2e-simulator
description: iOS シミュレータで SwingDuet をビルド・起動し、動画 2 本の選択 → 解析 → 同期再生 → 保存 / 復元までを XCUITest で自動操作して動作確認する手順（テスト動画の投入・ハーネス生成・スクリーンショット検証）。「エミュレータで動作確認」「シミュレータで E2E」「通しで動かして」と言われたら使う。
---

# iOS シミュレータ E2E 動作確認手順

2026-09-06 に実際に動作確認済みの手順。所要時間の目安: ビルド約 1 分 + E2E 約 2 分。

## 前提知識

- Bundle ID は `com.ha2ne2.SwingDuet`。外部依存なし。ビルドの基本は [docs/guides/build-test.md](../../../docs/guides/build-test.md)
- 動作確認済みデバイス: iPhone 16e（iOS 26.2）。UDID は `xcrun simctl list devices available` で確認
- **Vision の姿勢推定はシミュレータで動かない**。解析は常にフォールバック位相（テンポ 3.0 : 1）＋「信頼度が低い」警告になる。
  E2E で検証できるのは「フロー・UI・再生同期・永続化」であって検出精度ではない（精度は実機で確認）
- 240fps の動画は PhotosPicker から 30fps のレンダリング版で渡る（[docs/TODO.md](../../../docs/TODO.md) A）

## 1. シミュレータ起動とスモークテスト

```bash
xcrun simctl boot "iPhone 16e" 2>/dev/null; open -a Simulator
xcodebuild build -project SwingDuet.xcodeproj -scheme SwingDuet \
  -destination 'platform=iOS Simulator,name=iPhone 16e' -derivedDataPath build -quiet
xcrun simctl install booted build/Build/Products/Debug-iphonesimulator/SwingDuet.app
xcrun simctl launch booted com.ha2ne2.SwingDuet
xcrun simctl io booted screenshot /tmp/launch.png     # 空状態の一覧画面が出ていればOK
```

## 2. テスト動画の投入

写真アプリに動画が無いと PhotosPicker で選べない。どちらかを投入する:

```bash
# 実サンプル（docs/data/ は gitignore。人物が写るので共有しない）
xcrun simctl addmedia booted docs/data/*.mp4

# 合成の棒人間スイング動画（人物検出はされない。フロー確認用）
swiftc -O -o build/gen-swing-video .claude/skills/e2e-simulator/gen-swing-video.swift
build/gen-swing-video build/self_240fps.mov 240 3.0 0.50 0.62    # <出力> <fps> <秒> <トップ位置 0-1> <インパクト位置 0-1>
build/gen-swing-video build/model_60fps.mov 60 3.0 0.42 0.52
xcrun simctl addmedia booted build/self_240fps.mov build/model_60fps.mov
```

ピッカーは**撮影日時（動画の作成日）の新しい順**に並ぶ。addmedia した順番ではないので、合成動画（今日の日付）と
古い実サンプルが混在すると合成動画が先頭に来る。E2E で選ぶ動画は `E2E_MINE_MATCH` / `E2E_MODEL_MATCH`（下記）で日付指定するのが確実。

## 3. 自動 E2E（XCUITest ハーネス）

`osascript` / `cliclick` はアクセシビリティ権限が要り、失敗しやすい。権限不要で確実なのは XCUITest。
アプリの xcodeproj には手を入れず、`build/e2e-harness/` に「アプリ + UI テストバンドル」の別プロジェクトを生成して回す。

```bash
python3 .claude/skills/e2e-simulator/make-harness.py   # build/e2e-harness/ を生成（何度実行してもよい）
build/e2e-harness/run.sh                               # 起動中のシミュレータで実行。UDID を引数で指定も可
```

- `run.sh` はアプリをアンインストールしてから始める（毎回まっさらな状態）。アプリのソースは実行のたびに同期される
- 結果は `build/e2e-harness/out/` に出る:
  - `uitest_trace.log` … 操作ログ（TAP / MISSING / 各段階の画面テキスト）
  - `<テスト名>_NN_*.png` … 各段階のスクリーンショット（例 `FullFlow_09_playing.png`。目視で確認する）
  - `*.txt` … 画面の要素階層ダンプ（ボタンのラベルを調べるときに読む）
  - `../xcodebuild.log` … xcodebuild の全出力
- テスト内容は [FlowTests.swift](./FlowTests.swift):
  - `testFullFlow`: 起動 → ＋ → 動画 2 本選択 → 解析 → 比較画面 → 再生（再生中に基準切替・ループ範囲変更が効くこと）→ 停止 →
    フェーズジャンプ → コマ送り → 基準切替 → 速度切替 → ループ設定 → 区間ループ再生 → フェーズ調整シート → 一覧 → 再起動で復元 → 再オープン
  - `testZoomPanPersistence`: ペインをピンチで拡大 / 縮小・ドラッグで移動 → 一覧に戻って開き直す → 再起動、で状態が残ること → リセット。
    ペインの状態は `accessibilityValue`（`x1.50 (12, -30)` = 自動フィットに対する拡大率と位置）で読む
  - `testPhaseEditCandidates`: 保存済みプロジェクトを開き、フェーズ調整の「スイング候補」を切り替える。Vision が動かないので
    候補は `projects.json` に直接入れる（下記）。`E2E_KEEP_DATA=1` で回す（アンインストールしない）
- 1 テストだけ回す: `E2E_ONLY="SwingDuetUITests/FlowTests/testZoomPanPersistence" build/e2e-harness/run.sh`
- 候補 UI の確認手順: `testFullFlow` を回した後、
  `python3 - <<'EOF'` 等で `$(xcrun simctl get_app_container booted com.ha2ne2.SwingDuet data)/Documents/projects.json` の
  `model.candidates` に PhaseSet の配列（`build/analyze-swing docs/data/*.mp4` の出力から作る）を入れ、
  `E2E_KEEP_DATA=1 E2E_ONLY="SwingDuetUITests/FlowTests/testPhaseEditCandidates" build/e2e-harness/run.sh`
- `run.sh` は他のセッションが同じシミュレータで E2E を回していると衝突する（アプリのアンインストールと `out/` の削除で互いのランナーが落ち、
  「Restarting after unexpected exit」「Executed 0 tests」になる）。実行前に `pgrep -f "xcodebuild tes[t]"` で確認する
- ピッカーで選ぶ動画は環境変数で指定する。ラベル（`uitest_trace.log` の `picker: N video cells: [...]` に出る "ビデオ, 四秒, 9月05日, 23:09" 等）に
  含まれる文字列で選ぶのが確実:
  `E2E_MINE_MATCH="9月05日" E2E_MODEL_MATCH="8月30日" build/e2e-harness/run.sh`
  指定が無ければ `E2E_MINE_INDEX` / `E2E_MODEL_INDEX`（新しい順のセル番号。既定 1 / 0）

## 4. 検証のコツ

- 各操作後のスクリーンショットを必ず目視する。再生の進みはシークバーの再生ヘッド位置で判断する（時刻ラベルは無い）。
  2 秒 × 0.3 倍 → 共通時間 0.6 秒。共通時間の長さは基準側のスイング区間長
- PhotosPicker のセルは表示アニメーション中 `isHittable == false` になる。`coordinate(...).tap()` なら押せる（実装済み）
- 画面遷移中に全要素を列挙すると "Failed to get matching snapshot" で落ちる。`texts()` は存在確認しながらリトライしている
- ピンチは `element.pinch(withScale:velocity:)`（要素の中心が基準。倍率は指定どおりにならず 2.0 指定で 3 倍前後になる）、
  ドラッグは `coordinate.press(forDuration: 0.1, thenDragTo:)`。手動で試すときは Simulator.app で Option を押しながらドラッグ（Option+Shift で中心を移動）
- エラーログの確認:
  `xcrun simctl spawn booted log show --predicate 'process == "SwingDuet" AND (messageType == error OR messageType == fault)' --last 10m --style compact`
- 保存データ: `$(xcrun simctl get_app_container booted com.ha2ne2.SwingDuet data)/Documents/{projects.json,Videos/}`

## 5. 手動で触る

E2E 後はプロジェクトが 1 件入った状態でアプリが残るので、Simulator.app でそのまま操作できる。

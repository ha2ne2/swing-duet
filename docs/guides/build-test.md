# ビルド・動作確認手順

`SwingDuet.xcodeproj` をコマンドラインでビルドし、シミュレータ / 実機で動かす手順。
通しの自動 E2E は [.claude/skills/e2e-simulator/SKILL.md](../../.claude/skills/e2e-simulator/SKILL.md) を参照。

## 前提

- Xcode 26 以降（`xcodebuild -version` で確認）
- iOS 26 シミュレータ（`xcrun simctl list devices available` で確認）
- 署名は自動（`DEVELOPMENT_TEAM` は pbxproj に設定済み）。実機に入れる場合は Xcode に Apple ID がサインイン済みであること
- 外部依存なし（パッケージ解決の手順は不要）
- 作業ディレクトリ: リポジトリルート

## シミュレータでの起動確認

```bash
xcrun simctl boot "iPhone 16e" 2>/dev/null; open -a Simulator   # 起動済みならエラーになるが無視してよい
xcodebuild build -project SwingDuet.xcodeproj -scheme SwingDuet \
  -destination 'platform=iOS Simulator,name=iPhone 16e' -derivedDataPath build -quiet
xcrun simctl install booted build/Build/Products/Debug-iphonesimulator/SwingDuet.app
xcrun simctl launch booted com.ha2ne2.SwingDuet
```

スクリーンショット取得:

```bash
xcrun simctl io booted screenshot /tmp/screenshot.png
```

`-derivedDataPath build` で出力先を固定している（既定の DerivedData はプロジェクトごとに
複数生成されることがあり、グロブで指すと**古いビルドを掴む事故**が起きる）。

### 動画をフォトライブラリに入れる

シミュレータの写真アプリには動画が無いので、確認前に投入する:

```bash
xcrun simctl addmedia booted docs/data/*.mp4     # docs/data/ はサンプル動画置き場（gitignore）
```

- 合成のスイング風動画が欲しいときは `.claude/skills/e2e-simulator/gen-swing-video.swift`（使い方は SKILL.md）
- **240fps の動画は写真アプリで「スローモーション」扱いになり、PhotosPicker からは 30fps のレンダリング版が渡る**
  （[docs/TODO.md](../TODO.md) A）。240fps のまま解析・コマ送りする確認は現状できない

### シミュレータの制約

- Vision の姿勢推定はシミュレータでは動作しない（ログに `Missing weights path cnn_human_pose.espresso.weights`）。
  解析は常にフォールバック位相（テンポ 3.0 : 1）＋「信頼度が低い」警告になる。**検出精度の確認は実機で行う**

### ログ・データの確認

```bash
# アプリのエラー・fault ログ（直近 10 分）
xcrun simctl spawn booted log show --predicate 'process == "SwingDuet" AND (messageType == error OR messageType == fault)' \
  --last 10m --style compact
# 保存データ（projects.json と Videos/）
ls "$(xcrun simctl get_app_container booted com.ha2ne2.SwingDuet data)/Documents"
```

## 実機なしで検出ロジックを確認する（macOS CLI）

Vision はシミュレータでは動かないが Mac では動くので、アプリと同じ `SwingAnalyzer` を CLI にして実サンプルで検出結果を見られる:

```bash
swiftc -O -o build/analyze-swing SwingDuet/Services/SwingAnalyzer.swift SwingDuet/Models/SwingModels.swift scripts/analyze-swing/main.swift
build/analyze-swing docs/data/*.mp4            # 候補ごとの A/T/I/F・採点・採用（★）
build/analyze-swing --series docs/data/x.mp4   # 手首位置と速度の系列も出す（閾値を調整するとき）
```

検出ロジックを変えたら必ずこれで実サンプルを確認する（[docs/ARCHITECTURE.md](../ARCHITECTURE.md) §5）。

## 実機へのインストール

iPhone をケーブルで Mac につなぎ:

```bash
xcodebuild build -project SwingDuet.xcodeproj -scheme SwingDuet \
  -destination 'generic/platform=iOS' -allowProvisioningUpdates -derivedDataPath build
xcrun devicectl list devices    # connected / available (paired) であること。Identifier を次の <DEVICE_ID> に
xcrun devicectl device install app --device <DEVICE_ID> \
  build/Build/Products/Debug-iphoneos/SwingDuet.app
```

- Xcode 派は `open SwingDuet.xcodeproj` で開き、実機を選んで ▶ でも同じ
- 初回は iPhone の 設定 → 一般 → VPNとデバイス管理 で開発者を「信頼」する必要がある
- 無料 Apple ID の署名は **7 日で切れる**。切れたら再ビルド + 再インストール
- Wi-Fi 経由は不安定なことがある（`unavailable` のまま）。**ケーブル接続が確実**
- 手順は DriveMemory の iOS 版と同じ。本リポジトリでの実機インストールは 2026-09-06 時点で未実施

## 補足

- Bundle ID は `com.ha2ne2.SwingDuet`
- `build/`（DerivedData）と `xcuserdata/` は gitignore 済み

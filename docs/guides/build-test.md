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
- アプリの「動画」タブは写真ライブラリの権限を求める。許可すれば 240fps のスローモーション動画も原本のまま取り込める
  （拒否したときの OS ピッカー経由は 30fps のレンダリング版）。E2E の `run.sh` は `xcrun simctl privacy booted grant photos com.ha2ne2.SwingDuet` で先に許可する
  （iOS 26.2 では xcodebuild がアプリを入れ直すと消える。[TODO.md](../TODO.md) G）

### シミュレータの制約

- Vision の姿勢推定はシミュレータでは動作しない（ログに `Missing weights path cnn_human_pose.espresso.weights`）。
  解析は常にフォールバック位相（テンポ 3.0 : 1）になる（`lowConfidence` は記録のみで画面には出ない）。**検出精度の確認は実機で行う**

### ログ・データの確認

```bash
# アプリのエラー・fault ログ（直近 10 分）
xcrun simctl spawn booted log show --predicate 'process == "SwingDuet" AND (messageType == error OR messageType == fault)' \
  --last 10m --style compact
# 保存データ（library.json と Videos/）
ls "$(xcrun simctl get_app_container booted com.ha2ne2.SwingDuet data)/Documents"
```

## 実機なしで検出ロジックを確認する（macOS CLI）

Vision はシミュレータでは動かないが Mac では動くので、アプリと同じ `SwingAnalyzer` を CLI にして実サンプルで検出結果を見られる:

```bash
swiftc -O -o build/analyze-swing SwingDuet/Services/{SwingAnalyzer,PoseTracker,SwingDetector}.swift \
  SwingDuet/Models/*.swift scripts/analyze-swing/main.swift
build/analyze-swing docs/data/*.mp4            # 候補ごとの A/T/I/F・採点・採用（★）・推定したフェーズ・人物範囲
build/analyze-swing --series docs/data/x.mp4   # 手の高さ（腰 0・首 1）と速度の系列も出す（閾値を調整するとき）
build/analyze-swing --joints docs/data/x.mp4   # 左右の手首・腰・首の生の位置と信頼度（手首が隠れる区間を調べるとき）
```

検出ロジックを変えたら必ずこれで実サンプルを確認する（[docs/ARCHITECTURE.md](../ARCHITECTURE.md) §5）。

## 単体テスト

Swift Testing（`SwingDuetTests/`）。検出ロジック（`SwingDetector`）、同期（`SyncEngine`）、動画の速さの推定（`SlowFactor`）、
保存（`ClipStore`：旧データの移行・上限・相手の解決）、ジョグホイールの回転（`JogRotation`）、ループ範囲の端（`LoopRange`）を固定している。アプリをホストにするのでシミュレータで走る:

```bash
xcodebuild test -project SwingDuet.xcodeproj -scheme SwingDuetTests \
  -destination 'platform=iOS Simulator,name=iPhone 16e' -derivedDataPath build -quiet
```

検出ロジックを変えたら、このテストと上の CLI（実サンプル）の両方で確認する。

## 実機へのインストール

iPhone をケーブルで Mac につなぎ（Mac のそばに無い iPhone には OTA：[.claude/skills/ota-install/SKILL.md](../../.claude/skills/ota-install/SKILL.md)）:

```bash
xcodebuild build -project SwingDuet.xcodeproj -scheme SwingDuet \
  -destination 'generic/platform=iOS' -allowProvisioningUpdates -derivedDataPath build
xcrun devicectl list devices    # connected / available (paired) であること。Identifier を次の <DEVICE_ID> に
xcrun devicectl device install app --device <DEVICE_ID> \
  build/Build/Products/Debug-iphoneos/SwingDuet.app
```

### 初めてつなぐ iPhone（プロファイル未登録）の場合

上のビルドは `Device "..." isn't registered in your developer account` で失敗する。
xcodebuild に端末の自動登録を許可し、対象端末を直接指定してビルドする（登録が済めば以降は上の手順でよい）:

```bash
xcodebuild -project SwingDuet.xcodeproj -scheme SwingDuet -showdestinations 2>/dev/null | grep 'platform:iOS,'
#   → { platform:iOS, arch:arm64, id:00008140-…, name:npiPhone } の id を使う
#     （devicectl の Identifier とは別物。xcodebuild には通らない）
xcodebuild build -project SwingDuet.xcodeproj -scheme SwingDuet \
  -destination 'platform=iOS,id=<XCODEBUILD_ID>' \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration -derivedDataPath build
```

- 事前に iPhone 側で「このコンピュータを信頼」と、設定 → プライバシーとセキュリティ → **デベロッパモード** を有効化しておく
- Xcode 派は `open SwingDuet.xcodeproj` で開き、実機を選んで ▶ でも同じ（Xcode は端末登録も自動で行う）
- 初回起動時に「信頼されていないデベロッパ」と出たら、iPhone の 設定 → 一般 → VPNとデバイス管理 で開発者を「信頼」する
- 署名は有料の Developer Program のチームなので、インストールしたアプリは**ビルドから約 1 年**動く（無料 Apple ID なら 7 日）。
  切れたら再ビルド + 再インストール
- Wi-Fi 経由は不安定なことがある（`unavailable` のまま）。**ケーブル接続が確実**
- 手順は DriveMemory の iOS 版と同じ。iPhone 15 / iPhone 16（iOS 26）へのインストールを確認済み（2026-09-08）

## 補足

- Bundle ID は `com.ha2ne2.SwingDuet`
- `build/`（DerivedData）と `xcuserdata/` は gitignore 済み

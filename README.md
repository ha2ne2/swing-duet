# SwingDuet — ゴルフスイング比較アプリ（MVP）

自分のスイングとお手本のスイングをフォトライブラリから読み込み、**インパクトを基準点に区間別（バックスイング / ダウンスイング / フォロー）で時間同期**して並べて比較する iOS アプリです。
動画はすべて端末内に保存され、外部サーバーには送信されません。

## クイックスタート: 実機で動かす

Xcode 26 以降 / iOS 17 以降。署名は自動（Team は pbxproj に設定済み）。iPhone をケーブルで Mac につなぎ:

```bash
xcodebuild build -project SwingDuet.xcodeproj -scheme SwingDuet \
  -destination 'generic/platform=iOS' -allowProvisioningUpdates -derivedDataPath build
xcrun devicectl list devices    # 表示された Identifier を次のコマンドの <DEVICE_ID> に
xcrun devicectl device install app --device <DEVICE_ID> \
  build/Build/Products/Debug-iphoneos/SwingDuet.app
```

- Xcode 派は `open SwingDuet.xcodeproj` で開き、実機を選んで ▶ でも同じ
- フォトライブラリの動画と Vision の姿勢推定を使うため、**動作確認は実機を推奨**
  （シミュレータでは姿勢推定が動かず、フェーズは仮の値になります）
- シミュレータでの起動・自動 E2E・実機インストールの注意点は [docs/guides/build-test.md](./docs/guides/build-test.md)

## 主な機能

- 🎞️ **入力** — ホームの「＋ スイングを追加」で写真ライブラリから 1 本選ぶと、そのスイングとお手本を並べたステージが開く。動画を選ぶ画面は「動画」（写真ライブラリの動画だけを撮影日順に。スロー撮影は原本のまま取り込む）と「お手本」の 2 タブ。人物が収まるように自動で拡大し、ピンチで拡大縮小・ドラッグで位置合わせ（保存される）
- 📓 **スイングの記録** — 取り込んだスイングは撮影日ごとに一覧に残る。★ を付けたものは「★ お気に入り」に固定され、それ以外は 60 本で流れる。削除は「元に戻す」で戻せる
- ⭐ **お手本** — ライブラリから右ペインに入れるときに名前を付けると登録され、次回は「お手本」タブで選ぶだけ（再解析なし）。★ お気に入りのスイングも同じ棚に並ぶので、自分のお気に入りを相手にできる
- 🔍 **自動検出** — 体に対する手の高さ（Vision の姿勢推定）からアドレス / トップ / インパクト / フィニッシュを検出。正面でも後方でも同じ仕組みで、素振りが混ざっていても振り切った本番を選び、候補を切り替え可能。手動修正付き
- ⏱️ **同期** — インパクト基準・区間別の速度倍率で 4 点を一致させる。自分基準 / お手本基準を切替
- ▶️ **再生** — 共通シークバー（区間色分け）、フェーズジャンプ、0.1〜1.0 倍速、ジョグホイールでコマ送り（回した分だけ進み、回し続けると 1 周ごとに加速。1 コマごとに振動）、ループ範囲（区間のプリセットと、シークバー両端のつまみでコマ単位に広げ縮め）。各動画の下の「フェーズ調整」で検出結果を直せる
- 💾 **保存** — 解析結果・手直し・位置合わせ・最後に比べた相手はスイングごとに自動で残る。保存ボタンは無い

MVP から除外: 線引き / 棒人間 / 動画書き出し / YouTube 連携（詳細は [docs/SPEC.md](./docs/SPEC.md)）

## 開発

- 進め方は SDD（AI が設計・実装 → 人間がレビュー）。タスク管理は [docs/ROADMAP.md](./docs/ROADMAP.md)、残課題は [docs/TODO.md](./docs/TODO.md)
- 検証用のサンプル動画は `docs/data/` に置く（gitignore 済み）

## ドキュメント

| ドキュメント                                             | 内容                                       |
| -------------------------------------------------------- | ------------------------------------------ |
| [AGENTS.md](./AGENTS.md)                                 | AI エージェント向けの開発指示書            |
| [docs/SPEC.md](./docs/SPEC.md)                           | 機能仕様・要件定義                         |
| [docs/ARCHITECTURE.md](./docs/ARCHITECTURE.md)           | 技術スタック・同期 / 検出の仕組み          |
| [docs/ROADMAP.md](./docs/ROADMAP.md)                     | 開発ロードマップ                           |
| [docs/guides/build-test.md](./docs/guides/build-test.md) | ビルド・シミュレータ・実機の手順           |

## ライセンス

未定

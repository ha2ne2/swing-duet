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

- 🎞️ **入力** — 画面は比較画面 1 枚。左右のペインの + からフォトライブラリの動画を選ぶ。右上の「＋ 新しいスイング」で両ペインを空に戻して最初から。人物が収まるように自動で拡大し、ピンチで拡大縮小・ドラッグで位置合わせ（保存される）
- ⭐ **お手本の登録** — お手本はライブラリから選ぶときに名前を付けると登録され、次回はピッカーで選ぶだけ（再解析なし）。フェーズの修正は登録元にも反映
- 🔍 **自動検出** — 手首の動き（Vision）からアドレス / トップ / インパクト / フィニッシュを検出。素振りが混ざっていても振り切った本番を選び、候補を切り替え可能。手動修正付き
- ⏱️ **同期** — インパクト基準・区間別の速度倍率で 4 点を一致させる。自分基準 / お手本基準を切替
- ▶️ **再生** — 共通シークバー（区間色分け）、フェーズジャンプ、0.1〜1.0 倍速、コマ送り（押しっぱなしで連続）、区間ループ。各動画の下の「フェーズ調整」で検出結果を直せる
- 💾 **履歴** — 両方の動画がそろった比較は自動で履歴に残り、開き直せる

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

---
name: ota-install
description: Mac に USB でも同じ LAN でもつながっていない iPhone（出先）に、ビルド済みの SwingDuet を入れる手順。署名済みの .app を IPA にして Mac から一時的な HTTPS で配り、iPhone の Safari から入れる（OTA インストール）。「出先だけど iPhone に入れて」「USB 無しでインストール」と言われたら使う。
---

# 出先の iPhone に入れる（OTA インストール）

Mac のそばにある iPhone には [docs/guides/build-test.md](../../../docs/guides/build-test.md) の `devicectl` が早い。
これは iPhone が Mac から見えない（`xcrun devicectl list devices` で unavailable）ときの手段。2026-09-12 に iPhone 15（iOS 26.6）で確認済み。
他の手段との比較（TestFlight など）は [docs/research/260912_1546](../../../docs/research/260912_1546-ota-install-away-from-mac.md)。

## 仕組みと制約

- 署名済みの `.app` を zip して IPA にし、Mac の 127.0.0.1 の小さなサーバー（`serve.py`）で配り、`cloudflared` の一時トンネル（アカウント不要）で HTTPS の URL を付ける。
  iPhone の Safari で `itms-services://` のリンクをタップすると iOS が manifest.plist と IPA を読んで入れる（Apple の Ad Hoc / 社内配布と同じ仕組み）
- **届くのは Mac でサーバーとトンネルが動いている間だけ。** 止めると URL は無効になる（URL は毎回変わる）
- 入るのは開発用プロファイルに UDID が入った iPhone だけ（一度 USB で入れた端末）。有料の Developer Program が前提。アプリアイコンは無くてよい
- 同じ bundle ID の上書きなので `Documents/`（library.json・動画）は残る
- 動いている間は URL を知る人なら誰でも届く。IPA 以外（`docs/data/` の動画など）は同じサーバーで配らない。入ったらすぐ止める
- 外部への入口を開く操作なので、始める前にユーザーの了解を得る。Mac 側にダイアログは出ない：再署名しない（キーチェーン）、127.0.0.1 だけに束ねる（ファイアウォール）、cloudflared は外向きの接続だけ

## 前提

- `brew install cloudflared`（初回のみ。パスワード不要）
- 実機向けにビルド済み（`xcodebuild build -destination 'generic/platform=iOS' -allowProvisioningUpdates -derivedDataPath build`。build-test.md）

## 手順

1. **IPA を作る**（署名済みの .app をそのまま zip）

   ```bash
   DIR=$(mktemp -d /tmp/ota.XXXXXX) && mkdir "$DIR/Payload" \
     && cp -R build/Build/Products/Debug-iphoneos/SwingDuet.app "$DIR/Payload/" \
     && (cd "$DIR" && zip -qry SwingDuet.ipa Payload && rm -rf Payload)
   ```

2. **サーバーとトンネルを起こす**（それぞれバックグラウンドで。止めるまで動き続ける。`caffeinate` で Mac を眠らせない）

   ```bash
   python3 .claude/skills/ota-install/serve.py "$DIR" 8080
   caffeinate -i cloudflared tunnel --url http://127.0.0.1:8080 --no-autoupdate
   ```

   cloudflared の出力に `https://<ランダム>.trycloudflare.com` が出る。

3. **manifest.plist と index.html を `$DIR` に書く**（下のテンプレの `<URL>` を置き換える。バージョンは `.app/Info.plist` の `CFBundleShortVersionString`）
4. **ユーザーに `<URL>/` を送る。** Safari で開いて「インストール」をタップ。「信頼されていないデベロッパ」なら 設定 → 一般 → VPN とデバイス管理 で信頼。
   外からの疎通確認はこちらで行わず、ユーザーの iPhone で確かめる（ローカルは `curl -sI http://127.0.0.1:8080/manifest.plist` が `text/xml` で 200 ならよい）
5. **入ったら両方を止める**（`TaskStop`。一時ディレクトリも消す）

## テンプレ

`manifest.plist`（`.plist` は `text/xml`、`.ipa` は `application/octet-stream` で配る。`serve.py` がそうしている）:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>items</key><array><dict>
    <key>assets</key><array><dict>
      <key>kind</key><string>software-package</string>
      <key>url</key><string><URL>/SwingDuet.ipa</string>
    </dict></array>
    <key>metadata</key><dict>
      <key>bundle-identifier</key><string>com.ha2ne2.SwingDuet</string>
      <key>bundle-version</key><string>1.0</string>
      <key>kind</key><string>software</string>
      <key>title</key><string>SwingDuet</string>
    </dict>
  </dict></array>
</dict></plist>
```

`index.html`（タップして入れるページ。見出しにコミットを入れると新旧を見分けられる）:

```html
<!doctype html><html lang="ja"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>SwingDuet インストール</title></head>
<body style="font-family:-apple-system;text-align:center;padding:48px 24px">
<h1>SwingDuet 1.0 (コミット)</h1>
<a href="itms-services://?action=download-manifest&amp;url=<URL>/manifest.plist"
   style="display:block;padding:18px;background:#0a84ff;color:#fff;border-radius:14px;text-decoration:none;font-size:18px">インストール</a>
<p>確認が出たら許可。同じアプリの上書きなので記録は残ります。</p>
</body></html>
```

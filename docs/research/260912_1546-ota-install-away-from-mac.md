# 出先の iPhone に、家の Mac でビルドしたものを入れる方法

- 日付：2026-09-12
- 種別：調査
- 前提：iPhone 15 は Mac と同じ LAN に無い（`devicectl list devices` で unavailable）。Mac には Homebrew があり、トンネル系のツール（tailscale / cloudflared / ngrok）は無い。
  Developer Program は有料（開発用プロファイル `iOS Team Provisioning Profile: *` の期限が 1 年。無料の Personal Team なら 7 日）。
  プロファイルには 3 台の UDID が入っていて iPhone 15 も含む。署名の証明書は `Apple Development` のみ（`Apple Distribution` は無い）。
  アプリアイコンの画像は未登録（`AppIcon.appiconset` は Contents.json のみ）

## 1. 結論

**できる。** 開発用署名（いま USB で入れているものと同じ）の .app を IPA に固め、HTTPS で配って iPhone の Safari から `itms-services://` で入れる（OTA インストール）。
Mac 側に外から届く HTTPS の口が要るので、Cloudflare の一時トンネル（`cloudflared`、アカウント不要）を使うのが最短。所要 10 分ほど。
同日に iPhone 15（iOS 26.6）で実施して入った。手順とスクリプトは [.claude/skills/ota-install/SKILL.md](../../.claude/skills/ota-install/SKILL.md) に整えた。

| 手段 | 使えるか | 備考 |
| --- | --- | --- |
| **開発用 IPA ＋ OTA（`itms-services`）** | ◎ | 新しい証明書・App Store Connect・アイコン不要。UDID が入った端末にだけ入る。HTTPS の口だけ要る（§2） |
| TestFlight | ○（準備が要る） | App Store Connect にアプリの登録、1024px のアイコン、Xcode のサインイン、`ITSAppUsesNonExemptEncryption` が要る。アップロード後の処理待ちが 10〜30 分。以後は最も楽 |
| Ad Hoc IPA ＋ OTA | ○ | 上と同じ配り方だが `Apple Distribution` 証明書と Ad Hoc プロファイルを新しく作る必要がある。開発用 IPA で足りるので不要 |
| `devicectl` / Xcode の無線接続 | × | Bonjour で見つける同一 LAN 限定。VPN 越しは mDNS が通らず不安定 |
| AltStore / Sideloadly 系 | × | 同じ Wi-Fi に Mac か PC が要る |

## 2. 開発用 IPA ＋ OTA の手順（案）

1. **IPA を作る**。ビルド済みの `build/Build/Products/Debug-iphoneos/SwingDuet.app` を `Payload/` に入れて zip し `SwingDuet.ipa` にする
   （`xcodebuild archive` → `-exportArchive`（method: development）でも同じものができる。zip の方が速い）
2. **manifest.plist を書く**。`items[0].assets[0]`（kind: software-package, url: IPA の HTTPS URL）と `metadata`（bundle-identifier `com.ha2ne2.SwingDuet`、bundle-version、kind software、title）。
   `.plist` は `text/xml`、`.ipa` は `application/octet-stream` で配る（Python の `http.server` は既定でこの型にならないので、型を指定した数行のサーバを書く）
   アイコンは要らない：manifest の `display-image` / `full-size-image` は任意で、無ければ iPhone にはいまと同じ既定のアイコンで入る。アイコンが必須なのは App Store Connect へのアップロード（TestFlight）だけ
3. **HTTPS で外に出す**。`brew install cloudflared` → `cloudflared tunnel --url http://localhost:8080` で `https://<ランダム>.trycloudflare.com` が出る（Cloudflare のアカウント不要。プロセスを止めれば消える）
4. **iPhone で開く**。`index.html` に `<a href="itms-services://?action=download-manifest&url=https://…/manifest.plist">` を置き、その URL を Safari で開いてタップ。
   同じ bundle ID なので上書きインストールになり、`Documents/`（library.json・動画）は残る。
   初回は「設定 → 一般 → VPN とデバイス管理」でデベロッパ App の信頼を求められることがある
5. 入ったらトンネルとサーバを止める

**注意**：トンネルが動いている間は誰でも URL に届く。URL はランダムで推測しにくく、IPA は UDID が入った 3 台にしか入らないが、用が済んだらすぐ止める。
`docs/data/` の動画など、アプリ以外のものを同じサーバから配らない。

## 3. TestFlight に乗り換えるなら

繰り返し出先で試すなら TestFlight の方が楽（Mac 側は `xcodebuild -exportArchive`（method: app-store-connect, destination: upload）1 回、iPhone 側は TestFlight アプリ）。
先に要るもの：

- App Store Connect でアプリの登録（bundle ID `com.ha2ne2.SwingDuet`。iPhone のブラウザからでもできる）
- 1024×1024 の App アイコン（無いとアップロードの検証で落ちる）
- Info.plist の `ITSAppUsesNonExemptEncryption = NO`（暗号化の質問を省く。`INFOPLIST_KEY_` で pbxproj に足せる）
- Xcode に Developer Program の Apple ID がサインインしていること（無ければ App Store Connect の API キー）

## 4. 決めてもらうこと

1. §2 を今やるか（Mac に `cloudflared` を Homebrew で入れる。トンネルは作業中だけ開く）
2. 今後も出先で試すなら §3 の TestFlight の準備（アイコンの用意を含む）を別タスクにするか

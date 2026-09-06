# E2E の並列実行とシミュレータ 2 台起動の調査

**作成日時**: 2026-09-06 18:11 JST
**対象**: E2E ハーネス（`.claude/skills/e2e-simulator/` の `make-harness.py` / `run.sh` / `FlowTests.swift`）と
`docs/guides/build-test.md` のシミュレータ手順
**目的**: 2 つのエージェントセッションが同時に E2E を回すと壊れる問題について、シミュレータを 2 台起動して分離できるか、
ほかに何を分ける必要があるかを明らかにする
**種別**: 調査（コード・設定は変更していない。実験で作ったシミュレータは削除済み）

---

## 1. 結論

- **シミュレータは 2 台同時に起動できる**（実測）。2 台目は `simctl create` → `boot` で 27 秒で使える状態になり、
  同じアプリを両方で同時に動かせた。メモリ 16 GB のこの Mac では 2 台目＋アプリで空きメモリが 43% → 31% に減った程度で、
  2 台までは現実的。3 台以上は厳しい
- ただし **2 台起動するだけでは競合は解消しない**。今のハーネスは「起動中のシミュレータ 1 台」「共有の `build/e2e-harness/`」
  「同じ作業ツリー」を前提にしており、競合する資源は 3 つある（§3）。

  | 資源 | 今の状態 | 競合すると |
  | ---- | -------- | ---------- |
  | シミュレータ端末 | `run.sh` は起動中の 1 台目を自動選択 | 相手の E2E の途中でアプリをアンインストールし、相手のテストランナーが落ちる（「Restarting after unexpected exit」「Executed 0 tests」） |
  | `build/e2e-harness/` | 1 か所固定（`out/`・`xcodebuild.log`・DerivedData・アプリソースのコピー） | `out/` を消し合う、同じ DerivedData に 2 つの xcodebuild、ログの上書き |
  | 作業ツリー（ソース） | 1 つの作業ディレクトリを 2 セッションが編集 | 相手の未コミット編集が `rsync` でハーネスに混ざり、何を検証しているのか分からなくなる |

- **推奨**: セッションごとに **git worktree** を切り（[AGENTS.md](../AGENTS.md) §4.3 の運用）、worktree ごとに
  **名前付きのシミュレータ端末**を持つ。worktree を分ければ `build/` 配下（ハーネス・DerivedData）は自動的に分かれるので、
  残る変更は「`run.sh` が `booted` ではなく自分の端末を使う」だけになる（§4）。
  worktree を切るまでの暫定は、`pgrep -f "xcodebuild tes[t]"` で相手の実行中を確認してから回す直列運用（SKILL.md に記載済み）

---

## 2. 実測

環境: macOS 26.5.2 / Apple M4 / 16 GB / Xcode 26.3 / iOS 26.2 ランタイムのみ。起動中の共用端末は iPhone 16e（`F45DC6F4-…`、data 3.1 GB）。

| 確認したこと | 結果 |
| ------------ | ---- |
| 2 台目の作成と起動 | `xcrun simctl create "SwingDuet-E2E-probe" "iPhone 16e" "iOS26.2"` → `boot` → `bootstatus -b` で **27 秒**。Simulator.app は起動済みのまま 2 台目のウィンドウも出る |
| `booted` の解決 | `simctl help`: 「複数が起動中なら **どれか 1 台を選ぶ**」。実測では `simctl getenv booted SIMULATOR_UDID` が 5 回とも**後から起動した 2 台目**を返した。一方 `run.sh` の `simctl list devices booted \| head -1` は**先頭の 1 台目**を返す。つまり同じ「起動中」でもコマンドによって別の端末を指す |
| 写真ライブラリ | 端末ごとに別。新しい端末には `simctl addmedia <UDID> docs/data/*.mp4` で入れ直す必要がある（成功） |
| 同じアプリの同時実行 | 1 台目で動作中のまま 2 台目にビルド済み `SwingDuet.app` を `install` / `launch` → プロセスが 2 つ、スクリーンショットも取れた |
| メモリ | 空き 43% → 31%（2 台目 + アプリで約 2 GB） |
| 起動中の端末の複製 | `simctl clone <起動中の UDID> ...` は **エラー**（`Unable to clone device in current state: Booted`）。複製するには元を `shutdown` する必要がある（shutdown 後の clone は未検証） |

---

## 3. 競合の内訳

### 3.1 シミュレータ端末（アプリ・保存データ・写真ライブラリ）

- `run.sh` は端末を引数で受け取れるが、省略時は「起動中の先頭」を使う。2 セッションとも省略すれば同じ端末になる
- 実行の冒頭で `simctl uninstall` し、テスト中はアプリを起動・終了・再起動する。同じ端末で相手が同じことをすれば、
  どちらのテストランナーも落ちる（2026-09-06 に実際に起きた症状）
- `docs/guides/build-test.md` の手順も `booted` を多用している。2 台以上起動した状態では、§2 のとおりどの端末に効くか分からない

### 3.2 `build/e2e-harness/`（ハーネス一式）

`make-harness.py` の出力先は `REPO/build/e2e-harness` に固定。`run.sh` は毎回

1. `rsync --delete` でアプリソースをコピー（相手が編集中のファイルもそのまま入る）
2. `rm -rf out/`（相手のスクリーンショット・操作ログが消える）
3. `xcodebuild test -derivedDataPath build/e2e-harness/build`（同じ DerivedData に 2 つの xcodebuild。ビルドの途中で相手が上書きする）
4. `xcodebuild.log` を上書き

を行うので、端末を分けても同じディレクトリを使う限り壊れる。

### 3.3 作業ツリー

2 セッションが同じ作業ディレクトリで別の変更を進めると、E2E は「両方の未コミット編集を混ぜたもの」を検証することになる。
これは E2E に限らず、ビルド（`build/` の DerivedData も共有）や `docs/` の編集でも同じ。
[AGENTS.md](../AGENTS.md) §4.3 は「atelier worktree を併設する場合は修正は起動時の作業ディレクトリ配下のみ」と定めているので、
セッションごとに worktree を切るのが本来の運用。

### 3.4 競合しないもの

- Simulator.app（1 プロセスで複数端末のウィンドウを持てる）
- XCUITest のランナーやポート（端末ごとに独立）
- `xcrun simctl` 自体（UDID を明示すれば端末単位で独立）

---

## 4. 選択肢

| 案 | 内容 | 長所 | 短所 |
| -- | ---- | ---- | ---- |
| A. 直列運用（暫定） | 実行前に `pgrep -f "xcodebuild tes[t]"` で相手の実行中を確認し、終わるまで待つ | 変更なし。SKILL.md に記載済み | 待ちが出る。確認を忘れると壊れる。ソースの混在（§3.3）は残る |
| B. 端末とハーネスをセッションごとに分ける | `run.sh` に端末名を渡す（無ければ `simctl create` + `boot` + `addmedia`）。`make-harness.py` に出力先の引数を足す | 同じ作業ツリーのままでも E2E は衝突しない | ソースの混在（§3.3）は残る。スクリプトの変更が要る |
| C. worktree をセッションごとに切る ＋ 端末を worktree ごとに固定 | AGENTS §4.3 の運用。`build/` が worktree ごとになるのでハーネスは自動で分離。端末名は worktree 名から決める（例 `SwingDuet-<worktree 名>`） | 3 つの資源すべてが分かれる。E2E 以外の競合も無くなる | worktree の作成・`docs/data/` の手動コピー・端末の初期化（addmedia）が要る。`run.sh` の端末選択の変更は必要 |
| D. Xcode の並列テスト（`-parallel-testing-enabled`） | 1 つの xcodebuild が端末を複製して並列化する | — | 1 セッション内の並列化であり、セッション間の競合には無関係 |

**推奨は C**（暫定として A）。B は C の部分集合なので、C に進むなら B を別に作る必要はない。

### 4.1 C を設計するときの要点

- `run.sh` の端末選択: `booted` を使わず、**名前で固定**する。無ければ作って起動し、`docs/data/*.mp4` と合成動画を `addmedia` する
  （初回だけ）。名前は worktree のディレクトリ名から決めると環境変数の設定が要らない
- `build-test.md` の `booted` は、2 台以上のときは UDID（または名前から引く）に読み替える注意を添える
- 端末の複製で写真ライブラリごと増やしたい場合は、元端末を `shutdown` してから `simctl clone`（shutdown 後の動作は未検証）。
  `addmedia` で入れ直す方が単純
- メモリの目安: 端末 1 台 + アプリで約 2 GB。この Mac では **2 セッションまで**
- 実装は「実装タスク」として、`run.sh` / `make-harness.py` / SKILL.md / build-test.md を同時に更新する（[AGENTS.md](../AGENTS.md) §2.2）

---

## 参考

- `xcrun simctl help`（`booted` の定義: 「複数が起動中なら simctl がどれか 1 台を選ぶ」）
- [Allowing parallel iOS UI tests runs in CI（Igor Kulman）](https://blog.kulman.sk/parallel-ui-test-runs/) — ジョブごとに `simctl create` で端末を作り、終わったら `delete` する

import XCTest

/// SwingDuet の主要フロー（ホーム → ＋ → 動画を選ぶ → ステージ → お手本を入れて比較 → 一覧から開き直し）をシミュレータで通しで操作する E2E テスト。
/// make-harness.py が生成する別プロジェクト（build/e2e-harness/）から実行する。使い方は SKILL.md。
///
/// 環境変数（run.sh が TEST_RUNNER_ 接頭辞で渡す）:
/// - E2E_OUT_DIR:     スクリーンショット・操作ログ・要素ダンプの出力先
/// - E2E_MINE_MATCH / E2E_MODEL_MATCH: 「動画」タブのセルのラベル（例 "9/5"）に含まれる文字列で選ぶ。指定があれば index より優先
/// - E2E_MINE_INDEX / E2E_MODEL_INDEX: セル番号で選ぶ（撮影日時の新しい順。既定 1 / 0）
final class FlowTests: XCTestCase {
    private static let env = ProcessInfo.processInfo.environment
    private static let outDir = URL(fileURLWithPath: env["E2E_OUT_DIR"] ?? NSTemporaryDirectory() + "swingduet-e2e")
    private let mineIndex = Int(env["E2E_MINE_INDEX"] ?? "") ?? 1
    private let modelIndex = Int(env["E2E_MODEL_INDEX"] ?? "") ?? 0
    private let mineMatch = env["E2E_MINE_MATCH"].flatMap { $0.isEmpty ? nil : $0 }
    private let modelMatch = env["E2E_MODEL_MATCH"].flatMap { $0.isEmpty ? nil : $0 }

    private var app: XCUIApplication!
    private var step = 0

    override func setUpWithError() throws {
        continueAfterFailure = true
        try? FileManager.default.createDirectory(at: Self.outDir, withIntermediateDirectories: true)
        app = XCUIApplication()
    }

    // MARK: - 記録用ヘルパー

    private func log(_ s: String) {
        NSLog("UITEST: \(s)")
        let url = Self.outDir.appendingPathComponent("uitest_trace.log")
        let line = ("[\(name)] " + s + "\n").data(using: .utf8)!
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(line); h.closeFile()
        } else {
            try? line.write(to: url)
        }
    }

    /// テストメソッド名から "test" を除いた短い名前（スクリーンショットのファイル名に使う）
    private var testTag: String {
        let method = name.split(separator: " ").last.map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "]")) } ?? name
        return method.hasPrefix("test") ? String(method.dropFirst(4)) : method
    }

    private func shot(_ name: String) {
        step += 1
        let file = String(format: "%@_%02d_%@.png", testTag, step, name)
        do {
            try XCUIScreen.main.screenshot().pngRepresentation.write(to: Self.outDir.appendingPathComponent(file))
            log("SHOT \(file)")
        } catch {
            log("SHOT FAILED \(file): \(error)")
        }
    }

    private func dump(_ name: String) {
        try? app.debugDescription.write(to: Self.outDir.appendingPathComponent("\(name).txt"), atomically: true, encoding: .utf8)
        log("DUMP \(name).txt")
    }

    /// 画面上の静的テキストをすべて集める。画面更新中に要素が消えても失敗しないよう、存在確認しながら取得しリトライする
    private func texts() -> [String] {
        for _ in 0..<3 {
            var out: [String] = []
            var ok = true
            for e in app.staticTexts.allElementsBoundByIndex {
                if e.exists { out.append(e.label) } else { ok = false; break }
            }
            if ok { return out }
            usleep(400_000)
        }
        return ["<texts unstable>"]
    }

    private func pauseButton() -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'pause' OR label CONTAINS '一時停止'")).firstMatch
    }

    /// ループ範囲のメニュー（↻）
    private func loopMenuButton() -> XCUIElement {
        app.buttons.matching(NSPredicate(
            format: "label CONTAINS 'ループ範囲' OR label CONTAINS[c] 'repeat' OR label CONTAINS 'リピート' OR label CONTAINS '繰り返し'")).firstMatch
    }

    /// 開いているループ範囲のメニューから項目を選ぶ（Menu の項目は buttons か menuItems のどちらかで見える）
    @discardableResult
    private func pickLoopItem(_ label: String) -> Bool {
        tapIfExists(app.buttons[label], "loop=\(label)", timeout: 3) || tapIfExists(app.menuItems[label], "loop=\(label) (menuItem)", timeout: 2)
    }

    /// ホームの一覧の行（スイング）。識別子は "swing.<UUID>"
    private var swingRows: XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'swing.'"))
    }

    @discardableResult
    private func tapIfExists(_ el: XCUIElement, _ what: String, timeout: TimeInterval = 5) -> Bool {
        if el.waitForExistence(timeout: timeout) {
            el.tap()
            log("TAP \(what)")
            return true
        }
        log("MISSING \(what)")
        return false
    }

    /// シートが閉じ終わるまで待つ（閉じるアニメーション中のタップは吸われる）
    private func waitForSheetToClose(_ title: String) {
        let bar = app.navigationBars[title]
        _ = XCTWaiter().wait(for: [expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: bar)], timeout: 5)
        usleep(300_000)
    }

    // MARK: - 画面の操作

    /// 「動画」タブのグリッドからセルを選び、プレビューの「使う」まで。match があればラベルに含む最初のセル、無ければ index 番目
    private func pickLibraryVideo(what: String, index: Int, match: String?) {
        let cells = app.buttons.matching(identifier: "library.cell")
        // 写真の権限ダイアログが出たら人が押す（iOS 26 のシミュレータでは別プロセスで、XCTest からは触れない。docs/TODO.md G）。その猶予を含めて待つ
        guard cells.firstMatch.waitForExistence(timeout: 45) else {
            dump("library_fail_\(what)")
            shot("library_fail")
            XCTFail("library cells not found for \(what); texts=\(texts())")
            return
        }
        let labels = cells.allElementsBoundByIndex.map { $0.label }
        log("library: \(labels.count) cells: \(labels)")
        shot("library")
        var chosen = min(index, labels.count - 1)
        if let match {
            guard let found = labels.firstIndex(where: { $0.contains(match) }) else {
                XCTFail("library: no cell matches '\(match)' for \(what): \(labels)")
                return
            }
            chosen = found
        }
        cells.element(boundBy: chosen).tap()
        log("TAP cell '\(labels[chosen])' (\(what))")
        let use = app.buttons["preview.use"]
        XCTAssertTrue(use.waitForExistence(timeout: 10), "preview did not appear for \(what); texts=\(texts())")
        sleep(1)
        shot("preview")
        use.tap()
        log("TAP use (\(what))")
    }

    /// ステージでペインの「動画を選ぶ」を開く。右が空なら ⊕ を、そうでなければ右上の「替える」を押す
    private func openPicker(side: String) {
        if side == "model" {
            let add = app.buttons["slot.model.add"]
            if add.waitForExistence(timeout: 3) {
                add.tap()
                log("TAP slot.model.add")
                return
            }
        }
        XCTAssertTrue(tapIfExists(app.buttons["pane.\(side).swap"], "swap (\(side))", timeout: 5))
    }

    /// ペインに入っているクリップの表示名（「替える」ボタンの value。画面には出ない）。無ければ空文字
    private func paneTitle(side: String) -> String {
        app.buttons["pane.\(side).swap"].value as? String ?? ""
    }

    /// そのペインの解析が終わるまで待つ（解析中の表示が無ければすぐ返る）
    private func waitForAnalysis(side: String) {
        let analyzing = app.otherElements["slot.\(side).analyzing"]
        if analyzing.waitForExistence(timeout: 5) {
            shot("\(side)_analyzing")
            let done = XCTWaiter().wait(for: [expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: analyzing)], timeout: 240)
            XCTAssertEqual(done, .completed, "\(side) analysis did not finish")
        }
    }

    /// 比較（基準切替のセグメントが出る）になるまで待つ
    @discardableResult
    private func waitForComparison() -> Bool {
        let appeared = app.buttons["自分基準"].waitForExistence(timeout: 240)
        sleep(2)   // 初期シークが落ち着くのを待つ
        shot("comparison")
        dump("comparison")
        log("comparison appeared: \(appeared) texts=\(texts())")
        XCTAssertTrue(appeared, "comparison did not appear; texts=\(texts())")
        return appeared
    }

    /// ホームの ＋ → 「動画」タブ → プレビュー → 使う → ステージ（左が解析中）。解析が終わるまで待つ
    private func addSwingFromHome() {
        XCTAssertTrue(tapIfExists(app.buttons["list.addSwing"], "add swing", timeout: 10))
        XCTAssertTrue(app.navigationBars["動画を選ぶ"].waitForExistence(timeout: 5), "picker did not open (home)")
        shot("picker_home"); dump("picker_home")
        pickLibraryVideo(what: "自分", index: mineIndex, match: mineMatch)
        waitForSheetToClose("動画を選ぶ")
        waitForAnalysis(side: "mine")
        shot("swing_ready")
    }

    /// ステージの右に、ライブラリから新しいお手本（名前付き）を入れて比較になるまで。
    /// 右の＋は「お手本」タブで開くので、「動画」タブへ切り替えてから選ぶ
    /// - name: 付ける名前（nil なら空のまま確定し、日時の名前が付く）
    private func addModelOnStage(name: String?) -> Bool {
        openPicker(side: "model")
        XCTAssertTrue(app.navigationBars["動画を選ぶ"].waitForExistence(timeout: 5), "picker did not open (model)")
        shot("picker_model"); dump("picker_model")
        XCTAssertTrue(tapIfExists(app.segmentedControls.buttons["動画"], "tab=動画", timeout: 3))
        pickLibraryVideo(what: "お手本", index: modelIndex, match: modelMatch)
        let field = app.textFields["modelName"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "name step did not appear; texts=\(texts())")
        if let name {
            field.tap()
            field.typeText(name)
            log("typed model name: \(field.value ?? "nil")")
        }
        shot("name_step")
        XCTAssertTrue(tapIfExists(app.buttons["お手本に追加"], "confirm name", timeout: 3))
        waitForSheetToClose("動画を選ぶ")
        waitForAnalysis(side: "model")
        return waitForComparison()
    }

    /// ステージから一覧（ホーム）へ戻る
    private func goHome() {
        let back = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(tapIfExists(back, "back to home", timeout: 5))
        XCTAssertTrue(app.navigationBars["スイング"].waitForExistence(timeout: 5), "home did not appear")
    }

    /// 一覧の最初の行をタップし、比較が開くまで
    @discardableResult
    private func openFirstSwing() -> Bool {
        let row = swingRows.firstMatch
        let listed = row.waitForExistence(timeout: 10)
        log("home row visible: \(listed) rows=\(swingRows.count) texts=\(texts())")
        shot("home"); dump("home")
        XCTAssertTrue(listed, "home has no row")
        guard listed else { return false }
        row.tap()
        return waitForComparison()
    }

    // MARK: - テスト本体

    /// 起動（空のホーム）→ スイングを追加 → 右にお手本を入れて比較 → 再生操作一式 → フェーズ調整 → 一覧から開き直し → 再起動で復元
    func testFullFlow() throws {
        app.launch()
        log("empty home: \(app.staticTexts["スイングはまだありません"].waitForExistence(timeout: 10))")
        shot("launch"); dump("01_home")
        addSwingFromHome()

        // まだお手本が無いので右は ⊕
        XCTAssertTrue(app.buttons["slot.model.add"].waitForExistence(timeout: 10), "right pane should be empty; texts=\(texts())")
        guard addModelOnStage(name: nil) else { return }
        log("buttons: \(app.buttons.allElementsBoundByIndex.map { "\($0.label)|\($0.identifier)" })")

        // 開いた直後は自動で再生が始まる（始まっていなければ再生ボタンを押す）→ 再生中に基準とループ範囲を変える
        // （再生中でも操作が効き、再生が止まらないこと）→ 停止。進みはスクリーンショットの再生ヘッドで確認する
        let play = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'play' OR label CONTAINS '再生'")).firstMatch
        let loop = loopMenuButton()
        let autoPlaying = pauseButton().waitForExistence(timeout: 3)
        log("auto-play: \(autoPlaying)")
        if autoPlaying || tapIfExists(play, "play") {
            sleep(1)
            shot("playing")

            let modelRef = app.buttons["お手本基準"]
            if tapIfExists(modelRef, "reference=model (playing)", timeout: 3) {
                usleep(500_000)
                log("reference=model while playing: selected=\(modelRef.isSelected) stillPlaying=\(pauseButton().exists)")
                XCTAssertTrue(modelRef.isSelected, "再生中に基準を切り替えられない")
                XCTAssertTrue(pauseButton().exists, "基準切替で再生が止まった")
                shot("reference_model_playing")
            }

            if tapIfExists(loop, "loop menu (playing)", timeout: 3) {
                shot("loop_menu_playing"); dump("05_loop_menu_playing")
                XCTAssertTrue(pickLoopItem("フォローのみ"), "再生中にループ範囲のメニュー項目を選べない")
                sleep(1)
                log("loop=follow while playing: stillPlaying=\(pauseButton().exists)")
                XCTAssertTrue(pauseButton().exists, "ループ範囲の変更で再生が止まった")
                shot("playing_follow_loop")
            }
            tapIfExists(pauseButton(), "pause")
        }

        // フェーズジャンプ
        for phase in ["トップ", "インパクト", "アドレス"] {
            tapIfExists(app.buttons[phase], "jump \(phase)", timeout: 3)
            usleep(500_000)
            if phase == "インパクト" { shot("jump_impact") }
        }

        // コマ送り
        let forward = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'forward'")).firstMatch
        let backward = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'backward'")).firstMatch
        for _ in 0..<3 { tapIfExists(forward, "step +1", timeout: 3); usleep(300_000) }
        tapIfExists(backward, "step -1", timeout: 3); usleep(300_000)
        shot("after_steps")

        // 基準切り替え（停止中）
        tapIfExists(app.buttons["自分基準"], "reference=mine", timeout: 3)
        usleep(500_000); shot("reference_mine")

        // 再生速度（表示をタップすると 0.1 / 0.2 / 0.3 / 0.5 / 1.0 を巡回する）
        let speed = app.buttons["再生速度"]
        if speed.waitForExistence(timeout: 3) {
            let before = speed.value as? String ?? ""
            speed.tap()
            usleep(300_000)
            let after = speed.value as? String ?? ""
            log("speed tap: \(before) -> \(after)")
            XCTAssertNotEqual(before, after, "速度表示をタップしても速度が変わらない")
        }

        // ループメニュー（停止中）→ ダウンスイングのみ → 区間ループ再生
        if tapIfExists(loop, "loop menu", timeout: 3) {
            shot("loop_menu"); dump("05_loop_menu")
            pickLoopItem("ダウンスイングのみ")
        }
        if tapIfExists(play, "play (segment loop)", timeout: 3) {
            sleep(3); shot("playing_loop")
            tapIfExists(pauseButton(), "pause", timeout: 3)
        }

        // フェーズ調整シート（自分ペイン下端の「フェーズ調整」をタップして開き、保存で閉じる）
        if tapIfExists(app.buttons["pane.mine.editPhases"], "edit phases (mine)", timeout: 3) {
            let title = app.navigationBars.matching(NSPredicate(format: "identifier CONTAINS 'フェーズ調整'")).firstMatch
            log("phase edit appeared: \(title.waitForExistence(timeout: 10)) texts=\(texts())")
            shot("phase_edit"); dump("06_phase_edit")
            tapIfExists(app.buttons["+1コマ"], "phase +1 frame", timeout: 3)
            tapIfExists(app.buttons["保存"], "save phase edit", timeout: 3)
        }
        usleep(500_000)
        shot("comparison_end")

        // ★ お気に入り（ステージのツールバー）
        if tapIfExists(app.buttons["stage.favorite"], "favorite on", timeout: 3) {
            usleep(500_000)
            log("favorite value: \(app.buttons["stage.favorite"].value ?? "nil")")
            XCTAssertEqual(app.buttons["stage.favorite"].value as? String, "オン", "★ が付かない")
        }

        // 一覧に戻って開き直す（★ お気に入りの節に並ぶ）
        goHome()
        XCTAssertTrue(app.staticTexts["★ お気に入り"].waitForExistence(timeout: 5), "★ お気に入りの節が無い; texts=\(texts())")
        XCTAssertTrue(openFirstSwing())

        // 再起動 → ホームに行が残っている → 開き直す
        app.terminate(); app.launch()
        XCTAssertTrue(app.navigationBars["スイング"].waitForExistence(timeout: 10), "home should appear after relaunch")
        shot("relaunch")
        XCTAssertTrue(openFirstSwing())
        sleep(1); shot("reopened")
    }

    /// ライブラリから選んだお手本に名前を付けると「お手本」タブに入り、次はカードを選ぶだけで（解析なしで）入れ替わること。
    /// カードの「…」で名前を変えるとペインのラベルにも反映されること
    func testModelLibrary() throws {
        let name = "McIlroy iron"
        app.launch()
        addSwingFromHome()
        guard addModelOnStage(name: name) else { return }
        XCTAssertEqual(paneTitle(side: "model"), name, "registered name not shown on pane; texts=\(texts())")
        shot("registered")

        // 右ラベル → 「お手本」タブで開く → カードを選ぶ（再解析なし）
        openPicker(side: "model")
        XCTAssertTrue(app.navigationBars["動画を選ぶ"].waitForExistence(timeout: 5), "picker did not open for reuse")
        shot("shelf"); dump("08_shelf")
        XCTAssertTrue(tapIfExists(app.buttons[name], "card '\(name)'", timeout: 5))
        waitForSheetToClose("動画を選ぶ")
        XCTAssertFalse(app.otherElements["slot.model.analyzing"].exists, "registered model should not be analyzed again")
        XCTAssertTrue(waitForComparison())
        XCTAssertEqual(paneTitle(side: "model"), name, "library model name not shown on pane")
        shot("reused")

        // 一覧は 1 本のまま（右を入れ替えても行は増えない）
        goHome()
        XCTAssertTrue(swingRows.firstMatch.waitForExistence(timeout: 10))
        log("home rows: \(swingRows.count)")
        XCTAssertEqual(swingRows.count, 1, "one swing expected on home")
        shot("home_one"); dump("08_home")
        XCTAssertTrue(openFirstSwing())

        // カードの「…」→ 名前を変更
        openPicker(side: "model")
        XCTAssertTrue(app.navigationBars["動画を選ぶ"].waitForExistence(timeout: 5), "picker did not open for rename")
        XCTAssertTrue(tapIfExists(app.buttons["\(name) のメニュー"], "card menu", timeout: 5))
        XCTAssertTrue(tapIfExists(app.buttons["名前を変更"], "rename (menu)", timeout: 5))
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "rename alert not shown")
        field.tap()
        field.typeText(" v2")
        XCTAssertTrue(tapIfExists(app.alerts.buttons["保存"], "save rename", timeout: 3))
        XCTAssertTrue(app.buttons["\(name) v2"].waitForExistence(timeout: 5), "renamed card not shown")
        shot("renamed")
        tapIfExists(app.buttons["閉じる"], "close picker", timeout: 3)
        waitForSheetToClose("動画を選ぶ")
        XCTAssertEqual(paneTitle(side: "model"), "\(name) v2", "pane label did not follow the rename")
    }

    /// 保存済みのスイング（E2E_KEEP_DATA=1 で残したもの。お手本側に candidates を入れておく）を開き、
    /// フェーズ調整画面でスイング候補を切り替えられること。シミュレータでは Vision が動かないので候補は library.json に直接入れる
    func testPhaseEditCandidates() throws {
        app.launch()
        XCTAssertTrue(swingRows.firstMatch.waitForExistence(timeout: 10), "保存済みのスイングがない（先に testFullFlow を回し、library.json に candidates を入れる）")
        XCTAssertTrue(openFirstSwing())
        sleep(1)
        log("comparison texts: \(texts())")

        XCTAssertTrue(tapIfExists(app.buttons["pane.model.editPhases"], "edit phases (model)"))
        let title = app.navigationBars.matching(NSPredicate(format: "identifier CONTAINS 'フェーズ調整'")).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        sleep(1)
        shot("phase_edit_candidates")
        dump("phase_edit_candidates")
        let candidates = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'candidate.'"))
        log("candidate buttons: \(candidates.allElementsBoundByIndex.map { $0.label })")
        XCTAssertGreaterThan(candidates.count, 1, "候補ボタンが表示されていない")

        func impactText() -> String {
            app.staticTexts.matching(NSPredicate(format: "label ENDSWITH '秒'")).firstMatch.label
        }
        let before = impactText()
        tapIfExists(app.buttons["candidate.0"], "candidate 1", timeout: 3)
        usleep(500_000)
        let after = impactText()
        log("impact time before=\(before) after=\(after)")
        XCTAssertNotEqual(before, after, "候補を切り替えても時刻が変わらない")
        shot("phase_edit_candidate1")
        // 保存せずに閉じる（自動検出の採用結果をテストで上書きしない。保存の経路は testFullFlow で確認している）
        tapIfExists(app.buttons["キャンセル"], "cancel", timeout: 3)
        usleep(500_000)
        log("after cancel: \(texts())")
        shot("after_candidate_cancel")
    }

    /// ピンチで拡大・縮小、ドラッグで移動したペインの状態が、一覧から開き直しても、再起動しても残ること
    func testZoomPanPersistence() throws {
        app.launch()
        addSwingFromHome()
        guard addModelOnStage(name: nil) else { return }

        let mine = app.otherElements["pane.mine"]
        let model = app.otherElements["pane.model"]
        XCTAssertTrue(mine.waitForExistence(timeout: 10), "pane.mine not found")
        XCTAssertTrue(model.waitForExistence(timeout: 5), "pane.model not found")
        log("before: mine=\(mine.value ?? "nil") model=\(model.value ?? "nil") mineFrame=\(mine.frame)")

        mine.pinch(withScale: 2.0, velocity: 1.0)                       // 自分: 拡大
        usleep(700_000)
        log("mine after pinch-out: \(mine.value ?? "nil")")
        let from = mine.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let to = mine.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.3))
        from.press(forDuration: 0.1, thenDragTo: to)                    // 自分: 右上へ移動
        usleep(700_000)
        log("mine after drag: \(mine.value ?? "nil")")
        model.pinch(withScale: 0.7, velocity: -0.5)                     // お手本: 縮小
        usleep(700_000)
        log("model after pinch-in: \(model.value ?? "nil")")
        shot("zoom_pan")

        let mineState = mine.value as? String ?? ""
        let modelState = model.value as? String ?? ""
        XCTAssertFalse(mineState.hasPrefix("x1.00"), "mine scale unchanged: \(mineState)")
        XCTAssertFalse(mineState.hasSuffix("(0, 0)"), "mine offset unchanged: \(mineState)")
        XCTAssertFalse(modelState.hasPrefix("x1.00"), "model scale unchanged: \(modelState)")

        // 一覧から開き直す
        goHome()
        XCTAssertTrue(openFirstSwing())
        XCTAssertTrue(mine.waitForExistence(timeout: 15))
        sleep(1)
        log("after reopen: mine=\(mine.value ?? "nil") model=\(model.value ?? "nil")")
        XCTAssertEqual(mine.value as? String, mineState, "mine state lost after reopen")
        XCTAssertEqual(model.value as? String, modelState, "model state lost after reopen")
        shot("zoom_pan_reopened")

        // 再起動 → 一覧から開き直す
        app.terminate(); app.launch()
        XCTAssertTrue(openFirstSwing())
        XCTAssertTrue(mine.waitForExistence(timeout: 15))
        sleep(1)
        log("after relaunch: mine=\(mine.value ?? "nil") model=\(model.value ?? "nil")")
        XCTAssertEqual(mine.value as? String, mineState, "mine state lost after relaunch")
        XCTAssertEqual(model.value as? String, modelState, "model state lost after relaunch")
        shot("zoom_pan_relaunched")
    }

    /// ループ範囲のつまみ：区間を選ぶとつまみが区間の両端に来て、ドラッグで端がコマ単位に動き、離しても位置が保たれること。
    /// つまみは `accessibilityValue` にフェーズからのコマ数（「トップ」「トップ −3 コマ」）を持つ
    func testLoopTrimHandles() throws {
        app.launch()
        addSwingFromHome()
        guard addModelOnStage(name: nil) else { return }
        tapIfExists(pauseButton(), "pause", timeout: 3)

        XCTAssertTrue(tapIfExists(loopMenuButton(), "loop menu", timeout: 5))
        pickLoopItem("ダウンスイングのみ")
        sleep(1)
        shot("loop_downswing"); dump("09_loop_downswing")

        let start = app.descendants(matching: .any)["seekBar.loopStart"]
        let end = app.descendants(matching: .any)["seekBar.loopEnd"]
        XCTAssertTrue(start.waitForExistence(timeout: 5), "start handle not found; texts=\(texts())")
        XCTAssertTrue(end.waitForExistence(timeout: 5), "end handle not found")
        log("handles before: start=\(start.value ?? "nil") \(start.frame) end=\(end.value ?? "nil") \(end.frame)")

        // 開始のつまみを左へ、終了のつまみを右へ 40pt ずつ
        for (handle, dx, what) in [(start, -40.0, "start"), (end, 40.0, "end")] {
            let from = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            from.press(forDuration: 0.3, thenDragTo: from.withOffset(CGVector(dx: dx, dy: 0)))
            usleep(500_000)
            log("DRAG \(what) handle \(dx)pt: start=\(start.value ?? "nil") end=\(end.value ?? "nil")")
            shot("after_drag_\(what)")
        }
        XCTAssertNotEqual(start.value as? String, "トップ", "開始のつまみが動いていない")
        XCTAssertNotEqual(end.value as? String, "インパクト", "終了のつまみが動いていない")
    }
}

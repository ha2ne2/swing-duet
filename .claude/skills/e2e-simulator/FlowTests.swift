import XCTest

/// SwingDuet の主要フロー（空のステージ → 動画 2 本 → 比較 → 履歴）をシミュレータで通しで操作する E2E テスト。
/// make-harness.py が生成する別プロジェクト（build/e2e-harness/）から実行する。使い方は SKILL.md。
///
/// 環境変数（run.sh が TEST_RUNNER_ 接頭辞で渡す）:
/// - E2E_OUT_DIR:     スクリーンショット・操作ログ・要素ダンプの出力先
/// - E2E_MINE_MATCH / E2E_MODEL_MATCH: ピッカーのセルのラベル（例 "9月05日"）に含まれる文字列で選ぶ。指定があれば index より優先
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

    private var projectRow: XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '比較 '")).firstMatch
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

    /// PhotosPicker を開いて動画セルをタップする。match があればラベルに含む最初のセル、無ければ index 番目。
    /// セルは表示アニメーション中 hittable にならないので、待っても駄目なら座標タップで押す
    private func pickVideo(via opener: XCUIElement, what: String, index: Int, match: String?) {
        XCTAssertTrue(tapIfExists(opener, "open photos (\(what))"))
        let pred = NSPredicate(format: "label BEGINSWITH[c] 'video' OR label CONTAINS 'ビデオ' OR label CONTAINS '動画'")
        let cells = app.images.matching(pred)
        // PhotosPicker は別プロセスの UI で、シート表示直後のタップを取りこぼすことがあるので 1 回だけ押し直す
        if !cells.firstMatch.waitForExistence(timeout: 8) {
            log("picker did not open for \(what); retrying tap")
            tapIfExists(opener, "open photos (\(what), retry)", timeout: 3)
        }
        guard cells.firstMatch.waitForExistence(timeout: 15) else {
            dump("picker_fail_\(index)")
            shot("picker_fail")
            XCTFail("picker cells not found for \(what)")
            return
        }
        let n = cells.count
        let labels = cells.allElementsBoundByIndex.map { $0.label }
        log("picker: \(n) video cells: \(labels)")
        shot("picker")
        var chosen = min(index, n - 1)
        if let match {
            guard let found = labels.firstIndex(where: { $0.contains(match) }) else {
                XCTFail("picker: no cell matches '\(match)' for \(what): \(labels)")
                return
            }
            chosen = found
        }
        let cell = cells.element(boundBy: chosen)
        let hit = XCTWaiter().wait(for: [expectation(for: NSPredicate(format: "isHittable == true"), evaluatedWith: cell)], timeout: 10)
        log("cell '\(cell.label)' hittable=\(hit == .completed) frame=\(cell.frame)")
        if hit == .completed {
            cell.tap()
        } else {
            cell.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
    }

    /// ピッカーの「ライブラリから選ぶ」ボタン
    private var libraryButton: XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'ライブラリから選ぶ'")).firstMatch
    }

    /// ペインのピッカーを開く。空なら + を、比較中ならラベル（選び直す）を押す
    private func openPicker(side: String) {
        let add = app.buttons["slot.\(side).add"]
        if add.waitForExistence(timeout: 3) {
            add.tap()
            log("TAP slot.\(side).add")
            return
        }
        let relabel = app.buttons[side == "mine" ? "自分の動画を選び直す" : "お手本の動画を選び直す"]
        XCTAssertTrue(tapIfExists(relabel, "pane label (\(side))", timeout: 5))
    }

    /// シートが閉じ終わるまで待つ（閉じるアニメーション中のタップは吸われる）
    private func waitForSheetToClose(_ title: String) {
        let bar = app.navigationBars[title]
        _ = XCTWaiter().wait(for: [expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: bar)], timeout: 5)
        usleep(300_000)
    }

    /// ペインのラベルに添えられた名前（登録済みお手本の名前）。無ければ空文字
    private func paneTitle(side: String) -> String {
        app.buttons[side == "mine" ? "自分の動画を選び直す" : "お手本の動画を選び直す"].value as? String ?? ""
    }

    /// 右ペイン（お手本）→ 左ペイン（自分）の順に動画を入れ、比較になるまで。比較が出たら true。
    /// - modelName: ライブラリから選んだお手本に付ける名前（nil なら空のまま確定し、日時の名前が付く）
    /// - registeredModel: ライブラリではなく、登録済みのこの名前のお手本を選ぶ
    /// - pickMine: false なら左ペインは触らない（比較中に右だけ入れ替えるとき）
    private func createComparison(modelName: String? = nil, registeredModel: String? = nil, pickMine: Bool = true) -> Bool {
        openPicker(side: "model")
        XCTAssertTrue(app.navigationBars["お手本を選ぶ"].waitForExistence(timeout: 5), "picker did not open (model)")
        shot("picker_model"); dump("02_picker_model")
        if let registeredModel {
            XCTAssertTrue(tapIfExists(app.buttons[registeredModel], "registered '\(registeredModel)'", timeout: 5))
        } else {
            pickVideo(via: libraryButton, what: "お手本", index: modelIndex, match: modelMatch)
            let field = app.textFields["modelName"]
            XCTAssertTrue(field.waitForExistence(timeout: 30), "name step did not appear; texts=\(texts())")
            if let modelName {
                field.tap()
                field.typeText(modelName)
                log("typed model name: \(field.value ?? "nil")")
            }
            shot("name_step")
            XCTAssertTrue(tapIfExists(app.buttons["この名前で使う"], "confirm name", timeout: 3))
        }
        // 右ペインの解析が終わるまで（登録済みなら解析は無い）
        let analyzing = app.otherElements["slot.model.analyzing"]
        if analyzing.waitForExistence(timeout: 5) {
            shot("model_analyzing")
            let done = XCTWaiter().wait(for: [expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: analyzing)], timeout: 240)
            XCTAssertEqual(done, .completed, "model analysis did not finish")
        }
        shot("model_ready")

        if pickMine {
            openPicker(side: "mine")
            XCTAssertTrue(app.navigationBars["自分のスイングを選ぶ"].waitForExistence(timeout: 5), "picker did not open (mine)")
            pickVideo(via: libraryButton, what: "自分", index: mineIndex, match: mineMatch)
        }

        // 両方そろうと比較になる（基準切替のセグメントが出たら遷移完了とみなす）
        let appeared = app.buttons["自分基準"].waitForExistence(timeout: 240)
        sleep(2)   // 初期シークが落ち着くのを待つ
        shot("comparison")
        dump("04_comparison")
        log("comparison appeared: \(appeared) texts=\(texts())")
        XCTAssertTrue(appeared, "comparison did not appear; texts=\(texts())")
        return appeared
    }

    /// 「履歴」を開いて最初の行をタップし、比較が開くまで
    @discardableResult
    private func reopenFromHistory() -> Bool {
        XCTAssertTrue(tapIfExists(app.buttons["履歴"], "history", timeout: 5))
        let listed = projectRow.waitForExistence(timeout: 10)
        log("history row visible: \(listed) texts=\(texts())")
        shot("history"); dump("07_history")
        XCTAssertTrue(listed, "history has no row")
        guard listed else { return false }
        projectRow.tap()
        let reopened = app.buttons["自分基準"].waitForExistence(timeout: 15)
        log("reopened comparison: \(reopened)")
        return reopened
    }

    // MARK: - テスト本体

    /// 起動（空のステージ）→ お手本・自分の順に動画を入れて比較 → 再生操作一式 → フェーズ調整 → 履歴から開き直し → 再起動で復元
    func testFullFlow() throws {
        app.launch()
        log("empty stage: \(app.buttons["slot.mine.add"].waitForExistence(timeout: 10))")
        shot("launch"); dump("01_stage")
        guard createComparison() else { return }
        log("buttons: \(app.buttons.allElementsBoundByIndex.map { "\($0.label)|\($0.identifier)" })")

        // 再生 → 再生中に基準とループ範囲を変える（再生中でも操作が効き、再生が止まらないこと）→ 停止
        // 進みはスクリーンショットの再生ヘッドで確認する
        let play = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'play' OR label CONTAINS '再生'")).firstMatch
        let loop = app.buttons.matching(NSPredicate(
            format: "label CONTAINS 'ループ範囲' OR label CONTAINS[c] 'repeat' OR label CONTAINS 'リピート' OR label CONTAINS '繰り返し'")).firstMatch
        if tapIfExists(play, "play") {
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
                let picked = tapIfExists(app.buttons["フォローのみ"], "loop=follow (playing)", timeout: 3)
                    || tapIfExists(app.menuItems["フォローのみ"], "loop=follow (playing, menuItem)", timeout: 2)
                XCTAssertTrue(picked, "再生中にループ範囲のメニュー項目を選べない")
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
            if !tapIfExists(app.buttons["ダウンスイングのみ"], "loop=downswing", timeout: 3) {
                tapIfExists(app.menuItems["ダウンスイングのみ"], "loop=downswing (menuItem)", timeout: 2)
            }
        }
        if tapIfExists(play, "play (segment loop)", timeout: 3) {
            sleep(3); shot("playing_loop")
            tapIfExists(pauseButton(), "pause", timeout: 3)
        }

        // フェーズ調整シート（テンポバッジをタップして開き、保存で閉じる）
        let badge = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '自分 '")).firstMatch
        if tapIfExists(badge, "tempo badge (mine)", timeout: 3) {
            let title = app.navigationBars.matching(NSPredicate(format: "identifier CONTAINS 'フェーズ調整'")).firstMatch
            log("phase edit appeared: \(title.waitForExistence(timeout: 10)) texts=\(texts())")
            shot("phase_edit"); dump("06_phase_edit")
            tapIfExists(app.buttons["+1コマ"], "phase +1 frame", timeout: 3)
            tapIfExists(app.buttons["保存"], "save phase edit", timeout: 3)
        }
        usleep(500_000)
        shot("comparison_end")

        // 履歴から開き直す
        XCTAssertTrue(reopenFromHistory())

        // 再起動 → ステージは空 → 履歴に残っている → 開き直す
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["slot.mine.add"].waitForExistence(timeout: 10), "stage should be empty after relaunch")
        shot("relaunch")
        XCTAssertTrue(reopenFromHistory())
        sleep(1); shot("reopened")
    }

    /// ライブラリから選んだお手本に名前を付けると登録済みに入り、次はピッカーで選ぶだけで（解析なしで）入れ替わること。
    /// 長押しで名前を変えるとペインのラベルにも反映されること
    func testModelLibrary() throws {
        let name = "McIlroy iron"
        app.launch()
        guard createComparison(modelName: name) else { return }
        XCTAssertEqual(paneTitle(side: "model"), name, "registered name not shown on pane; texts=\(texts())")
        shot("registered")

        // 比較中に右ペインだけ登録済みから入れ替える（前回バッジ付きで並ぶ）
        guard createComparison(registeredModel: name, pickMine: false) else { return }
        XCTAssertEqual(paneTitle(side: "model"), name, "library model name not shown on pane")
        shot("reused")

        // 履歴に 2 件
        XCTAssertTrue(tapIfExists(app.buttons["履歴"], "history", timeout: 5))
        let rows = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '比較 '"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10))
        log("history rows: \(rows.count)")
        XCTAssertEqual(rows.count, 2, "two comparisons expected in history")
        shot("history_two"); dump("08_history")
        tapIfExists(app.buttons["閉じる"], "close history", timeout: 3)
        waitForSheetToClose("履歴")

        // 長押し → 名前を変更
        openPicker(side: "model")
        XCTAssertTrue(app.navigationBars["お手本を選ぶ"].waitForExistence(timeout: 5), "picker did not open for rename")
        let card = app.buttons[name]
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.press(forDuration: 1.0)
        XCTAssertTrue(tapIfExists(app.buttons["名前を変更"], "rename (context menu)", timeout: 5))
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "rename alert not shown")
        field.tap()
        field.typeText(" v2")
        XCTAssertTrue(tapIfExists(app.alerts.buttons["保存"], "save rename", timeout: 3))
        XCTAssertTrue(app.buttons["\(name) v2"].waitForExistence(timeout: 5), "renamed card not shown")
        shot("renamed")
        tapIfExists(app.buttons["閉じる"], "close picker", timeout: 3)
        waitForSheetToClose("お手本を選ぶ")
        XCTAssertEqual(paneTitle(side: "model"), "\(name) v2", "pane label did not follow the rename")
    }

    /// 保存済みプロジェクト（E2E_KEEP_DATA=1 で残したもの。お手本側に candidates を入れておく）を開き、
    /// フェーズ調整画面でスイング候補を切り替えられること。シミュレータでは Vision が動かないので候補は projects.json に直接入れる
    func testPhaseEditCandidates() throws {
        app.launch()
        XCTAssertTrue(tapIfExists(app.buttons["履歴"], "history", timeout: 10))
        XCTAssertTrue(projectRow.waitForExistence(timeout: 10), "保存済みプロジェクトがない（先に testFullFlow を回し、projects.json に candidates を入れる）")
        projectRow.tap()
        XCTAssertTrue(app.buttons["自分基準"].waitForExistence(timeout: 15))
        sleep(1)
        shot("comparison")
        log("comparison texts: \(texts())")

        let badge = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'お手本 '")).firstMatch
        XCTAssertTrue(tapIfExists(badge, "tempo badge (model)"))
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

    /// ピンチで拡大・縮小、ドラッグで移動したペインの状態が、履歴から開き直しても、再起動しても残ること
    func testZoomPanPersistence() throws {
        app.launch()
        guard createComparison() else { return }

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

        // 履歴から開き直す
        XCTAssertTrue(reopenFromHistory())
        XCTAssertTrue(mine.waitForExistence(timeout: 15))
        sleep(1)
        log("after reopen: mine=\(mine.value ?? "nil") model=\(model.value ?? "nil")")
        XCTAssertEqual(mine.value as? String, mineState, "mine state lost after reopen")
        XCTAssertEqual(model.value as? String, modelState, "model state lost after reopen")
        shot("zoom_pan_reopened")

        // 再起動 → 履歴から開き直す
        app.terminate(); app.launch()
        XCTAssertTrue(reopenFromHistory())
        XCTAssertTrue(mine.waitForExistence(timeout: 15))
        sleep(1)
        log("after relaunch: mine=\(mine.value ?? "nil") model=\(model.value ?? "nil")")
        XCTAssertEqual(mine.value as? String, mineState, "mine state lost after relaunch")
        XCTAssertEqual(model.value as? String, modelState, "model state lost after relaunch")
        shot("zoom_pan_relaunched")

        // リセットボタンで既定に戻る（自分ペイン側の 2 つ目のボタン）
        let reset = app.buttons.matching(identifier: "arrow.counterclockwise").firstMatch
        if tapIfExists(reset, "reset (mine)", timeout: 3) {
            usleep(500_000)
            log("mine after reset: \(mine.value ?? "nil")")
            XCTAssertEqual(mine.value as? String, "x1.00 (0, 0)")
        }
    }
}

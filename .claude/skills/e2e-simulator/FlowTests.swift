import XCTest

/// SwingDuet の主要フローをシミュレータで通しで操作する E2E テスト。
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
    private func pickVideo(rowTitle: String, index: Int, match: String?) {
        XCTAssertTrue(tapIfExists(app.staticTexts[rowTitle], rowTitle))
        let pred = NSPredicate(format: "label BEGINSWITH[c] 'video' OR label CONTAINS 'ビデオ' OR label CONTAINS '動画'")
        let cells = app.images.matching(pred)
        guard cells.firstMatch.waitForExistence(timeout: 15) else {
            dump("picker_fail_\(index)")
            shot("picker_fail")
            XCTFail("picker cells not found for \(rowTitle)")
            return
        }
        let n = cells.count
        let labels = cells.allElementsBoundByIndex.map { $0.label }
        log("picker: \(n) video cells: \(labels)")
        shot("picker")
        var chosen = min(index, n - 1)
        if let match {
            guard let found = labels.firstIndex(where: { $0.contains(match) }) else {
                XCTFail("picker: no cell matches '\(match)' for \(rowTitle): \(labels)")
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

    /// ＋ → 動画 2 本を選択 → 解析 → 比較画面が出るまで。比較画面が出たら true
    private func createProject() -> Bool {
        log("empty state visible: \(app.staticTexts["比較プロジェクトがありません"].waitForExistence(timeout: 10))")
        dump("01_list")

        // ＋ ボタン（SF Symbol "plus" のラベルはロケール依存なので候補を並べる）
        let nav = app.navigationBars.firstMatch
        XCTAssertTrue(nav.waitForExistence(timeout: 5))
        let add = nav.buttons.matching(NSPredicate(format: "label IN {'Add','追加','plus','+'} OR identifier IN {'Add','plus'}")).firstMatch
        if !tapIfExists(add, "+ (by label)") {
            nav.buttons.element(boundBy: nav.buttons.count - 1).tap()
            log("TAP + (last nav button)")
        }
        XCTAssertTrue(app.navigationBars["新しい比較"].waitForExistence(timeout: 5), "sheet did not open")
        shot("new_sheet")
        dump("02_new_sheet")

        pickVideo(rowTitle: "自分のスイング", index: mineIndex, match: mineMatch)
        XCTAssertTrue(app.navigationBars["新しい比較"].waitForExistence(timeout: 20), "picker did not dismiss (mine)")
        shot("after_pick_mine")
        pickVideo(rowTitle: "お手本のスイング", index: modelIndex, match: modelMatch)
        XCTAssertTrue(app.navigationBars["新しい比較"].waitForExistence(timeout: 20), "picker did not dismiss (model)")

        // 2 本とも読み込めると解析ボタンが有効になる
        let analyze = app.buttons["解析して比較を開始"]
        XCTAssertTrue(analyze.waitForExistence(timeout: 10))
        let enabled = XCTWaiter().wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: analyze)], timeout: 60)
        log("analyze button enabled: \(enabled == .completed) texts=\(texts())")
        shot("both_picked")
        dump("03_both_picked")
        if enabled != .completed {
            XCTFail("videos did not load: \(texts())")
            return false
        }
        analyze.tap()
        shot("analyzing")

        // 解析完了 → 比較画面（基準切替のセグメントが出たら遷移完了とみなす）
        let appeared = app.buttons["自分基準"].waitForExistence(timeout: 240)
        sleep(2)   // シートの閉じアニメーションと初期シークが落ち着くのを待つ
        shot("after_analyze")
        dump("04_after_analyze")
        log("comparison appeared: \(appeared) texts=\(texts())")
        XCTAssertTrue(appeared, "comparison view did not appear; texts=\(texts())")
        return appeared
    }

    // MARK: - テスト本体

    /// 起動 → プロジェクト作成 → 再生操作一式 → フェーズ調整 → 一覧 → 再起動で復元
    func testFullFlow() throws {
        app.launch()
        shot("launch")
        guard createProject() else { return }
        log("buttons: \(app.buttons.allElementsBoundByIndex.map { "\($0.label)|\($0.identifier)" })")

        // 再生 → 2 秒後に停止（進みはスクリーンショットの再生ヘッドで確認する）
        let play = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'play' OR label CONTAINS '再生'")).firstMatch
        if tapIfExists(play, "play") {
            sleep(2)
            shot("playing")
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

        // 基準切り替え
        tapIfExists(app.buttons["お手本基準"], "reference=model", timeout: 3)
        usleep(500_000); shot("reference_model")
        tapIfExists(app.buttons["自分基準"], "reference=mine", timeout: 3)
        usleep(300_000)

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

        // ループメニュー → ダウンスイングのみ → 区間ループ再生
        let loop = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'repeat' OR label CONTAINS 'リピート' OR label CONTAINS '繰り返し'")).firstMatch
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

        // 一覧へ戻る → 行がある
        tapIfExists(app.navigationBars.buttons.firstMatch, "back", timeout: 5)
        log("project row visible: \(projectRow.waitForExistence(timeout: 10)) texts=\(texts())")
        shot("list_with_project"); dump("07_list_with_project")

        // 再起動 → 永続化を確認 → 再オープン
        app.terminate(); app.launch()
        let persisted = projectRow.waitForExistence(timeout: 10)
        log("persisted after relaunch: \(persisted)")
        XCTAssertTrue(persisted)
        shot("relaunch")
        if persisted {
            projectRow.tap()
            log("reopened comparison: \(app.buttons["自分基準"].waitForExistence(timeout: 15))")
            sleep(1); shot("reopened")
        }
    }

    /// 保存済みプロジェクト（E2E_KEEP_DATA=1 で残したもの。お手本側に candidates を入れておく）を開き、
    /// フェーズ調整画面でスイング候補を切り替えられること。シミュレータでは Vision が動かないので候補は projects.json に直接入れる
    func testPhaseEditCandidates() throws {
        app.launch()
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

    /// ピンチで拡大・縮小、ドラッグで移動したペインの状態が、一覧に戻って開き直しても、再起動しても残ること
    func testZoomPanPersistence() throws {
        app.launch()
        guard createProject() else { return }

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

        // 一覧へ戻って開き直す
        tapIfExists(app.navigationBars.buttons.firstMatch, "back", timeout: 5)
        XCTAssertTrue(projectRow.waitForExistence(timeout: 10))
        projectRow.tap()
        XCTAssertTrue(mine.waitForExistence(timeout: 15))
        sleep(1)
        log("after reopen: mine=\(mine.value ?? "nil") model=\(model.value ?? "nil")")
        XCTAssertEqual(mine.value as? String, mineState, "mine state lost after reopen")
        XCTAssertEqual(model.value as? String, modelState, "model state lost after reopen")
        shot("zoom_pan_reopened")

        // 再起動
        app.terminate(); app.launch()
        XCTAssertTrue(projectRow.waitForExistence(timeout: 10))
        projectRow.tap()
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

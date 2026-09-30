import XCTest

/// W1 UI 测试：作品库 → 工作区（真实 SwiftRuntime 解释器）。
/// 源码修改通过真实的编辑器输入完成（选中全部 → 键入新内容），不走任何注入后门。
@MainActor
final class FairyStudioUITests: XCTestCase {
    // MARK: - 辅助

    private func launch() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        return app
    }

    private func wait(_ element: XCUIElement, label expected: String, timeout: TimeInterval = 10) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", expected), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// 在主线程轮询条件（每 100ms 查询一次无障碍树）。
    private func waitFor(timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }

    private func stateBadge(_ app: XCUIApplication) -> XCUIElement { app.staticTexts["run.state"] }

    /// 通过真实编辑器替换当前文件。
    private func replaceEditorText(in app: XCUIApplication, with text: String) {
        let editor = app.textViews["editor.text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        editor.typeKey("a", modifierFlags: .command)
        editor.typeText(XCUIKeyboardKey.delete.rawValue)
        if let remaining = editor.value as? String, !remaining.isEmpty {
            editor.typeKey(XCUIKeyboardKey.downArrow.rawValue, modifierFlags: .command)
            editor.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: remaining.count + 8))
        }
        XCTAssertEqual((editor.value as? String) ?? "", "", "清空编辑器失败")
        editor.typeText(text)
        XCTAssertEqual(editor.value as? String, text, "编辑器内容与键入内容不一致（可能被自动替换）")
    }

    private func run(_ app: XCUIApplication) {
        app.buttons["run.button"].tap()
    }

    private func stop(_ app: XCUIApplication) {
        let stop = app.buttons["stop.button"]
        if stop.isEnabled { stop.tap() }
    }

    /// 新建作品表：填名后创建，进工作区。
    private func createProject(named name: String, in app: XCUIApplication) {
        app.buttons["library.new"].tap()
        let field = app.textFields["library.newName"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(name)
        app.buttons["library.create"].tap()
    }

    /// 从模板建作品：首页 → 模板库 → 模板行。
    private func createFromTemplate(_ id: String, in app: XCUIApplication) {
        // 首屏"从模板开始"：基础模板在首屏（懒加载 List，必要时滚动）。
        var button = app.buttons["library.template.\(id)"]
        var rowFound = button.waitForExistence(timeout: 2)
        for _ in 0..<5 where !rowFound {
            app.swipeUp()
            rowFound = button.waitForExistence(timeout: 1)
        }
        XCTAssertTrue(rowFound, "找不到模板入口 \(id)")
        button.tap()
    }
    /// 确保在代码段（iPhone 分段；iPad 顶栏分段）。
    private func showCode(_ app: XCUIApplication) {
        let picker = app.segmentedControls["workspace.panePicker"]
        if picker.exists {
            picker.buttons["代码"].tap()
            return
        }
        let segment = app.segmentedControls["workspace.viewPicker"]
        XCTAssertTrue(segment.waitForExistence(timeout: 5), "找不到作品/代码分段")
        segment.buttons["代码"].tap()
    }

    /// 确保在作品段（运行结果可见）。
    private func showPreview(_ app: XCUIApplication) {
        let picker = app.segmentedControls["workspace.panePicker"]
        if picker.exists {
            picker.buttons["作品"].tap()
            return
        }
        app.segmentedControls["workspace.viewPicker"].buttons["作品"].tap()
    }

    /// 关闭键盘（点顶部工具条空白处）：菜单/弹窗操作前调用。
    private func dismissKeyboard(in app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)).tap()
    }

    /// 文件树中的文件行：若不在层级里则打开「文件」抽屉。
    private func treeRow(_ path: String, in app: XCUIApplication) -> XCUIElement {
        let id = "workspace.openFile.\(path)"
        if app.buttons[id].exists { return app.buttons[id] }
        app.buttons["workspace.filesButton"].tap()
        let row = app.buttons[id]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "找不到文件行 \(path)")
        return row
    }

    /// 关闭抽屉（若开）并回到代码段。
    private func backToCode(in app: XCUIApplication) {
        if app.buttons["完成"].exists {
            app.buttons["完成"].tap()
        }
        let picker = app.segmentedControls["workspace.panePicker"]
        if picker.exists {
            picker.buttons["代码"].tap()
            return
        }
        let segment = app.segmentedControls["workspace.viewPicker"]
        if segment.exists { segment.buttons["代码"].tap() }
    }

    /// 文件树抽屉中长按指定文件 → 改名（内联输入新路径回车）。
    private func renameInDrawer(_ path: String, to newPath: String, in app: XCUIApplication) {
        dismissKeyboard(in: app)
        treeRow(path, in: app).press(forDuration: 1.2)
        app.buttons["改名"].tap()
        let field = app.textFields["workspace.inlineRenameField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(newPath + "\n")
        backToCode(in: app)
    }

    /// 文件树抽屉中长按指定文件 → 删除。
    private func deleteInDrawer(_ path: String, in app: XCUIApplication) {
        dismissKeyboard(in: app)
        treeRow(path, in: app).press(forDuration: 1.2)
        app.buttons["删除"].tap()
        backToCode(in: app)
    }
    private func openFile(_ path: String, in app: XCUIApplication) {
        // 行标识即入口：不在层级里则打开「文件」抽屉。
        var row = app.buttons["workspace.openFile.\(path)"]
        if !row.exists {
            app.buttons["workspace.filesButton"].tap()
            row = app.buttons["workspace.openFile.\(path)"]
            XCTAssertTrue(row.waitForExistence(timeout: 10), "找不到文件行 \(path)")
        }
        row.tap()
        if app.buttons["完成"].exists {
            app.buttons["完成"].tap()
        }
        showCode(app)
        XCTAssertTrue(app.textViews["editor.text"].waitForExistence(timeout: 10))
    }

    private func record(_ line: String) {
        print(line)
        let attachment = XCTAttachment(string: line)
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private var deviceName: String { UIDevice.current.name }
    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    // MARK: - 流程

    /// 新建空白作品 → 运行 → Hello → 停止。
    func testCreateBlankAndRun() throws {
        let app = launch()
        XCTAssertTrue(app.buttons["library.new"].waitForExistence(timeout: 10), "首页应为作品库")
        createProject(named: "空白验证", in: app)
        XCTAssertTrue(app.buttons["run.button"].waitForExistence(timeout: 10))
        showCode(app)
        run(app)
        XCTAssertTrue(wait(stateBadge(app), label: "运行状态：运行中"), "实际：\(stateBadge(app).label)")
        showPreview(app)
        let hello = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Hello, FairyStudio!")).firstMatch
        XCTAssertTrue(hello.waitForExistence(timeout: 10))
        record("[FAIRY-W1-UI] device=\(deviceName) blank run → \(hello.label)")
        stop(app)
        XCTAssertTrue(wait(stateBadge(app), label: "运行状态：已停止"))
    }

    /// 完整流程：模板新建 → 运行 → 新建第二文件 → 编辑保存 → 运行 → 改名 → 重跑一致 → 删除 → 破坏 → 诊断（失败）。
    func testCounterFileFlow() throws {
        let app = launch()
        createFromTemplate("counter", in: app)
        XCTAssertTrue(app.buttons["run.button"].waitForExistence(timeout: 10))
        showCode(app)

        // 运行 → 预览 → Count: 0 → 点击 → 1。
        run(app)
        XCTAssertTrue(wait(stateBadge(app), label: "运行状态：运行中"), "实际：\(stateBadge(app).label)")
        showPreview(app)
        var count = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Count: ")).firstMatch
        XCTAssertTrue(count.waitForExistence(timeout: 10))
        XCTAssertTrue(wait(count, label: "Count: 0"), "实际：\(count.label)")
        app.buttons["Increment"].tap()
        XCTAssertTrue(wait(count, label: "Count: 1"), "实际：\(count.label)")

        // 新建第二文件（Sources/Untitled.swift 自动打开）→ 切到代码 → 写入 → 保存。
        app.buttons["workspace.newFile"].tap()
        app.buttons["新建文件"].tap()
        showCode(app)
        XCTAssertTrue(waitFor { app.textViews["editor.text"].exists })
        replaceEditorText(in: app, with: "// helper\nstruct Helper {\n    static func one() -> Int {\n        1\n    }\n}\n")
        app.buttons["workspace.save"].tap()
        XCTAssertTrue(waitFor { !app.buttons["workspace.save"].isEnabled }, "保存后应变干净")

        // 运行：结果一致。
        run(app)
        showPreview(app)
        XCTAssertTrue(wait(stateBadge(app), label: "运行状态：运行中"), "实际：\(stateBadge(app).label)")
        count = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Count: ")).firstMatch
        XCTAssertTrue(wait(count, label: "Count: 0"), "实际：\(count.label)")

        // 改名第二文件 → 重跑一致。
        renameInDrawer("Sources/Untitled.swift", to: "Sources/Helpers/Format.swift", in: app)
        XCTAssertTrue(waitFor(timeout: 10) { stateBadge(app).label == "运行状态：运行中" || stateBadge(app).label == "运行状态：已停止" })
        run(app)
        XCTAssertTrue(wait(stateBadge(app), label: "运行状态：运行中"), "改名后实际：\(stateBadge(app).label)")
        showPreview(app)
        count = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Count: ")).firstMatch
        XCTAssertTrue(wait(count, label: "Count: 0"), "改名后实际：\(count.label)")

        // 删除第二文件 → 仍可运行。
        deleteInDrawer("Sources/Helpers/Format.swift", in: app)
        run(app)
        XCTAssertTrue(wait(stateBadge(app), label: "运行状态：运行中"), "删除后实际：\(stateBadge(app).label)")

        // 破坏主文件（class 继承）→ 运行失败。
        openFile("Sources/Views/ContentView.swift", in: app)
        replaceEditorText(in: app, with: "struct Broken {}\nclass Base {}\nclass Derived: Base {}\n")
        app.buttons["workspace.save"].tap()
        run(app)
        XCTAssertTrue(wait(stateBadge(app), label: "运行状态：失败", timeout: 15), "破坏后实际：\(stateBadge(app).label)")
        record("[FAIRY-W1-UI] device=\(deviceName) flow ok（新建→编辑→运行→改名→重跑→删除→诊断）")
        stop(app)
    }

    // MARK: - 布局

    /// iPhone：作品 / 代码 / 助手三段切换；作品是默认段；助手段为真实对话面板。
    func testCompactLayout() throws {
        try XCTSkipUnless(!isPad, "仅 iPhone 跑分段断言")
        let app = launch()
        createProject(named: "布局验证", in: app)
        let picker = app.segmentedControls["workspace.panePicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["run.button"].waitForExistence(timeout: 5), "作品段应含运行控制")
        for name in ["代码", "助手"] {
            picker.buttons[name].tap()
        }
        let input = app.descendants(matching: .any).matching(identifier: "assistant.input").firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5), "助手段为真实对话面板")
        picker.buttons["作品"].tap()
        XCTAssertTrue(app.buttons["run.button"].waitForExistence(timeout: 5))
        record("[FAIRY-W1-UI] device=\(deviceName) compact 三段切换 ok")
    }

    /// 模板库页可达：从首页进入分组模板库并复制为新作品。
    func testTemplateGalleryPushes() throws {
        let app = launch()
        let gallery = app.descendants(matching: .any).matching(identifier: "library.templateGallery").firstMatch
        var found = gallery.waitForExistence(timeout: 10)
        for _ in 0..<6 where !found {
            app.swipeUp()
            found = gallery.waitForExistence(timeout: 1)
        }
        XCTAssertTrue(found, "找不到模板库入口")
        gallery.tap()
        let calcRow = app.buttons["library.template.calc"]
        var rowFound = calcRow.waitForExistence(timeout: 2)
        for _ in 0..<8 where !rowFound {
            app.swipeUp()
            rowFound = calcRow.waitForExistence(timeout: 1)
        }
        XCTAssertTrue(rowFound, "模板库应包含 calc 模板")
        calcRow.tap()
        XCTAssertTrue(app.buttons["run.button"].waitForExistence(timeout: 10), "从模板进入工作区")
        record("[FAIRY-W1-UI] device=\(deviceName) 模板库推入 ok")
    }

    /// 模板库页可达：从首页进入分组模板库并复制为新作品。

    /// iPad：左中右三面板——侧栏（会话历史 / 设置）+ 中栏聊天 + 右栏运行预览；文件树经抽屉可达。
    func testRegularLayout() throws {
        try XCTSkipUnless(isPad, "仅 iPad 跑三面板断言")
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = launch()
        createProject(named: "布局验证", in: app)
        XCTAssertTrue(app.buttons["run.button"].waitForExistence(timeout: 10))
        let anyElement = app.descendants(matching: .any)
        XCTAssertTrue(app.buttons["assistant.newChat"].waitForExistence(timeout: 10)
                      || anyElement.matching(identifier: "assistant.sidebar").firstMatch.exists, "助手栏应常驻")
        XCTAssertTrue(anyElement.matching(identifier: "workspace.mainStage").firstMatch.exists, "作品主舞台应常驻")
        XCTAssertTrue(anyElement.matching(identifier: "assistant.input").firstMatch.waitForExistence(timeout: 5), "聊天输入框应在位")
        // 文件树经「文件」抽屉可达。
        app.buttons["workspace.filesButton"].tap()
        XCTAssertTrue(app.buttons["workspace.openFile.Sources/ContentView.swift"].waitForExistence(timeout: 10), "文件抽屉应有文件行")
        app.buttons["完成"].tap()
        record("[FAIRY-W1-UI] device=\(deviceName) regular 三面板 ok")
    
}
}
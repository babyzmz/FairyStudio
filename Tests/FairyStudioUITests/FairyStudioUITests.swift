import XCTest

/// Verify scheme 的 UI 测试（M0-C 起全部使用真实 SwiftRuntime 解释器；App 中已无夹具引擎）。
/// 源码修改通过真实的编辑器输入完成（选中全部 → 键入新内容），不走任何注入后门。
@MainActor
final class FairyStudioUITests: XCTestCase {
    // MARK: - 源码（与 Templates/Counter 的 Counter.swift 结构一致，只改需要验证的部分）

    static let counterInitialTen = """
    struct CounterModel {
        private(set) var count: Int = 10
        var step: Int = 1

        mutating func increment() {
            count += step
        }

        mutating func reset() {
            count = 0
        }

        var label: String {
            "Count: \\(count)"
        }
    }

    """

    static let counterInfiniteLoop = """
    struct CounterModel {
        private(set) var count: Int = 0
        var step: Int = 1

        mutating func increment() {
            while true { count += step }
        }

        mutating func reset() {
            count = 0
        }

        var label: String {
            "Count: \\(count)"
        }
    }

    """

    static let counterDivideByZero = """
    struct CounterModel {
        private(set) var count: Int = 0
        var step: Int = 1

        mutating func increment() {
            count += 10 / (step - step)
        }

        mutating func reset() {
            count = 0
        }

        var label: String {
            "Count: \\(count)"
        }
    }

    """

    static let counterWithClassInheritance = """
    struct CounterModel {
        private(set) var count: Int = 0
        var step: Int = 1

        mutating func increment() {
            count += step
        }

        mutating func reset() {
            count = 0
        }

        var label: String {
            "Count: \\(count)"
        }
    }

    class Base {}
    class Derived: Base {}

    """

    static let formContentView = """
    import SwiftUI

    struct ContentView: View {
        @State private var name = ""
        @State private var agreed = false
        @State private var items = ["apple", "banana", "cherry", "durian"]

        var body: some View {
            VStack(spacing: 12) {
                TextField("Name", text: $name)
                Text("Hello, \\(name)")
                Toggle("Agree", isOn: $agreed)
                Text(agreed ? "State: on" : "State: off")
                Button("Reverse") {
                    items.reverse()
                }
                ForEach(items, id: \\.self) { item in
                    Text(item)
                }
            }
            .padding()
        }
    }

    """

    // MARK: - 辅助

    private func launch(longBudget: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        if longBudget { app.launchArguments += ["-fairy.budget", "long"] }
        app.launch()
        return app
    }

    private func wait(_ element: XCUIElement, label expected: String, timeout: TimeInterval = 10) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", expected), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func wait(_ element: XCUIElement, value expected: String, timeout: TimeInterval = 10) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", expected), object: element)
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

    private func countLabel(_ app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Count: ")).firstMatch
    }

    /// iPhone（compact）在代码 / 预览之间切换；iPad（regular）两栏并排，无需切换。
    private func showPane(_ name: String, in app: XCUIApplication) {
        let picker = app.segmentedControls["lab.panePicker"]
        if picker.exists { picker.buttons[name].tap() }
    }

    private func selectFile(_ fileName: String, in app: XCUIApplication) {
        showPane("代码", in: app)
        let button = app.segmentedControls["editor.filePicker"].buttons[fileName]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "找不到文件标签 \(fileName)")
        button.tap()
    }

    /// 通过真实编辑器替换当前文件：点入 → ⌘A 全选 → 删除 → 键入新内容；键入后核对编辑器内容与期望完全一致。
    private func replaceEditorText(in app: XCUIApplication, with text: String) {
        let editor = app.textViews["editor.text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        editor.typeKey("a", modifierFlags: .command)
        editor.typeText(XCUIKeyboardKey.delete.rawValue)
        if let remaining = editor.value as? String, !remaining.isEmpty {
            // ⌘A 不可用时的退路：把光标移到末尾后逐字删除。
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
        XCTAssertTrue(stop.isEnabled)
        stop.tap()
    }

    private func openDrawer(_ tab: String, in app: XCUIApplication) {
        let tabs = app.segmentedControls["console.tabs"]
        if !tabs.exists { app.buttons["console.toggle"].tap() }
        XCTAssertTrue(tabs.waitForExistence(timeout: 5))
        tabs.buttons[tab].tap()
    }

    /// 打开「指标」页、刷新，返回指定指标的文本。
    private func metric(_ id: String, in app: XCUIApplication, refresh: Bool = true) -> String {
        openDrawer("指标", in: app)
        if refresh { app.buttons["metrics.refresh"].tap() }
        let element = app.staticTexts[id]
        XCTAssertTrue(element.waitForExistence(timeout: 5), "找不到指标 \(id)")
        return element.label
    }

    private func record(_ line: String) {
        print(line)
        let attachment = XCTAttachment(string: line)
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private var deviceName: String { UIDevice.current.name }

    // MARK: - 端到端

    /// 运行 → Count: 0 → 点击 → 1 → 2 → 停止；状态序列 validating→preparing→running→stopping→stopped。
    func testCounterRunIncrementStop() throws {
        let app = launch()
        XCTAssertTrue(wait(stateBadge(app), label: "运行状态：空闲"))
        let engineLabel = app.descendants(matching: .any)["engine.label"].firstMatch
        XCTAssertTrue(engineLabel.waitForExistence(timeout: 5))
        XCTAssertTrue(engineLabel.label.contains("SwiftRuntime"), "实际：\(engineLabel.label)")
        XCTAssertFalse(app.staticTexts["夹具引擎：非真实执行"].exists, "App 中不得再有夹具横幅")

        run(app)
        XCTAssertTrue(wait(stateBadge(app), label: "运行状态：运行中"), "实际：\(stateBadge(app).label)")
        let count = countLabel(app)
        XCTAssertTrue(count.waitForExistence(timeout: 10))
        XCTAssertTrue(wait(count, label: "Count: 0"), "实际：\(count.label)")
        attachScreenshot("counter-0-\(deviceName)")

        app.buttons["Increment"].tap()
        XCTAssertTrue(wait(count, label: "Count: 1"), "实际：\(count.label)")
        app.buttons["Increment"].tap()
        XCTAssertTrue(wait(count, label: "Count: 2"), "实际：\(count.label)")
        attachScreenshot("counter-2-\(deviceName)")

        stop(app)
        XCTAssertTrue(wait(stateBadge(app), label: "运行状态：已停止"), "实际：\(stateBadge(app).label)")
        XCTAssertFalse(app.buttons["stop.button"].isEnabled)

        let history = metric("metrics.stateHistory", in: app, refresh: false)
        let start = metric("metrics.startLatency", in: app, refresh: false)
        let validation = metric("metrics.validation", in: app, refresh: false)
        record("[FAIRY-M0C-UI] device=\(deviceName) stateHistory=\(history) startLatencyMs=\(start) validationMs=\(validation)")
        XCTAssertEqual(history, "idle→validating→preparing→running→stopping→stopped")
    }

    /// 修改源码（初始值改为 10）后重新运行，界面随之变化。
    func testEditSourceAndRerunChangesUI() throws {
        let app = launch()
        run(app)
        let count = countLabel(app)
        XCTAssertTrue(count.waitForExistence(timeout: 10))
        XCTAssertTrue(wait(count, label: "Count: 0"), "实际：\(count.label)")

        selectFile("Counter.swift", in: app)
        replaceEditorText(in: app, with: Self.counterInitialTen)
        run(app)
        XCTAssertTrue(wait(count, label: "Count: 10"), "实际：\(count.label)")
        app.buttons["Increment"].tap()
        XCTAssertTrue(wait(count, label: "Count: 11"), "实际：\(count.label)")
        stop(app)
        XCTAssertTrue(wait(stateBadge(app), label: "运行状态：已停止"))
    }

    /// 按钮里的无限循环（调试长预算，只有用户停止能结束）：测量点击停止 → 已停止。
    func testInfiniteLoopStopLatency() throws {
        let app = launch(longBudget: true)
        selectFile("Counter.swift", in: app)
        replaceEditorText(in: app, with: Self.counterInfiniteLoop)
        run(app)
        XCTAssertTrue(wait(stateBadge(app), label: "运行状态：运行中"))
        let increment = app.buttons["Increment"]
        XCTAssertTrue(increment.waitForExistence(timeout: 10))
        increment.tap()
        // 循环已持续 1.5 秒：长预算下不会被中断。
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertEqual(stateBadge(app).label, "运行状态：运行中")

        let stopButton = app.buttons["stop.button"]
        let t0 = Date()
        stopButton.tap()
        // 100ms 轮询（XCTNSPredicateExpectation 约 1s 轮询一次，会把观测值放大到秒级）。
        XCTAssertTrue(waitFor(timeout: 5) { stateBadge(app).label == "运行状态：已停止" }, "实际：\(stateBadge(app).label)")
        let uiObserved = Date().timeIntervalSince(t0) * 1000

        let appMeasured = metric("metrics.stopLatency", in: app, refresh: false)
        let completion = metric("metrics.stopCompletion", in: app, refresh: false)
        let budget = metric("metrics.budget", in: app, refresh: false)
        record(String(format: "[FAIRY-M0C-UI] device=%@ infiniteLoop stop: app(停止→终态)=%@ms app(停止→释放)=%@ms xcuitest(点击→观察到已停止，含 XCUITest 点击与无障碍查询开销)=%.0fms budget=%@",
                      deviceName, appMeasured, completion, uiObserved, budget))
        let ms = try XCTUnwrap(Double(appMeasured))
        XCTAssertLessThan(ms, 250, "停止延迟超过 250ms")
    }

    /// 同样的无限循环在默认预算下：UI 事件单片墙钟 200ms 是硬上限 → 已中断 + budgetExceeded 诊断。
    func testInfiniteLoopDefaultBudgetInterrupts() throws {
        let app = launch()
        selectFile("Counter.swift", in: app)
        replaceEditorText(in: app, with: Self.counterInfiniteLoop)
        run(app)
        let increment = app.buttons["Increment"]
        XCTAssertTrue(increment.waitForExistence(timeout: 10))
        increment.tap()
        XCTAssertTrue(wait(stateBadge(app), label: "运行状态：已中断", timeout: 5), "实际：\(stateBadge(app).label)")
        openDrawer("诊断", in: app)
        let diagnostic = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "budgetExceeded")).firstMatch
        XCTAssertTrue(diagnostic.waitForExistence(timeout: 5))
        record("[FAIRY-M0C-UI] device=\(deviceName) defaultBudget infiniteLoop → \(diagnostic.label)")
    }

    /// 连续运行—停止 30 次：协调器实例数 0、引擎存活 0/0/0、记录前后内存。
    func testThirtyRunStopCyclesLeaveNoInstances() throws {
        let app = launch()
        let residentBefore = metric("metrics.residentMB", in: app)
        let footprintBefore = metric("metrics.footprintMB", in: app, refresh: false)
        let count = countLabel(app)
        for index in 0..<30 {
            run(app)
            XCTAssertTrue(wait(stateBadge(app), label: "运行状态：运行中"), "第 \(index + 1) 次：\(stateBadge(app).label)")
            XCTAssertTrue(wait(count, label: "Count: 0"), "第 \(index + 1) 次：\(count.label)")
            stop(app)
            XCTAssertTrue(wait(stateBadge(app), label: "运行状态：已停止"), "第 \(index + 1) 次：\(stateBadge(app).label)")
        }
        let active = metric("metrics.activeInstances", in: app)
        let engineLive = metric("metrics.engineLive", in: app, refresh: false)
        let runCounts = metric("metrics.runCounts", in: app, refresh: false)
        let residentAfter = metric("metrics.residentMB", in: app, refresh: false)
        let footprintAfter = metric("metrics.footprintMB", in: app, refresh: false)
        record("[FAIRY-M0C-UI] device=\(deviceName) 30 cycles: activeInstances=\(active) engineLive(实例/线程/任务)=\(engineLive) started/released=\(runCounts) residentMB \(residentBefore)→\(residentAfter) footprintMB \(footprintBefore)→\(footprintAfter)")
        XCTAssertEqual(active, "0")
        XCTAssertEqual(engineLive, "0/0/0")
        XCTAssertEqual(runCounts, "30/30")
    }

    /// 交换两个文件顺序后重新运行，结果一致。
    func testFileOrderSwapGivesSameResult() throws {
        let app = launch()
        showPane("代码", in: app)
        let order = app.staticTexts["editor.order"]
        XCTAssertTrue(order.waitForExistence(timeout: 5))
        let orderBefore = order.label

        func runAndCollect() -> [String] {
            run(app)
            let count = countLabel(app)
            XCTAssertTrue(wait(count, label: "Count: 0"), "实际：\(count.label)")
            app.buttons["Increment"].tap()
            XCTAssertTrue(wait(count, label: "Count: 1"), "实际：\(count.label)")
            let observed = [count.label, app.buttons["Increment"].exists ? "Increment" : "-",
                            app.buttons["Reset"].exists ? "Reset" : "-", app.buttons["Reset"].isEnabled ? "reset-enabled" : "reset-disabled"]
            stop(app)
            XCTAssertTrue(wait(stateBadge(app), label: "运行状态：已停止"))
            return observed
        }

        let first = runAndCollect()
        showPane("代码", in: app)
        app.buttons["editor.swapOrder"].tap()
        XCTAssertTrue(waitFor { order.label != orderBefore })
        let orderAfter = order.label
        let second = runAndCollect()
        record("[FAIRY-M0C-UI] device=\(deviceName) order「\(orderBefore)」→\(first)；order「\(orderAfter)」→\(second)")
        XCTAssertEqual(first, second)
    }

    /// 合法但不支持的 Swift（class 继承）→ 诊断「运行时尚不支持」且带 capability ID，不是「找不到名称」。
    func testUnsupportedSyntaxShowsCapabilityID() throws {
        let app = launch()
        selectFile("Counter.swift", in: app)
        replaceEditorText(in: app, with: Self.counterWithClassInheritance)
        run(app)
        XCTAssertTrue(wait(stateBadge(app), label: "运行状态：失败"), "实际：\(stateBadge(app).label)")
        openDrawer("诊断", in: app)
        let diagnostic = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "syntax.class")).firstMatch
        XCTAssertTrue(diagnostic.waitForExistence(timeout: 5), "诊断面板没有 capability ID syntax.class")
        XCTAssertTrue(diagnostic.label.contains("尚不支持"), "实际：\(diagnostic.label)")
        XCTAssertTrue(diagnostic.label.contains("unsupportedSyntax"), "实际：\(diagnostic.label)")
        let nameResolution = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "nameResolution"))
        XCTAssertEqual(nameResolution.count, 0, "不得伪装成名称错误")
        record("[FAIRY-M0C-UI] device=\(deviceName) unsupported → \(diagnostic.label)")
        attachScreenshot("unsupported-\(deviceName)")
    }

    /// 除零 trap → runtimeTrap 诊断、状态失败、App 不崩，之后可以再次运行。
    func testDivideByZeroTrapIsDiagnosed() throws {
        let app = launch()
        selectFile("Counter.swift", in: app)
        replaceEditorText(in: app, with: Self.counterDivideByZero)
        run(app)
        let increment = app.buttons["Increment"]
        XCTAssertTrue(increment.waitForExistence(timeout: 10))
        increment.tap()
        XCTAssertTrue(wait(stateBadge(app), label: "运行状态：失败"), "实际：\(stateBadge(app).label)")
        openDrawer("诊断", in: app)
        let diagnostic = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "runtimeTrap")).firstMatch
        XCTAssertTrue(diagnostic.waitForExistence(timeout: 5))
        record("[FAIRY-M0C-UI] device=\(deviceName) trap → \(diagnostic.label)")
        XCTAssertEqual(app.state, .runningForeground, "App 不得崩溃")
        // App 仍可继续使用：再次运行得到新的实例。
        run(app)
        XCTAssertTrue(wait(stateBadge(app), label: "运行状态：运行中"))
        XCTAssertTrue(wait(countLabel(app), label: "Count: 0"))
        stop(app)
    }

    /// 真实引擎下的表单控件：中文输入不丢字不颠倒、Toggle 回写、ForEach 反转。
    func testFormControlsWithRealEngine() throws {
        let app = launch()
        selectFile("ContentView.swift", in: app)
        replaceEditorText(in: app, with: Self.formContentView)
        run(app)
        XCTAssertTrue(wait(stateBadge(app), label: "运行状态：运行中"), "实际：\(stateBadge(app).label)")

        let field = app.textFields["Name"].exists ? app.textFields["Name"] : app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        // 分两批输入：第一批的回写（revision+1）到达后再输入第二批。若光标被回写打断会得到「世界你好」或丢字。
        field.typeText("你好")
        let greeting = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Hello, ")).firstMatch
        XCTAssertTrue(wait(greeting, label: "Hello, 你好"), "实际：\(greeting.label)")
        field.typeText("世界")
        XCTAssertTrue(wait(greeting, label: "Hello, 你好世界"), "实际：\(greeting.label)")
        XCTAssertTrue(wait(field, value: "你好世界"), "输入框实际：\(String(describing: field.value))")

        let toggle = app.switches.firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        let inner = toggle.switches.firstMatch
        if inner.exists { inner.tap() } else { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() }
        XCTAssertTrue(app.staticTexts["State: on"].waitForExistence(timeout: 5))

        let apple = app.staticTexts["apple"]
        XCTAssertTrue(apple.waitForExistence(timeout: 5))
        let appleY = apple.frame.minY
        app.buttons["Reverse"].tap()
        let durian = app.staticTexts["durian"]
        XCTAssertTrue(waitFor { durian.exists && abs(durian.frame.minY - appleY) <= 1 }, "反转后 durian 应在原 apple 的位置")
        // 其他控件引起的重新渲染不影响已输入内容。
        XCTAssertTrue(wait(field, value: "你好世界"))
        attachScreenshot("form-\(deviceName)")
        stop(app)
    }

    // MARK: - AI 状态

    func testAIStatusReportsRealAvailability() throws {
        let app = launch()
        // iPad（iOS 26）的标签栏与侧栏会各有一个同名按钮，取第一个可点的。
        let tab = app.tabBars.buttons["AI 状态"].firstMatch.exists ? app.tabBars.buttons["AI 状态"].firstMatch : app.buttons["AI 状态"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 5))
        tab.tap()

        let headline = app.staticTexts["ai.headline"]
        XCTAssertTrue(headline.waitForExistence(timeout: 10))
        let headlineText = headline.label
        let onDeviceCode = app.staticTexts["ai.code.onDevice"]
        scrollUntilHittable(onDeviceCode, in: app)
        XCTAssertTrue(onDeviceCode.waitForExistence(timeout: 10))
        let onDeviceText = onDeviceCode.label
        let cloudCode = app.staticTexts["ai.code.privateCloudCompute"]
        scrollUntilHittable(cloudCode, in: app)
        XCTAssertTrue(cloudCode.waitForExistence(timeout: 5))
        record("[FAIRY-AVAILABILITY-UI] device=\(deviceName) onDevice=\(onDeviceText) pcc=\(cloudCode.label) headline=\(headlineText)")

        XCTAssertEqual(cloudCode.label, "pccSDKMissing")
        if onDeviceText != "available" {
            // 不可用时：标题为「AI 当前不可用」，发送按钮禁用（没有任何假响应路径）。
            XCTAssertTrue(headlineText.contains("AI 当前不可用"), "实际：\(headlineText)")
            let prompt = app.textFields["ai.prompt"]
            scrollUntilExists(prompt, in: app)
            XCTAssertTrue(prompt.exists)
            prompt.tap()
            prompt.typeText("你好")
            let send = app.buttons["ai.send"]
            scrollUntilExists(send, in: app)
            XCTAssertTrue(send.exists)
            XCTAssertFalse(send.isEnabled, "AI 不可用时发送按钮必须禁用")
            let reason = app.staticTexts["ai.send.reason"]
            scrollUntilExists(reason, in: app)
            XCTAssertFalse(reason.label.isEmpty)
            XCTAssertNotEqual(reason.label, "请输入内容")
            app.swipeDown()
        }

        let recheck = app.buttons["ai.recheck"]
        var remaining = 5
        while !recheck.isHittable && remaining > 0 {
            app.swipeDown()
            remaining -= 1
        }
        recheck.tap()
        XCTAssertTrue(headline.waitForExistence(timeout: 10))
    }

    private func scrollUntilExists(_ element: XCUIElement, in app: XCUIApplication, attempts: Int = 5) {
        var remaining = attempts
        while !element.exists && remaining > 0 {
            app.swipeUp()
            remaining -= 1
        }
    }

    private func scrollUntilHittable(_ element: XCUIElement, in app: XCUIApplication, attempts: Int = 15) {
        var remaining = attempts
        while !(element.exists && element.isHittable) && remaining > 0 {
            // 慢速滑动 Form 本身（iPad 分栏时屏幕中心可能不是 Form）。
            let form = app.collectionViews.firstMatch
            if form.exists {
                form.swipeUp(velocity: .slow)
            } else {
                app.swipeUp(velocity: .slow)
            }
            remaining -= 1
        }
    }
}

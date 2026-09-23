import XCTest

/// Verify scheme（FAIRY_VERIFY_BUILD + Debug）的 UI 测试。夹具引擎通过启动参数选择，界面顶部必须出现夹具横幅。
final class FairyStudioUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(engine: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-fairy.engine", engine]
        app.launch()
        return app
    }

    private func waitForLabel(_ element: XCUIElement, equals expected: String, timeout: TimeInterval = 5) -> Bool {
        let predicate = NSPredicate(format: "label == %@", expected)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForValue(_ element: XCUIElement, equals expected: String, timeout: TimeInterval = 5) -> Bool {
        let predicate = NSPredicate(format: "value == %@", expected)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func scrollUntilExists(_ element: XCUIElement, in app: XCUIApplication, attempts: Int = 5) {
        var remaining = attempts
        while !element.exists && remaining > 0 {
            app.swipeUp()
            remaining -= 1
        }
    }

    func testCounterRunIncrementStop() throws {
        let app = launch(engine: "fixture.counter")
        let banner = app.staticTexts["夹具引擎：非真实执行"]
        XCTAssertTrue(banner.waitForExistence(timeout: 5), "夹具横幅必须可见")
        // 横幅不得遮住运行按钮。
        XCTAssertTrue(app.buttons["run.button"].isHittable)
        XCTAssertLessThanOrEqual(banner.frame.maxY, app.buttons["run.button"].frame.minY + 1, "横幅遮挡了工具条")

        app.buttons["run.button"].tap()
        let count = app.staticTexts["counter.label"]
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForLabel(count, equals: "Count: 0"), "实际：\(count.label)")

        app.buttons["counter.increment"].tap()
        XCTAssertTrue(waitForLabel(count, equals: "Count: 1"), "实际：\(count.label)")

        let stop = app.buttons["stop.button"]
        XCTAssertTrue(stop.isEnabled)
        stop.tap()
        let state = app.staticTexts["run.state"]
        XCTAssertTrue(waitForLabel(state, equals: "运行状态：已停止"), "实际：\(state.label)")
        XCTAssertFalse(stop.isEnabled)
    }

    func testChineseTextInputKeepsEveryCharacter() throws {
        let app = launch(engine: "fixture.form")
        app.buttons["run.button"].tap()
        let field = app.textFields["form.name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()

        // 分两批输入：第一批的回写（revision+1）到达后再输入第二批。若光标被回写打断会得到「世界你好」或丢字。
        field.typeText("你好")
        let greeting = app.staticTexts["form.greeting"]
        XCTAssertTrue(waitForLabel(greeting, equals: "你好，你好"), "实际：\(greeting.label)")
        field.typeText("世界")
        XCTAssertTrue(waitForLabel(greeting, equals: "你好，你好世界"), "实际：\(greeting.label)")
        XCTAssertTrue(waitForValue(field, equals: "你好世界"), "输入框实际：\(String(describing: field.value))")

        // 与其他控件交互引起的 revision 更新不影响已输入内容。
        app.buttons["form.reverse"].tap()
        XCTAssertTrue(waitForValue(field, equals: "你好世界"))
    }

    private func scrollUntilHittable(_ element: XCUIElement, in app: XCUIApplication, attempts: Int = 15) {
        var remaining = attempts
        while !(element.exists && element.isHittable) && remaining > 0 {
            // 慢速滑动：大字号下快速滑动的惯性会越过目标行（惰性 Form 中越过的行不在无障碍树里）。
            // 滑动 Form 本身（UICollectionView）：iPad 分栏时屏幕中心是编辑区/分隔线，不能滑整屏。
            let form = app.collectionViews.firstMatch
            if form.exists {
                form.swipeUp(velocity: .slow)
            } else {
                app.swipeUp(velocity: .slow)
            }
            remaining -= 1
        }
    }

    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testFormToggleAndReorder() throws {
        let app = launch(engine: "fixture.form")
        app.buttons["run.button"].tap()
        let toggle = app.switches["form.agree"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        // 点击开关本体（SwiftUI Toggle 的可点区域在右侧）。
        let innerSwitch = toggle.switches.firstMatch
        if innerSwitch.exists {
            innerSwitch.tap()
        } else {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        }
        let state = app.staticTexts["form.agree.state"]
        XCTAssertTrue(waitForLabel(state, equals: "状态：已同意"), "实际：\(state.label)")

        let firstBefore = app.staticTexts["form.list/apple"]
        XCTAssertTrue(firstBefore.waitForExistence(timeout: 5))
        let appleY = firstBefore.frame.minY
        app.buttons["form.reverse"].tap()
        let durian = app.staticTexts["form.list/durian"]
        let reordered = NSPredicate { _, _ in durian.exists && durian.frame.minY <= appleY + 1 }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: reordered, object: nil)], timeout: 5), .completed,
                       "反转后榴莲应在第一行")
    }

    func testGalleryPresentationAndNavigation() throws {
        let app = launch(engine: "fixture.gallery")
        app.buttons["run.button"].tap()
        XCTAssertTrue(app.staticTexts["gallery.text"].waitForExistence(timeout: 5))
        attachScreenshot("gallery-top")

        // Slider → setBinding(.double) → 运行时回写文本。
        let slider = app.sliders["gallery.slider"]
        scrollUntilHittable(slider, in: app)
        slider.adjust(toNormalizedSliderPosition: 0.9)
        let sliderValue = app.staticTexts["gallery.slider.value"]
        XCTAssertTrue(waitForLabel(sliderValue, equals: "滑块：9"), "实际：\(sliderValue.label)")

        // Sheet：打开 → 内容可见 → 运行时 dismiss action 关闭。
        let sheetButton = app.buttons["gallery.sheet.button"]
        scrollUntilHittable(sheetButton, in: app)
        sheetButton.tap()
        let sheetTitle = app.staticTexts["gallery.sheet.title"]
        XCTAssertTrue(sheetTitle.waitForExistence(timeout: 5))
        attachScreenshot("gallery-sheet")
        app.buttons["gallery.sheet.close"].tap()
        XCTAssertTrue(sheetTitle.waitForNonExistence(timeout: 5))

        // Alert：打开 → 点「好」→ 关闭。
        let alertButton = app.buttons["gallery.alert.button"]
        scrollUntilHittable(alertButton, in: app)
        alertButton.tap()
        let alert = app.alerts["提示"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["好"].tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 5))

        // 导航：navigationLink → navigationPush → 运行时推入 destination → 返回 → navigationPop。
        let link = app.buttons["gallery.link"]
        scrollUntilHittable(link, in: app)
        link.tap()
        let detailTitle = app.staticTexts["gallery.detail.title"]
        XCTAssertTrue(detailTitle.waitForExistence(timeout: 5))
        attachScreenshot("gallery-detail")
        let back = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
        XCTAssertTrue(detailTitle.waitForNonExistence(timeout: 5))
        XCTAssertTrue(link.waitForExistence(timeout: 5))

        // 不支持的节点在总览里同样可见。
        let unsupported = app.descendants(matching: .any)["bridge.unsupported.view.Chart"]
        scrollUntilHittable(unsupported, in: app)
        XCTAssertTrue(unsupported.exists)
    }

    func testUnsupportedNodeIsVisible() throws {
        let app = launch(engine: "fixture.unsupported")
        app.buttons["run.button"].tap()
        let placeholder = app.descendants(matching: .any)["bridge.unsupported.view.Canvas"]
        XCTAssertTrue(placeholder.waitForExistence(timeout: 5), "不支持的节点必须显示可见占位")
        XCTAssertTrue(placeholder.label.contains("运行时尚不支持"), "实际：\(placeholder.label)")
    }

    func testAIStatusReportsRealAvailability() throws {
        let app = launch(engine: "fixture.counter")
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
        let record = "[FAIRY-AVAILABILITY-UI] onDevice=\(onDeviceText) pcc=\(cloudCode.label) headline=\(headlineText)"
        print(record)
        let attachment = XCTAttachment(string: record)
        attachment.lifetime = .keepAlways
        add(attachment)

        XCTAssertEqual(cloudCode.label, "pccSDKMissing")
        if onDeviceText != "available" {
            // 不可用时：标题为「AI 当前不可用」，发送按钮禁用（没有任何假响应路径）。
            XCTAssertTrue(headlineText.contains("AI 当前不可用"), "实际：\(headlineText)")
            // Form 是惰性列表：屏幕外的行不在无障碍树中，需要先滚动到位。
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
            // 禁用原因必须是可用性原因，而不是「请输入内容」。
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
}

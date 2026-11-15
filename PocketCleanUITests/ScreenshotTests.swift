import XCTest

final class ScreenshotTests: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name; a.lifetime = .keepAlways
        add(a)
    }

    private func tapIfExists(_ e: XCUIElement, timeout: TimeInterval = 3) {
        if e.waitForExistence(timeout: timeout) { e.tap() }
    }

    func testTour() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-noads"]
        addUIInterruptionMonitor(withDescription: "권한") { alert in
            for l in ["Allow Full Access", "전체 접근 허용", "Allow", "허용", "OK", "확인"] {
                if alert.buttons[l].exists { alert.buttons[l].tap(); return true }
            }
            return false
        }
        app.launch()
        sleep(2)
        shot(app, "01_home_before")

        tapIfExists(app.buttons["사진 접근 허용"])
        app.swipeUp(); app.swipeDown()
        tapIfExists(app.buttons["분석하기"])
        sleep(12)
        app.swipeDown()
        shot(app, "02_home_after")

        app.tabBars.buttons["사진·영상"].tap()
        sleep(1)
        shot(app, "03_media_hub")
        let exact = app.staticTexts["똑같은 사진"].firstMatch
        if exact.waitForExistence(timeout: 3) { exact.tap(); sleep(2); shot(app, "04_exact"); app.navigationBars.buttons.firstMatch.tap() }
        let sim = app.staticTexts["비슷한 사진"].firstMatch
        if sim.waitForExistence(timeout: 3) { sim.tap(); sleep(2); shot(app, "05_similar"); app.navigationBars.buttons.firstMatch.tap() }
        let sw = app.staticTexts["스와이프 정리"].firstMatch
        if sw.waitForExistence(timeout: 3) { sw.tap(); sleep(2); shot(app, "06_swipe"); app.navigationBars.buttons.firstMatch.tap() }

        app.tabBars.buttons["파일"].tap(); sleep(1); shot(app, "07_files")
        app.tabBars.buttons["도구"].tap(); sleep(1); shot(app, "08_tools")
        tapIfExists(app.staticTexts["연락처 정리"])
        tapIfExists(app.buttons["연락처 접근 허용"])
        app.tap()
        sleep(3); shot(app, "09_contacts")
        app.navigationBars.buttons.firstMatch.tap()
        tapIfExists(app.staticTexts["동영상 압축"]); sleep(1); shot(app, "10_compress")
        app.navigationBars.buttons.firstMatch.tap()
        tapIfExists(app.staticTexts["비밀 보관함"]); sleep(1); shot(app, "11_vault")
        app.navigationBars.buttons.firstMatch.tap()

        app.tabBars.buttons["설정"].tap(); sleep(1); shot(app, "12_settings")
        tapIfExists(app.buttons["프리미엄 시작하기"]); sleep(3); shot(app, "13_paywall")
    }
}

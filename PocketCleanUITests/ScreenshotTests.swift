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

    private func back(_ app: XCUIApplication) {
        let close = app.buttons["닫기"]
        if close.exists { close.tap(); sleep(1) }
        let b = app.navigationBars.buttons.element(boundBy: 0)
        if b.exists { b.tap(); sleep(1) }
    }

    private func open(_ app: XCUIApplication, _ title: String) -> Bool {
        let t = app.staticTexts[title].firstMatch
        guard t.waitForExistence(timeout: 4) else { return false }
        t.tap(); sleep(2); return true
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
        // 분석이 끝날 때까지 기다림 (최대 90초)
        let again = app.buttons["다시 분석하기"]
        for _ in 0..<45 { if again.exists && again.isEnabled { break }; sleep(2) }
        sleep(1)
        app.swipeDown()
        shot(app, "S1_home")

        app.tabBars.buttons["사진·영상"].tap(); sleep(1)
        shot(app, "03_media_hub")
        if open(app, "똑같은 사진") { shot(app, "04_exact"); back(app) }
        if open(app, "비슷한 사진") { shot(app, "S2_similar"); back(app) }
        if open(app, "스와이프 정리") { shot(app, "S3_swipe"); back(app) }

        app.tabBars.buttons["파일"].tap(); sleep(1); shot(app, "07_files")

        app.tabBars.buttons["도구"].tap(); sleep(1); shot(app, "08_tools")
        if open(app, "연락처 정리") {
            tapIfExists(app.buttons["연락처 접근 허용"], timeout: 2)
            sleep(3)
            if app.buttons["닫기"].exists { app.buttons["닫기"].tap(); sleep(1) }
            shot(app, "S4_contacts")
            back(app)
        }
        if open(app, "동영상 압축") { shot(app, "S5_compress"); back(app) }
        if open(app, "비밀 보관함") { shot(app, "S6_vault"); back(app) }

        app.tabBars.buttons["설정"].tap(); sleep(1); shot(app, "12_settings")
        tapIfExists(app.staticTexts["프리미엄 시작하기"])
        sleep(5)
        shot(app, "S7_paywall")
    }
}

import XCTest

/// 시뮬레이터에서 앱을 실제로 실행해 주요 화면을 열어 보고 화면을 남긴다.
final class ScreenshotTests: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    private func tapTab(_ app: XCUIApplication, _ index: Int) {
        let b = app.tabBars.buttons.element(boundBy: index)
        if b.waitForExistence(timeout: 5) { b.tap() }
        sleep(1)
    }

    private func run(lang: String, prefix: String) {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-noads", "-AppleLanguages", "(\(lang))", "-AppleLocale", lang == "ko" ? "ko_KR" : "en_US"]
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 15))
        sleep(1)
        shot("\(prefix)_01_home")

        // 문서 열기 (기존 뷰어)
        for (i, f) in ["Report.hwp", "Guide.pdf", "Budget.xlsx"].enumerated() {
            let row = app.buttons["file-\(f)"]
            if !row.waitForExistence(timeout: 4) { app.swipeUp() }
            guard row.waitForExistence(timeout: 4) else { XCTFail("missing \(f)"); continue }
            row.tap()
            sleep(f.hasSuffix(".xlsx") ? 8 : 4)
            shot(String(format: "%@_%02d_%@", prefix, i + 2, f.replacingOccurrences(of: ".", with: "_")))
            if app.state != .runningForeground { XCTFail("crashed on \(f)"); app.launch(); sleep(2); continue }
            if f == "Guide.pdf" {
                let tools = app.buttons["doc-tools"]
                if tools.waitForExistence(timeout: 3) { tools.tap(); sleep(1); shot("\(prefix)_03b_pdf_tools"); app.tap(); sleep(1) }
            }
            let close = app.buttons["close"]
            if close.waitForExistence(timeout: 5) { close.tap() }
            sleep(1)
        }

        // 파일 탭: 받은 파일
        tapTab(app, 1)
        let rec = app.buttons["filter-received"]
        if rec.waitForExistence(timeout: 4) { rec.tap(); sleep(1) }
        shot("\(prefix)_05_files_received")

        // 도구 탭
        tapTab(app, 3)
        shot("\(prefix)_06_tools")

        // 스캔 (시뮬레이터: 예시 쪽)
        tapTab(app, 2)
        sleep(2)
        shot("\(prefix)_07_scan_pages")
        let p1 = app.buttons["page-1"]
        if p1.waitForExistence(timeout: 5) {
            p1.tap(); sleep(3)
            shot("\(prefix)_08_scan_editor")
            app.navigationBars.buttons.element(boundBy: 0).tap(); sleep(1)
        }
        let save = app.buttons["scan-save"]
        if save.waitForExistence(timeout: 4) { save.tap(); sleep(2); shot("\(prefix)_09_scan_save")
            let confirm = app.buttons["scan-save-confirm"]
            if confirm.waitForExistence(timeout: 3) { confirm.tap(); sleep(5); shot("\(prefix)_10_scan_saved_pdf")
                let close = app.buttons["close"]; if close.waitForExistence(timeout: 4) { close.tap(); sleep(1) }
            }
        }
        if app.state != .runningForeground { XCTFail("crashed in scan"); app.launch(); sleep(2) }

        // 구독
        tapTab(app, 0)
        let removeAds = app.buttons["remove-ads"]
        if removeAds.waitForExistence(timeout: 5) {
            removeAds.tap(); sleep(4)
            shot("\(prefix)_11_paywall")
            let c = app.buttons["paywall-close"]; if c.waitForExistence(timeout: 3) { c.tap() }
            sleep(1)
        }
        tapTab(app, 4)
        shot("\(prefix)_12_settings")
        app.terminate()
    }

    func testKorean() { run(lang: "ko", prefix: "ko") }
    func testEnglish() { run(lang: "en", prefix: "en") }
}

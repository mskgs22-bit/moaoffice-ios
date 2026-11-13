import XCTest

/// 시뮬레이터에서 앱을 실제로 실행해 각 문서를 열어 보고 화면을 남긴다.
/// Codemagic 결과(Artifacts)에서 스크린샷을 내려받아 확인한다.
final class ScreenshotTests: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    private func run(lang: String, prefix: String) {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-noads", "-AppleLanguages", "(\(lang))", "-AppleLocale", lang == "ko" ? "ko_KR" : "en_US"]
        app.launch()
        XCTAssertTrue(app.navigationBars["MoaOffice"].waitForExistence(timeout: 15))
        shot("\(prefix)_01_home")

        let files = ["Report.hwp", "Report.hwpx", "Guide.pdf", "Letter.docx", "Budget.xlsx", "Orders.csv"]
        for (i, f) in files.enumerated() {
            let row = app.buttons["file-\(f)"]
            if !row.waitForExistence(timeout: 5) { app.swipeUp() }
            guard row.waitForExistence(timeout: 5) else { XCTFail("missing \(f)"); continue }
            row.tap()
            sleep(4)
            shot(String(format: "%@_%02d_%@", prefix, i + 2, f.replacingOccurrences(of: ".", with: "_")))
            let close = app.buttons["close"]
            if close.waitForExistence(timeout: 5) { close.tap() }
            sleep(1)
        }

        app.buttons["settings"].tap()
        sleep(1)
        shot("\(prefix)_08_settings")
        app.terminate()
    }

    func testKorean() { run(lang: "ko", prefix: "ko") }
    func testEnglish() { run(lang: "en", prefix: "en") }
}

import Foundation
import UIKit
import WebKit
import Capacitor

/// 앱 화면(인쇄용 레이아웃)을 iOS 기본 인쇄(AirPrint) 화면으로 보냅니다. (안드로이드 WebPrintPlugin.java 와 같은 이름·메서드)
@objc(WebPrintPlugin)
public class WebPrintPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "WebPrintPlugin"
    public let jsName = "WebPrint"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "print", returnType: CAPPluginReturnPromise)
    ]

    @objc func print(_ call: CAPPluginCall) {
        let name = call.getString("name") ?? "PocketScanner"
        DispatchQueue.main.async {
            guard let webView = self.bridge?.webView else {
                call.reject("WebView를 찾을 수 없어요")
                return
            }
            let info = UIPrintInfo(dictionary: nil)
            info.outputType = .general
            info.jobName = name
            let pc = UIPrintInteractionController.shared
            pc.printInfo = info
            pc.printFormatter = webView.viewPrintFormatter()
            pc.present(animated: true) { _, completed, error in
                if let error = error {
                    call.reject(error.localizedDescription)
                } else {
                    call.resolve(["completed": completed])
                }
            }
        }
    }
}

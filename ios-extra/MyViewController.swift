import UIKit
import Capacitor

/// 앱 전용 플러그인(WebPrint)을 등록하는 메인 화면
class MyViewController: CAPBridgeViewController {
    override open func capacitorDidLoad() {
        bridge?.registerPluginInstance(WebPrintPlugin())
    }
}

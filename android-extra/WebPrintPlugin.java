package kr.pocketscanner.app;

import android.content.Context;
import android.print.PrintAttributes;
import android.print.PrintDocumentAdapter;
import android.print.PrintManager;
import android.webkit.WebView;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;

/** 앱 화면(인쇄용 레이아웃)을 안드로이드 기본 인쇄 화면으로 보냅니다. */
@CapacitorPlugin(name = "WebPrint")
public class WebPrintPlugin extends Plugin {
    @PluginMethod
    public void print(PluginCall call) {
        final String name = call.getString("name", "PocketScanner");
        getActivity().runOnUiThread(() -> {
            try {
                WebView webView = getBridge().getWebView();
                PrintManager pm = (PrintManager) getActivity().getSystemService(Context.PRINT_SERVICE);
                PrintDocumentAdapter adapter = webView.createPrintDocumentAdapter(name);
                pm.print(name, adapter, new PrintAttributes.Builder()
                        .setMediaSize(PrintAttributes.MediaSize.ISO_A4)
                        .build());
                call.resolve();
            } catch (Exception e) {
                call.reject(e.getMessage());
            }
        });
    }
}

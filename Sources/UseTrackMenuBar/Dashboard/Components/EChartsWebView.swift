// UseTrack — Dashboard
// EChartsWebView: WKWebView + ECharts 通用封装

import SwiftUI
import WebKit

struct EChartsWebView: NSViewRepresentable {
    let htmlFileName: String  // "timeline" or "heatmap"
    let data: String          // JSON string

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")  // Transparent background

        // Load HTML template from bundle
        if let htmlURL = Bundle.module.url(forResource: htmlFileName,
                                            withExtension: "html",
                                            subdirectory: "ECharts") {
            webView.loadFileURL(htmlURL, allowingReadAccessTo: htmlURL.deletingLastPathComponent())
        }

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard !data.isEmpty else { return }
        if context.coordinator.isReady {
            let js = "updateChart(\(data));"
            webView.evaluateJavaScript(js, completionHandler: nil)
        } else {
            context.coordinator.pendingData = data
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator: NSObject, WKNavigationDelegate {
        var pendingData: String?
        var isReady = false

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isReady = true
            if let data = pendingData {
                let js = "updateChart(\(data));"
                webView.evaluateJavaScript(js, completionHandler: nil)
                pendingData = nil
            }
        }
    }
}

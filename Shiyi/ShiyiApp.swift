import SwiftUI
import WebKit

@main
struct ShiyiApp: App {
    var body: some Scene {
        WindowGroup {
            WebView(url: URL(string: "http://172.16.2.89:8899")!)
                .edgesIgnoringSafeArea(.all)
        }
    }
}

struct WebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.scrollView.bounces = false
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

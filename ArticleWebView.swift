import SwiftUI
import WebKit

struct ArticleWebView: NSViewRepresentable {
    let url: URL
    @Binding var isLoading: Bool
    @Binding var canGoBack: Bool
    @Binding var canGoForward: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = true
        configuration.defaultWebpagePreferences = preferences
        configuration.preferences.isFraudulentWebsiteWarningEnabled = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        context.coordinator.currentRequestedURL = url
        let request = URLRequest(url: url)
        webView.load(request)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        if context.coordinator.currentRequestedURL != url {
            context.coordinator.currentRequestedURL = url
            let request = URLRequest(url: url)
            nsView.load(request)
        }
    }

    @MainActor
    class Coordinator: NSObject, WKNavigationDelegate {
        var parent: ArticleWebView
        weak var webView: WKWebView?
        var currentRequestedURL: URL?

        init(_ parent: ArticleWebView) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            guard let requestURL = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }

            // 1. Strict scheme policy: only HTTPS and HTTP
            guard let scheme = requestURL.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
                decisionHandler(.cancel)
                return
            }

            // 2. Prevent navigation to local or intranet IP hosts
            if let host = requestURL.host {
                let validationResult = IPAddressValidator.validateHost(host)
                switch validationResult {
                case .allowed:
                    break
                case .blocked, .unresolvable:
                    decisionHandler(.cancel)
                    return
                }
            }

            // 3. Delegate target="_blank" popups to external default browser
            if navigationAction.targetFrame == nil {
                NSWorkspace.shared.open(requestURL)
                decisionHandler(.cancel)
                return
            }

            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            DispatchQueue.main.async {
                self.parent.isLoading = true
                self.parent.canGoBack = webView.canGoBack
                self.parent.canGoForward = webView.canGoForward
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.async {
                self.parent.isLoading = false
                self.parent.canGoBack = webView.canGoBack
                self.parent.canGoForward = webView.canGoForward
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async {
                self.parent.isLoading = false
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async {
                self.parent.isLoading = false
            }
        }
    }
}

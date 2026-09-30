import SwiftUI
import WebKit

enum WebNavigationAction: Equatable {
    case goBack
    case goForward
    case reload
}

struct ArticleWebView: NSViewRepresentable {
    let url: URL
    var allowHTTP: Bool
    @Binding var isLoading: Bool
    @Binding var canGoBack: Bool
    @Binding var canGoForward: Bool
    @Binding var action: WebNavigationAction?
    @Binding var loadError: String?

    init(
        url: URL,
        allowHTTP: Bool = false,
        isLoading: Binding<Bool>,
        canGoBack: Binding<Bool>,
        canGoForward: Binding<Bool>,
        action: Binding<WebNavigationAction?> = .constant(nil),
        loadError: Binding<String?> = .constant(nil)
    ) {
        self.url = url
        self.allowHTTP = allowHTTP
        self._isLoading = isLoading
        self._canGoBack = canGoBack
        self._canGoForward = canGoForward
        self._action = action
        self._loadError = loadError
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Do not inherit publisher service workers or cookies from earlier previews.
        configuration.websiteDataStore = .nonPersistent()
        let preferences = WKWebpagePreferences()
        // Public WebKit proxies do not constrain WebRTC sockets created by publisher scripts.
        preferences.allowsContentJavaScript = false
        configuration.defaultWebpagePreferences = preferences
        configuration.preferences.isFraudulentWebsiteWarningEnabled = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        context.coordinator.currentRequestedURL = url
        context.coordinator.prepareGateway(webView)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        if context.coordinator.parent.allowHTTP != allowHTTP {
            context.coordinator.requestGeneration = UUID()
        }
        context.coordinator.parent = self
        if context.coordinator.currentRequestedURL != url {
            context.coordinator.requestGeneration = UUID()
            nsView.stopLoading()
            context.coordinator.currentRequestedURL = url
            if context.coordinator.gatewayReady { nsView.load(URLRequest(url: url)) }
        }
        if let currentAction = action {
            switch currentAction {
            case .goBack:
                if nsView.canGoBack { nsView.goBack() }
            case .goForward:
                if nsView.canGoForward { nsView.goForward() }
            case .reload:
                if context.coordinator.gatewayReady { nsView.reload() }
                else { context.coordinator.prepareGateway(nsView) }
            }
            DispatchQueue.main.async {
                self.action = nil
            }
        }
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        coordinator.gatewayTask?.cancel()
        coordinator.requestGeneration = UUID()
        nsView.stopLoading()
        nsView.navigationDelegate = nil
        coordinator.webView = nil
    }

    @MainActor
    class Coordinator: NSObject, WKNavigationDelegate {
        var parent: ArticleWebView
        weak var webView: WKWebView?
        var currentRequestedURL: URL?
        var requestGeneration = UUID()
        private var activeNavigation: WKNavigation?
        var gatewayReady = false
        var gatewayTask: Task<Void, Never>?

        func prepareGateway(_ view: WKWebView) {
            gatewayTask?.cancel()
            parent.isLoading = true
            gatewayTask = Task { [weak self, weak view] in
                do {
                    let proxy = try await NetworkBoundaryProxy.shared.configuration()
                    let rules = try await WebPreviewPolicy.contentRules()
                    guard !Task.isCancelled, let self, let view, self.webView === view else { return }
                    view.configuration.userContentController.add(rules)
                    view.configuration.websiteDataStore.proxyConfigurations = [proxy]
                    self.gatewayReady = true
                    self.currentRequestedURL = self.parent.url
                    view.load(URLRequest(url: self.parent.url))
                } catch {
                    guard !Task.isCancelled, let self, let view, self.webView === view else { return }
                    self.parent.isLoading = false
                    self.parent.loadError = "The protected network gateway could not start. Try reloading."
                }
            }
        }

        init(_ parent: ArticleWebView) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let requestURL = navigationAction.request.url else { return .cancel }
            let generation = requestGeneration
            let allowHTTP = parent.allowHTTP
            do {
                // Navigation delegates cover documents, not WebKit subresource traffic.
                try await SecureHTTPClient.shared.validateDestination(requestURL, allowHTTP: allowHTTP)
                guard !Task.isCancelled, self.webView === webView,
                      requestGeneration == generation else { return .cancel }
                if navigationAction.targetFrame == nil {
                    NSWorkspace.shared.open(requestURL)
                    return .cancel
                }
                return .allow
            } catch {
                guard self.webView === webView, requestGeneration == generation else { return .cancel }
                parent.loadError = "This address was blocked by the app’s network policy. Open the publisher in your browser if needed."
                parent.isLoading = false
                return .cancel
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            guard self.webView === webView else { return }
            activeNavigation = navigation
            parent.loadError = nil
            parent.isLoading = true
            updateHistory(webView)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard self.webView === webView, navigation === activeNavigation else { return }
            parent.isLoading = false
            updateHistory(webView)
        }

        private func updateHistory(_ webView: WKWebView) {
            parent.canGoBack = webView.canGoBack
            parent.canGoForward = webView.canGoForward
        }

        private func didFail(_ webView: WKWebView, navigation: WKNavigation?, error: Error) {
            guard self.webView === webView, navigation === activeNavigation else { return }
            parent.isLoading = false
            if (error as NSError).code != NSURLErrorCancelled {
                parent.loadError = "The publisher page could not be loaded. Try reloading or return to Reader."
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            didFail(webView, navigation: navigation, error: error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            didFail(webView, navigation: navigation, error: error)
        }
    }
}

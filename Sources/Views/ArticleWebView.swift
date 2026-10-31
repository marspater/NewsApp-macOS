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

    static func isValidDataStore(_ dataStore: WKWebsiteDataStore) -> Bool {
        !dataStore.isPersistent
    }

    static func makeConfiguration(dataStore: WKWebsiteDataStore = .nonPersistent()) -> WKWebViewConfiguration {
        guard isValidDataStore(dataStore) else {
            preconditionFailure("Article web view must use a non-persistent website data store for origin isolation")
        }
        let configuration = WKWebViewConfiguration()
        // Do not inherit publisher service workers or cookies from earlier previews.
        configuration.websiteDataStore = dataStore
        let preferences = WKWebpagePreferences()
        // Public WebKit proxies do not constrain WebRTC sockets created by publisher scripts.
        preferences.allowsContentJavaScript = false
        configuration.defaultWebpagePreferences = preferences
        configuration.preferences.isFraudulentWebsiteWarningEnabled = true
        return configuration
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = Self.makeConfiguration()
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
                // A reload the reader asked for may retry a failure once more.
                context.coordinator.hasRetriedProvisionalFailure = false
                context.coordinator.prepareGateway(nsView) { [weak nsView] in
                    guard let nsView else { return }
                    // After a blocked or failed first load there is no page to reload; request the story again.
                    if nsView.backForwardList.currentItem == nil {
                        DispatchQueue.main.async { self.loadError = nil }
                        nsView.load(URLRequest(url: url))
                    } else {
                        nsView.reload()
                    }
                }
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
        private var configuredPort: UInt16?
        private var contentRulesConfigured = false
        /// A failed provisional load retries once after re-checking the gateway; the flag clears on a finished
        /// page or a reload the reader asks for, never on the retry itself, so a persistent failure cannot loop.
        var hasRetriedProvisionalFailure = false

        func prepareGateway(_ view: WKWebView, then onReady: (@MainActor () -> Void)? = nil) {
            gatewayTask?.cancel()
            parent.isLoading = true
            gatewayTask = Task { [weak self, weak view] in
                do {
                    let port = try await NetworkBoundaryProxy.shared.port()
                    let needsRules = !(self?.contentRulesConfigured ?? true)
                    let rules = needsRules ? try await WebPreviewPolicy.contentRules() : nil
                    guard !Task.isCancelled, let self, let view, self.webView === view else { return }
                    if let rules {
                        view.configuration.userContentController.add(rules)
                        self.contentRulesConfigured = true
                    }
                    if WebPreviewPolicy.needsProxyRefresh(configuredPort: self.configuredPort, currentPort: port) {
                        let proxy = NetworkBoundaryProxy.configuration(port: port)
                        view.configuration.websiteDataStore.proxyConfigurations = [proxy]
                        self.configuredPort = port
                    }
                    self.gatewayReady = true
                    if let onReady {
                        onReady()
                    } else {
                        self.currentRequestedURL = self.parent.url
                        view.load(URLRequest(url: self.parent.url))
                    }
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

        func webView(
            _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            guard let requestURL = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            let generation = requestGeneration
            let allowHTTP = parent.allowHTTP
            let opensNewWindow = navigationAction.targetFrame == nil
            Task { @MainActor [weak self, weak webView] in
                do {
                    // Navigation delegates cover documents, not WebKit subresource traffic.
                    try await SecureHTTPClient.shared.validateDestination(requestURL, allowHTTP: allowHTTP)
                    guard !Task.isCancelled, let self, let webView, self.webView === webView,
                        self.requestGeneration == generation
                    else {
                        decisionHandler(.cancel)
                        return
                    }
                    if opensNewWindow {
                        if let url = WebLink.url(requestURL.absoluteString) { NSWorkspace.shared.open(url) }
                        decisionHandler(.cancel)
                        return
                    }
                    decisionHandler(.allow)
                } catch {
                    if let self, let webView, self.webView === webView, self.requestGeneration == generation {
                        self.parent.loadError =
                            "This address was blocked by the app’s network policy. Open the publisher in your browser if needed."
                        self.parent.isLoading = false
                    }
                    decisionHandler(.cancel)
                }
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
            hasRetriedProvisionalFailure = false
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

        func webView(
            _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error
        ) {
            guard self.webView === webView, navigation === activeNavigation else { return }
            if (error as NSError).code != NSURLErrorCancelled, !hasRetriedProvisionalFailure {
                hasRetriedProvisionalFailure = true
                prepareGateway(webView) { [weak self, weak webView] in
                    guard let self, let webView, self.webView === webView else { return }
                    if webView.backForwardList.currentItem == nil {
                        self.parent.loadError = nil
                        webView.load(URLRequest(url: self.parent.url))
                    } else {
                        webView.reload()
                    }
                }
                return
            }
            didFail(webView, navigation: navigation, error: error)
        }
    }
}

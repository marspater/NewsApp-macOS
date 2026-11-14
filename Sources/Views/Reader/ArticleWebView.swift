// Copyright 2026 Mars Pater
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import SwiftUI
import WebKit

/// A history or reload request from the web toolbar, carried out once and then cleared.
enum WebNavigationAction: Equatable {
    /// Goes back in the page history, when there is a page to go back to.
    case goBack
    /// Goes forward in the page history, when there is a page to go forward to.
    case goForward
    /// Reloads the page, or requests the story again when the first load failed; a failure may then retry once more.
    case reload
}

/// The publisher's page in a web view with an ephemeral data store, JavaScript off and content rules applied, loaded
/// only through the protected network gateway; every document request is validated first, and a link that opens a new
/// window goes to the browser.
struct ArticleWebView: NSViewRepresentable {
    /// The publisher page to show; a change stops the current load and requests the new address.
    let url: URL
    /// Allows plain `http` destinations, from the setting for `http` feeds.
    var allowHTTP: Bool
    /// Set while the gateway starts or a page loads.
    @Binding var isLoading: Bool
    /// Whether the page history can go back.
    @Binding var canGoBack: Bool
    /// Whether the page history can go forward.
    @Binding var canGoForward: Bool
    /// The toolbar's pending request; the view sets it back to nil once handled.
    @Binding var action: WebNavigationAction?
    /// Why the page did not load, in words for the reader; nil while nothing failed.
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

    /// Whether the data store keeps nothing on disk, as the web view requires.
    static func isValidDataStore(_ dataStore: WKWebsiteDataStore) -> Bool {
        !dataStore.isPersistent
    }

    /// A web view configuration with a non-persistent data store, JavaScript off and fraudulent-site warnings on; a
    /// persistent store is a programming error and stops the app.
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

    /// The web view's navigation delegate: validates each document request and keeps the bindings in step with the
    /// page.
    @MainActor
    class Coordinator: NSObject, WKNavigationDelegate {
        /// The view whose bindings the coordinator updates; replaced on every update.
        var parent: ArticleWebView
        /// The web view the coordinator serves; callbacks from any other are ignored.
        weak var webView: WKWebView?
        /// The address last requested for the story.
        var currentRequestedURL: URL?
        /// Changes when the address or the `http` setting changes, so validations started for the old request are
        /// dropped.
        var requestGeneration = UUID()
        private var activeNavigation: WKNavigation?
        /// Whether the gateway's proxy and content rules are in place, so the page may load.
        var gatewayReady = false
        /// The running gateway preparation; a new one cancels it.
        var gatewayTask: Task<Void, Never>?
        private var configuredPort: UInt16?
        private var contentRulesConfigured = false
        /// A failed provisional load retries once after re-checking the gateway; the flag clears on a finished
        /// page or a reload the reader asks for, never on the retry itself, so a persistent failure cannot loop.
        var hasRetriedProvisionalFailure = false

        /// Starts or reuses the protected network gateway, adds the content rules once and points the data store's
        /// proxy at the gateway's port, then runs `onReady` or loads the story; a failure shows a load error.
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
            let isMainFrame = WebPreviewPolicy.isMainFrame(targetFrameIsMain: navigationAction.targetFrame?.isMainFrame)
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
                    if let message = WebPreviewPolicy.refusalMessage(isMainFrame: isMainFrame), let self, let webView,
                        self.webView === webView, self.requestGeneration == generation
                    {
                        self.parent.loadError = message
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
                // Retry the address that failed, never the page still in history: with story A shown, a failed
                // load of story B must not reload A under B's reader.
                let failed = ((error as NSError).userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? parent.url
                let story = parent.url
                prepareGateway(webView) { [weak self, weak webView] in
                    // The reader may have moved to another story while the gateway was refreshed.
                    guard let self, let webView, self.webView === webView, self.parent.url == story else { return }
                    self.parent.loadError = nil
                    webView.load(URLRequest(url: failed))
                }
                return
            }
            didFail(webView, navigation: navigation, error: error)
        }
    }
}

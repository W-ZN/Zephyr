import AppKit
import WebKit

/// Created only by the explicit page-snapshot action. The card keeps a bitmap after capture,
/// never a running browser. One render across all document windows, with an eight-second deadline.
@MainActor
final class LinkPreviewPageRenderer: NSObject, WKNavigationDelegate, WKUIDelegate {
    struct Snapshot {
        let image: NSImage
        let title: String
        let text: String
    }

    private static weak var active: LinkPreviewPageRenderer?
    private static var rules: Task<WKContentRuleList, Error>?
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<Snapshot, Error>?
    private var preparation: Task<Void, Never>?
    private var deadline: DispatchWorkItem?
    private var capture: DispatchWorkItem?
    private var captureTime: DispatchTime?
    private var capturing = false
    private var checkingPage = false
    private var navigationGeneration = 0

    func render(_ url: URL, in host: NSView) async throws -> Snapshot {
        try Task.checkCancellation()
        Self.active?.cancel()
        Self.active = self
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let deadline = DispatchWorkItem { [weak self] in self?.finish(.failure(URLError(.timedOut))) }
                self.deadline = deadline
                DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: deadline)
                preparation = Task { @MainActor [weak self, weak host] in
                    do {
                        let rules = try await Self.contentRules()
                        guard let self, let host, self.continuation != nil, !Task.isCancelled else { return }
                        let configuration = WKWebViewConfiguration()
                        configuration.websiteDataStore = .nonPersistent()
                        configuration.mediaTypesRequiringUserActionForPlayback = .all
                        configuration.userContentController.add(rules)
                        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1024, height: 640), configuration: configuration)
                        view.navigationDelegate = self
                        view.uiDelegate = self
                        host.addSubview(view, positioned: .below, relativeTo: nil)
                        self.webView = view
                        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
                        request.setValue("text/html,application/xhtml+xml;q=0.9", forHTTPHeaderField: "Accept")
                        view.load(request)
                    } catch {
                        self?.finish(.failure(error))
                    }
                }
            }
        }, onCancel: { [weak self] in Task { @MainActor in self?.cancel() } })
    }

    func cancel() { finish(.failure(CancellationError())) }

    private static func contentRules() async throws -> WKContentRuleList {
        if rules == nil {
            rules = Task {
                let store = WKContentRuleListStore.default()!
                let identifier = "zephyr-page-snapshot-v1"
                // Keep page layout/images/scripts, omit media, downloadable fonts and child frames.
                let json = #"[{"trigger":{"url-filter":".*","resource-type":["media","font","popup"]},"action":{"type":"block"}},{"trigger":{"url-filter":".*","load-context":["child-frame"]},"action":{"type":"block"}}]"#
                guard let compiled = try await store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) else { throw URLError(.cannotDecodeContentData) }
                return compiled
            }
        }
        return try await rules!.value
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let allowed = action.targetFrame?.isMainFrame == true && action.navigationType == .other
            && ["http", "https"].contains(action.request.url?.scheme?.lowercased() ?? "")
            && action.request.httpMethod == "GET"
        decisionHandler(allowed ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        guard response.isForMainFrame, let http = response.response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              ["text/html", "application/xhtml+xml", "text/plain"].contains(response.response.mimeType ?? ""),
              response.response.expectedContentLength <= 2 << 20 else {
            decisionHandler(.cancel)
            finish(.failure(URLError(.badServerResponse)))
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        navigationGeneration += 1
        checkingPage = false
        capture?.cancel()
        capture = nil
        captureTime = nil
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { scheduleCapture(after: 3) }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { scheduleCapture(after: 1) }

    private func scheduleCapture(after seconds: Double) {
        guard continuation != nil, !capturing, !checkingPage else { return }
        let time = DispatchTime.now() + seconds
        if let captureTime, time.uptimeNanoseconds >= captureTime.uptimeNanoseconds { return }
        capture?.cancel()
        captureTime = time
        // Capture the first viewport without waiting indefinitely for slow associated resources.
        let work = DispatchWorkItem { [weak self] in self?.takeSnapshot() }
        capture = work
        DispatchQueue.main.asyncAfter(deadline: time, execute: work)
    }

    private func takeSnapshot() {
        guard let webView, continuation != nil, !capturing, !checkingPage else { return }
        checkingPage = true
        captureTime = nil
        let generation = navigationGeneration
        // A committed client-rendered shell may still be blank. Poll only inside the overall deadline.
        let script = "Boolean(document.body && (document.body.innerText.trim().length || Array.from(document.images).some(image => image.complete && image.naturalWidth > 0) || document.querySelector('svg,canvas')))"
        webView.evaluateJavaScript(script) { [weak self, weak webView] value, error in
            guard let self, let webView, self.continuation != nil, self.navigationGeneration == generation else { return }
            self.checkingPage = false
            if let error { self.finish(.failure(error)); return }
            guard value as? Bool == true else { self.scheduleCapture(after: 0.5); return }
            self.captureImage(from: webView, generation: generation)
        }
    }

    private func captureImage(from webView: WKWebView, generation: Int) {
        guard continuation != nil, !capturing else { return }
        capturing = true
        let configuration = WKSnapshotConfiguration()
        configuration.rect = webView.bounds
        // WebKit takes points here; Retina backing must still fit the 1280-pixel budget.
        let scale = webView.window?.backingScaleFactor ?? 1
        configuration.snapshotWidth = NSNumber(value: min(1_280 / scale, webView.bounds.width))
        webView.takeSnapshot(with: configuration) { [weak self, weak webView] image, error in
            guard let self, self.continuation != nil, let webView else { return }
            guard self.navigationGeneration == generation else { self.finish(.failure(URLError(.cannotDecodeContentData))); return }
            guard let image else { self.finish(.failure(error ?? URLError(.cannotDecodeContentData))); return }
            let title = String((webView.title ?? webView.url?.host ?? "").prefix(160))
            webView.evaluateJavaScript("document.body ? document.body.innerText.slice(0,8192) : ''") { [weak self] value, _ in
                guard let self, self.continuation != nil else { return }
                guard self.navigationGeneration == generation else { self.finish(.failure(URLError(.cannotDecodeContentData))); return }
                self.finish(.success(Snapshot(image: image, title: title, text: value as? String ?? "")))
            }
        }
    }

    private func finish(_ result: Result<Snapshot, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        preparation?.cancel()
        preparation = nil
        deadline?.cancel()
        deadline = nil
        capture?.cancel()
        capture = nil
        captureTime = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView?.removeFromSuperview()
        webView = nil
        if Self.active === self { Self.active = nil }
        continuation.resume(with: result)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finish(.failure(URLError(.cannotDecodeContentData))) }
    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) { completionHandler() }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) { completionHandler(false) }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) { completionHandler(nil) }
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) { decisionHandler(.deny) }
    @available(macOS 27.0, *)
    func webView(_ webView: WKWebView, requestGeolocationPermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, decisionHandler: @escaping (WKPermissionDecision) -> Void) { decisionHandler(.deny) }
}

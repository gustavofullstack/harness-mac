import AppKit
import WebKit

/// Hosts the harness web UI and keeps it on loopback: any other destination opens in the
/// user's browser instead of inside the app.
@MainActor
final class WebController: NSViewController, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    private let automation: Automation?
    private var origin: URL?
    private var connectAttempts = 0
    private var titleObservation: NSKeyValueObservation?
    private let overlay = NSStackView()

    init(automation: Automation?) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.preferences.isElementFullscreenEnabled = true
        config.applicationNameForUserAgent = "HarnessMac"
        // dsh always runs on this Mac, so offline caching buys nothing, and a worker left by a
        // previous server (other token, maybe other build) fails navigations with "Could not connect".
        config.userContentController.addUserScript(WKUserScript(
            source: "if (navigator.serviceWorker) { navigator.serviceWorker.getRegistrations().then(rs => rs.forEach(r => r.unregister())); navigator.serviceWorker.register = () => Promise.reject(new Error('Service workers are disabled in Harness')); }",
            injectionTime: .atDocumentStart, forMainFrameOnly: false))
        if automation != nil {
            // Off-screen windows are occluded and WebKit pauses animations there; without this
            // the snapshot shows elements frozen at the first frame of their fade-in.
            config.userContentController.addUserScript(WKUserScript(
                source: "document.documentElement.appendChild(Object.assign(document.createElement('style'),{textContent:'*,*::before,*::after{animation:none!important;transition:none!important}'}))",
                injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsMagnification = true
        webView.isInspectable = true
        self.automation = automation
        super.init(nibName: nil, bundle: nil)
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1280, height: 820))
        for sub in [webView, overlay] as [NSView] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(sub)
        }
        overlay.orientation = .vertical
        overlay.alignment = .centerX
        overlay.spacing = 14
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            webView.topAnchor.constraint(equalTo: root.topAnchor),
            webView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            overlay.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            overlay.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            overlay.widthAnchor.constraint(lessThanOrEqualToConstant: 520),
        ])
        view = root
        titleObservation = webView.observe(\.title, options: [.new]) { [weak self] web, _ in
            Task { @MainActor in
                self?.view.window?.title = (web.title?.isEmpty == false ? web.title : nil) ?? "DSH"
            }
        }
    }

    // MARK: - States

    func showLoading(_ text: String) {
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.startAnimation(nil)
        setOverlay([spinner, label(text, secondary: true)])
    }

    func showError(_ text: String, retry: @escaping () -> Void) {
        let retryButton = NSButton(title: "Try Again", target: nil, action: nil)
        retryButton.bezelStyle = .push
        retryButton.keyEquivalent = "\r"
        retryButton.onAction = retry
        let docs = NSButton(title: "Open the Quickstart", target: NSApp.delegate, action: #selector(AppDelegate.openDocs(_:)))
        docs.bezelStyle = .push
        let icon = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)!)
        icon.symbolConfiguration = .init(pointSize: 34, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        let buttons = NSStackView(views: [docs, retryButton])
        setOverlay([icon, label("DeepSeek Harness could not start", secondary: false), label(text, secondary: true), buttons])
    }

    /// Every launch serves a fresh dsh (new token, maybe a new build), so workers and caches from
    /// the previous one are dropped before loading. Local storage (current session, drafts) is kept.
    func load(_ url: URL) async {
        origin = url
        connectAttempts = 0
        await dropStaleData()
        webView.load(URLRequest(url: url))
    }

    private func dropStaleData() async {
        let stale: Set<String> = [WKWebsiteDataTypeServiceWorkerRegistrations, WKWebsiteDataTypeFetchCache,
                                  WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache]
        await webView.configuration.websiteDataStore.removeData(ofTypes: stale, modifiedSince: .distantPast)
    }

    private func setOverlay(_ views: [NSView]) {
        overlay.arrangedSubviews.forEach { $0.removeFromSuperview() }
        views.forEach(overlay.addArrangedSubview)
        overlay.isHidden = views.isEmpty
        webView.isHidden = !views.isEmpty
    }

    private func label(_ text: String, secondary: Bool) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.alignment = .center
        field.isSelectable = true
        field.font = secondary ? .systemFont(ofSize: 12) : .systemFont(ofSize: 15, weight: .semibold)
        field.textColor = secondary ? .secondaryLabelColor : .labelColor
        return field
    }

    // MARK: - Navigation policy

    private func isHarness(_ url: URL?) -> Bool {
        guard let url, let origin else { return url?.scheme == "about" }
        return url.scheme == origin.scheme && url.host == origin.host && url.port == origin.port
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        if isHarness(action.request.url) || action.request.url?.scheme == "blob" || action.request.url?.scheme == "data" {
            return .allow
        }
        if let url = action.request.url, ["http", "https", "mailto"].contains(url.scheme ?? "") {
            NSWorkspace.shared.open(url)
        }
        return .cancel
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url, ["http", "https", "mailto"].contains(url.scheme ?? "") {
            NSWorkspace.shared.open(url)
        }
        return nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        setOverlay([])
        if let automation { Task { await runAutomation(automation) } }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        // Retry briefly: the socket may still be coming up, or a stale worker is being dropped.
        if (error as NSError).code == NSURLErrorCannotConnectToHost, connectAttempts < 10, let origin {
            connectAttempts += 1
            Task {
                await dropStaleData()
                try? await Task.sleep(for: .milliseconds(300 * connectAttempts))
                webView.load(URLRequest(url: origin))
            }
            return
        }
        showError(error.localizedDescription) { [weak self] in self?.webView.reload() }
        automation?.fail(error.localizedDescription)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { webView.reload() }

    // MARK: - Panels and dialogs

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        return await panel.begin() == .OK ? panel.urls : nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async {
        _ = alert(message, buttons: ["OK"]).runModal()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async -> Bool {
        alert(message, buttons: ["OK", "Cancel"]).runModal() == .alertFirstButtonReturn
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo) async -> String? {
        let a = alert(prompt, buttons: ["OK", "Cancel"])
        let field = NSTextField(string: defaultText ?? "")
        field.frame.size.width = 280
        a.accessoryView = field
        return a.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    private func alert(_ text: String, buttons: [String]) -> NSAlert {
        let a = NSAlert()
        a.messageText = text
        buttons.forEach { a.addButton(withTitle: $0) }
        return a
    }

    // MARK: - Headless automation

    private func runAutomation(_ job: Automation) async {
        try? await Task.sleep(for: .seconds(job.delay))
        if let script = job.script, !script.isEmpty {
            do { _ = try await webView.evaluateJavaScript(script + "\n;0") }
            catch { print("script error: \(error.localizedDescription)") }
            try? await Task.sleep(for: .seconds(job.delay))
        }
        let text = (try? await webView.evaluateJavaScript("document.body.innerText")) as? String ?? ""
        print("title: \(webView.title ?? "")")
        print("text: \(text.prefix(1500))")
        guard let image = try? await webView.takeSnapshot(configuration: nil),
              let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            job.fail("snapshot failed")
        }
        do { try png.write(to: URL(fileURLWithPath: job.snapshotPath)) } catch { job.fail(error.localizedDescription) }
        print("snapshot: \(job.snapshotPath)")
        NSApp.terminate(nil)
    }
}

private extension NSButton {
    /// Closure-based action, so views do not need a target object per button.
    var onAction: (() -> Void)? {
        get { (target as? ClosureTarget)?.handler }
        set {
            let t = newValue.map(ClosureTarget.init)
            objc_setAssociatedObject(self, &ClosureTarget.key, t, .OBJC_ASSOCIATION_RETAIN)
            target = t
            action = #selector(ClosureTarget.fire)
        }
    }
}

private final class ClosureTarget: NSObject {
    nonisolated(unsafe) static var key = 0
    let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func fire() { handler() }
}

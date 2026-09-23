import AppKit
import DSHKit
import WebKit

/// Hosts the harness web UI and keeps it on loopback: any other destination opens in the
/// user's browser instead of inside the app.
@MainActor
final class WebController: NSViewController, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    /// The web UI's own page color, so the window never flashes a different shade around it.
    static let pageBackground = NSColor(srgbRed: 21 / 255, green: 21 / 255, blue: 23 / 255, alpha: 1)

    let webView: DragWebView
    private let automation: Automation?
    private var origin: URL?
    private var connectAttempts = 0
    private var staleDataCleanup: Task<Void, Never>?
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
        // The title bar is transparent over the page: empty parts of the page's top 40 pt move the
        // window, and a double click zooms it, as in any Mac app.
        config.userContentController.addUserScript(WKUserScript(source: """
            addEventListener('mousedown', e => {
              if (e.button !== 0 || e.clientY > 40 || e.target.closest('button,a,input,textarea,select,summary,label,[contenteditable],[draggable=true],[role=button],[role=link],[role=tab],[role=menuitem],[role=option],[role=switch],[role=checkbox],[role=textbox],[role=slider]')) return;
              webkit.messageHandlers.dshWindow.postMessage(e.detail === 2 ? 'zoom' : 'drag');
            }, true);
            """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        // Room for the traffic lights above the sidebar, expanded or collapsed to its rail. Matched by
        // the CSS-module name stems, so a renamed class only brings back the overlap, nothing breaks.
        config.userContentController.addUserScript(WKUserScript(source: """
            document.documentElement.appendChild(Object.assign(document.createElement('style'), {textContent:
              '[class*="_sidebarCol"] [class*="_root"][class*="_quietBars"]{padding-top:16px}[class*="_sidebarCol"] [class*="_collapsed"] [class*="_logoRow"]{margin-top:16px}'}));
            """, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        // dsh names reasoning levels after their ids; the app can show other names (Preferences).
        let effortLabelsJSON = (try? JSONSerialization.data(withJSONObject: Preferences.effortLabels))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        config.userContentController.addUserScript(WKUserScript(source: """
            (() => {
              const names = \(effortLabelsJSON);
              const scope = 'button,[role=option],[role=menuitem],[role=menuitemradio],[role=listbox],[role=menu]';
              const fix = root => {
                const walk = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
                for (let n; (n = walk.nextNode());) {
                  const t = n.nodeValue.trim();
                  if (names[t] && n.parentElement?.closest(scope)) n.nodeValue = n.nodeValue.replace(t, names[t]);
                }
              };
              new MutationObserver(ms => ms.forEach(m => m.addedNodes.forEach(x => x.nodeType === 1 ? fix(x) : x.nodeType === 3 && x.parentNode && fix(x.parentNode))))
                .observe(document, {subtree: true, childList: true, characterData: true});
              addEventListener('DOMContentLoaded', () => fix(document.body));
            })();
            """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        if automation != nil {
            // Off-screen windows are occluded and WebKit pauses animations there; without this
            // the snapshot shows elements frozen at the first frame of their fade-in.
            config.userContentController.addUserScript(WKUserScript(
                source: "document.documentElement.appendChild(Object.assign(document.createElement('style'),{textContent:'*,*::before,*::after{animation:none!important;transition:none!important}'}))",
                injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        webView = DragWebView(frame: .zero, configuration: config)
        webView.underPageBackgroundColor = Self.pageBackground
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsMagnification = true
        webView.isInspectable = true
        self.automation = automation
        super.init(nibName: nil, bundle: nil)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        config.userContentController.add(WeakMessageHandler(self), name: "dshWindow")
        // Run the one-time service worker cleanup while dsh starts. Clearing every cache on every
        // navigation made the UI slower and could interrupt a page that was already connected.
        staleDataCleanup = Task {
            await webView.configuration.websiteDataStore.removeData(
                ofTypes: [WKWebsiteDataTypeServiceWorkerRegistrations], modifiedSince: .distantPast)
        }
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let window = view.window else { return }
        switch message.body as? String {
        case "drag": if let down = webView.lastMouseDown { window.performDrag(with: down) }
        case "zoom": window.performZoom(nil)
        default: break
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1280, height: 820))
        root.wantsLayer = true
        root.layer?.backgroundColor = Self.pageBackground.cgColor
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

    /// Asks a dsh server whether every enabled plugin is active, signed in with this web view's own
    /// cookies (dsh's session cookie outlives the server process). False while signed out.
    func readinessProbe() async -> @Sendable (Int) async -> Bool {
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
            .filter { $0.domain == "127.0.0.1" && $0.name.hasPrefix("dsh-auth-") }
            .map { ($0.name, $0.value) }
        return { port in
            let name = HarnessWebServer.authCookieName(port: port)
            guard let value = cookies.first(where: { $0.0 == name })?.1,
                  let url = URL(string: "http://127.0.0.1:\(port)/api/pluginInventory/list") else { return false }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 3)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("http://127.0.0.1:\(port)", forHTTPHeaderField: "Origin")
            request.setValue("\(name)=\(value)", forHTTPHeaderField: "Cookie")
            request.httpShouldHandleCookies = false
            request.httpBody = Data(#"{"type":"client-request","rpcId":"ready","method":"pluginInventory/list","payload":{"args":{}}}"#.utf8)
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let reply = try? JSONDecoder().decode(InventoryReply.self, from: data), reply.result.ok,
                  let entries = reply.result.value?.entries, !entries.isEmpty else { return false }
            return entries.allSatisfy { !$0.enabled || $0.fiberPhase == "active" }
        }
    }

    /// A fresh dsh supplies a new login token. Local storage and regular caches survive relaunches.
    func load(_ url: URL) async {
        origin = url
        connectAttempts = 0
        await staleDataCleanup?.value
        staleDataCleanup = nil
        // Sessions of servers on other ports are dead weight in every request's Cookie header.
        let store = webView.configuration.websiteDataStore.httpCookieStore
        let current = url.port.map { HarnessWebServer.authCookieName(port: $0) }
        for cookie in await store.allCookies()
        where cookie.domain == "127.0.0.1" && cookie.name.hasPrefix("dsh-auth-") && cookie.name != current {
            await store.deleteCookie(cookie)
        }
        webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
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

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if response.isForMainFrame, (response.response as? HTTPURLResponse)?.statusCode == 401 {
            (NSApp.delegate as? AppDelegate)?.serverRejectedSession()
            return .cancel
        }
        return .allow
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
        (NSApp.delegate as? AppDelegate)?.serverAuthenticated()
        if let automation { Task { await runAutomation(automation) } }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        // Cancelled by the policy above (401 → new session) or by a newer load: not a failure.
        if nsError.code == NSURLErrorCancelled || (nsError.domain == "WebKitErrorDomain" && nsError.code == 102) { return }
        // Retry briefly: the socket may still be coming up, or a stale worker is being dropped.
        if nsError.code == NSURLErrorCannotConnectToHost, connectAttempts < 10, let origin {
            connectAttempts += 1
            Task {
                try? await Task.sleep(for: .milliseconds(300 * connectAttempts))
                webView.load(URLRequest(url: origin, cachePolicy: .reloadIgnoringLocalCacheData))
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

    /// The page snapshot does not include the window's own controls; draw the traffic lights where
    /// they sit so the snapshot shows what the user sees.
    private func withWindowButtons(_ page: NSImage) -> NSImage {
        guard let window = view.window else { return page }
        let image = NSImage(size: page.size)
        image.lockFocus()
        page.draw(in: NSRect(origin: .zero, size: page.size))
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(kind), let rep = button.bitmapImageRepForCachingDisplay(in: button.bounds) else { continue }
            button.cacheDisplay(in: button.bounds, to: rep)
            let frame = button.convert(button.bounds, to: nil)   // window coordinates, origin bottom-left
            rep.draw(in: NSRect(x: frame.minX, y: frame.minY - (window.frame.height - page.size.height),
                                width: frame.width, height: frame.height))
        }
        image.unlockFocus()
        return image
    }

    private func runAutomation(_ job: Automation) async {
        try? await Task.sleep(for: .seconds(job.delay))
        if let script = job.script, !script.isEmpty {
            do { _ = try await webView.evaluateJavaScript(script + "\n;0") }
            catch { job.fail("automation script failed") }
            try? await Task.sleep(for: .seconds(job.delay))
        }
        let text = (try? await webView.evaluateJavaScript("document.body.innerText")) as? String ?? ""
        let connectedUI = text.contains("New Session") &&
            !text.localizedCaseInsensitiveContains("Reconnect now") &&
            !text.localizedCaseInsensitiveContains("Could not connect")
        print("ui: \(connectedUI ? "connected" : "unverified")")
        print("title: \(webView.title ?? "")")
        print("window: \(view.window.map { NSStringFromRect($0.frame) } ?? "none")")
        guard let page = try? await webView.takeSnapshot(configuration: nil),
              let tiff = withWindowButtons(page).tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            job.fail("snapshot failed")
        }
        do { try png.write(to: URL(fileURLWithPath: job.snapshotPath)) } catch { job.fail(error.localizedDescription) }
        print("snapshot: saved")
        NSApp.terminate(nil)
    }
}

/// `pluginInventory/list` reply, only the fields readiness needs.
private struct InventoryReply: Decodable {
    struct Result: Decodable { let ok: Bool; let value: Value? }
    struct Value: Decodable { let entries: [Entry] }
    struct Entry: Decodable { let enabled: Bool; let fiberPhase: String? }
    let result: Result
}

/// Remembers the last mouse-down, which `performDrag` needs once the page says the press landed
/// on an empty part of the title area.
final class DragWebView: WKWebView {
    private(set) var lastMouseDown: NSEvent?
    override func mouseDown(with event: NSEvent) {
        lastMouseDown = event
        super.mouseDown(with: event)
    }
}

/// WKUserContentController retains its handlers; this keeps it from retaining the controller.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        target?.userContentController(c, didReceive: m)
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

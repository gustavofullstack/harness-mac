import AppKit
import DSHKit
import WebKit

/// Native shell around the official DeepSeek Harness web UI.
///
/// The app starts `dsh --profile web` on loopback, shows it in a WKWebView and owns the
/// process lifecycle. The UI itself is the harness's own frontend, unchanged.
@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    private let automation = Automation.fromEnvironment()
    /// Headless runs get a free port and no pidfile unless HARNESS_PORT is set, so they never touch
    /// the user's server. A normal launch starts a fresh server and receives its login token.
    private lazy var port = Int(ProcessInfo.processInfo.environment["HARNESS_PORT"] ?? "") ?? (automation == nil ? 3179 : 0)
    private lazy var server = HarnessWebServer(pidFile: port == 0 ? nil : {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Harness", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(port == 3179 ? "dsh-web.pid" : "dsh-web-\(port).pid")
    }())
    private var recentExits: [Date] = []
    private var authFailures = 0
    private var window: NSWindow!
    private var web: WebController!
    private var wakeActivity: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One window per install: a second launch brings the running one forward.
        if automation == nil, let running = NSRunningApplication.runningApplications(
            withBundleIdentifier: Bundle.main.bundleIdentifier ?? "").first(where: {
                $0 != .current && $0.bundleURL == Bundle.main.bundleURL && $0.activationPolicy == .regular }) {
            running.activate()
            exit(0)
        }
        NSApp.mainMenu = MainMenu.build()
        setKeepAwake(UserDefaults.standard.object(forKey: "keepAwake") as? Bool ?? true)
        server.onUnexpectedExit = { [weak self] in Task { @MainActor in self?.serverExited() } }
        web = WebController(automation: automation)
        window = makeWindow()
        if automation == nil {
            NSApp.setActivationPolicy(.regular)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
        } else {
            // Background mode: no Dock icon, never activated, window kept off every screen.
            NSApp.setActivationPolicy(.accessory)
            window.orderBack(nil)
        }
        Task { await boot() }
    }

    private func makeWindow() -> NSWindow {
        let frame = NSRect(x: 0, y: 0, width: 1280, height: 820)
        let style: NSWindow.StyleMask = automation == nil
            ? [.titled, .closable, .miniaturizable, .resizable]
            : [.borderless]
        let w = NSWindow(contentRect: frame, styleMask: style, backing: .buffered, defer: false)
        w.title = "DSH"
        w.minSize = NSSize(width: 720, height: 480)
        w.contentViewController = web
        w.isReleasedWhenClosed = false
        if automation == nil {
            // Blend the native titlebar into the DSH canvas while preserving familiar macOS
            // window controls. The web view remains the unmodified upstream interface.
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.titlebarSeparatorStyle = .none
            w.backgroundColor = NSColor(calibratedWhite: 0.09, alpha: 1)
            w.center()
            w.setFrameAutosaveName("HarnessMainWindow")
            w.tabbingMode = .disallowed
        } else {
            w.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        }
        return w
    }

    private var booting = false
    private var restartPending = false

    private func boot() async {
        // Retry and Restart can fire while a boot is still waiting on dsh; two boots would stop each
        // other's server, so a Restart during a boot runs once that boot has ended.
        guard !booting else { return }
        booting = true
        defer {
            booting = false
            if restartPending { restartPending = false; Task { await boot() } }
        }
        let loading = Task { [web] in
            try await Task.sleep(for: .milliseconds(400))
            web?.showLoading("Starting DeepSeek Harness…")
        }
        defer { loading.cancel() }
        let env = await Task.detached { HarnessEnvironment.loginShell() }.value
        let override = UserDefaults.standard.string(forKey: "dshPath") ?? ""
        let dsh = FileManager.default.isExecutableFile(atPath: override)
            ? URL(fileURLWithPath: override) : HarnessEnvironment.locateDSH(in: env)
        guard let dsh else {
            web.showError("`dsh` was not found on your PATH.\n\nInstall DeepSeek Harness with the official quickstart, or point the app at it:\ndefaults write io.github.harness-mac dshPath /path/to/dsh",
                          retry: { [weak self] in Task { await self?.boot() } })
            if let automation { automation.fail("dsh not found") }
            return
        }
        do {
            let url = try await server.start(executable: dsh, environment: env, preferredPort: port)
            loading.cancel()
            await web.load(url)
        } catch {
            web.showError(error.localizedDescription, retry: { [weak self] in Task { await self?.boot() } })
            automation?.fail(error.localizedDescription)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        server.stop()
        setKeepAwake(false)
    }

    private func setKeepAwake(_ enabled: Bool) {
        if let wakeActivity {
            ProcessInfo.processInfo.endActivity(wakeActivity)
            self.wakeActivity = nil
        }
        if enabled && automation == nil {
            wakeActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled],
                reason: "DeepSeek Harness is running")
        }
    }

    @objc func toggleKeepAwake(_ sender: NSMenuItem) {
        let enabled = sender.state != .on
        UserDefaults.standard.set(enabled, forKey: "keepAwake")
        setKeepAwake(enabled)
        sender.state = enabled ? .on : .off
    }

    /// The server died under the page (crash, killed from a terminal): boot it again with a new
    /// login token and load the new URL.
    private func serverExited() {
        recentExits = recentExits.filter { $0.timeIntervalSinceNow > -60 } + [Date()]
        guard recentExits.count <= 3 else {
            web.showError("The harness server stopped \(recentExits.count) times in a minute.",
                          retry: { [weak self] in self?.recentExits = []; Task { await self?.boot() } })
            return
        }
        Task { await boot() }
    }

    /// An unexpected 401 on the fresh login URL is retried once, then surfaced rather than looping.
    func serverRejectedSession() {
        authFailures += 1
        server.stop()
        guard authFailures <= 1 else {
            web.showError("The harness rejected its login session.", retry: { [weak self] in
                self?.authFailures = 0
                Task { await self?.boot() }
            })
            return
        }
        Task { await boot() }
    }

    func serverAuthenticated() { authFailures = 0 }

    // MARK: - Menu actions

    @objc func reloadHarness(_ sender: Any?) { web.webView.reload() }

    @objc func restartHarness(_ sender: Any?) {
        if booting { restartPending = true }
        server.stop()
        Task { await boot() }
    }

    @objc func openInBrowser(_ sender: Any?) {
        if let url = web.webView.url { NSWorkspace.shared.open(url) }
    }

    @objc func zoomIn(_ sender: Any?) { web.webView.pageZoom = min(web.webView.pageZoom + 0.1, 3) }
    @objc func zoomOut(_ sender: Any?) { web.webView.pageZoom = max(web.webView.pageZoom - 0.1, 0.5) }
    @objc func actualSize(_ sender: Any?) { web.webView.pageZoom = 1 }

    @objc func openDocs(_ sender: Any?) {
        NSWorkspace.shared.open(URL(string: "https://deepseek-harness.github.io/deepseek-harness/en/guide/quickstart")!)
    }
}

/// Headless run used by CI and by agents: renders off-screen, saves a PNG and exits.
///
/// `HARNESS_SNAPSHOT=out.png` enables it. `HARNESS_SNAPSHOT_JS` is evaluated after the page
/// loads, and `HARNESS_SNAPSHOT_DELAY` (seconds, default 5) is waited before and after it.
struct Automation: Equatable {
    let snapshotPath: String
    let script: String?
    let delay: Double

    static func fromEnvironment() -> Automation? {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["HARNESS_SNAPSHOT"], !path.isEmpty else { return nil }
        return Automation(snapshotPath: path, script: env["HARNESS_SNAPSHOT_JS"],
                          delay: Double(env["HARNESS_SNAPSHOT_DELAY"] ?? "") ?? 5)
    }

    func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("harness: \(message)\n".utf8))
        exit(1)
    }
}

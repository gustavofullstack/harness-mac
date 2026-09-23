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

    private let server = HarnessWebServer(pidFile: {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Harness", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("dsh-web.pid")
    }())
    private let automation = Automation.fromEnvironment()
    private var window: NSWindow!
    private var web: WebController!
    /// dsh runs agents that keep working while the window is hidden; App Nap would throttle them.
    private let noNap = ProcessInfo.processInfo.beginActivity(
        options: .userInitiatedAllowingIdleSystemSleep, reason: "DeepSeek Harness server is running")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
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
        web.showLoading("Starting DeepSeek Harness…\nWith many MCP servers configured this can take up to a minute.")
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
            let url = try await server.start(executable: dsh, environment: env)
            await web.load(url)
        } catch {
            web.showError(error.localizedDescription, retry: { [weak self] in Task { await self?.boot() } })
            automation?.fail(error.localizedDescription)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) { server.stop() }

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

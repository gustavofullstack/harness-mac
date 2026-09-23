import Foundation

/// Resolves the environment and the `dsh` executable the way a terminal would.
///
/// Apps launched from Finder get a minimal `PATH` and none of the variables from
/// the login shell, so `dsh` (a Node script) and `node` itself are not found.
/// We ask the user's login shell for its environment once, with a timeout.
public enum HarnessEnvironment {
    /// Environment of the user's login shell, falling back to the app's own.
    public static func loginShell(timeout: TimeInterval = 5) -> [String: String] {
        var base = ProcessInfo.processInfo.environment
        let shell = base["SHELL"] ?? "/bin/zsh"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: shell)
        proc.arguments = ["-ilc", "env -0"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        proc.standardInput = FileHandle.nullDevice
        do { try proc.run() } catch { return withFallbackPath(base) }

        let deadline = Date().addingTimeInterval(timeout)
        while proc.isRunning, Date() < deadline { usleep(20_000) }
        if proc.isRunning { proc.terminate(); return withFallbackPath(base) }

        let data = out.fileHandleForReading.readDataToEndOfFile()
        for entry in data.split(separator: 0) {
            guard let s = String(data: Data(entry), encoding: .utf8), let eq = s.firstIndex(of: "=") else { continue }
            base[String(s[..<eq])] = String(s[s.index(after: eq)...])
        }
        return withFallbackPath(base)
    }

    /// Adds the usual install locations for Homebrew, npm and user binaries.
    static func withFallbackPath(_ env: [String: String]) -> [String: String] {
        var env = env
        let home = env["HOME"] ?? NSHomeDirectory()
        let extras = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.npm-global/bin"]
        var parts = (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        for dir in extras where !parts.contains(dir) { parts.append(dir) }
        env["PATH"] = parts.joined(separator: ":")
        return env
    }

    /// First executable named `dsh` on the given `PATH`.
    public static func locateDSH(in env: [String: String]) -> URL? {
        let fm = FileManager.default
        for dir in (env["PATH"] ?? "").split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent("dsh")
            if fm.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}

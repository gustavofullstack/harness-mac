import DSHKit
import Foundation

// Starts and stops `dsh --profile web` N times and prints how long each boot took.
// Usage: webserver-smoke [runs]
let runs = Int(CommandLine.arguments.dropFirst().first ?? "") ?? 5
let env = HarnessEnvironment.loginShell()
guard let dsh = HarnessEnvironment.locateDSH(in: env) else { print("dsh not found"); exit(1) }
var failures = 0
for i in 1...runs {
    let server = HarnessWebServer()
    let started = Date()
    do {
        let url = try await server.start(executable: dsh, environment: env, preferredPort: 0)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.httpMethod = "GET"
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.userAuthenticationRequired)
        }
        print(String(format: "boot %d authenticated %.1fs port %d", i, Date().timeIntervalSince(started), url.port ?? -1))
        server.stop()
        do {
            _ = try await URLSession.shared.data(for: request)
            failures += 1
            print("boot \(i) FAILED server still accepts requests after stop")
        } catch {
            print("boot \(i) stopped")
        }
    } catch {
        failures += 1
        print(String(format: "boot %d FAILED %.1fs %@", i, Date().timeIntervalSince(started), error.localizedDescription))
    }
    server.stop()
}
exit(failures == 0 ? 0 : 1)

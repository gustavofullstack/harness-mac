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
        let url = try await server.start(executable: dsh, environment: env)
        print(String(format: "boot %d ok %.1fs port %d", i, Date().timeIntervalSince(started), url.port ?? -1))
    } catch {
        failures += 1
        print(String(format: "boot %d FAILED %.1fs %@", i, Date().timeIntervalSince(started), error.localizedDescription))
    }
    server.stop()
}
exit(failures == 0 ? 0 : 1)

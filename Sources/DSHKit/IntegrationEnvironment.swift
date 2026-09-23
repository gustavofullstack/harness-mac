import Foundation

/// Only credentials explicitly supplied by DSH.app settings reach its child process.
/// The login shell is used to locate `dsh`, not as an implicit integration grant.
public enum IntegrationEnvironment {
    private static let managedKeys = [
        "TYPESAFE_API_KEY",
        "JEV_API_KEY",
        "OMNI_ROUTER_API_KEY",
        "OMNIROUTER_API_KEY",
    ]

    public static func forWebServer(
        _ loginEnvironment: [String: String],
        jevKey: String? = nil,
        omniRouteKey: String? = nil
    ) -> [String: String] {
        var result = loginEnvironment
        for key in managedKeys { result.removeValue(forKey: key) }
        if let jevKey, !jevKey.isEmpty { result["TYPESAFE_API_KEY"] = jevKey }
        if let omniRouteKey, !omniRouteKey.isEmpty { result["OMNI_ROUTER_API_KEY"] = omniRouteKey }
        return result
    }
}

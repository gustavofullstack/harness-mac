import Foundation
import Yams

/// A provider route and model the runtime can be initialized with.
public struct ModelChoice: Hashable, Sendable, Identifiable {
    public var provider: String
    public var model: String
    public var providerLabel: String
    public var id: String { "\(provider)/\(model)" }

    public init(provider: String, model: String, providerLabel: String? = nil) {
        self.provider = provider
        self.model = model
        self.providerLabel = providerLabel ?? provider
    }
}

/// Read-only view of `$DSH_HOME/settings.yaml` (default `~/.dsh`).
///
/// The harness owns this file; the app never writes it. Credentials are never read:
/// they live in `.credentials.yaml`, which this type does not open.
public struct HarnessSettings: Sendable {
    public var defaultModel: ModelChoice?
    public var models: [ModelChoice]

    public init(defaultModel: ModelChoice?, models: [ModelChoice]) {
        self.defaultModel = defaultModel
        self.models = models
    }

    /// Routes the harness always ships, available even with an empty settings file.
    public static let builtIn: [ModelChoice] = [
        ModelChoice(provider: "deepseek-official", model: "deepseek-flash", providerLabel: "DeepSeek"),
        ModelChoice(provider: "deepseek-official", model: "deepseek-v4-flash", providerLabel: "DeepSeek"),
        ModelChoice(provider: "deepseek-official", model: "deepseek-v4-pro", providerLabel: "DeepSeek"),
    ]

    public static func harnessHome(env: [String: String]) -> URL {
        if let custom = env["DSH_HOME"], !custom.isEmpty { return URL(fileURLWithPath: custom) }
        return URL(fileURLWithPath: env["HOME"] ?? NSHomeDirectory()).appendingPathComponent(".dsh")
    }

    public static func load(env: [String: String]) -> HarnessSettings {
        let url = harnessHome(env: env).appendingPathComponent("settings.yaml")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return HarnessSettings(defaultModel: builtIn.first, models: builtIn)
        }
        return parse(yaml: text)
    }

    /// Parses the subset of settings the app needs. Pure, so it is unit-tested.
    public static func parse(yaml: String) -> HarnessSettings {
        guard let root = (try? Yams.load(yaml: yaml)) as? [String: Any] else {
            return HarnessSettings(defaultModel: builtIn.first, models: builtIn)
        }
        var models: [ModelChoice] = []
        if let pi = root["llm-pi-ai"] as? [String: Any], let providers = pi["providers"] as? [String: Any] {
            for (name, value) in providers.sorted(by: { $0.key < $1.key }) {
                guard let route = value as? [String: Any] else { continue }
                let label = route["displayName"] as? String ?? name
                for entry in route["models"] as? [[String: Any]] ?? [] {
                    if let id = entry["id"] as? String {
                        models.append(ModelChoice(provider: name, model: id, providerLabel: label))
                    }
                }
            }
        }
        models += builtIn.filter { b in !models.contains(where: { $0.id == b.id }) }

        var defaultModel = models.first
        if let d = root["agent-default-model"] as? [String: Any],
           let provider = d["provider"] as? String, let model = d["model"] as? String {
            defaultModel = models.first(where: { $0.provider == provider && $0.model == model })
                ?? ModelChoice(provider: provider, model: model)
        }
        return HarnessSettings(defaultModel: defaultModel, models: models)
    }
}

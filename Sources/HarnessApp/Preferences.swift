import Foundation

/// Typed access to the app's own settings (the harness's settings live in ~/.dsh).
enum Preferences {
    static let keepAwakeKey = "keepAwake"
    static let effortLabelsKey = "effortLabels"

    /// Keeps the Mac from idle-sleeping while DSH is open, so running agents are not stopped.
    static var keepAwake: Bool {
        UserDefaults.standard.object(forKey: keepAwakeKey) as? Bool ?? true
    }

    /// Display names for dsh's reasoning levels, keyed by dsh's own label. "Auto" belongs to setups
    /// where the Minimal level is wired to an automatic effort picker, so it is opt-in:
    /// `defaults write io.github.harness-mac effortLabels -dict Minimal Auto Xhigh "Extra High" Max "Ultra Code"`
    static var effortLabels: [String: String] {
        UserDefaults.standard.dictionary(forKey: effortLabelsKey) as? [String: String] ?? ["Xhigh": "Extra High"]
    }
}

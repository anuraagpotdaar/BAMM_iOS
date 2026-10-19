import Foundation

final class TransformStore: @unchecked Sendable {
    static let shared = TransformStore()

    private let defaults: UserDefaults
    private let prefix = "transformStore."

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> [String: Float] {
        var out: [String: Float] = [:]
        for (key, value) in defaults.dictionaryRepresentation() {
            guard key.hasPrefix(prefix), let f = value as? Float ?? (value as? Double).map({ Float($0) }) else { continue }
            out[String(key.dropFirst(prefix.count))] = f
        }
        return out
    }

    func save(_ entries: [String: Float]) {
        for (key, value) in entries {
            defaults.set(value, forKey: prefix + key)
        }
    }

    func saveOne(_ key: String, _ value: Float) {
        defaults.set(value, forKey: prefix + key)
    }
}

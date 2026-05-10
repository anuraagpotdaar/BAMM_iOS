import Foundation

final class BackendUrlStore: @unchecked Sendable {
    static let shared = BackendUrlStore()

    private let defaults: UserDefaults
    private let modelKey = "backend.model"
    private let modeKey  = "backend.mode"
    private let legacyCurrentKey = "backend.currentUrl"
    private let legacyRecentsKey = "backend.recentUrls"
    private let maxRecents = 8

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        migrateLegacyIfNeeded()
    }

    var model: BackendModel {
        get {
            if let raw = defaults.string(forKey: modelKey), let m = BackendModel(rawValue: raw) {
                return m
            }
            return .bamm
        }
        set { defaults.set(newValue.rawValue, forKey: modelKey) }
    }

    var mode: BackendMode {
        get {
            if let raw = defaults.string(forKey: modeKey), let m = BackendMode(rawValue: raw) {
                return m
            }
            return .local
        }
        set { defaults.set(newValue.rawValue, forKey: modeKey) }
    }

    func url(model: BackendModel, mode: BackendMode) -> String {
        if let s = defaults.string(forKey: urlKey(model, mode)), !s.isEmpty {
            return s
        }
        return defaultUrl(for: model, mode: mode)
    }

    func setUrl(_ url: String, model: BackendModel, mode: BackendMode) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        defaults.set(trimmed, forKey: urlKey(model, mode))
        var list = recentsList(model: model, mode: mode)
        list.removeAll { $0 == trimmed }
        list.insert(trimmed, at: 0)
        if list.count > maxRecents { list = Array(list.prefix(maxRecents)) }
        defaults.set(list, forKey: recentsKey(model, mode))
    }

    func recentsList(model: BackendModel, mode: BackendMode) -> [String] {
        defaults.stringArray(forKey: recentsKey(model, mode)) ?? []
    }

    var current: String { url(model: model, mode: mode) }

    var recents: [String] { recentsList(model: model, mode: mode) }

    private func defaultUrl(for model: BackendModel, mode: BackendMode) -> String {
        switch (model, mode) {
        case (.bamm, .local):  return "http://localhost:7860"
        case (.mmm,  .local):  return "http://localhost:7860"
        case (.bamm, .hosted): return "https://example.modal.run"
        case (.mmm,  .hosted): return "https://example.modal.run"
        }
    }

    private func urlKey(_ model: BackendModel, _ mode: BackendMode) -> String {
        "backend.url.\(model.rawValue).\(mode.rawValue)"
    }
    private func recentsKey(_ model: BackendModel, _ mode: BackendMode) -> String {
        "backend.recents.\(model.rawValue).\(mode.rawValue)"
    }

    /// Pre-split keys land in the BAMM slots, but never clobber a new value.
    private func migrateLegacyIfNeeded() {
        let bammLocalUrlKey  = urlKey(.bamm, .local)
        let bammHostedUrlKey = urlKey(.bamm, .hosted)
        if defaults.string(forKey: bammLocalUrlKey) == nil,
           let s = defaults.string(forKey: "backend.url.local") {
            defaults.set(s, forKey: bammLocalUrlKey)
        }
        if defaults.string(forKey: bammHostedUrlKey) == nil,
           let s = defaults.string(forKey: "backend.url.hosted") {
            defaults.set(s, forKey: bammHostedUrlKey)
        }

        let bammLocalRecKey  = recentsKey(.bamm, .local)
        let bammHostedRecKey = recentsKey(.bamm, .hosted)
        if defaults.stringArray(forKey: bammLocalRecKey) == nil,
           let list = defaults.stringArray(forKey: "backend.recents.local") {
            defaults.set(list, forKey: bammLocalRecKey)
        }
        if defaults.stringArray(forKey: bammHostedRecKey) == nil,
           let list = defaults.stringArray(forKey: "backend.recents.hosted") {
            defaults.set(list, forKey: bammHostedRecKey)
        }

        if defaults.string(forKey: bammLocalUrlKey) == nil,
           let s = defaults.string(forKey: legacyCurrentKey) {
            defaults.set(s, forKey: bammLocalUrlKey)
        }
        if defaults.stringArray(forKey: bammLocalRecKey) == nil,
           let list = defaults.stringArray(forKey: legacyRecentsKey) {
            defaults.set(list, forKey: bammLocalRecKey)
        }
    }
}

import Foundation

struct SortPreferenceStore {
    let keyPrefix: String
    let entityId: String

    private var key: String { "sortPreference_\(keyPrefix)_\(entityId)" }

    func load() -> TrackSortOption? {
        guard let raw = UserDefaults.standard.string(forKey: key),
              let option = TrackSortOption(rawValue: raw) else { return nil }
        return option
    }

    func save(_ option: TrackSortOption) {
        UserDefaults.standard.set(option.rawValue, forKey: key)
    }
}

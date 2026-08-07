import Foundation

final class SettingsManager: ObservableObject {
    static let shared = SettingsManager()

    @Published var settings: AppSettings {
        didSet { saveSettings() }
    }

    private let defaults = UserDefaults.standard
    private let settingsKey = "ClaudeUsageSettings"

    private init() {
        if let data = defaults.data(forKey: settingsKey),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = decoded
        } else {
            settings = AppSettings()
        }
    }

    private func saveSettings() {
        if let encoded = try? JSONEncoder().encode(settings) {
            defaults.set(encoded, forKey: settingsKey)
        }
    }

    func setRefreshInterval(_ value: Double) { settings.refreshIntervalMinutes = value }
}

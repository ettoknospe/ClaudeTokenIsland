import Foundation

struct AppSettings: Codable {
    var warningThreshold: Double = 80.0   // island bar turns orange at/above this
    var criticalThreshold: Double = 90.0  // island bar turns red at/above this
    var refreshIntervalMinutes: Double = 5.0
}

struct UsageSnapshot {
    let fiveHourUtilization: Int
    let sevenDayUtilization: Int
    let sevenDaySonnetUtilization: Int?
    let fiveHourResetIn: String?
    let sevenDayResetIn: String?
    let lastUpdated: Date
    let weeklySessions: Int
    let weeklyMessages: Int
    let weeklyTokens: Int
    let extraUsageEnabled: Bool

    var displayText: String { "\(sevenDayUtilization)%" }
    var menuBarPrimaryText: String { "5hr: \(fiveHourUtilization)%" }
    var menuBarSecondaryText: String { "Week: \(sevenDayUtilization)%" }

    static var placeholder: UsageSnapshot {
        UsageSnapshot(
            fiveHourUtilization: 0,
            sevenDayUtilization: 0,
            sevenDaySonnetUtilization: nil,
            fiveHourResetIn: nil,
            sevenDayResetIn: nil,
            lastUpdated: Date(),
            weeklySessions: 0,
            weeklyMessages: 0,
            weeklyTokens: 0,
            extraUsageEnabled: false
        )
    }
}

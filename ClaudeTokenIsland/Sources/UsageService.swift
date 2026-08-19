import Foundation

// MARK: - API Response Model

struct OAuthUsageResponse: Decodable {
    let fiveHour: UsagePeriod?
    let sevenDay: UsagePeriod?
    let sevenDaySonnet: UsagePeriod?
    let extraUsage: ExtraUsage?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDaySonnet = "seven_day_sonnet"
        case extraUsage = "extra_usage"
    }

    struct UsagePeriod: Decodable {
        let utilization: Double
        let resetsAt: String

        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }

        var resetsAtDate: Date? {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.date(from: resetsAt)
        }
    }

    // Pay-as-you-go "extra usage": the account toggle that lets work continue
    // (billed as credits) after the plan's 5h/7d limits are hit. The live API
    // returns `is_enabled` plus `monthly_limit`/`used_credits`/`utilization`,
    // but those three come back null when the toggle is off and we have no real
    // sample of the enabled shape — the types are inferred (utilization is a
    // Double 0–100 like every other utilization in this API; the credit values
    // are assumed plain numbers). Each is decoded through `try?` so a wrong
    // guess yields nil instead of throwing and killing the whole response
    // decode. Replace the guesses when a real enabled-state sample arrives.
    struct ExtraUsage: Decodable {
        let isEnabled: Bool
        let utilization: Double?   // 0–100, drives the bar colour
        let usedCredits: Double?
        let monthlyLimit: Double?

        enum CodingKeys: String, CodingKey {
            case isEnabled = "is_enabled"
            case utilization
            case usedCredits = "used_credits"
            case monthlyLimit = "monthly_limit"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            isEnabled    = ((try? c.decodeIfPresent(Bool.self,   forKey: .isEnabled)) ?? nil) ?? false
            utilization  =  (try? c.decodeIfPresent(Double.self, forKey: .utilization)) ?? nil
            usedCredits  =  (try? c.decodeIfPresent(Double.self, forKey: .usedCredits)) ?? nil
            monthlyLimit =  (try? c.decodeIfPresent(Double.self, forKey: .monthlyLimit)) ?? nil
        }
    }
}

// MARK: - Utilization helpers (pure, testable)

/// Returns utilization percentage (0–100) given token count and limit.
func calculateUtilization(tokens: Int, limit: Int) -> Int {
    guard limit > 0 else { return 0 }
    return min(100, tokens * 100 / limit)
}

/// Formats a future date as a human-readable countdown string.
func formatTimeRemaining(until date: Date, from now: Date = Date()) -> String {
    let interval = date.timeIntervalSince(now)
    if interval <= 0 { return "now" }
    let days = Int(interval) / 86400
    let hours = (Int(interval) % 86400) / 3600
    let minutes = (Int(interval) % 3600) / 60
    if days > 0 { return "\(days)d \(hours)h" }
    return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
}

// MARK: - UsageService

final class UsageService: ObservableObject {
    static let shared = UsageService()

    @Published private(set) var currentUsage: UsageSnapshot = .placeholder
    @Published private(set) var error: String?
    // False until the first successful fetch. Lets the UI tell "no data yet
    // (e.g. rate-limited on launch)" apart from real zero-percent usage.
    @Published private(set) var hasData: Bool = false
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var weeklySessions: Int = 0
    @Published private(set) var weeklyMessages: Int = 0
    @Published private(set) var weeklyTokens: Int = 0

    private var refreshTimer: Timer?
    private var normalInterval: TimeInterval = SettingsManager.shared.settings.refreshIntervalMinutes * 60
    private let backoffInterval: TimeInterval = 15 * 60 // 15 minutes after 429
    private var isInBackoff: Bool = false

    // Injectable for testing
    var urlSession: URLSession = .shared

    private init() {}

    func startPolling() {
        fetchUsage()
        scheduleTimer(interval: normalInterval)
    }

    func stopPolling() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func scheduleTimer(interval: TimeInterval) {
        isInBackoff = (interval == backoffInterval)
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            self?.fetchUsage()
        }
    }

    func updateRefreshInterval(minutes: Double) {
        normalInterval = minutes * 60
        if !isInBackoff {
            scheduleTimer(interval: normalInterval)
        }
    }

    func fetchUsage() {
        DispatchQueue.main.async { self.isLoading = true }

        Task {
            do {
                let token = try await AuthManager.shared.validAccessToken()
                let response = try await fetchOAuthUsage(accessToken: token)

                let fiveHourUtil = Int(response.fiveHour?.utilization ?? 0)
                let sevenDayUtil = Int(response.sevenDay?.utilization ?? 0)
                let sonnetUtil: Int? = response.sevenDaySonnet.map { Int($0.utilization) }

                let fiveHourReset = response.fiveHour?.resetsAtDate
                let sevenDayReset = response.sevenDay?.resetsAtDate

                let extraUsage: ExtraUsageInfo = response.extraUsage.map {
                    ExtraUsageInfo(
                        enabled: $0.isEnabled,
                        percent: $0.utilization.map { Int($0) },
                        used: $0.usedCredits,
                        limit: $0.monthlyLimit
                    )
                } ?? .off

                let snapshot = UsageSnapshot(
                    fiveHourUtilization: fiveHourUtil,
                    sevenDayUtilization: sevenDayUtil,
                    sevenDaySonnetUtilization: sonnetUtil,
                    fiveHourResetIn: fiveHourReset.map { formatTimeRemaining(until: $0) },
                    sevenDayResetIn: sevenDayReset.map { formatTimeRemaining(until: $0) },
                    lastUpdated: Date(),
                    weeklySessions: 0,
                    weeklyMessages: 0,
                    weeklyTokens: 0,
                    extraUsage: extraUsage
                )

                await MainActor.run {
                    self.currentUsage = snapshot
                    self.error = nil
                    self.hasData = true
                    self.isLoading = false
                    self.scheduleTimer(interval: self.normalInterval)
                }
            } catch let error as NSError {
                let isRateLimit = error.code == 429
                let isAuthError = error.code == 401 || error.code == 403
                if isAuthError {
                    // Access token was rejected outright (not just near expiry) — force a refresh now.
                    _ = try? await AuthManager.shared.forceRefresh()
                }
                await MainActor.run {
                    if isRateLimit {
                        self.error = "Rate limited — retrying in 15 min"
                        self.scheduleTimer(interval: self.backoffInterval)
                    } else {
                        self.error = error.localizedDescription
                        self.scheduleTimer(interval: self.normalInterval)
                    }
                    self.isLoading = false
                }
            }
        }
    }

    func fetchOAuthUsage(accessToken: String) async throws -> OAuthUsageResponse {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        print("[UsageService] GET /api/oauth/usage")

        let (data, response) = try await urlSession.data(for: request)
        let body = String(data: data, encoding: .utf8) ?? "<binary>"

        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        print("[UsageService] HTTP \(http.statusCode) — \(body.prefix(300))")

        guard http.statusCode == 200 else {
            throw NSError(domain: "OAuthUsage", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(body)"])
        }

        return try JSONDecoder().decode(OAuthUsageResponse.self, from: data)
    }
}

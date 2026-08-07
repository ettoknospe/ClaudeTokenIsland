import SwiftUI

struct MenuBarView: View {
    @ObservedObject var usageService: UsageService
    @ObservedObject var settingsManager: SettingsManager
    @State private var showSettings = false
    @State private var showDashboard = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            usageHeader
            
            Divider()
                .padding(.vertical, 4)

            modelBreakdown

            Divider()
                .padding(.vertical, 4)

            actionButtons

            Divider()
                .padding(.vertical, 4)

            quitButton
        }
        .padding(.vertical, 8)
        .frame(minWidth: 200)
        .sheet(isPresented: $showSettings) {
            SettingsView(settingsManager: settingsManager, usageService: usageService)
        }
    }

    private var usageHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: usageIconName)
                    .foregroundColor(usageColor)
                Text("5hr: \(usageService.currentUsage.fiveHourUtilization)%")
                    .fontWeight(.medium)
                Spacer()
                if let timeLeft = usageService.currentUsage.fiveHourResetIn {
                    Text(timeLeft)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            HStack {
                Image(systemName: "calendar")
                    .foregroundColor(weeklyColor)
                Text("Week: \(usageService.currentUsage.sevenDayUtilization)%")
                    .fontWeight(.medium)
                Spacer()
                if let timeLeft = usageService.currentUsage.sevenDayResetIn {
                    Text(timeLeft)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if let error = usageService.error {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .lineLimit(2)
            } else if usageService.isLoading {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(height: 10)
            }
        }
        .padding(.horizontal, 12)
    }

    private var modelBreakdown: some View {
        Group {
            if let sonnetUsage = usageService.currentUsage.sevenDaySonnetUtilization {
                HStack {
                    Image(systemName: "cpu")
                        .font(.caption)
                        .foregroundColor(.blue)
                    Text("Sonnet: \(sonnetUsage)%")
                        .font(.caption)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 2)
            }
        }
    }

    private var actionButtons: some View {
        VStack(spacing: 0) {
            Button(action: openDashboard) {
                HStack {
                    Image(systemName: "chart.bar")
                    Text("Open Dashboard")
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Button(action: refreshUsage) {
                HStack {
                    Image(systemName: "arrow.clockwise")
                    Text("Refresh")
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Button(action: { showSettings = true }) {
                HStack {
                    Image(systemName: "gear")
                    Text("Settings")
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    private var quitButton: some View {
        Button(action: quitApp) {
            HStack {
                Image(systemName: "power")
                Text("Quit")
                Spacer()
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var usageIconName: String {
        let usage = usageService.currentUsage.fiveHourUtilization
        if usage >= 80 { return "exclamationmark.triangle.fill" }
        if usage >= 50 { return "chart.pie.fill" }
        return "chart.pie"
    }

    private var usageColor: Color {
        let usage = usageService.currentUsage.fiveHourUtilization
        if usage >= 90 { return .red }
        if usage >= 70 { return .orange }
        return .primary
    }

    private var weeklyColor: Color {
        let usage = usageService.currentUsage.sevenDayUtilization
        let criticalThreshold = Int(settingsManager.settings.criticalThreshold)
        let warningThreshold = Int(settingsManager.settings.warningThreshold)
        if usage >= criticalThreshold { return .red }
        if usage >= warningThreshold { return .orange }
        return .primary
    }

    private func openDashboard() {
        if let url = URL(string: "https://console.anthropic.com/settings/usage") {
            NSWorkspace.shared.open(url)
        }
    }

    private func refreshUsage() {
        usageService.fetchUsage()
    }

    private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}

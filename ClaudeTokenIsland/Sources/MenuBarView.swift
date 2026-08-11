import SwiftUI

// The popover the gear on the expanded island opens: just the controls —
// refresh interval and quit (manual refresh lives on the island's reload
// icon). Usage numbers live on the island itself, so they're not repeated.
struct MenuBarView: View {
    @ObservedObject var usageService: UsageService
    @ObservedObject var settingsManager: SettingsManager

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Settings")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("Refresh every \(Int(settingsManager.settings.refreshIntervalMinutes)) min")
                    .font(.callout)
                Slider(
                    value: Binding(
                        get: { settingsManager.settings.refreshIntervalMinutes },
                        set: { newValue in
                            settingsManager.setRefreshInterval(newValue)
                            usageService.updateRefreshInterval(minutes: newValue)
                        }
                    ),
                    in: 1...30, step: 1
                )
            }

            Divider()

            Button(action: { NSApplication.shared.terminate(nil) }) {
                HStack {
                    Image(systemName: "power")
                    Text("Quit")
                    Spacer()
                }
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .frame(width: 220)
    }
}

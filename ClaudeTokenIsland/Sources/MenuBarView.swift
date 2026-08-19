import SwiftUI
import AppKit

// The popover the gear on the expanded island opens: just the controls —
// sign-in, refresh interval and quit (manual refresh lives on the island's
// reload icon). Usage numbers live on the island itself, so they're not
// repeated.
struct MenuBarView: View {
    @ObservedObject var usageService: UsageService
    @ObservedObject var settingsManager: SettingsManager
    @ObservedObject var authManager: AuthManager = .shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Settings")
                .font(.headline)

            accountSection

            Divider()

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

    @ViewBuilder
    private var accountSection: some View {
        if authManager.isAuthenticated {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text("Signed in")
                    .font(.callout)
                Spacer()
                Button("Sign out") { authManager.signOut() }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        } else {
            Button(action: startSignIn) {
                HStack {
                    Image(systemName: "person.crop.circle.badge.plus")
                    Text("Sign in to Claude")
                    Spacer()
                }
            }
            .buttonStyle(.plain)
        }
    }

    // A plain NSAlert modal, not a SwiftUI field in the popover — the popover
    // is anchored to a non-activating NSPanel (see NotchOverlayController),
    // and a modal alert window reliably takes keyboard focus regardless of
    // the panel's own activation state, which an inline TextField would not
    // be guaranteed to do.
    private func startSignIn() {
        authManager.beginLogin()

        let alert = NSAlert()
        alert.messageText = "Paste the code from the browser"
        alert.informativeText = "After approving in the browser, copy the code shown on the success page and paste it here."
        alert.addButton(withTitle: "Submit")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "code#state"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let code = field.stringValue
        Task { await authManager.completeLogin(pastedCode: code) }
    }
}

import AppKit
import SwiftUI
import UserNotifications
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var notchController: NotchOverlayController!
    private var popover: NSPopover!
    private let usageService = UsageService.shared
    private let settingsManager = SettingsManager.shared

    private var lastWarningNotified: Int = 0
    private var lastCriticalNotified: Int = 0
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupPopover()
        setupNotchOverlay()
        setupNotifications()
        startUsagePolling()

        usageService.$currentUsage
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.checkForNotifications() }
            .store(in: &cancellables)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(closePopover),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        usageService.stopPolling()
    }

    // MARK: - Setup

    private func setupPopover() {
        popover = NSPopover()
        popover.contentSize = NSSize(width: 240, height: 200)
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(
            rootView: MenuBarView(usageService: usageService, settingsManager: settingsManager)
        )
    }

    private func setupNotchOverlay() {
        notchController = NotchOverlayController(
            usageService: usageService,
            settingsManager: settingsManager,
            popover: popover
        )
    }

    private func setupNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error { print("Notification auth error: \(error)") }
        }
    }

    private func startUsagePolling() {
        if settingsManager.settings.isConfigured {
            usageService.startPolling()
        }
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.checkForNotifications()
        }
    }

    // MARK: - Actions

    @objc private func closePopover() {
        notchController?.closePopover()
    }

    // MARK: - Usage Notifications

    private func checkForNotifications() {
        guard settingsManager.settings.notificationsEnabled else { return }
        let usage = usageService.currentUsage.sevenDayUtilization
        let warning  = Int(settingsManager.settings.warningThreshold)
        let critical = Int(settingsManager.settings.criticalThreshold)

        if usage < warning {
            lastWarningNotified = 0
            lastCriticalNotified = 0
        }

        if usage >= critical && lastCriticalNotified < critical {
            sendNotification(
                title: "Critical: Claude Usage",
                body: "You've used \(usage)% of your weekly quota. Consider pausing non-essential tasks.",
                isCritical: true
            )
            lastCriticalNotified = critical
        } else if usage >= warning && lastWarningNotified < warning && usage < critical {
            sendNotification(
                title: "Warning: Claude Usage",
                body: "You've used \(usage)% of your weekly quota.",
                isCritical: false
            )
            lastWarningNotified = warning
        }
    }

    private func sendNotification(title: String, body: String, isCritical: Bool) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = isCritical ? .defaultCritical : .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { print("Notification error: \(error)") }
        }
    }
}

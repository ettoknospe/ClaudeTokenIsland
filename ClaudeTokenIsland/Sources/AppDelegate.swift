import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var notchController: NotchOverlayController!
    private var popover: NSPopover!
    private let usageService = UsageService.shared
    private let settingsManager = SettingsManager.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Belt-and-suspenders alongside Info.plist's LSUIElement=true — without
        // this, an accessory app launched from outside /Applications can behave
        // inconsistently.
        NSApp.setActivationPolicy(.accessory)

        setupPopover()
        setupNotchOverlay()
        startUsagePolling()

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

    private func startUsagePolling() {
        usageService.startPolling()
    }

    // MARK: - Actions

    @objc private func closePopover() {
        notchController?.closePopover()
    }
}

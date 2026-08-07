import AppKit
import SwiftUI

// MARK: - Custom Panel
// NSPanel + .nonactivatingPanel prevents stealing keyboard focus.
// canBecomeKey = true is required for the attached NSPopover to work.
private final class NotchPanel: NSPanel {
    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(contentRect: contentRect, styleMask: style,
                   backing: backingStoreType, defer: flag)
        hasShadow = false
        isOpaque = false
        backgroundColor = .clear
        isReleasedWhenClosed = false
    }
    override var canBecomeKey: Bool { true }
}

// Accepts the very first click even while the window is inactive — without this
// a non-activating panel swallows the first click just to take focus, so the
// pill would need a second click to actually register the tap.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Controller
final class NotchOverlayController: NSObject, ObservableObject, NSPopoverDelegate {
    private var panel: NotchPanel?
    var popover: NSPopover?

    private let usageService: UsageService
    private let settingsManager: SettingsManager

    @Published private(set) var isExpanded = false
    private var collapseTimer: Timer?
    private var outsideClickMonitor: Any?
    private static let autoCollapseDelay: TimeInterval = 4

    // Geometry needed to compute both the collapsed and expanded window
    // frames; captured once in setupPanel and reused by toggleExpand.
    private var screen: NSScreen!
    private var notchX: CGFloat = 0
    private var notchW: CGFloat = 0
    private var notchH: CGFloat = 0

    private static let expandedWidth: CGFloat = 232
    private static let expandedContentHeight: CGFloat = 104

    init(usageService: UsageService, settingsManager: SettingsManager, popover: NSPopover) {
        self.usageService    = usageService
        self.settingsManager = settingsManager
        self.popover         = popover
        super.init()
        popover.delegate = self
        setupPanel()
        NotificationCenter.default.addObserver(
            self, selector: #selector(repositionPanel),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
    }

    // MARK: - Built-in Screen
    //
    // Always target the MacBook's own display, NOT NSScreen.main which
    // returns whichever screen currently has the active app's menu bar.
    // If the user has an external monitor set as "main", NSScreen.main
    // would point to that external display — completely wrong for notch work.

    private var builtInScreen: NSScreen {
        let builtIn = NSScreen.screens.first { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return false }
            return CGDisplayIsBuiltin(id) != 0
        }
        return builtIn ?? NSScreen.main ?? NSScreen.screens[0]
    }

    // MARK: - Notch Rect

    // Returns the notch bounding rect in the screen's coordinate space
    // (AppKit: origin at bottom-left, Y increases upward).
    // Formula from navtoj/NotchBar:
    //   x = leftArea.maxX (right edge of left menu-bar region = left edge of notch)
    //   y = leftArea.minY (bottom of menu bar = bottom of notch)
    //   width  = rightArea.minX - leftArea.maxX
    //   height = safeAreaInsets.top

    private func notchRect(for screen: NSScreen) -> NSRect? {
        guard #available(macOS 12.0, *),
              let left  = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea,
              screen.safeAreaInsets.top > 0 else { return nil }

        return NSRect(
            x:      left.maxX,
            y:      left.minY,
            width:  right.minX - left.maxX,
            height: screen.safeAreaInsets.top
        )
    }

    // MARK: - Setup

    private func setupPanel() {
        let screen = builtInScreen
        self.screen = screen

        // Positioned directly with AppKit's bottom-left-origin math — no reliance
        // on SwiftUI/AppKit coordinate-flip assumptions, which was the previous
        // full-screen-window approach's bug (content rendered at the bottom of
        // the screen instead of the top).
        let notch = notchRect(for: screen)
        notchX = notch?.origin.x ?? (screen.frame.midX - 120)
        notchW = notch?.width    ?? 240
        notchH = notch?.height   ?? NSStatusBar.system.thickness

        let frame = collapsedFrame()

        let p = NotchPanel(
            contentRect: frame,
            styleMask:   [.borderless, .nonactivatingPanel],
            backing:     .buffered,
            defer:       false
        )

        // .screenSaver level (1000) sits above all normal UI including the menu bar,
        // which lets us draw in the notch region. (Same as DynamicNotchKit.)
        p.level = .screenSaver
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenNone, .ignoresCycle]
        p.isMovable          = false
        p.ignoresMouseEvents = false

        let hostingView = FirstMouseHostingView(rootView: NotchLiveView(
            usageService:    usageService,
            settingsManager: settingsManager,
            controller:      self,
            notchWidth:      notchW,
            notchHeight:     notchH
        ))
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = CGColor.clear
        // Fully manual sizing — driven by setFrame/animator, never the content's
        // (zero) intrinsic size.
        hostingView.sizingOptions = []
        p.contentView = hostingView
        p.setFrame(frame, display: true)

        panel = p
        p.orderFrontRegardless()
    }

    @objc private func repositionPanel() {
        collapseTimer?.invalidate()
        panel?.close()
        panel = nil
        isExpanded = false
        setupPanel()
    }

    // MARK: - Expand / Collapse
    //
    // The window itself is animated to the target frame (never SwiftUI-internal
    // .frame layout) — every state's frame is computed with the same proven
    // AppKit bottom-left-origin math the collapsed pill already uses, so there's
    // no dependency on NSHostingView's flip behavior for interior alignment.

    private func collapsedFrame() -> NSRect {
        let totalHeight = notchH + NotchLiveView.stripHeight
        return NSRect(
            x: notchX,
            y: screen.frame.maxY - totalHeight,
            width: notchW,
            height: totalHeight
        )
    }

    private func expandedFrame() -> NSRect {
        let totalHeight = notchH + Self.expandedContentHeight
        let centerX = notchX + notchW / 2
        return NSRect(
            x: centerX - Self.expandedWidth / 2,
            y: screen.frame.maxY - totalHeight,
            width: Self.expandedWidth,
            height: totalHeight
        )
    }

    private func animate(to frame: NSRect) {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.38
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.34, 1.56, 0.64, 1)
            panel.animator().setFrame(frame, display: true)
        }
    }

    func toggleExpand() {
        isExpanded ? collapse() : expand()
    }

    private func expand() {
        isExpanded = true
        animate(to: expandedFrame())
        scheduleCollapseTimer()
        startOutsideClickMonitor()
    }

    private func collapse() {
        isExpanded = false
        collapseTimer?.invalidate()
        stopOutsideClickMonitor()
        // Close the settings popover first so it can't be left anchored to the
        // shrinking panel, stranded over the notch.
        popover?.performClose(nil)
        animate(to: collapsedFrame())
    }

    // A click anywhere outside our own windows (another app, the desktop, even
    // the same app that was already active) collapses the island. The global
    // monitor never fires for clicks on the island itself — those go through the
    // tap gesture — so this cleanly means "clicked away".
    private func startOutsideClickMonitor() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            self?.collapse()
        }
    }

    private func stopOutsideClickMonitor() {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }

    private func scheduleCollapseTimer() {
        collapseTimer?.invalidate()
        collapseTimer = Timer.scheduledTimer(withTimeInterval: Self.autoCollapseDelay, repeats: false) { [weak self] _ in
            self?.collapse()
        }
    }

    // Hovering the expanded island pauses the auto-collapse countdown;
    // leaving it restarts the countdown rather than collapsing immediately.
    func hoverChanged(_ hovering: Bool) {
        // Don't let the leave-island path restart a countdown that would collapse
        // out from under an open settings popover.
        guard isExpanded, popover?.isShown != true else { return }
        if hovering {
            collapseTimer?.invalidate()
        } else {
            scheduleCollapseTimer()
        }
    }

    // MARK: - Popover (Settings/Quit) — opened by the gear on the expanded island

    func openSettings() {
        guard let popover, let p = panel, let cv = p.contentView else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            // Keep the island open while the popover is up; popoverDidClose
            // restarts the auto-collapse countdown.
            collapseTimer?.invalidate()
            let anchor = NSRect(x: cv.bounds.midX - 1, y: 0, width: 2, height: 2)
            popover.show(relativeTo: anchor, of: cv, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func closePopover() { popover?.performClose(nil) }

    func popoverDidClose(_ notification: Notification) {
        if isExpanded { scheduleCollapseTimer() }
    }
}

// MARK: - Island Shape
//
// One continuous outline for both the collapsed pill and the expanded island —
// the same shape just gets wider/taller as the window animates between the two,
// so it reads as a single piece growing rather than a nub with a separate body
// appearing beneath it.
//
//   ╮────────╭                    ← concave corners matching notch hardware
//   │ camera │
//   │        ╰──╮          ╭──╯   ← shoulders flare out to the full width
//   │           │  content  │        (collapse to nothing when width == topWidth)
//   ╰───────────┴───────────╯     ← convex bottom corners
//
private struct IslandShape: Shape {
    var topWidth:    CGFloat   // width of the physical notch cutout
    var notchHeight: CGFloat   // height of the physical notch cutout
    var topRadius:    CGFloat = 8    // corner radius hugging the notch's own hardware curve
    var bottomRadius: CGFloat = 16

    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let leftX0  = max(0, (w - topWidth) / 2)
        let rightX0 = min(w, leftX0 + topWidth)
        let t = min(topRadius, topWidth / 2, notchHeight)
        let b = min(bottomRadius, h - notchHeight, w / 2)

        return Path { p in
            if leftX0 > t {
                // Expanded: the top edge is solid full-width black, with the
                // physical notch cut into it as its own concave-cornered notch —
                // exactly the shape of the hardware cutout, not a separate nub.
                let oc = min(topRadius, leftX0 - t, notchHeight)
                p.move(to: CGPoint(x: oc, y: 0))
                p.addLine(to: CGPoint(x: leftX0 - t, y: 0))
                p.addQuadCurve(to: CGPoint(x: leftX0, y: t), control: CGPoint(x: leftX0, y: 0))
                p.addLine(to: CGPoint(x: leftX0, y: notchHeight))
                p.addLine(to: CGPoint(x: rightX0, y: notchHeight))
                p.addLine(to: CGPoint(x: rightX0, y: t))
                p.addQuadCurve(to: CGPoint(x: rightX0 + t, y: 0), control: CGPoint(x: rightX0, y: 0))
                p.addLine(to: CGPoint(x: w - oc, y: 0))
                p.addQuadCurve(to: CGPoint(x: w, y: oc), control: CGPoint(x: w, y: 0))
            } else {
                // Collapsed (or nearly so): the notch IS the shape's own width —
                // a single concave corner per side, same as the resting pill.
                p.move(to: CGPoint(x: t, y: 0))
                p.addLine(to: CGPoint(x: w - t, y: 0))
                p.addQuadCurve(to: CGPoint(x: w, y: t), control: CGPoint(x: w, y: 0))
            }

            p.addLine(to: CGPoint(x: w, y: h - b))
            p.addQuadCurve(to: CGPoint(x: w - b, y: h), control: CGPoint(x: w, y: h))
            p.addLine(to: CGPoint(x: b, y: h))
            p.addQuadCurve(to: CGPoint(x: 0, y: h - b), control: CGPoint(x: 0, y: h))

            if leftX0 > t {
                let oc = min(topRadius, leftX0 - t, notchHeight)
                p.addLine(to: CGPoint(x: 0, y: oc))
                p.addQuadCurve(to: CGPoint(x: oc, y: 0), control: CGPoint(x: 0, y: 0))
            } else {
                p.addLine(to: CGPoint(x: 0, y: t))
                p.addQuadCurve(to: CGPoint(x: t, y: 0), control: CGPoint(x: 0, y: 0))
            }
            p.closeSubpath()
        }
    }
}

// MARK: - Live View
//
// The window is always sized exactly to the current (collapsed or expanded)
// state by NotchOverlayController — this view just fills whatever bounds it's
// given via GeometryReader, so its own layout never fights the window-frame
// animation that does the actual "growing" motion.

private extension View {
    // matchedGeometryEffect only when an id is supplied — lets one row helper
    // serve both the matched 5h row and the unmatched 7d row.
    @ViewBuilder
    func matchedGeometry(_ id: String?, in ns: Namespace.ID) -> some View {
        if let id {
            matchedGeometryEffect(id: id, in: ns)
        } else {
            self
        }
    }
}

struct NotchLiveView: View {
    @ObservedObject var usageService:    UsageService
    @ObservedObject var settingsManager: SettingsManager
    @ObservedObject var controller:      NotchOverlayController

    var notchWidth:  CGFloat
    var notchHeight: CGFloat

    @State private var isHovered = false

    // Shared namespace so the collapsed "5h %" number and its bar morph into the
    // expanded "Session (5h)" row's number and full-width bar (and back) instead
    // of cross-fading. The window frame is animated by AppKit over 0.38s with a
    // spring-overshoot curve; the matched content is animated with the same curve
    // (see .animation below) so the two clocks stay in step.
    @Namespace private var geometry
    private enum Match {
        static let fiveHourPercent = "fiveHourPercent"
        static let fiveHourBar = "fiveHourBar"
    }

    // The stats strip hangs below the physical camera housing.
    static let stripHeight: CGFloat = 14

    private var fiveHour: Int { usageService.currentUsage.fiveHourUtilization }
    private var sevenDay: Int { usageService.currentUsage.sevenDayUtilization }
    private var snapshot: UsageSnapshot { usageService.currentUsage }

    // Once the 5h session is maxed and extra-usage credits are covering the
    // overflow, a flat "100%" tells you nothing — so in that state the 5h slot
    // shows the live credit spend instead. Shared by the collapsed pill and the
    // expanded row so the number is identical and the morph stays clean.
    private var fiveHourValueText: String {
        if fiveHour >= 100, snapshot.extraUsage.enabled, let used = snapshot.extraUsage.used {
            return creditText(used)
        }
        return "\(fiveHour)%"
    }

    private func statusColor(for v: Int) -> Color {
        let w = settingsManager.settings.warningThreshold
        let c = settingsManager.settings.criticalThreshold
        if Double(v) >= c { return .red }
        if Double(v) >= w { return .orange }
        return Color(red: 0.2, green: 0.9, blue: 0.4)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                Color.clear.allowsHitTesting(false)

                // Same shape throughout — only its bounding rect changes as the
                // window animates, so the pill reads as one piece growing.
                // The cutout is drawn narrower/shorter than the real notch so the
                // black shape bleeds under the hardware edges instead of leaving
                // hairline gaps at the seam.
                IslandShape(topWidth: max(0, notchWidth - 8), notchHeight: notchHeight - 2)
                    .fill(Color.black)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .overlay {
                        // if/else, not AnyView: type-erasure breaks the
                        // matchedGeometryEffect identity the morph relies on.
                        if controller.isExpanded { expandedContent } else { collapsedContent }
                    }
                    // Smooth easeInOut (NOT the window's spring curve) so the
                    // matched 5h number and bar glide to their expanded positions
                    // without the overshoot that made them fling. Same 0.38s as the
                    // window animation so content and frame land together.
                    .animation(.easeInOut(duration: 0.38), value: controller.isExpanded)
                    // Tap-to-expand only when collapsed; when expanded, collapse
                    // is owned by the outside-click monitor and the auto-collapse
                    // timer — so a tap on the gear can't also collapse the island.
                    .onTapGesture { if !controller.isExpanded { controller.toggleExpand() } }
            }
        }
        .onHover { hovering in
            isHovered = hovering
            controller.hoverChanged(hovering)
        }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
    }

    // ── Collapsed: "87 %" + inline bar, flush under the notch ─────────────────
    private var collapsedContent: some View {
        VStack {
            Spacer()
            statsRow
                .padding(.horizontal, 7)
                .frame(height: Self.stripHeight)
        }
    }

    // ── Expanded: full breakdown — session, weekly, extra usage credits —
    // with a gear (Settings/Quit popover) tucked into the top-right corner.
    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            usageRow(label: "Session (5h)", percent: fiveHour, resetIn: snapshot.fiveHourResetIn,
                     valueText: fiveHourValueText,
                     percentMatchID: Match.fiveHourPercent, barMatchID: Match.fiveHourBar)
            usageRow(label: "Weekly (7d)", percent: sevenDay, resetIn: snapshot.sevenDayResetIn)

            extraUsageRow(snapshot.extraUsage)
        }
        .padding(.horizontal, 12)
        .padding(.top, 24)
        .padding(.bottom, 9)
        .overlay(alignment: .topTrailing) {
            Button(action: { controller.openSettings() }) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.55))
            }
            .buttonStyle(.plain)
            .padding(.top, 7)
            .padding(.trailing, 12)
        }
    }

    private func usageRow(label: String, percent: Int, resetIn: String?,
                          valueText: String? = nil,
                          percentMatchID: String? = nil, barMatchID: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.8))
                Spacer()
                Text(valueText ?? "\(percent)%")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
                    .matchedGeometry(percentMatchID, in: geometry)
                if let resetIn {
                    Text("· resets \(resetIn)")
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.4))
                }
            }
            bar(percent: percent, matchID: barMatchID)
        }
    }

    // The account's pay-as-you-go "extra usage" pool — whether work keeps going
    // (billed as credits) once the plan limits are hit, plus how much has been
    // spent. Bar is green/orange/red by utilization when on, flat gray when off.
    private func extraUsageRow(_ info: ExtraUsageInfo) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("Extra usage")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.8))
                Spacer()
                if info.enabled, let used = info.used, let limit = info.limit {
                    Text("\(creditText(used)) / \(creditText(limit))")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.white.opacity(0.6))
                } else {
                    Text(info.enabled ? "On" : "Off")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(info.enabled ? 0.9 : 0.5))
                }
            }
            extraUsageBar(info)
        }
    }

    // Credit values arrive in minor units (cents); render as euros.
    private func creditText(_ minorUnits: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "EUR"
        f.locale = Locale(identifier: "de_DE")
        return f.string(from: NSNumber(value: minorUnits / 100)) ?? String(format: "€%.2f", minorUnits / 100)
    }

    private func extraUsageBar(_ info: ExtraUsageInfo) -> some View {
        let fraction = info.enabled ? min(1, max(0, CGFloat(info.percent ?? 0) / 100)) : 0
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.15))
                Capsule()
                    .fill(statusColor(for: info.percent ?? 0))
                    .frame(width: geo.size.width * fraction)
            }
        }
        .frame(height: 3)
    }

    private func bar(percent: Int, matchID: String? = nil) -> some View {
        GeometryReader { geo in
            let fraction = min(1, max(0, CGFloat(percent) / 100))
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.15))
                Capsule()
                    .fill(statusColor(for: percent))
                    .frame(width: geo.size.width * fraction)
            }
        }
        .frame(height: 3)
        // Applied to the sized result, not inside the GeometryReader, so the
        // matched frame is the bar's real bounds.
        .matchedGeometry(matchID, in: geometry)
    }

    // ── Stats row: "87 %" + inline progress bar (collapsed pill only) ─────────
    private var statsRow: some View {
        HStack(spacing: 6) {
            Text(fiveHourValueText)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)
                .brightness(isHovered ? 0.15 : 0)
                .matchedGeometry(Match.fiveHourPercent, in: geometry)

            bar(percent: fiveHour, matchID: Match.fiveHourBar)
        }
    }
}

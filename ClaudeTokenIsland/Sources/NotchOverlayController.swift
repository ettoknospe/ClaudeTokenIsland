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

// MARK: - Controller
final class NotchOverlayController: NSObject {
    private var panel: NotchPanel?
    var popover: NSPopover?

    private let usageService: UsageService
    private let settingsManager: SettingsManager

    init(usageService: UsageService, settingsManager: SettingsManager, popover: NSPopover) {
        self.usageService    = usageService
        self.settingsManager = settingsManager
        self.popover         = popover
        super.init()
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

        // ── Small window, exactly the pill's size ───────────────────────────────
        // Positioned directly with AppKit's bottom-left-origin math — no reliance
        // on SwiftUI/AppKit coordinate-flip assumptions, which was the previous
        // full-screen-window approach's bug (content rendered at the bottom of
        // the screen instead of the top).
        let notch  = notchRect(for: screen)
        let notchX = notch?.origin.x ?? (screen.frame.midX - 120)
        let notchW = notch?.width    ?? 240
        let notchH = notch?.height   ?? NSStatusBar.system.thickness

        let stripHeight = NotchLiveView.stripHeight
        let totalHeight = notchH + stripHeight
        let frame = NSRect(
            x: notchX,
            y: screen.frame.maxY - totalHeight,
            width: notchW,
            height: totalHeight
        )

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

        let hosting = NSHostingController(rootView: NotchLiveView(
            usageService:    usageService,
            settingsManager: settingsManager,
            notchWidth:      notchW,
            notchHeight:     notchH,
            onTap: { [weak self] in self?.togglePopover() }
        ))
        hosting.view.wantsLayer        = true
        hosting.view.layer?.backgroundColor = CGColor.clear
        p.contentViewController        = hosting

        panel = p
        p.orderFrontRegardless()
    }

    @objc private func repositionPanel() {
        panel?.close()
        panel = nil
        setupPanel()
    }

    // MARK: - Popover

    func togglePopover() {
        guard let popover, let p = panel, let cv = p.contentView else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            let anchor = NSRect(x: cv.bounds.midX - 1, y: 0, width: 2, height: 2)
            popover.show(relativeTo: anchor, of: cv, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func closePopover() { popover?.performClose(nil) }
}

// MARK: - Notch Shape
//
// Concave corners at the TOP match the physical notch hardware corner curve.
// Convex corners at the BOTTOM form the rounded pill that hangs below.
//
//   ╮──────────────────────╭   ← concave (matches notch hardware ~8 pt radius)
//   │    camera housing    │   ← top notchHeight pts are behind the notch
//   │  ── stats strip ──   │   ← bottom stripHeight pts are visible
//   ╰──────────────────────╯   ← convex (pill, ~12 pt radius)
//
private struct NotchBarShape: Shape {
    var topRadius:    CGFloat = 8
    var bottomRadius: CGFloat = 10

    func path(in rect: CGRect) -> Path {
        let t = topRadius, b = bottomRadius
        return Path { p in
            p.move(to: CGPoint(x: t, y: 0))
            p.addLine(to: CGPoint(x: rect.width - t, y: 0))
            // top-right concave corner
            p.addQuadCurve(to: CGPoint(x: rect.width, y: t),
                           control: CGPoint(x: rect.width, y: 0))
            p.addLine(to: CGPoint(x: rect.width, y: rect.height - b))
            // bottom-right convex corner
            p.addQuadCurve(to: CGPoint(x: rect.width - b, y: rect.height),
                           control: CGPoint(x: rect.width, y: rect.height))
            p.addLine(to: CGPoint(x: b, y: rect.height))
            // bottom-left convex corner
            p.addQuadCurve(to: CGPoint(x: 0, y: rect.height - b),
                           control: CGPoint(x: 0, y: rect.height))
            p.addLine(to: CGPoint(x: 0, y: t))
            // top-left concave corner
            p.addQuadCurve(to: CGPoint(x: t, y: 0),
                           control: CGPoint(x: 0, y: 0))
            p.closeSubpath()
        }
    }
}

// MARK: - Live View

struct NotchLiveView: View {
    @ObservedObject var usageService:    UsageService
    @ObservedObject var settingsManager: SettingsManager

    var notchWidth:  CGFloat
    var notchHeight: CGFloat
    var onTap: () -> Void

    @State private var isHovered = false

    // The stats strip hangs below the physical camera housing.
    static let stripHeight: CGFloat = 14

    private var totalHeight: CGFloat { notchHeight + Self.stripHeight }

    private var fiveHour: Int { usageService.currentUsage.fiveHourUtilization }

    private func statusColor(for v: Int) -> Color {
        let w = settingsManager.settings.warningThreshold
        let c = settingsManager.settings.criticalThreshold
        if Double(v) >= c { return .red }
        if Double(v) >= w { return .orange }
        return Color(red: 0.2, green: 0.9, blue: 0.4)
    }

    var body: some View {
        // Window is sized exactly to the pill (see NotchOverlayController.setupPanel),
        // so content just fills it — no manual positioning needed here.
        notchContent
            .frame(width: notchWidth, height: totalHeight)
    }

    // ── Notch content pill ─────────────────────────────────────────────────────
    private var notchContent: some View {
        ZStack(alignment: .bottom) {
            NotchBarShape()
                .fill(Color.black)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)

            statsRow
                .padding(.horizontal, 7)
                .frame(height: Self.stripHeight)
        }
        .onHover      { isHovered = $0 }
        .onTapGesture { onTap() }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
    }

    // ── Stats row: "87 %" + inline progress bar ──────────────────────────────
    private var statsRow: some View {
        HStack(spacing: 6) {
            Text("\(fiveHour) %")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)
                .brightness(isHovered ? 0.15 : 0)

            usageBar
        }
    }

    private var usageBar: some View {
        GeometryReader { geo in
            let fraction = min(1, max(0, CGFloat(fiveHour) / 100))
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.15))
                Capsule()
                    .fill(statusColor(for: fiveHour))
                    .frame(width: geo.size.width * fraction)
            }
        }
        .frame(height: 2.5)
    }
}

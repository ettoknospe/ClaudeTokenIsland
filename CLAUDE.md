# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project layout

The repo root holds `README.md`, `docs/`, and a nested `ClaudeTokenIsland/` directory that is the actual Xcode app (this double-nesting is intentional). **All `xcodebuild`/`xcodegen` commands run from `ClaudeTokenIsland/ClaudeTokenIsland/`.**

## Build / test / run

Requires full Xcode selected (not just Command Line Tools): `xcode-select -p` must point at `/Applications/Xcode.app/...`. Uses [XcodeGen](https://github.com/yonaskolb/XcodeGen) — `project.yml` is the source of truth and the `.xcodeproj` is generated.

```bash
cd ClaudeTokenIsland/ClaudeTokenIsland

# Regenerate the project — REQUIRED after adding/removing source files or
# changing targets/settings in project.yml (the .xcodeproj is gitignored-ish
# generated output; edits to it are lost on the next generate).
xcodegen generate

# Build
xcodebuild -project ClaudeTokenIsland.xcodeproj -scheme ClaudeTokenIsland -configuration Debug build

# All tests
xcodebuild test -project ClaudeTokenIsland.xcodeproj -scheme ClaudeTokenIslandTests -destination 'platform=macOS'

# A single test / class
xcodebuild test -project ClaudeTokenIsland.xcodeproj -scheme ClaudeTokenIslandTests \
  -destination 'platform=macOS' \
  -only-testing:ClaudeTokenIslandTests/OAuthUsageResponseTests/testDecodesFullResponse

# Run: build, then open the product
open ~/Library/Developer/Xcode/DerivedData/ClaudeTokenIsland-*/Build/Products/Debug/ClaudeTokenIsland.app
```

When iterating on a running instance, `pkill -f ClaudeTokenIsland` before relaunching — `open` won't replace an already-running copy, and an old process keeps serving the previous binary.

Optional editor tooling: `xcode-build-server config -project ClaudeTokenIsland.xcodeproj -scheme ClaudeTokenIsland` writes `buildServer.json` (gitignored) for SourceKit-LSP.

## Code signing / Keychain gotcha

Signing is ad-hoc (`CODE_SIGN_IDENTITY: "-"` in `project.yml`). The app reads a Keychain item owned by another app, which requires a user "Always Allow" grant. That grant is keyed to the code signature, and **ad-hoc signatures change on every rebuild**, so each freshly-built binary re-prompts for the Keychain password. This is a dev-loop artifact only: a copy that lives in a fixed location (`/Applications`) and isn't rebuilt prompts exactly once. Switching to a stable signing identity requires an Apple ID signed into Xcode (Settings → Accounts), which was not configured — don't assume automatic signing works.

## Architecture

Non-sandboxed `LSUIElement` (accessory) app. `main.swift` → `AppDelegate` wires three singletons and the overlay.

**`UsageService` (singleton, `ObservableObject`)** — the only data source. Reads the OAuth token from the Keychain item `Claude Code-credentials`, then polls the undocumented `GET https://api.anthropic.com/api/oauth/usage` (with `anthropic-beta: oauth-2025-04-20`). Publishes a `UsageSnapshot`. Token is cached in memory and cleared on `401/403` so the next attempt re-reads a refreshed token; `429` triggers a 15-minute backoff. `URLSession` is injectable for tests. The response model (`OAuthUsageResponse`) and the pure helpers (`calculateUtilization`, `formatTimeRemaining`) are what `UsageServiceTests` exercises — keep new decodable fields optional so existing fixture tests still decode.

**`NotchOverlayController` (`ObservableObject`)** — owns the on-screen island. The key design decisions, which are easy to break:

- It targets the **built-in** screen explicitly (never `NSScreen.main`, which can be an external display) and derives notch bounds from `safeAreaInsets` / `auxiliaryTopLeftArea` / `auxiliaryTopRightArea`.
- The island is an `NSPanel` at `.screenSaver` level whose **window frame is animated** (`animator().setFrame`) between a `collapsedFrame()` and an `expandedFrame()`. Every frame is computed with plain AppKit bottom-left-origin math (`y = screen.frame.maxY - height`, centered on the notch). **The SwiftUI content always fills 100% of the window bounds** and never positions itself internally — this deliberately avoids depending on `NSHostingView`'s flip behavior, which previously rendered content at the bottom of the screen.
- The hosting view is a `FirstMouseHostingView` (accepts first mouse) so a click on the inactive non-activating panel expands on the **first** click instead of being swallowed for focus. Its `sizingOptions = []` is **required** — otherwise AppKit resizes the window to the content's (zero) intrinsic size and the island vanishes.
- Auto-collapse: a 4s timer (paused while hovered, via `hoverChanged`) plus a **global mouse-down monitor** started while expanded — any click outside our own windows collapses it. (An app-activation observer does *not* work: clicking back into an already-active app fires no activation event.)

**`IslandShape`** — one continuous `Shape` used for both states. When collapsed (window width ≈ notch width) it's a simple concave-cornered pill; when expanded it draws a solid full-width top edge with the physical notch cut into it as a notch-shaped hole. The cutout is drawn a few points narrower/shorter than the real notch (`notchWidth - 8`, `notchHeight - 2`) to bleed under the hardware edge and avoid a hairline seam.

**Settings** — the gear on the expanded island opens an `NSPopover` hosting `MenuBarView` (refresh interval, manual refresh, quit). There is intentionally **no menu bar status item**; the gear is the only entry point. `AppSettings.warningThreshold` / `criticalThreshold` are fixed color thresholds for the bars (no UI to change them).

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

## Code signing / Keychain gotcha (historical)

Earlier versions read the Keychain item owned by Claude Code CLI (`Claude Code-credentials`), which requires a user "Always Allow" grant keyed to the app's code signature. Signing was switched to a **stable self-signed identity** (`CODE_SIGN_IDENTITY: "ClaudeTokenIsland Signing"` in `project.yml`) so the grant survives rebuilds — but the CLI's own token *refresh* (and definitely a CLI re-login) recreates that Keychain item and resets its ACL, forcing a re-prompt regardless of our signing stability. That's the irregular re-prompting this app used to see.

**Fixed by owning our own OAuth grant** (see Architecture below) — the app no longer touches the CLI's Keychain item at all, so the CLI's own refresh/re-login cadence can no longer trigger our prompts. The stable signing identity is still worth keeping (any Keychain-backed grant benefits from it), but it's no longer load-bearing for this particular problem.

## Architecture

Non-sandboxed `LSUIElement` (accessory) app. `main.swift` → `AppDelegate` wires the singletons and the overlay.

**`AuthManager` (singleton, `ObservableObject`, `@MainActor`)** — owns sign-in. Standard OAuth authorization-code + PKCE flow against the same public endpoints Claude Code CLI itself uses (`client_id` is a public app identifier, not a secret): browser opens `https://claude.ai/oauth/authorize`, user approves and copies the `code#state` shown on the hosted success page, pastes it into the app's settings popover. Tokens are exchanged/refreshed at `https://console.anthropic.com/v1/oauth/token` and stored in **our own** Keychain item (`ClaudeTokenIsland-credentials`) — never the CLI's. `validAccessToken()` refreshes proactively when the cached token is within 60s of `expires_in`; `forceRefresh()` is called by `UsageService` on a `401`/`403` from the usage API itself.

**`UsageService` (singleton, `ObservableObject`)** — the only usage data source. Gets its token from `AuthManager.validAccessToken()`, then polls the undocumented `GET https://api.anthropic.com/api/oauth/usage` (with `anthropic-beta: oauth-2025-04-20`). Publishes a `UsageSnapshot`. `429` triggers a 15-minute backoff; `401`/`403` triggers an `AuthManager.forceRefresh()`. `URLSession` is injectable for tests. The response model (`OAuthUsageResponse`) and the pure helpers (`calculateUtilization`, `formatTimeRemaining`) are what `UsageServiceTests` exercises — keep new decodable fields optional so existing fixture tests still decode.

**`NotchOverlayController` (`ObservableObject`)** — owns the on-screen island. The key design decisions, which are easy to break:

- It targets the **built-in** screen explicitly (never `NSScreen.main`, which can be an external display) and derives notch bounds from `safeAreaInsets` / `auxiliaryTopLeftArea` / `auxiliaryTopRightArea`.
- The island is an `NSPanel` at `.screenSaver` level whose **window frame is animated** (`animator().setFrame`) between a `collapsedFrame()` and an `expandedFrame()`. Every frame is computed with plain AppKit bottom-left-origin math (`y = screen.frame.maxY - height`, centered on the notch). **The SwiftUI content always fills 100% of the window bounds** and never positions itself internally — this deliberately avoids depending on `NSHostingView`'s flip behavior, which previously rendered content at the bottom of the screen.
- The hosting view is a `FirstMouseHostingView` (accepts first mouse) so a click on the inactive non-activating panel expands on the **first** click instead of being swallowed for focus. Its `sizingOptions = []` is **required** — otherwise AppKit resizes the window to the content's (zero) intrinsic size and the island vanishes.
- Auto-collapse: a 4s timer (paused while hovered, via `hoverChanged`) plus a **global mouse-down monitor** started while expanded — any click outside our own windows collapses it. (An app-activation observer does *not* work: clicking back into an already-active app fires no activation event.)

**`IslandShape`** — one continuous `Shape` used for both states. When collapsed (window width ≈ notch width) it's a simple concave-cornered pill; when expanded it draws a solid full-width top edge with the physical notch cut into it as a notch-shaped hole. The cutout is drawn a few points narrower/shorter than the real notch (`notchWidth - 8`, `notchHeight - 2`) to bleed under the hardware edge and avoid a hairline seam.

**Settings** — the gear on the expanded island opens an `NSPopover` hosting `MenuBarView` (sign in/out, refresh interval, manual refresh, quit). There is intentionally **no menu bar status item**; the gear is the only entry point. `AppSettings.warningThreshold` / `criticalThreshold` are fixed color thresholds for the bars (no UI to change them).

# Claude Token Island

A lightweight macOS menu bar app that shows your [Claude.ai](https://claude.ai) plan usage in real time — a Dynamic-Island-style pill attached under the notch, plus a menu bar popover — without opening a browser.

![Claude Token Island](ClaudeTokenIsland/Resources/Assets.xcassets/Image.imageset/Image.png)

## What it shows

- **Notch pill**: current 5-hour session usage, live, right under the notch.
- **Menu bar popover**: same data, plus weekly (7-day) usage.

Mirrors the data on `claude.ai/settings/usage`. Colors update based on your configured warning/critical thresholds.

## Requirements

- macOS 13+, MacBook with a notch (for the pill; the menu bar popover works on any Mac)
- [Claude Code](https://claude.ai/code) installed and logged in (the app reads its OAuth token from your Keychain — no separate credentials needed)

## Build from source

```bash
git clone <this-repo>
cd ClaudeTokenIsland/ClaudeTokenIsland
xcodebuild -scheme ClaudeTokenIsland -configuration Release build
open ~/Library/Developer/Xcode/DerivedData/ClaudeTokenIsland-*/Build/Products/Release/ClaudeTokenIsland.app
```

Or open `ClaudeTokenIsland.xcodeproj` in Xcode and run with ⌘R.

Uses [XcodeGen](https://github.com/yonaskolb/XcodeGen) — after editing `project.yml`, regenerate with `xcodegen generate`.

## How it works

The app reads your Claude Code OAuth token from the macOS Keychain (`Claude Code-credentials`) and calls the same internal endpoint that powers `claude.ai/settings/usage`:

```
GET https://api.anthropic.com/api/oauth/usage
Authorization: Bearer <oauth_token>
anthropic-beta: oauth-2025-04-20
```

The token is read once at startup and cached in memory, and re-read from the Keychain automatically if a request comes back unauthorized.

> **Note:** This endpoint is undocumented and may change. It requires Claude Code to be installed and logged in.

## Settings

| Setting | Default | Description |
|---------|---------|-------------|
| Compact display | On | Show both 5h and 7d in the menu bar popover |
| Warning threshold | 80% | Orange color above this |
| Critical threshold | 90% | Red color above this |
| Usage alerts | On | macOS notification when thresholds are crossed |

## Running tests

```bash
xcodebuild test -project ClaudeTokenIsland.xcodeproj \
  -scheme ClaudeTokenIslandTests \
  -destination 'platform=macOS'
```

## License

MIT

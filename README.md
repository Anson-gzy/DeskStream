# Desk Stream

English | [简体中文](README.zh-CN.md)

A canvas for every macOS desktop at once. Desks run left to right in the same order as Mission Control, and each desk shows its windows as a vertical stream. Click a window to go to it, exactly as it is.

Desk Stream never moves, resizes, hides or minimizes your windows. It only shows them and takes you there.

## Features

- **Open from anywhere**: press `⌃ ⌥ Space` or swipe down with four fingers
- **Every desk at a glance**: each macOS desktop (Space) is a column, full-screen apps get their own column, thumbnails are taken fresh each time the canvas opens, and your own wallpaper sits behind it
- **Go to a window**: click it and Desk Stream switches to its desktop and brings it to the front. Click an empty desk to switch to that desk
- **Scroll like a page**: scroll down a desk, or across to the next one, with native momentum and edge bounce
- **Add a desk**: at the last desk, push a little further to the right and a new macOS desktop slides in
- **Remove a desk**: hover the label of an empty desk and click ×
- **Reorder desks**: drag a desk label. The canvas updates at once and the real order is synced through Mission Control in the background (about 4 seconds)
- **Keyboard**: `⌃ ⌥ ↑ ↓` moves between rows, `⌃ ⌥ ← →` moves between desks, `Esc` closes the canvas

## Requirements

- macOS 15 or later (developed and tested on macOS 27.2)
- A trackpad for the four-finger gesture (the keyboard shortcut works without one)

## Install

1. Download `DeskStream.zip` from [Releases](../../releases/latest), unzip it and move `DeskStream.app` to `/Applications`
2. The app is ad-hoc signed and **not notarized**, so macOS blocks it the first time. Open it once, then go to System Settings → Privacy & Security and click **Open Anyway**. If macOS says the app is damaged, run `xattr -dr com.apple.quarantine /Applications/DeskStream.app` and open it again
3. Grant the two permissions it asks for in System Settings → Privacy & Security:
   - **Accessibility**: to list windows and bring them to the front
   - **Screen Recording**: to take window thumbnails and the wallpaper

Desk Stream lives in the menu bar (no Dock icon). Use the menu bar item to open the canvas or quit.

### Recommended system settings

- **Turn off App Exposé on four-finger swipe down**: System Settings → Trackpad → More Gestures → App Exposé. Otherwise both open at once
- **Turn off "Automatically rearrange Spaces based on most recent use"**: System Settings → Desktop & Dock → Mission Control. When it is on, macOS moves the desktop you switch to next to the current one, so the order on the canvas keeps changing

## Build from source

Requires Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
cd mac
xcodegen generate
xcodebuild -project DeskStream.xcodeproj -scheme DeskStream -configuration Debug -derivedDataPath build build test
ditto build/Build/Products/Debug/DeskStream.app /Applications/DeskStream.app
```

Set `DEVELOPMENT_TEAM` in `mac/project.yml` to your own team ID first. Sign with a real certificate: with ad-hoc signing macOS forgets the Accessibility and Screen Recording permissions after every build.

### Try the canvas in a browser

The canvas is plain HTML, CSS and JavaScript in `web/`. Opened in a browser it runs in demo mode with sample windows:

```bash
cd web && python3 -m http.server 4174 --bind 127.0.0.1
```

Then open <http://127.0.0.1:4174>.

## How it works

- `web/` is the canvas, shown in a full-screen `WKWebView` panel. `docs/bridge.md` is the protocol between Swift and the page
- `mac/DeskStream` is the app: windows through the Accessibility API, thumbnails through ScreenCaptureKit, global hotkeys through Carbon, the four-finger swipe through a listen-only event tap
- `mac/DeskCore` holds the layout logic and its unit tests
- There is no public API for desktops. Desk Stream reads them with private SkyLight calls, and adds, removes and reorders them through the buttons Mission Control exposes to Accessibility. A future macOS update can break any of this

## Credits

The look of the canvas is inspired by [Pane](https://trypane.app). Desk Stream is an independent project and is not affiliated with Pane.

Fonts: [Inter](https://github.com/rsms/inter) and [JetBrains Mono](https://github.com/JetBrains/JetBrainsMono), under the SIL Open Font License (`web/assets/fonts/OFL.txt`).

## License

[MIT](LICENSE)

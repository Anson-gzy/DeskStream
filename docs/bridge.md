# Desk Stream bridge

The Mac app (`mac/`, Swift) manages real windows. The canvas UI is the web page in `web/`, loaded
into a `WKWebView` inside a full-screen overlay panel. This file is the contract between the two.
The same page also runs in a plain browser with built-in demo windows; it detects the app by the
presence of `window.webkit.messageHandlers.desk`.

## Model

- In the app, **desks are the macOS Spaces**: one desk per user desktop (named `Desktop 1`, `Desktop 2`…
  like Mission Control) and one per full-screen Space (named after its app), in Mission Control
  order, ids `s<ManagedSpaceID>`. A window sits in the desk of the Space it is on. Desks cannot be
  added, removed or renamed from the canvas, and a window can only be dragged within its own desk.
  The browser demo keeps free-form desks.
- A **desk** is a vertical stream of **rows**. Each desk's windows (in order) are chunked into rows:
  one per row when the desk has 2 windows or fewer, two per row otherwise. The page sends the chunked
  rows back in `layout` whenever they differ from what `load` carried.
- The canvas draws every window at its real size and aspect ratio, scaled down only to fit its slot
  (the full desk width, or half of it when two share a row). There are no ratio dividers.
- Windows on other Spaces and native full-screen windows are listed too; going to one switches Space.
  Space membership comes from the window server's per-Space window list (yabai's real-window test),
  not from `SLSCopySpacesForWindows`, which still names a Space for ordered-out windows.
- The home zoom fits the whole active desk on screen at about four tenths of the screen width; the
  size control in the bottom-right corner (and ⌘− / ⌘=) scales that from 0.5× to 1.6× and is
  remembered in the page's `localStorage`.
- Desks sit left to right on the canvas. Desks and rows only group windows for the canvas: the app
  never moves, resizes, hides, minimises or un-minimises a window. Going to a window raises and
  focuses it where it already is. The **active row** is the row of the last focused window.
- Window ids are `CGWindowID` numbers, sent as JSON numbers.

## Loading

The panel loads `desk://app/index.html`. One `WKURLSchemeHandler` for the `desk` scheme serves:

| URL | Body |
|---|---|
| `desk://app/<path>` | file `<path>` from the bundled `web/` folder, MIME by extension |
| `desk://thumb/<wid>?v=<n>` | latest JPEG thumbnail of window `<wid>` (404 when none yet). While the canvas is up every window is streamed with ScreenCaptureKit at up to 10 fps, so `thumb` calls keep arriving; a window on a Space that is not showing keeps its last picture |
| `desk://icon/<pid>` | PNG of `NSRunningApplication(pid).icon`, 64×64 |
| `desk://wallpaper` | the main screen's desktop picture (`NSWorkspace.desktopImageURL(for:)`) as JPEG, longest side at most 3840; 404 when it is not a still image (dynamic or aerial wallpapers), and the page then falls back to its bundled wallpaper |

## Swift → JS

Calls on `window.deskStream`, made with `evaluateJavaScript` after the page posted `ready`.

```js
deskStream.load(state)   // full state, replaces whatever the page shows
deskStream.thumb(wid, v) // a new thumbnail version for one window
deskStream.open(fromWid) // overlay just became visible; animate out from this window (may be null)
deskStream.close()       // overlay is about to hide (hotkey or focus lost)
deskStream.showDesk(id)  // jump (no animation) to this desk at the default size, while Mission Control still covers the canvas
```

`state`:

```json
{
  "desks": [
    { "id": "s4", "name": "Desktop 2",
      "rows": [ { "wins": [1234, 5678], "ratios": [0.5, 0.5] } ] }
  ],
  "windows": {
    "1234": { "title": "README.md", "app": "Xcode", "pid": 812,
              "icon": "desk://icon/812", "thumb": "desk://thumb/1234?v=3",
              "x": 36, "y": 60, "w": 1440, "h": 900 }
  },
  "active": { "desk": "s4", "row": 0, "win": 1234 },
  "screen": { "w": 1512, "h": 982, "visible": { "x": 0, "y": 33, "w": 1512, "h": 880 } }
}
```

`ratios` has one entry per window in the row and sums to 1; the page always sends equal ratios and ignores them on load.
`thumb` is `null` until a capture exists. `x`, `y`, `w`, `h` are the window's real frame in points,
relative to the top-left of the overlay's screen; the page flies a clicked window to that frame
before posting `go`. `screen` is the overlay's screen in points; `visible` is its visibleFrame in
the same coordinates (below the menu bar, above the Dock).

## JS → Swift

`webkit.messageHandlers.desk.postMessage(msg)`:

| `msg.type` | Fields | Swift does |
|---|---|---|
| `ready` | | push `load(state)` |
| `go` | `win` | hide overlay, raise and focus `win` without changing its frame or state; its row becomes active |
| `dismiss` | | hide overlay, keep the current active row |
| `layout` | `desks` (same shape as `state.desks`) | adopt as the new layout (rules below), persist, do not echo back |
| `close` | `win` | press the window's AX close button, then re-read windows and push `load` |
| `minimize` | `win` | set AX minimized; the window leaves the layout until restored; push `load` |
| `zoom` | `win` | same as `go` |
| `goDesk` | `desk` (an `s<space id>` desk id) | hide overlay, switch to that Space even when it has no windows: a transparent 1×1 window of the app is moved there (`SLSMoveWindowsToManagedSpace`) and brought to the front |
| `addDesk` | | add a real macOS desktop through Mission Control: open it, AXPress the "Add Desktop" button that WindowManager exposes in its Spaces Bar, Escape; no mouse events. The overlay stays open underneath (losing key does not hide it meanwhile); then re-read Spaces, push `load`, `showDesk` the new one and make the overlay key again. macOS always adds it after the last desktop. The page sends it on a swipe (horizontal wheel deltas over 90 within 450 ms) that starts with the canvas already scrolled to its end; the ghost desk past the last one stays hidden and is only pulled in from the right edge during that swipe |
| `removeDesk` | `desk` | same route as `addDesk` with the desktop's `AXRemoveDesktop` action ("Exit To Desktop N" button). Only offered for desks without windows (the × shows when hovering the label). Escape is resent while Mission Control is still up, because the first one is sometimes swallowed by the removal animation. On the next `load` without that desk the page jumps to the desk now at its place |
| `moveDesk` | `desk`, `to` | the label of `desk` was dropped at index `to`. Mission Control has no action for reordering, so its thumbnail is dragged along the Spaces Bar with real HID pointer events under the opaque canvas (events posted to WindowManager alone are ignored); WindowManager reports each thumbnail's centre as its AX position. The overlay ignores mouse events and the pointer is detached from the mouse meanwhile, then warped back; the cursor itself stays visible because Mission Control shows it. Syncs are held until it is done, so the old order is not pushed back over the canvas. The page renumbers "Desktop N" names by position at once, as Mission Control will |

## Layout rules (Swift owns them)

- `layout` from the page: adopted as the window order inside each desk, and as the desk order.
  Dragging a desk label reorders desks on the canvas only: Mission Control's order of real desktops
  cannot be changed without moving the mouse (no AX action, and posted mouse events do not reach its
  Spaces Bar). A Space new to the canvas goes right after the desk of the Space before it.
- Every window sync (2 s timer and AX notifications) rebuilds the desks from the Spaces: a window keeps
  its place in its Space's desk, windows new to that Space go to the end, closed windows drop out,
  and rows are chunked again. `load` is pushed only when this changed something.
- Flights copy Mission Control: every window of the desk flies at once in a straight line between
  its real frame and its card, on a critically damped spring (no overshoot), the clicked or active
  window on top. Opening flies them from the real frames into the cards (320 ms). The flying copies
  have no shadow or chip, so at 60% of the flight the real cards are shown under them and fade in
  their shadow and chip; swapping only after the motion stops reads as a hitch.
- `go`: the window is raised behind the still-opaque canvas while the desk's pictures fly back to
  their real frames (300 ms); the canvas fades out 0.2 s after `go`. When the window is on another
  Space, the canvas stays opaque until `activeSpaceDidChange` (1.5 s at most) and fades after the
  system slide, so the two never show at once.
- Clicking an empty desk (no windows) posts `goDesk`; its panel grows to the full screen while the
  Space switches, and the canvas fades after the switch the same way.
- The panel is `.stationary`: without it the system Space slide and Mission Control draw over the
  canvas. With it the canvas covers both, so `addDesk` / `removeDesk` show no Mission Control flash.
- Dragging a desk label zooms the canvas out to an overview anchored at the cursor (the point under
  it stays put), the desk follows the cursor and the others make room, sliding with their labels
  (320 ms, driven per frame in JS so label and desk share one x); on release it slides into its slot,
  zooms back to the default size centred on that desk, and posts `layout`.
- The user focusing a window by other means (Cmd-Tab, Dock, a click) makes that window's row active.
- Layout is saved to `~/Library/Application Support/DeskStream/layout.json` and restored on launch;
  ids that no longer exist are dropped.

## Hotkeys (global, native)

| Keys | Action |
|---|---|
| ⌃⌥Space | toggle the canvas overlay |
| ⌃⌥↑ / ⌃⌥↓ | previous / next row of the active desk (no wrap): raise that row's windows, focus its last focused one |
| ⌃⌥← / ⌃⌥→ | previous / next desk, landing on that desk's last active row (no wrap), raised the same way |

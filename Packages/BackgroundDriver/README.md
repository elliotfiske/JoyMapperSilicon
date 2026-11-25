# BackgroundDriver

Drives a macOS app from the inside, so tests and scripts can click, hover, and type without
taking over the real mouse and keyboard. The app starts a loopback HTTP server; requests find
elements by accessibility identifier and become `NSEvent`s delivered straight to the app's own
windows. Nothing goes through the window server: the app stays in the background, behind other
windows, and never activates.

```swift
import BackgroundDriver

#if DEBUG
try? BackgroundDriver.start()   // debug builds only: whoever has the token can drive the app
#endif
```

The endpoint (`port`, `token`, `pid`) is written to
`~/Library/Caches/<bundle id>/background-driver.json`. A test that launches the app can choose
them itself with `BACKGROUND_DRIVER_PORT` and `BACKGROUND_DRIVER_TOKEN`. Every request needs
`Authorization: Bearer <token>`.

## From a test or script

`BackgroundDriverClient` launches a fresh copy in the background (a new instance, never
activated, ignoring saved window state) or attaches to a running one, then drives it with
blocking calls shaped like XCUITest's:

```swift
import BackgroundDriverClient

let app = try LaunchedApp.launch(appURL, environment: ["MY_FLAG": "1"])
defer { app.terminate() }
try app.client.click(Target(id: "start-standup"))
let name = try app.client.element("person-name")?.element.label
```

The launched copy gets the caller's environment minus what a test runner injects
(`XCTest*`, `DYLD_*`, …), so it doesn't think it's being unit-tested. It publishes its endpoint to
its own file, so it doesn't disturb a copy you're using.

## API

| Request | Does |
|---|---|
| `GET /status` | pid, whether the app is active or hidden, the frontmost app, the key window |
| `GET /windows` | the app's windows, frontmost first |
| `GET /elements?id=<prefix>&window=<title prefix>` | elements with an identifier: role, label, value, frame (window points, top-left origin) |
| `GET /element?id=<id>&within=<id>&window=<title prefix>` | one element and the texts inside it |
| `GET /tree?window=<title prefix>` | the whole accessibility tree, as text |
| `GET /menu` | main-menu items with shortcuts |
| `POST /click {"id" or "label", "window"?, "count"?}` | clicks the element's center |
| `POST /hover {"id" or "label", "window"?}` | moves the synthetic mouse over it (and off the last one) |
| `POST /key {"key", "modifiers"?, "window"?}` | `space`, `return`, `escape`, `left`…, or one character; modifiers `command`, `shift`, `option`, `control` |
| `POST /close {"window"?}` | closes a window, like its close button |
| `GET /snapshot?window=<title prefix>&method=views\|windowserver` | the window as PNG |

`window` matches a title prefix; the frontmost match wins.

## How it works, and why

A background app has no key window, and much of AppKit assumes one. Each workaround is scoped
to the driver's own events:

- **The accessibility tree.** SwiftUI only builds it once an assistive client asks. On its
  first request the driver reads its own windows through the AX API, which needs no permission
  for your own process. SwiftUI's nodes don't declare `NSAccessibilityProtocol`, so the driver
  calls them through Objective-C dynamic dispatch.
- **Clicks.** A window that isn't key drops a click unless the view under it
  `acceptsFirstMouse(for:)`. SwiftUI buttons accept first mouse, but `onTapGesture` content
  doesn't. While the driver delivers a click, the views under it accept first mouse.
- **AppKit controls** (toolbar items, `NSButton`) wait inside `mouseDown` for the mouse-up, so the
  driver queues the up with `postEvent` before it sends the down.
- **Hover.** AppKit computes enter/exit from the real cursor, so a synthetic `mouseMoved` does
  nothing. The driver sends `mouseEntered`/`mouseExited` to the tracking areas themselves,
  which is what SwiftUI's `onHover` listens to.
- **Keys** go through `NSApp.sendEvent`, so local event monitors see them. Shortcuts try the
  target window's `performKeyEquivalent`, then menu items; items with no target (Hide, Copy, …)
  have their action sent down the target window's responder chain.
- **Stale geometry.** Right after SwiftUI moves things, the AppKit views it hosts can lag its
  layout for a moment. Before clicking, the driver waits (up to 2s) until hit-testing at the
  point reaches the view that owns the element, rather than whatever used to be there.
- **Covered windows.** macOS reports a covered window as occluded, and SwiftUI then stops
  refreshing lazy containers in it. While the driver runs, windows report being visible.
- **Older elements.** Some AppKit elements (a SwiftUI `List`'s rows) only answer the
  attribute-based accessibility API, so the driver falls back to it for elements with no role.
- **Snapshots.** `views` makes the view hierarchy draw itself into a bitmap. It works on any
  display and behind other windows, with no Screen Recording permission. `windowserver`
  is the compositor's copy (`CGWindowListCreateImage`, which an app may use on its own windows).

## Known gaps

- ⌘W doesn't close a window when the app has no Close menu item (SwiftUI's `Window` scenes
  don't); use `POST /close`.
- No text typing into fields, drags, scrolling, or right clicks yet.
- Anything that depends on real activation or focus rings won't look the same as with a real
  mouse. For that, use XCUITest's real input ("foreground mode").
- A `LazyVGrid` in a background window doesn't swap one set of children for another (say,
  placeholders for loaded cards) even with the occlusion fix. Give it a new `.id` when that
  happens, as the app's overview does.

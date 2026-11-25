# JoyMapperSilicon

A macOS Dock app that maps Nintendo Switch 2 Joy-Con 2 (L and R) buttons and sticks to keyboard and mouse events. Each Joy-Con is its own controller with its own mappings, plus optional per-app overrides picked by the frontmost app.

It's a Dock app **on purpose**: no menu bar extra, no `LSUIElement`. Clicking the Dock icon opens the window. Closing the window keeps the app (and the mappings) running.

## Architecture

```
CoreBluetooth ──► Switch2Central ──► MappingEngine ──► CGEventPoster ──► macOS
   (BLE queue)     connection,        buttons diff,      CGEvent.post
                   setup, reports     stick → pointer
                        │                  ▲   │ previews (≤10 Hz)
                        │ events           │   ▼
                        └─────────► AppFeature (TCA store) ◄── SwiftUI views
                                      pushes MappingSnapshot on change
```

- `App/Sources/Controllers/Switch2/`: the Joy-Con 2 Bluetooth LE protocol.
  - `Switch2Protocol` parses advertisements and input reports, and builds commands.
  - `Switch2Central` scans, connects, runs setup, sends the keep-alive and pairs.
- `App/Sources/Mapping/`: `MappingEngine`, which is thread-safe and runs on its own queue. It turns input into `SyntheticEvent`s. `CGEventPoster` posts them, and `FileRecordingPoster` writes them to a file for tests.
- `App/Sources/Features/`: the TCA reducers. `AppFeature` is the root. `BindingEditorFeature` is the editor in the inspector.
  - Persistence is `@Shared(.fileStorage)`: `profiles.json` and `settings.json` in `~/Library/Application Support/JoyMapperSilicon`.
- `App/Sources/Dependencies/`: `ControllerClient`, `MappingEngineClient` and `SystemClient` (Accessibility, frontmost app, login item, Finder). `LiveRuntime` owns the long-lived engine and the central.
- Input reports never go through the store, because they arrive at report rate. The store only gets connection events and throttled previews.
- `Vendor/JoyConSwift`: the old Switch 1 HID framework. The app doesn't link it. It's kept for a possible Switch 1 Pro Controller transport.

## Joy-Con 2 protocol: facts verified on hardware

The full reference is in `docs/switch2-ble-protocol.md`.

- Joy-Con 2s are **not HID**. They're BLE peripherals with Nintendo's own GATT protocol, so macOS Bluetooth settings never see them. The app owns the whole connection. **Never pair them in System Settings**: SMP pairing makes them disconnect.
- Discovery uses manufacturer data `53 05 01 00 03 7e 05 <PID LE>`. 0x2067 is L and 0x2066 is R. A zero host address at index 0x0C–0x11 means pairing mode (SYNC held).
- Setup, in order:
  1. Subscribe to `C765A961…` (command replies).
  2. Write to `649D4AC9…` without response: read the calibration, set the player lights, set the feature mask (0x37), enable the features.
  3. Subscribe to `…7FD2` (63-byte input reports, about 28/s on this Mac).
- **Keep-alive:** macOS drops the link about 17 s after the host's last write. The app re-sends the player-lights command every second.
- **Pairing:** in pairing mode, the app sends the four `0x15` commands, which store this Mac's Bluetooth address. After that, any button press reconnects the controller without SYNC. This probably replaces the console pairing; attaching the controller to the Switch 2 pairs it back to the console.

## Accessibility permission

`CGEvent.post` **silently does nothing** without Accessibility permission. Check it with `AXIsProcessTrusted()`, and use the banner in the app.

The app is signed with an Apple Development certificate, which keeps the grant across rebuilds. If it's lost anyway, toggle the app off and on in System Settings → Privacy & Security → Accessibility. To clear stale entries: `tccutil reset Accessibility com.elliotfiske.JoyMapperSilicon`.

## Build, run, test

- `mise exec -- tuist generate --no-open` generates the project (Tuist 4.211 via `.mise.toml`). Pass `-skipMacroValidation` to `xcodebuild` for TCA's macros.
- `scripts/run.sh` builds Debug and relaunches the app in the background.
- `scripts/test.sh [unit|ui|all]` runs the tests:
  - **unit**: reducers (`TestStore`), protocol parsing using bytes captured from the real controllers, and the mapping engine.
  - **ui**: background UI tests. They launch a fresh app copy with simulated Joy-Cons, a temporary data folder and an event log, and drive it through BackgroundDriver. They never take focus or touch the real mouse or keyboard, so they're safe to run while you work.

### Feedback loop with real controllers

- Log: `tail -f ~/Library/Logs/JoyMapperSilicon/joymapper.log`. The same lines go to the unified log, subsystem `com.elliotfiske.JoyMapperSilicon`. Categories:
  - `ble`: connection, setup commands and replies, calibration, battery, raw button bits.
  - `input`: decoded presses.
  - `mapping`: what got posted.
  - `app`: lifecycle and permissions.
- The "Log raw reports" toggle in the sidebar adds hex dumps of the input reports.
- `scripts/driver.sh` reads and drives the running Debug app's UI without the mouse (see `Packages/BackgroundDriver/README.md`). For example, `scripts/driver.sh GET '/elements?id=pressed-'` shows live button state, and `scripts/driver.sh GET /snapshot > shot.png` saves a picture of the window.
- `scripts/simulate.sh` drives a copy launched with `JOYMAPPER_SIMULATED_CONTROLLERS`.

### BackgroundDriver

`Packages/BackgroundDriver` is copied from the standup-dashboard repo (`Packages/BackgroundDriver`), where it's developed. Re-sync it with `rsync -a --delete --exclude .build`. In a background window it can't click into sheets or change a `List`'s selection. That's why the binding editor is an `.inspector`, and why sidebar rows also select on tap.

## GitHub: switching accounts for this personal repo

This repo (`elliotfiske/JoyMapperSilicon`) belongs to a personal GitHub account, but the active `gh` session uses an Enterprise Managed User (`efiske_life360`). Switch accounts for GitHub operations:

```bash
gh auth switch --user elliotfiske && <gh command>; gh auth switch --user efiske_life360
```

`gh auth` state is global, so switching also affects any other agents running at the time.

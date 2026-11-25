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

## Dictation

A floating pill on the right edge of the screen: an `NSPanel` that never takes focus (`FloatingDictationPanel`). It expands while you dictate.

- **Start and stop:** hold Right ⌥, ⌃⌥Space to start or stop, ⌃⌥V to paste the last dictation (`HotkeyMonitor`, a session event tap that needs Accessibility). Joy-Con buttons can also have a `DictationAction`: in the starter R mapping, C is hold-to-talk and Home pastes the last dictation.
- **Pipeline (`DictationFeature`):**
  1. Record from the microphone into a file (48 kHz float), and run on-device `SpeechAnalyzer`/`DictationTranscriber` at the same time, so the transcript is live.
  2. On stop, **Parakeet TDT 0.6B v2** (`ParakeetRecognizer`, FluidAudio, about 0.1 s) transcribes the saved file, and its text replaces Apple's. Apple's is kept in `liveText`. If Parakeet isn't loaded, fails, or returns nothing where Apple heard words, Apple's text is used. The model (about 450 MB) downloads at first launch into `Application Support/JoyMapperSilicon/Models`, shared by every copy, and later loads in about 0.2 s. `Tools/SpeechBakeoff` compares recognizers on saved recordings: Parakeet beat Apple and Whisper there.
  3. Bias Apple's live recognition with dictionary terms plus symbols read from the frontmost window (`ScreenContext`, through Accessibility).
  4. Claude cleans up the text through the company LLM gateway (`CleanupService`, Sonnet 5.5 with `thinking: between_tools` at low effort).
  5. Paste the result (`TextInserter`, which puts your clipboard back afterwards).
  If cleanup fails or times out, the raw text is pasted instead.
- **Never commit the gateway URL, key, token command or anything company-specific.** All of it lives in `~/Library/Application Support/JoyMapperSilicon/dictation-settings.json`, and a static key, if used, in the Keychain (`GatewayKeychain`).
- **Gateway auth (`GatewayAuth`):** either a static key, or a *token command* that prints a short-lived token (an SSO helper).
  - The app runs the command only **quietly**: `BROWSER=/usr/bin/true`, plus the configured quiet-run environment variables, with a 20 s timeout.
  - If that fails, cleanup is skipped and the panel shows "Log in again to turn on Claude cleanup". Only the **Log in** button runs the command interactively, which may open a browser. The app never starts a sign-in on its own.
  - The token is kept in memory and fetched again 5 minutes before its JWT `exp`. A 401 triggers one quiet refetch and retry.
- Settings decode with defaults for missing keys, so adding a setting doesn't reset an existing file.
- **History:** `Dictation/history.jsonl` (append-only; the newest line per ID wins) and `Dictation/Audio/<id>.caf`. Nothing is deleted.
- **Test hooks:**
  - `JOYMAPPER_DICTATION_AUDIO_FILE=<file>` reads that file instead of the microphone. Make one with `say -o x.aiff "…"`.
  - `JOYMAPPER_CLEANUP_STUB=1` returns `[clean] <raw>` without calling the gateway.
  - With `JOYMAPPER_EVENT_LOG` set, pasted text is recorded instead of pasted.

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

## Accessibility permission and signing

`CGEvent.post` and the dictation hotkey tap **silently do nothing** without Accessibility permission. The launch log line says `Accessibility granted` or `missing`.

macOS ties the grant to the app's *designated requirement*:
- An **ad-hoc** signature makes that requirement a hash of the binary. Every rebuild then loses the grant, while System Settings still shows it on. That's the "it's granted but nothing comes through" bug.
- Debug builds therefore sign with a self-signed certificate, **"JoyMapper Silicon Local Signing"**, which exists only on this Mac. The requirement becomes `identifier "com.elliotfiske.JoyMapperSilicon" and certificate leaf = H"…"`, which survives rebuilds and works from any worktree. Check it with `codesign -d -r- <app>`.

Setup and recovery:
- **Once per Mac:** `scripts/setup-local-signing.sh`. It creates the certificate and asks for your password once, to trust it for code signing.
- Without the certificate, the build fails. Run the script, or set `TUIST_SIGNING_IDENTITY=-` for ad-hoc.
- Debug turns hardened runtime off. Its library validation only loads code with the app's Team ID, a self-signed certificate has none, so it would reject the debug dylib and the test bundle. Release keeps hardened runtime on.
- If a stale grant ever sticks: `tccutil reset Accessibility com.elliotfiske.JoyMapperSilicon`, relaunch, then click **Grant…** in the app.

## Build, run, test

- `mise exec -- tuist generate --no-open` generates the project (Tuist 4.211 via `.mise.toml`). Pass `-skipMacroValidation` to `xcodebuild` for TCA's macros.
- `scripts/run.sh` builds Debug and relaunches the app in the background.
- `scripts/test.sh [unit|ui|all]` runs the tests:
  - **unit**: reducers (`TestStore`), protocol parsing using bytes captured from the real controllers, and the mapping engine.
  - **ui**: background UI tests. They launch a fresh app copy with simulated Joy-Cons, a temporary data folder and an event log, and drive it through BackgroundDriver. They never take focus or touch the real mouse or keyboard, so they're safe to run while you work.

### Feedback loop with real controllers

- Log: `tail -f ~/Library/Logs/JoyMapperSilicon/joymapper.log`. Every line has the process ID, because your copy and test copies share the file. The unified log has the same lines: use `/usr/bin/log show`, since plain `log` is a zsh builtin. The same lines go to the unified log, subsystem `com.elliotfiske.JoyMapperSilicon`. Categories:
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

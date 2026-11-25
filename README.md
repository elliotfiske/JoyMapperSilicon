# JoyMapper Silicon

Maps Nintendo Switch 2 **Joy-Con 2** buttons and sticks to keyboard keys and mouse actions on macOS, so you can drive your Mac from a controller. For example, you can browse while walking on a treadmill.

- Each Joy-Con is its own controller, with its own mappings.
- Per-app overrides switch with the frontmost app.
- The left stick moves the pointer, and the right stick scrolls. Either stick can also send keys, in eight directions.
- Bindings can be any key with modifiers, media keys, or mouse buttons (including dragging).
- It's a Dock app, not a menu bar app. Click the Dock icon to configure it; close the window and it keeps working.

## Connecting a Joy-Con 2

1. Open the app.
2. Hold the small **sync** button on the Joy-Con's rail side until the lights sweep. The app connects on its own, and one light stays on.
3. After that, pressing any button reconnects it; you don't need sync again.

Don't pair Joy-Con 2s in System Settings → Bluetooth. They use Nintendo's own Bluetooth LE protocol, and the app handles the connection itself. Pairing to the Mac likely replaces the Joy-Con's pairing with a Switch 2; attach it to the console to pair it back.

Grant **Accessibility** permission when the app asks. Without it, macOS silently ignores the keys and clicks the app sends.

## Development

Built with TCA and SwiftUI, and generated with Tuist. See [CLAUDE.md](CLAUDE.md) for the architecture, the Joy-Con 2 protocol notes, logging and tests.

```bash
scripts/run.sh         # build and launch in the background
scripts/test.sh all    # unit tests, then background UI tests (they never take over the screen)
```

## Acknowledgements

This app started as a fork of [qibinc/JoyMapperSilicon](https://github.com/qibinc/JoyMapperSilicon), which was based on [magicien/JoyKeyMapper](https://github.com/magicien/JoyKeyMapper). The Joy-Con 2 protocol work builds on [ndeadly/switch2_controller_research](https://github.com/ndeadly/switch2_controller_research), SDL's Switch 2 driver and [switch2mac](https://github.com/Peterksharma/switch2mac).

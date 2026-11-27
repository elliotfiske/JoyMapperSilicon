import AppKit
import CoreGraphics

/// Global dictation hotkeys, through a session event tap (needs Accessibility):
/// - hold **Right Option** to talk; pressing any other key meanwhile cancels (it was a shortcut),
/// - **⌃⌥Space** starts and stops,
/// - **⌃⌥V** pastes the last dictation.
/// The two chords are swallowed so the frontmost app doesn't also see them.
final class HotkeyMonitor: @unchecked Sendable {
    struct Options: Equatable, Sendable {
        var holdKey: Bool
        var toggleKeys: Bool
    }

    private let continuation: AsyncStream<DictationCommand>.Continuation
    let commands: AsyncStream<DictationCommand>
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var options = Options(holdKey: true, toggleKeys: true)
    private var rightOptionDown = false
    private var holdActive = false
    private var loggedMissingPermission = false

    private static let rightOption: Int64 = 0x3D
    private static let space: Int64 = 0x31
    private static let vKey: Int64 = 0x09

    init() {
        (commands, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(20))
    }

    /// Returns false if the tap couldn't be created (no Accessibility permission yet).
    @MainActor
    @discardableResult
    func start(options: Options) -> Bool {
        self.options = options
        guard tap == nil else { return true }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, pointer in
                guard let pointer else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(pointer).takeUnretainedValue()
                return monitor.handle(type: type, event: event)
            },
            userInfo: pointer
        ) else {
            if !loggedMissingPermission {
                loggedMissingPermission = true
                Log.dictation.error("Couldn't create the hotkey event tap; Accessibility permission is probably missing. Retrying quietly.")
            }
            return false
        }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Log.dictation.notice("Hotkeys on: hold Right ⌥ \(options.holdKey ? "on" : "off"), ⌃⌥Space / ⌃⌥V \(options.toggleKeys ? "on" : "off")")
        return true
    }

    func update(options: Options) {
        self.options = options
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)

        case .flagsChanged:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            guard code == Self.rightOption, options.holdKey else { break }
            let isDown = event.flags.contains(.maskAlternate)
            if isDown, !rightOptionDown {
                rightOptionDown = true
                holdActive = true
                continuation.yield(.holdStarted(source: "hotkey"))
            } else if !isDown, rightOptionDown {
                rightOptionDown = false
                if holdActive {
                    holdActive = false
                    continuation.yield(.holdEnded)
                }
            }

        case .keyDown:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags
            if rightOptionDown, holdActive {
                holdActive = false
                continuation.yield(.holdCancelled)
            }
            let isChord = flags.contains(.maskControl) && flags.contains(.maskAlternate)
                && !flags.contains(.maskCommand) && !flags.contains(.maskShift)
            guard options.toggleKeys, isChord else { break }
            if code == Self.space {
                continuation.yield(.toggle(source: "hotkey"))
                return nil
            }
            if code == Self.vKey {
                continuation.yield(.pasteLast)
                return nil
            }

        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }
}

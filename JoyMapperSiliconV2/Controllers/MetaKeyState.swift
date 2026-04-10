// JoyMapperSiliconV2/Controllers/MetaKeyState.swift
import InputMethodKit

private let shiftKey = Int32(kVK_Shift)
private let optionKey = Int32(kVK_Option)
private let controlKey = Int32(kVK_Control)
private let commandKey = Int32(kVK_Command)
private let metaKeys = [kVK_Shift, kVK_Option, kVK_Control, kVK_Command]
private nonisolated(unsafe) var pushedKeyConfigs = Set<KeyMap>()

func resetMetaKeyState() {
    let source = CGEventSource(stateID: .hidSystemState)
    pushedKeyConfigs.removeAll()

    DispatchQueue.main.async {
        metaKeys.forEach {
            let ev = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode($0), keyDown: false)
            ev?.post(tap: .cghidEventTap)
        }
    }
}

func getMetaKeyState() -> (shift: Bool, option: Bool, control: Bool, command: Bool) {
    var shift = false
    var option = false
    var control = false
    var command = false

    pushedKeyConfigs.forEach {
        let modifiers = NSEvent.ModifierFlags(rawValue: UInt($0.modifiers))
        shift = shift || modifiers.contains(.shift)
        option = option || modifiers.contains(.option)
        control = control || modifiers.contains(.control)
        command = command || modifiers.contains(.command)
    }

    return (shift, option, control, command)
}

func metaKeyEvent(config: KeyMap, keyDown: Bool) {
    var shift: Bool
    var option: Bool
    var control: Bool
    var command: Bool

    if keyDown {
        (shift, option, control, command) = getMetaKeyState()
        pushedKeyConfigs.insert(config)
    } else {
        pushedKeyConfigs.remove(config)
        (shift, option, control, command) = getMetaKeyState()
    }

    let source = CGEventSource(stateID: .hidSystemState)
    let modifiers = NSEvent.ModifierFlags(rawValue: UInt(config.modifiers))
    if !shift && modifiers.contains(.shift) {
        let ev = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Shift), keyDown: keyDown)
        ev?.post(tap: .cghidEventTap)
    }

    if !option && modifiers.contains(.option) {
        let ev = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Option), keyDown: keyDown)
        ev?.post(tap: .cghidEventTap)
    }

    if !control && modifiers.contains(.control) {
        let ev = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Control), keyDown: keyDown)
        ev?.post(tap: .cghidEventTap)
    }

    if !command && modifiers.contains(.command) {
        let ev = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Command), keyDown: keyDown)
        ev?.post(tap: .cghidEventTap)
    }
}

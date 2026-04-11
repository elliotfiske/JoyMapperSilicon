// JoyMapperSiliconV2/Utilities/KeyConfigClipboard.swift
import AppKit

enum KeyConfigClipboard {
    static let pasteboardType = NSPasteboard.PasteboardType("com.elliotfiske.JoyMapperSilicon.KeyConfig")

    static func copy(_ keyConfig: KeyConfig) {
        guard let data = try? JSONEncoder().encode(keyConfig) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(data, forType: pasteboardType)
    }

    static func paste() -> KeyConfig? {
        guard let data = NSPasteboard.general.data(forType: pasteboardType) else { return nil }
        return try? JSONDecoder().decode(KeyConfig.self, from: data)
    }

    static func canPaste() -> Bool {
        NSPasteboard.general.data(forType: pasteboardType) != nil
    }
}

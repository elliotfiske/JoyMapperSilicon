import AppKit
import ApplicationServices
import Foundation

/// Names the user might say, read from the frontmost window: code identifiers, file names,
/// product names. They bias on-device recognition and tell the cleanup pass how to spell things.
///
/// Reads the window through the Accessibility API (the same permission the mappings need):
/// - the window title (editors put the file and project there),
/// - the document file, when the app exposes one (Xcode and most native editors), read from disk,
/// - the visible text of the window (browsers for GitHub and Notion, Conductor, VS Code with its
///   accessibility support on), capped so a huge page can't stall dictation.
struct ScreenContext: Equatable, Sendable {
    var appName: String?
    var bundleID: String?
    var windowTitle: String?
    var symbols: [String] = []

    static let empty = ScreenContext()

    /// Stops walking the window after this many characters or elements.
    private static let maxCharacters = 200_000
    private static let maxElements = 4_000
    static let maxSymbols = 300

    static func capture(from app: NSRunningApplication?) -> ScreenContext {
        guard let app else { return .empty }
        var context = ScreenContext(appName: app.localizedName, bundleID: app.bundleIdentifier)
        guard AXIsProcessTrusted() else { return context }

        let started = Date()
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.25)
        guard let window: AXUIElement = attribute(element, kAXFocusedWindowAttribute) else { return context }

        context.windowTitle = attribute(window, kAXTitleAttribute)
        var text = context.windowTitle ?? ""

        if let document: String = attribute(window, kAXDocumentAttribute),
           let url = URL(string: document), url.isFileURL,
           let contents = try? String(contentsOf: url, encoding: .utf8) {
            text += "\n" + url.lastPathComponent + "\n" + String(contents.prefix(maxCharacters))
        }

        var visited = 0
        collectText(from: window, into: &text, visited: &visited)

        context.symbols = extractSymbols(from: text)
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        Log.dictation.info("Screen context from \(app.localizedName ?? "?"): \(context.symbols.count) symbols, \(text.count) chars, \(visited) elements, \(elapsed) ms")
        return context
    }

    private static func collectText(from element: AXUIElement, into text: inout String, visited: inout Int) {
        guard visited < maxElements, text.count < maxCharacters else { return }
        visited += 1
        for key in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
            if let value: String = attribute(element, key), !value.isEmpty {
                text += "\n" + value
            }
        }
        guard let children: [AXUIElement] = attribute(element, kAXChildrenAttribute) else { return }
        for child in children {
            collectText(from: child, into: &text, visited: &visited)
        }
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    /// Identifier-like words, most frequent first: CamelCase, camelCase, snake_case, kebab-case
    /// file names, and words with digits like Switch2Central. Plain lowercase words are left out:
    /// recognition already knows English.
    static func extractSymbols(from text: String) -> [String] {
        var counts: [String: Int] = [:]
        let pattern = /[A-Za-z_][A-Za-z0-9_]*(?:[.\-][A-Za-z0-9_]+)*/
        for match in text.matches(of: pattern) {
            for word in candidates(from: String(match.output)) {
                guard word.count >= 4, word.count <= 60, looksLikeSymbol(word) else { continue }
                counts[word, default: 0] += 1
            }
        }
        let ranked = counts.sorted { lhs, rhs in
            lhs.value != rhs.value ? lhs.value > rhs.value : lhs.key < rhs.key
        }
        return ranked.prefix(maxSymbols).map(\.key)
    }

    /// `JoyConManager.shared.connectHandler` → each part. `AppDelegate.swift` → the file name
    /// and its base name, since people say file names whole.
    static func candidates(from token: String) -> [String] {
        let parts = token.split { $0 == "." }.map(String.init)
        guard parts.count > 1 else { return [token] }
        let fileExtension = parts.last ?? ""
        let looksLikeFileName = parts.count == 2
            && (1...5).contains(fileExtension.count)
            && fileExtension.allSatisfy { $0.isLowercase || $0.isNumber }
        return looksLikeFileName ? [token, parts[0]] : parts
    }

    static func looksLikeSymbol(_ word: String) -> Bool {
        let hasUnderscore = word.contains("_")
        let hasDigit = word.contains(where: \.isNumber)
        let hasSeparator = word.contains(".") || word.contains("-")
        let letters = word.filter(\.isLetter)
        let uppercaseCount = letters.filter(\.isUppercase).count
        let startsLower = word.first?.isLowercase == true
        // "JoyConManager", "connectHandler", "URLSession": a capital after the first letter.
        let hasInnerCapital = word.dropFirst().contains(where: \.isUppercase)
        let isAllCaps = uppercaseCount == letters.count
        if isAllCaps { return letters.count >= 3 && letters.count <= 8 } // acronyms: HTTP, BLE
        if hasInnerCapital { return true }
        if hasUnderscore || hasDigit { return true }
        if hasSeparator, startsLower { return true } // file names: AppDelegate.swift, my-file.ts
        return false
    }
}

/// Puts text into the frontmost app by pasting it, then puts the clipboard back.
enum TextInserter {
    static func paste(_ text: String) async {
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.pasteboardItems?.map { item -> [NSPasteboard.PasteboardType: Data] in
            var copy: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { copy[type] = data }
            }
            return copy
        } ?? []

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let changeCount = pasteboard.changeCount

        let poster = CGEventPoster()
        let vKey = 0x09 // kVK_ANSI_V
        poster.post(.key(code: 0x37, down: true, modifiers: [.command]))
        poster.post(.key(code: vKey, down: true, modifiers: [.command]))
        poster.post(.key(code: vKey, down: false, modifiers: [.command]))
        poster.post(.key(code: 0x37, down: false, modifiers: []))

        // Give the app time to read the clipboard before putting the old contents back.
        try? await Task.sleep(for: .milliseconds(400))
        guard pasteboard.changeCount == changeCount else { return } // something else copied since
        pasteboard.clearContents()
        let items = saved.map { contents -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in contents { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }
}

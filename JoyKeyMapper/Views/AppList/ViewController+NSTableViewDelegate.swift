//
//  ViewController+NSTableViewDelegate.swift
//  JoyKeyMapper
//
//  Created by magicien on 2019/07/21.
//  Copyright © 2019 DarkHorse. All rights reserved.
//

import AppKit
import JoyConSwift

let appNameColumnID = "appName"

extension ViewController: NSTableViewDelegate, NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView === self.appTableView {
            return self.numRowsOfAppTableView()
        }
        
        return 0
    }
    
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === self.appTableView {
            return self.viewForAppTable(column: tableColumn, row: row)
        }

        return nil
    }

    // MARK: - AppTableView
    
    func convertAppName(_ name: String?) -> String {
        guard var appName = name else { return "" }
        
        if appName.hasSuffix(".app") {
            appName.removeLast(4)
        }
        appName = appName.replacingOccurrences(of: "%20", with: " ")
        
        return appName
    }
    
    func numRowsOfAppTableView() -> Int {
        guard let controller = self.selectedController else { return 0 }
        
        let numApps = controller.data.appConfigs?.count ?? 0
        
        return numApps + 1
    }
    
    func viewForAppTable(column: NSTableColumn?, row: Int) -> NSView? {
        guard let controller = self.selectedController else { return nil }
        guard let col = column else { return nil }
        guard let newView = self.appTableView.makeView(withIdentifier: col.identifier, owner: self) as? AppCellView else { return nil }
        
        if row == 0 {
            newView.appIcon.image = NSImage(named: "GenericApplicationIcon")
            newView.appName.stringValue = "Default"
        } else {
            guard let appConfig = controller.data.appConfigs?[row - 1] as? AppConfig else { return nil }
            guard let appData = appConfig.app else { return nil }

            if let icon = appData.icon {
                newView.appIcon.image = NSImage(data: icon)
            } else {
                newView.appIcon.image = NSImage(named: "GenericApplicationIcon")
            }
            
            newView.appName.stringValue = self.convertAppName(appData.displayName)
        }
        
        return newView
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        self.updateAppAddRemoveButtonState()
        self.configTableView.reloadData()
    }

    // MARK: - Copy/Paste Configuration

    func copySelectedConfig() {
        guard let keyConfig = self.selectedKeyConfig else {
            NSSound.beep()
            return
        }

        let clipboardData = KeyConfigClipboardData(from: keyConfig)
        guard let data = try? JSONEncoder().encode(clipboardData) else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(data, forType: keyConfigPasteboardType)
    }

    func pasteToSelectedConfig() {
        guard let keyConfig = self.selectedKeyConfig else {
            NSSound.beep()
            return
        }

        let pasteboard = NSPasteboard.general
        guard let data = pasteboard.data(forType: keyConfigPasteboardType) else {
            NSSound.beep()
            return
        }
        guard let clipboardData = try? JSONDecoder().decode(KeyConfigClipboardData.self, from: data) else {
            NSSound.beep()
            return
        }

        self.applyClipboardData(clipboardData, to: keyConfig)
        self.configTableView.reloadData()
        self.selectedController?.updateKeyMap()
    }

    private func applyClipboardData(_ clipboardData: KeyConfigClipboardData, to keyConfig: KeyConfig) {
        for sourceMap in clipboardData.keyMaps {
            let existing = keyConfig.keyMaps?.first(where: { obj in
                guard let km = obj as? KeyMap else { return false }
                return km.button == sourceMap.button
            }) as? KeyMap

            if let targetMap = existing {
                targetMap.keyCode = sourceMap.keyCode
                targetMap.modifiers = sourceMap.modifiers
                targetMap.mouseButton = sourceMap.mouseButton
                targetMap.isEnabled = sourceMap.isEnabled
            } else {
                guard let newMap = self.appDelegate?.dataManager?.createKeyMap() else { continue }
                newMap.button = sourceMap.button
                newMap.keyCode = sourceMap.keyCode
                newMap.modifiers = sourceMap.modifiers
                newMap.mouseButton = sourceMap.mouseButton
                newMap.isEnabled = sourceMap.isEnabled
                keyConfig.addToKeyMaps(newMap)
            }
        }

        if let sourceStick = clipboardData.leftStick, let targetStick = keyConfig.leftStick {
            applyStickData(sourceStick, to: targetStick)
        }
        if let sourceStick = clipboardData.rightStick, let targetStick = keyConfig.rightStick {
            applyStickData(sourceStick, to: targetStick)
        }
    }

    private func applyStickData(_ source: StickConfigData, to target: StickConfig) {
        target.type = source.type
        target.speed = source.speed

        for sourceMap in source.keyMaps {
            let existing = target.keyMaps?.first(where: { obj in
                guard let km = obj as? KeyMap else { return false }
                return km.button == sourceMap.button
            }) as? KeyMap

            if let targetMap = existing {
                targetMap.keyCode = sourceMap.keyCode
                targetMap.modifiers = sourceMap.modifiers
                targetMap.mouseButton = sourceMap.mouseButton
                targetMap.isEnabled = sourceMap.isEnabled
            }
        }
    }

    // MARK: - Context Menu

    func setupAppTableContextMenu() {
        let menu = NSMenu()
        menu.delegate = self
        self.appTableView.menu = menu
    }
}

extension ViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        guard menu === self.appTableView.menu else { return }

        let clickedRow = self.appTableView.clickedRow
        guard clickedRow >= 0 else { return }

        self.appTableView.selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)

        let copyItem = NSMenuItem(title: NSLocalizedString("Copy Configuration", comment: "Copy Configuration"),
                                  action: #selector(copyConfigMenuAction(_:)), keyEquivalent: "")
        copyItem.target = self
        menu.addItem(copyItem)

        let pasteItem = NSMenuItem(title: NSLocalizedString("Paste Configuration", comment: "Paste Configuration"),
                                   action: #selector(pasteConfigMenuAction(_:)), keyEquivalent: "")
        pasteItem.target = self
        let hasPasteData = NSPasteboard.general.data(forType: keyConfigPasteboardType) != nil
        pasteItem.isEnabled = hasPasteData
        menu.addItem(pasteItem)
    }

    @objc func copyConfigMenuAction(_ sender: NSMenuItem) {
        self.copySelectedConfig()
    }

    @objc func pasteConfigMenuAction(_ sender: NSMenuItem) {
        self.pasteToSelectedConfig()
    }
}

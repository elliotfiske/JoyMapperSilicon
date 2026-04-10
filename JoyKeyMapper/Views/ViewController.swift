//
//  ViewController.swift
//  JoyKeyMapper
//
//  Created by magicien on 2019/07/14.
//  Copyright © 2019 DarkHorse. All rights reserved.
//

import AppKit
import InputMethodKit
import JoyConSwift

class ViewController: NSViewController {
    
    @IBOutlet weak var controllerCollectionView: NSCollectionView!
    @IBOutlet weak var appTableView: NSTableView!
    @IBOutlet weak var appAddRemoveButton: NSSegmentedControl!
    @IBOutlet weak var configTableView: NSOutlineView!
    
    var appDelegate: AppDelegate? {
        return NSApplication.shared.delegate as? AppDelegate
    }
    var selectedController: GameController? {
        didSet {
            self.appTableView.reloadData()
            self.configTableView.reloadData()
            self.updateAppAddRemoveButtonState()
        }
    }
    var selectedControllerData: ControllerData? {
        return self.selectedController?.data
    }
    var selectedAppConfig: AppConfig? {
        guard let data = self.selectedControllerData else {
            return nil
        }
        let row = self.appTableView.selectedRow
        if row < 1 {
            return nil
        }
        return data.appConfigs?[row - 1] as? AppConfig
    }
    var selectedKeyConfig: KeyConfig? {
        if self.appTableView.selectedRow < 0 {
            return nil
        }
        return self.selectedAppConfig?.config ?? self.selectedControllerData?.defaultConfig
    }
    var keyDownHandler: Any?

    private var accessibilityBanner: NSView?
    private var accessibilityCheckTimer: Timer?
    private var connectionLogPanel: ConnectionLogPanelView?

    override func viewDidLoad() {
        super.viewDidLoad()

        if self.controllerCollectionView == nil { return }

        self.controllerCollectionView.delegate = self
        self.controllerCollectionView.dataSource = self

        self.appTableView.delegate = self
        self.appTableView.dataSource = self

        self.configTableView.delegate = self
        self.configTableView.dataSource = self

        self.setupAppTableContextMenu()
        self.updateAppAddRemoveButtonState()

        self.setupAccessibilityBanner()
        self.updateAccessibilityBanner()
        self.accessibilityCheckTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.updateAccessibilityBanner()
        }

        NotificationCenter.default.addObserver(self, selector: #selector(controllerAdded), name: .controllerAdded, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(controllerRemoved), name: .controllerRemoved, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(controllerConnected), name: .controllerConnected, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(controllerDisconnected), name: .controllerDisconnected, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(controllerIconChanged), name: .controllerIconChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(controllerConnecting), name: .controllerConnecting, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(controllerConnectionFailed), name: .controllerConnectionFailed, object: nil)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if connectionLogPanel == nil {
            setupConnectionLogPanel()
        }
    }

    override func viewDidDisappear() {
        self.accessibilityCheckTimer?.invalidate()
        self.accessibilityCheckTimer = nil
    }

    // MARK: - Accessibility Banner

    private func setupAccessibilityBanner() {
        let banner = NSView()
        banner.translatesAutoresizingMaskIntoConstraints = false
        banner.wantsLayer = true
        banner.layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.15).cgColor

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Warning")
        icon.contentTintColor = .systemYellow
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let label = NSTextField(wrappingLabelWithString: "Accessibility permission is required for key mapping to work. Grant access in System Settings.")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .labelColor

        let requestButton = NSButton(title: "Request Access…", target: self, action: #selector(requestAccessibilityAccess))
        requestButton.translatesAutoresizingMaskIntoConstraints = false
        requestButton.bezelStyle = .recessed
        requestButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        requestButton.setContentHuggingPriority(.required, for: .horizontal)

        let settingsButton = NSButton(title: "Open Settings…", target: self, action: #selector(openAccessibilitySettings))
        settingsButton.translatesAutoresizingMaskIntoConstraints = false
        settingsButton.bezelStyle = .recessed
        settingsButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        settingsButton.setContentHuggingPriority(.required, for: .horizontal)

        banner.addSubview(icon)
        banner.addSubview(label)
        banner.addSubview(requestButton)
        banner.addSubview(settingsButton)

        self.view.addSubview(banner)

        NSLayoutConstraint.activate([
            banner.topAnchor.constraint(equalTo: self.view.topAnchor),
            banner.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),

            icon.leadingAnchor.constraint(equalTo: banner.leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: banner.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),

            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: banner.centerYAnchor),
            label.topAnchor.constraint(greaterThanOrEqualTo: banner.topAnchor, constant: 6),
            label.bottomAnchor.constraint(lessThanOrEqualTo: banner.bottomAnchor, constant: -6),

            requestButton.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 8),
            requestButton.centerYAnchor.constraint(equalTo: banner.centerYAnchor),

            settingsButton.leadingAnchor.constraint(equalTo: requestButton.trailingAnchor, constant: 4),
            settingsButton.trailingAnchor.constraint(equalTo: banner.trailingAnchor, constant: -10),
            settingsButton.centerYAnchor.constraint(equalTo: banner.centerYAnchor),
        ])

        self.accessibilityBanner = banner
    }

    private func updateAccessibilityBanner() {
        let trusted = AXIsProcessTrusted()
        self.accessibilityBanner?.isHidden = trusted
    }

    @objc private func requestAccessibilityAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    @objc private func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    private func setupConnectionLogPanel() {
        guard let window = self.view.window else { return }
        guard let contentView = window.contentView else { return }

        // Replace window.contentView with an NSSplitView.
        // The old contentView becomes the top pane; the log panel is the bottom pane.
        let splitView = NSSplitView()
        splitView.isVertical = false  // horizontal split (top/bottom)
        splitView.dividerStyle = .thin

        let oldContentView = contentView
        let logPanel = ConnectionLogPanelView()
        self.connectionLogPanel = logPanel

        splitView.addArrangedSubview(oldContentView)
        splitView.addArrangedSubview(logPanel)

        window.contentView = splitView

        // Force layout so bounds are correct before setting divider position
        splitView.layoutSubtreeIfNeeded()

        // Set the log panel to its collapsed height (just the header bar)
        splitView.setPosition(splitView.bounds.height - 28, ofDividerAt: 0)

        // Set holding priorities so the log panel stays small and the main content resizes
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 1)
        splitView.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
    }

    override var representedObject: Any? {
        didSet {
        // Update the view, if already loaded.
        }
    }
    
    // MARK: - Apps
    
    @IBAction func clickAppSegmentButton(_ sender: NSSegmentedControl) {
        let selectedSegment = sender.selectedSegment
        
        if selectedSegment == 0 {
            self.addApp()
        } else if selectedSegment == 1 {
            self.removeApp()
        }
    }
    
    func updateAppAddRemoveButtonState() {
        if self.selectedController == nil {
            self.appAddRemoveButton.setEnabled(false, forSegment: 0)
            self.appAddRemoveButton.setEnabled(false, forSegment: 1)
        } else if self.appTableView.selectedRow < 1 {
            self.appAddRemoveButton.setEnabled(true, forSegment: 0)
            self.appAddRemoveButton.setEnabled(false, forSegment: 1)
        } else {
            self.appAddRemoveButton.setEnabled(true, forSegment: 0)
            self.appAddRemoveButton.setEnabled(true, forSegment: 1)
        }        
    }
    
    func addApp() {
        guard let controller = self.selectedController else { return }
        
        let panel = NSOpenPanel()
        panel.message = NSLocalizedString("Choose an app to add", comment: "Choosing app message")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canCreateDirectories = false
        panel.canChooseFiles = true
        panel.allowedFileTypes = ["app"]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.begin { [weak self] response in
            if response == .OK {
                guard let url = panel.url else { return }
                controller.addApp(url: url)
                self?.appTableView.reloadData()
            }
        }
    }
    
    func removeApp() {
        guard let controller = self.selectedController else { return }
        guard let appConfig = self.selectedAppConfig else { return }
        let appName = self.convertAppName(appConfig.app?.displayName)
        
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String.localizedStringWithFormat(NSLocalizedString("Do you really want to delete the settings for %@?", comment: "Do you really want to delete the settings for <app>?"), appName)
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Cancel"))
        alert.addButton(withTitle: NSLocalizedString("OK", comment: "OK"))
        let result = alert.runModal()
        
        if result == .alertSecondButtonReturn {
            controller.removeApp(appConfig)
            self.appTableView.reloadData()
            self.configTableView.reloadData()
        }
    }
    
    // MARK: - Controllers
    
    @objc func controllerAdded() {
        DispatchQueue.main.async { [weak self] in
            self?.controllerCollectionView.reloadData()
        }
    }
    
    @objc func controllerConnected() {
        DispatchQueue.main.async { [weak self] in
            self?.controllerCollectionView.reloadData()
        }
    }
    
    @objc func controllerDisconnected() {
        DispatchQueue.main.async { [weak self] in
            self?.controllerCollectionView.reloadData()
        }
    }
    
    @objc func controllerRemoved(_ notification: NSNotification) {
        guard let gameController = notification.object as? GameController else { return }
        
        DispatchQueue.main.async { [weak self] in
            guard let _self = self else { return }
            let numItems = _self.controllerCollectionView.numberOfItems(inSection: 0)
            for i in 0..<numItems {
                if let item = self?.controllerCollectionView.item(at: i) as? ControllerViewItem {
                    if item.controller === gameController {
                        self?.controllerCollectionView.deselectAll(nil)
                    }
                }
            }
            self?.controllerCollectionView.reloadData()
        }
    }
    
    @objc func controllerIconChanged(_ notification: NSNotification) {
        guard let gameController = notification.object as? GameController else { return }

        DispatchQueue.main.async { [weak self] in
            self?.controllerCollectionView.reloadData()
        }
    }

    @objc func controllerConnecting() {
        DispatchQueue.main.async { [weak self] in
            self?.controllerCollectionView.reloadData()
        }
    }

    @objc func controllerConnectionFailed() {
        DispatchQueue.main.async { [weak self] in
            self?.controllerCollectionView.reloadData()
        }
    }

    // MARK: - Copy/Paste

    @objc func copy(_ sender: Any?) {
        self.copySelectedConfig()
    }

    @objc func paste(_ sender: Any?) {
        self.pasteToSelectedConfig()
    }

    // MARK: - Import
    
    @IBAction func importKeyMappings(_ sender: NSButton) {
    }
    
    // MARK: - Export
    
    @IBAction func exportKeyMappngs(_ sender: NSButton) {
        return
        /*
        guard let dataManager = self.appDelegate?.dataManager else { return }

        let savePanel = NSSavePanel()
        savePanel.message = NSLocalizedString("Save key mapping data", comment: "Save key mapping data")
        savePanel.allowedFileTypes = ["jkmap"]
        
        savePanel.begin { response in
            guard response == .OK else { return }
            guard let filePath = savePanel.url?.absoluteString.removingPercentEncoding else { return }
        }
        */
    }
    
    // MARK: - Options
    
    @IBAction func didPushOptions(_ sender: NSButton) {
        guard let controller = self.storyboard?.instantiateController(withIdentifier: "AppSettingsViewController") as? AppSettingsViewController else { return }
        
        self.presentAsSheet(controller)
    }
}

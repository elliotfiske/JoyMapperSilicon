//
//  ConnectionLogPanelView.swift
//  JoyKeyMapper
//

import AppKit

class ConnectionLogPanelView: NSView {
    private let headerView = NSView()
    private let scrollView = NSScrollView()
    private let textView = NSTextView()
    private let collapseButton = NSButton()
    private var isExpanded = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
        observeLog()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
        observeLog()
    }

    private func setupViews() {
        self.translatesAutoresizingMaskIntoConstraints = false

        // Header bar
        headerView.translatesAutoresizingMaskIntoConstraints = false
        headerView.wantsLayer = true
        headerView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        addSubview(headerView)

        let titleLabel = NSTextField(labelWithString: "Connection Log")
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        headerView.addSubview(titleLabel)

        let copyButton = NSButton(title: "Copy Log", target: self, action: #selector(copyLog))
        copyButton.translatesAutoresizingMaskIntoConstraints = false
        copyButton.bezelStyle = .recessed
        copyButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        copyButton.setContentHuggingPriority(.required, for: .horizontal)
        headerView.addSubview(copyButton)

        collapseButton.translatesAutoresizingMaskIntoConstraints = false
        collapseButton.bezelStyle = .disclosure
        collapseButton.title = ""
        collapseButton.state = .off
        collapseButton.target = self
        collapseButton.action = #selector(toggleCollapse)
        collapseButton.setContentHuggingPriority(.required, for: .horizontal)
        headerView.addSubview(collapseButton)

        // Scroll view + text view
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        textView.isEditable = false
        textView.isSelectable = true
        textView.font = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        textView.backgroundColor = NSColor(white: 0.1, alpha: 1.0)
        textView.textColor = NSColor(white: 0.9, alpha: 1.0)
        textView.textContainerInset = NSSize(width: 8, height: 4)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isRichText = false

        scrollView.documentView = textView
        addSubview(scrollView)

        // Start collapsed
        scrollView.isHidden = true

        // Layout
        NSLayoutConstraint.activate([
            headerView.topAnchor.constraint(equalTo: topAnchor),
            headerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerView.heightAnchor.constraint(equalToConstant: 28),

            collapseButton.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 6),
            collapseButton.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: collapseButton.trailingAnchor, constant: 4),
            titleLabel.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),

            copyButton.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -10),
            copyButton.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),

            scrollView.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func observeLog() {
        NotificationCenter.default.addObserver(self, selector: #selector(logUpdated(_:)), name: .connectionLogUpdated, object: nil)
    }

    @objc private func logUpdated(_ notification: Notification) {
        guard let entry = notification.object as? String else { return }
        let appendBlock = { [weak self] in
            guard let self = self else { return }
            let storage = self.textView.textStorage!
            let needsNewline = storage.length > 0
            let text = (needsNewline ? "\n" : "") + entry
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular),
                .foregroundColor: NSColor(white: 0.9, alpha: 1.0)
            ]
            storage.append(NSAttributedString(string: text, attributes: attrs))
            self.textView.scrollToEndOfDocument(nil)
        }
        if Thread.isMainThread {
            appendBlock()
        } else {
            DispatchQueue.main.async(execute: appendBlock)
        }
    }

    @objc private func copyLog() {
        let text = ConnectionLog.shared.copyAll()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func toggleCollapse() {
        isExpanded.toggle()
        scrollView.isHidden = !isExpanded
        collapseButton.state = isExpanded ? .on : .off

        // Notify the enclosing split view to re-layout
        if let splitView = self.superview as? NSSplitView {
            splitView.adjustSubviews()
        }
    }
}

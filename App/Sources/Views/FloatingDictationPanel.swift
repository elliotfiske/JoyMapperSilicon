import AppKit
import ComposableArchitecture
import SwiftUI

/// The always-there dictation pill. It floats above other windows on every Space, sticks to the
/// right edge of the screen (drag it up or down), and never takes focus, so the text goes to the
/// app you were using. It grows to show the live transcript while you dictate.
@MainActor
final class FloatingDictationPanel {
    private let panel: NSPanel
    private var observers: [NSObjectProtocol] = []
    private var isRepositioning = false
    private static let centerKey = "FloatingDictationPanel.centerY"
    private static let edgeMargin: CGFloat = 6

    init(store: StoreOf<DictationFeature>) {
        let hosting = NSHostingController(rootView: FloatingDictationView(store: store))
        hosting.sizingOptions = [.preferredContentSize]
        panel = NSPanel(contentViewController: hosting)
        panel.styleMask = [.borderless, .nonactivatingPanel]
        panel.title = "Dictation"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = true

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didResizeNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.pinToEdge() }
        })
        observers.append(center.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rememberPosition() }
        })
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.pinToEdge() }
        })
        pinToEdge()
        panel.orderFrontRegardless()
    }

    /// Keeps the right edge on the screen's edge and the vertical center where the user left it,
    /// whatever size the content is.
    private func pinToEdge() {
        guard !isRepositioning, let screen = panel.screen ?? NSScreen.main else { return }
        isRepositioning = true
        defer { isRepositioning = false }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let savedCenter = UserDefaults.standard.object(forKey: Self.centerKey) as? Double
        let centerY = savedCenter.map { CGFloat($0) } ?? visible.midY
        let clampedCenter = min(max(centerY, visible.minY + size.height / 2), visible.maxY - size.height / 2)
        let origin = NSPoint(x: visible.maxX - size.width - Self.edgeMargin, y: clampedCenter - size.height / 2)
        panel.setFrameOrigin(origin)
    }

    private func rememberPosition() {
        guard !isRepositioning else { return }
        UserDefaults.standard.set(Double(panel.frame.midY), forKey: Self.centerKey)
        pinToEdge()
    }
}

struct FloatingDictationView: View {
    let store: StoreOf<DictationFeature>
    @State private var isHovering = false

    var body: some View {
        Group {
            if store.phase == .idle {
                collapsed
            } else {
                expanded
            }
        }
        .animation(.snappy(duration: 0.2), value: store.phase == .idle)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dictation-panel")
    }

    private var collapsed: some View {
        Button {
            store.send(.command(.toggle(source: "panel")))
        } label: {
            Image(systemName: "mic.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 34, height: 34)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.quaternary))
        }
        .buttonStyle(.plain)
        .opacity(isHovering ? 1 : 0.55)
        .padding(4)
        .help("Dictate: hold Right ⌥, or ⌃⌥Space to start and stop")
        .accessibilityIdentifier("dictation-toggle")
    }

    private var expanded: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                StatusDot(phase: store.phase)
                if store.phase == .listening {
                    LevelMeter(level: store.inputLevel)
                }
                Text(statusText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("dictation-state")
                Spacer(minLength: 12)
                if store.phase.isRecording {
                    Button("Done") { store.send(.stopTapped) }
                        .controlSize(.small)
                        .accessibilityIdentifier("dictation-stop")
                }
                if let id = store.current?.id, store.phase == .done || store.phase.isFailed {
                    Button("Copy") { store.send(.copyTapped(id)) }
                        .controlSize(.small)
                        .accessibilityIdentifier("dictation-copy")
                }
                Button {
                    store.send(.cancelTapped)
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .accessibilityLabel(store.phase.isBusy ? "Cancel" : "Close")
                .accessibilityIdentifier("dictation-cancel")
            }
            if store.needsLogin, !store.phase.isRecording {
                LoginNeededRow(store: store)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    Text(displayText)
                        .font(.body)
                        .foregroundStyle(store.phase.isBusy && store.phase != .cleaning ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .id("end")
                        .accessibilityIdentifier("dictation-live-text")
                }
                .frame(maxHeight: 160)
                .onChange(of: store.liveText) { proxy.scrollTo("end", anchor: .bottom) }
            }
        }
        .padding(12)
        .frame(width: 360)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.quaternary))
        .padding(4)
    }

    private var displayText: String {
        if store.liveText.isEmpty {
            switch store.phase {
            case .starting: return "Waiting for the microphone… (Bluetooth headsets take a moment)"
            case .listening: return "Listening on \(store.inputDeviceName ?? "the microphone")…"
            default: return ""
            }
        }
        return store.liveText
    }

    private var statusText: String {
        switch store.phase {
        case .idle: ""
        case .starting: "Opening microphone…"
        case .listening: store.mode == .hold ? "Listening — release to finish" : "Listening — ⌃⌥Space to finish"
        case .recognizing: "Finishing…"
        case .cleaning: "Cleaning up…"
        case .done: store.current?.pasted == true ? "Pasted" : (store.current?.correctionError == nil ? "Done" : "Done (not cleaned up)")
        case let .failed(message): message
        }
    }
}

/// Cleanup is off until the user signs in to the gateway again. Signing in only starts here.
struct LoginNeededRow: View {
    let store: StoreOf<DictationFeature>

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .foregroundStyle(.orange)
            Text("Log in again to turn on Claude cleanup")
                .font(.caption)
            Spacer(minLength: 8)
            Button(store.isLoggingIn ? "Signing in…" : "Log in") { store.send(.logInTapped) }
                .controlSize(.small)
                .disabled(store.isLoggingIn)
                .accessibilityIdentifier("dictation-log-in")
        }
        .padding(8)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dictation-login-needed")
    }
}

/// Five bars that follow the input level, so it's obvious whether the mic hears you.
private struct LevelMeter: View {
    let level: Float

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<5, id: \.self) { index in
                let threshold = Float(index) / 5
                RoundedRectangle(cornerRadius: 1)
                    .fill(level > threshold ? Color.red : Color.secondary.opacity(0.25))
                    .frame(width: 3, height: 4 + CGFloat(index) * 2.5)
            }
        }
        .animation(.linear(duration: 0.08), value: level)
        .accessibilityElement()
        .accessibilityLabel("Input level")
        .accessibilityValue(String(format: "%.2f", level))
        .accessibilityIdentifier("dictation-level")
    }
}

private struct StatusDot: View {
    let phase: DictationFeature.Phase
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .opacity(phase.isRecording && pulse ? 0.35 : 1)
            .animation(phase.isRecording ? .easeInOut(duration: 0.6).repeatForever() : .default, value: pulse)
            .onAppear { pulse = true }
    }

    private var color: Color {
        switch phase {
        case .starting: .orange
        case .listening: .red
        case .recognizing, .cleaning: .orange
        case .done: .green
        case .failed: .yellow
        case .idle: .gray
        }
    }
}

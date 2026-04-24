// JoyMapperSiliconV2/Views/AccessibilityBanner.swift
@preconcurrency import ApplicationServices
import SwiftUI

struct AccessibilityBanner: View {
    @State private var isTrusted = AXIsProcessTrusted()

    let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        if !isTrusted {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text("Accessibility permission is required for key mapping to work.")
                    .font(.callout)
                Spacer()
                Button("Request Access\u{2026}") {
                    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
                    AXIsProcessTrustedWithOptions(options)
                }
                Button("Open Settings\u{2026}") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.yellow.opacity(0.15))
            .onReceive(timer) { _ in
                isTrusted = AXIsProcessTrusted()
            }
        }
    }
}

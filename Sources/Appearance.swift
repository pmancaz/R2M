import AppKit
import SwiftUI

// Shared system typography and semantic surfaces retain the native macOS
// interaction, accessibility and light/dark appearances.
enum R2MTheme {
    // Filled controls use a deeper tone so white system labels stay legible
    // in both appearances; secondary controls use the adaptive tone below.
    static let actionAccent = Color(red: 0.08, green: 0.43, blue: 0.40)
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.34, green: 0.73, blue: 0.67, alpha: 1)
            : NSColor(srgbRed: 0.08, green: 0.43, blue: 0.40, alpha: 1)
    })
}

private struct ControlSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        content.background {
            if reduceTransparency {
                Color(nsColor: .windowBackgroundColor)
            } else {
                Rectangle().fill(.bar)
            }
        }
    }
}

private struct PrimaryAction: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *), !reduceTransparency {
            content.tint(R2MTheme.actionAccent).buttonStyle(.glassProminent)
        } else {
            content.tint(R2MTheme.actionAccent).buttonStyle(.borderedProminent)
        }
    }
}

extension View {
    func r2mControlSurface() -> some View { modifier(ControlSurface()) }
    func r2mPrimaryAction() -> some View { modifier(PrimaryAction()) }
    func r2mAppearance() -> some View {
        self.font(.system(size: 13))
            .tint(R2MTheme.accent)
            .buttonStyle(.bordered)
            .buttonBorderShape(.roundedRectangle(radius: 8))
            .controlSize(.regular)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}

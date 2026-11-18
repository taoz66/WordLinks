import AppKit
import SwiftUI

/// A choice stays a normal content-layer control, with distinct selection,
/// pointer, press and keyboard-focus states in both system contrast modes.
struct ChoiceCardButtonStyle: ButtonStyle {
    let isSelected: Bool
    var cornerRadius: CGFloat = 14

    func makeBody(configuration: Configuration) -> some View {
        ChoiceCardBody(configuration: configuration, isSelected: isSelected,
                       cornerRadius: cornerRadius)
    }

    private struct ChoiceCardBody: View {
        let configuration: ButtonStyleConfiguration
        let isSelected: Bool
        let cornerRadius: CGFloat
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.isFocused) private var isFocused
        @Environment(\.colorSchemeContrast) private var contrast
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var isHovered = false

        private var increasedContrast: Bool { contrast == .increased }
        private var borderColor: Color {
            if isSelected { return .accentColor }
            return increasedContrast ? .primary : Color(nsColor: .separatorColor)
        }

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            let focusRingShape = RoundedRectangle(cornerRadius: cornerRadius + 4, style: .continuous)
            configuration.label
                .contentShape(shape)
                .background {
                    ZStack {
                        Color(nsColor: .controlBackgroundColor)
                        if isSelected {
                            Color.accentColor.opacity(increasedContrast ? 0.18 : 0.09)
                        }
                        if isEnabled && isHovered {
                            Color.primary.opacity(increasedContrast ? 0.10 : 0.05)
                        }
                        if configuration.isPressed {
                            Color.primary.opacity(increasedContrast ? 0.20 : 0.12)
                        }
                    }
                    .clipShape(shape)
                }
                .overlay {
                    shape.strokeBorder(borderColor,
                                       lineWidth: isSelected ? 2 : (increasedContrast ? 1.5 : 0.75))
                }
                .overlay {
                    focusRingShape.strokeBorder(isFocused ? Color.accentColor : .clear, lineWidth: 3)
                        .padding(-4)
                }
                .opacity(isEnabled ? 1 : 0.45)
                .onHover { isHovered = $0 }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovered)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
}

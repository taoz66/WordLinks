import AppKit
import SwiftUI

/// Content stays opaque and readable; only the native sheet/popover supplies material.
enum EditorSurface {
    static let cornerRadius: CGFloat = 8
    static let textInset = NSSize(width: 10, height: 10)
}

extension View {
    func editorSurface() -> some View {
        let shape = RoundedRectangle(cornerRadius: EditorSurface.cornerRadius, style: .continuous)
        return background(Color(nsColor: .textBackgroundColor), in: shape)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
    }
}

import AppKit
import SwiftUI

extension Notification.Name {
    /// Posted when the island stops receiving mouse events (pointer left, or it closed).
    static let isletResetHover = Notification.Name("IsletResetHover")
}

extension View {
    /// Like `.hoverState($hovering)`, but also clears the highlight when the island stops
    /// receiving mouse events. Without this, leaving the island right from a button meant the
    /// button never got its "hover ended" event and stayed highlighted.
    func hoverState(_ hovering: Binding<Bool>) -> some View {
        onHover { hovering.wrappedValue = $0 }
            .onReceive(NotificationCenter.default.publisher(for: .isletResetHover)) { _ in
                if hovering.wrappedValue { hovering.wrappedValue = false }
            }
    }
}

/// Hosting view that reacts to the first click even when the panel isn't key yet, so a click
/// right after the island opens is never swallowed just to focus the window.
final class IsletHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

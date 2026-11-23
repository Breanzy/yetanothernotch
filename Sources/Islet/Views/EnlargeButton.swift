import SwiftUI

/// ⤢ / ⤡ button that toggles the island's big mode (used by the clipboard and the mirror).
struct EnlargeButton: View {
    @EnvironmentObject var vm: NotchViewModel
    /// Extra work when enlarging (e.g. start the camera).
    var onEnlarge: () -> Void = {}
    @ViewState private var hovering = false

    var body: some View {
        Button {
            let enlarging = !vm.isEnlarged
            if enlarging { onEnlarge() }
            withAnimation(NotchViewModel.openAnimation) { vm.isEnlarged = enlarging }
        } label: {
            Image(systemName: vm.isEnlarged ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 9, weight: .bold))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.black.opacity(0.35)))
                .background(Circle().fill(Color.white.opacity(hovering ? 0.22 : 0.12)))
        }
        .buttonStyle(.plain)
        .hoverState($hovering)
        .help(vm.isEnlarged ? "Make smaller" : "Make bigger")
    }
}

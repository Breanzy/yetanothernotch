import AppKit
import SwiftUI

/// The notch window's root view. It hosts the SwiftUI content and handles all drops in AppKit,
/// which (unlike SwiftUI's `onDrop`) supports file promises such as the screenshot thumbnail.
@MainActor
final class DropContainerView: NSView {
    private let viewModel: NotchViewModel

    init(hosting: NSView, viewModel: NotchViewModel) {
        self.viewModel = viewModel
        super.init(frame: .zero)
        pin(hosting)
        registerForDraggedTypes(DropIngest.acceptedTypes)
    }

    private func pin(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Geometry (SwiftUI's global space: top-left origin)

    private func swiftUIPoint(_ info: NSDraggingInfo) -> CGPoint {
        let p = convert(info.draggingLocation, from: nil)
        return CGPoint(x: p.x, y: bounds.height - p.y)
    }

    private func notchRect() -> CGRect {
        let size = viewModel.currentSize
        return CGRect(x: (bounds.width - size.width) / 2, y: 0, width: size.width, height: size.height)
            .insetBy(dx: -24, dy: -16)
    }

    // MARK: - NSDraggingDestination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        update(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        update(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        viewModel.isDropTargeted = false
        viewModel.isAirDropTargeted = false
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        viewModel.isDropTargeted = false
        viewModel.isAirDropTargeted = false
    }

    private func update(_ sender: NSDraggingInfo) -> NSDragOperation {
        // Ignore drags that started on our own shelf/clipboard cards.
        if (sender.draggingSource as? NSView)?.window === window {
            viewModel.isDropTargeted = false
            return []
        }
        let point = swiftUIPoint(sender)
        let overNotch = notchRect().contains(point)
        let overAirDrop = viewModel.isExpanded && viewModel.tab == .shelf && viewModel.airDropFrame.contains(point)
        if viewModel.isDropTargeted != overNotch { viewModel.isDropTargeted = overNotch }
        if viewModel.isAirDropTargeted != overAirDrop { viewModel.isAirDropTargeted = overAirDrop }
        guard overNotch else { return [] }
        // Islet moves/copies the files itself; show the plain cursor if the source allows it.
        return sender.draggingSourceOperationMask.contains(.generic) ? .generic : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let point = swiftUIPoint(sender)
        guard notchRect().contains(point) else { return false }
        let toAirDrop = viewModel.isExpanded && viewModel.tab == .shelf && viewModel.airDropFrame.contains(point)
        viewModel.isDropTargeted = false
        viewModel.isAirDropTargeted = false

        let shelf = viewModel.shelf
        let vm = viewModel
        DropIngest.receive(from: sender.draggingPasteboard) { urls in
            guard !urls.isEmpty else { return }
            if toAirDrop {
                // Anything Islet had to save (screenshots, images, text) also lands on the shelf
                // so it's visible and can be removed later.
                shelf.add(urls.filter(DropIngest.isOwned))
                shelf.airDrop(urls)
            } else {
                withAnimation(Animation.snappy.scaled) {
                    shelf.add(urls)
                    vm.tab = .shelf
                }
            }
        }
        return true
    }
}

import AppKit
import SwiftUI

/// Owns the notch panel, keeps it positioned over the notch, and decides when
/// to expand / collapse based on where the pointer is (including during file drags).
@MainActor
final class NotchWindowController {
    private let viewModel: NotchViewModel
    private let panel: NotchPanel
    private var screen: NSScreen
    private var timer: Timer?
    private var monitors: [Any] = []
    private var openMenus = 0

    static func makeHosting(_ viewModel: NotchViewModel) -> NSView {
        let root = NotchRootView()
            .environmentObject(viewModel)
            .environmentObject(viewModel.media)
            .environmentObject(viewModel.calendar)
            .environmentObject(viewModel.shelf)
            .environmentObject(viewModel.mirror)
            .environmentObject(viewModel.themes)
            .environmentObject(viewModel.timer)
            .environmentObject(viewModel.settings)
            .environmentObject(viewModel.clipboard)
            .environmentObject(viewModel.awake)
        let hosting = IsletHostingView(rootView: root)
        hosting.sizingOptions = []
        return hosting
    }

    private var enteredAt: Date?
    private var exitedAt: Date?
    private var lastDragChangeCount = NSPasteboard(name: .drag).changeCount

    /// Open/close delays come from Settings → Behavior. "Instant" open still waits a hair
    /// (40 ms) so sweeping the pointer across the menu bar doesn't pop the island open.
    private var expandDelay: TimeInterval { max(0.04, viewModel.settings.openDelay) }
    private var collapseDelay: TimeInterval { viewModel.settings.closeDelay }

    init(viewModel: NotchViewModel) {
        self.viewModel = viewModel
        self.screen = Self.targetScreen()
        self.panel = NotchPanel(contentRect: .zero)

        panel.contentView = DropContainerView(hosting: Self.makeHosting(viewModel), viewModel: viewModel)

        reposition()
        panel.orderFrontRegardless()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reposition() }
        }

        // Event monitors make hover feel instant; the timer covers drags and edge cases.
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.tick() }
            return event
        }) { monitors.append(local) }

        // Track open menus (SwiftUI Menu/Picker dropdowns, context menus). Their popups sit
        // outside the island, so without this the island would close under an open menu.
        let center = NotificationCenter.default
        center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.openMenus += 1 }
        }
        center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.openMenus = max(0, self.openMenus - 1)
                self.exitedAt = nil
                self.tick() // close right away if the pointer ended up outside
            }
        }

        setTickRate(fast: false)
    }

    /// The timer only needs to run fast while something is happening (island open, a hover or
    /// close delay pending, mouse button held). Otherwise mouse events drive everything and a
    /// slow tick just catches drags from other apps — far fewer wake-ups for an idle Mac.
    private var tickIsFast: Bool?

    private func setTickRate(fast: Bool) {
        guard tickIsFast != fast else { return }
        tickIsFast = fast
        timer?.invalidate()
        let t = Timer(timeInterval: fast ? 1.0 / 30.0 : 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = fast ? 0.005 : 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: - Geometry

    /// Prefer the built-in display with a notch; otherwise the main display.
    static func targetScreen() -> NSScreen {
        NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func reposition() {
        screen = Self.targetScreen()

        let notchHeight: CGFloat
        let notchWidth: CGFloat
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            notchHeight = screen.safeAreaInsets.top
            notchWidth = screen.frame.width - left.width - right.width
            viewModel.hasPhysicalNotch = true
        } else {
            // No notch: draw a compact pill in the menu bar instead.
            notchHeight = max(24, screen.frame.maxY - screen.visibleFrame.maxY)
            notchWidth = 180
            viewModel.hasPhysicalNotch = false
        }
        viewModel.notchSize = CGSize(width: notchWidth, height: notchHeight)

        // The window is a fixed canvas large enough for the expanded state plus shadow.
        let size = CGSize(
            width: NotchViewModel.maxExpandedWidth + NotchViewModel.expandedEar * 2 + 80,
            height: NotchViewModel.maxExpandedHeight + 60
        )
        let frame = NSRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
        panel.setFrame(frame, display: true)
    }

    /// The on-screen rect (in global coordinates) currently occupied by the notch shape.
    private func activeRect() -> NSRect {
        let s = viewModel.currentSize
        return NSRect(x: screen.frame.midX - s.width / 2, y: screen.frame.maxY - s.height,
                      width: s.width, height: s.height)
    }

    // MARK: - Hover / drag logic

    private func tick() {
        let mouse = NSEvent.mouseLocation
        let buttonDown = NSEvent.pressedMouseButtons & 1 != 0
        let fileDrag = updateFileDragState(buttonDown: buttonDown)
        defer {
            setTickRate(fast: viewModel.isExpanded || enteredAt != nil || buttonDown || fileDrag)
        }

        let hot: NSRect
        if viewModel.isExpanded {
            // Exactly the island's shape bounds; only extended upward so the very top
            // pixel row of the screen still counts as inside.
            let r = activeRect()
            hot = NSRect(x: r.minX, y: r.minY, width: r.width, height: r.height + 4)
        } else if fileDrag {
            hot = activeRect().insetBy(dx: -50, dy: -30) // generous target while dragging files
        } else {
            hot = activeRect().insetBy(dx: -8, dy: -4)
        }
        let inside = hot.contains(mouse)

        // Only talk to the window server when something actually changes.
        if panel.ignoresMouseEvents == inside {
            panel.ignoresMouseEvents = !inside
            // The window won't see the pointer leave its buttons anymore, so clear hover states.
            if !inside { NotificationCenter.default.post(name: .isletResetHover, object: nil) }
        }
        if inside, viewModel.isExpanded, !panel.isKeyWindow { panel.makeKey() }

        let now = Date()
        if inside {
            exitedAt = nil
            if !viewModel.isExpanded {
                // Don't pop open when the user is just dragging a window/selection across the top.
                if buttonDown && !fileDrag { enteredAt = nil; return }
                if enteredAt == nil { enteredAt = now }
                if now.timeIntervalSince(enteredAt!) >= expandDelay {
                    expand(toShelf: fileDrag)
                }
            }
        } else {
            enteredAt = nil
            guard viewModel.isExpanded else { return }
            // Keep open while a context menu is tracking or we're dragging a file out of the shelf.
            if openMenus > 0 || RunLoop.current.currentMode == .eventTracking || viewModel.isDraggingOut {
                exitedAt = nil
                return
            }
            if exitedAt == nil { exitedAt = now }
            if now.timeIntervalSince(exitedAt!) >= collapseDelay {
                collapse()
            }
        }

        if !buttonDown { viewModel.isDraggingOut = false }
    }

    /// Detects a file drag in progress anywhere on the system by watching the drag pasteboard.
    private var wasButtonDown = false

    private func updateFileDragState(buttonDown: Bool) -> Bool {
        // Reading the drag pasteboard is a round-trip to the pasteboard server, so only do it
        // while the mouse button is held (when a drag can actually be happening).
        defer { wasButtonDown = buttonDown }
        guard buttonDown else {
            if wasButtonDown {
                lastDragChangeCount = NSPasteboard(name: .drag).changeCount
                if viewModel.isFileDragActive { viewModel.isFileDragActive = false }
            }
            return false
        }
        if viewModel.isFileDragActive { return true }
        let pb = NSPasteboard(name: .drag)
        // Any drag session (files, screenshot thumbnails, images, text, links…) writes to the
        // drag pasteboard, so a change while the button is held means something droppable is moving.
        if pb.changeCount != lastDragChangeCount, !(pb.types ?? []).isEmpty {
            viewModel.isFileDragActive = true
        }
        return viewModel.isFileDragActive
    }

    private func expand(toShelf: Bool) {
        if toShelf { viewModel.tab = .shelf }
        // Become key right away so the first click and hover tracking work immediately.
        panel.ignoresMouseEvents = false
        panel.makeKey()
        let open: () -> Void = { [weak self] in
            withAnimation(NotchViewModel.openAnimation) { self?.viewModel.isExpanded = true }
        }
        if viewModel.themes.theme != .classic && !viewModel.themeLayerMounted {
            // Render the theme layer at the closed size first, then grow everything together.
            viewModel.themeLayerMounted = true
            DispatchQueue.main.async { open() }
        } else {
            open()
        }
        Haptics.tap()
        viewModel.media.setPanelOpen(true)
    }

    private func collapse() {
        exitedAt = nil
        NotificationCenter.default.post(name: .isletResetHover, object: nil)
        viewModel.mirror.stop() // never leave the camera running in a closed notch
        viewModel.isEnlarged = viewModel.tab == .clipboard // back to the default size for next time
        withAnimation(NotchViewModel.closeAnimation) { viewModel.isExpanded = false }
        viewModel.calendar.suspend()
        viewModel.media.setPanelOpen(false)
        viewModel.clipboard.purgeThumbnails()
        IconCache.purge()
        // Give the keyboard back to the app you were using once the close animation is done.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.returnKeyboardFocus()
        }
        // Once the close animation is done, hand freed memory back to the system.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, !self.viewModel.isExpanded else { return }
            self.viewModel.themeLayerMounted = false // drop the GPU theme layer once fully closed
            malloc_zone_pressure_relief(nil, 0)
        }
    }

    /// The island becomes the key window while open (so clicks, hover and the search field work
    /// right away). A non-activating panel keeps keyboard focus until something else takes it,
    /// so without this, typing after the island closed went nowhere until you clicked your app.
    ///
    /// When Islet's key window goes away and Islet has no other window that can take focus,
    /// macOS gives the keyboard back to the app you're using. Hiding the island itself did that
    /// but made anything showing in the closed notch (timer, album art) blink, so instead an
    /// invisible 1×1 window takes focus for a moment and is the one that gets hidden.
    private lazy var focusSink = FocusSinkPanel()

    private func returnKeyboardFocus() {
        guard !viewModel.isExpanded, panel.isKeyWindow else { return }
        panel.allowsKey = false // so macOS doesn't hand focus straight back to the island
        focusSink.setFrameOrigin(NSPoint(x: screen.frame.minX, y: screen.frame.minY))
        focusSink.orderFrontRegardless()
        focusSink.makeKey()
        focusSink.orderOut(nil)
        DispatchQueue.main.async { [weak self] in self?.panel.allowsKey = true }
    }
}

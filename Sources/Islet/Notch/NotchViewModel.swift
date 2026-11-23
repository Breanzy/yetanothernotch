import AppKit
import Combine
import SwiftUI

@MainActor
final class NotchViewModel: ObservableObject {
    enum Tab: String, Hashable { case home, shelf, clipboard, settings }
    enum SettingsSection: String, CaseIterable, Identifiable {
        case general = "General", behavior = "Behavior", layout = "Layout", appearance = "Appearance"
        case shelf = "Shelf", clipboard = "Clipboard"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .behavior: "cursorarrow.motionlines"
            case .layout: "square.grid.2x2"
            case .appearance: "paintpalette"
            case .shelf: "tray.full"
            case .clipboard: "doc.on.clipboard"
            }
        }
    }

    @Published var isExpanded = false
    /// The glass/material theme layer exists only around open states. It's mounted one frame
    /// *before* opening so it grows together with the notch instead of popping in at full size.
    @Published var themeLayerMounted = false
    /// Big mode for the mirror / clipboard (⤢ button). The clipboard starts big; the mirror starts
    /// small. Reset to those defaults when switching tabs or closing.
    @Published var isEnlarged = false
    /// Last opened tab/section, remembered across closes and restarts.
    @Published var tab: Tab = Tab(rawValue: UserDefaults.standard.string(forKey: "lastTab") ?? "") ?? .home {
        didSet {
            guard tab != oldValue else { return }
            UserDefaults.standard.set(tab.rawValue, forKey: "lastTab")
            isEnlarged = tab == .clipboard // the clipboard opens big by default
            if tab != .home { mirror.stop() } // the camera only runs on Home
        }
    }
    @Published var settingsSection: SettingsSection =
        SettingsSection(rawValue: UserDefaults.standard.string(forKey: "lastSettingsSection") ?? "") ?? .general {
        didSet { UserDefaults.standard.set(settingsSection.rawValue, forKey: "lastSettingsSection") }
    }
    @Published var notchSize = CGSize(width: 200, height: 32)
    @Published var hasPhysicalNotch = true
    @Published var showLiveActivity = false
    /// Width of each side of the closed-notch live activity (wider when a timer is shown).
    @Published var liveInset: CGFloat = 40
    @Published var isDropTargeted = false
    @Published var isAirDropTargeted = false
    /// AirDrop zone frame in the notch window's SwiftUI coordinate space (for routing drops).
    var airDropFrame: CGRect = .zero
    @Published var isFileDragActive = false
    var isDraggingOut = false

    /// Largest the panel ever gets; the window canvas is sized for this.
    static let maxExpandedWidth: CGFloat = 780
    /// Normal panel height (all tabs share it so the island doesn't jump around).
    static let standardHeight: CGFloat = 180
    /// Enlarged mirror / clipboard.
    static let enlargedMinWidth: CGFloat = 640
    static let enlargedHeight: CGFloat = 400
    /// Tallest the panel ever gets; the window canvas is sized for this.
    static let maxExpandedHeight: CGFloat = enlargedHeight

    // Home widget widths (the panel is only as wide as the home widgets that are switched on).
    static let nowPlayingWidth: CGFloat = 270
    static let calendarWidth: CGFloat = 196
    static let tileWidth: CGFloat = 96

    /// Every tab uses the home size, so the island doesn't jump around when switching tabs.
    /// It only changes when home widgets are switched on/off.
    var expandedSize: CGSize {
        if isEnlarged {
            return CGSize(width: max(homeWidth, Self.enlargedMinWidth), height: Self.enlargedHeight)
        }
        return CGSize(width: homeWidth, height: Self.standardHeight)
    }

    private var homeWidth: CGFloat {
        let s = settings
        var parts: [CGFloat] = []
        if s.showNowPlaying { parts.append(Self.nowPlayingWidth) }
        if s.showCalendar { parts.append(Self.calendarWidth) }
        if s.showTimer { parts.append(Self.tileWidth) }
        if s.showMirror { parts.append(Self.tileWidth) }
        if s.showAwake { parts.append(Self.tileWidth) }
        var width = parts.reduce(0, +) + CGFloat(max(0, parts.count - 1)) * 12
        if s.showNowPlaying && s.showCalendar { width += 13 } // divider
        // Leave room for the tabs and battery on either side of the physical notch.
        return max(520, notchSize.width + 300, width + 32)
    }

    /// Width of the "ears" that curve out into the menu bar at the top corners.
    static let collapsedEar: CGFloat = 6
    static let expandedEar: CGFloat = 14

    static let openAnimation = Animation.spring(response: 0.3, dampingFraction: 0.82)
    static let closeAnimation = Animation.spring(response: 0.24, dampingFraction: 0.95)

    let media: MediaController
    let calendar: CalendarService
    let shelf: ShelfStore
    let mirror = MirrorController()
    let themes = ThemeStore()
    let timer = FocusTimer()
    let settings = AppSettings()
    let awake = AwakeController()
    let clipboard = ClipboardStore()
    private var cancellables = Set<AnyCancellable>()

    init(media: MediaController, calendar: CalendarService, shelf: ShelfStore) {
        self.media = media
        self.calendar = calendar
        self.shelf = shelf
        isEnlarged = tab == .clipboard

        let playing = media.$nowPlaying.map { $0?.isPlaying == true }.removeDuplicates()
        let timing = timer.$phase.map { $0 != .idle }.removeDuplicates()
        Publishers.CombineLatest(playing, timing)
            .receive(on: RunLoop.main)
            .sink { [weak self] playing, timing in
                withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                    self?.showLiveActivity = playing || timing
                    self?.liveInset = timing ? 64 : 40
                }
            }
            .store(in: &cancellables)
    }

    var ear: CGFloat { isExpanded ? Self.expandedEar : Self.collapsedEar }
    var bottomRadius: CGFloat { isExpanded ? 22 : (hasPhysicalNotch ? 10 : 12) }

    var collapsedBodyWidth: CGFloat {
        notchSize.width + (showLiveActivity ? liveInset * 2 : 0)
    }

    /// Full size of the notch shape (including ears) for the current state.
    var currentSize: CGSize {
        if isExpanded {
            return CGSize(width: expandedSize.width + Self.expandedEar * 2, height: expandedSize.height)
        }
        return CGSize(width: collapsedBodyWidth + Self.collapsedEar * 2, height: notchSize.height)
    }
}

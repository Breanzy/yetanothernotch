import AppKit
import Combine
import ServiceManagement

@main
@MainActor
enum IsletMain {
    static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        if Snapshot.runIfRequested() { return }
        app.delegate = delegate
        app.setActivationPolicy(.accessory) // no Dock icon
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let media = MediaController()
    let calendar = CalendarService()
    let shelf = ShelfStore()
    lazy var viewModel = NotchViewModel(media: media, calendar: calendar, shelf: shelf)

    private var notchController: NotchWindowController?
    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()
    private var settings: AppSettings { viewModel.settings }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Features switched off in Settings → Layout don't run at all (see the sinks below).
        if !settings.showClipboardTab && viewModel.tab == .clipboard { viewModel.tab = .home }
        notchController = NotchWindowController(viewModel: viewModel)
        media.start(enabled: settings.showNowPlaying)
        viewModel.clipboard.setActive(settings.showClipboardTab)
        calendar.refreshAuthorization()
        setupStatusItem()

        // Now Playing off: stop checking Music/Spotify and clear the closed-notch music activity.
        settings.$showNowPlaying
            .dropFirst()
            .sink { [weak self] on in self?.media.setEnabled(on) }
            .store(in: &cancellables)

        // Clipboard off: stop recording and unload history (kept on disk for when it's back on).
        settings.$showClipboardTab
            .dropFirst()
            .sink { [weak self] on in
                guard let self else { return }
                if !on && self.viewModel.tab == .clipboard { self.viewModel.tab = .home }
                self.viewModel.clipboard.setActive(on)
                if on { self.viewModel.clipboard.purge(olderThanDays: self.settings.clipboardRetention.days) }
            }
            .store(in: &cancellables)

        // Show/hide the menu bar icon whenever the setting changes.
        settings.$showMenuBarIcon
            .sink { [weak self] visible in self?.statusItem?.isVisible = visible }
            .store(in: &cancellables)

        // Menu bar icon turns into a hot cup while Keep Awake is on.
        viewModel.awake.$isOn
            .removeDuplicates()
            .sink { [weak self] awake in
                let image = NSImage(systemSymbolName: awake ? "cup.and.heat.waves.fill" : "rectangle.topthird.inset.filled",
                                    accessibilityDescription: awake ? "Islet (keeping Mac awake)" : "Islet")
                image?.isTemplate = true
                if let image { self?.statusItem?.button?.image = image }
            }
            .store(in: &cancellables)

        // Startup allocates scratch memory that's freed right away; hand it back to the system.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            malloc_zone_pressure_relief(nil, 0)
        }
        // Long-running work (music polling, clipboard) leaves freed memory behind; return it
        // to the system every minute while the notch is closed.
        let relief = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                if self?.viewModel.isExpanded == false { malloc_zone_pressure_relief(nil, 0) }
            }
        }
        relief.tolerance = 10
        RunLoop.main.add(relief, forMode: .common)

        // Auto-clear old shelf items and clipboard history: now, every hour, and whenever
        // the retention settings change.
        runAutoClear()
        let cleanup = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.runAutoClear() }
        }
        cleanup.tolerance = 300
        RunLoop.main.add(cleanup, forMode: .common)
        settings.$shelfRetention.combineLatest(settings.$clipboardRetention)
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] shelfRetention, clipboardRetention in
                // @Published emits before the property changes, so use the emitted values.
                self?.runAutoClear(shelf: shelfRetention, clipboard: clipboardRetention)
            }
            .store(in: &cancellables)
    }

    private func runAutoClear(shelf shelfRetention: Retention? = nil, clipboard clipboardRetention: Retention? = nil) {
        shelf.purge(olderThanDays: (shelfRetention ?? settings.shelfRetention).days)
        viewModel.clipboard.purge(olderThanDays: (clipboardRetention ?? settings.clipboardRetention).days)
    }

    /// Opening Islet again (Finder, Spotlight, Launchpad) while it's running brings
    /// the menu bar icon back, so hiding it is never a dead end.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settings.showMenuBarIcon = true
        return false
    }

    // MARK: - Menu bar item

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "rectangle.topthird.inset.filled", accessibilityDescription: "Islet")
            ?? NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Islet")
        image?.isTemplate = true
        item.button?.image = image
        statusItem = item
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.delegate = self
        statusItem?.menu = menu
    }

    private func populate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(withTitle: "Islet", action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(.separator())

        // Theme
        let themeItem = NSMenuItem(title: "Theme", action: nil, keyEquivalent: "")
        let themeMenu = NSMenu()
        for theme in NotchTheme.allCases {
            let item = NSMenuItem(title: theme.title, action: #selector(selectTheme(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = theme.rawValue
            item.state = viewModel.themes.theme == theme ? .on : .off
            themeMenu.addItem(item)
        }
        themeMenu.addItem(.separator())
        themeMenu.addItem(withTitle: "Tint", action: nil, keyEquivalent: "").isEnabled = false
        for tint in ThemeTint.allCases {
            let item = NSMenuItem(title: tint.title, action: #selector(selectTint(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = tint.rawValue
            item.state = viewModel.themes.tint == tint ? .on : .off
            item.indentationLevel = 1
            themeMenu.addItem(item)
        }
        themeItem.submenu = themeMenu
        menu.addItem(themeItem)

        // Timer
        let timer = viewModel.timer
        let timerItem = NSMenuItem(title: "Focus Timer", action: nil, keyEquivalent: "")
        let timerMenu = NSMenu()
        let toggleTitle: String
        switch timer.phase {
        case .running: toggleTitle = "Pause (\(FocusTimer.format(timer.remaining())) left)"
        case .paused: toggleTitle = "Resume (\(FocusTimer.format(timer.remaining())) left)"
        default: toggleTitle = "Start \(FocusTimer.label(for: timer.defaultLength))"
        }
        let toggle = NSMenuItem(title: toggleTitle, action: #selector(toggleTimer), keyEquivalent: "")
        toggle.target = self
        timerMenu.addItem(toggle)
        if timer.isActive {
            let reset = NSMenuItem(title: "Reset", action: #selector(resetTimer), keyEquivalent: "")
            reset.target = self
            timerMenu.addItem(reset)
        }
        timerMenu.addItem(.separator())
        for length in FocusTimer.presets {
            let item = NSMenuItem(title: "Start \(FocusTimer.label(for: length))",
                                  action: #selector(startTimerPreset(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = length
            timerMenu.addItem(item)
        }
        timerItem.submenu = timerMenu
        menu.addItem(timerItem)

        // Clipboard history: the 10 most recent clips, click to copy again.
        let clipItem = NSMenuItem(title: "Clipboard History", action: nil, keyEquivalent: "")
        let clipMenu = NSMenu()
        let clips = viewModel.clipboard.items.prefix(10)
        if !viewModel.clipboard.isActive {
            clipMenu.addItem(withTitle: "History is off (Settings → Layout → Clipboard)", action: nil, keyEquivalent: "").isEnabled = false
        } else if clips.isEmpty {
            clipMenu.addItem(withTitle: "Nothing copied yet", action: nil, keyEquivalent: "").isEnabled = false
        }
        for clip in clips {
            let preview: String
            switch clip.kind {
            case .text, .link: preview = String((clip.text ?? "").prefix(80)).replacingOccurrences(of: "\n", with: " ")
            case .image: preview = "Image"
            case .file: preview = clip.fileURLs.map(\.lastPathComponent).joined(separator: ", ")
            }
            let title = preview.count > 50 ? String(preview.prefix(50)) + "…" : preview
            let item = NSMenuItem(title: (clip.pinned ? "📌 " : "") + title,
                                  action: #selector(copyClip(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = clip.id
            clipMenu.addItem(item)
        }
        if viewModel.clipboard.isActive {
            clipMenu.addItem(.separator())
            let clearClips = NSMenuItem(title: "Clear History", action: #selector(clearClipboard), keyEquivalent: "")
            clearClips.target = self
            clipMenu.addItem(clearClips)
        }
        clipItem.submenu = clipMenu
        menu.addItem(clipItem)
        menu.addItem(.separator())

        let awakeItem = NSMenuItem(title: "Keep Mac Awake", action: #selector(toggleAwake), keyEquivalent: "")
        awakeItem.target = self
        awakeItem.state = viewModel.awake.isOn ? .on : .off
        if viewModel.awake.isOn { awakeItem.title = "Keep Mac Awake (\(viewModel.awake.remainingText()))" }
        menu.addItem(awakeItem)
        menu.addItem(.separator())

        settings.refreshLoginStatus()
        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.state = settings.launchAtLogin ? .on : .off
        login.target = self
        menu.addItem(login)

        let hide = NSMenuItem(title: "Hide Menu Bar Icon", action: #selector(hideMenuBarIcon), keyEquivalent: "")
        hide.target = self
        hide.toolTip = "Bring it back from the notch's Settings tab, or by opening Islet again."
        menu.addItem(hide)

        let haptics = NSMenuItem(title: "Haptic Feedback", action: #selector(toggleHaptics), keyEquivalent: "")
        haptics.state = settings.haptics ? .on : .off
        haptics.target = self
        menu.addItem(haptics)

        let clear = NSMenuItem(title: "Clear Shelf", action: #selector(clearShelf), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Islet", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    @objc private func selectTheme(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let theme = NotchTheme(rawValue: raw) {
            viewModel.themes.theme = theme
        }
    }

    @objc private func selectTint(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let tint = ThemeTint(rawValue: raw) {
            viewModel.themes.tint = tint
        }
    }

    @objc private func toggleTimer() { viewModel.timer.toggle() }

    @objc private func copyClip(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? UUID,
           let clip = viewModel.clipboard.items.first(where: { $0.id == id }) {
            viewModel.clipboard.copy(clip)
        }
    }

    @objc private func clearClipboard() { viewModel.clipboard.clearUnpinned() }
    @objc private func resetTimer() { viewModel.timer.reset() }

    @objc private func startTimerPreset(_ sender: NSMenuItem) {
        if let length = sender.representedObject as? TimeInterval { viewModel.timer.start(length) }
    }

    @objc private func toggleLaunchAtLogin() {
        settings.setLaunchAtLogin(!settings.launchAtLogin)
        if settings.loginStatus == .requiresApproval { settings.openLoginItemsSettings() }
    }

    @objc private func toggleAwake() {
        viewModel.awake.toggle()
    }

    @objc private func hideMenuBarIcon() {
        settings.showMenuBarIcon = false
    }

    @objc private func toggleHaptics() {
        settings.haptics.toggle()
    }

    @objc private func clearShelf() {
        shelf.clear()
    }
}

extension AppDelegate: NSMenuDelegate {
    /// Rebuild the menu each time it opens so theme/timer state is always current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        populate(menu)
    }
}

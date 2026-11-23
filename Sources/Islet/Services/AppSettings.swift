import AppKit
import ServiceManagement
import SwiftUI

/// How long the shelf / clipboard history keep items before they're cleared automatically.
enum Retention: Int, CaseIterable, Identifiable {
    case never = 0, oneDay = 1, threeDays = 3, oneWeek = 7, twoWeeks = 14, oneMonth = 30

    var id: Int { rawValue }
    var days: Int { rawValue }
    var title: String {
        switch self {
        case .never: "Never"
        case .oneDay: "1 day"
        case .threeDays: "3 days"
        case .oneWeek: "1 week"
        case .twoWeeks: "2 weeks"
        case .oneMonth: "1 month"
        }
    }

    /// Compact label for the settings chips.
    var shortTitle: String {
        switch self {
        case .never: "Never"
        case .oneDay: "1d"
        case .threeDays: "3d"
        case .oneWeek: "1w"
        case .twoWeeks: "2w"
        case .oneMonth: "1mo"
        }
    }
}

/// App-wide preferences shown in the Settings tab and the menu bar menu.
@MainActor
final class AppSettings: ObservableObject {
    @Published var showMenuBarIcon: Bool {
        didSet { UserDefaults.standard.set(showMenuBarIcon, forKey: Settings.menuBarIconKey) }
    }
    @Published var haptics: Bool {
        didSet { Settings.haptics = haptics }
    }
    // Layout: which tabs / widgets are shown. Battery and Calendar are off by default.
    @Published var showShelfTab: Bool { didSet { save(showShelfTab, "layout.shelfTab") } }
    @Published var showClipboardTab: Bool { didSet { save(showClipboardTab, "layout.clipboardTab") } }
    @Published var showBattery: Bool { didSet { save(showBattery, "layout.battery") } }
    @Published var showNowPlaying: Bool { didSet { save(showNowPlaying, "layout.nowPlaying") } }
    @Published var showCalendar: Bool { didSet { save(showCalendar, "layout.calendar") } }
    @Published var showTimer: Bool { didSet { save(showTimer, "layout.timer") } }
    @Published var showMirror: Bool { didSet { save(showMirror, "layout.mirror") } }
    @Published var showAwake: Bool { didSet { save(showAwake, "layout.awake") } }

    /// How long the pointer must rest on the notch before it opens, and how long after leaving
    /// before it closes (seconds). Both default to instant.
    @Published var openDelay: Double { didSet { UserDefaults.standard.set(openDelay, forKey: "hover.openDelay") } }
    @Published var closeDelay: Double { didSet { UserDefaults.standard.set(closeDelay, forKey: "hover.closeDelay") } }
    static let openDelayOptions: [(label: String, value: Double)] =
        [("Instant", 0), ("0.15s", 0.15), ("0.3s", 0.3), ("0.5s", 0.5), ("1s", 1)]
    static let closeDelayOptions: [(label: String, value: Double)] =
        [("Instant", 0), ("0.3s", 0.3), ("0.6s", 0.6), ("1s", 1), ("2s", 2)]

    /// Speed of every animation (opening/closing the island, tabs, tiles…). 0 = Instant:
    /// no animation, things just appear. 1 = the normal speed.
    @Published var animationSpeed: Double {
        didSet {
            UserDefaults.standard.set(animationSpeed, forKey: "motion.speed")
            Motion.speed = animationSpeed
        }
    }
    static let animationSpeedOptions: [(label: String, value: Double)] =
        [("Instant", 0), ("Faster", 3), ("Fast", 1.75), ("Normal", 1), ("Slow", 0.7)]

    // Auto-clear: shelf after 3 days, clipboard after 1 week by default.
    /// Shelf behaviour (see ShelfPrefs for the keys the store reads).
    @Published var moveFilesIntoShelf: Bool {
        didSet { UserDefaults.standard.set(moveFilesIntoShelf, forKey: ShelfPrefs.moveInKey) }
    }
    @Published var removeAfterDragOut: Bool {
        didSet { UserDefaults.standard.set(removeAfterDragOut, forKey: ShelfPrefs.removeAfterDragKey) }
    }

    @Published var shelfRetention: Retention {
        didSet { UserDefaults.standard.set(shelfRetention.rawValue, forKey: "retention.shelf") }
    }
    @Published var clipboardRetention: Retention {
        didSet { UserDefaults.standard.set(clipboardRetention.rawValue, forKey: "retention.clipboard") }
    }

    @Published private(set) var loginStatus: SMAppService.Status = .notRegistered
    @Published private(set) var loginError: String?

    init() {
        Settings.registerDefaults()
        showMenuBarIcon = UserDefaults.standard.bool(forKey: Settings.menuBarIconKey)
        haptics = Settings.haptics
        let d = UserDefaults.standard
        showShelfTab = d.bool(forKey: "layout.shelfTab")
        showClipboardTab = d.bool(forKey: "layout.clipboardTab")
        showBattery = d.bool(forKey: "layout.battery")
        showNowPlaying = d.bool(forKey: "layout.nowPlaying")
        showCalendar = d.bool(forKey: "layout.calendar")
        showTimer = d.bool(forKey: "layout.timer")
        showMirror = d.bool(forKey: "layout.mirror")
        showAwake = d.bool(forKey: "layout.awake")
        ShelfPrefs.registerDefaults()
        moveFilesIntoShelf = ShelfPrefs.moveFilesIn
        removeAfterDragOut = ShelfPrefs.removeAfterDragOut
        openDelay = d.double(forKey: "hover.openDelay")
        closeDelay = d.double(forKey: "hover.closeDelay")
        let speed = d.double(forKey: "motion.speed")
        animationSpeed = speed
        Motion.speed = speed
        shelfRetention = Retention(rawValue: d.integer(forKey: "retention.shelf")) ?? .threeDays
        clipboardRetention = Retention(rawValue: d.integer(forKey: "retention.clipboard")) ?? .oneWeek
        refreshLoginStatus()
    }

    private func save(_ value: Bool, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    /// True when no home widget is enabled.
    var homeIsEmpty: Bool { !showNowPlaying && !showCalendar && !showTimer && !showMirror && !showAwake }

    // MARK: Launch at login

    /// On when registered, including while macOS is still waiting for the user to approve it.
    var launchAtLogin: Bool { loginStatus == .enabled || loginStatus == .requiresApproval }

    /// Login items registered from a temporary build folder break if that folder moves or is deleted.
    var isInstalledInApplications: Bool {
        let path = Bundle.main.bundleURL.path
        return path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        loginError = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            loginError = error.localizedDescription
        }
        refreshLoginStatus()
    }

    func refreshLoginStatus() {
        loginStatus = SMAppService.mainApp.status
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

enum Settings {
    static let menuBarIconKey = "showMenuBarIcon"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            "haptics": true, menuBarIconKey: true,
            "layout.shelfTab": true, "layout.clipboardTab": true,
            "layout.battery": false, "layout.calendar": false,
            "layout.nowPlaying": true, "layout.timer": true, "layout.mirror": true, "layout.awake": true,
            "motion.speed": 1.0,
            "retention.shelf": Retention.threeDays.rawValue,
            "retention.clipboard": Retention.oneWeek.rawValue,
        ])
    }

    static var haptics: Bool {
        get { UserDefaults.standard.bool(forKey: "haptics") }
        set { UserDefaults.standard.set(newValue, forKey: "haptics") }
    }
}

// MARK: - Settings tab

/// Settings fits in the same size as Home: section pills across the top, compact rows below.
/// Longer explanations live in tooltips (hover a row).
struct SettingsView: View {
    @EnvironmentObject var vm: NotchViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                ForEach(NotchViewModel.SettingsSection.allCases) { SectionPill(section: $0) }
                Spacer(minLength: 6)
                SmallButton(title: "Quit") { NSApp.terminate(nil) }
                    .help("Quit Islet")
            }
            .frame(height: 22)

            Group {
                switch vm.settingsSection {
                case .general: GeneralSettings()
                case .behavior: BehaviorSettings()
                case .layout: LayoutSettings()
                case .appearance: ThemesView()
                case .shelf: ShelfSettings()
                case .clipboard: ClipboardSettings()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

private struct SectionPill: View {
    @EnvironmentObject var vm: NotchViewModel
    let section: NotchViewModel.SettingsSection
    @ViewState private var hovering = false

    var body: some View {
        let selected = vm.settingsSection == section
        Button {
            withAnimation(Animation.snappy(duration: 0.15).scaled) { vm.settingsSection = section }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: section.symbol).font(.system(size: 10, weight: .semibold))
                Text(section.rawValue).font(.system(size: 11, weight: selected ? .semibold : .medium))
            }
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(Capsule().fill(Color.white.opacity(selected ? 0.16 : (hovering ? 0.07 : 0))))
            .foregroundStyle(selected ? .white : .white.opacity(0.6))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .hoverState($hovering)
    }
}

/// Small capsule button used inside compact settings rows.
struct SmallButton: View {
    let title: String
    let action: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background(Capsule().fill(Color.white.opacity(hovering ? 0.2 : 0.12)))
        }
        .buttonStyle(.plain)
        .hoverState($hovering)
    }
}

/// One compact settings row: icon, title (+ optional one-line note), accessory, switch.
struct SwitchRow<Accessory: View>: View {
    let icon: String
    let title: String
    var note: String? = nil
    var noteIsWarning = false
    var help: String = ""
    @Binding var isOn: Bool
    @ViewBuilder var accessory: () -> Accessory

    init(icon: String, title: String, note: String? = nil, noteIsWarning: Bool = false, help: String = "",
         isOn: Binding<Bool>, @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() }) {
        self.icon = icon
        self.title = title
        self.note = note
        self.noteIsWarning = noteIsWarning
        self.help = help
        self._isOn = isOn
        self.accessory = accessory
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 20, height: 20)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.1)))
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.system(size: 12, weight: .medium))
                if let note {
                    Text(note)
                        .font(.system(size: 9.5))
                        .foregroundStyle(noteIsWarning ? Color.orange : .white.opacity(0.45))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            accessory()
            MiniSwitch(isOn: $isOn)
        }
        .frame(height: note == nil ? 23 : 30)
        .contentShape(Rectangle())
        .help(help)
    }
}

private struct GeneralSettings: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        VStack(spacing: 3) {
            SwitchRow(
                icon: "power", title: "Launch at login",
                note: loginNote, noteIsWarning: loginNoteIsWarning,
                help: "Start Islet automatically when you log in.",
                isOn: Binding(get: { settings.launchAtLogin }, set: { settings.setLaunchAtLogin($0) })
            ) {
                if settings.loginStatus == .requiresApproval {
                    SmallButton(title: "Approve…") { settings.openLoginItemsSettings() }
                }
            }
            SwitchRow(
                icon: "menubar.rectangle", title: "Show menu bar icon",
                note: settings.showMenuBarIcon ? nil : "Hidden. Open Islet again from Finder to bring it back.",
                help: "Islet's icon in the menu bar. If hidden, open Islet again from Finder or Spotlight to bring it back.",
                isOn: $settings.showMenuBarIcon
            )
        }
        .onAppear { settings.refreshLoginStatus() }
    }

    /// Only shown when something needs attention.
    private var loginNote: String? {
        if let error = settings.loginError { return "Couldn't change it: \(error)" }
        switch settings.loginStatus {
        case .requiresApproval: return "Approve Islet in System Settings → Login Items."
        case .enabled where !settings.isInstalledInApplications: return "Move Islet to Applications so this keeps working."
        default: return nil
        }
    }

    private var loginNoteIsWarning: Bool { loginNote != nil }
}

/// How the island reacts to the pointer.
private struct BehaviorSettings: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        VStack(spacing: 3) {
            ChoiceRow(icon: "cursorarrow.and.square.on.square.dashed", title: "Open delay",
                      help: "How long the pointer rests on the notch before it opens.",
                      options: AppSettings.openDelayOptions, selection: $settings.openDelay)
            ChoiceRow(icon: "rectangle.portrait.and.arrow.right", title: "Close delay",
                      help: "How long after the pointer leaves before the island closes.",
                      options: AppSettings.closeDelayOptions, selection: $settings.closeDelay)
            ChoiceRow(icon: "hare", title: "Animations",
                      help: "How fast the island opens and closes, and every other animation. Instant: no animation at all, it just appears.",
                      options: AppSettings.animationSpeedOptions, selection: $settings.animationSpeed)
            SwitchRow(
                icon: "hand.tap", title: "Haptic feedback",
                help: "A tap on the trackpad when the notch opens and when a timer finishes.",
                isOn: $settings.haptics
            )
        }
    }
}

/// A row with a small segmented choice (delays, retention, on/off modes…).
private struct ChoiceRow<Value: Hashable>: View {
    let icon: String
    let title: String
    let help: String
    let options: [(label: String, value: Value)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 20, height: 20)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.1)))
            Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
            Spacer(minLength: 6)
            HStack(spacing: 2) {
                ForEach(options.indices, id: \.self) { i in
                    let option = options[i]
                    let selected = option.value == selection
                    Button {
                        withAnimation(Animation.snappy(duration: 0.15).scaled) { selection = option.value }
                    } label: {
                        Text(option.label)
                            .font(.system(size: 10, weight: selected ? .semibold : .medium))
                            .padding(.horizontal, 7)
                            .frame(height: 18)
                            .background(Capsule().fill(selected ? Color.accentColor : .clear))
                            .foregroundStyle(selected ? .white : .white.opacity(0.65))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .background(Capsule().fill(Color.white.opacity(0.08)))
        }
        .frame(height: 26)
        .help(help)
    }
}

/// Choose which widgets appear on Home and which tabs/indicators appear in the top bar.
private struct LayoutSettings: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 3) {
                SwitchRow(icon: "music.note", title: "Now Playing",
                          help: "Home widget, plus album art and equalizer in the closed notch. Off: Islet stops checking Music and Spotify entirely.",
                          isOn: $settings.showNowPlaying)
                SwitchRow(icon: "calendar", title: "Calendar", help: "Home widget", isOn: $settings.showCalendar)
                SwitchRow(icon: "timer", title: "Focus Timer", help: "Home widget", isOn: $settings.showTimer)
            }
            VStack(spacing: 3) {
                SwitchRow(icon: "person.crop.square", title: "Mirror", help: "Home widget", isOn: $settings.showMirror)
                SwitchRow(icon: "cup.and.saucer", title: "Keep Awake", help: "Home widget", isOn: $settings.showAwake)
            }
            VStack(spacing: 3) {
                SwitchRow(icon: "tray.full", title: "Shelf tab", help: "Top bar", isOn: $settings.showShelfTab)
                SwitchRow(icon: "doc.on.clipboard", title: "Clipboard",
                          help: "Top bar tab and clipboard history. Off: nothing is recorded and history is unloaded (it's kept on disk for when you turn it back on).",
                          isOn: $settings.showClipboardTab)
                SwitchRow(icon: "battery.75percent", title: "Battery", help: "Top bar", isOn: $settings.showBattery)
            }
        }
    }
}

/// How the shelf treats files.
private struct ShelfSettings: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        VStack(spacing: 3) {
            ChoiceRow(icon: "tray.and.arrow.down", title: "Adding files",
                      help: "Move: files you drop leave their folder and live on the shelf (Put Back returns them). "
                          + "Keep in place: the shelf just points to them.",
                      options: [("Move to shelf", true), ("Keep in place", false)],
                      selection: $settings.moveFilesIntoShelf)
            ChoiceRow(icon: "tray.and.arrow.up", title: "After dragging out",
                      help: "Remove: an item leaves the shelf once you drop it somewhere. Keep: it stays until you remove it.",
                      options: [("Remove", true), ("Keep", false)],
                      selection: $settings.removeAfterDragOut)
            ChoiceRow(icon: "clock.arrow.circlepath", title: "Keep for",
                      help: "Items are cleared this long after being added. Your own files go back where they came from; "
                          + "files Islet saved go to the Trash. Checked hourly.",
                      options: Retention.allCases.map { ($0.shortTitle, $0) },
                      selection: $settings.shelfRetention)
        }
    }
}

/// Clipboard history settings.
private struct ClipboardSettings: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var clipboard: ClipboardStore

    var body: some View {
        VStack(spacing: 3) {
            if !settings.showClipboardTab {
                SwitchRow(icon: "pause.circle", title: "Recording is off",
                          note: "Nothing you copy is saved. Turn it on to record and see your history.",
                          noteIsWarning: true,
                          help: "Same as the Clipboard switch in Layout.",
                          isOn: $settings.showClipboardTab)
            }
            ChoiceRow(icon: "clock.arrow.circlepath", title: "Keep history for",
                      help: "Clipboard items are cleared this long after they were last copied. Pinned items are kept. Checked hourly.",
                      options: Retention.allCases.map { ($0.shortTitle, $0) },
                      selection: $settings.clipboardRetention)
            if settings.showClipboardTab {
                HStack(spacing: 8) {
                    Image(systemName: "trash")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 20, height: 20)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.1)))
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Clear history").font(.system(size: 12, weight: .medium))
                        Text("Pinned items are always kept.")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                    Spacer(minLength: 6)
                    let count = clipboard.items.filter { !$0.pinned }.count
                    SmallButton(title: count > 0 ? "Clear (\(count))" : "Clear") {
                        withAnimation(Animation.default.scaled) { clipboard.clearUnpinned() }
                    }
                    .disabled(count == 0)
                    .opacity(count == 0 ? 0.5 : 1)
                }
                .frame(height: 30)
            }
        }
    }
}


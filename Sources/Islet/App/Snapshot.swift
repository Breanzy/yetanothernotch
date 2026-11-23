import AppKit
import SwiftUI

/// Debug helper: `Islet --snapshot <dir>` renders the notch states to PNGs and exits.
@MainActor
enum Snapshot {
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return false }
        let dir = URL(fileURLWithPath: args[i + 1])
        let d = IsletMain.delegate
        let vm = d.viewModel
        vm.notchSize = CGSize(width: 185, height: 32)
        
        func env<V: View>(_ v: V) -> some View {
            v.environmentObject(vm).environmentObject(d.media)
                .environmentObject(d.calendar).environmentObject(d.shelf)
                .environmentObject(vm.mirror).environmentObject(vm.themes)
                .environmentObject(vm.timer).environmentObject(vm.settings)
                .environmentObject(vm.clipboard).environmentObject(vm.awake)
                .preferredColorScheme(.dark)
        }
        func write<V: View>(_ v: V, _ name: String) {
            let r = ImageRenderer(content: v)
            r.scale = 2
            if let img = r.nsImage, let tiff = img.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: dir.appendingPathComponent("\(name).png"))
            }
        }
        func render(_ name: String) {
            write(env(NotchRootView().frame(width: 900, height: 470).background(Color(white: 0.85))), name)
        }

        // Snapshot uses its own defaults domain ("Islet"), so these don't touch the real app.
        let s = vm.settings
        vm.isExpanded = true; vm.tab = .home; render("home-default")
        vm.awake.start(for: 3600); render("home-awake-on"); vm.awake.stop()
        s.showCalendar = true; s.showBattery = true; render("home-all")
        s.showCalendar = false; s.showBattery = false
        s.showNowPlaying = false; s.showTimer = false; s.showMirror = false; render("home-empty")
        s.showNowPlaying = true; s.showTimer = true; s.showMirror = true
        vm.tab = .shelf; render("shelf")
        for section in NotchViewModel.SettingsSection.allCases {
            vm.settingsSection = section; vm.tab = .settings; render("settings-\(section.rawValue)")
        }
        vm.clipboard.loadPreviewItems()
        vm.tab = .clipboard; render("clipboard")
        vm.isEnlarged = true; render("clipboard-big"); vm.isEnlarged = false
        let items = vm.clipboard.filteredItems
        vm.clipboard.selectedID = items.first?.id
        write(env(HStack(alignment: .top, spacing: 14) {
            ClipRows(items: items, selectedID: items.first?.id).frame(width: 330)
            ClipPreview(item: items.first).frame(width: 360, height: 230)
        }.padding(14).background(Color.black)), "clipboard-rows")
        vm.isExpanded = false
        vm.timer.start(); vm.liveInset = 64; vm.showLiveActivity = true; render("collapsed-timer")
        vm.isExpanded = true; vm.tab = .home; render("home-timer-running")
        vm.timer.reset()
        return true
    }
}

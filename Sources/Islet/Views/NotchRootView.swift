import SwiftUI

struct NotchRootView: View {
    @EnvironmentObject var vm: NotchViewModel
    /// Observed so the panel resizes when widgets are switched on/off.
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        VStack(spacing: 0) {
            notch
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .preferredColorScheme(.dark)
    }

    private var notch: some View {
        let size = vm.currentSize
        let shape = NotchShape(topRadius: vm.ear, bottomRadius: vm.bottomRadius)

        return ZStack(alignment: .top) {
            NotchBackground(shape: shape)

            Group {
                if vm.isExpanded {
                    ExpandedView()
                        .transition(.asymmetric(
                            // Fade only — the notch shape itself provides the growth, so the
                            // content shouldn't scale on top of it (that read as two things expanding).
                            insertion: .opacity.animation(.easeOut(duration: 0.15).delay(0.05)),
                            removal: .opacity.animation(.easeIn(duration: 0.07))
                        ))
                } else if vm.showLiveActivity {
                    CollapsedLiveActivity()
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, vm.ear)
        }
        .frame(width: size.width, height: size.height)
        .clipShape(shape)
        .shadow(color: .black.opacity(vm.isExpanded ? 0.55 : 0), radius: 14, y: 6)
        .overlay {
            // Subtle highlight ring while files hover over the notch.
            if vm.isDropTargeted {
                shape.stroke(Color.white.opacity(0.35), lineWidth: 1.5)
            }
        }
        .contentShape(shape)
        .animation(vm.isExpanded ? NotchViewModel.openAnimation : NotchViewModel.closeAnimation, value: vm.isExpanded)
        .animation(.spring(response: 0.32, dampingFraction: 0.78), value: vm.showLiveActivity)
    }
}

// MARK: - Expanded

struct ExpandedView: View {
    @EnvironmentObject var vm: NotchViewModel

    var body: some View {
        VStack(spacing: 6) {
            HeaderBar()
                .frame(height: vm.notchSize.height)
            Group {
                switch vm.tab {
                case .home: HomeView()
                case .shelf: ShelfView()
                case .clipboard: ClipboardView()
                case .settings: SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .foregroundStyle(.white)
    }
}

struct HeaderBar: View {
    @EnvironmentObject var vm: NotchViewModel
    @EnvironmentObject var shelf: ShelfStore
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        HStack(spacing: 4) {
            TabButton(symbol: "house.fill", tab: .home)
            // Shelf stays visible while it holds files or is the open tab (e.g. after a drop).
            if settings.showShelfTab || vm.tab == .shelf || !shelf.items.isEmpty {
                TabButton(symbol: "tray.full.fill", tab: .shelf, badge: shelf.items.count)
            }
            if settings.showClipboardTab || vm.tab == .clipboard {
                TabButton(symbol: "doc.on.clipboard.fill", tab: .clipboard)
            }
            TabButton(symbol: "gearshape.fill", tab: .settings)
            Spacer(minLength: vm.notchSize.width + 20) // keep clear of the physical notch
            if settings.showBattery {
                BatteryView()
            }
        }
        .padding(.top, 4)
    }
}

struct TabButton: View {
    @EnvironmentObject var vm: NotchViewModel
    let symbol: String
    let tab: NotchViewModel.Tab
    var badge: Int = 0
    @ViewState private var hovering = false

    var body: some View {
        let selected = vm.tab == tab
        Button {
            withAnimation(.snappy(duration: 0.15)) { vm.tab = tab }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 30, height: 22)
                .background(Capsule().fill(Color.white.opacity(selected ? 0.18 : (hovering ? 0.08 : 0))))
                .contentShape(Capsule()) // clickable across the whole pill, not just the glyph
                .foregroundStyle(selected ? .white : .white.opacity(0.55))
                .overlay(alignment: .topTrailing) {
                    if badge > 0 {
                        Text("\(badge)")
                            .font(.system(size: 8, weight: .bold))
                            .padding(.horizontal, 3)
                            .frame(minWidth: 12, minHeight: 12)
                            .background(Capsule().fill(Color.accentColor))
                            .offset(x: 4, y: -3)
                    }
                }
        }
        .buttonStyle(.plain)
        .hoverState($hovering)
    }
}

/// The home tab shows whichever widgets are switched on in Settings → Layout.
struct HomeView: View {
    @EnvironmentObject var vm: NotchViewModel
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        if vm.isEnlarged {
            MirrorLarge()
        } else if settings.homeIsEmpty {
            VStack(spacing: 8) {
                Text("No widgets on Home")
                    .font(.system(size: 12, weight: .semibold))
                PillButton(title: "Choose widgets…") {
                    vm.settingsSection = .layout
                    withAnimation(.snappy) { vm.tab = .settings }
                }
            }
            .foregroundStyle(.white.opacity(0.7))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HStack(spacing: 12) {
                if settings.showNowPlaying {
                    NowPlayingView()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if settings.showCalendar {
                    if settings.showNowPlaying { divider }
                    CalendarView()
                        .frame(width: settings.showNowPlaying ? NotchViewModel.calendarWidth : nil)
                        .frame(maxWidth: settings.showNowPlaying ? nil : .infinity)
                        .onAppear { vm.calendar.reload() }
                }
                if !settings.showNowPlaying && !settings.showCalendar { Spacer(minLength: 0) }
                if settings.showTimer {
                    TimerTile().frame(width: NotchViewModel.tileWidth)
                }
                if settings.showMirror {
                    MirrorTile().frame(width: NotchViewModel.tileWidth)
                }
                if settings.showAwake {
                    AwakeTile().frame(width: NotchViewModel.tileWidth)
                }
                if !settings.showNowPlaying && !settings.showCalendar { Spacer(minLength: 0) }
            }
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.1))
            .frame(width: 1)
            .padding(.vertical, 6)
    }
}

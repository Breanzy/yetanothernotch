import SwiftUI

enum NotchTheme: String, CaseIterable, Identifiable {
    case classic, liquidGlass, clearGlass, tintedGlass, frosted, aurora

    var id: String { rawValue }

    var title: String {
        switch self {
        case .classic: "Classic"
        case .liquidGlass: "Liquid Glass"
        case .clearGlass: "Clear Glass"
        case .tintedGlass: "Tinted Glass"
        case .frosted: "Frosted"
        case .aurora: "Aurora"
        }
    }

    var usesTint: Bool { self == .tintedGlass || self == .aurora }
    var isGlass: Bool { self == .liquidGlass || self == .clearGlass || self == .tintedGlass }
}

enum ThemeTint: String, CaseIterable, Identifiable {
    case albumArt, blue, purple, pink, red, orange, green, graphite

    var id: String { rawValue }

    var title: String {
        switch self {
        case .albumArt: "Album Art"
        default: rawValue.capitalized
        }
    }

    /// `nil` means "follow the current album artwork".
    var color: Color? {
        switch self {
        case .albumArt: nil
        case .blue: Color(red: 0.20, green: 0.48, blue: 1.00)
        case .purple: Color(red: 0.58, green: 0.36, blue: 0.98)
        case .pink: Color(red: 0.98, green: 0.36, blue: 0.62)
        case .red: Color(red: 0.96, green: 0.27, blue: 0.27)
        case .orange: Color(red: 1.00, green: 0.58, blue: 0.18)
        case .green: Color(red: 0.24, green: 0.80, blue: 0.48)
        case .graphite: Color(white: 0.55)
        }
    }
}

@MainActor
final class ThemeStore: ObservableObject {
    @Published var theme: NotchTheme {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: "theme") }
    }
    @Published var tint: ThemeTint {
        didSet { UserDefaults.standard.set(tint.rawValue, forKey: "themeTint") }
    }

    init() {
        theme = NotchTheme(rawValue: UserDefaults.standard.string(forKey: "theme") ?? "") ?? .classic
        tint = ThemeTint(rawValue: UserDefaults.standard.string(forKey: "themeTint") ?? "") ?? .albumArt
    }

    /// The tint color to use right now (album art color when playing, otherwise blue).
    func resolvedTint(albumAccent: Color, hasArtwork: Bool) -> Color {
        tint.color ?? (hasArtwork ? albumAccent : ThemeTint.blue.color!)
    }
}

// MARK: - Rendering

/// Paints a theme into any shape. Used for the notch itself and for the theme swatches.
struct ThemeFill<S: Shape>: View {
    let theme: NotchTheme
    let tint: Color
    let shape: S

    var body: some View {
        switch theme {
        case .classic:
            shape.fill(Color.black)
        case .liquidGlass:
            GlassFill(shape: shape, clear: false, tint: .black.opacity(0.32))
        case .clearGlass:
            GlassFill(shape: shape, clear: true, tint: .black.opacity(0.16))
        case .tintedGlass:
            GlassFill(shape: shape, clear: false, tint: tint.opacity(0.45))
        case .frosted:
            shape.fill(.ultraThinMaterial)
                .overlay(shape.fill(Color.black.opacity(0.35)))
        case .aurora:
            shape.fill(Color.black)
                .overlay(
                    shape.fill(RadialGradient(colors: [tint.opacity(0.75), tint.opacity(0.15), .clear],
                                              center: .bottomLeading, startRadius: 0, endRadius: 420))
                )
                .overlay(
                    shape.fill(RadialGradient(colors: [tint.opacity(0.45), .clear],
                                              center: .topTrailing, startRadius: 0, endRadius: 320))
                        .hueRotation(.degrees(40))
                )
        }
    }
}

/// Static look-alike of a theme for the picker. Drawing six live glass/material effects just
/// to show swatches would load the GPU effects stack even for Classic users.
struct ThemeSwatch<S: Shape>: View {
    let theme: NotchTheme
    let tint: Color
    let shape: S

    var body: some View {
        switch theme {
        case .classic:
            shape.fill(Color.black)
        case .aurora:
            ThemeFill(theme: .aurora, tint: tint, shape: shape) // plain gradients, no GPU effects
        case .liquidGlass, .clearGlass, .tintedGlass, .frosted:
            shape.fill(glassFill)
                .overlay(shape.stroke(glassEdge, lineWidth: 1))
        }
    }

    private var glassFill: Color {
        switch theme {
        case .liquidGlass: Color.black.opacity(0.32)
        case .clearGlass: Color.black.opacity(0.1)
        case .tintedGlass: tint.opacity(0.5)
        default: Color(white: 0.22).opacity(0.8)
        }
    }

    private var glassEdge: LinearGradient {
        LinearGradient(colors: [.white.opacity(0.7), .white.opacity(0.1), .white.opacity(0.35)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// Liquid Glass on macOS 26+, falling back to a dark material on older systems.
struct GlassFill<S: Shape>: View {
    let shape: S
    let clear: Bool
    let tint: Color

    var body: some View {
        // Liquid Glass needs the macOS 26 SDK (Swift 6.2+) to compile; older toolchains build the
        // material fallback so the project still builds on macOS 15 with Xcode 16.
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            Color.clear
                .glassEffect((clear ? Glass.clear : Glass.regular).tint(tint), in: shape)
        } else {
            fallback
        }
        #else
        fallback
        #endif
    }

    private var fallback: some View {
        shape.fill(clear ? .ultraThinMaterial : .regularMaterial)
            .overlay(shape.fill(tint))
    }
}

/// Background of the notch. With a physical notch the closed state always stays black
/// so it blends with the cut-out; the theme fades in as the panel opens.
struct NotchBackground: View {
    @EnvironmentObject var vm: NotchViewModel
    @EnvironmentObject var themes: ThemeStore
    @EnvironmentObject var media: MediaController
    let shape: NotchShape

    var body: some View {
        let themed = themes.theme != .classic && (vm.isExpanded || !vm.hasPhysicalNotch)
        ZStack {
            // Only build the glass/material while it's visible: hidden under the black notch it
            // would still keep the GPU effects stack (several MB + GPU work) alive.
            if themes.theme != .classic && (vm.themeLayerMounted || !vm.hasPhysicalNotch) {
                ThemeFill(theme: themes.theme,
                          tint: themes.resolvedTint(albumAccent: media.accent, hasArtwork: media.artwork != nil),
                          shape: shape)
                    // Only the fade gets its own timing. A plain `.animation(_:value:)` here also
                    // re-timed the background's *size*, so it grew slower than the island's
                    // content and outline — it looked like two notches opening at once.
                    .animation(Animation.easeInOut(duration: 0.3).scaled) { $0.opacity(themed ? 1 : 0) }
                    .transition(.identity)
            }
            shape.fill(Color.black)
                .animation(Animation.easeInOut(duration: 0.3).scaled) { $0.opacity(themed ? 0 : 1) }
        }
    }
}

// MARK: - Themes tab

struct ThemesView: View {
    @EnvironmentObject var themes: ThemeStore
    @EnvironmentObject var media: MediaController

    var body: some View {
        let tint = themes.resolvedTint(albumAccent: media.accent, hasArtwork: media.artwork != nil)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ForEach(NotchTheme.allCases) { theme in
                    ThemeCard(theme: theme, tint: tint, selected: themes.theme == theme) {
                        withAnimation(Animation.easeInOut(duration: 0.3).scaled) { themes.theme = theme }
                    }
                }
            }
            HStack(spacing: 8) {
                Text("Tint")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(themes.theme.usesTint ? 0.7 : 0.35))
                ForEach(ThemeTint.allCases) { option in
                    TintDot(option: option, albumAccent: media.accent, selected: themes.tint == option) {
                        withAnimation(Animation.default.scaled) { themes.tint = option }
                    }
                }
                Spacer()
                if !themes.theme.usesTint {
                    Text("For Tinted Glass & Aurora")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            .opacity(themes.theme.usesTint ? 1 : 0.6)
        }
    }
}

struct ThemeCard: View {
    let theme: NotchTheme
    let tint: Color
    let selected: Bool
    let action: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        Button(action: action) {
            VStack(spacing: 5) {
                ZStack {
                    // A little "wallpaper" so glass themes have something to refract.
                    shape.fill(LinearGradient(colors: [Color(red: 0.95, green: 0.55, blue: 0.35),
                                                       Color(red: 0.35, green: 0.40, blue: 0.95)],
                                              startPoint: .topLeading, endPoint: .bottomTrailing))
                    ThemeSwatch(theme: theme, tint: tint, shape: shape)
                        .padding(5)
                    Capsule()
                        .fill(Color.white.opacity(0.85))
                        .frame(width: 24, height: 4)
                }
                .frame(height: 42)
                .clipShape(shape)
                .overlay(shape.strokeBorder(Color.white.opacity(selected ? 0.95 : (hovering ? 0.35 : 0.12)),
                                            lineWidth: selected ? 2 : 1))
                Text(theme.title)
                    .font(.system(size: 10, weight: selected ? .semibold : .medium))
                    .foregroundStyle(.white.opacity(selected ? 1 : 0.65))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .hoverState($hovering)
    }
}

struct TintDot: View {
    let option: ThemeTint
    let albumAccent: Color
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if let color = option.color {
                    Circle().fill(color)
                } else {
                    Circle().fill(AngularGradient(colors: [.red, .orange, .yellow, .green, .blue, .purple, .red],
                                                  center: .center))
                    Image(systemName: "music.note")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 14, height: 14)
            .padding(2)
            .contentShape(Circle())
            .overlay(Circle().strokeBorder(Color.white.opacity(selected ? 0.95 : 0), lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .help(option.title)
    }
}

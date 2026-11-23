import SwiftUI

struct NowPlayingView: View {
    @EnvironmentObject var media: MediaController

    var body: some View {
        if let np = media.nowPlaying {
            HStack(spacing: 12) {
                ArtworkView(image: media.artwork, size: 76, corner: 14)
                    .shadow(color: media.accent.opacity(0.35), radius: 12)
                    .onTapGesture { media.launch(np.source) }

                VStack(alignment: .leading, spacing: 6) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(np.title)
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)
                        Text(np.artist)
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                    }
                    ProgressBarView(nowPlaying: np, accent: media.accent) { media.seek(toFraction: $0) }
                    HStack(spacing: 16) {
                        ControlButton(symbol: "backward.fill", size: 13) { media.previousTrack() }
                        ControlButton(symbol: np.isPlaying ? "pause.fill" : "play.fill", size: 19) {
                            media.togglePlayPause()
                        }
                        ControlButton(symbol: "forward.fill", size: 13) { media.nextTrack() }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        } else {
            HStack(spacing: 12) {
                ArtworkView(image: nil, size: 76, corner: 14)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Nothing playing")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Start music in Music or Spotify.")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                    HStack(spacing: 8) {
                        PillButton(title: "Music") { media.launch(.music) }
                        PillButton(title: "Spotify") { media.launch(.spotify) }
                    }
                }
            }
        }
    }
}

struct ArtworkView: View {
    let image: NSImage?
    let size: CGFloat
    let corner: CGFloat

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(colors: [.white.opacity(0.14), .white.opacity(0.05)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.36, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}

struct ProgressBarView: View {
    let nowPlaying: NowPlaying
    let accent: Color
    let onSeek: (Double) -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let elapsed = nowPlaying.elapsed(at: context.date)
            let fraction = nowPlaying.duration > 0 ? elapsed / nowPlaying.duration : 0
            HStack(spacing: 8) {
                Text(format(elapsed)).monospacedDigit()
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.15))
                        Capsule().fill(accent)
                            .frame(width: max(4, geo.size.width * fraction))
                            .animation(.linear(duration: 0.5), value: fraction)
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onEnded { value in
                        onSeek(value.location.x / max(1, geo.size.width))
                    })
                }
                .frame(height: 5)
                Text(format(nowPlaying.duration)).monospacedDigit()
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.white.opacity(0.55))
        }
    }

    private func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let s = Int(seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

struct ControlButton: View {
    let symbol: String
    let size: CGFloat
    let action: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: size + 16, height: size + 12)
                .background(Circle().fill(Color.white.opacity(hovering ? 0.12 : 0)))
                .contentShape(Circle()) // clickable across the whole circle, not just the glyph
        }
        .buttonStyle(.plain)
        .hoverState($hovering)
    }
}

struct PillButton: View {
    let title: String
    let action: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.white.opacity(hovering ? 0.2 : 0.12)))
        }
        .buttonStyle(.plain)
        .hoverState($hovering)
    }
}

/// Shown inside the closed notch while music plays and/or a focus timer runs:
/// artwork (or timer ring) on the left, equalizer (or time left) on the right.
struct CollapsedLiveActivity: View {
    @EnvironmentObject var vm: NotchViewModel
    @EnvironmentObject var media: MediaController
    @EnvironmentObject var timer: FocusTimer

    var body: some View {
        let h = vm.notchSize.height
        let timerShown = timer.phase != .idle
        let playing = media.nowPlaying?.isPlaying == true
        HStack(spacing: 0) {
            Group {
                if playing {
                    ArtworkView(image: media.artwork, size: h - 10, corner: 6)
                } else if timerShown {
                    TimerRing().frame(width: h * 0.5, height: h * 0.5)
                }
            }
            .frame(width: vm.liveInset, alignment: .center)
            Spacer(minLength: vm.notchSize.width)
            Group {
                if timerShown {
                    TimerCompactLabel()
                } else if playing {
                    EqualizerView(color: media.accent)
                        .frame(width: 18, height: h * 0.42)
                }
            }
            .frame(width: vm.liveInset, alignment: .center)
        }
        .frame(height: h)
    }
}

/// Equalizer bars animated by Core Animation, which runs in the system render server —
/// so the closed notch costs Islet ~0% CPU while music plays (vs. redrawing 30×/s).
struct EqualizerView: NSViewRepresentable {
    let color: Color

    func makeNSView(context: Context) -> EqualizerBarsView { EqualizerBarsView() }

    func updateNSView(_ view: EqualizerBarsView, context: Context) {
        view.barColor = NSColor(color)
    }
}

final class EqualizerBarsView: NSView {
    var barColor: NSColor = .white {
        didSet { bars.forEach { $0.backgroundColor = barColor.cgColor } }
    }
    private var bars: [CALayer] = []
    private let durations: [CFTimeInterval] = [0.42, 0.55, 0.37, 0.61]
    private let offsets: [CFTimeInterval] = [0, 0.21, 0.09, 0.33]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for _ in 0..<4 {
            let bar = CALayer()
            bar.backgroundColor = barColor.cgColor
            layer?.addSublayer(bar)
            bars.append(bar)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let gap: CGFloat = 2
        let width = max(1, (bounds.width - gap * 3) / 4)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, bar) in bars.enumerated() {
            bar.bounds = CGRect(x: 0, y: 0, width: width, height: bounds.height)
            bar.position = CGPoint(x: CGFloat(i) * (width + gap) + width / 2, y: bounds.midY)
            bar.cornerRadius = width / 2
        }
        CATransaction.commit()
        startAnimating()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        startAnimating()
    }

    private func startAnimating() {
        guard window != nil else { return }
        for (i, bar) in bars.enumerated() where bar.animation(forKey: "bounce") == nil {
            let anim = CABasicAnimation(keyPath: "transform.scale.y")
            anim.fromValue = 0.3
            anim.toValue = 1.0
            anim.duration = durations[i]
            anim.autoreverses = true
            anim.repeatCount = .infinity
            anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            anim.beginTime = CACurrentMediaTime() + offsets[i]
            anim.isRemovedOnCompletion = false
            bar.add(anim, forKey: "bounce")
        }
    }
}

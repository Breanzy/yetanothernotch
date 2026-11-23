import AppKit
import SwiftUI

/// A Pomodoro-style countdown. One click starts the default length (1 hour unless changed).
@MainActor
final class FocusTimer: ObservableObject {
    enum Phase: Equatable {
        case idle
        case running(end: Date)
        case paused(remaining: TimeInterval)
        case finished
    }

    static let presets: [TimeInterval] = [5, 15, 25, 45, 60, 90].map { $0 * 60 }

    @Published private(set) var phase: Phase = .idle
    /// Length of the current session (used for the progress ring).
    @Published private(set) var sessionLength: TimeInterval
    @Published var defaultLength: TimeInterval {
        didSet {
            UserDefaults.standard.set(defaultLength, forKey: "timer.default")
            if phase == .idle { sessionLength = defaultLength }
        }
    }

    private var completion: Timer?
    private var clearFinished: DispatchWorkItem?

    init() {
        let saved = UserDefaults.standard.double(forKey: "timer.default")
        defaultLength = saved > 0 ? saved : 60 * 60
        sessionLength = saved > 0 ? saved : 60 * 60
    }

    var isActive: Bool {
        switch phase {
        case .running, .paused: true
        default: false
        }
    }

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    func remaining(at date: Date = Date()) -> TimeInterval {
        switch phase {
        case .idle: defaultLength
        case .running(let end): max(0, end.timeIntervalSince(date))
        case .paused(let remaining): remaining
        case .finished: 0
        }
    }

    func progress(at date: Date = Date()) -> Double {
        // Idle: an empty ring, even if the default length was just changed.
        guard phase != .idle, sessionLength > 0 else { return 0 }
        return min(1, max(0, 1 - remaining(at: date) / sessionLength))
    }

    /// How often time-based views need to redraw: every second while counting down,
    /// otherwise practically never (state changes redraw them anyway).
    var tickInterval: TimeInterval { isRunning ? 1 : 3600 }

    // MARK: - Actions

    /// The quick button: start → pause → resume.
    func toggle() {
        switch phase {
        case .idle, .finished: start()
        case .running: pause()
        case .paused: resume()
        }
    }

    func start(_ length: TimeInterval? = nil) {
        let length = length ?? defaultLength
        sessionLength = length
        run(until: Date().addingTimeInterval(length))
    }

    func pause() {
        guard case .running = phase else { return }
        completion?.invalidate()
        phase = .paused(remaining: remaining())
    }

    func resume() {
        guard case .paused(let remaining) = phase else { return }
        run(until: Date().addingTimeInterval(remaining))
    }

    func add(minutes: Double) {
        switch phase {
        case .running(let end):
            sessionLength += minutes * 60
            run(until: end.addingTimeInterval(minutes * 60))
        case .paused(let remaining):
            sessionLength += minutes * 60
            phase = .paused(remaining: remaining + minutes * 60)
        default:
            start(minutes * 60)
        }
    }

    func reset() {
        completion?.invalidate()
        clearFinished?.cancel()
        phase = .idle
        sessionLength = defaultLength
    }

    private func run(until end: Date) {
        completion?.invalidate()
        clearFinished?.cancel()
        phase = .running(end: end)
        let t = Timer(fire: end, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish() }
        }
        RunLoop.main.add(t, forMode: .common)
        completion = t
    }

    private func finish() {
        phase = .finished
        NSSound(named: "Glass")?.play()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { NSSound(named: "Glass")?.play() }
        Haptics.tap()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { Haptics.tap() }
        // Show "Done" in the notch for a little while, then go back to idle.
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                if self?.phase == .finished { self?.reset() }
            }
        }
        clearFinished = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: work)
    }

    // MARK: - Formatting

    static func format(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.up))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    static func label(for length: TimeInterval) -> String {
        let minutes = Int(length / 60)
        if minutes % 60 == 0 { return minutes == 60 ? "1 hour" : "\(minutes / 60) hours" }
        return minutes > 60 ? "\(minutes / 60) hr \(minutes % 60) min" : "\(minutes) min"
    }
}

// MARK: - Views

/// Home widget: a progress ring with the time left. Tap the ring (or ▶︎) to start the default
/// length (1 hour unless changed), tap again to pause. The clock menu has other lengths.
struct TimerTile: View {
    @EnvironmentObject var timer: FocusTimer
    @ViewState private var hovering = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(hovering ? 0.12 : 0.07))

            VStack(spacing: 6) {
                TimelineView(.periodic(from: .now, by: timer.tickInterval)) { ctx in
                    ZStack {
                        Circle().stroke(Color.white.opacity(0.12), lineWidth: 4)
                        Circle()
                            .trim(from: 0, to: timer.phase == .finished ? 1 : timer.progress(at: ctx.date))
                            .stroke(ringColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(.linear(duration: 1), value: timer.progress(at: ctx.date))
                        VStack(spacing: 1) {
                            Text(timeText(at: ctx.date))
                                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                            Text(statusText)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                    }
                    .frame(width: 62, height: 62)
                }
                .contentShape(Circle())
                .onTapGesture { withAnimation(Animation.snappy.scaled) { timer.toggle() } }
                .help(primaryHelp)

                HStack(spacing: 6) {
                    roundButton(timer.isRunning ? "pause.fill" : "play.fill", help: primaryHelp) {
                        withAnimation(Animation.snappy.scaled) { timer.toggle() }
                    }
                    if timer.isActive || timer.phase == .finished {
                        roundButton("arrow.counterclockwise", help: "Reset") {
                            withAnimation(Animation.snappy.scaled) { timer.reset() }
                        }
                    }
                    MenuIconButton(symbol: "clock", help: "Timer lengths") { [timer] in
                        let menu = NSMenu()
                        menu.addItem(.sectionHeader(title: "Start"))
                        for length in FocusTimer.presets {
                            menu.addItem(ClosureMenuItem(FocusTimer.label(for: length)) { timer.start(length) })
                        }
                        if timer.isActive {
                            menu.addItem(.separator())
                            menu.addItem(ClosureMenuItem("Add 5 min") { timer.add(minutes: 5) })
                        }
                        menu.addItem(.separator())
                        menu.addItem(.sectionHeader(title: "Default length"))
                        for length in FocusTimer.presets {
                            let item = ClosureMenuItem(FocusTimer.label(for: length)) { timer.defaultLength = length }
                            item.state = timer.defaultLength == length ? .on : .off
                            menu.addItem(item)
                        }
                        return menu
                    }
                }
            }
        }
        .hoverState($hovering)
    }

    private func roundButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            SymbolImage(symbol) // play ⇄ pause crossfades (see SymbolImage)
                .font(.system(size: 10, weight: .bold))
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var ringColor: Color {
        switch timer.phase {
        case .finished: .green
        case .paused: .white.opacity(0.5)
        default: .orange
        }
    }

    private var statusText: String {
        switch timer.phase {
        case .idle: "Focus"
        case .running: "Focusing"
        case .paused: "Paused"
        case .finished: "Done!"
        }
    }

    private var primaryHelp: String {
        switch timer.phase {
        case .idle, .finished: "Start a \(FocusTimer.label(for: timer.defaultLength)) focus timer"
        case .running: "Pause"
        case .paused: "Resume"
        }
    }

    private func timeText(at date: Date) -> String {
        switch timer.phase {
        case .idle: FocusTimer.format(timer.defaultLength)
        case .finished: "0:00"
        default: FocusTimer.format(timer.remaining(at: date))
        }
    }
}

/// Small progress ring used in the closed notch.
struct TimerRing: View {
    @EnvironmentObject var timer: FocusTimer

    var body: some View {
        TimelineView(.periodic(from: .now, by: timer.tickInterval)) { ctx in
            ZStack {
                Circle().stroke(Color.white.opacity(0.15), lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: timer.phase == .finished ? 1 : timer.progress(at: ctx.date))
                    .stroke(timer.phase == .finished ? Color.green : .orange,
                            style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
    }
}

/// Remaining time shown on the right side of the closed notch.
struct TimerCompactLabel: View {
    @EnvironmentObject var timer: FocusTimer

    var body: some View {
        TimelineView(.periodic(from: .now, by: timer.tickInterval)) { ctx in
            Group {
                if timer.phase == .finished {
                    Label("Done", systemImage: "checkmark")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.green)
                        .symbolEffect(.pulse)
                } else {
                    Text(FocusTimer.format(timer.remaining(at: ctx.date)))
                        .foregroundStyle(timer.isRunning ? Color.orange : .white.opacity(0.5))
                }
            }
            .font(.system(size: 12, weight: .semibold).monospacedDigit())
            .lineLimit(1)
            .fixedSize()
        }
    }
}

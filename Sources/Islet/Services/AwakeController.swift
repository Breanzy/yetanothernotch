import AppKit
import IOKit.pwr_mgt
import SwiftUI

/// "Keep Awake" mode: stops the display and the Mac from idle-sleeping, and keeps the screen
/// saver / idle lock from kicking in, for a chosen duration or until turned off.
///
/// Uses the standard power-management assertions (the same mechanism as `caffeinate`), plus a
/// periodic "user is active" declaration so the idle screen saver and lock timer never fire.
/// It can't stop a manual lock (⌃⌘Q) or closing the lid — macOS doesn't allow that, on purpose.
@MainActor
final class AwakeController: ObservableObject {
    @Published private(set) var isOn = false
    /// When awake mode ends on its own; `nil` while on means "until turned off".
    @Published private(set) var endsAt: Date?

    /// `nil` = indefinitely.
    static let durations: [TimeInterval?] = [nil, 30 * 60, 60 * 60, 2 * 3600, 4 * 3600, 8 * 3600]

    private var displayAssertion: IOPMAssertionID = 0
    private var systemAssertion: IOPMAssertionID = 0
    private var activityAssertion: IOPMAssertionID = 0
    private var activityTimer: Timer?
    private var endTimer: Timer?
    private let reason = "Islet Keep Awake" as CFString

    func toggle() {
        isOn ? stop() : start(for: nil)
    }

    func start(for duration: TimeInterval?) {
        releaseAll()
        IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                    IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &displayAssertion)
        IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                    IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &systemAssertion)
        declareActivity()
        // Re-declaring activity resets the idle timer that starts the screen saver / lock.
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.declareActivity() }
        }
        t.tolerance = 5
        RunLoop.main.add(t, forMode: .common)
        activityTimer = t

        if let duration {
            let end = Date().addingTimeInterval(duration)
            endsAt = end
            let e = Timer(fire: end, interval: 0, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.stop() }
            }
            RunLoop.main.add(e, forMode: .common)
            endTimer = e
        } else {
            endsAt = nil
        }
        isOn = true
    }

    func stop() {
        releaseAll()
        isOn = false
        endsAt = nil
    }

    private func declareActivity() {
        IOPMAssertionDeclareUserActivity(reason, kIOPMUserActiveLocal, &activityAssertion)
    }

    private func releaseAll() {
        activityTimer?.invalidate(); activityTimer = nil
        endTimer?.invalidate(); endTimer = nil
        for id in [displayAssertion, systemAssertion, activityAssertion] where id != 0 {
            IOPMAssertionRelease(id)
        }
        displayAssertion = 0; systemAssertion = 0; activityAssertion = 0
    }

    // MARK: - Labels

    static func label(for duration: TimeInterval?) -> String {
        guard let duration else { return "Indefinitely" }
        let minutes = Int(duration / 60)
        if minutes < 60 { return "\(minutes) minutes" }
        return minutes == 60 ? "1 hour" : "\(minutes / 60) hours"
    }

    func remainingText(at date: Date = Date()) -> String {
        guard isOn else { return "Off" }
        guard let endsAt else { return "Until off" }
        let s = max(0, Int(endsAt.timeIntervalSince(date)))
        if s >= 3600 { return "\(s / 3600)h \((s % 3600) / 60)m left" }
        return "\(max(1, s / 60))m left"
    }
}

// MARK: - Home tile

struct AwakeTile: View {
    @EnvironmentObject var awake: AwakeController
    @ViewState private var hovering = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(awake.isOn ? Color.orange.opacity(hovering ? 0.32 : 0.24)
                                 : Color.white.opacity(hovering ? 0.12 : 0.07))

            VStack(spacing: 5) {
                SymbolImage(awake.isOn ? "cup.and.heat.waves.fill" : "cup.and.saucer")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(awake.isOn ? Color.orange : .white.opacity(0.6))
                    .frame(height: 28)
                Text(awake.isOn ? "Awake" : "Keep Awake")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(awake.isOn ? 1 : 0.7))
                TimelineView(.periodic(from: .now, by: awake.endsAt == nil ? 3600 : 30)) { ctx in
                    Text(awake.remainingText(at: ctx.date))
                        .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.5))
                }
                MenuIconButton(symbol: "clock", help: "Keep awake for…") { [awake] in
                    let menu = NSMenu()
                    for duration in AwakeController.durations {
                        menu.addItem(ClosureMenuItem(AwakeController.label(for: duration)) { awake.start(for: duration) })
                    }
                    if awake.isOn {
                        menu.addItem(.separator())
                        menu.addItem(ClosureMenuItem("Turn Off") { awake.stop() })
                    }
                    return menu
                }
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .hoverState($hovering)
        .onTapGesture { withAnimation(.snappy(duration: 0.2)) { awake.toggle() } }
        .animation(.snappy(duration: 0.2), value: awake.isOn)
        .help(awake.isOn ? "Click to let your Mac sleep again"
                         : "Click to keep your Mac awake (no sleep, screen saver or auto-lock)")
    }
}

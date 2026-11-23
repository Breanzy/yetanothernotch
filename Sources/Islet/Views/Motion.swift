import SwiftUI

/// Global animation speed (Settings → Behavior → Animations).
///
/// Every UI animation goes through `Animation.scaled`: at speed 1 it's unchanged, higher is
/// faster, and 0 means Instant: no animation at all, things just appear. (The music progress
/// bar and the timer ring keep gliding; they show time passing, not a UI transition.)
@MainActor
enum Motion {
    static var speed: Double = 1

    static func scaled(_ base: Animation) -> Animation? {
        if speed <= 0 { return nil }
        return speed == 1 ? base : base.speed(speed)
    }
}

extension Animation {
    /// This animation at the user's chosen speed, or `nil` (no animation) when set to Instant.
    @MainActor var scaled: Animation? { Motion.scaled(self) }
}

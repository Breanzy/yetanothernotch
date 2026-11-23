import AppKit

/// Trackpad haptics.
///
/// `NSHapticFeedbackManager` only plays for the app you're actively using, and Islet never is
/// (it's a background panel), so macOS silently drops those requests. Instead we drive the
/// trackpad's actuator through MultitouchSupport — the private framework behind Force Click,
/// also used by other notch utilities. It's loaded with `dlopen`, so if a future macOS changes
/// it, Islet simply falls back to `NSHapticFeedbackManager` instead of crashing.
@MainActor
enum Haptics {
    private typealias CreateDefault = @convention(c) () -> UnsafeMutableRawPointer?
    private typealias GetDeviceID = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<UInt64>) -> Int32
    private typealias ActuatorCreate = @convention(c) (UInt64) -> UnsafeMutableRawPointer?
    private typealias ActuatorOpen = @convention(c) (UnsafeMutableRawPointer) -> Int32
    private typealias ActuatorActuate = @convention(c) (UnsafeMutableRawPointer, Int32, UInt32, Float, Float) -> Int32

    private static let handle = dlopen(
        "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_LAZY)

    private static func symbol<T>(_ name: String, as _: T.Type) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    private static let actuate = symbol("MTActuatorActuate", as: ActuatorActuate.self)

    /// Opened once and kept; reopened if the trackpad changes.
    private static var actuator: UnsafeMutableRawPointer?

    private static func openActuator() -> UnsafeMutableRawPointer? {
        if let actuator { return actuator }
        guard let createDefault = symbol("MTDeviceCreateDefault", as: CreateDefault.self),
              let getID = symbol("MTDeviceGetDeviceID", as: GetDeviceID.self),
              let create = symbol("MTActuatorCreateFromDeviceID", as: ActuatorCreate.self),
              let open = symbol("MTActuatorOpen", as: ActuatorOpen.self),
              let device = createDefault() else { return nil }
        var deviceID: UInt64 = 0
        guard getID(device, &deviceID) == 0, let candidate = create(deviceID), open(candidate) == 0 else { return nil }
        actuator = candidate
        return candidate
    }

    /// Plays a short click on the trackpad if haptics are enabled (or `force` is true).
    /// Returns true when the trackpad actuator accepted it.
    @discardableResult
    static func tap(force: Bool = false) -> Bool {
        guard force || Settings.haptics else { return false }
        if let actuate, let actuator = openActuator() {
            if actuate(actuator, 6, 0, 0, 0) == 0 { return true }
            // The device may have changed (e.g. external trackpad); retry once with a fresh one.
            self.actuator = nil
            if let fresh = openActuator(), actuate(fresh, 6, 0, 0, 0) == 0 { return true }
        }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        return false
    }
}

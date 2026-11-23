import AppKit
@preconcurrency import AVFoundation
import SwiftUI

/// Runs the front camera so the notch can act as a quick mirror.
/// The camera is only on while the mirror is open; it shuts off when the notch closes.
///
/// Clicks only record what the user *wants* (camera on or off). A single serial job then
/// reconciles the real camera with the latest wish, so rapid clicking can never leave the
/// UI and the camera out of sync.
@MainActor
final class MirrorController: ObservableObject {
    enum State: Equatable { case off, starting, on, denied, unavailable }

    @Published private(set) var state: State = .off

    /// Created the first time the mirror is opened (the camera stack costs several MB),
    /// then reused. Views re-host the single preview layer instead of creating new ones.
    private var _session: AVCaptureSession?
    private var _previewLayer: AVCaptureVideoPreviewLayer?

    var session: AVCaptureSession {
        if let s = _session { return s }
        let s = AVCaptureSession()
        _session = s
        // If the camera gets taken by another app or errors out, reflect that instead of
        // showing a frozen/black tile.
        let center = NotificationCenter.default
        for name in [AVCaptureSession.runtimeErrorNotification, AVCaptureSession.wasInterruptedNotification] {
            observers.append(center.addObserver(forName: name, object: s, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reconcile() }
            })
        }
        return s
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        if let l = _previewLayer { return l }
        let l = AVCaptureVideoPreviewLayer(session: session)
        l.videoGravity = .resizeAspectFill
        l.backgroundColor = NSColor.black.cgColor
        _previewLayer = l
        return l
    }

    private let queue = DispatchQueue(label: "app.islet.camera")
    private let lock = NSLock()
    nonisolated(unsafe) private var wantsRunning = false
    nonisolated(unsafe) private var configured = false
    private var observers: [NSObjectProtocol] = []
    private var releaseWork: DispatchWorkItem?
    /// The camera permission prompt is showing; start only if still wanted when it's answered.
    private var awaitingPermission = false

    var isActive: Bool { state == .on || state == .starting }

    func toggle() {
        isActive ? stop() : start()
    }

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            setWants(true)
        case .notDetermined:
            state = .starting
            awaitingPermission = true
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        // The island may have closed (or the mirror been turned off) while the
                        // permission prompt was up; never start the camera in a closed notch.
                        let stillWanted = self.awaitingPermission
                        self.awaitingPermission = false
                        if !granted { self.state = .denied }
                        else if stillWanted { self.setWants(true) }
                        else { self.state = .off }
                    }
                }
            }
        default:
            state = .denied
        }
    }

    func stop() {
        if awaitingPermission {
            awaitingPermission = false
            state = .off
            return
        }
        guard state != .denied, _session != nil || state != .off else { return }
        setWants(false)
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Reconciliation

    /// Fully tears down the camera stack (session, inputs, preview layer, frame buffers)
    /// once the mirror has been off for a while; it's rebuilt on the next use.
    private func scheduleRelease() {
        releaseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.state == .off || self.state == .unavailable,
                      !self.lock.withLock({ self.wantsRunning }),
                      let session = self._session else { return }
                self.observers.forEach(NotificationCenter.default.removeObserver)
                self.observers.removeAll()
                self._previewLayer?.removeFromSuperlayer()
                self._previewLayer = nil
                self._session = nil
                self.queue.async { [weak self] in
                    if session.isRunning { session.stopRunning() }
                    session.beginConfiguration()
                    session.inputs.forEach(session.removeInput)
                    session.commitConfiguration()
                    self?.configured = false
                }
            }
        }
        releaseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: work)
    }

    private func setWants(_ wants: Bool) {
        if wants { releaseWork?.cancel() } else { scheduleRelease() }
        lock.withLock { wantsRunning = wants }
        state = wants ? .starting : .off
        reconcile()
    }

    private func reconcile() {
        // Turning off a camera that was never created: nothing to do (and don't create one).
        if _session == nil, !lock.withLock({ wantsRunning }) {
            if state != .denied { state = .off }
            return
        }
        let session = session
        queue.async { [weak self] in
            guard let self else { return }
            let wants = self.lock.withLock { self.wantsRunning }
            var failed = false

            if wants {
                if !self.configured { failed = !self.configure(session) }
                if !failed && !session.isRunning { session.startRunning() }
                if !session.isRunning { failed = true }
            } else if session.isRunning {
                session.stopRunning()
            }

            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // Only publish if this result still matches the latest click.
                    let latest = self.lock.withLock { self.wantsRunning }
                    guard latest == wants else { return }
                    if wants {
                        self.state = failed ? .unavailable : .on
                    } else if self.state != .denied {
                        self.state = .off
                    }
                }
            }
        }
    }

    /// Runs on `queue`.
    nonisolated private func configure(_ session: AVCaptureSession) -> Bool {
        guard let device = Self.frontCamera(),
              let input = try? AVCaptureDeviceInput(device: device) else { return false }
        session.beginConfiguration()
        // The tile is ~120 pt wide, so 640×480 is plenty and uses a fraction of the
        // frame-buffer memory of .high (1080p+).
        session.sessionPreset = session.canSetSessionPreset(.vga640x480) ? .vga640x480 : .medium
        for old in session.inputs { session.removeInput(old) }
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            return false
        }
        session.addInput(input)
        session.commitConfiguration()
        configured = true
        return true
    }

    nonisolated private static func frontCamera() -> AVCaptureDevice? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video, position: .unspecified
        )
        // Prefer the built-in FaceTime camera over iPhone/external cameras.
        return discovery.devices.first(where: { $0.deviceType == .builtInWideAngleCamera })
            ?? AVCaptureDevice.default(for: .video)
            ?? discovery.devices.first
    }
}

// MARK: - Views

/// The mirror tile on the home tab: tap to turn the camera on, tap again to turn it off.
struct MirrorTile: View {
    @EnvironmentObject var mirror: MirrorController
    @ViewState private var hovering = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(hovering ? 0.12 : 0.07))

            // Only mounted once the camera is in use, so it isn't loaded just by opening the panel.
            // The shared preview layer means re-mounting never creates a second camera feed.
            if mirror.state == .on || mirror.state == .starting {
                CameraPreview(layer: mirror.previewLayer)
                    .opacity(mirror.state == .on ? 1 : 0)
                    .allowsHitTesting(false)
            }

            switch mirror.state {
            case .on:
                EmptyView()
            case .starting:
                ProgressView().controlSize(.small)
            case .off:
                label("person.crop.square", "Mirror")
            case .denied:
                label("video.slash", "Allow camera")
            case .unavailable:
                label("video.slash", "Camera busy\nTap to retry")
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contentShape(Rectangle())
        .hoverState($hovering)
        .onTapGesture {
            switch mirror.state {
            case .denied: mirror.openPrivacySettings()
            case .unavailable: mirror.start()
            default: mirror.toggle()
            }
        }
        .overlay(alignment: .topTrailing) {
            EnlargeButton(onEnlarge: { if !mirror.isActive { mirror.start() } })
                .padding(6)
        }
        .animation(Animation.easeInOut(duration: 0.25).scaled, value: mirror.state)
        .help(mirror.isActive ? "Turn off mirror" : "Use your camera as a mirror")
    }

    private func label(_ symbol: String, _ text: String) -> some View {
        VStack(spacing: 6) {
            SymbolImage(symbol)
                .font(.system(size: 22, weight: .medium))
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.white.opacity(0.6))
    }
}

/// The enlarged mirror: the live camera fills the whole home area.
struct MirrorLarge: View {
    @EnvironmentObject var mirror: MirrorController

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        ZStack {
            shape.fill(Color.white.opacity(0.07))
            if mirror.state == .on || mirror.state == .starting {
                CameraPreview(layer: mirror.previewLayer)
                    .opacity(mirror.state == .on ? 1 : 0)
                    .allowsHitTesting(false)
            }
            switch mirror.state {
            case .starting:
                ProgressView().controlSize(.small)
            case .off:
                Button("Turn on camera") { mirror.start() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
            case .denied:
                Button("Allow camera access in System Settings") { mirror.openPrivacySettings() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
            case .unavailable:
                Button("Camera busy — tap to retry") { mirror.start() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
            case .on:
                EmptyView()
            }
        }
        .clipShape(shape)
        .overlay(alignment: .topTrailing) { EnlargeButton().padding(8) }
        .onAppear { if !mirror.isActive { mirror.start() } }
        .animation(Animation.easeInOut(duration: 0.25).scaled, value: mirror.state)
    }
}

/// Hosts the shared, horizontally flipped camera preview layer (so it behaves like a real mirror).
struct CameraPreview: NSViewRepresentable {
    let layer: AVCaptureVideoPreviewLayer

    func makeNSView(context: Context) -> PreviewView {
        PreviewView(previewLayer: layer)
    }

    func updateNSView(_ nsView: PreviewView, context: Context) {}

    final class PreviewView: NSView {
        private let previewLayer: AVCaptureVideoPreviewLayer

        init(previewLayer: AVCaptureVideoPreviewLayer) {
            self.previewLayer = previewLayer
            super.init(frame: .zero)
            wantsLayer = true
            layer?.backgroundColor = NSColor.black.cgColor
            previewLayer.removeFromSuperlayer()
            layer?.addSublayer(previewLayer)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            // Re-claim the shared layer if another view took it, and keep it mirrored.
            if previewLayer.superlayer !== layer {
                previewLayer.removeFromSuperlayer()
                layer?.addSublayer(previewLayer)
            }
            previewLayer.setAffineTransform(.identity)
            previewLayer.frame = bounds
            previewLayer.setAffineTransform(CGAffineTransform(scaleX: -1, y: 1))
            CATransaction.commit()
        }
    }
}

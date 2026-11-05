import AVFoundation
import Foundation
import Observation

@Observable @MainActor final class AudioOutputMonitor {
    struct RouteSnapshot: Equatable {
        var name: String
        var portTypes: [AVAudioSession.Port]
        var volume: Float
    }
    private(set) var routeName = "No audio output"
    private(set) var isBluetooth = false
    var needsGlassesOutput: Bool { !isBluetooth }
    private(set) var volume: Float = 0
    private(set) var testPlaying = false
    private(set) var message: String?
    private(set) var lastTestDiagnostics: String?
    var onStateChange: (() -> Void)?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var volumeObserver: NSKeyValueObservation?
    @ObservationIgnored private var testPlayer: LiveVoicePCMPlayer?
    @ObservationIgnored private var testGeneration = UUID()
    @ObservationIgnored private var keepSessionActive = false
    @ObservationIgnored private let readRoute: () -> RouteSnapshot
    @ObservationIgnored private let activateRouteSelection: () throws -> Void
    @ObservationIgnored private let deactivateRouteSelection: () -> Void
    @ObservationIgnored private var routeSelectionActive = false

    init(readRoute: (() -> RouteSnapshot)? = nil, activateRouteSelection: (() throws -> Void)? = nil,
         deactivateRouteSelection: (() -> Void)? = nil) {
        self.readRoute = readRoute ?? {
            let session = AVAudioSession.sharedInstance(), outputs = session.currentRoute.outputs
            return RouteSnapshot(name: outputs.isEmpty ? "No audio output" : outputs.map(\.portName).joined(separator: ", "),
                                 portTypes: outputs.map(\.portType), volume: session.outputVolume)
        }
        self.activateRouteSelection = activateRouteSelection ?? { try GlassesAudioRoute.preparePlaybackSession() }
        self.deactivateRouteSelection = deactivateRouteSelection ?? {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        refresh()
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        })
        volumeObserver = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }

    func refresh() {
        let route = readRoute()
        let bluetooth = GlassesAudioRoute.supportsSpeech(portTypes: route.portTypes)
        let changed = routeName != route.name || isBluetooth != bluetooth || volume != route.volume
        routeName = route.name; isBluetooth = bluetooth; volume = route.volume
        if changed { onStateChange?() }
    }

    /// Makes playback destinations available in the native route picker, even
    /// when speech preparation was blocked by the current phone-speaker route.
    /// This does not open a recording session or choose a device on the user's behalf.
    func prepareForRouteSelection() {
        do {
            try activateRouteSelection()
            routeSelectionActive = true
            message = nil
        } catch {
            message = "Audio outputs are unavailable. Check Bluetooth and try again."
        }
        refresh()
        onStateChange?()
    }

    /// Keep ownership while voice is active: its speech driver may still be
    /// unavailable, so the monitor must release this session on End voice.
    /// Opening just the picker must not leave other audio ducked after closing.
    func finishRouteSelection(keepSessionActive: Bool) {
        guard routeSelectionActive else { return }
        if !keepSessionActive {
            routeSelectionActive = false
            deactivateRouteSelection()
        }
        refresh()
    }

    /// Uses the same PCM graph as Live, with a local signal and no network or mic.
    /// The coordinator silences Live output while testing and decides whether
    /// this test may deactivate the app's shared audio session on completion.
    func testSound(keepSessionActive: Bool = false) async throws {
        cancelTest()
        let current = UUID(); testGeneration = current
        self.keepSessionActive = keepSessionActive
        let player = LiveVoicePCMPlayer(enableDiagnostics: true, keepSessionActiveOnStop: keepSessionActive)
        testPlayer = player; testPlaying = true; message = nil; lastTestDiagnostics = nil
        onStateChange?()
        var failure: String?
        player.onFailure = { failure = $0 }
        defer {
            if testGeneration == current {
                lastTestDiagnostics = player.diagnostics.report
                player.stop(keepSessionActive: keepSessionActive)
                testPlayer = nil; testPlaying = false; refresh()
                onStateChange?()
            }
        }
        do {
            try Task.checkCancellation()
            try player.prepare(); refresh()
            guard !needsGlassesOutput else {
                throw LiveVoiceError.message(GlassesAudioRoute.selectionRequiredMessage)
            }
            let pcm = Self.testPCM
            try player.enqueue(pcm)
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while ContinuousClock.now < deadline {
                try Task.checkCancellation()
                guard testGeneration == current else { throw CancellationError() }
                if let failure { throw LiveVoiceError.message(failure) }
                let stats = player.diagnostics
                if stats.playedFrames >= pcm.count / 2, stats.mixedPeak > 0.001 {
                    refresh()
                    if volume <= 0.001 { message = "Output volume is zero. Raise the media volume and try the sound test again." }
                    else if !isBluetooth { message = "Sound was sent to \(routeName). Select your glasses in Audio output to hear it there." }
                    else { message = "Two test tones were sent to \(routeName)." }
                    return
                }
                try await Task.sleep(for: .milliseconds(25))
            }
            throw LiveVoiceError.message("The audio graph did not finish the sound test. Reconnect the output and try again.")
        } catch {
            if testGeneration == current, !(error is CancellationError) { message = error.localizedDescription }
            throw error
        }
    }

    func cancelTest() {
        let wasPlaying = testPlaying
        testGeneration = UUID()
        testPlayer?.stop(keepSessionActive: keepSessionActive); testPlayer = nil
        testPlaying = false
        if wasPlaying { onStateChange?() }
    }

    /// Two gentle, tapered tones with a short lead-in for Bluetooth wake-up.
    static var testPCM: Data {
        let rate = 24_000, lead = 4800, tone = 6000, gap = 3600
        let total = lead + tone * 2 + gap
        var data = Data(capacity: total * 2)
        for frame in 0..<total {
            let position: Int, frequency: Double
            if frame >= lead, frame < lead + tone { position = frame - lead; frequency = 520 }
            else if frame >= lead + tone + gap { position = frame - lead - tone - gap; frequency = 780 }
            else { position = -1; frequency = 0 }
            var sample: Double = 0
            if position >= 0 {
                let envelope = min(1, min(Double(position) / 240, Double(tone - 1 - position) / 240))
                sample = sin(2 * .pi * frequency * Double(position) / Double(rate)) * 0.16 * envelope
            }
            let value = UInt16(bitPattern: Int16((sample * 32767).rounded()))
            data.append(UInt8(truncatingIfNeeded: value)); data.append(UInt8(truncatingIfNeeded: value >> 8))
        }
        return data
    }
}

import AVFoundation
import Foundation

@MainActor protocol LiveVoicePlayback: AnyObject {
    var onActivityChange: ((Bool) -> Void)? { get set }
    var onFailure: ((String) -> Void)? { get set }
    var supportsBufferCompletion: Bool { get }
    var onBufferPlayed: ((Int) -> Void)? { get set }
    func prepare() throws
    func enqueue(_ pcm16: Data) throws
    func clear()
    func stop()
}

extension LiveVoicePlayback {
    var onFailure: ((String) -> Void)? { get { nil } set {} }
    var supportsBufferCompletion: Bool { false }
    var onBufferPlayed: ((Int) -> Void)? { get { nil } set {} }
    func prepare() throws {}
}

/// Playback owns no microphone. `.playback` uses the glasses' high-quality A2DP
/// route when selected; it must never switch the session to Bluetooth HFP.
@MainActor final class LiveVoicePCMPlayer: LiveVoicePlayback {
    var onActivityChange: ((Bool) -> Void)?
    var onFailure: ((String) -> Void)?
    let supportsBufferCompletion = true
    var onBufferPlayed: ((Int) -> Void)?
    struct Diagnostics {
        let routeName: String
        let portTypes: [String]
        let volume: Float
        let engineRunning: Bool
        let playerPlaying: Bool
        let scheduledFrames: Int
        let playedFrames: Int
        let queuedFrames: Int
        let mixedFrames: Int
        let mixedPeak: Float
        let outputSampleRate: Double
        let outputChannels: UInt32
        var isBluetooth: Bool {
            GlassesAudioRoute.supportsSpeech(portTypes: portTypes.map { AVAudioSession.Port(rawValue: $0) })
        }
        var report: String {
            "route=\(routeName); ports=\(portTypes.joined(separator: ",")); volume=\(volume); engine=\(engineRunning); player=\(playerPlaying); scheduled=\(scheduledFrames); played=\(playedFrames); queued=\(queuedFrames); mixed=\(mixedFrames); mixedPeak=\(mixedPeak); hardware=\(outputSampleRate)Hz/\(outputChannels)ch"
        }
    }
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000,
                                      channels: 1, interleaved: false)!
    private var queuedFrames = 0
    private var generation = UUID()
    private var connected = false
    private var activity = false
    private var activatedAudioSession = false
    private let enableDiagnostics: Bool
    private let keepSessionActiveOnStop: Bool
    private let readPortTypes: () -> [AVAudioSession.Port]
    private let prepareAudioSession: () throws -> Void
    private let deactivateAudioSession: () -> Void
    private var observers: [NSObjectProtocol] = []
    private var wantsPlayback = false
    private var recovering = false
    private var configuredHardware = ""
    private var tapInstalled = false
    private var meterGeneration = UUID()
    private var scheduledFrames = 0
    private var playedFrames = 0
    private var mixedFrames = 0
    private var mixedPeak: Float = 0

    init(enableDiagnostics: Bool = false, keepSessionActiveOnStop: Bool = false,
         readPortTypes: (() -> [AVAudioSession.Port])? = nil,
         prepareAudioSession: (() throws -> Void)? = nil,
         deactivateAudioSession: (() -> Void)? = nil) {
        self.enableDiagnostics = enableDiagnostics
        self.keepSessionActiveOnStop = keepSessionActiveOnStop
        self.readPortTypes = readPortTypes ?? { AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portType) }
        self.prepareAudioSession = prepareAudioSession ?? { try GlassesAudioRoute.preparePlaybackSession() }
        self.deactivateAudioSession = deactivateAudioSession ?? {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        observers.append(NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            Task { @MainActor in self?.recoverConfiguration() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] notification in
            let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard type == AVAudioSession.InterruptionType.began.rawValue else { return }
            Task { @MainActor in self?.failOutput("Audio playback was interrupted. Start live voice again when ready.") }
        })
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.wantsPlayback,
                      !GlassesAudioRoute.supportsSpeech(portTypes: self.readPortTypes()) else { return }
                self.failOutput(GlassesAudioRoute.selectionRequiredMessage)
            }
        })
    }

    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }

    var diagnostics: Diagnostics {
        let session = AVAudioSession.sharedInstance(), hardware = engine.outputNode.outputFormat(forBus: 0)
        return Diagnostics(routeName: session.currentRoute.outputs.map(\.portName).joined(separator: ", "),
            portTypes: session.currentRoute.outputs.map { $0.portType.rawValue }, volume: session.outputVolume,
            engineRunning: engine.isRunning, playerPlaying: player.isPlaying, scheduledFrames: scheduledFrames,
            playedFrames: playedFrames, queuedFrames: queuedFrames, mixedFrames: mixedFrames, mixedPeak: mixedPeak,
            outputSampleRate: hardware.sampleRate, outputChannels: hardware.channelCount)
    }

    /// Establish output before the server's first packet. Constructing the mixer
    /// after session activation lets its automatic output connection use the
    /// selected hardware format. A2DP is already enabled by `.playback`.
    func prepare() throws {
        wantsPlayback = true
        do {
            if engine.isRunning { try requireGlassesRoute(); return }
            try prepareAudioSession(); activatedAudioSession = true
            try requireGlassesRoute()
            if !connected {
                engine.attach(player); engine.connect(player, to: engine.mainMixerNode, format: format); connected = true
            }
            installMeterIfNeeded()
            engine.prepare(); try engine.start()
            configuredHardware = hardwareSignature
        } catch {
            stop()
            throw error
        }
    }

    func enqueue(_ pcm16: Data) throws {
        guard !pcm16.isEmpty, pcm16.count.isMultiple(of: 2) else {
            throw LiveVoiceError.message("Live voice returned invalid PCM audio.")
        }
        let count = pcm16.count / 2
        // A bounded queue fails visibly instead of reading obsolete instructions
        // seconds after the user changed the task. Normal audio streams in real time.
        guard queuedFrames + count <= 24_000 * 3 else {
            throw LiveVoiceError.message("Live voice playback fell behind. Please reconnect to continue.")
        }
        // Recheck before every packet, including when the engine remains
        // running after iOS changed its route. Never enqueue onto the phone.
        do { try requireGlassesRoute(); try prepare() }
        catch { stop(); throw error }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
              let samples = buffer.floatChannelData?[0] else { throw LiveVoiceError.message("Live voice could not allocate playback audio.") }
        buffer.frameLength = AVAudioFrameCount(count)
        let bytes = [UInt8](pcm16)
        for index in 0..<count {
            let bits = UInt16(bytes[index * 2]) | (UInt16(bytes[index * 2 + 1]) << 8)
            samples[index] = Float(Int16(bitPattern: bits)) / 32768
        }
        do { try requireGlassesRoute() }
        catch { stop(); throw error }
        let current = generation
        queuedFrames += count; scheduledFrames += count
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == current else { return }
                self.queuedFrames = max(0, self.queuedFrames - count)
                self.playedFrames += count
                // Refill before reporting the whole queue drained. This keeps
                // streamed narration continuous while retaining played-back ACKs.
                self.onBufferPlayed?(count)
                self.setActivity(self.queuedFrames > 0)
            }
        }
        if !player.isPlaying { player.play() }
        setActivity(true)
    }

    func clear() {
        generation = UUID(); player.stop(); queuedFrames = 0; setActivity(false)
    }
    func stop() { stop(keepSessionActive: keepSessionActiveOnStop) }
    func stop(keepSessionActive: Bool) {
        wantsPlayback = false; clear(); engine.stop(); removeMeter()
        if activatedAudioSession {
            activatedAudioSession = false
            if !keepSessionActive { deactivateAudioSession() }
        }
    }
    private var hardwareSignature: String {
        let output = engine.outputNode.outputFormat(forBus: 0)
        return "\(output.sampleRate)-\(output.channelCount)"
    }
    private func requireGlassesRoute() throws {
        guard GlassesAudioRoute.supportsSpeech(portTypes: readPortTypes()) else {
            throw LiveVoiceError.message(GlassesAudioRoute.selectionRequiredMessage)
        }
    }
    private func recoverConfiguration() {
        guard wantsPlayback, !recovering else { return }
        guard GlassesAudioRoute.supportsSpeech(portTypes: readPortTypes()) else {
            failOutput(GlassesAudioRoute.selectionRequiredMessage); return
        }
        // Activation can notify after prepare() already established the correct
        // graph. Ignore that notification instead of restarting our own output.
        guard !engine.isRunning || configuredHardware != hardwareSignature else { return }
        recovering = true; defer { recovering = false }
        clear(); engine.stop(); removeMeter()
        do { try prepare() }
        catch {
            // prepare() already stopped the engine, so deliver the notice even
            // though wantsPlayback has been cleared during its cleanup.
            onFailure?((error as? LiveVoiceError)?.localizedDescription ?? "Audio playback could not recover after the output changed. Reconnect your glasses and try again.")
        }
    }
    private func failOutput(_ message: String) {
        guard wantsPlayback else { return }
        stop(); onFailure?(message)
    }
    private func installMeterIfNeeded() {
        guard enableDiagnostics, !tapInstalled else { return }
        meterGeneration = UUID(); let current = meterGeneration
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            guard let channels = buffer.floatChannelData else { return }
            var peak: Float = 0
            let frames = Int(buffer.frameLength)
            for channel in 0..<Int(buffer.format.channelCount) {
                for frame in 0..<frames { peak = max(peak, abs(channels[channel][frame])) }
            }
            Task { @MainActor [weak self, peak] in
                guard let self, self.meterGeneration == current else { return }
                self.mixedFrames += frames; self.mixedPeak = max(self.mixedPeak, peak)
            }
        }
        tapInstalled = true
    }
    private func removeMeter() {
        meterGeneration = UUID()
        if tapInstalled { engine.mainMixerNode.removeTap(onBus: 0); tapInstalled = false }
    }
    private func setActivity(_ active: Bool) {
        guard activity != active else { return }
        activity = active; onActivityChange?(active)
    }
}

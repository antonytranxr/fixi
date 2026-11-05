import AVFoundation
import Foundation

/// The seam keeps tests offline and lets the output owner fence late native
/// callbacks without relying on didCancel, which is not sent for every stop.
@MainActor protocol SystemSpeechDriver: AnyObject {
    var onFinished: ((UUID) -> Void)? { get set }
    var onCancelled: ((UUID) -> Void)? { get set }
    var onFailure: ((String) -> Void)? { get set }
    func prepare() throws
    func prepareForUtterance() throws
    func speak(_ utterance: AVSpeechUtterance, id: UUID)
    func cancel()
    func stop()
}

/// A Bluetooth port is an eligible private output, not proof that the selected
/// accessory is the glasses. The system picker shows the actual device name.
enum GlassesAudioRoute {
    static let selectionRequiredMessage = "Choose your glasses in Audio output. Spoken replies are paused until a Bluetooth output is selected."

    static func supportsSpeech(portTypes: [AVAudioSession.Port]) -> Bool {
        !portTypes.isEmpty && portTypes.allSatisfy { $0 == .bluetoothA2DP || $0 == .bluetoothLE }
    }

    @MainActor static func preparePlaybackSession() throws {
        let session = AVAudioSession.sharedInstance()
        // Playback already allows A2DP. Do not open an HFP microphone route:
        // the DAT Speech capability owns microphone input independently.
        if session.category != .playback || session.mode != .spokenAudio || session.categoryOptions != [.duckOthers] {
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        }
        // Ask iOS to interrupt immediately on disconnection, before an app
        // notification can otherwise allow playback to move to the phone.
        try session.setPrefersInterruptionOnRouteDisconnect(true)
        try session.setActive(true)
    }
}

/// Reads the completed app reply. There is no network request, conversation,
/// prompt, or second model that can answer or reinterpret the supplied text.
@MainActor final class SystemSpeechOutput: ConversationSpeechOutput {
    struct Limits {
        var textBytes = 24_000
        var completionTimeout: Duration = .seconds(180)
    }
    var onFailure: ((String) -> Void)?
    var onTranscript: ((String) -> Void)?
    private let makeDriver: () -> any SystemSpeechDriver
    private let limits: Limits
    private var driver: (any SystemSpeechDriver)?
    private var generation = UUID()
    private var requestID: UUID?
    private var completion: CheckedContinuation<Bool, Never>?
    private var deadline: Task<Void, Never>?

    init(makeDriver: (() -> any SystemSpeechDriver)? = nil, limits: Limits = Limits()) {
        self.makeDriver = makeDriver ?? { AppleSpeechDriver() }
        self.limits = limits
    }

    /// The legacy contract accepts a key; local speech never stores or uses it.
    func start(apiKey: String) async throws {
        try Task.checkCancellation()
        guard driver == nil else { throw LiveVoiceError.message("Spoken output is already prepared.") }
        let current = UUID(); generation = current
        let candidate = makeDriver()
        candidate.onFinished = { [weak self] id in
            guard let self, self.generation == current, self.requestID == id else { return }
            self.finish(true)
        }
        candidate.onCancelled = { [weak self] id in
            guard let self, self.generation == current, self.requestID == id else { return }
            self.fail("Spoken output was interrupted. You can still read the instructions on screen.")
        }
        candidate.onFailure = { [weak self] message in
            guard let self, self.generation == current, self.driver != nil else { return }
            self.fail(message)
        }
        do { try candidate.prepare() }
        catch {
            candidate.stop()
            if let error = error as? LiveVoiceError { throw error }
            throw LiveVoiceError.message("Spoken output could not use the selected audio route. Check the output and try again.")
        }
        driver = candidate
    }

    func speak(_ text: String) async -> Bool {
        guard let driver, !Task.isCancelled else { return false }
        // Empty replies do not interrupt a valid utterance already playing.
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
        guard text.utf8.count <= limits.textBytes else {
            fail("That reply is too long to read in one turn. The complete instructions remain on screen.")
            return false
        }
        cancel()
        // DAT input and other system audio can change the route after start().
        // Re-establish and validate it before exposing or submitting this reply.
        do { try driver.prepareForUtterance() }
        catch {
            let message = (error as? LiveVoiceError)?.localizedDescription
                ?? "Spoken output could not use the selected audio route. Check the output and try again."
            fail(message)
            return false
        }
        let id = UUID(), current = generation
        requestID = id
        // Preserve the string exactly, including questions, numbers, units and
        // whitespace. Native speech normalizes pronunciation, not app content.
        let utterance = AVSpeechUtterance(string: text)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                completion = continuation
                deadline = Task { [weak self, limits] in
                    do { try await Task.sleep(for: limits.completionTimeout) } catch { return }
                    guard let self, self.generation == current, self.requestID == id else { return }
                    self.fail("Spoken output did not finish. Ask to repeat the instruction when ready.")
                }
                onTranscript?(text)
                guard generation == current, requestID == id else { return }
                driver.speak(utterance, id: id)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.generation == current, self.requestID == id else { return }
                self.cancel()
            }
        }
    }

    func cancel() {
        // Retire the request before stopping native playback: didCancel may be
        // synchronous, delayed, or absent for an utterance that never started.
        finish(false)
        driver?.cancel()
    }

    func stop() {
        generation = UUID()
        finish(false)
        let old = driver; driver = nil
        old?.onFinished = nil; old?.onCancelled = nil; old?.onFailure = nil
        old?.stop()
    }

    private func finish(_ succeeded: Bool) {
        requestID = nil
        deadline?.cancel(); deadline = nil
        let waiting = completion; completion = nil
        waiting?.resume(returning: succeeded)
    }

    private func fail(_ message: String) {
        guard driver != nil else { return }
        stop()
        onFailure?(message)
    }
}

/// The app owns the output-only session; native Meta Speech still owns input.
/// .playback supports A2DP without requesting the HFP microphone route. It does
/// not select a particular accessory; the user makes that choice in iOS.
/// https://developer.apple.com/documentation/avfaudio/avspeechsynthesizer/usesapplicationaudiosession
/// https://developer.apple.com/documentation/avfaudio/avaudiosession/categoryoptions-swift.struct/allowbluetootha2dp
@MainActor final class AppleSpeechDriver: NSObject, SystemSpeechDriver, AVSpeechSynthesizerDelegate {
    var onFinished: ((UUID) -> Void)?
    var onCancelled: ((UUID) -> Void)?
    var onFailure: ((String) -> Void)?
    private let synthesizer = AVSpeechSynthesizer()
    private var active: (id: UUID, utterance: AVSpeechUtterance)?
    private var prepared = false
    private var observerGeneration = UUID()
    private var observers: [NSObjectProtocol] = []

    override init() {
        super.init()
        synthesizer.usesApplicationAudioSession = true
        synthesizer.delegate = self
    }

    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }

    func prepare() throws {
        try GlassesAudioRoute.preparePlaybackSession()
        prepared = true
        try bindSelectedOutput()
        observeOutput()
    }

    func prepareForUtterance() throws {
        try GlassesAudioRoute.preparePlaybackSession()
        try bindSelectedOutput()
    }

    private func bindSelectedOutput() throws {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        guard GlassesAudioRoute.supportsSpeech(portTypes: outputs.map(\.portType)) else {
            throw LiveVoiceError.message(GlassesAudioRoute.selectionRequiredMessage)
        }
        // These channels come from the selected route, not guessed device IDs.
        // A few routes omit channel metadata; they still must pass the port gate.
        let channels = outputs.flatMap { $0.channels ?? [] }
        synthesizer.outputChannels = channels.isEmpty ? nil : channels
    }

    func speak(_ utterance: AVSpeechUtterance, id: UUID) {
        cancel()
        guard prepared else {
            onFailure?("Spoken output is not ready. Check the audio output and try again.")
            return
        }
        // Also fence the immediate native submission. Do not let a callback
        // between preparation and submission silently switch speech to iPhone.
        guard GlassesAudioRoute.supportsSpeech(portTypes: AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portType)) else {
            onFailure?(GlassesAudioRoute.selectionRequiredMessage)
            return
        }
        active = (id, utterance)
        synthesizer.speak(utterance)
    }

    func cancel() {
        active = nil
        synthesizer.stopSpeaking(at: .immediate)
    }

    func stop() {
        observerGeneration = UUID()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        cancel()
        if prepared {
            prepared = false
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    // Retain the callback's utterance until the main-actor check. An identifier
    // alone could be recycled if the old object deallocated before that check.
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self, utterance] in self?.receive(utterance, succeeded: true) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self, utterance] in self?.receive(utterance, succeeded: false) }
    }

    private func receive(_ utterance: AVSpeechUtterance, succeeded: Bool) {
        guard let active, active.utterance === utterance else { return }
        self.active = nil
        if succeeded { onFinished?(active.id) } else { onCancelled?(active.id) }
    }

    private func observeOutput() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        let current = UUID(); observerGeneration = current
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] notification in
            let kind = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard kind == AVAudioSession.InterruptionType.began.rawValue else { return }
            Task { @MainActor in
                self?.outputFailed("Audio playback was interrupted. Your microphone can still listen.", generation: current)
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.prepared, self.observerGeneration == current else { return }
                let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
                if !GlassesAudioRoute.supportsSpeech(portTypes: outputs.map(\.portType)) {
                    self.outputFailed(GlassesAudioRoute.selectionRequiredMessage, generation: current)
                }
            }
        })
    }

    private func outputFailed(_ message: String, generation: UUID) {
        guard prepared, observerGeneration == generation else { return }
        stop()
        onFailure?(message)
    }
}

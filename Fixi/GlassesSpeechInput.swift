import Foundation
import MWDATCore
import MWDATSpeech

/// A session-scoped recognizer that uses the glasses microphone without opening HFP.
@MainActor
final class GlassesSpeechInput: SceneVoiceSpeechInput {
    private struct InputError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private let session: DeviceSession
    private var speech: MWDATSpeech.Speech?
    private var tokens: [any AnyListenerToken] = []
    private var generation = UUID()
    private var started = false
    private var startRequested = false
    private var startupFailure: String?
    private var endedTask: Task<Void, Never>?
    var onRecognitionEnded: (() -> Void)?
    private var onText: ((String, Bool) -> Void)?
    private var onFailure: ((String) -> Void)?

    init(session: DeviceSession) {
        self.session = session
    }

    func start(onText: @escaping (String, Bool) -> Void,
               onFailure: @escaping (String) -> Void,
               onStatus: @escaping (String) -> Void,
               allowPermissionRequest: Bool = true) async throws {
        try Task.checkCancellation()
        stop()
        let id = UUID()
        generation = id
        do {
            guard session.state == .started else {
                throw InputError(message: "The glasses session is not ready for speech.")
            }
            onStatus("Checking the glasses microphone…")
            // The Objective-C bridge avoids the SDK's newer typed-throws async ABI.
            var permission = try await ObjC_Wearables.sharedInstance.checkPermissionStatus(.microphone)
            try checkRun(id)
            if permission != .granted {
                guard allowPermissionRequest else {
                    throw InputError(message: "Choose Glasses again to allow microphone access.")
                }
                onStatus("Allow the microphone in Meta AI, then return to Fixi.")
                permission = try await ObjC_Wearables.sharedInstance.requestPermission(.microphone)
                try checkRun(id)
            }
            guard permission == .granted else {
                throw InputError(message: "Glasses microphone access was not granted in Meta AI.")
            }
            // stop() is asynchronous on the glasses. Never overlap listening runs.
            try await waitUntilStopped()
            try checkRun(id)
            guard session.state == .started else {
                throw InputError(message: "The glasses session paused. Choose Glasses after it reconnects.")
            }
            if speech == nil {
                speech = try session.addSpeech()
            }
            guard let speech else {
                throw InputError(message: "The glasses session is not ready for speech.")
            }
            self.onText = onText
            self.onFailure = onFailure
            startupFailure = nil
            tokens = [
                speech.transcriptionPublisher.listen { [weak self] result in
                    Task { @MainActor in
                        guard let self, self.generation == id else { return }
                        // Confidence -1 means unavailable, not an invalid transcript.
                        self.onText?(result.text, result.isFinal)
                    }
                },
                speech.errorPublisher.listen { [weak self] error in
                    let message = error.localizedDescription
                    Task { @MainActor in
                        guard let self, self.generation == id else { return }
                        self.receiveFailure(message)
                    }
                },
                speech.statePublisher.listen { [weak self] state in
                    Task { @MainActor in
                        guard let self, self.generation == id, self.started,
                              state == .stopped, self.speech?.state == .stopped else { return }
                        self.scheduleCleanRunEnd(id: id)
                    }
                },
                speech.localePublisher.listen { _ in }
            ]
            onStatus("Starting the glasses microphone…")
            startRequested = true
            speech.start()
            let deadline = ContinuousClock.now.advanced(by: .seconds(8))
            while ContinuousClock.now < deadline {
                try checkRun(id)
                if let failure = startupFailure { throw InputError(message: failure) }
                guard session.state == .started else {
                    throw InputError(message: "The glasses session was interrupted.")
                }
                if speech.state == .started {
                    started = true
                    return
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw InputError(message: "The glasses microphone did not start in time.")
        } catch {
            // An older permission callback must not stop a newer listening run.
            if generation == id { stop() }
            throw error
        }
    }

    func stop() {
        generation = UUID()
        endedTask?.cancel(); endedTask = nil
        started = false
        startupFailure = nil
        onText = nil
        onFailure = nil
        let previousTokens = tokens
        tokens = []
        if !previousTokens.isEmpty {
            Task { for token in previousTokens { await token.cancel() } }
        }
        if let speech, startRequested || speech.state == .started || speech.state == .starting {
            speech.stop()
        }
        startRequested = false
    }

    /// Used before another listening run or speaker playback, with a bounded wait.
    func waitUntilStopped() async throws {
        guard let speech else { return }
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while speech.state != .stopped {
            try Task.checkCancellation()
            if session.state == .stopped { return }
            guard ContinuousClock.now < deadline else {
                throw InputError(message: "The glasses microphone is still stopping. Try again.")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        try Task.checkCancellation()
    }

    private func checkRun(_ id: UUID) throws {
        try Task.checkCancellation()
        guard generation == id else { throw CancellationError() }
    }

    private func scheduleCleanRunEnd(id: UUID) {
        guard endedTask == nil else { return }
        // Allow a final transcript or actual error queued alongside stopped to
        // arrive first. Device disconnection is never treated as a clean end.
        endedTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            guard let self, self.generation == id, self.started, self.speech?.state == .stopped else { return }
            guard self.session.state == .started else {
                self.receiveFailure("The glasses microphone session disconnected. Choose Glasses after reconnecting."); return
            }
            let callback = self.onRecognitionEnded
            let failure = self.onFailure
            self.stop()
            if let callback { callback() }
            else { failure?("Glasses speech stopped. Choose Glasses again.") }
        }
    }

    private func receiveFailure(_ message: String) {
        if !started {
            startupFailure = message
            return
        }
        let callback = onFailure
        stop()
        callback?(message)
    }
}

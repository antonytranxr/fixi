import Foundation
import Observation

/// Meta Speech supplies words without a Camera stream. Only the existing app
/// coordinator interprets questions/actions; the output service reads its replies.
@Observable @MainActor final class TranscriptVoiceSession: ConversationVoiceSession {
    private(set) var isActive = false
    private(set) var isConnecting = false
    private(set) var isMuted = false
    private(set) var requiresAddress = false
    let listeningMode: VoiceListeningMode
    private(set) var isListeningForTurn = false
    private(set) var isSpeaking = false
    private(set) var isReceivingSpeech = false
    private(set) var captureSuspended = false
    private(set) var status = "Conversation is off"
    private(set) var inputTranscript = ""
    private(set) var outputTranscript = ""
    private(set) var error: String?
    @ObservationIgnored var onDelegation: ((String, String) -> Void)?
    @ObservationIgnored var onFailure: ((String) -> Void)?
    @ObservationIgnored var onNotice: ((String) -> Void)?
    @ObservationIgnored var onStateChange: (() -> Void)?
    @ObservationIgnored var onUserSpeechStarted: (() -> Void)?
    @ObservationIgnored var onWillSpeak: (() async throws -> Void)?
    @ObservationIgnored var onDidFinishSpeaking: (() -> Void)?
    @ObservationIgnored private let makeSpeechInput: @MainActor () async throws -> any SceneVoiceSpeechInput
    @ObservationIgnored private let output: any ConversationSpeechOutput
    @ObservationIgnored private let pauseDelay: Duration
    @ObservationIgnored private let turnTimeout: Duration
    @ObservationIgnored private var turnGeneration = UUID()
    @ObservationIgnored private var turnDeadline: Task<Void, Never>?
    @ObservationIgnored private var input: (any SceneVoiceSpeechInput)?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var listeningGeneration = UUID()
    @ObservationIgnored private var speechGeneration = UUID()
    @ObservationIgnored private var preparedSpeechID: UUID?
    @ObservationIgnored private var utteranceID = UUID()
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var restart: Task<Void, Never>?
    @ObservationIgnored private var renewal: Task<Void, Never>?
    @ObservationIgnored private var lifecycle: SpeechRunLifecycle
    @ObservationIgnored private var recognitionRestarting = false
    @ObservationIgnored private var outputReady = false
    @ObservationIgnored private var outputKey = ""
    @ObservationIgnored private var outputGeneration = UUID()
    @ObservationIgnored private var narration: Task<Void, Never>?
    @ObservationIgnored private var outputEnabled = true
    @ObservationIgnored private var pendingReply: String?
    @ObservationIgnored private var speakingText: String?
    @ObservationIgnored private var recentNarration = ""
    @ObservationIgnored private var narrationEnded = Date.distantPast
    @ObservationIgnored private var gate = NarrationInterruptionGate(narration: "")
    @ObservationIgnored private var utteranceRequiresFinal = false
    @ObservationIgnored private var credentialUtterance = false
    @ObservationIgnored private var awaitingCredentialFinal = false
    @ObservationIgnored private var pendingQuestion = ""
    @ObservationIgnored private var lastFinal = ""
    @ObservationIgnored private var lastFinalAt = Date.distantPast
    @ObservationIgnored private var currentDelegation: String?
    @ObservationIgnored private var awaitingDelegatedReply = false
    @ObservationIgnored private var context = ""
    @ObservationIgnored private var history: [String] = []

    init(makeSpeechInput: @escaping @MainActor () async throws -> any SceneVoiceSpeechInput,
         output: (any ConversationSpeechOutput)? = nil, pauseDelay: Duration = .milliseconds(1500),
         lifecycle: SpeechRunLifecycle = SpeechRunLifecycle(),
         listeningMode: VoiceListeningMode = .continuous, turnTimeout: Duration = .seconds(20)) {
        self.makeSpeechInput = makeSpeechInput
        self.output = output ?? RealtimeSpeechOutput()
        self.pauseDelay = pauseDelay
        self.lifecycle = lifecycle
        self.listeningMode = listeningMode
        self.turnTimeout = turnTimeout
    }

    var conversationContext: String { ([context] + history).joined(separator: "\n") }

    func start(apiKey: String, context: String) async throws {
        guard !isActive, !isConnecting else { throw LiveVoiceError.message("A conversation is already open.") }
        let id = UUID(); generation = id
        isConnecting = true; isMuted = false; captureSuspended = false; error = nil
        outputKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        outputReady = false; outputGeneration = UUID(); bindOutputCallbacks()
        lifecycle.reset(); recognitionRestarting = false
        inputTranscript = ""; outputTranscript = ""; history = []; currentDelegation = nil; awaitingDelegatedReply = false
        awaitingCredentialFinal = false
        lastFinal = ""; lastFinalAt = .distantPast; recentNarration = ""; narrationEnded = .distantPast
        sendContext(context); resetUtterance()
        status = "Connecting glasses speech…"; onStateChange?()
        do {
            let speech = try await makeSpeechInput()
            guard generation == id, !Task.isCancelled else { throw CancellationError() }
            input = speech
            let outputID = outputGeneration
            do {
                try await output.start(apiKey: outputKey)
                if outputGeneration == outputID { outputReady = true }
            }
            catch {
                guard generation == id, !Task.isCancelled else { throw CancellationError() }
                if outputGeneration == outputID { outputFailed(error.localizedDescription) }
            }
            guard generation == id, !Task.isCancelled else { throw CancellationError() }
            if listeningMode == .continuous {
                try await startRecognition(session: id, allowPermissionRequest: true)
            }
            guard generation == id, !Task.isCancelled else { throw CancellationError() }
            isConnecting = false; isActive = true; updateStatus(); onStateChange?()
        } catch {
            if generation == id {
                stopImmediately(); self.error = error is CancellationError ? nil : error.localizedDescription
            }
            throw error
        }
    }

    func stop() async {
        let old = input
        stopImmediately()
        try? await old?.waitUntilStopped()
    }

    private func stopImmediately() {
        generation = UUID(); listeningGeneration = UUID()
        turnGeneration = UUID(); isListeningForTurn = false
        turnDeadline?.cancel(); turnDeadline = nil
        renewal?.cancel(); renewal = nil; recognitionRestarting = false
        restart?.cancel(); restart = nil; debounce?.cancel(); debounce = nil
        cancelNarration(); output.stop(); outputReady = false; outputKey = ""
        input?.onRecognitionEnded = nil; input?.stop(); input = nil
        pendingReply = nil; currentDelegation = nil; awaitingDelegatedReply = false; captureSuspended = false
        awaitingCredentialFinal = false
        isActive = false; isConnecting = false; isMuted = false
        resetUtterance(); status = "Conversation is off"; onStateChange?()
    }

    func mute() {
        guard isActive, !isMuted else { return }
        if listeningMode == .oneTurn { closeOneTurn(notify: false) }
        isMuted = true; listeningGeneration = UUID()
        renewal?.cancel(); renewal = nil; recognitionRestarting = false
        awaitingCredentialFinal = false
        restart?.cancel(); restart = nil; input?.stop(); resetUtterance()
        updateStatus(); onStateChange?()
    }

    func unmute() {
        guard isActive, isMuted else { return }
        if listeningMode == .oneTurn {
            isMuted = false; updateStatus(); onStateChange?(); return
        }
        isMuted = false; recognitionRestarting = true; let id = generation
        updateStatus(); onStateChange?()
        restart?.cancel()
        restart = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.input?.waitUntilStopped()
                guard self.generation == id, !self.isMuted, !Task.isCancelled else { return }
                try await self.startRecognition(session: id, allowPermissionRequest: false)
                guard self.generation == id, !self.isMuted, !Task.isCancelled else { return }
                self.recognitionRestarting = false; self.restart = nil; self.updateStatus(); self.onStateChange?()
            } catch {
                guard self.generation == id, !self.isMuted, !(error is CancellationError) else { return }
                self.fail("The glasses microphone could not resume. Start the conversation again.")
            }
        }
    }

    /// A physical Talk selection permits exactly one final native segment.
    /// This limits when speech is accepted; it does not identify the speaker.
    func listenForOneTurn() {
        guard listeningMode == .oneTurn, isActive else { return }
        closeOneTurn(notify: false)
        let id = generation, turn = UUID(); turnGeneration = turn
        isMuted = false; isListeningForTurn = true; recognitionRestarting = true
        pendingReply = nil; currentDelegation = nil; awaitingDelegatedReply = false; inputTranscript = ""
        lastFinal = ""; lastFinalAt = .distantPast
        cancelNarration(); resetUtterance()
        updateStatus(); onStateChange?()
        restart = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.input?.waitUntilStopped()
                guard self.generation == id, self.turnGeneration == turn,
                      self.isListeningForTurn, !self.isMuted, !Task.isCancelled else { return }
                // The controller owns Meta AI permission handoff when the
                // conversation opens. A Talk selection must not start another.
                try await self.startRecognition(session: id, allowPermissionRequest: false)
                guard self.generation == id, self.turnGeneration == turn,
                      self.isListeningForTurn, !self.isMuted, !Task.isCancelled else { return }
                self.restart = nil; self.recognitionRestarting = false
                self.scheduleTurnDeadline(session: id, turn: turn)
                self.updateStatus(); self.onStateChange?()
            } catch {
                guard self.generation == id, self.turnGeneration == turn,
                      self.isListeningForTurn, !(error is CancellationError) else { return }
                self.closeOneTurn()
                self.onNotice?("The glasses microphone could not start. Tap Talk to try again.")
            }
        }
    }

    private func scheduleTurnDeadline(session id: UUID, turn: UUID) {
        turnDeadline?.cancel()
        turnDeadline = Task { [weak self, turnTimeout] in
            do { try await Task.sleep(for: turnTimeout) } catch { return }
            guard let self, self.generation == id, self.turnGeneration == turn,
                  self.isListeningForTurn, !Task.isCancelled else { return }
            // Never turn an unfinished fragment into a command when time runs out.
            let hadPartial = self.isReceivingSpeech
            self.closeOneTurn()
            if hadPartial { self.onNotice?("Listening timed out. Tap Talk to try again.") }
        }
    }

    private func closeOneTurn(notify: Bool = true, discardTranscript: Bool = true) {
        guard listeningMode == .oneTurn else { return }
        let wasListening = isListeningForTurn
        isListeningForTurn = false; turnGeneration = UUID(); listeningGeneration = UUID()
        turnDeadline?.cancel(); turnDeadline = nil
        restart?.cancel(); restart = nil; renewal?.cancel(); renewal = nil
        recognitionRestarting = false; awaitingCredentialFinal = false
        input?.onRecognitionEnded = nil
        if wasListening { input?.stop() }
        resetUtterance()
        if discardTranscript { inputTranscript = "" }
        updateStatus()
        if notify { onStateChange?() }
    }

    private func startRecognition(session id: UUID, allowPermissionRequest: Bool) async throws {
        guard let input else { throw LiveVoiceError.message("The glasses speech service is unavailable.") }
        let run = UUID(); listeningGeneration = run
        input.onRecognitionEnded = { [weak self] in
            guard let self, self.generation == id, self.listeningGeneration == run, self.isActive, !self.isMuted else { return }
            if self.listeningMode == .oneTurn { self.closeOneTurn(); return }
            guard self.lifecycle.allowUnexpectedRestart() else {
                self.fail("The glasses microphone stopped repeatedly. Choose Glasses to reconnect."); return
            }
            self.restartRecognition(session: id)
        }
        try await input.start(onText: { [weak self] text, final in
            guard let self, self.generation == id, self.listeningGeneration == run,
                  self.isActive, !self.isMuted,
                  self.listeningMode == .continuous || self.isListeningForTurn else { return }
            self.receive(text, final: final)
        }, onFailure: { [weak self] message in
            guard let self, self.generation == id, self.listeningGeneration == run else { return }
            self.fail(message)
        }, onStatus: { [weak self] text in
            guard let self, self.generation == id, self.isConnecting else { return }
            self.status = text
        }, allowPermissionRequest: allowPermissionRequest)
        guard generation == id, listeningGeneration == run, !isMuted, !Task.isCancelled else { throw CancellationError() }
        if listeningMode == .continuous { scheduleRenewal(session: id, run: run) }
    }

    private func scheduleRenewal(session id: UUID, run: UUID) {
        renewal?.cancel()
        renewal = Task { [weak self, lifecycle] in
            do { try await Task.sleep(for: lifecycle.renewalInterval) } catch { return }
            guard let self else { return }
            let deadline = ContinuousClock.now.advanced(by: lifecycle.utteranceGrace)
            while self.isReceivingSpeech, ContinuousClock.now < deadline {
                do { try await Task.sleep(for: lifecycle.pollingInterval) } catch { return }
            }
            guard self.generation == id, self.listeningGeneration == run, self.isActive, !self.isMuted, !Task.isCancelled else { return }
            if self.isReceivingSpeech { self.onNotice?("The microphone needs a brief refresh. Please repeat your last sentence.") }
            self.renewal = nil
            self.restartRecognition(session: id)
        }
    }

    private func restartRecognition(session id: UUID) {
        guard listeningMode == .continuous, generation == id, isActive, !isMuted, restart == nil else { return }
        listeningGeneration = UUID(); renewal?.cancel(); renewal = nil
        awaitingCredentialFinal = false
        resetUtterance(); recognitionRestarting = true; input?.stop()
        updateStatus(); onStateChange?()
        restart = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.input?.waitUntilStopped()
                guard self.generation == id, self.isActive, !self.isMuted, !Task.isCancelled else { return }
                try await self.startRecognition(session: id, allowPermissionRequest: false)
                guard self.generation == id, self.isActive, !self.isMuted, !Task.isCancelled else { return }
                self.restart = nil; self.recognitionRestarting = false; self.updateStatus(); self.onStateChange?()
            } catch {
                guard self.generation == id, !self.isMuted, !(error is CancellationError) else { return }
                self.fail("The glasses microphone could not refresh. Choose Glasses to reconnect.")
            }
        }
    }

    private func receive(_ text: String, final: Bool) {
        guard text.utf8.count <= 12_000 else { fail("That spoken question was too long. Start again with a shorter question."); return }
        let addressed = MendSpeechAddress.content(in: text)
        if requiresAddress, addressed == nil {
            if final { awaitingCredentialFinal = false }
            resetUtterance(); return
        }
        let text = addressed ?? text
        // Redact before either display or history. Recognition revisions must not
        // reveal a token after an earlier partial identified a credential turn.
        if awaitingCredentialFinal || Self.containsCredentialDisclosure(text) { credentialUtterance = true }
        if final { awaitingCredentialFinal = false }
        let safeText = credentialUtterance ? Self.credentialSentinel : text
        // The echo fence expires even if no new utterance arrived after playback.
        // Otherwise a later command matching an old reply can be suppressed forever.
        if !isSpeaking, !isReceivingSpeech, !recentNarration.isEmpty,
           Date().timeIntervalSince(narrationEnded) >= 2 {
            recentNarration = ""; gate = NarrationInterruptionGate(narration: "")
        }
        guard let question = gate.question(from: safeText, final: final), !question.isEmpty else {
            if final { resetUtterance() }
            return
        }
        let normalized = Self.normalized(question)
        guard !normalized.isEmpty else {
            if final { resetUtterance() }
            return
        }
        // Native Speech can repeat a final or deliver it after our pause fallback.
        if !isReceivingSpeech, normalized == lastFinal, Date().timeIntervalSince(lastFinalAt) < 2 {
            if final { resetUtterance() }; return
        }
        if !isReceivingSpeech {
            isReceivingSpeech = true
            // Capture the view at the beginning of the utterance without letting
            // a room fragment cancel the answer already in progress.
            onUserSpeechStarted?(); onStateChange?()
        }
        if isSpeaking || awaitingDelegatedReply || pendingReply != nil { utteranceRequiresFinal = true }
        pendingQuestion = question
        inputTranscript = credentialUtterance ? "Sensitive credential omitted. Enter keys privately in Settings." : question
        debounce?.cancel(); debounce = nil
        if final { finalize(question); return }
        guard canSubmitPausedUtterance else { return }
        let id = generation, utterance = utteranceID
        debounce = Task { [weak self, pauseDelay] in
            do { try await Task.sleep(for: pauseDelay) } catch { return }
            guard let self, self.generation == id, self.utteranceID == utterance,
                  self.isActive, !self.isMuted, self.canSubmitPausedUtterance else { return }
            // A late final can omit the prefix that identified the secret.
            // Keep that unfinished native segment redacted after our pause timer.
            if self.credentialUtterance { self.awaitingCredentialFinal = true }
            self.finalize(self.pendingQuestion)
        }
    }

    /// Partial transcripts can be ambient speech. Only a native final may
    /// interrupt an answer; an idle pause fallback still keeps conversation fluid.
    private var canSubmitPausedUtterance: Bool {
        listeningMode == .continuous && !utteranceRequiresFinal && !isSpeaking && !awaitingDelegatedReply && pendingReply == nil
    }

    private func finalize(_ question: String) {
        if listeningMode == .oneTurn {
            guard isListeningForTurn else { return }
            // Close before delegation: a synchronous reply must not be canceled
            // by cleanup, and a queued second final cannot choose another action.
            closeOneTurn(notify: false, discardTranscript: false)
        }
        // Acceptance, rather than the first partial, retires the previous turn.
        // Do this before delegation so a synchronous new reply survives cleanup.
        pendingReply = nil; currentDelegation = nil; awaitingDelegatedReply = false
        cancelNarration()
        lastFinal = Self.normalized(question); lastFinalAt = Date()
        let id = "speech_" + UUID().uuidString; currentDelegation = id; awaitingDelegatedReply = true
        if question != Self.credentialSentinel { appendHistory("User: " + question) }
        resetUtterance(); status = captureSuspended ? "Listening · voice reply waits for camera" : "Thinking…"
        onDelegation?(id, question)
        if listeningMode == .oneTurn { onStateChange?() }
    }

    private func resetUtterance() {
        let wasReceiving = isReceivingSpeech
        debounce?.cancel(); debounce = nil; utteranceID = UUID(); isReceivingSpeech = false
        utteranceRequiresFinal = false; credentialUtterance = false; pendingQuestion = ""
        let echoText = isSpeaking || Date().timeIntervalSince(narrationEnded) < 2 ? recentNarration : ""
        gate = NarrationInterruptionGate(narration: echoText)
        if wasReceiving { onStateChange?() }
    }

    func setOutputEnabled(_ enabled: Bool) {
        outputEnabled = enabled
        if !enabled { pendingReply = nil; cancelNarration() }
    }

    /// A saved-key change affects only the output connection. Native input,
    /// accepted delegations, mute state, and the current repair remain intact.
    func setOutputAPIKey(_ key: String) {
        let clean = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean != outputKey else { return }
        outputKey = clean; outputGeneration = UUID()
        cancelNarration(); output.stop(); outputReady = false
        bindOutputCallbacks()
        guard isActive || isConnecting else { return }
        if clean.isEmpty {
            error = "Spoken output is unavailable. Voice controls can still listen. Add an OpenAI API key in Settings for spoken replies."
            onNotice?(error!)
        } else {
            error = nil
            onNotice?("OpenAI voice key updated. The next spoken reply will reconnect.")
        }
        updateStatus(); onStateChange?()
    }

    private func bindOutputCallbacks() {
        let session = generation, outputID = outputGeneration
        output.onFailure = { [weak self] message in
            guard let self, self.generation == session, self.outputGeneration == outputID else { return }
            self.outputFailed(message)
        }
        output.onTranscript = { [weak self] text in
            guard let self, self.generation == session, self.outputGeneration == outputID,
                  self.isActive, self.isSpeaking else { return }
            self.outputTranscript = text
        }
    }

    func setRequiresAddress(_ enabled: Bool) {
        guard requiresAddress != enabled else { return }
        requiresAddress = enabled
        awaitingCredentialFinal = false
        resetUtterance(); lastFinal = ""; lastFinalAt = .distantPast
        updateStatus(); onStateChange?()
    }

    func interruptPlayback() { pendingReply = nil; cancelNarration() }
    func sendContext(_ text: String) { context = String(text.prefix(12_000)) }

    /// Switching repairs clears conversational evidence without restarting the
    /// native microphone. Old delegated answers can no longer be narrated.
    func resetConversation() {
        if listeningMode == .oneTurn { closeOneTurn(notify: false) }
        pendingReply = nil; currentDelegation = nil; awaitingDelegatedReply = false; cancelNarration()
        awaitingCredentialFinal = false; recentNarration = ""; narrationEnded = .distantPast
        history = []; inputTranscript = ""; outputTranscript = ""
        lastFinal = ""; lastFinalAt = .distantPast
        resetUtterance(); updateStatus(); onStateChange?()
    }

    func sayResult(_ text: String, delegationID: String? = nil) {
        guard isActive, delegationID == nil || delegationID == currentDelegation else { return }
        awaitingDelegatedReply = false
        outputTranscript = text; appendHistory("Assistant: " + text)
        guard outputEnabled else { return }
        if captureSuspended { pendingReply = text; return }
        narration?.cancel()
        narration = Task { [weak self] in _ = await self?.performSpeech(text) }
    }

    func speakAndWait(_ text: String) async -> Bool {
        // A finite camera cue supersedes any reply queued by resume or sayResult.
        // Queued narration calls performSpeech directly so it cannot cancel itself.
        narration?.cancel(); narration = nil
        return await performSpeech(text)
    }

    private func performSpeech(_ text: String) async -> Bool {
        guard isActive, !captureSuspended, !Task.isCancelled else { return false }
        guard outputEnabled else { return true }
        // Even an unsolicited camera cue or late app reply must close the Talk
        // window before narration, so speaker playback cannot become a command.
        if listeningMode == .oneTurn, isListeningForTurn { closeOneTurn() }
        cancelNarration(cancelTask: false)
        let id = generation, outputID = outputGeneration, speechID = UUID(); speechGeneration = speechID
        preparedSpeechID = speechID
        defer { finishSpeechPreparation(speechID) }
        // A partial timer may already exist when the answer becomes ready.
        // Retain its utterance/context, but never let its pause stop this reply.
        debounce?.cancel(); debounce = nil
        if isReceivingSpeech { utteranceRequiresFinal = true }
        speakingText = text; recentNarration = text; gate = NarrationInterruptionGate(narration: text)
        isSpeaking = true; outputTranscript = text; updateStatus(); onStateChange?()
        do {
            try Task.checkCancellation()
            guard generation == id, outputGeneration == outputID, speechGeneration == speechID else { return false }
            if listeningMode == .oneTurn {
                // Speech.stop() is asynchronous on the glasses. Wait for its
                // bounded stop before preparing or playing any spoken output.
                try await input?.waitUntilStopped()
                try Task.checkCancellation()
                guard generation == id, outputGeneration == outputID, speechGeneration == speechID else { return false }
            }
            try await onWillSpeak?()
            try Task.checkCancellation()
            guard generation == id, outputGeneration == outputID, speechGeneration == speechID else { return false }
        } catch {
            guard generation == id, outputGeneration == outputID, speechGeneration == speechID, !Task.isCancelled else { return false }
            if !(error is CancellationError) { outputFailed(error.localizedDescription) }
            return false
        }
        if !outputReady {
            do {
                try await output.start(apiKey: outputKey)
                guard generation == id, outputGeneration == outputID, speechGeneration == speechID, !Task.isCancelled else { return false }
                outputReady = true; error = nil; onNotice?("Spoken replies are available again.")
            } catch {
                guard generation == id, outputGeneration == outputID, speechGeneration == speechID, !Task.isCancelled else { return false }
                outputFailed(error.localizedDescription); return false
            }
        }
        let completed = await output.speak(text)
        guard generation == id, outputGeneration == outputID, speechGeneration == speechID else { return false }
        if !completed, !Task.isCancelled { outputFailed("The spoken reply did not finish. You can still use voice controls and read the screen.") }
        return completed && !Task.isCancelled
    }

    func setCaptureSuspended(_ suspended: Bool) {
        guard captureSuspended != suspended else { return }
        captureSuspended = suspended
        if suspended {
            let waiting = pendingReply ?? speakingText
            cancelNarration(); pendingReply = outputEnabled ? waiting : nil
        } else if let text = pendingReply {
            pendingReply = nil
            if outputEnabled, isActive {
                narration = Task { [weak self] in _ = await self?.performSpeech(text) }
            }
        }
        // Native Speech remains available for stop/cancel during recording.
        // Its own stopped/error callback ends the conversation if the SDK refuses.
        updateStatus(); onStateChange?()
    }

    private func cancelNarration(cancelTask: Bool = true) {
        let preparedID = preparedSpeechID
        speechGeneration = UUID()
        if cancelTask { narration?.cancel(); narration = nil }
        output.cancel()
        // Superseding speech while a reconnect is pending must retire that
        // startup too; otherwise the next reply sees an already-open socket.
        if !outputReady { output.stop() }
        if let preparedID { finishSpeechPreparation(preparedID) }
        else { updateStatus() }
    }

    /// Cancellation releases its preparation immediately. Its suspended task may
    /// finish later, but cannot release a newer camera/audio preparation.
    private func finishSpeechPreparation(_ id: UUID) {
        guard preparedSpeechID == id else { return }
        preparedSpeechID = nil
        let wasSpeaking = isSpeaking
        if wasSpeaking { narrationEnded = Date() }
        isSpeaking = false; speakingText = nil
        updateStatus()
        if wasSpeaking { onStateChange?() }
        onDidFinishSpeaking?()
    }

    private func updateStatus() {
        if !isActive { return }
        if isMuted { status = "Microphone muted" }
        else if listeningMode == .oneTurn {
            if recognitionRestarting { status = "Opening microphone…" }
            else if isListeningForTurn { status = "Listening…" }
            else if isSpeaking { status = "Speaking · tap Talk to interrupt" }
            else { status = "Tap Talk to speak" }
        }
        else if recognitionRestarting { status = "Refreshing glasses microphone…" }
        else if captureSuspended { status = "Listening · voice reply waits for camera" }
        else if isSpeaking { status = requiresAddress ? "Speaking · say Hey Fixi to interrupt" : "Speaking · you can interrupt" }
        else if !outputReady { status = "Listening · spoken output unavailable" }
        else { status = requiresAddress ? "Listening for Hey Fixi" : "Listening through your glasses" }
    }

    private func appendHistory(_ text: String) {
        history.append(String(text.prefix(6000)))
        while history.count > 12 || history.joined().utf8.count > 24_000 { history.removeFirst() }
    }
    private static func normalized(_ text: String) -> String {
        text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }
    private static let credentialSentinel = "api key is [redacted]"
    private static func containsCredentialDisclosure(_ text: String) -> Bool {
        text.lowercased().contains("sk-") || normalized(text).contains("api key is")
    }
    private func fail(_ message: String) {
        guard isActive || isConnecting else { return }
        stopImmediately(); error = message; status = "Conversation stopped"
        onFailure?(message); onStateChange?()
    }

    private func outputFailed(_ message: String) {
        guard isActive || isConnecting else { return }
        let notice = "Spoken output is unavailable. Voice controls can still listen. " + String(message.prefix(400))
        let changed = error != notice
        outputReady = false; pendingReply = nil; cancelNarration(); output.stop()
        error = notice; updateStatus()
        if changed { onNotice?(notice) }
        onStateChange?()
    }
}

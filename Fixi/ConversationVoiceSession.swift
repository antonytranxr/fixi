import AVFoundation
import Foundation

enum VoiceListeningMode {
    case continuous
    case oneTurn
}

/// Conversation coordination is independent of its microphone transport.
@MainActor protocol ConversationVoiceSession: AnyObject {
    var isActive: Bool { get }
    var isConnecting: Bool { get }
    var isMuted: Bool { get }
    var requiresAddress: Bool { get }
    var listeningMode: VoiceListeningMode { get }
    var isListeningForTurn: Bool { get }
    var isSpeaking: Bool { get }
    var isReceivingSpeech: Bool { get }
    var captureSuspended: Bool { get }
    var status: String { get }
    var inputTranscript: String { get }
    var outputTranscript: String { get }
    var error: String? { get }
    var conversationContext: String { get }
    var onDelegation: ((String, String) -> Void)? { get set }
    var onFailure: ((String) -> Void)? { get set }
    var onNotice: ((String) -> Void)? { get set }
    var onStateChange: (() -> Void)? { get set }
    var onUserSpeechStarted: (() -> Void)? { get set }
    var onWillSpeak: (() async throws -> Void)? { get set }
    var onDidFinishSpeaking: (() -> Void)? { get set }
    func start(apiKey: String, context: String) async throws
    func stop() async
    func appendAudio(_ buffer: AVAudioPCMBuffer)
    func mute()
    func unmute()
    func setRequiresAddress(_ enabled: Bool)
    func listenForOneTurn()
    func setOutputEnabled(_ enabled: Bool)
    func setOutputAPIKey(_ key: String)
    func interruptPlayback()
    func sendContext(_ text: String)
    func sayResult(_ text: String, delegationID: String?)
    func speakAndWait(_ text: String) async -> Bool
    func setCaptureSuspended(_ suspended: Bool)
    func resetConversation()
}

extension ConversationVoiceSession {
    var captureSuspended: Bool { false }
    var requiresAddress: Bool { false }
    var listeningMode: VoiceListeningMode { .continuous }
    var isListeningForTurn: Bool { false }
    var isReceivingSpeech: Bool { false }
    var onNotice: ((String) -> Void)? { get { nil } set {} }
    var onUserSpeechStarted: (() -> Void)? { get { nil } set {} }
    var onWillSpeak: (() async throws -> Void)? { get { nil } set {} }
    var onDidFinishSpeaking: (() -> Void)? { get { nil } set {} }
    func appendAudio(_ buffer: AVAudioPCMBuffer) {}
    func sayResult(_ text: String) { sayResult(text, delegationID: nil) }
    func speakAndWait(_ text: String) async -> Bool { sayResult(text); return true }
    func setCaptureSuspended(_ suspended: Bool) {}
    func resetConversation() {}
    func setRequiresAddress(_ enabled: Bool) {}
    func listenForOneTurn() {}
    func setOutputAPIKey(_ key: String) {}
}

@MainActor protocol ConversationSpeechOutput: AnyObject {
    var onFailure: ((String) -> Void)? { get set }
    var onTranscript: ((String) -> Void)? { get set }
    func start(apiKey: String) async throws
    /// True means local speech playback completed, not just queued audio.
    func speak(_ text: String) async -> Bool
    func cancel()
    func stop()
}

import Foundation

enum LiveVoiceError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}

/// Shared JSON framing and transport only. Conversation input uses native Meta
/// speech; production spoken replies use isolated text-to-audio Realtime requests.
enum LiveVoiceProtocol {
    static func encode(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }
    static func eventID() -> String { "mendsight_" + UUID().uuidString }
}

@MainActor protocol LiveVoiceTransport: AnyObject {
    func send(_ text: String) async throws
    func receive() async throws -> String
    func close()
}

@MainActor final class LiveVoiceWebSocket: LiveVoiceTransport {
    private let session: URLSession
    private let socket: URLSessionWebSocketTask

    init(request: URLRequest) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        // Quiet users do not time out. The server owns session expiration.
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        session = URLSession(configuration: configuration)
        socket = session.webSocketTask(with: request)
        socket.maximumMessageSize = 1_000_000
        socket.resume()
    }

    func send(_ text: String) async throws {
        do { try await socket.send(.string(text)) }
        catch { throw connectionError(error) }
    }
    func receive() async throws -> String {
        do {
            switch try await socket.receive() {
            case .string(let text): return text
            case .data(let data):
                guard let text = String(data: data, encoding: .utf8) else { throw LiveVoiceError.message("Realtime voice returned an invalid event.") }
                return text
            @unknown default: throw LiveVoiceError.message("Realtime voice returned an unsupported message.")
            }
        } catch { throw connectionError(error) }
    }
    private func connectionError(_ error: Error) -> Error {
        if let response = socket.response as? HTTPURLResponse,
           let explanation = Self.failure(forHTTPStatus: response.statusCode) { return explanation }
        return error
    }
    static func failure(forHTTPStatus status: Int) -> LiveVoiceError? {
        switch status {
        case 401: return .message("OpenAI rejected this API key. Check your key in Settings.")
        case 403: return .message("OpenAI denied Realtime voice access. Check your project's permissions and Realtime voice model access.")
        case 404: return .message("OpenAI's Realtime endpoint was not available. Check Realtime voice access for this account.")
        case 429: return .message("OpenAI limited this request. Check API quota and billing, or retry after the rate limit clears.")
        case 400..<500: return .message("OpenAI rejected the Realtime connection request. Check your API project's access.")
        case 500..<600: return .message("OpenAI voice is temporarily unavailable. Please try again shortly.")
        default: return nil
        }
    }
    func close() { socket.cancel(with: .normalClosure, reason: nil); session.invalidateAndCancel() }
}

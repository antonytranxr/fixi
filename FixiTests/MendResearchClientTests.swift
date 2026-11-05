import XCTest
@testable import Fixi

final class MendResearchClientTests: XCTestCase {
    private let details = MendProjectDetails(make: "Bosch", model: "Example model", problem: "The latch will not close.")
    private let step = MendStep(id: "latch", title: "Inspect latch", instruction: "Look at the visible latch without forcing it.",
        expectedResult: "The latch is aligned.", caution: "Stop if the cover is bent.", marker: nil)
    private var diagnosis: MendDiagnosis {
        MendDiagnosis(photoID: "photo-001", status: .ready, title: "Raised latch", summary: "The latch appears raised.",
            evidence: ["The latch is raised."], confidence: .medium, questions: [], tools: [], precautions: [], steps: [step])
    }
    private func annotation(_ raw: String, marker: String = "CITED", url: String = "https://www.bosch-home.com/support/manuals", title: String = "Manufacturer manual") -> [String: Any] {
        let range = raw.range(of: marker)!
        return ["type": "url_citation", "start_index": raw[..<range.lowerBound].unicodeScalars.count,
                "end_index": raw[..<range.upperBound].unicodeScalars.count, "url": url, "title": title]
    }
    private func envelope(_ raw: String = "Inspect the latch. CITED", annotations: [[String: Any]]? = nil,
                          status: String = "completed", searchStatus: String? = "completed", extra: [[String: Any]] = []) throws -> Data {
        var output: [[String: Any]] = []
        if let searchStatus { output.append(["type": "web_search_call", "status": searchStatus, "action": ["type": "search"]]) }
        output.append(["type": "message", "role": "assistant", "status": "completed", "content": [
            ["type": "output_text", "text": raw, "annotations": annotations ?? [annotation(raw)]]]])
        output += extra
        return try JSONSerialization.data(withJSONObject: ["status": status, "output": output])
    }

    func testRequestRequiresRealWebSearchAndKeepsAcceptedStepAsContextOnly() throws {
        let body = try MendResearchClient.requestBody(question: "What does aligned mean?", details: details, diagnosis: diagnosis, step: step)
        XCTAssertEqual(body["model"] as? String, "gpt-4.1")
        XCTAssertEqual(body["tool_choice"] as? String, "required")
        XCTAssertEqual(body["store"] as? Bool, false)
        let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools.first?["type"] as? String, "web_search")
        XCTAssertEqual(tools.first?["external_web_access"] as? Bool, true)
        XCTAssertNil(body["previous_response_id"])
        let input = try XCTUnwrap((body["input"] as? [[String: Any]])?.first)
        let content = try XCTUnwrap(input["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 1)
        XCTAssertEqual(content.first?["type"] as? String, "input_text")
        let json = try XCTUnwrap(content.first?["text"] as? String)
        let context = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual((context["project"] as? [String: String])?["model"], details.model)
        XCTAssertEqual((context["current_step"] as? [String: String])?["caution"], step.caution)
        XCTAssertNil((context["current_step"] as? [String: Any])?["marker"])
    }

    func testUnknownDetailsArePreservedAndStaleStepsAreRejected() throws {
        let body = try MendResearchClient.requestBody(question: "Where is the product label?", details: .init(make: "Unknown", model: "Unknown", problem: "Loose cover"), diagnosis: nil, step: nil)
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)
        XCTAssertTrue(encoded.contains("Unknown"))
        XCTAssertThrowsError(try MendResearchClient.requestBody(question: "Explain", details: details, diagnosis: nil, step: step))
        let changed = MendStep(id: step.id, title: step.title, instruction: "Force it closed", expectedResult: step.expectedResult, caution: step.caution, marker: nil)
        XCTAssertThrowsError(try MendResearchClient.requestBody(question: "Explain", details: details, diagnosis: diagnosis, step: changed))
    }

    func testCompletedSearchReturnsClickableCitationsAndCleanSpokenAnswer() throws {
        let answer = try MendResearchClient.decodeResponse(envelope())
        XCTAssertEqual(answer.sources.count, 1)
        XCTAssertEqual(answer.sources.first?.title, "Manufacturer manual")
        XCTAssertEqual(answer.sources.first?.id, "https://www.bosch-home.com/support/manuals")
        XCTAssertTrue(answer.text.contains("[Source 1](<https://www.bosch-home.com/support/manuals>)"))
        XCTAssertEqual(answer.spokenText, "Inspect the latch.")
        XCTAssertFalse(answer.text.contains("CITED"))
    }

    func testUnicodeOffsetsAndDuplicateCitationsKeepOneSource() throws {
        let raw = "💡 Inspect the latch. CITED Then check the label. AGAIN"
        let items = [annotation(raw), annotation(raw, marker: "AGAIN")]
        let answer = try MendResearchClient.decodeResponse(envelope(raw, annotations: items))
        XCTAssertEqual(answer.sources.count, 1)
        XCTAssertTrue(answer.text.hasPrefix("💡 Inspect the latch."))
        XCTAssertFalse(answer.text.contains("AGAIN"))
        XCTAssertEqual(answer.spokenText, "💡 Inspect the latch. Then check the label.")
    }

    func testNoSearchFailedSearchIncompleteAnswerAndArbitraryToolCallsAreRejected() throws {
        XCTAssertThrowsError(try MendResearchClient.decodeResponse(envelope(searchStatus: nil)))
        XCTAssertThrowsError(try MendResearchClient.decodeResponse(envelope(searchStatus: "failed")))
        XCTAssertThrowsError(try MendResearchClient.decodeResponse(envelope(status: "incomplete")))
        XCTAssertThrowsError(try MendResearchClient.decodeResponse(envelope(status: "failed")))
        XCTAssertThrowsError(try MendResearchClient.decodeResponse(envelope(extra: [["type": "function_call", "name": "advanceStep"]])))
    }

    func testMissingOrInvalidCitationsDiscardUnverifiedInstructions() throws {
        let raw = "Unverified instruction. CITED"
        let none = try MendResearchClient.decodeResponse(envelope(raw, annotations: []))
        XCTAssertTrue(none.sources.isEmpty)
        XCTAssertTrue(none.text.contains("couldn't verify"))
        XCTAssertFalse(none.text.contains("Unverified instruction"))
        var malformed = annotation(raw)
        malformed["start_index"] = -1
        let invalid = try MendResearchClient.decodeResponse(envelope(raw, annotations: [malformed]))
        XCTAssertTrue(invalid.sources.isEmpty)
    }

    func testOnlyPublicHTTPOrHTTPSCitationDestinationsAreAccepted() {
        let rejected = ["javascript:alert(1)", "file:///etc/passwd", "data:text/html,x", "https://localhost/a",
            "https://192.168.1.1/a", "https://127.0.0.1/a", "https://[::1]/a", "https://printer.local/a",
            "https://local.internal/a", "https://user:password@www.bosch-home.com/a", "https://www.bosch-home.com:8443/a",
            "https://www.bosch-home.com/a\nextra", "https://www.bosch-home.com/a>payload", "https://2130706433/a"]
        for url in rejected { XCTAssertNil(MendResearchClient.publicSourceURL(url), url) }
        XCTAssertNotNil(MendResearchClient.publicSourceURL("https://www.bosch-home.com/manual.pdf#page=4"))
        XCTAssertNotNil(MendResearchClient.publicSourceURL("http://support.example.org/manual"))
    }

    func testModelAuthoredLinksNeverBecomeAdditionalClickableSources() throws {
        let raw = "Read [this](javascript:alert) and <file:///secret>. CITED https://unverified.example.org/"
        let answer = try MendResearchClient.decodeResponse(envelope(raw))
        XCTAssertEqual(answer.sources.count, 1)
        XCTAssertFalse(answer.text.contains("javascript:"))
        XCTAssertFalse(answer.text.contains("<file:"))
        XCTAssertFalse(answer.text.contains("https://unverified"))
        XCTAssertEqual(answer.text.components(separatedBy: "](<").count - 1, 1)
    }

    func testRequestAndResponseBoundsAreEnforced() throws {
        for question in [" ", String(repeating: "x", count: 2001)] {
            XCTAssertThrowsError(try MendResearchClient.requestBody(question: question, details: details, diagnosis: nil, step: nil))
        }
        XCTAssertThrowsError(try MendResearchClient.requestBody(question: "Help", details: .init(make: String(repeating: "x", count: 121)), diagnosis: nil, step: nil))
        XCTAssertThrowsError(try MendResearchClient.decodeResponse(Data(repeating: 32, count: 256 * 1024 + 1)))
        XCTAssertThrowsError(try MendResearchClient.decodeResponse(envelope(String(repeating: "x", count: 3001), annotations: [])))
    }

    func testInvalidKeysFailBeforeNetworkAccess() async {
        for key in ["", "invalid\nkey", String(repeating: "x", count: 2049)] {
            do {
                _ = try await MendResearchClient().answer(question: "Explain", details: details, diagnosis: nil, step: nil, key: key)
                XCTFail("Invalid key must fail locally")
            } catch { XCTAssertTrue(error is MendError) }
        }
    }
}

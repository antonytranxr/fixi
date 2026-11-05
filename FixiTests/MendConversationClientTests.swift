import XCTest
@testable import Fixi

final class MendConversationClientTests: XCTestCase {
    private let step = MendStep(id: "one", title: "Check latch", instruction: "Gently close the visible latch.",
        expectedResult: "The cover sits flush.", caution: "Do not force a bent latch.", marker: nil)

    private var diagnosis: MendDiagnosis {
        MendDiagnosis(photoID: "photo-001", status: .ready, title: "Raised latch", summary: "The latch appears open.",
            evidence: ["The latch is raised."], confidence: .medium, questions: [], tools: [], precautions: [], steps: [step])
    }

    private func envelope(answer: String, status: String = "completed") throws -> Data {
        let object = try JSONSerialization.data(withJSONObject: ["answer": answer])
        return try JSONSerialization.data(withJSONObject: ["status": status, "output": [["type": "message", "content": [
            ["type": "output_text", "text": String(decoding: object, as: UTF8.self)]]]]])
    }

    func testRequestIncludesOnlyBoundedTextContextAndNoExecutableActions() throws {
        let body = try MendConversationClient.requestBody(question: "What does flush mean?", problem: "The cover is loose.",
            diagnosis: diagnosis, step: step, history: "User: I found the latch.")
        XCTAssertEqual(body["model"] as? String, "muse-wonder-1.0")
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual(body["max_output_tokens"] as? Int, 4096)
        XCTAssertEqual((body["reasoning"] as? [String: String])?["effort"], "low")
        for key in ["tools", "api_key", "previous_response_id", "tool_choice"] { XCTAssertNil(body[key]) }
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 1)
        let content = try XCTUnwrap(input.first?["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 1)
        XCTAssertEqual(content.first?["type"] as? String, "input_text")
        let contextText = try XCTUnwrap(content.first?["text"] as? String)
        let context = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contextText.utf8)) as? [String: Any])
        XCTAssertEqual(context["question"] as? String, "What does flush mean?")
        XCTAssertEqual((context["saved_diagnosis"] as? [String: Any])?["observations"] as? [String], ["The latch is raised."])
        XCTAssertEqual((context["current_step"] as? [String: Any])?["caution"] as? String, "Do not force a bent latch.")
        XCTAssertNil((context["current_step"] as? [String: Any])?["marker"])
        let format = try XCTUnwrap((body["text"] as? [String: Any])?["format"] as? [String: Any])
        let schema = try XCTUnwrap(format["schema"] as? [String: Any])
        XCTAssertEqual(format["strict"] as? Bool, true)
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        XCTAssertEqual(schema["required"] as? [String], ["answer"])
    }

    func testMissingDiagnosisWorksButUnvalidatedOrStaleStepCannotSupplyRepairContext() throws {
        XCTAssertNoThrow(try MendConversationClient.requestBody(question: "Can you help?", problem: "", diagnosis: nil, step: nil, history: ""))
        XCTAssertThrowsError(try MendConversationClient.requestBody(question: "Explain", problem: "", diagnosis: nil, step: step, history: ""))
        let changed = MendStep(id: step.id, title: step.title, instruction: "A different instruction", expectedResult: step.expectedResult, caution: step.caution, marker: nil)
        XCTAssertThrowsError(try MendConversationClient.requestBody(question: "Explain", problem: "", diagnosis: diagnosis, step: changed, history: ""))
        let invalid = MendDiagnosis(photoID: "old", status: .moreEvidence, title: "Unknown", summary: "Unclear", evidence: [],
            confidence: .low, questions: ["Show the part."], tools: [], precautions: [], steps: [step])
        XCTAssertThrowsError(try MendConversationClient.requestBody(question: "Explain", problem: "", diagnosis: invalid, step: nil, history: ""))
    }

    func testBeforeChecklistQuestionIncludesSavedIdentityAndProblemWithoutClaimingAnImageOrStep() throws {
        let saved = "Make: Apple. Model: MacBook Pro. Will not restart. Best-guess fields: make."
        let body = try MendConversationClient.requestBody(question: "How do I restart it?", problem: saved,
            diagnosis: nil, step: nil, history: "User reported that the laptop will not restart.")
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        let content = try XCTUnwrap(input.first?["content"] as? [[String: Any]])
        let json = try XCTUnwrap(content.first?["text"] as? String)
        let context = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(context["question"] as? String, "How do I restart it?")
        XCTAssertEqual(context["reported_problem"] as? String, saved)
        XCTAssertEqual(context["has_saved_checklist"] as? Bool, false)
        XCTAssertNil(context["saved_diagnosis"]); XCTAssertNil(context["current_step"])
        XCTAssertEqual(content.count, 1); XCTAssertEqual(content.first?["type"] as? String, "input_text")
    }

    func testExplicitAnswerBudgetExhaustionRetriesOnceWithTheSameQuestionContext() async throws {
        let truncated = try JSONSerialization.data(withJSONObject: ["status": "incomplete",
            "incomplete_details": ["reason": "max_output_tokens"], "output": []])
        let complete = try envelope(answer: "First, save your work if the menu still responds.")
        var bodies: [[String: Any]] = []
        let client = MendConversationClient { body, key in
            bodies.append(body); XCTAssertEqual(key, "offline-test-key")
            return bodies.count == 1 ? truncated : complete
        }
        let answer = try await client.answer(question: "How do I restart it?", problem: "Laptop won't restart",
            diagnosis: nil, step: nil, history: "", key: "offline-test-key")
        XCTAssertEqual(answer, "First, save your work if the menu still responds.")
        XCTAssertEqual(bodies.count, 2)
        XCTAssertEqual(bodies[0]["max_output_tokens"] as? Int, 4096)
        XCTAssertEqual(bodies[1]["max_output_tokens"] as? Int, 8192)
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: bodies[0]["input"]!, options: .sortedKeys),
            try JSONSerialization.data(withJSONObject: bodies[1]["input"]!, options: .sortedKeys))
    }

    func testRepeatedIncompleteAnswersStopAfterOneRetryAndOtherFailuresNeverRetry() async throws {
        for reason in ["max_output_tokens", "content_filter"] {
            let incomplete = try JSONSerialization.data(withJSONObject: ["status": "incomplete",
                "incomplete_details": ["reason": reason], "output": []])
            var calls = 0
            let client = MendConversationClient { _, _ in calls += 1; return incomplete }
            do {
                _ = try await client.answer(question: "Explain", problem: "", diagnosis: nil, step: nil, history: "", key: "offline-test-key")
                XCTFail("Incomplete text must never be spoken")
            } catch { XCTAssertTrue(error is MendError) }
            XCTAssertEqual(calls, reason == "max_output_tokens" ? 2 : 1)
        }
    }

    func testCancellationAfterTheFirstAnswerStopsBeforeRetry() async throws {
        let incomplete = try JSONSerialization.data(withJSONObject: ["status": "incomplete",
            "incomplete_details": ["reason": "max_output_tokens"], "output": []])
        var calls = 0
        let client = MendConversationClient { _, _ in
            calls += 1
            withUnsafeCurrentTask { $0?.cancel() }
            return incomplete
        }
        let task = Task { try await client.answer(question: "Explain", problem: "", diagnosis: nil, step: nil, history: "", key: "offline-test-key") }
        do { _ = try await task.value; XCTFail("Canceled answer must not retry") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(calls, 1)
    }

    func testInputBoundsPreventUnboundedConversation() {
        for question in [" ", String(repeating: "x", count: 2001)] {
            XCTAssertThrowsError(try MendConversationClient.requestBody(question: question, problem: "", diagnosis: nil, step: nil, history: ""))
        }
        XCTAssertThrowsError(try MendConversationClient.requestBody(question: "Help", problem: String(repeating: "x", count: 1801), diagnosis: nil, step: nil, history: ""))
        XCTAssertThrowsError(try MendConversationClient.requestBody(question: "Help", problem: "", diagnosis: nil, step: nil, history: String(repeating: "x", count: 12001)))
    }

    func testOnlyCompletePlainAnswersAreAccepted() throws {
        XCTAssertEqual(try MendConversationClient.decodeResponse(envelope(answer: "  The cover should sit evenly against its frame.  ")),
            "The cover should sit evenly against its frame.")
        XCTAssertThrowsError(try MendConversationClient.decodeResponse(envelope(answer: "", status: "incomplete")))
        XCTAssertThrowsError(try MendConversationClient.decodeResponse(envelope(answer: " ")))
        XCTAssertThrowsError(try MendConversationClient.decodeResponse(envelope(answer: String(repeating: "a", count: 1201))))
        XCTAssertThrowsError(try MendConversationClient.decodeResponse(Data(repeating: 32, count: 64 * 1024 + 1)))
        XCTAssertThrowsError(try MendConversationClient.decodeResponse(JSONSerialization.data(withJSONObject: ["answer": "Bare answer"])))
        let refused: [String: Any] = ["status": "completed", "output": [["type": "message", "content": [["type": "refusal", "refusal": "Unavailable"]]]]]
        XCTAssertThrowsError(try MendConversationClient.decodeResponse(JSONSerialization.data(withJSONObject: refused)))
        let toolCall: [String: Any] = ["status": "completed", "output": [["type": "function_call", "name": "nextStep"]]]
        XCTAssertThrowsError(try MendConversationClient.decodeResponse(JSONSerialization.data(withJSONObject: toolCall)))
    }

    func testUnexpectedActionFieldsCannotBeReturnedAsAnAnswer() throws {
        let payload = "{\"answer\":\"Next.\",\"action\":\"nextStep\"}"
        let response: [String: Any] = ["status": "completed", "output": [["type": "message", "content": [["type": "output_text", "text": payload]]]]]
        XCTAssertThrowsError(try MendConversationClient.decodeResponse(JSONSerialization.data(withJSONObject: response)))
    }

    func testInvalidKeysFailBeforeNetworking() async {
        for key in ["", "bad\nkey", String(repeating: "a", count: 2049)] {
            do {
                _ = try await MendConversationClient().answer(question: "Explain", problem: "", diagnosis: nil, step: nil, history: "", key: key)
                XCTFail("Invalid API key should fail locally")
            } catch {
                XCTAssertTrue(error is MendError)
            }
        }
    }
}

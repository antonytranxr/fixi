import UIKit
import XCTest
@testable import Fixi

@MainActor final class MendPartsClientTests: XCTestCase {
    private let details = MendProjectDetails(make: "Generic", model: "Cabinet hinge", problem: "The door is loose.")
    private let step = MendStep(id: "one", title: "Check screw", instruction: "Check the screw while supporting the door.",
        expectedResult: "The hinge stays seated.", caution: "Keep the door supported.", marker: nil)
    private var photo: MendPhoto {
        MendPhoto(id: "parts-photo", jpeg: Data([0xff, 0xd8, 0xff, 0xd9]), image: UIImage(), source: "Parts photo", capturedAt: Date())
    }
    private func diagnosis(parts: [String]? = []) -> MendDiagnosis {
        MendDiagnosis(photoID: "plan-photo", status: .ready, title: "Loose hinge", summary: "The hinge may be loose.",
            evidence: ["The user reports a loose door."], confidence: .medium, questions: [], tools: ["Phillips screwdriver"],
            precautions: ["Support the door."], steps: [step], parts: parts)
    }
    private func envelope(_ object: [String: Any], status: String = "completed") throws -> Data {
        let json = try JSONSerialization.data(withJSONObject: object)
        return try JSONSerialization.data(withJSONObject: ["status": status, "output": [["type": "message", "content": [
            ["type": "output_text", "text": String(decoding: json, as: UTF8.self)]]]]])
    }
    private func response(issues: [String] = [], photoID: String? = nil) throws -> Data {
        try envelope(["photoID": photoID as Any? ?? NSNull(), "issues": issues])
    }
    private func content(_ body: [String: Any]) throws -> [[String: Any]] {
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 1)
        return try XCTUnwrap(input.first?["content"] as? [[String: Any]])
    }
    private func context(_ body: [String: Any]) throws -> [String: Any] {
        let text = try XCTUnwrap(content(body).first?["text"] as? String)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    func testPlansRequireSeparatePartsArrayButLegacySavedGuidesStillDecode() throws {
        let body = try MendClient.planRequestBody(details: details, jpeg: nil, photoID: "project")
        let format = try XCTUnwrap((body["text"] as? [String: Any])?["format"] as? [String: Any])
        let schema = try XCTUnwrap(format["schema"] as? [String: Any])
        XCTAssertTrue((schema["required"] as? [String])?.contains("parts") == true)
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        XCTAssertEqual((properties["parts"] as? [String: Any])?["type"] as? String, "array")
        XCTAssertEqual((properties["parts"] as? [String: Any])?["maxItems"] as? Int, 12)
        XCTAssertNotNil(properties["tools"])
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(diagnosis())) as? [String: Any])
        legacy.removeValue(forKey: "parts")
        let decoded = try JSONDecoder().decode(MendDiagnosis.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(decoded.parts)
        XCTAssertNoThrow(try decoded.validated(expectedPhotoID: "plan-photo"))
        XCTAssertEqual(try diagnosis(parts: []).validated(expectedPhotoID: "plan-photo").parts, [])
    }

    func testPartsBoundsRejectEmptyOrUnboundedEntriesWithoutChangingTools() throws {
        for parts in [[" "], [String(repeating: "x", count: 161)], Array(repeating: "Washer", count: 13)] {
            XCTAssertThrowsError(try diagnosis(parts: parts).validated(expectedPhotoID: "plan-photo"))
        }
        let valid = try diagnosis(parts: ["Matching replacement hinge"]).validated(expectedPhotoID: "plan-photo")
        XCTAssertEqual(valid.tools, ["Phillips screwdriver"])
        XCTAssertEqual(valid.parts, ["Matching replacement hinge"])
    }

    func testTextInventoryUsesNoImageAndSerializesExplicitPlanRequirements() throws {
        let body = try MendPartsClient.requestBody(details: details, diagnosis: diagnosis(parts: ["Replacement hinge"]),
            text: "I only have a flathead screwdriver.", photo: nil)
        XCTAssertEqual(body["model"] as? String, "muse-wonder-1.0")
        XCTAssertEqual(body["store"] as? Bool, false)
        for key in ["tools", "tool_choice", "previous_response_id", "api_key"] { XCTAssertNil(body[key]) }
        XCTAssertEqual(try content(body).count, 1)
        let ctx = try context(body)
        XCTAssertTrue(ctx["photo_id"] is NSNull)
        XCTAssertEqual(ctx["latest_user_text"] as? String, "I only have a flathead screwdriver.")
        let saved = try XCTUnwrap(ctx["saved_diagnosis"] as? [String: Any])
        XCTAssertEqual(saved["tools"] as? [String], ["Phillips screwdriver"])
        XCTAssertEqual(saved["parts"] as? [String], ["Replacement hinge"])
        XCTAssertEqual(saved["precautions"] as? [String], ["Support the door."])
        XCTAssertNil((saved["steps"] as? [[String: Any]])?.first?["marker"])
        let format = try XCTUnwrap((body["text"] as? [String: Any])?["format"] as? [String: Any])
        let schema = try XCTUnwrap(format["schema"] as? [String: Any])
        XCTAssertEqual(format["strict"] as? Bool, true)
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        XCTAssertEqual(Set(schema["required"] as? [String] ?? []), ["photoID", "issues"])
    }

    func testPhotoReviewIncludesOnlyTheExplicitImageAndPreservesUnknownPartsList() throws {
        let body = try MendPartsClient.requestBody(details: details, diagnosis: diagnosis(parts: nil), text: "", photo: photo)
        let parts = try content(body)
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[1]["type"] as? String, "input_image")
        XCTAssertEqual(parts[1]["image_url"] as? String, "data:image/jpeg;base64," + photo.jpeg.base64EncodedString())
        let ctx = try context(body)
        XCTAssertEqual(ctx["photo_id"] as? String, photo.id)
        XCTAssertTrue((ctx["saved_diagnosis"] as? [String: Any])?["parts"] is NSNull)
    }

    func testMissingEvidenceInvalidImagesAndNonreadyPlansDoNotReachReview() throws {
        XCTAssertThrowsError(try MendPartsClient.requestBody(details: details, diagnosis: diagnosis(), text: " ", photo: nil))
        XCTAssertThrowsError(try MendPartsClient.requestBody(details: details, diagnosis: diagnosis(), text: String(repeating: "x", count: 3001), photo: nil))
        XCTAssertThrowsError(try MendPartsClient.requestBody(details: MendProjectDetails(), diagnosis: diagnosis(), text: "A screwdriver.", photo: nil))
        let invalid = MendPhoto(id: "bad", jpeg: Data("bad".utf8), image: UIImage(), source: "Invalid", capturedAt: Date())
        XCTAssertThrowsError(try MendPartsClient.requestBody(details: details, diagnosis: diagnosis(), text: "", photo: invalid))
        for status in [DiagnosisStatus.stop, .moreEvidence] {
            let blocked = MendDiagnosis(photoID: "old", status: status, title: "Need evidence", summary: "Unclear model.",
                evidence: [], confidence: .low, questions: status == .moreEvidence ? ["Show the label."] : [], tools: [], precautions: [], steps: [])
            XCTAssertThrowsError(try MendPartsClient.requestBody(details: details, diagnosis: blocked, text: "A screwdriver.", photo: nil))
        }
    }

    func testEmptyFindingsAreAcceptedWithoutAnAllClearOrPhotoClaim() throws {
        let textOnly = try MendPartsClient.decodeResponse(response(), expectedPhotoID: nil)
        XCTAssertEqual(textOnly, MendPartsReview(photoID: nil, issues: []))
        let visual = try MendPartsClient.decodeResponse(response(photoID: photo.id), expectedPhotoID: photo.id)
        XCTAssertEqual(visual.issues, [])
        XCTAssertEqual(visual.photoID, photo.id)
        let issue = try MendPartsClient.decodeResponse(response(issues: ["  The plan needs a Phillips screwdriver; you reported only a flathead.  "]), expectedPhotoID: nil)
        XCTAssertEqual(issue.issues, ["The plan needs a Phillips screwdriver; you reported only a flathead."])
    }

    func testReviewsRejectMismatchedPhotoIDsAndMalformedIssues() throws {
        XCTAssertThrowsError(try MendPartsClient.decodeResponse(response(photoID: "old-photo"), expectedPhotoID: photo.id))
        XCTAssertThrowsError(try MendPartsClient.decodeResponse(response(photoID: photo.id), expectedPhotoID: nil))
        XCTAssertThrowsError(try MendPartsClient.decodeResponse(response(), expectedPhotoID: photo.id))
        for issues in [[" "], [String(repeating: "x", count: 301)], Array(repeating: "Mismatch", count: 5)] {
            XCTAssertThrowsError(try MendPartsClient.decodeResponse(response(issues: issues), expectedPhotoID: nil))
        }
        XCTAssertThrowsError(try MendPartsReview(photoID: " ", issues: []).validated(expectedPhotoID: " "))
    }

    func testUnexpectedFieldsBareResultsRefusalsAndIncompleteAnswersAreRejected() throws {
        for object: [String: Any] in [
            ["issues": []], ["photoID": NSNull(), "issues": [], "completeStep": true],
            ["photoID": NSNull(), "issues": "All good"], ["photoID": 42, "issues": []]
        ] {
            XCTAssertThrowsError(try MendPartsClient.decodeResponse(envelope(object), expectedPhotoID: nil))
        }
        XCTAssertThrowsError(try MendPartsClient.decodeResponse(JSONSerialization.data(withJSONObject: ["photoID": NSNull(), "issues": []]), expectedPhotoID: nil))
        XCTAssertThrowsError(try MendPartsClient.decodeResponse(envelope(["photoID": NSNull(), "issues": []], status: "incomplete"), expectedPhotoID: nil))
        XCTAssertThrowsError(try MendPartsClient.decodeResponse(Data(repeating: 32, count: 64 * 1024 + 1), expectedPhotoID: nil))
        let refusal: [String: Any] = ["status": "completed", "output": [["type": "message", "content": [["type": "refusal", "refusal": "Unavailable"]]]]]
        XCTAssertThrowsError(try MendPartsClient.decodeResponse(JSONSerialization.data(withJSONObject: refusal), expectedPhotoID: nil))
        let action: [String: Any] = ["status": "completed", "output": [["type": "function_call", "name": "completeStep"]]]
        XCTAssertThrowsError(try MendPartsClient.decodeResponse(JSONSerialization.data(withJSONObject: action), expectedPhotoID: nil))
    }

    func testOneBudgetRetryUsesIdenticalPartsEvidence() async throws {
        let incomplete = try JSONSerialization.data(withJSONObject: ["status": "incomplete", "incomplete_details": ["reason": "max_output_tokens"], "output": []])
        let complete = try response(photoID: photo.id)
        var bodies: [[String: Any]] = []
        let client = MendPartsClient { body, key in
            bodies.append(body); XCTAssertEqual(key, "offline-key")
            return bodies.count == 1 ? incomplete : complete
        }
        let result = try await client.check(details: details, diagnosis: diagnosis(), text: "These are my tools.", photo: photo, key: "offline-key")
        XCTAssertTrue(result.issues.isEmpty); XCTAssertEqual(bodies.count, 2)
        XCTAssertEqual(bodies[0]["max_output_tokens"] as? Int, 4096)
        XCTAssertEqual(bodies[1]["max_output_tokens"] as? Int, 8192)
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: bodies[0]["input"]!, options: .sortedKeys),
                       try JSONSerialization.data(withJSONObject: bodies[1]["input"]!, options: .sortedKeys))
    }

    func testNoRetryForOtherFailuresAndAtMostOneForBudgetExhaustion() async throws {
        for reason in ["max_output_tokens", "content_filter"] {
            let incomplete = try JSONSerialization.data(withJSONObject: ["status": "incomplete", "incomplete_details": ["reason": reason], "output": []])
            var calls = 0
            let client = MendPartsClient { _, _ in calls += 1; return incomplete }
            do { _ = try await client.check(details: details, diagnosis: diagnosis(), text: "A screwdriver.", photo: nil, key: "offline-key"); XCTFail("Incomplete review accepted") }
            catch { XCTAssertTrue(error is MendError) }
            XCTAssertEqual(calls, reason == "max_output_tokens" ? 2 : 1)
        }
    }

    func testCancellationAndInvalidKeyDoNotContinueReview() async throws {
        let incomplete = try JSONSerialization.data(withJSONObject: ["status": "incomplete", "incomplete_details": ["reason": "max_output_tokens"], "output": []])
        var calls = 0
        let client = MendPartsClient { _, _ in calls += 1; withUnsafeCurrentTask { $0?.cancel() }; return incomplete }
        let task = Task { try await client.check(details: details, diagnosis: diagnosis(), text: "A screwdriver.", photo: nil, key: "offline-key") }
        do { _ = try await task.value; XCTFail("Cancelled review continued") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(calls, 1)
        let invalidKeyClient = MendPartsClient { _, _ in XCTFail("Invalid key reached transport"); return Data() }
        for key in ["", "invalid\nkey", String(repeating: "x", count: 2049)] {
            do { _ = try await invalidKeyClient.check(details: details, diagnosis: diagnosis(), text: "A screwdriver.", photo: nil, key: key); XCTFail("Invalid key accepted") }
            catch { XCTAssertTrue(error is MendError) }
        }
    }

    func testAnswerClientsReceiveNewPartsContextWithoutChangingTheirActionBoundary() throws {
        let plan = diagnosis(parts: ["Matching hinge"])
        let conversation = try MendConversationClient.requestBody(question: "Is this right?", problem: details.problem,
            diagnosis: plan, step: step, history: "User: I have a hinge.")
        let live = try MendLiveQuestionClient.requestBody(question: "Is this right?", details: details,
            diagnosis: plan, step: step, history: "", photo: photo)
        let research = try MendResearchClient.requestBody(question: "Look up the hinge.", details: details,
            diagnosis: plan, step: step, photo: photo)
        for body in [conversation, live, research] {
            XCTAssertEqual((try context(body)["saved_diagnosis"] as? [String: Any])?["parts"] as? [String], ["Matching hinge"])
            XCTAssertNil(body["previous_response_id"])
        }
        XCTAssertNil(conversation["tools"]); XCTAssertNil(live["tools"])
        XCTAssertEqual((research["tools"] as? [[String: Any]])?.first?["type"] as? String, "web_search")
    }
}

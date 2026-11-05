import UIKit
import XCTest
@testable import Fixi

@MainActor final class MendLiveQuestionClientTests: XCTestCase {
    private let details = MendProjectDetails(make: "Generic", model: "Cabinet hinge", problem: "The door is loose.")
    private let step = MendStep(id: "one", title: "Check screw", instruction: "Check the visible screw while supporting the door.",
        expectedResult: "The screw sits flush.", caution: "Keep the door supported.", marker: nil)
    private let arrow = PhotoMarker(kind: "arrow", x: 0.2, y: 0.4, width: nil, height: nil,
        endX: 0.5, endY: 0.6, label: "Hinge screw")

    private var photo: MendPhoto {
        MendPhoto(id: "live-frame-001", jpeg: Data([0xff, 0xd8, 0xff, 0xd9]), image: UIImage(), source: "Glasses live view",
                  capturedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    private var diagnosis: MendDiagnosis {
        MendDiagnosis(photoID: "earlier-plan-photo", status: .ready, title: "Loose hinge", summary: "A hinge may be loose.",
            evidence: ["The user reports a loose door."], confidence: .medium, questions: [], tools: ["Screwdriver"],
            precautions: ["Support the door."], steps: [step])
    }

    private func markerObject(_ marker: PhotoMarker) -> [String: Any] {
        ["kind": marker.kind, "x": marker.x, "y": marker.y,
         "width": marker.width as Any? ?? NSNull(), "height": marker.height as Any? ?? NSNull(),
         "endX": marker.endX as Any? ?? NSNull(), "endY": marker.endY as Any? ?? NSNull(), "label": marker.label]
    }

    private func envelope(object: [String: Any], status: String = "completed") throws -> Data {
        let json = try JSONSerialization.data(withJSONObject: object)
        return try JSONSerialization.data(withJSONObject: ["status": status, "output": [["type": "message", "content": [
            ["type": "output_text", "text": String(decoding: json, as: UTF8.self)]]]]])
    }

    private func response(answer: String = "The arrow marks the visible hinge screw.", marker: PhotoMarker? = nil,
                          photoID: String = "live-frame-001") throws -> Data {
        try envelope(object: ["answer": answer, "photoID": photoID, "marker": marker.map(markerObject) as Any? ?? NSNull()])
    }

    private func context(_ body: [String: Any]) throws -> [String: Any] {
        let messages = try XCTUnwrap(body["input"] as? [[String: Any]])
        let content = try XCTUnwrap(messages.first?["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    func testQuestionSendsExactlyOneSnapshotAndPreservesRepairContextWithoutOldCoordinates() throws {
        let body = try MendLiveQuestionClient.requestBody(question: "Is this the screw?", details: details,
            diagnosis: diagnosis, step: step, history: "User: I am looking at the hinge.", photo: photo)
        XCTAssertEqual(body["model"] as? String, "muse-wonder-1.0")
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual(body["max_output_tokens"] as? Int, 4096)
        for key in ["tools", "api_key", "previous_response_id", "tool_choice"] { XCTAssertNil(body[key]) }
        let messages = try XCTUnwrap(body["input"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1)
        let content = try XCTUnwrap(messages.first?["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 2)
        XCTAssertEqual(content[0]["type"] as? String, "input_text")
        XCTAssertEqual(content[1]["type"] as? String, "input_image")
        XCTAssertEqual(content[1]["image_url"] as? String, "data:image/jpeg;base64," + photo.jpeg.base64EncodedString())
        let context = try context(body)
        XCTAssertEqual(context["photo_id"] as? String, photo.id)
        XCTAssertEqual(context["image_kind"] as? String, "fresh_live_view_snapshot")
        XCTAssertEqual(context["question"] as? String, "Is this the screw?")
        XCTAssertEqual((context["project_details"] as? [String: String])?["model"], "Cabinet hinge")
        XCTAssertEqual((context["saved_diagnosis"] as? [String: Any])?["precautions"] as? [String], ["Support the door."])
        XCTAssertEqual((context["current_step"] as? [String: String])?["caution"], "Keep the door supported.")
        XCTAssertNil((context["current_step"] as? [String: Any])?["marker"])
        let format = try XCTUnwrap((body["text"] as? [String: Any])?["format"] as? [String: Any])
        let schema = try XCTUnwrap(format["schema"] as? [String: Any])
        XCTAssertEqual(format["strict"] as? Bool, true)
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        XCTAssertEqual(Set(schema["required"] as? [String] ?? []), ["answer", "marker", "photoID"])
    }

    func testQuestionBeforeChecklistRetainsBestGuessIdentityAndNeverClaimsConfirmation() throws {
        let pending = MendProjectDetails(make: "Apple", model: "MacBook Pro", problem: "Will not restart", suggestedFields: ["make", "model"])
        let body = try MendLiveQuestionClient.requestBody(question: "Which button is power?", details: pending,
            diagnosis: nil, step: nil, history: "", photo: photo)
        let context = try context(body)
        XCTAssertEqual(context["suggested_fields"] as? [String], ["make", "model"])
        XCTAssertEqual(context["has_saved_checklist"] as? Bool, false)
        XCTAssertNil(context["saved_diagnosis"]); XCTAssertNil(context["current_step"])
        XCTAssertNil(context["details_confirmed_by_user"])
    }

    func testBlockedAndMissingEvidenceStatesRemainExplicitInVisualRequest() throws {
        for status in [DiagnosisStatus.moreEvidence, .stop] {
            let saved = MendDiagnosis(photoID: "previous", status: status, title: "Need a safer view", summary: "The source is unclear.",
                evidence: [], confidence: .low, questions: status == .moreEvidence ? ["Show the label."] : [], tools: [],
                precautions: ["Do not open the cover."], steps: [])
            let body = try MendLiveQuestionClient.requestBody(question: "Can I continue?", details: details,
                diagnosis: saved, step: nil, history: "", photo: photo)
            XCTAssertEqual((try context(body)["saved_diagnosis"] as? [String: Any])?["status"] as? String, status.rawValue)
        }
    }

    func testInvalidOrStaleContextIsRejectedBeforeRequest() throws {
        XCTAssertThrowsError(try MendLiveQuestionClient.requestBody(question: "Explain", details: details,
            diagnosis: nil, step: step, history: "", photo: photo))
        let changed = MendStep(id: step.id, title: step.title, instruction: step.instruction, expectedResult: step.expectedResult,
            caution: "Different caution", marker: nil)
        XCTAssertThrowsError(try MendLiveQuestionClient.requestBody(question: "Explain", details: details,
            diagnosis: diagnosis, step: changed, history: "", photo: photo))
        for question in [" ", String(repeating: "x", count: 2001)] {
            XCTAssertThrowsError(try MendLiveQuestionClient.requestBody(question: question, details: details,
                diagnosis: nil, step: nil, history: "", photo: photo))
        }
        XCTAssertThrowsError(try MendLiveQuestionClient.requestBody(question: "Explain", details: details,
            diagnosis: nil, step: nil, history: String(repeating: "x", count: 12001), photo: photo))
        let invalidPhoto = MendPhoto(id: photo.id, jpeg: Data("not jpeg".utf8), image: photo.image, source: photo.source, capturedAt: photo.capturedAt)
        XCTAssertThrowsError(try MendLiveQuestionClient.requestBody(question: "Explain", details: details,
            diagnosis: nil, step: nil, history: "", photo: invalidPhoto))
        XCTAssertThrowsError(try MendLiveQuestionClient.requestBody(question: "Explain",
            details: MendProjectDetails(make: String(repeating: "x", count: 121)), diagnosis: nil, step: nil, history: "", photo: photo))
    }

    func testValidAnswerAndAnnotationRemainBoundToTheExactSnapshot() throws {
        let result = try MendLiveQuestionClient.decodeResponse(response(answer: "  This is the hinge screw.  ", marker: arrow), expectedPhotoID: photo.id)
        XCTAssertEqual(result.answer, "This is the hinge screw.")
        XCTAssertEqual(result.photoID, photo.id); XCTAssertEqual(result.marker, arrow)
        XCTAssertNil(try MendLiveQuestionClient.decodeResponse(response(answer: "There are two screws. Which one do you mean?"), expectedPhotoID: photo.id).marker)
        XCTAssertThrowsError(try MendLiveQuestionClient.decodeResponse(response(marker: arrow, photoID: "other-frame"), expectedPhotoID: photo.id))
    }

    func testSmallTargetDotDecodesOnlyForItsExactLiveSnapshot() throws {
        let dot = PhotoMarker(kind: "dot", x: 0.5, y: 0.6, width: nil, height: nil, endX: nil, endY: nil, label: "Hinge screw")
        let result = try MendLiveQuestionClient.decodeResponse(response(answer: "The dot marks the visible screw.", marker: dot), expectedPhotoID: photo.id)
        XCTAssertEqual(result.marker, dot)
        XCTAssertThrowsError(try MendLiveQuestionClient.decodeResponse(response(marker: dot, photoID: "earlier-frame"), expectedPhotoID: photo.id))
        for invalid in [
            PhotoMarker(kind: "dot", x: 0.5, y: 1.1, width: nil, height: nil, endX: nil, endY: nil, label: "Hinge screw"),
            PhotoMarker(kind: "dot", x: 0.5, y: 0.6, width: 0.02, height: nil, endX: nil, endY: nil, label: "Hinge screw"),
            PhotoMarker(kind: "dot", x: 0.5, y: 0.6, width: nil, height: nil, endX: 0.5, endY: 0.6, label: "Hinge screw")
        ] {
            XCTAssertThrowsError(try MendLiveQuestionClient.decodeResponse(response(marker: invalid), expectedPhotoID: photo.id))
        }
    }

    func testLiveQuestionSchemaAllowsPointMarkersWithExplicitNullableGeometry() throws {
        let body = try MendLiveQuestionClient.requestBody(question: "Which screw?", details: details,
            diagnosis: diagnosis, step: step, history: "", photo: photo)
        let format = try XCTUnwrap((body["text"] as? [String: Any])?["format"] as? [String: Any])
        let schema = try XCTUnwrap(format["schema"] as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: [String: Any]])
        let options = try XCTUnwrap(properties["marker"]?["anyOf"] as? [[String: Any]])
        let marker = try XCTUnwrap(options.first { $0["type"] as? String == "object" })
        let geometry = try XCTUnwrap(marker["properties"] as? [String: [String: Any]])
        XCTAssertEqual(Set(geometry["kind"]?["enum"] as? [String] ?? []), ["dot", "circle", "arrow"])
        XCTAssertEqual(Set(marker["required"] as? [String] ?? []), Set(geometry.keys))
        XCTAssertEqual(marker["additionalProperties"] as? Bool, false)
        for key in ["width", "height", "endX", "endY"] {
            let variants = try XCTUnwrap(geometry[key]?["anyOf"] as? [[String: Any]])
            XCTAssertTrue(variants.contains { $0["type"] as? String == "null" })
        }
    }

    func testOutOfBoundsUnknownAndDegenerateMarkersAreRejected() throws {
        let invalid = [
            PhotoMarker(kind: "circle", x: 0.9, y: 0.4, width: 0.2, height: 0.1, endX: nil, endY: nil, label: "Screw"),
            PhotoMarker(kind: "arrow", x: 0.4, y: 0.4, width: nil, height: nil, endX: 0.4, endY: 0.4, label: "Screw"),
            PhotoMarker(kind: "arrow", x: -0.1, y: 0.4, width: nil, height: nil, endX: 0.5, endY: 0.6, label: "Screw"),
            PhotoMarker(kind: "arrow", x: 0.2, y: 0.4, width: 0.1, height: nil, endX: 0.5, endY: 0.6, label: "Screw"),
            PhotoMarker(kind: "track", x: 0.2, y: 0.4, width: nil, height: nil, endX: 0.5, endY: 0.6, label: "Screw")
        ]
        for marker in invalid {
            XCTAssertThrowsError(try MendLiveQuestionClient.decodeResponse(response(marker: marker), expectedPhotoID: photo.id))
        }
        let nonfinite = PhotoMarker(kind: "arrow", x: .nan, y: 0.4, width: nil, height: nil, endX: 0.5, endY: 0.6, label: "Screw")
        XCTAssertThrowsError(try MendLiveAnswer(photoID: photo.id, answer: "A screw.", marker: nonfinite).validated(expectedPhotoID: photo.id))
    }

    func testUnexpectedFieldsMissingNullsAndActionsAreRejected() throws {
        let base: [String: Any] = ["photoID": photo.id, "answer": "Check this screw.", "marker": NSNull()]
        var extra = base; extra["action"] = "completeStep"
        var missing = base; missing.removeValue(forKey: "marker")
        var nested = base; var nestedMarker = markerObject(arrow); nestedMarker["action"] = "completeStep"; nested["marker"] = nestedMarker
        var missingNulls = base; var minimalMarker = markerObject(arrow); minimalMarker.removeValue(forKey: "width"); missingNulls["marker"] = minimalMarker
        for object in [extra, missing, nested, missingNulls] {
            XCTAssertThrowsError(try MendLiveQuestionClient.decodeResponse(envelope(object: object), expectedPhotoID: photo.id))
        }
        let function: [String: Any] = ["status": "completed", "output": [["type": "function_call", "name": "nextStep"]]]
        XCTAssertThrowsError(try MendLiveQuestionClient.decodeResponse(JSONSerialization.data(withJSONObject: function), expectedPhotoID: photo.id))
    }

    func testOnlyCompleteBoundedUsableAnswersAreAccepted() throws {
        for answer in [" ", String(repeating: "a", count: 1201)] {
            XCTAssertThrowsError(try MendLiveQuestionClient.decodeResponse(response(answer: answer), expectedPhotoID: photo.id))
        }
        XCTAssertThrowsError(try MendLiveQuestionClient.decodeResponse(Data(repeating: 32, count: 64 * 1024 + 1), expectedPhotoID: photo.id))
        XCTAssertThrowsError(try MendLiveQuestionClient.decodeResponse(envelope(object: ["photoID": photo.id, "answer": "Pending", "marker": NSNull()], status: "incomplete"), expectedPhotoID: photo.id))
        let refusal: [String: Any] = ["status": "completed", "output": [["type": "message", "content": [["type": "refusal", "refusal": "Unavailable"]]]]]
        XCTAssertThrowsError(try MendLiveQuestionClient.decodeResponse(JSONSerialization.data(withJSONObject: refusal), expectedPhotoID: photo.id))
    }

    func testExplicitBudgetExhaustionRetriesOnceWithTheIdenticalSnapshotAndContext() async throws {
        let incomplete = try JSONSerialization.data(withJSONObject: ["status": "incomplete", "incomplete_details": ["reason": "max_output_tokens"], "output": []])
        let complete = try response(marker: arrow)
        var bodies: [[String: Any]] = []
        let client = MendLiveQuestionClient { body, key in
            bodies.append(body); XCTAssertEqual(key, "offline-test-key")
            return bodies.count == 1 ? incomplete : complete
        }
        let result = try await client.answer(question: "Is this it?", details: details, diagnosis: diagnosis, step: step,
            history: "", photo: photo, key: "offline-test-key")
        XCTAssertEqual(result.photoID, photo.id); XCTAssertEqual(result.marker, arrow)
        XCTAssertEqual(bodies.count, 2)
        XCTAssertEqual(bodies[0]["max_output_tokens"] as? Int, 4096)
        XCTAssertEqual(bodies[1]["max_output_tokens"] as? Int, 8192)
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: bodies[0]["input"]!, options: .sortedKeys),
                       try JSONSerialization.data(withJSONObject: bodies[1]["input"]!, options: .sortedKeys))
    }

    func testOtherFailuresNeverRetryAndRepeatedBudgetExhaustionStops() async throws {
        for reason in ["max_output_tokens", "content_filter"] {
            let incomplete = try JSONSerialization.data(withJSONObject: ["status": "incomplete", "incomplete_details": ["reason": reason], "output": []])
            var calls = 0
            let client = MendLiveQuestionClient { _, _ in calls += 1; return incomplete }
            do {
                _ = try await client.answer(question: "Is this it?", details: details, diagnosis: nil, step: nil,
                    history: "", photo: photo, key: "offline-test-key")
                XCTFail("Incomplete answers must not be shown or spoken")
            } catch { XCTAssertTrue(error is MendError) }
            XCTAssertEqual(calls, reason == "max_output_tokens" ? 2 : 1)
        }
    }

    func testCancellationAfterResponsePreventsRetry() async throws {
        let incomplete = try JSONSerialization.data(withJSONObject: ["status": "incomplete", "incomplete_details": ["reason": "max_output_tokens"], "output": []])
        var calls = 0
        let client = MendLiveQuestionClient { _, _ in
            calls += 1; withUnsafeCurrentTask { $0?.cancel() }; return incomplete
        }
        let task = Task { try await client.answer(question: "Is this it?", details: details, diagnosis: nil, step: nil,
            history: "", photo: photo, key: "offline-test-key") }
        do { _ = try await task.value; XCTFail("Canceled answers must not retry") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(calls, 1)
    }

    func testInvalidKeyFailsBeforeInjectedTransport() async {
        var calls = 0
        let client = MendLiveQuestionClient { _, _ in calls += 1; return Data() }
        for key in ["", "invalid\nkey", String(repeating: "x", count: 2049)] {
            do {
                _ = try await client.answer(question: "Is this it?", details: details, diagnosis: nil, step: nil,
                    history: "", photo: photo, key: key)
                XCTFail("Invalid key must fail locally")
            } catch { XCTAssertTrue(error is MendError) }
        }
        XCTAssertEqual(calls, 0)
    }
}

import XCTest
@testable import Fixi

final class RepairCoreTests: XCTestCase {
    private let photoID = "photo-001"
    private let jpeg = Data([0xff, 0xd8, 0xff, 0xd9])

    private var circle: PhotoMarker {
        PhotoMarker(kind: "circle", x: 0.2, y: 0.3, width: 0.25, height: 0.2,
            endX: nil, endY: nil, label: "Latch")
    }
    private var arrow: PhotoMarker {
        PhotoMarker(kind: "arrow", x: 0.2, y: 0.3, width: nil, height: nil,
            endX: 0.5, endY: 0.5, label: "Latch")
    }
    private var dot: PhotoMarker {
        PhotoMarker(kind: "dot", x: 0.35, y: 0.4, width: nil, height: nil, endX: nil, endY: nil, label: "Latch screw")
    }

    private func step(id: String = "step-1", marker: PhotoMarker? = nil) -> MendStep {
        MendStep(id: id, title: "Check the latch", instruction: "Gently close the visible latch.",
            expectedResult: "The cover sits flush.", caution: nil, marker: marker)
    }

    private func diagnosis(status: DiagnosisStatus = .ready, confidence: DiagnosisConfidence = .medium,
                           steps: [MendStep]? = nil, questions: [String] = [], id: String? = nil) -> MendDiagnosis {
        MendDiagnosis(photoID: id ?? photoID, status: status, title: "Loose cover",
            summary: "The visible latch appears open.", evidence: ["The latch is raised."],
            confidence: confidence, questions: questions, tools: [], precautions: [], steps: steps ?? [step(marker: circle)])
    }

    private func envelope<T: Encodable>(_ value: T, status: String = "completed") throws -> Data {
        let text = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        return try JSONSerialization.data(withJSONObject: ["status": status,
            "output": [["type": "message", "content": [["type": "output_text", "text": text]]]]])
    }

    func testDecodesCompletedAnswerAndRetainsPhotoBinding() throws {
        let result = try MendClient.decodeResponse(envelope(diagnosis()), expectedPhotoID: photoID)
        XCTAssertEqual(result.photoID, photoID)
        XCTAssertEqual(result.status, .ready)
        XCTAssertEqual(result.steps.first?.marker, circle)
        XCTAssertThrowsError(try MendClient.decodeResponse(envelope(diagnosis()), expectedPhotoID: "new-photo"))
    }

    func testIncompleteAndRefusedResponsesNeverBecomeGuides() throws {
        XCTAssertThrowsError(try MendClient.decodeResponse(envelope(diagnosis(), status: "incomplete"), expectedPhotoID: photoID))
        let refused: [String: Any] = ["status": "completed", "output": [["type": "message", "content": [
            ["type": "refusal", "refusal": "Cannot comply"]]]]]
        XCTAssertThrowsError(try MendClient.decodeResponse(JSONSerialization.data(withJSONObject: refused), expectedPhotoID: photoID))
        XCTAssertThrowsError(try MendClient.decodeResponse(JSONEncoder().encode(diagnosis()), expectedPhotoID: photoID))
    }

    func testReadyRequiresEvidenceAndResolvedQuestions() throws {
        XCTAssertThrowsError(try diagnosis(confidence: .low).validated(expectedPhotoID: photoID))
        XCTAssertThrowsError(try diagnosis(steps: []).validated(expectedPhotoID: photoID))
        XCTAssertThrowsError(try diagnosis(questions: ["Which model is this?"]).validated(expectedPhotoID: photoID))
        let noEvidence = MendDiagnosis(photoID: photoID, status: .ready, title: "Cover", summary: "Possibly loose",
            evidence: [], confidence: .medium, questions: [], tools: [], precautions: [], steps: [step()])
        XCTAssertThrowsError(try noEvidence.validated(expectedPhotoID: photoID))
    }

    func testStopsAndEvidenceRequestsCannotSmuggleRepairSteps() throws {
        XCTAssertThrowsError(try diagnosis(status: .stop).validated(expectedPhotoID: photoID))
        XCTAssertThrowsError(try diagnosis(status: .moreEvidence, questions: ["Show the label."]).validated(expectedPhotoID: photoID))
        XCTAssertThrowsError(try diagnosis(status: .moreEvidence, steps: []).validated(expectedPhotoID: photoID))
        XCTAssertNoThrow(try diagnosis(status: .stop, confidence: .low, steps: []).validated(expectedPhotoID: photoID))
        XCTAssertNoThrow(try diagnosis(status: .moreEvidence, confidence: .low, steps: [], questions: ["Show the label."])
            .validated(expectedPhotoID: photoID))
    }

    func testStepIdentifiersAndCountsCannotConflict() throws {
        XCTAssertThrowsError(try diagnosis(steps: [step(), step()]).validated(expectedPhotoID: photoID))
        XCTAssertThrowsError(try diagnosis(steps: [step(id: " ")]).validated(expectedPhotoID: photoID))
        XCTAssertThrowsError(try diagnosis(steps: (0..<13).map { step(id: "step-\($0)") }).validated(expectedPhotoID: photoID))
    }

    func testCircleMustStayInsideTheExactPhoto() throws {
        let invalid = [
            PhotoMarker(kind: "circle", x: 0.9, y: 0.3, width: 0.2, height: 0.2, endX: nil, endY: nil, label: "Latch"),
            PhotoMarker(kind: "circle", x: 0.2, y: -0.1, width: 0.2, height: 0.2, endX: nil, endY: nil, label: "Latch"),
            PhotoMarker(kind: "circle", x: 0.2, y: 0.3, width: 0, height: 0.2, endX: nil, endY: nil, label: "Latch"),
            PhotoMarker(kind: "circle", x: .nan, y: 0.3, width: 0.2, height: 0.2, endX: nil, endY: nil, label: "Latch"),
            PhotoMarker(kind: "circle", x: 0.2, y: 0.3, width: 0.2, height: 0.2, endX: 0.5, endY: 0.5, label: "Latch")
        ]
        for marker in invalid {
            XCTAssertThrowsError(try diagnosis(steps: [step(marker: marker)]).validated(expectedPhotoID: photoID))
        }
    }

    func testArrowsNeedDistinctInBoundsEndpointsAndNoCircleDimensions() throws {
        XCTAssertNoThrow(try diagnosis(steps: [step(marker: arrow)]).validated(expectedPhotoID: photoID))
        let invalid = [
            PhotoMarker(kind: "arrow", x: 0.2, y: 0.3, width: nil, height: nil, endX: 1.1, endY: 0.5, label: "Latch"),
            PhotoMarker(kind: "arrow", x: 0.2, y: 0.3, width: nil, height: nil, endX: 0.2, endY: 0.3, label: "Latch"),
            PhotoMarker(kind: "arrow", x: 0.2, y: 0.3, width: 0.2, height: nil, endX: 0.5, endY: 0.5, label: "Latch"),
            PhotoMarker(kind: "arrow", x: 0.2, y: 0.3, width: nil, height: nil, endX: nil, endY: nil, label: "Latch"),
            PhotoMarker(kind: "worldPoint", x: 0.2, y: 0.3, width: nil, height: nil, endX: 0.5, endY: 0.5, label: "Latch")
        ]
        for marker in invalid {
            XCTAssertThrowsError(try diagnosis(steps: [step(marker: marker)]).validated(expectedPhotoID: photoID))
        }
    }

    func testDotsRequireOneFiniteInBoundsPointAndExactPhotoEvidence() throws {
        let valid = diagnosis(steps: [step(marker: dot)])
        XCTAssertEqual(try MendClient.decodeResponse(envelope(valid), expectedPhotoID: photoID).steps[0].marker, dot)
        XCTAssertThrowsError(try valid.validated(expectedPhotoID: "other-photo"))
        XCTAssertThrowsError(try valid.validated(expectedPhotoID: photoID, hasPhoto: false))
        let grounded = MendGrounding(photoID: photoID, found: true, message: "The screw is visible.", marker: dot)
        XCTAssertEqual(try MendClient.decodeGroundingResponse(envelope(grounded), expectedPhotoID: photoID).marker, dot)
        let invalid = [
            PhotoMarker(kind: "dot", x: 1.01, y: 0.4, width: nil, height: nil, endX: nil, endY: nil, label: "Screw"),
            PhotoMarker(kind: "dot", x: 0.3, y: -.infinity, width: nil, height: nil, endX: nil, endY: nil, label: "Screw"),
            PhotoMarker(kind: "dot", x: 0.3, y: 0.4, width: 0, height: nil, endX: nil, endY: nil, label: "Screw"),
            PhotoMarker(kind: "dot", x: 0.3, y: 0.4, width: nil, height: 0.1, endX: nil, endY: nil, label: "Screw"),
            PhotoMarker(kind: "dot", x: 0.3, y: 0.4, width: nil, height: nil, endX: 0.3, endY: nil, label: "Screw"),
            PhotoMarker(kind: "dot", x: 0.3, y: 0.4, width: nil, height: nil, endX: nil, endY: 0.4, label: "Screw")
        ]
        for marker in invalid {
            XCTAssertThrowsError(try diagnosis(steps: [step(marker: marker)]).validated(expectedPhotoID: photoID))
            XCTAssertFalse(PhotoFocus.isValid(marker))
        }
    }

    func testEveryRepairRequestSchemaAcceptsPointCircleAndArrowMarkers() throws {
        let requests = [
            try MendClient.requestBody(jpeg: jpeg, photoID: photoID, problem: "The cover is loose."),
            try MendClient.planRequestBody(details: MendProjectDetails(make: "Generic", model: "Cover", problem: "Loose latch"), jpeg: jpeg, photoID: photoID),
            try MendClient.locateRequestBody(jpeg: jpeg, photoID: photoID, step: step())
        ]
        for request in requests {
            let format = try XCTUnwrap((request["text"] as? [String: Any])?["format"] as? [String: Any])
            let schema = try XCTUnwrap(format["schema"] as? [String: Any])
            let kinds = markerKinds(in: schema)
            XCTAssertEqual(kinds.count, 1)
            XCTAssertEqual(Set(kinds.first ?? []), ["dot", "circle", "arrow"])
            try assertStrictObjects(schema)
        }
    }

    private func markerKinds(in value: Any) -> [[String]] {
        if let object = value as? [String: Any] {
            if let kind = object["kind"] as? [String: Any], let values = kind["enum"] as? [String] { return [values] }
            return object.values.flatMap { markerKinds(in: $0) }
        }
        if let array = value as? [Any] { return array.flatMap { markerKinds(in: $0) } }
        return []
    }

    func testGroundingIsBoundToNewPhotoAndRequiresAMarkerExactlyWhenFound() throws {
        let result = MendGrounding(photoID: "new-photo", found: true, message: "The latch is visible.", marker: arrow)
        let decoded = try MendClient.decodeGroundingResponse(envelope(result), expectedPhotoID: "new-photo")
        XCTAssertTrue(decoded.found)
        XCTAssertEqual(decoded.marker, arrow)
        XCTAssertThrowsError(try MendClient.decodeGroundingResponse(envelope(result), expectedPhotoID: photoID))
        XCTAssertThrowsError(try MendGrounding(photoID: photoID, found: true, message: "Visible", marker: nil).validated(expectedPhotoID: photoID))
        XCTAssertThrowsError(try MendGrounding(photoID: photoID, found: false, message: "Unclear", marker: circle).validated(expectedPhotoID: photoID))
        XCTAssertNoThrow(try MendGrounding(photoID: photoID, found: false, message: "Show the latch straight on.", marker: nil).validated(expectedPhotoID: photoID))
    }

    func testRequestContainsOnlyExplicitPhotoAndProblemWithStrictPrivateSchema() throws {
        let problem = "The cover won't stay shut."
        let body = try MendClient.requestBody(jpeg: jpeg, photoID: photoID, problem: problem)
        XCTAssertEqual(body["model"] as? String, "muse-wonder-1.0")
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertNil(body["api_key"])
        XCTAssertNil(body["previous_response_id"])
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 1)
        let content = try XCTUnwrap(input[0]["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 2)
        let contextString = try XCTUnwrap(content[0]["text"] as? String)
        let context = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contextString.utf8)) as? [String: Any])
        XCTAssertEqual(context["photo_id"] as? String, photoID)
        XCTAssertEqual(context["problem"] as? String, problem)
        XCTAssertEqual(context["user_confirmation_required_before_guide"] as? Bool, true)
        XCTAssertEqual(content[1]["image_url"] as? String, "data:image/jpeg;base64," + jpeg.base64EncodedString())
        let text = try XCTUnwrap(body["text"] as? [String: Any])
        let format = try XCTUnwrap(text["format"] as? [String: Any])
        XCTAssertEqual(format["strict"] as? Bool, true)
        try assertStrictObjects(XCTUnwrap(format["schema"] as? [String: Any]))
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: body))
    }

    func testGroundingRequestNeverReusesOldMarkerOrImage() throws {
        let body = try MendClient.locateRequestBody(jpeg: jpeg, photoID: "new-photo", step: step(marker: circle))
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        let content = try XCTUnwrap(input.first?["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        let context = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(context["photo_id"] as? String, "new-photo")
        XCTAssertEqual(context["step_id"] as? String, "step-1")
        XCTAssertNil(context["marker"])
        XCTAssertNil(context["old_photo_id"])
        XCTAssertEqual(body["store"] as? Bool, false)
    }

    func testInputAndOutputSizeBoundaries() throws {
        XCTAssertThrowsError(try MendClient.requestBody(jpeg: Data([0, 1, 2]), photoID: photoID, problem: ""))
        XCTAssertThrowsError(try MendClient.requestBody(jpeg: jpeg, photoID: " ", problem: ""))
        XCTAssertThrowsError(try MendClient.requestBody(jpeg: jpeg, photoID: photoID, problem: String(repeating: "x", count: 1801)))
        let oversizedPhoto = Data([0xff, 0xd8]) + Data(repeating: 0, count: 8 * 1024 * 1024) + Data([0xff, 0xd9])
        XCTAssertThrowsError(try MendClient.requestBody(jpeg: oversizedPhoto, photoID: photoID, problem: ""))
        XCTAssertThrowsError(try MendClient.decodeResponse(Data(repeating: 32, count: 1024 * 1024 + 1), expectedPhotoID: photoID))
    }

    private func assertStrictObjects(_ schema: [String: Any]) throws {
        if schema["type"] as? String == "object" {
            let properties = try XCTUnwrap(schema["properties"] as? [String: [String: Any]])
            XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
            XCTAssertEqual(Set(schema["required"] as? [String] ?? []), Set(properties.keys))
            for child in properties.values { try assertStrictObjects(child) }
        }
        if let items = schema["items"] as? [String: Any] { try assertStrictObjects(items) }
        for option in schema["anyOf"] as? [[String: Any]] ?? [] { try assertStrictObjects(option) }
    }
}

import UIKit
import XCTest
@testable import Fixi

@MainActor final class MendLiveResearchTests: XCTestCase {
    private let details = MendProjectDetails(make: "Generic", model: "Cabinet hinge", problem: "The door is loose.")

    private func content(_ body: [String: Any]) throws -> [[String: Any]] {
        let messages = try XCTUnwrap(body["input"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1)
        return try XCTUnwrap(messages.first?["content"] as? [[String: Any]])
    }

    private func context(_ content: [[String: Any]]) throws -> [String: Any] {
        let text = try XCTUnwrap(content.first?["text"] as? String)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    func testSourceLookupAttachesExactlyTheProvidedSnapshotAndKeepsWebSearchRequired() throws {
        let photo = MendPhoto(id: "fresh-research-frame", jpeg: Data([0xff, 0xd8, 0xff, 0xd9]), image: UIImage(),
                              source: "Glasses live view", capturedAt: Date())
        let body = try MendResearchClient.requestBody(question: "Find the manual for this hinge.", details: details,
            diagnosis: nil, step: nil, photo: photo)
        let parts = try content(body)
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[0]["type"] as? String, "input_text")
        XCTAssertEqual(parts[1]["type"] as? String, "input_image")
        XCTAssertEqual(parts[1]["image_url"] as? String, "data:image/jpeg;base64," + photo.jpeg.base64EncodedString())
        let context = try context(parts)
        XCTAssertEqual(context["photo_id"] as? String, photo.id)
        XCTAssertEqual(context["question"] as? String, "Find the manual for this hinge.")
        XCTAssertTrue((context["visual_input"] as? String)?.contains("snapshot") == true)
        XCTAssertEqual(body["tool_choice"] as? String, "required")
        XCTAssertEqual((body["tools"] as? [[String: Any]])?.first?["type"] as? String, "web_search")
        XCTAssertEqual(body["store"] as? Bool, false)
    }

    func testNilSnapshotProducesTheSameTextOnlyRequestAsTheDefaultCall() throws {
        let explicit = try MendResearchClient.requestBody(question: "Find the manual.", details: details,
            diagnosis: nil, step: nil, photo: nil)
        let implicit = try MendResearchClient.requestBody(question: "Find the manual.", details: details,
            diagnosis: nil, step: nil)
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: explicit, options: .sortedKeys),
                       try JSONSerialization.data(withJSONObject: implicit, options: .sortedKeys))
        let parts = try content(explicit)
        XCTAssertEqual(parts.count, 1)
        let context = try context(parts)
        XCTAssertNil(context["photo_id"])
        XCTAssertTrue((context["visual_input"] as? String)?.contains("No image") == true)
    }

    func testLiveSourceLookupDoesNotSendOldStepMarkerCoordinates() throws {
        let oldMarker = PhotoMarker(kind: "circle", x: 0.4, y: 0.4, width: 0.1, height: 0.1,
                                   endX: nil, endY: nil, label: "Old target")
        let step = MendStep(id: "one", title: "Check hinge", instruction: "Check the hinge while supporting the door.",
            expectedResult: "The hinge is seated.", caution: "Keep the door supported.", marker: oldMarker)
        let diagnosis = MendDiagnosis(photoID: "old-photo", status: .ready, title: "Loose hinge", summary: "A hinge may be loose.",
            evidence: ["The user reports a loose door."], confidence: .medium, questions: [], tools: [],
            precautions: ["Support the door."], steps: [step])
        let photo = MendPhoto(id: "new-photo", jpeg: Data([0xff, 0xd8, 0xff, 0xd9]), image: UIImage(),
                              source: "Glasses live view", capturedAt: Date())
        let body = try MendResearchClient.requestBody(question: "Find hinge instructions.", details: details,
            diagnosis: diagnosis, step: step, photo: photo)
        let context = try context(content(body))
        XCTAssertEqual(context["photo_id"] as? String, "new-photo")
        XCTAssertNil((context["current_step"] as? [String: Any])?["marker"])
        XCTAssertEqual((context["current_step"] as? [String: Any])?["caution"] as? String, step.caution)
        XCTAssertEqual((context["saved_diagnosis"] as? [String: Any])?["precautions"] as? [String], ["Support the door."])
    }
}

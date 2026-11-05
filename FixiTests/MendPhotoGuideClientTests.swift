import UIKit
import XCTest
@testable import Fixi

@MainActor final class MendPhotoGuideClientTests: XCTestCase {
    private let details = MendProjectDetails(make: "Generic", model: "Cabinet hinge", problem: "Loose door")
    private let dot = PhotoMarker(kind: "dot", x: 0.42, y: 0.58, width: nil, height: nil,
                                  endX: nil, endY: nil, label: "Hinge screw")

    private func step(_ id: String, marker: PhotoMarker? = nil, fresh: Bool = false) -> MendStep {
        MendStep(id: id, title: "Check \(id)", instruction: "Check the visible screw while supporting the door.",
                 expectedResult: "The screw sits flush.", caution: "Support the door.", marker: marker,
                 photoHint: fresh ? "Show the screw clearly." : nil, requiresFreshPhoto: fresh)
    }

    private func photo(_ id: String, time: TimeInterval = 1, source: String = "Photo library",
                       jpeg: Data = Data([0xff, 0xd8, 0xff, 0xd9])) -> MendPhoto {
        MendPhoto(id: id, jpeg: jpeg, image: UIImage(), source: source, capturedAt: Date(timeIntervalSince1970: time))
    }

    private func markerObject(_ marker: PhotoMarker) -> [String: Any] {
        ["kind": marker.kind, "x": marker.x, "y": marker.y,
         "width": marker.width as Any? ?? NSNull(), "height": marker.height as Any? ?? NSNull(),
         "endX": marker.endX as Any? ?? NSNull(), "endY": marker.endY as Any? ?? NSNull(), "label": marker.label]
    }

    private func target(_ id: String, marker: PhotoMarker? = nil) -> [String: Any] {
        ["stepID": id, "marker": markerObject(marker ?? dot)]
    }

    private func envelope(_ object: [String: Any], status: String = "completed") throws -> Data {
        let json = try JSONSerialization.data(withJSONObject: object)
        return try JSONSerialization.data(withJSONObject: ["status": status, "output": [[
            "type": "message", "status": "completed", "role": "assistant",
            "content": [["type": "output_text", "text": String(decoding: json, as: UTF8.self)]]
        ]]])
    }

    private func response(photoID: String, targets: [[String: Any]] = []) throws -> Data {
        try envelope(["photoID": photoID, "targets": targets])
    }

    private func context(_ body: [String: Any]) throws -> [String: Any] {
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        let content = try XCTUnwrap(input.first?["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    func testNewestPhotosCoverOnlyUnresolvedStepsAndPreserveOriginalPixels() async throws {
        let old = photo("old", time: 1), middle = photo("middle", time: 2), newest = photo("new", time: 3)
        let steps = [step("first"), step("second"), step("third")]
        var requests: [[String: Any]] = []
        let client = MendPhotoGuideClient { body, key in
            XCTAssertEqual(key, "offline-key")
            let context = try self.context(body); requests.append(context)
            switch context["photo_id"] as? String {
            case "new": return try self.response(photoID: newest.id, targets: [self.target("second")])
            case "middle": return try self.response(photoID: middle.id, targets: [self.target("third"), self.target("first")])
            default: XCTFail("Older photos are unnecessary after every step is covered"); return Data()
            }
        }
        let references = try await client.locate(details: details, steps: steps, photos: [old, newest, middle], key: "offline-key")
        XCTAssertEqual(requests.compactMap { $0["photo_id"] as? String }, ["new", "middle"])
        XCTAssertEqual((requests[1]["steps"] as? [[String: Any]])?.compactMap { $0["step_id"] as? String }, ["first", "third"])
        XCTAssertEqual(references.map(\.stepID), ["first", "second", "third"])
        XCTAssertEqual(references.map { $0.photo.id }, ["middle", "new", "middle"])
        XCTAssertTrue(references[0].photo.image === middle.image)
        XCTAssertTrue(references[1].photo.image === newest.image)
        XCTAssertEqual(references[1].photo.jpeg, newest.jpeg)
        XCTAssertEqual(references[1].photo.capturedAt, newest.capturedAt)
        XCTAssertEqual(references[1].marker, dot)
    }

    func testEveryRetainedPhotoIsConsideredWhenEarlierPhotosDecline() async throws {
        let photos = (1...7).map { photo("photo-\($0)", time: Double($0)) }
        var visited: [String] = []
        let client = MendPhotoGuideClient { body, _ in
            let id = try XCTUnwrap(self.context(body)["photo_id"] as? String)
            visited.append(id)
            return try self.response(photoID: id, targets: id == "photo-1" ? [self.target("one")] : [])
        }
        let references = try await client.locate(details: details, steps: [step("one")], photos: photos, key: "offline-key")
        XCTAssertEqual(visited, (1...7).reversed().map { "photo-\($0)" })
        XCTAssertEqual(references.first?.photo.id, "photo-1")
    }

    func testEqualPhotoDatesHaveStableCallerOrderAndNoMatchIsAnEmptyResult() async throws {
        var visited: [String] = []
        let client = MendPhotoGuideClient { body, _ in
            let id = try XCTUnwrap(self.context(body)["photo_id"] as? String); visited.append(id)
            return try self.response(photoID: id)
        }
        let result = try await client.locate(details: details, steps: [step("one")], photos: [photo("b"), photo("a")], key: "offline-key")
        XCTAssertEqual(visited, ["b", "a"]); XCTAssertTrue(result.isEmpty)
    }

    func testFailuresBetweenUsablePhotosPreserveReferencesAndContinueSearching() async throws {
        let newest = photo("newest", time: 4), oldest = photo("oldest", time: 1)
        var visited: [String] = []
        let client = MendPhotoGuideClient { body, _ in
            let context = try self.context(body)
            let id = try XCTUnwrap(context["photo_id"] as? String); visited.append(id)
            if id != "newest" {
                XCTAssertEqual((context["steps"] as? [[String: Any]])?.compactMap { $0["step_id"] as? String }, ["second"])
            }
            switch id {
            case "newest": return try self.response(photoID: id, targets: [self.target("first")])
            case "malformed": return try self.response(photoID: "wrong-photo", targets: [self.target("second")])
            case "unavailable": throw URLError(.networkConnectionLost)
            case "oldest": return try self.response(photoID: id, targets: [self.target("second")])
            default: XCTFail("Unexpected photo"); return Data()
            }
        }
        let result = try await client.locate(details: details, steps: [step("first"), step("second")],
            photos: [oldest, photo("malformed", time: 3), newest, photo("unavailable", time: 2)], key: "key")
        XCTAssertEqual(visited, ["newest", "malformed", "unavailable", "oldest"])
        XCTAssertEqual(result.map(\.stepID), ["first", "second"])
        XCTAssertEqual(result.map { $0.photo.id }, ["newest", "oldest"])
        XCTAssertTrue(result[0].photo.image === newest.image)
        XCTAssertTrue(result[1].photo.image === oldest.image)
    }

    func testMalformedAndIllustrativePhotosDoNotHideOtherUsableOriginals() async throws {
        let valid = photo("valid", time: 1, source: "Glasses camera")
        let photos = [photo("example", time: 9, source: "Online example"),
                      photo("demo", time: 8, source: "Illustrated example"),
                      photo("broken", time: 7, jpeg: Data("not jpeg".utf8)),
                      photo("conflict", time: 6), photo("conflict", time: 5),
                      photo("bad-date", time: .nan), valid]
        var visited: [String] = []
        let client = MendPhotoGuideClient { body, _ in
            let id = try XCTUnwrap(self.context(body)["photo_id"] as? String); visited.append(id)
            return try self.response(photoID: id, targets: [self.target("one")])
        }
        let result = try await client.locate(details: details, steps: [step("one")], photos: photos, key: "offline-key")
        XCTAssertEqual(visited, ["valid"])
        XCTAssertTrue(try XCTUnwrap(result.first).photo.image === valid.image)
    }

    func testNoStepsOrUsablePhotosMakesNoProviderRequest() async throws {
        var calls = 0
        let client = MendPhotoGuideClient { _, _ in calls += 1; return Data() }
        let noSteps = try await client.locate(details: details, steps: [], photos: [photo("one")], key: "")
        let noPhotos = try await client.locate(details: details, steps: [step("one")], photos: [], key: "")
        let referencesOnly = try await client.locate(details: details, steps: [step("one")],
                                                    photos: [photo("web", source: "Online example")], key: "")
        XCTAssertTrue(noSteps.isEmpty); XCTAssertTrue(noPhotos.isEmpty); XCTAssertTrue(referencesOnly.isEmpty)
        XCTAssertEqual(calls, 0)
    }

    func testRequestUsesOnlyTheOriginalSnapshotAndOmitsOldMarkerCoordinates() throws {
        let original = photo("camera", source: "iPhone camera")
        let uncertain = MendProjectDetails(make: "Generic", model: "Cabinet hinge", problem: "Loose door", suggestedFields: ["model"])
        let body = try MendPhotoGuideClient.requestBody(details: uncertain,
            steps: [step("one", marker: dot), step("fresh", fresh: true)], photo: original)
        XCTAssertEqual(body["model"] as? String, "muse-wonder-1.0")
        XCTAssertEqual(body["store"] as? Bool, false)
        for key in ["tools", "tool_choice", "previous_response_id", "api_key"] { XCTAssertNil(body[key]) }
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        let content = try XCTUnwrap(input.first?["content"] as? [[String: Any]])
        XCTAssertEqual(input.count, 1); XCTAssertEqual(content.count, 2)
        XCTAssertEqual(content[1]["image_url"] as? String, "data:image/jpeg;base64," + original.jpeg.base64EncodedString())
        let context = try context(body)
        XCTAssertEqual(context["photo_id"] as? String, original.id)
        XCTAssertEqual(context["image_kind"] as? String, "retained_original_project_photo")
        XCTAssertEqual(context["suggested_fields"] as? [String], ["model"])
        let steps = try XCTUnwrap(context["steps"] as? [[String: Any]])
        XCTAssertNil(steps[0]["marker"]); XCTAssertNil(steps[0]["photoID"])
        XCTAssertEqual(steps[1]["requires_fresh_photo"] as? Bool, true)
        XCTAssertEqual(steps[1]["caution"] as? String, "Support the door.")
        let instructions = try XCTUnwrap(body["instructions"] as? String)
        XCTAssertTrue(instructions.contains("not the current scene"))
        XCTAssertTrue(instructions.contains("older reference does not fulfill it"))
    }

    func testSchemaRestrictsPhotoAndStepIdentityAndSupportsEveryMarkerKind() throws {
        let body = try MendPhotoGuideClient.requestBody(details: details, steps: [step("one"), step("two")], photo: photo("photo"))
        let format = try XCTUnwrap((body["text"] as? [String: Any])?["format"] as? [String: Any])
        let schema = try XCTUnwrap(format["schema"] as? [String: Any])
        XCTAssertEqual(format["strict"] as? Bool, true)
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        let properties = try XCTUnwrap(schema["properties"] as? [String: [String: Any]])
        XCTAssertEqual(properties["photoID"]?["enum"] as? [String], ["photo"])
        let target = try XCTUnwrap(properties["targets"]?["items"] as? [String: Any])
        let fields = try XCTUnwrap(target["properties"] as? [String: [String: Any]])
        XCTAssertEqual(fields["stepID"]?["enum"] as? [String], ["one", "two"])
        let marker = try XCTUnwrap(fields["marker"])
        let geometry = try XCTUnwrap(marker["properties"] as? [String: [String: Any]])
        XCTAssertEqual(Set(geometry["kind"]?["enum"] as? [String] ?? []), ["dot", "circle", "arrow"])
        XCTAssertEqual(Set(marker["required"] as? [String] ?? []), Set(geometry.keys))
    }

    func testDifferentPhotoUnknownStepAndDuplicateMappingAreRejected() throws {
        let original = photo("original"), steps = [step("one"), step("two")]
        for data in [try response(photoID: "another", targets: [target("one")]),
                     try response(photoID: original.id, targets: [target("other")]),
                     try response(photoID: original.id, targets: [target("one"), target("one")])] {
            XCTAssertThrowsError(try MendPhotoGuideClient.decodeResponse(data, steps: steps, photo: original))
        }
    }

    func testUnexpectedKeysMissingNullsAndActionPayloadsAreRejected() throws {
        let original = photo("original")
        var injected = target("one"); injected["action"] = "completeStep"
        var incompleteMarker = markerObject(dot); incompleteMarker.removeValue(forKey: "width")
        var injectedMarker = markerObject(dot); injectedMarker["completed"] = true
        for object: [String: Any] in [
            ["photoID": original.id, "targets": [target("one")], "completed": true],
            ["photoID": original.id, "targets": [injected]],
            ["photoID": original.id, "targets": [["stepID": "one", "marker": incompleteMarker]]],
            ["photoID": original.id, "targets": [["stepID": "one", "marker": injectedMarker]]],
            ["photoID": original.id, "targets": [["stepID": "one", "marker": NSNull()]]]
        ] {
            XCTAssertThrowsError(try MendPhotoGuideClient.decodeResponse(envelope(object), steps: [step("one")], photo: original))
        }
        let function = try JSONSerialization.data(withJSONObject: ["status": "completed", "output": [["type": "function_call", "name": "completeStep"]]])
        XCTAssertThrowsError(try MendPhotoGuideClient.decodeResponse(function, steps: [step("one")], photo: original))
    }

    func testInvalidGeometryAndIncompleteResponsesNeverCreateReferences() throws {
        let original = photo("original")
        let invalid = [
            PhotoMarker(kind: "dot", x: 1.01, y: 0.5, width: nil, height: nil, endX: nil, endY: nil, label: "Screw"),
            PhotoMarker(kind: "dot", x: 0.5, y: 0.5, width: 0.1, height: nil, endX: nil, endY: nil, label: "Screw"),
            PhotoMarker(kind: "circle", x: 0.9, y: 0.1, width: 0.2, height: 0.2, endX: nil, endY: nil, label: "Hinge"),
            PhotoMarker(kind: "arrow", x: 0.3, y: 0.3, width: nil, height: nil, endX: 0.3, endY: 0.3, label: "Screw"),
            PhotoMarker(kind: "unknown", x: 0.5, y: 0.5, width: nil, height: nil, endX: nil, endY: nil, label: "Screw")
        ]
        for marker in invalid {
            XCTAssertThrowsError(try MendPhotoGuideClient.decodeResponse(response(photoID: original.id, targets: [target("one", marker: marker)]),
                                                                        steps: [step("one")], photo: original))
        }
        XCTAssertThrowsError(try MendPhotoGuideClient.decodeResponse(envelope(["photoID": original.id, "targets": []], status: "incomplete"),
                                                                    steps: [step("one")], photo: original))
        XCTAssertThrowsError(try MendPhotoGuideClient.decodeResponse(Data(repeating: 32, count: 128 * 1024 + 1),
                                                                    steps: [step("one")], photo: original))
    }

    func testBadChecklistOrKeyIsRejectedBeforeAnyProviderRequest() async {
        var calls = 0
        let client = MendPhotoGuideClient { _, _ in calls += 1; return Data() }
        for (steps, key) in [([step("duplicate"), step("duplicate")], "key"), ([step("one")], " ")] {
            do {
                _ = try await client.locate(details: details, steps: steps, photos: [photo("photo")], key: key)
                XCTFail("Invalid input must fail")
            } catch {}
        }
        XCTAssertEqual(calls, 0)
    }

    func testCancellationStopsBeforeCheckingAnotherPhoto() async {
        var calls = 0
        let client = MendPhotoGuideClient { _, _ in calls += 1; throw CancellationError() }
        do {
            _ = try await client.locate(details: details, steps: [step("one")], photos: [photo("one"), photo("two")], key: "key")
            XCTFail("Cancellation must propagate")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(calls, 1)
    }

    func testOutputLimitRetriesOnlyTheSamePhotoAndUnresolvedStepsOnce() async throws {
        let incomplete = try JSONSerialization.data(withJSONObject: ["status": "incomplete",
            "incomplete_details": ["reason": "max_output_tokens"], "output": []])
        var bodies: [[String: Any]] = []
        let client = MendPhotoGuideClient { body, _ in
            bodies.append(body)
            return bodies.count == 1 ? incomplete : try self.response(photoID: "photo", targets: [self.target("one")])
        }
        let result = try await client.locate(details: details, steps: [step("one")], photos: [photo("photo")], key: "key")
        XCTAssertEqual(result.count, 1); XCTAssertEqual(bodies.count, 2)
        XCTAssertEqual(bodies[0]["max_output_tokens"] as? Int, 4096)
        XCTAssertEqual(bodies[1]["max_output_tokens"] as? Int, 8192)
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: bodies[0]["input"]!, options: .sortedKeys),
                       try JSONSerialization.data(withJSONObject: bodies[1]["input"]!, options: .sortedKeys))
    }
}

import XCTest
import UIKit
@testable import Fixi

@MainActor final class MendPhotoHistoryTests: XCTestCase {
    func testAllSuppliedSetupPhotosSurvivePlanCreationAndResetWithTheProject() async throws {
        let model = fixture()
        defer { model.cancelStepVisualPreparation(); model.cancel() }
        model.acceptPhoto(try photo(.red).jpeg, source: "Photo library")
        await until { !model.busy }
        let first = try XCTUnwrap(model.photo)
        model.acceptPhoto(try photo(.blue).jpeg, source: "iPhone camera")
        await until { !model.busy }
        let second = try XCTUnwrap(model.photo)
        XCTAssertEqual(model.projectPhotos.map(\.id), [first.id, second.id])
        var reviewed: [String] = []
        model.findPhotoGuides = { _, _, photos, _ in reviewed = photos.map(\.id); return [] }
        model.reviewProject(); model.confirmProject()
        await until { !model.busy && !reviewed.isEmpty }
        XCTAssertEqual(Set(reviewed), Set([first.id, second.id]))
        XCTAssertEqual(model.projectPhotos.count, 2)
        XCTAssertTrue(model.checkedSteps.isEmpty)
        model.newRepair()
        XCTAssertTrue(model.projectPhotos.isEmpty)
        XCTAssertNil(model.stepPhotoReference)
    }

    func testSubmittedLiveQuestionPhotoSurvivesClosingHelp() async throws {
        let model = fixture()
        defer { model.cancelStepVisualPreparation(); model.cancel() }
        model.stage = .confirmation; model.confirmProject()
        await until { !model.busy }
        model.confirmParts(); model.openChecklistStep(0)
        let still = try photo(.green, source: "Glasses live view")
        model.liveViewEnabled = true
        model.acquireLivePhoto = { still }
        model.answerLiveQuestion = { _, _, _, _, _, supplied, _ in
            XCTAssertEqual(supplied.id, still.id)
            return MendLiveAnswer(photoID: supplied.id, answer: "The latch is visible.", marker: nil)
        }
        model.askQuestion("Which part is the latch?")
        await until { !model.voiceReplyPending }
        XCTAssertEqual(model.projectPhotos.map(\.id), [still.id])
        model.clearStepHelp()
        XCTAssertNil(model.liveAnswerPhoto)
        XCTAssertEqual(model.projectPhotos.map(\.id), [still.id])
        model.pauseForBackground()
        XCTAssertEqual(model.projectPhotos.map(\.id), [still.id])
        model.newRepair()
        XCTAssertTrue(model.projectPhotos.isEmpty)
    }

    func testDistinctCaptureIDsSurviveIdenticalPixelsWhileDuplicateIDsAndStaleImportsAreIgnored() throws {
        let model = fixture()
        defer { model.cancelStepVisualPreparation(); model.cancel() }
        let still = try photo(.orange)
        model.rememberProjectPhoto(still)
        model.rememberProjectPhoto(still)
        let second = MendPhoto(id: UUID().uuidString, jpeg: still.jpeg, image: still.image,
                               source: still.source, capturedAt: Date())
        model.rememberProjectPhoto(second)
        XCTAssertEqual(model.projectPhotos.map(\.id), [still.id, second.id], "Each capture ID remains available for markers, even with identical pixels")
        model.acceptPhoto(try photo(.purple).jpeg, source: "Photo library", expectedToken: "stale")
        XCTAssertEqual(model.projectPhotos.map(\.id), [still.id, second.id])
        model.stepExample = MendExampleImage(image: still.image,
            source: MendSource(title: "Online reference", url: URL(string: "https://example.org/reference")!), caption: "Reference")
        XCTAssertEqual(model.projectPhotos.map(\.id), [still.id, second.id], "Downloaded examples never become submitted photo evidence")
    }

    private func fixture() -> FixiModel {
        let model = FixiModel(configurationError: "Offline photo history test")
        model.modelKey = { "offline-meta" }; model.openAIKey = { "" }
        model.findPhotoGuides = { _, _, _, _ in [] }
        model.locateStepCameraTarget = { photo, _, _ in
            MendGrounding(photoID: photo.id, found: false, message: "No target in this offline view.", marker: nil)
        }
        model.findExampleImage = { _, _, _ in nil }
        model.prepareAudioOutputForSelection = {}
        model.project = MendProjectDetails(make: "Unknown", model: "Cabinet hinge", problem: "Loose latch")
        model.collectProject = { details, _, _, _, _ in MendIntakeResult(details: details, prompt: "Ready.") }
        model.checkParts = { _, _, _, supplied, _ in MendPartsReview(photoID: supplied?.id, issues: []) }
        model.createPlan = { _, _, id, _ in
            MendDiagnosis(photoID: id, status: .ready, title: "Inspect the latch", summary: "Inspect the latch.",
                evidence: ["Loose latch reported"], confidence: .medium, questions: [], tools: [], precautions: [],
                steps: [MendStep(id: "latch", title: "Find the latch", instruction: "Find the latch on the door.",
                                 expectedResult: "The latch is identified.", caution: nil, marker: nil)], parts: [])
        }
        return model
    }

    private func photo(_ color: UIColor, source: String = "Photo library") throws -> MendPhoto {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 160, height: 120)).image { context in
            color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 160, height: 120))
        }
        return try MendPhoto.make(data: XCTUnwrap(image.jpegData(compressionQuality: 0.8)), source: source)
    }

    private func until(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<1000 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Timed out waiting for photo history", file: file, line: line)
    }
}

import UIKit
import XCTest
@testable import Fixi

@MainActor final class MendStepExampleTests: XCTestCase {
    func testChecklistCreationPrefetchesAllStepsWithAtMostTwoOnlineRequests() async {
        var pending: [String: CheckedContinuation<MendExampleImage?, Never>] = [:]
        var started: [String] = []
        let model = await fixture(stepCount: 4) { model in
            model.findExampleImage = { _, step, _ in
                started.append(step.id)
                return await withCheckedContinuation { pending[step.id] = $0 }
            }
        }
        defer { cleanup(model) }
        await until { pending.count == 2 }
        XCTAssertEqual(model.stage, .parts)
        XCTAssertEqual(started, ["step-1", "step-2"])
        XCTAssertEqual(model.stepVisualPreparation.lookups.count, 2)
        XCTAssertEqual(model.stepVisualPreparation.pendingSteps.count, 2)
        assertQuiet(model)
        pending.removeValue(forKey: "step-1")?.resume(returning: example("one"))
        await until { started.count == 3 }
        XCTAssertEqual(model.stepVisualPreparation.lookups.count, 2)
        pending.removeValue(forKey: "step-2")?.resume(returning: nil)
        await until { started.count == 4 }
        XCTAssertEqual(model.stepVisualPreparation.lookups.count, 2)
        for value in pending.values { value.resume(returning: nil) }; pending = [:]
        await until { model.stepVisualPreparation.isIdle }
        XCTAssertNil(model.stepExample, "Prefetch must not replace the Parts screen")
        model.confirmParts(); model.openChecklistStep(0)
        XCTAssertEqual(model.stepExample?.caption, "one")
        XCTAssertTrue(model.checkedSteps.isEmpty)
    }

    func testNavigationKeepsOtherStepSearchesAndPublishesOnlySelectedStep() async {
        var pending: [String: CheckedContinuation<MendExampleImage?, Never>] = [:]
        var calls = 0
        let model = await fixture { model in
            model.findExampleImage = { _, step, _ in
                calls += 1; return await withCheckedContinuation { pending[step.id] = $0 }
            }
        }
        defer { cleanup(model) }
        await until { pending.count == 2 }
        model.confirmParts(); model.openChecklistStep(0); model.openChecklistStep(1)
        pending.removeValue(forKey: "step-1")?.resume(returning: example("first"))
        await until { model.stepVisualPreparation.examples["step-1"] != nil }
        XCTAssertNil(model.stepExample)
        pending.removeValue(forKey: "step-2")?.resume(returning: example("second"))
        await until { model.stepExample != nil }
        XCTAssertEqual(model.stepExample?.caption, "second")
        model.backToChecklist(); XCTAssertNil(model.stepExample)
        model.openChecklistStep(0)
        XCTAssertEqual(model.stepExample?.caption, "first"); XCTAssertEqual(calls, 2)
    }

    func testValidPlanPhotoTargetsAvoidPhotoAndOnlineSearches() async {
        let model = await fixture(withPhoto: true, withTarget: true) { model in
            model.findPhotoGuides = { _, _, _, _ in XCTFail("Plan already binds every target"); return [] }
            model.findExampleImage = { _, _, _ in XCTFail("Known target needs no example"); return nil }
        }
        defer { cleanup(model) }
        XCTAssertTrue(model.stepVisualPreparation.isIdle)
        XCTAssertEqual(model.stepVisualPreparation.references.count, 2)
        model.confirmParts(); model.openChecklistStep(0)
        XCTAssertEqual(model.stepPhotoReference?.photo.id, model.photo?.id)
        XCTAssertTrue(model.hasStepPhotoTarget); XCTAssertNil(model.stepExample)
    }

    func testAllSuppliedPhotosAreCheckedBeforeOnlyUnmatchedStepsUseOnlineExamples() async {
        let older = photo("older"), newer = photo("newer", color: .green)
        var photoRequest: CheckedContinuation<[MendStepPhotoReference], Never>?
        var searched: [String] = []
        let model = await fixture { model in
            model.projectPhotos = [older, newer]
            model.findPhotoGuides = { _, steps, photos, key in
                XCTAssertEqual(steps.map(\.id), ["step-1", "step-2"])
                XCTAssertEqual(photos.map(\.id), ["older", "newer"])
                XCTAssertEqual(key, "offline-plan-key")
                return await withCheckedContinuation { photoRequest = $0 }
            }
            model.findExampleImage = { _, step, _ in searched.append(step.id); return self.example("online") }
        }
        defer { cleanup(model) }
        await until { photoRequest != nil }
        XCTAssertTrue(searched.isEmpty)
        photoRequest?.resume(returning: [.init(stepID: "step-1", photo: older, marker: marker)]); photoRequest = nil
        await until { model.stepVisualPreparation.isIdle }
        XCTAssertEqual(searched, ["step-2"])
        model.confirmParts(); model.openChecklistStep(0)
        XCTAssertEqual(model.stepPhotoReference?.photo.id, "older"); XCTAssertNil(model.stepExample)
        model.openChecklistStep(1)
        XCTAssertNil(model.stepPhotoReference); XCTAssertEqual(model.stepExample?.caption, "online")
    }

    func testPhotoResultsMustBindKnownStepOriginalPixelsAndValidCoordinates() async {
        let original = photo("original"), foreign = photo("foreign")
        let altered = photo("original", color: .red)
        let invalid = PhotoMarker(kind: "dot", x: 1.4, y: 0.5, width: nil, height: nil, endX: nil, endY: nil, label: "Bad")
        var searched: [String] = []
        let model = await fixture(stepCount: 3) { model in
            model.projectPhotos = [original]
            model.findPhotoGuides = { _, _, _, _ in [
                .init(stepID: "unknown-step", photo: original, marker: self.marker),
                .init(stepID: "step-1", photo: foreign, marker: self.marker),
                .init(stepID: "step-2", photo: original, marker: invalid),
                .init(stepID: "step-3", photo: altered, marker: self.marker)
            ] }
            model.findExampleImage = { _, step, _ in searched.append(step.id); return nil }
        }
        defer { cleanup(model) }
        await until { model.stepVisualPreparation.isIdle }
        XCTAssertEqual(Set(searched), ["step-1", "step-2"])
        let bound = model.stepVisualPreparation.references["step-3"]
        XCTAssertTrue(bound?.photo.image === original.image)
        XCTAssertEqual(bound?.photo.jpeg, original.jpeg)
    }

    func testNewPhotoUpgradesAnOnlineExampleWithoutRefetchingAcceptedExamples() async {
        var onlineCalls = 0, photoCalls = 0
        let model = await fixture { model in
            model.findExampleImage = { _, _, _ in onlineCalls += 1; return self.example("reference") }
            model.findPhotoGuides = { _, steps, photos, _ in
                photoCalls += 1
                return [.init(stepID: steps[0].id, photo: photos[0], marker: self.marker)]
            }
        }
        defer { cleanup(model) }
        await until { model.stepVisualPreparation.isIdle }
        model.confirmParts(); model.openChecklistStep(0)
        XCTAssertNotNil(model.stepExample)
        model.rememberProjectPhoto(photo("new-view"))
        await until { model.stepVisualPreparation.isIdle }
        XCTAssertEqual(photoCalls, 1); XCTAssertEqual(onlineCalls, 2)
        XCTAssertEqual(model.stepPhotoReference?.photo.id, "new-view"); XCTAssertNil(model.stepExample)
    }

    func testBackgroundFencesLateResultsAndResumesUnfinishedPreparation() async {
        var pending: CheckedContinuation<MendExampleImage?, Never>?
        var calls = 0
        let model = await fixture(stepCount: 1) { model in
            model.findExampleImage = { _, _, _ in
                calls += 1
                if calls == 1 { return await withCheckedContinuation { pending = $0 } }
                return self.example("fresh")
            }
        }
        defer { cleanup(model) }
        await until { pending != nil }
        model.pauseForBackground()
        pending?.resume(returning: example("late")); pending = nil
        await drain()
        XCTAssertTrue(model.stepVisualPreparation.examples.isEmpty)
        XCTAssertTrue(model.stepVisualPreparation.isIdle); assertQuiet(model)
#if !canImport(MWDATCore)
        XCTAssertEqual(model.glasses.lastCard?.title, "Phone app disconnected")
#endif
        model.resumeFromBackground()
        await until { model.stepVisualPreparation.isIdle }
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(model.stepVisualPreparation.examples["step-1"]?.caption, "fresh")
    }

    func testNewProjectRetiresOutstandingWorkAndAllVisualCaches() async {
        var pending: CheckedContinuation<MendExampleImage?, Never>?
        let model = await fixture(stepCount: 1) { model in
            model.findExampleImage = { _, _, _ in await withCheckedContinuation { pending = $0 } }
        }
        defer { cleanup(model) }
        await until { pending != nil }
        model.newRepair()
        pending?.resume(returning: example("obsolete")); pending = nil
        await drain()
        XCTAssertEqual(model.stage, .welcome); XCTAssertNil(model.stepExample)
        XCTAssertNil(model.stepVisualPreparation.planKey)
        XCTAssertTrue(model.stepVisualPreparation.examples.isEmpty)
    }

    func testFailuresAreSilentAndDoNotAutomaticallyRetry() async {
        var calls = 0
        let model = await fixture(stepCount: 1) { model in
            model.findExampleImage = { _, _, _ in calls += 1; throw MendExampleImageLookupError.limited }
        }
        defer { cleanup(model) }
        await until { model.stepVisualPreparation.isIdle }
        model.confirmParts(); model.openChecklistStep(0)
        let voiceNotice = model.voiceNotice, errorMessage = model.errorMessage
        assertQuiet(model); XCTAssertNil(model.stepVisualStatus)
        model.prepareStepVisuals(); model.loadStepExampleIfNeeded(); model.backToChecklist(); model.openChecklistStep(0)
        XCTAssertEqual(calls, 1)
        model.findExampleImage = { _, _, _ in calls += 1; throw URLError(.notConnectedToInternet) }
        model.perform(.findExample)
        await until { model.stepVisualPreparation.isIdle }
        XCTAssertEqual(calls, 2); assertQuiet(model)
        XCTAssertEqual(model.voiceNotice, voiceNotice); XCTAssertEqual(model.errorMessage, errorMessage)
#if !canImport(MWDATCore)
        XCTAssertFalse(model.glasses.lastCard?.text.localizedCaseInsensitiveContains("example") == true)
        XCTAssertNil(model.glasses.lastCard?.image)
#endif
    }

    func testMissingKeyIsSilentAndAddingKeyAllowsExplicitRetry() async {
        var calls = 0
        let model = await fixture(stepCount: 1) { model in
            model.openAIKey = { "" }
            model.findExampleImage = { _, _, key in calls += 1; XCTAssertEqual(key, "new-offline-key"); return self.example("ready") }
        }
        defer { cleanup(model) }
        model.confirmParts(); model.openChecklistStep(0); model.perform(.findExample)
        assertQuiet(model); XCTAssertEqual(calls, 0)
        XCTAssertTrue(model.stepVisualPreparation.attemptedExamples.isEmpty)
        model.openAIKey = { "new-offline-key" }
        model.perform(.findExample)
        await until { model.stepVisualPreparation.isIdle }
        XCTAssertEqual(calls, 1); XCTAssertEqual(model.stepExample?.caption, "ready")
    }

    func testForcedManualRetrySilentlyReplacesAKnownHighlight() async {
        var pending: CheckedContinuation<MendExampleImage?, Never>?
        let model = await fixture(stepCount: 1, withPhoto: true, withTarget: true) { model in
            model.findExampleImage = { _, _, _ in await withCheckedContinuation { pending = $0 } }
        }
        defer { cleanup(model) }
        model.confirmParts(); model.openChecklistStep(0)
        XCTAssertNotNil(model.stepPhotoReference)
        model.perform(.findExample)
        await until { pending != nil }
        XCTAssertNil(model.stepPhotoReference); XCTAssertTrue(model.stepPhotoManuallySuppressed)
        XCTAssertFalse(model.showsStepCameraPhoto); assertQuiet(model)
        pending?.resume(returning: example("replacement")); pending = nil
        await until { model.stepVisualPreparation.isIdle }
        XCTAssertEqual(model.stepExample?.caption, "replacement"); XCTAssertTrue(model.checkedSteps.isEmpty)
    }

    func testUnrelatedArchivedPhotoCannotRestoreARejectedPlanHighlight() async {
        let model = await fixture(stepCount: 1, withPhoto: true, withTarget: true) { model in
            model.findPhotoGuides = { _, _, _, _ in XCTFail("A rejected step must not be matched by unrelated background photos"); return [] }
            model.findExampleImage = { _, _, _ in self.example("replacement") }
        }
        defer { cleanup(model) }
        model.confirmParts(); model.openChecklistStep(0)
        XCTAssertNotNil(model.stepPhotoReference)
        model.perform(.findExample)
        await until { model.stepVisualPreparation.isIdle }
        XCTAssertEqual(model.stepExample?.caption, "replacement")
        model.rememberProjectPhoto(photo("unrelated-live-question", color: .green))
        await until { model.stepVisualPreparation.isIdle }
        model.backToChecklist(); model.openChecklistStep(0)
        XCTAssertTrue(model.stepPhotoManuallySuppressed)
        XCTAssertNil(model.stepPhotoReference)
        XCTAssertNil(model.stepVisualPreparation.references["step-1"])
        XCTAssertFalse(model.showsStepCameraPhoto)
        XCTAssertEqual(model.stepExample?.caption, "replacement")
        assertQuiet(model)
    }

    func testOnlyAcceptedForegroundGroundingReleasesTheMatchingStepRejection() async {
        let model = await fixture(withPhoto: true) { model in
            model.findPhotoGuides = { _, steps, photos, _ in steps.map { .init(stepID: $0.id, photo: photos[0], marker: self.marker) } }
            model.findExampleImage = { _, step, _ in self.example(step.id) }
        }
        defer { cleanup(model) }
        await until { model.stepVisualPreparation.isIdle }
        model.confirmParts(); model.openChecklistStep(0); model.perform(.findExample)
        await until { model.stepVisualPreparation.isIdle }
        model.openChecklistStep(1); model.perform(.findExample)
        await until { model.stepVisualPreparation.isIdle }
        XCTAssertEqual(model.stepVisualPreparation.forcedExamples, ["step-1", "step-2"])
        let fresh = photo("foreground-grounding", color: .green)
        model.acceptForegroundStepPhotoTarget(stepID: "step-2", photo: fresh, marker: marker)
        XCTAssertEqual(model.stepVisualPreparation.forcedExamples.count, 2, "Unretained input cannot release an override")
        model.rememberProjectPhoto(fresh, prepare: false)
        model.acceptForegroundStepPhotoTarget(stepID: "step-1", photo: fresh, marker: marker)
        XCTAssertEqual(model.stepVisualPreparation.forcedExamples.count, 2, "Grounding belongs to the current foreground step only")
        let invalid = PhotoMarker(kind: "dot", x: 1.5, y: 0.5, width: nil, height: nil, endX: nil, endY: nil, label: "Invalid")
        model.acceptForegroundStepPhotoTarget(stepID: "step-2", photo: fresh, marker: invalid)
        XCTAssertEqual(model.stepVisualPreparation.forcedExamples.count, 2)
        model.acceptForegroundStepPhotoTarget(stepID: "step-2", photo: fresh, marker: marker)
        model.prepareStepVisuals()
        await until { model.stepVisualPreparation.isIdle }
        XCTAssertEqual(model.stepVisualPreparation.forcedExamples, ["step-1"])
        XCTAssertEqual(model.stepPhotoReference?.photo.id, fresh.id)
        XCTAssertTrue(model.stepPhotoReference?.photo.image === fresh.image)
        XCTAssertNil(model.stepExample)
        XCTAssertTrue(model.showsStepCameraPhoto)
        model.openChecklistStep(0)
        XCTAssertTrue(model.stepPhotoManuallySuppressed)
        XCTAssertNil(model.stepPhotoReference)
        XCTAssertEqual(model.stepExample?.caption, "step-1")
    }

    func testWatchdogSilentlyRetiresStuckLookupAndRejectsItsLateResult() async {
        var deadline: CheckedContinuation<Void, Never>?
        var response: CheckedContinuation<MendExampleImage?, Never>?
        var calls = 0
        let model = await fixture(stepCount: 1) { model in
            model.waitForExampleImageTimeout = { await withCheckedContinuation { deadline = $0 } }
            model.findExampleImage = { _, _, _ in calls += 1; return await withCheckedContinuation { response = $0 } }
        }
        defer { cleanup(model) }
        await until { deadline != nil && response != nil }
        deadline?.resume(); deadline = nil
        await until { model.stepVisualPreparation.isIdle }
        model.prepareStepVisuals(); XCTAssertEqual(calls, 1); assertQuiet(model)
        response?.resume(returning: example("late")); response = nil
        await drain()
        XCTAssertTrue(model.stepVisualPreparation.examples.isEmpty); assertQuiet(model)
    }

    func testPhotoReviewTimeoutFallsBackToOnlineWithoutPublishingStatus() async {
        var deadline: CheckedContinuation<Void, Never>?
        var photoResponse: CheckedContinuation<[MendStepPhotoReference], Never>?
        var waits = 0, onlineCalls = 0
        let original = photo("original")
        let model = await fixture(stepCount: 1) { model in
            model.projectPhotos = [original]
            model.waitForExampleImageTimeout = {
                waits += 1
                if waits == 1 { await withCheckedContinuation { deadline = $0 } }
                else { try await Task.sleep(for: .seconds(90)) }
            }
            model.findPhotoGuides = { _, _, _, _ in await withCheckedContinuation { photoResponse = $0 } }
            model.findExampleImage = { _, _, _ in onlineCalls += 1; return self.example("online") }
        }
        defer { cleanup(model) }
        await until { deadline != nil && photoResponse != nil }
        deadline?.resume(); deadline = nil
        await until { model.stepVisualPreparation.isIdle }
        XCTAssertEqual(onlineCalls, 1); assertQuiet(model)
        photoResponse?.resume(returning: [.init(stepID: "step-1", photo: original, marker: marker)]); photoResponse = nil
        await drain()
        XCTAssertTrue(model.stepVisualPreparation.references.isEmpty)
        XCTAssertEqual(model.stepVisualPreparation.examples["step-1"]?.caption, "online")
    }

    func testSourceActionsAreOnlyAvailableForTheSelectedOnlineExample() async {
        let model = await fixture { model in model.findExampleImage = { _, step, _ in self.example(step.id) } }
        defer { cleanup(model) }
        await until { model.stepVisualPreparation.isIdle }
        var opened: [URL] = []; model.openExampleURL = { opened.append($0) }
        model.confirmParts(); model.openChecklistStep(0); model.perform(.exampleSource)
        XCTAssertEqual(opened, [example("step-1").source.url])
        model.showParts(); model.perform(.exampleSource)
        XCTAssertNil(model.stepExample); XCTAssertEqual(opened.count, 1)
        model.confirmParts(); model.openChecklistStep(1); model.perform(.exampleSource)
        XCTAssertEqual(opened.last, example("step-2").source.url)
    }

    func testChangedProjectDetailsFenceAnOldResultUntilTheNewPlanIsConfirmed() async {
        var response: CheckedContinuation<MendExampleImage?, Never>?
        let model = await fixture(stepCount: 1) { model in
            model.findExampleImage = { _, _, _ in await withCheckedContinuation { response = $0 } }
        }
        defer { cleanup(model) }
        await until { response != nil }
        model.project.model = "Different cabinet"
        model.prepareStepVisuals()
        response?.resume(returning: example("wrong-project")); response = nil
        await drain()
        XCTAssertTrue(model.stepVisualPreparation.examples.isEmpty)
        XCTAssertTrue(model.stepVisualPreparation.isIdle)
        XCTAssertNil(model.stepExample)
    }

    private func fixture(stepCount: Int = 2, withPhoto: Bool = false, withTarget: Bool = false,
                         configure: (FixiModel) -> Void = { _ in }) async -> FixiModel {
        let model = FixiModel(configurationError: "Offline example test")
        model.modelKey = { "offline-plan-key" }; model.openAIKey = { "offline-image-key" }
        model.prepareAudioOutputForSelection = {}
        model.findPhotoGuides = { _, _, _, _ in [] }
        model.findExampleImage = { _, _, _ in nil }
        model.checkParts = { _, _, _, photo, _ in MendPartsReview(photoID: photo?.id, issues: []) }
        model.project = MendProjectDetails(make: "Acme", model: "Cabinet", problem: "Loose latch")
        configure(model)
        if withPhoto {
            model.collectProject = { current, _, _, _, _ in MendIntakeResult(details: current, prompt: "Ready to review.") }
            model.acceptPhoto(photo("fixture").jpeg, source: "Phone camera")
            await until { !model.busy }
        }
        model.stage = .confirmation
        model.createPlan = { _, _, photoID, _ in
            MendDiagnosis(photoID: photoID, status: .ready, title: "Inspect the latch", summary: "Find the latch.",
                          evidence: ["Reported loose latch"], confidence: .medium, questions: [], tools: [], precautions: [],
                          steps: (1...stepCount).map { i in MendStep(id: "step-\(i)", title: "Latch \(i)", instruction: "Locate latch \(i).", expectedResult: "You can identify the latch.", caution: nil,
                              marker: withTarget ? self.marker : nil, photoHint: nil, requiresFreshPhoto: false) }, parts: [])
        }
        model.confirmProject()
        await until { !model.busy && model.diagnosis != nil }
        return model
    }
    private var marker: PhotoMarker { .init(kind: "dot", x: 0.5, y: 0.5, width: nil, height: nil, endX: nil, endY: nil, label: "Latch") }
    private func photo(_ id: String, color: UIColor = .blue) -> MendPhoto {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 240), format: format).image { context in
            color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 320, height: 240))
        }
        return .init(id: id, jpeg: image.jpegData(compressionQuality: 0.8)!, image: image, source: "Phone camera", capturedAt: Date())
    }
    private func example(_ caption: String) -> MendExampleImage {
        MendExampleImage(image: PhotoCanvas.examplePhoto(), source: MendSource(title: "Source", url: URL(string: "https://example.org/\(caption)")!), caption: caption)
    }
    private func assertQuiet(_ model: FixiModel, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(model.exampleImageLoading, file: file, line: line)
        XCTAssertNil(model.exampleImageNotice, file: file, line: line)
    }
    private func cleanup(_ model: FixiModel) { model.cancelStepVisualPreparation(clearCache: true); model.cancel() }
    private func drain() async { for _ in 0..<40 { await Task.yield() } }
    private func until(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<1000 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Timed out waiting for visual preparation", file: file, line: line)
    }
}

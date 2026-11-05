import UIKit
import XCTest
@testable import Fixi

@MainActor final class MendStepCameraGuidanceTests: XCTestCase {
    func testMissingVisualUsesOneFreshStillQuietlyAndArchivesOriginalPixels() async {
        let (model, voice) = await fixture()
        defer { cleanup(model) }
        var captureCount = 0, locateCount = 0
        var captured: MendPhoto?
        model.acquireLivePhoto = {
            captureCount += 1
            XCTAssertFalse(model.liveFrameAcquiring, "Automatic capture must not publish Looking status")
            let photo = self.photo("fresh"); captured = photo; return photo
        }
        model.locateStepCameraTarget = { photo, step, key in
            locateCount += 1
            XCTAssertEqual(step.id, "step-1"); XCTAssertEqual(key, "offline-key")
            return self.grounding(photo)
        }
        let spoken = voice.spoken
        model.helpText = "Existing help"; model.progressDetail = "Existing progress"
        model.liveViewEnabled = true; model.openChecklistStep(0)
        // Entry clears prior help by design; the camera attempt must not change it again.
        let help = model.helpText, progress = model.progressDetail
        await until { model.stepPhotoReference != nil }
        XCTAssertEqual(captureCount, 1); XCTAssertEqual(locateCount, 1)
        XCTAssertTrue(model.stepPhotoReference?.photo.image === captured?.image)
        XCTAssertEqual(model.stepPhotoReference?.photo.jpeg, captured?.jpeg)
        XCTAssertEqual(model.stepPhotoReference?.photo.id, "fresh")
        XCTAssertEqual(model.currentMarker, marker)
        XCTAssertEqual(model.projectPhotos.map(\.id), ["fresh"])
        XCTAssertEqual(model.helpText, help); XCTAssertEqual(model.progressDetail, progress)
        XCTAssertEqual(voice.spoken, spoken)
        assertQuiet(model)
        for _ in 0..<4 { model.syncDisplay(); model.prepareStepVisuals() }
        await drain()
        XCTAssertEqual(captureCount, 1); XCTAssertTrue(model.checkedSteps.isEmpty)
    }

    func testQueuedNarrationAndOutputHoldFinishBeforeAcquiringTheStill() async {
        let (model, voice) = await fixture()
        defer { cleanup(model) }
        var captures = 0, finishedSpeakingAt: Date?
        model.acquireLivePhoto = {
            captures += 1
            XCTAssertFalse(voice.isSpeaking); XCTAssertFalse(model.liveOutputHeld)
            let photo = self.photo("after-narration")
            XCTAssertGreaterThanOrEqual(photo.capturedAt, finishedSpeakingAt ?? .distantFuture)
            return photo
        }
        model.locateStepCameraTarget = { photo, _, _ in self.grounding(photo) }
        voice.isActive = true
        voice.onSay = {
            Task { @MainActor in
                voice.isSpeaking = true; model.liveOutputHeld = true; model.syncDisplay()
            }
        }
        model.liveViewEnabled = true; model.openChecklistStep(0)
        await until { voice.isSpeaking }
        try? await Task.sleep(for: .milliseconds(220))
        XCTAssertEqual(captures, 0)
        XCTAssertEqual(model.stepCameraGuidance.phase, .waiting)
        finishedSpeakingAt = Date(); voice.isSpeaking = false; model.liveOutputHeld = false; model.syncDisplay()
        await until { model.stepPhotoReference != nil }
        XCTAssertEqual(captures, 1); assertQuiet(model)
    }

    func testFreshButPreEntryFrameIsRejectedWithoutRetryOrVisibleError() async {
        let (model, _) = await fixture()
        defer { cleanup(model) }
        let priorScene = photo("previous-step")
        var captures = 0, locates = 0
        model.acquireLivePhoto = { captures += 1; return priorScene }
        model.locateStepCameraTarget = { photo, _, _ in locates += 1; return self.grounding(photo) }
        model.liveViewEnabled = true; model.openChecklistStep(0)
        await until { model.stepCameraGuidance.attempted && model.stepCameraGuidance.task == nil }
        XCTAssertEqual(captures, 1); XCTAssertEqual(locates, 0)
        XCTAssertTrue(model.projectPhotos.isEmpty); XCTAssertNil(model.stepPhotoReference)
        model.syncDisplay(); await drain(); XCTAssertEqual(captures, 1)
        assertQuiet(model)
    }

    func testPausedCameraExistingVisualsAndExplicitExampleChoiceNeverStartCapture() async {
        for mode in ["paused", "example", "photo", "forced", "no-key"] {
            let (model, _) = await fixture()
            var captures = 0
            model.acquireLivePhoto = { captures += 1; return self.photo("unexpected") }
            let first = "step-1"
            if mode == "example" { model.stepVisualPreparation.examples[first] = example }
            if mode == "photo" {
                let original = photo("known")
                model.projectPhotos = [original]
                model.stepVisualPreparation.references[first] = .init(stepID: first, photo: original, marker: marker)
            }
            if mode == "forced" { model.stepVisualPreparation.forcedExamples.insert(first) }
            if mode == "no-key" { model.modelKey = { "" } }
            model.liveViewEnabled = mode != "paused"; model.openChecklistStep(0)
            try? await Task.sleep(for: .milliseconds(200))
            XCTAssertEqual(captures, 0, mode)
            XCTAssertEqual(model.liveViewEnabled, mode != "paused")
            if mode == "forced" { XCTAssertTrue(model.stepPhotoManuallySuppressed) }
            cleanup(model)
        }
    }

    func testSystemAndForegroundWorkHoldsDoNotStartAutomaticCapture() async {
        for mode in ["settings", "background", "question", "capture", "speech", "acquiring", "permission"] {
            let (model, voice) = await fixture()
            var captures = 0
            model.acquireLivePhoto = { captures += 1; return self.photo("unexpected") }
            model.openChecklistStep(0)
            model.liveViewEnabled = true
            switch mode {
            case "settings": model.presentation = .settings
            case "background": model.appActive = false
            case "question": model.voiceReplyPending = true
            case "capture": voice.captureSuspended = true
            case "speech": model.heardSpeech = true; voice.isReceivingSpeech = true
            case "acquiring": model.liveFrameAcquiring = true
            default: model.livePermissionHandoff = true
            }
            model.syncDisplay(); await drain()
            XCTAssertEqual(captures, 0, mode); XCTAssertNil(model.stepCameraGuidance.task)
            cleanup(model)
        }
    }

    func testStepNavigationRetiresLateResponseAndNewVisitCanCaptureOnce() async {
        let (model, _) = await fixture()
        defer { cleanup(model) }
        var firstResponse: CheckedContinuation<MendGrounding, Never>?
        var firstPhoto: MendPhoto?, requests: [String] = []
        var captures = 0
        model.acquireLivePhoto = { captures += 1; return self.photo("capture-\(captures)") }
        model.locateStepCameraTarget = { photo, step, _ in
            requests.append(step.id)
            if requests.count == 1 {
                firstPhoto = photo
                return await withCheckedContinuation { firstResponse = $0 }
            }
            return self.grounding(photo)
        }
        model.liveViewEnabled = true; model.openChecklistStep(0)
        await until { firstResponse != nil }
        model.openChecklistStep(1)
        firstResponse?.resume(returning: grounding(firstPhoto!)); firstResponse = nil
        await until { model.stepPhotoReference?.stepID == "step-2" }
        XCTAssertNil(model.stepVisualPreparation.references["step-1"])
        XCTAssertEqual(model.stepPhotoReference?.photo.id, "capture-2")
        model.backToChecklist(); model.openChecklistStep(0)
        await until { model.stepPhotoReference?.stepID == "step-1" }
        XCTAssertEqual(requests, ["step-1", "step-2", "step-1"])
        XCTAssertEqual(captures, 3)
    }

    func testPauseCompletionProjectChangeAndManualCancellationRejectLateResults() async {
        for mode in ["pause", "complete", "project", "manual", "background"] {
            let (model, _) = await fixture()
            var response: CheckedContinuation<MendGrounding, Never>?, captured: MendPhoto?
            model.acquireLivePhoto = { let photo = self.photo("pending"); captured = photo; return photo }
            model.locateStepCameraTarget = { photo, step, _ in
                if step.id == "step-2" {
                    return .init(photoID: photo.id, found: false, message: "No target", marker: nil)
                }
                return await withCheckedContinuation { response = $0 }
            }
            model.liveViewEnabled = true; model.openChecklistStep(0)
            await until { response != nil }
            let retiredAttemptID = model.stepCameraGuidance.id
            let retiredPhoto = captured!
            switch mode {
            case "pause": model.pauseLiveView()
            case "complete": model.checkAndAdvance()
            case "project": model.newRepair()
            case "background": model.pauseForBackground()
            default: model.cancelStepCameraGuidance()
            }
            response?.resume(returning: grounding(retiredPhoto)); response = nil
            await drain()
            XCTAssertNil(model.stepPhotoReference, mode)
            XCTAssertNil(model.stepVisualPreparation.references["step-1"], mode)
            XCTAssertNotEqual(model.stepCameraGuidance.id, retiredAttemptID, mode)
            if mode == "complete" {
                XCTAssertEqual(model.stage, .guide)
                XCTAssertEqual(model.currentStep?.id, "step-2")
                XCTAssertTrue(model.checkedSteps.contains("step-1"))
                // Completing this step may already start the next step's own
                // quiet attempt; only the retired result must be rejected.
            } else { XCTAssertNil(model.stepCameraGuidance.task, mode) }
            cleanup(model)
        }
    }

    func testExampleOrManualRejectionWinningTheRaceCannotBeOverwritten() async {
        for mode in ["example", "forced"] {
            let (model, _) = await fixture()
            var response: CheckedContinuation<MendGrounding, Never>?, captured: MendPhoto?
            model.acquireLivePhoto = { let photo = self.photo("pending"); captured = photo; return photo }
            model.locateStepCameraTarget = { _, _, _ in await withCheckedContinuation { response = $0 } }
            model.liveViewEnabled = true; model.openChecklistStep(0)
            await until { response != nil }
            if mode == "example" { model.stepVisualPreparation.examples["step-1"] = example; model.prepareStepVisuals() }
            else { model.loadStepExampleIfNeeded(retry: true, force: true) }
            response?.resume(returning: grounding(captured!)); response = nil
            await drain()
            XCTAssertNil(model.stepVisualPreparation.references["step-1"])
            if mode == "example" { XCTAssertEqual(model.stepExample?.caption, example.caption) }
            else { XCTAssertTrue(model.stepPhotoManuallySuppressed); XCTAssertNil(model.stepPhotoReference) }
            cleanup(model)
        }
    }

    func testLateArchiveReviewCannotOverwriteTheAcceptedAutomaticCameraTarget() async {
        let (model, _) = await fixture()
        defer { cleanup(model) }
        let older = photo("older-project-photo")
        model.rememberProjectPhoto(older)
        await until { model.stepVisualPreparation.isIdle }
        var batchReview: CheckedContinuation<[MendStepPhotoReference], Never>?
        model.findPhotoGuides = { _, _, _, _ in await withCheckedContinuation { batchReview = $0 } }
        model.acquireLivePhoto = { self.photo("fresh-camera-photo") }
        model.locateStepCameraTarget = { photo, _, _ in self.grounding(photo) }
        model.liveViewEnabled = true; model.openChecklistStep(0)
        await until { model.stepPhotoReference?.photo.id == "fresh-camera-photo" && batchReview != nil }
        batchReview?.resume(returning: [.init(stepID: "step-1", photo: older, marker: marker)]); batchReview = nil
        await until { model.stepVisualPreparation.isIdle }
        XCTAssertEqual(model.stepPhotoReference?.photo.id, "fresh-camera-photo")
        XCTAssertEqual(model.stepVisualPreparation.references["step-1"]?.photo.id, "fresh-camera-photo")
        assertQuiet(model)
    }

    func testGroundingMustMatchTheCapturedPhotoAndHaveValidGeometry() async {
        for mode in ["wrong-photo", "bad-marker", "decline", "error"] {
            let (model, _) = await fixture()
            model.acquireLivePhoto = { self.photo("captured") }
            model.locateStepCameraTarget = { photo, _, _ in
                if mode == "error" { throw URLError(.timedOut) }
                if mode == "decline" { return .init(photoID: photo.id, found: false, message: "Not visible", marker: nil) }
                let invalid = PhotoMarker(kind: "dot", x: 2, y: 0.4, width: nil, height: nil, endX: nil, endY: nil, label: "Invalid")
                return .init(photoID: mode == "wrong-photo" ? "other" : photo.id, found: true,
                             message: "Target", marker: mode == "bad-marker" ? invalid : self.marker)
            }
            model.liveViewEnabled = true; model.openChecklistStep(0)
            await until { model.stepCameraGuidance.attempted && model.stepCameraGuidance.task == nil }
            XCTAssertNil(model.stepPhotoReference, mode)
            XCTAssertEqual(model.projectPhotos.map(\.id), ["captured"], "Used still remains available to other steps")
            assertQuiet(model); cleanup(model)
        }
    }

    func testTimeoutSilentlyRetiresAttemptAndRejectsAnUncooperativeLateResponse() async {
        let (model, _) = await fixture()
        defer { cleanup(model) }
        var deadline: CheckedContinuation<Void, Never>?, response: CheckedContinuation<MendGrounding, Never>?
        var captured: MendPhoto?, calls = 0
        model.waitForStepCameraGuidanceTimeout = { await withCheckedContinuation { deadline = $0 } }
        model.acquireLivePhoto = { let photo = self.photo("pending"); captured = photo; return photo }
        model.locateStepCameraTarget = { _, _, _ in calls += 1; return await withCheckedContinuation { response = $0 } }
        model.liveViewEnabled = true; model.openChecklistStep(0)
        await until { deadline != nil && response != nil }
        deadline?.resume(); deadline = nil
        await until { model.stepCameraGuidance.task == nil }
        response?.resume(returning: grounding(captured!)); response = nil
        model.syncDisplay(); await drain()
        XCTAssertNil(model.stepPhotoReference); XCTAssertEqual(calls, 1); assertQuiet(model)
    }

    private func fixture() async -> (FixiModel, CameraGuidanceVoice) {
        let voice = CameraGuidanceVoice()
        let model = FixiModel(configurationError: "Offline camera guidance test", voiceSession: voice)
        model.modelKey = { "offline-key" }; model.openAIKey = { "" }
        model.findPhotoGuides = { _, _, _, _ in [] }; model.findExampleImage = { _, _, _ in nil }
        model.locateStepCameraTarget = { photo, _, _ in .init(photoID: photo.id, found: false, message: "No target", marker: nil) }
        model.checkParts = { _, _, _, photo, _ in .init(photoID: photo?.id, issues: []) }
        model.project = .init(make: "Acme", model: "Cabinet", problem: "Loose latch")
        model.stage = .confirmation
        model.createPlan = { _, _, photoID, _ in
            MendDiagnosis(photoID: photoID, status: .ready, title: "Check latch", summary: "Inspect the visible latch.",
                evidence: ["Loose latch reported"], confidence: .medium, questions: [], tools: [], precautions: [],
                steps: (1...2).map { MendStep(id: "step-\($0)", title: "Latch \($0)", instruction: "Locate the latch.",
                    expectedResult: "You can identify it.", caution: nil, marker: nil) }, parts: [])
        }
        model.confirmProject()
        await until { !model.busy && model.diagnosis != nil }
        model.confirmParts()
        return (model, voice)
    }
    private var marker: PhotoMarker { .init(kind: "dot", x: 0.5, y: 0.5, width: nil, height: nil, endX: nil, endY: nil, label: "Latch") }
    private var example: MendExampleImage {
        .init(image: UIImage(), source: .init(title: "Example", url: URL(string: "https://example.org/guide")!), caption: "Latch reference")
    }
    private func photo(_ id: String) -> MendPhoto {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 240), format: format).image { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 320, height: 240))
        }
        return .init(id: id, jpeg: image.jpegData(compressionQuality: 0.8)!, image: image,
                     source: "Glasses live view", capturedAt: Date())
    }
    private func grounding(_ photo: MendPhoto) -> MendGrounding {
        .init(photoID: photo.id, found: true, message: "Visible latch", marker: marker)
    }
    private func assertQuiet(_ model: FixiModel, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(model.busy, file: file, line: line)
        XCTAssertFalse(model.liveFrameAcquiring, file: file, line: line)
        XCTAssertFalse(model.exampleImageLoading, file: file, line: line)
        XCTAssertNil(model.exampleImageNotice, file: file, line: line)
        XCTAssertNil(model.errorMessage, file: file, line: line)
        XCTAssertNil(model.presentation, file: file, line: line)
    }
    private func cleanup(_ model: FixiModel) {
        model.cancelStepCameraGuidance(); model.liveViewEnabled = false
        model.cancelStepVisualPreparation(clearCache: true); model.cancelVoiceReply(); model.cancel()
    }
    private func drain() async { for _ in 0..<40 { await Task.yield() } }
    private func until(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<2000 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Timed out waiting for quiet camera guidance", file: file, line: line)
    }
}

@MainActor private final class CameraGuidanceVoice: ConversationVoiceSession {
    var isActive = false
    var isConnecting = false
    var isMuted = false
    var isSpeaking = false
    var isReceivingSpeech = false
    var captureSuspended = false
    var status = "Offline voice"
    var inputTranscript = ""
    var outputTranscript = ""
    var error: String?
    var conversationContext = ""
    var onDelegation: ((String, String) -> Void)?
    var onFailure: ((String) -> Void)?
    var onNotice: ((String) -> Void)?
    var onStateChange: (() -> Void)?
    var onUserSpeechStarted: (() -> Void)?
    var onWillSpeak: (() async throws -> Void)?
    var onDidFinishSpeaking: (() -> Void)?
    var onSay: (() -> Void)?
    var spoken: [String] = []
    func start(apiKey: String, context: String) async throws { isActive = true }
    func stop() async { isActive = false }
    func mute() { isMuted = true }
    func unmute() { isMuted = false }
    func setOutputEnabled(_ enabled: Bool) {}
    func interruptPlayback() { isSpeaking = false }
    func sendContext(_ text: String) { conversationContext = text }
    func sayResult(_ text: String, delegationID: String?) { spoken.append(text); onSay?() }
    func setCaptureSuspended(_ suspended: Bool) { captureSuspended = suspended }
}

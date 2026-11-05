import AVFoundation
import UIKit
import XCTest
@testable import Fixi

@MainActor final class MendLiveViewTests: XCTestCase {
    func testEachQuestionUsesANewSnapshotAndKeepsItsOwnAnnotation() async throws {
        let (model, _) = fixture()
        defer { cleanUp(model) }
        let first = try photo(.red), second = try photo(.blue)
        var acquisitions = 0, submitted: [MendPhoto] = []
        model.liveViewEnabled = true
        model.acquireLivePhoto = { acquisitions += 1; return acquisitions == 1 ? first : second }
        model.answerLiveQuestion = { _, _, _, _, _, image, _ in
            submitted.append(image)
            return MendLiveAnswer(photoID: image.id, answer: "The visible screw is here.", marker: self.marker)
        }
        model.askQuestion("Which screw is this?")
        await until { !model.voiceReplyPending && model.liveAnswer != nil }
        XCTAssertEqual(model.liveAnswerPhoto?.id, first.id)
        XCTAssertEqual(model.liveAnswer?.photoID, first.id)
        model.askQuestion("And this one?")
        await until { !model.voiceReplyPending && model.liveAnswerPhoto?.id == second.id }
        XCTAssertEqual(acquisitions, 2)
        XCTAssertEqual(submitted.map(\.id), [first.id, second.id])
        XCTAssertEqual(submitted.map(\.jpeg), [first.jpeg, second.jpeg])
        XCTAssertEqual(model.liveAnswer?.photoID, second.id)
        XCTAssertNotNil(model.liveAnswerImage)
        XCTAssertTrue(model.checkedSteps.isEmpty)
    }

    func testStaleFrameIsRejectedBeforeAnyQuestionServiceReceivesIt() async throws {
        let (model, _) = fixture()
        defer { cleanUp(model) }
        let stale = try photo(.red, capturedAt: Date().addingTimeInterval(-30))
        var submissions = 0
        model.liveViewEnabled = true
        model.acquireLivePhoto = { stale }
        model.answerLiveQuestion = { _, _, _, _, _, image, _ in
            submissions += 1
            return MendLiveAnswer(photoID: image.id, answer: "Unexpected stale view", marker: nil)
        }
        model.askQuestion("What am I pointing at?")
        await until { !model.voiceReplyPending }
        XCTAssertEqual(submissions, 0)
        XCTAssertNil(model.liveAnswer); XCTAssertNil(model.liveAnswerPhoto)
        XCTAssertTrue(model.lastAnswer?.contains("too old") == true)
    }

    func testPauseWhileAcquiringDiscardsTheFrameWithoutSubmittingIt() async throws {
        let (model, _) = fixture()
        defer { cleanUp(model) }
        let image = try photo(.red)
        var acquisition: CheckedContinuation<MendPhoto, Never>?
        var submissions = 0
        model.liveViewEnabled = true
        model.acquireLivePhoto = { await withCheckedContinuation { acquisition = $0 } }
        model.answerLiveQuestion = { _, _, _, _, _, image, _ in
            submissions += 1
            return MendLiveAnswer(photoID: image.id, answer: "Obsolete view", marker: nil)
        }
        model.askQuestion("Which part is this?")
        await until { acquisition != nil }
        XCTAssertTrue(model.liveFrameAcquiring)
        model.pauseLiveView()
        acquisition?.resume(returning: image); acquisition = nil
        await until { !model.liveFrameAcquiring }
        XCTAssertFalse(model.liveViewEnabled); XCTAssertFalse(model.voiceReplyPending)
        XCTAssertEqual(submissions, 0)
        XCTAssertNil(model.liveAnswer); XCTAssertNil(model.liveAnswerPhoto)
    }

    func testChangingStepsRejectsALateVisualAnswerWithoutCheckingEitherStep() async throws {
        let (model, _) = fixture()
        defer { cleanUp(model) }
        await prepareGuide(model)
        let image = try photo(.blue)
        var answer: CheckedContinuation<MendLiveAnswer, Never>?
        model.liveViewEnabled = true
        model.acquireLivePhoto = { image }
        model.answerLiveQuestion = { _, _, _, step, _, _, _ in
            XCTAssertEqual(step?.id, "support")
            return await withCheckedContinuation { answer = $0 }
        }
        model.askQuestion("Where do I support this?")
        await until { answer != nil }
        model.openChecklistStep(1)
        answer?.resume(returning: MendLiveAnswer(photoID: image.id, answer: "Old step answer", marker: marker))
        answer = nil
        await drain()
        XCTAssertEqual(model.currentStep?.id, "tighten")
        XCTAssertNil(model.liveAnswer); XCTAssertNil(model.lastAnswer)
        XCTAssertTrue(model.checkedSteps.isEmpty)
    }

    func testPauseAfterSubmissionLetsTheFrozenSnapshotAnswerFinish() async throws {
        let (model, _) = fixture()
        defer { cleanUp(model) }
        let image = try photo(.red)
        var answer: CheckedContinuation<MendLiveAnswer, Never>?
        var acquisitions = 0
        model.liveViewEnabled = true
        model.acquireLivePhoto = { acquisitions += 1; return image }
        model.answerLiveQuestion = { _, _, _, _, _, submitted, _ in
            XCTAssertEqual(submitted.id, image.id)
            return await withCheckedContinuation { answer = $0 }
        }
        model.askQuestion("Which screw is this?")
        await until { answer != nil }
        model.pauseLiveView()
        XCTAssertFalse(model.liveViewEnabled)
        answer?.resume(returning: MendLiveAnswer(photoID: image.id, answer: "The mounting screw.", marker: marker))
        answer = nil
        await until { !model.voiceReplyPending }
        XCTAssertEqual(model.lastAnswer, "The mounting screw.")
        XCTAssertEqual(model.liveAnswerPhoto?.id, image.id)
        XCTAssertEqual(model.liveAnswer?.photoID, image.id)
        XCTAssertEqual(acquisitions, 1)
        XCTAssertTrue(model.checkedSteps.isEmpty)
    }

    func testNewRepairRejectsALateVisualAnswerAndClearsItsPhoto() async throws {
        let (model, _) = fixture()
        defer { cleanUp(model) }
        let image = try photo(.red)
        var answer: CheckedContinuation<MendLiveAnswer, Never>?
        model.liveViewEnabled = true
        model.acquireLivePhoto = { image }
        model.answerLiveQuestion = { _, _, _, _, _, _, _ in await withCheckedContinuation { answer = $0 } }
        model.askQuestion("Which part is this?")
        await until { answer != nil }
        model.newRepair()
        answer?.resume(returning: MendLiveAnswer(photoID: image.id, answer: "Previous repair answer", marker: marker))
        answer = nil
        await drain()
        XCTAssertEqual(model.stage, .welcome)
        XCTAssertTrue(model.liveViewEnabled, "An active conversation keeps the user's camera choice across projects")
        XCTAssertNil(model.liveAnswer); XCTAssertNil(model.liveAnswerPhoto); XCTAssertNil(model.lastAnswer)
        XCTAssertTrue(model.project.make.isEmpty)
        let newImage = try photo(.blue)
        var newSubmissions = 0
        model.acquireLivePhoto = { newImage }
        model.collectProject = { _, text, jpeg, photoID, _ in
            newSubmissions += 1
            XCTAssertEqual(text.trimmingCharacters(in: .whitespacesAndNewlines), "how do I restart this")
            XCTAssertEqual(jpeg, newImage.jpeg); XCTAssertEqual(photoID, newImage.id)
            XCTAssertNotEqual(photoID, image.id)
            return MendIntakeResult(details: MendProjectDetails(make: "Apple", model: "MacBook Pro", problem: "Restart the computer", suggestedFields: ["make", "model"]), prompt: "Confirm the details.")
        }
        model.receiveVoice("how do I restart this", delegationID: "next-project-first-question")
        await until { !model.busy && model.stage == .confirmation }
        XCTAssertEqual(newSubmissions, 1)
        XCTAssertEqual(model.photo?.id, newImage.id)
        XCTAssertTrue(model.liveViewEnabled)
        XCTAssertNil(model.confirmedProject); XCTAssertNil(model.diagnosis)
    }

    func testMismatchedPhotoAndInvalidMarkerNeverBecomeDisplayedLiveAnswers() async throws {
        let invalid = PhotoMarker(kind: "circle", x: 0.95, y: 0.2, width: 0.5, height: 0.2,
                                  endX: nil, endY: nil, label: "Outside image")
        for wrongPhoto in [true, false] {
            let (model, _) = fixture()
            defer { cleanUp(model) }
            let image = try photo(.blue)
            model.liveViewEnabled = true
            model.acquireLivePhoto = { image }
            model.answerLiveQuestion = { _, _, _, _, _, _, _ in
                MendLiveAnswer(photoID: wrongPhoto ? "another-photo" : image.id,
                               answer: "Do not display this response", marker: wrongPhoto ? self.marker : invalid)
            }
            model.askQuestion("Which part?")
            await until { !model.voiceReplyPending }
            XCTAssertNil(model.liveAnswer); XCTAssertNil(model.liveAnswerPhoto)
            XCTAssertNotEqual(model.lastAnswer, "Do not display this response")
            XCTAssertNotNil(model.voiceNotice)
        }
    }

    func testSourceLookupReceivesTheFreshSnapshotFromThatQuestion() async throws {
        let (model, _) = fixture()
        defer { cleanUp(model) }
        let image = try photo(.blue)
        var submitted: MendPhoto?
        model.liveViewEnabled = true
        model.acquireLivePhoto = { image }
        model.researchQuestion = { text, _, _, _, photo, _ in
            XCTAssertEqual(text, "Look up this hinge")
            submitted = photo
            return MendResearchAnswer(text: "The model label is needed to find its manual.", sources: [])
        }
        model.askQuestion("Look up this hinge", research: true)
        await until { !model.voiceReplyPending }
        XCTAssertEqual(submitted?.id, image.id); XCTAssertEqual(submitted?.jpeg, image.jpeg)
        XCTAssertEqual(model.lastAnswer, "The model label is needed to find its manual.")
        XCTAssertTrue(model.checkedSteps.isEmpty)
    }

    func testLiveIntakeUsesExactCapturedPhotoAndStillRequiresConfirmation() async throws {
        let (model, _) = fixture()
        defer { cleanUp(model) }
        model.project = MendProjectDetails(); model.stage = .capture
        let image = try photo(.red)
        let guessed = MendProjectDetails(make: "Apple", model: "MacBook Pro", problem: "Cannot restart",
                                        suggestedFields: ["make", "model"])
        var submissions = 0, plans = 0
        model.liveViewEnabled = true
        model.acquireLivePhoto = { image }
        model.collectProject = { _, text, jpeg, photoID, _ in
            submissions += 1
            XCTAssertEqual(text.trimmingCharacters(in: .whitespacesAndNewlines), "I cannot restart this")
            XCTAssertEqual(jpeg, image.jpeg); XCTAssertEqual(photoID, image.id)
            return MendIntakeResult(details: guessed, prompt: "Confirm the suggested details.")
        }
        model.createPlan = { _, _, id, _ in plans += 1; return self.plan(photoID: id) }
        model.collectDetails(text: "I cannot restart this")
        await until { !model.busy }
        XCTAssertEqual(submissions, 1); XCTAssertEqual(plans, 0)
        XCTAssertEqual(model.stage, .confirmation)
        XCTAssertEqual(model.project, guessed)
        XCTAssertEqual(model.photo?.id, image.id); XCTAssertEqual(model.photo?.jpeg, image.jpeg)
        XCTAssertNil(model.confirmedProject); XCTAssertNil(model.diagnosis)
        XCTAssertTrue(model.checkedSteps.isEmpty)
    }

    func testPausingDuringIntakeAcquisitionContinuesWithSpokenDetailsOnly() async throws {
        let (model, _) = fixture()
        defer { cleanUp(model) }
        model.project = MendProjectDetails(); model.stage = .capture
        let image = try photo(.blue)
        var acquisition: CheckedContinuation<MendPhoto, Never>?
        var submissions = 0
        model.liveViewEnabled = true
        model.acquireLivePhoto = { await withCheckedContinuation { acquisition = $0 } }
        model.collectProject = { _, text, jpeg, photoID, _ in
            submissions += 1
            XCTAssertTrue(text.contains("MacBook Pro"))
            XCTAssertNil(jpeg); XCTAssertNil(photoID)
            return MendIntakeResult(details: MendProjectDetails(make: "Apple", model: "MacBook Pro", problem: "Cannot restart"),
                                    prompt: "Confirm the details.")
        }
        model.collectDetails(text: "My MacBook Pro cannot restart")
        await until { acquisition != nil }
        model.pauseLiveView()
        acquisition?.resume(returning: image); acquisition = nil
        await until { !model.busy }
        XCTAssertEqual(submissions, 1)
        XCTAssertNil(model.photo)
        XCTAssertEqual(model.stage, .confirmation)
        XCTAssertNil(model.confirmedProject); XCTAssertNil(model.diagnosis)
        XCTAssertFalse(model.liveViewEnabled)
    }

    func testExplicitStillPhotoIntakeIsNotReplacedByLiveView() async throws {
        let (model, _) = fixture()
        defer { cleanUp(model) }
        model.project = MendProjectDetails(); model.stage = .capture
        let explicit = try photo(.red), unwantedLive = try photo(.blue)
        var acquisitions = 0, submissions = 0
        var submittedJPEG: Data?, submittedID: String?
        model.liveViewEnabled = true
        model.acquireLivePhoto = { acquisitions += 1; return unwantedLive }
        model.collectProject = { _, _, jpeg, photoID, _ in
            submissions += 1; submittedJPEG = jpeg; submittedID = photoID
            return MendIntakeResult(details: MendProjectDetails(make: "Unknown", model: "Cabinet hinge", problem: "Loose door"),
                                    prompt: "Confirm the details.")
        }
        model.acceptPhoto(explicit.jpeg, source: "Explicit still fixture")
        await until { !model.busy }
        XCTAssertEqual(acquisitions, 0, "A chosen or manually captured photo must remain the intake evidence")
        XCTAssertEqual(submissions, 1)
        XCTAssertEqual(model.photo?.source, "Explicit still fixture")
        XCTAssertEqual(submittedJPEG, model.photo?.jpeg)
        XCTAssertEqual(submittedID, model.photo?.id)
        XCTAssertNotEqual(submittedID, unwantedLive.id)
        XCTAssertEqual(model.stage, .confirmation)
        XCTAssertNil(model.confirmedProject); XCTAssertNil(model.diagnosis)
    }

#if !canImport(MWDATCore)
    func testGlassesStartupPreparesCameraBeforeListeningAndSpeaksTheOriginalOpening() async throws {
        let (model, voice) = startupFixture()
        defer { cleanUp(model) }
        var events: [String] = []
        model.glasses.prepareConversationCameraOperation = {
            events.append("camera permission")
            XCTAssertTrue(model.liveViewEnabled, "Visual intent must exist before any microphone callback")
            XCTAssertFalse(voice.isActive)
        }
        voice.startOperation = {
            events.append("microphone")
            XCTAssertTrue(model.liveViewEnabled)
            XCTAssertEqual(model.glasses.prepareConversationCameraCount, 1)
        }
        model.startVoice()
        XCTAssertTrue(model.voiceStarting)
        XCTAssertTrue(model.liveViewEnabled)
        await until { !model.voiceStarting && voice.isActive }
        XCTAssertEqual(events, ["camera permission", "microphone"])
        XCTAssertEqual(voice.startCalls, 1)
        XCTAssertEqual(voice.spoken, ["What should we work on today? Tell me the details and show me the project so I can create your step-by-step guide."])
        XCTAssertEqual(model.stage, .capture)
        XCTAssertEqual(voice.listeningMode, .continuous)
        XCTAssertFalse(voice.requiresAddress)
        XCTAssertTrue(model.voiceInputIsOpen)
        XCTAssertFalse(model.availableActions.contains { $0.id == .talk || $0.id == .focusListening })
        await until { model.glasses.streaming }
        XCTAssertTrue(model.liveViewEnabled)
    }

    func testFirstRestartQuestionUsesAutomaticCameraContextBeforeVoiceStartupReturns() async throws {
        let (model, voice) = startupFixture()
        defer { cleanUp(model) }
        let image = try photo(.blue)
        var acquisitions = 0, submissions = 0, plans = 0
        model.acquireLivePhoto = { acquisitions += 1; return image }
        model.collectProject = { current, text, jpeg, photoID, _ in
            submissions += 1
            XCTAssertTrue(current.make.isEmpty); XCTAssertTrue(current.model.isEmpty)
            XCTAssertEqual(text.trimmingCharacters(in: .whitespacesAndNewlines), "how do I restart this")
            XCTAssertEqual(jpeg, image.jpeg); XCTAssertEqual(photoID, image.id)
            return MendIntakeResult(details: MendProjectDetails(make: "Apple", model: "MacBook Pro", problem: "Restart the computer", suggestedFields: ["make", "model"]), prompt: "Is this your MacBook Pro?")
        }
        model.createPlan = { _, _, id, _ in plans += 1; return self.plan(photoID: id) }
        // Native recognition may deliver its first final before start() returns.
        // The app must already have requested visual context at that point.
        voice.startOperation = {
            XCTAssertTrue(model.liveViewEnabled)
            voice.isReceivingSpeech = true
            voice.onUserSpeechStarted?()
            voice.isReceivingSpeech = false
            voice.onStateChange?()
            voice.onDelegation?("early-restart-question", "how do I restart this")
        }
        model.startVoice()
        await until { !model.voiceStarting && !model.busy && model.stage == .confirmation }
        XCTAssertEqual(acquisitions, 1); XCTAssertEqual(submissions, 1); XCTAssertEqual(plans, 0)
        XCTAssertEqual(model.photo?.id, image.id); XCTAssertEqual(model.photo?.jpeg, image.jpeg)
        XCTAssertEqual(model.project.make, "Apple"); XCTAssertEqual(model.project.model, "MacBook Pro")
        XCTAssertEqual(model.project.problem, "Restart the computer")
        XCTAssertNil(model.confirmedProject); XCTAssertNil(model.diagnosis)
        XCTAssertTrue(model.voiceInputIsOpen, "Finishing intake must leave the microphone open")
        XCTAssertTrue(model.liveViewEnabled)
    }

    func testFailedAutomaticSnapshotDoesNotPassAnOlderPhotoAsTheCurrentView() async throws {
        let (model, voice) = startupFixture()
        defer { cleanUp(model) }
        model.startVoice()
        await until { !model.voiceStarting && voice.isActive }
        let oldImage = try photo(.red)
        model.collectProject = { _, _, jpeg, photoID, _ in
            XCTAssertNotNil(jpeg); XCTAssertNotNil(photoID)
            return MendIntakeResult(details: MendProjectDetails(), prompt: "Tell me what you want to work on.")
        }
        model.acceptPhoto(oldImage.jpeg, source: "Previously selected photo")
        await until { !model.busy && model.photo != nil }
        XCTAssertNotNil(model.photo, "Seed the saved photo through the real photo intake path")
        var submissions = 0
        model.acquireLivePhoto = { throw MendError.message("No current camera frame") }
        model.collectProject = { _, text, jpeg, photoID, _ in
            submissions += 1
            XCTAssertTrue(text.contains("MacBook Pro"))
            XCTAssertNil(jpeg, "A failed live snapshot cannot silently substitute an older saved image")
            XCTAssertNil(photoID)
            return MendIntakeResult(details: MendProjectDetails(make: "Apple", model: "MacBook Pro", problem: "Cannot restart"), prompt: "Confirm the details.")
        }
        voice.onDelegation?("no-current-frame", "My MacBook Pro cannot restart")
        await until { !model.busy && model.stage == .confirmation }
        XCTAssertEqual(submissions, 1)
        XCTAssertEqual(model.liveViewNotice, "No fresh view. Using what you said.")
        XCTAssertTrue(model.voiceInputIsOpen)
        XCTAssertNil(model.confirmedProject); XCTAssertNil(model.diagnosis)
    }

    func testCameraPermissionFailureKeepsVoiceOpenAndReportsMissingVisualContext() async {
        let (model, voice) = startupFixture()
        defer { cleanUp(model) }
        model.glasses.prepareConversationCameraOperation = {
            throw MendError.message("Camera permission denied in offline fixture")
        }
        model.startVoice()
        await until { !model.voiceStarting && voice.isActive }
        XCTAssertEqual(voice.startCalls, 1)
        XCTAssertTrue(model.voiceInputIsOpen)
        XCTAssertFalse(model.liveViewEnabled)
        XCTAssertFalse(model.glasses.streaming)
        XCTAssertTrue(model.liveViewNotice?.contains("Camera permission denied") == true)
        XCTAssertEqual(voice.spoken.last, FixiModel.openingPrompt)
        XCTAssertNil(model.photo)
    }

    func testEndingVoiceDuringCameraPermissionPreventsLateMicrophoneOrCameraStartup() async {
        let (model, voice) = startupFixture()
        defer { cleanUp(model) }
        var permission: CheckedContinuation<Void, Never>?
        model.glasses.prepareConversationCameraOperation = {
            await withCheckedContinuation { permission = $0 }
        }
        model.startVoice()
        await until { permission != nil }
        XCTAssertTrue(model.voiceStarting)
        XCTAssertEqual(voice.startCalls, 0)
        model.endVoice()
        await until { !model.voiceStopping }
        permission?.resume(); permission = nil
        await drain()
        XCTAssertEqual(voice.startCalls, 0)
        XCTAssertFalse(voice.isActive)
        XCTAssertFalse(model.voiceStarting)
        XCTAssertFalse(model.liveViewEnabled)
        XCTAssertFalse(model.glasses.streaming)
        XCTAssertNil(model.liveCameraLoop)
        XCTAssertTrue(voice.spoken.isEmpty)
    }

    func testMutingAndPausingCameraRemainIndependentAfterAutomaticStartup() async throws {
        let (model, voice) = startupFixture()
        defer { cleanUp(model) }
        model.startVoice()
        await until { !model.voiceStarting && model.glasses.streaming }
        model.perform(.muteMic)
        XCTAssertTrue(voice.isMuted)
        XCTAssertTrue(model.liveViewEnabled)
        XCTAssertTrue(model.glasses.streaming)
        XCTAssertTrue(voice.isActive)
        model.glasses.onAction?(MendActionID.unmuteMic.rawValue)
        XCTAssertFalse(voice.isMuted)
        XCTAssertTrue(model.voiceInputIsOpen)
        model.glasses.onAction?(MendActionID.pauseLiveView.rawValue)
        XCTAssertFalse(model.liveViewEnabled)
        XCTAssertFalse(model.glasses.streaming)
        XCTAssertTrue(model.voiceInputIsOpen)
        let connections = model.glasses.connectionRequests.count
        let muteChanges = voice.muteChanges
        var cameraRequests = 0
        model.acquireLivePhoto = { cameraRequests += 1; return try self.photo(.red) }
        model.collectProject = { _, text, jpeg, photoID, _ in
            XCTAssertTrue(text.contains("MacBook Pro"))
            XCTAssertNil(jpeg); XCTAssertNil(photoID)
            return MendIntakeResult(details: MendProjectDetails(make: "Apple", model: "MacBook Pro", problem: "Cannot restart"), prompt: "Confirm the details.")
        }
        voice.onUserSpeechStarted?()
        voice.onDelegation?("after-camera-pause", "My MacBook Pro cannot restart")
        await until { !model.busy && model.stage == .confirmation }
        let prepare = try XCTUnwrap(voice.onWillSpeak)
        try await prepare()
        voice.onDidFinishSpeaking?()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(cameraRequests, 0, "A user-paused camera must stay paused on later questions")
        XCTAssertEqual(model.glasses.connectionRequests.count, connections)
        XCTAssertEqual(voice.muteChanges, muteChanges)
        XCTAssertFalse(model.liveViewEnabled); XCTAssertFalse(model.glasses.streaming)
        XCTAssertTrue(model.voiceInputIsOpen)
        XCTAssertNil(model.photo)
    }

    private func startupFixture() -> (FixiModel, LiveViewTestVoice) {
        let (model, voice) = fixture()
        model.stage = .welcome; model.project = MendProjectDetails()
        voice.isActive = false
        model.glasses.registered = true; model.glasses.available = true
        return (model, voice)
    }

    func testNormalBackgroundClearsFramesAndRequiresLiveViewToBeEnabledAgain() async throws {
        let (model, _) = fixture()
        defer { cleanUp(model) }
        let image = try photo(.blue)
        model.glasses.registered = true; model.glasses.available = true
        model.startLiveView()
        await until { model.glasses.streaming }
        model.glasses.deliverLiveFrame(image.image)
        XCTAssertNotNil(model.glasses.livePhoto())
        model.pauseForBackground()
        XCTAssertFalse(model.appActive); XCTAssertFalse(model.liveViewEnabled)
        XCTAssertFalse(model.glasses.streaming)
        XCTAssertNil(model.glasses.preview); XCTAssertNil(model.glasses.liveFrameReceivedAt)
        model.glasses.deliverLiveFrame(image.image)
        XCTAssertNil(model.glasses.livePhoto(), "A late frame cannot repopulate the backgrounded view")
        await until { !model.voiceStopping }
        let connections = model.glasses.connectionRequests.count
        model.resumeFromBackground()
        // Cross a camera-loop interval so an old scheduled iteration can run.
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(model.appActive)
        XCTAssertFalse(model.liveViewEnabled); XCTAssertFalse(model.glasses.streaming)
        XCTAssertNil(model.liveCameraLoop)
        XCTAssertEqual(model.glasses.connectionRequests.count, connections)
    }

    func testPermissionHandoffPreservesIntentButCannotAttachOrAcceptFramesUntilForeground() async throws {
        let (model, voice) = fixture()
        defer { cleanUp(model) }
        let image = try photo(.red)
        model.glasses.registered = true; model.glasses.available = true
        model.glasses.requestingCameraPermission = true
        model.glasses.connect()
        model.startLiveView()
        let stops = model.glasses.stopCameraCount
        model.pauseForBackground()
        XCTAssertTrue(model.livePermissionHandoff)
        XCTAssertTrue(model.liveViewEnabled); XCTAssertTrue(model.appActive)
        XCTAssertTrue(model.glasses.requestingCameraPermission)
        XCTAssertTrue(voice.isActive)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(model.glasses.requestingCameraPermission, "The live loop must not cancel the external permission request")
        XCTAssertEqual(model.glasses.stopCameraCount, stops)
        // Permission/session completion arrives while the external app is still visible.
        model.glasses.requestingCameraPermission = false
        model.glasses.connect()
        model.glasses.deliverLiveFrame(image.image)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(model.glasses.streaming)
        XCTAssertNil(model.glasses.preview); XCTAssertNil(model.glasses.liveFrameReceivedAt)
        XCTAssertNil(model.glasses.livePhoto())
        model.resumeFromBackground()
        await until { model.glasses.streaming }
        XCTAssertFalse(model.livePermissionHandoff)
        XCTAssertTrue(model.liveViewEnabled); XCTAssertTrue(voice.isActive)
        model.glasses.deliverLiveFrame(image.image)
        XCTAssertNotNil(model.glasses.livePhoto())
    }

    func testSpeechHooksStopTheCameraAndIdleRestartsItWithoutChangingMicrophoneMute() async throws {
        let (model, voice) = fixture()
        defer { cleanUp(model) }
        model.glasses.registered = true; model.glasses.available = true
        model.startLiveView()
        await until { model.glasses.streaming }
        voice.isMuted = true; voice.isSpeaking = true
        let prepare = try XCTUnwrap(voice.onWillSpeak)
        try await prepare()
        XCTAssertFalse(model.glasses.streaming); XCTAssertTrue(model.liveOutputHeld)
        XCTAssertTrue(voice.isMuted); XCTAssertEqual(voice.muteChanges, 0)
        voice.isSpeaking = false
        let finish = try XCTUnwrap(voice.onDidFinishSpeaking)
        finish()
        await until { model.glasses.streaming }
        XCTAssertFalse(model.liveOutputHeld)
        XCTAssertTrue(voice.isMuted); XCTAssertEqual(voice.muteChanges, 0)
        model.pauseLiveView()
        XCTAssertFalse(model.glasses.streaming)
        XCTAssertTrue(voice.isActive); XCTAssertTrue(voice.isMuted)
        XCTAssertEqual(voice.muteChanges, 0)
    }

    func testCameraSnapshotRejectsExpiredFramesAndClearsOnStop() async throws {
        let (model, _) = fixture()
        defer { cleanUp(model) }
        let image = try photo(.blue)
        model.glasses.registered = true; model.glasses.available = true
        model.glasses.connect()
        model.glasses.deliverLiveFrame(image.image, receivedAt: Date().addingTimeInterval(-5))
        XCTAssertNil(model.glasses.livePhoto())
        let receivedAt = Date()
        model.glasses.deliverLiveFrame(image.image, receivedAt: receivedAt)
        let snapshot = try XCTUnwrap(model.glasses.livePhoto())
        XCTAssertEqual(snapshot.capturedAt, receivedAt)
        model.glasses.stopCamera()
        XCTAssertNil(model.glasses.livePhoto()); XCTAssertNil(model.glasses.liveFrameReceivedAt)
    }
#endif

    private var marker: PhotoMarker {
        PhotoMarker(kind: "circle", x: 0.35, y: 0.35, width: 0.15, height: 0.15,
                    endX: nil, endY: nil, label: "Screw")
    }
    private func fixture() -> (FixiModel, LiveViewTestVoice) {
        let voice = LiveViewTestVoice()
        let output = AudioOutputMonitor(readRoute: {
            .init(name: "Offline glasses", portTypes: [.bluetoothA2DP], volume: 0.5)
        }, activateRouteSelection: {}, deactivateRouteSelection: {})
        let model = FixiModel(configurationError: "Offline live-view test", voiceSession: voice, audioOutput: output)
        model.prepareAudioOutputForSelection = {}
        model.modelKey = { "offline-meta" }; model.openAIKey = { "offline-openai" }
        model.findPhotoGuides = { _, _, _, _ in [] }
        model.locateStepCameraTarget = { photo, _, _ in
            MendGrounding(photoID: photo.id, found: false, message: "No target in this offline view.", marker: nil)
        }
        model.findExampleImage = { _, _, _ in nil }
        model.stage = .confirmation
        model.project = MendProjectDetails(make: "Unknown", model: "Cabinet hinge", problem: "Loose door")
        model.collectProject = { _, _, _, _, _ in XCTFail("Unexpected intake request"); throw MendError.message("No fixture") }
        model.createPlan = { _, _, _, _ in XCTFail("Unexpected plan request"); throw MendError.message("No fixture") }
        model.answerRepairQuestion = { _, _, _, _, _, _ in XCTFail("Unexpected text-only question"); throw MendError.message("No fixture") }
        model.answerLiveQuestion = { _, _, _, _, _, _, _ in XCTFail("Unexpected live question"); throw MendError.message("No fixture") }
        model.researchQuestion = { _, _, _, _, _, _ in XCTFail("Unexpected research question"); throw MendError.message("No fixture") }
        model.checkParts = { _, _, _, photo, _ in MendPartsReview(photoID: photo?.id, issues: []) }
        return (model, voice)
    }
    private func photo(_ color: UIColor, capturedAt: Date = Date()) throws -> MendPhoto {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 100)).image { context in
            color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        }
        let data = try XCTUnwrap(image.jpegData(compressionQuality: 0.8))
        let photo = try MendPhoto.make(data: data, source: "Offline camera fixture")
        return MendPhoto(id: photo.id, jpeg: photo.jpeg, image: photo.image, source: photo.source, capturedAt: capturedAt)
    }
    private func plan(photoID: String) -> MendDiagnosis {
        MendDiagnosis(photoID: photoID, status: .ready, title: "Secure the hinge", summary: "Support, then tighten.",
                      evidence: ["Reported loose door"], confidence: .medium, questions: [], tools: ["Screwdriver"],
                      precautions: ["Support the door"], steps: [
            MendStep(id: "support", title: "Support the door", instruction: "Hold the door steady.", expectedResult: "The door stays supported.", caution: nil, marker: nil),
            MendStep(id: "tighten", title: "Tighten the screw", instruction: "Turn the screw gently clockwise.", expectedResult: "The screw is snug.", caution: nil, marker: nil)
        ])
    }
    private func prepareGuide(_ model: FixiModel) async {
        model.createPlan = { _, _, id, _ in self.plan(photoID: id) }
        model.confirmProject()
        await until { !model.busy && model.diagnosis != nil }
        model.confirmParts()
        model.startGuide()
    }
    private func cleanUp(_ model: FixiModel) {
        model.pauseLiveView(); model.cancelVoiceReply(); model.cancel()
    }
    private func drain() async { for _ in 0..<30 { await Task.yield() } }
    private func until(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<1000 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Timed out waiting for offline live-view state", file: file, line: line)
    }
}

@MainActor private final class LiveViewTestVoice: ConversationVoiceSession {
    var isActive = true
    var isConnecting = false
    var isMuted = false
    var isSpeaking = false
    var isReceivingSpeech = false
    var captureSuspended = false
    var requiresAddress = false
    var status = "Offline listening"
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
    var muteChanges = 0
    var startCalls = 0
    var startOperation: (@MainActor () async throws -> Void)?
    var spoken: [String] = []
    func start(apiKey: String, context: String) async throws {
        startCalls += 1; isActive = true
        try await startOperation?()
    }
    func stop() async { isActive = false }
    func mute() { muteChanges += 1; isMuted = true }
    func unmute() { muteChanges += 1; isMuted = false }
    func setOutputEnabled(_ enabled: Bool) {}
    func interruptPlayback() { isSpeaking = false }
    func sendContext(_ text: String) { conversationContext = text }
    func sayResult(_ text: String, delegationID: String?) { spoken.append(text); outputTranscript = text }
    func setCaptureSuspended(_ suspended: Bool) { captureSuspended = suspended }
}

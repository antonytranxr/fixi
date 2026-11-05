import XCTest
import UIKit
@testable import Fixi

@MainActor
final class MendProjectFlowTests: XCTestCase {
    private var completeDetails: MendProjectDetails {
        MendProjectDetails(make: "Unknown", model: "Cabinet hinge", problem: "The door is loose.")
    }
    private func makeModel() -> (FixiModel, ProjectFlowVoice) {
        let voice = ProjectFlowVoice()
        let model = FixiModel(configurationError: "Offline flow test", voiceSession: voice)
        model.modelKey = { "offline-test-key" }
        model.openAIKey = { "" }
        model.findPhotoGuides = { _, _, _, _ in [] }
        model.locateStepCameraTarget = { photo, _, _ in
            MendGrounding(photoID: photo.id, found: false, message: "No target in this offline view.", marker: nil)
        }
        model.findExampleImage = { _, _, _ in nil }
        model.collectProject = { _, _, _, _, _ in
            XCTFail("Unexpected intake service call")
            throw MendError.message("No intake fixture")
        }
        model.createPlan = { _, _, _, _ in
            XCTFail("Unexpected plan service call")
            throw MendError.message("No plan fixture")
        }
        model.answerRepairQuestion = { _, _, _, _, _, _ in
            XCTFail("Unexpected question service call")
            throw MendError.message("No question fixture")
        }
        model.checkParts = { _, _, _, photo, _ in MendPartsReview(photoID: photo?.id, issues: []) }
        return (model, voice)
    }
    private func plan(photoID: String) -> MendDiagnosis {
        MendDiagnosis(photoID: photoID, status: .ready, title: "Secure the hinge",
            summary: "A general guide for the reported loose hinge.", evidence: ["User reports a loose door."],
            confidence: .medium, questions: [], tools: ["Screwdriver"], precautions: ["Support the door."], steps: [
                MendStep(id: "support", title: "Support the door", instruction: "Hold the door steady.", expectedResult: "The door is supported.", caution: nil, marker: nil),
                MendStep(id: "tighten", title: "Tighten the screw", instruction: "Turn the loose screw gently clockwise.", expectedResult: "The screw is snug.", caution: "Stop if it spins freely.", marker: nil),
                MendStep(id: "check", title: "Check movement", instruction: "Move the supported door slowly.", expectedResult: "The hinge remains secure.", caution: nil, marker: nil)
            ])
    }
    private func waitUntil(_ message: String, _ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<500 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for \(message)", file: file, line: line)
    }
    private func drainTasks() async { for _ in 0..<30 { await Task.yield() } }

    private func intakeResponse(make: [String: Any], model: [String: Any], problem: [String: Any]) throws -> Data {
        let payload = try JSONSerialization.data(withJSONObject: [
            "updates": ["make": make, "model": model, "problem": problem],
            "prompt": "Check the suggested details, then tell me what is wrong."
        ])
        return try JSONSerialization.data(withJSONObject: ["status": "completed", "output": [[
            "type": "message", "content": [["type": "output_text", "text": String(decoding: payload, as: UTF8.self)]]
        ]]])
    }
    private func intakeField(_ value: String?, source: String, quote: String? = nil) -> [String: Any] {
        ["value": value as Any? ?? NSNull(), "source": source, "correction": false, "userQuote": quote as Any? ?? NSNull()]
    }
    private func spokenMacBookResponse(_ utterance: String) throws -> Data {
        try intakeResponse(
            make: intakeField("Apple", source: "user_inference", quote: utterance),
            model: intakeField("MacBook Pro", source: "user", quote: utterance),
            problem: intakeField("Screen frozen", source: "user", quote: utterance)
        )
    }

    func testMacBookFinalSpeechReachesTheRealIntakeDecoderAndNeedsConfirmation() async throws {
        let (model, voice) = makeModel()
        defer { model.cancel() }
        voice.isActive = true
        let utterance = "my mac book pro was frozen"
        let response = try spokenMacBookResponse(utterance)
        var calls = 0
        model.collectProject = { current, text, jpeg, photoID, _ in
            calls += 1
            XCTAssertEqual(text.trimmingCharacters(in: .whitespacesAndNewlines), utterance)
            XCTAssertNil(jpeg); XCTAssertNil(photoID)
            return try MendIntakeClient.decodeResponse(response, current: current, text: text, hasPhoto: jpeg != nil)
        }
        model.startProject()
        voice.onUserSpeechStarted?()
        voice.onDelegation?("macbook-final", utterance)
        await waitUntil("spoken MacBook intake", { !model.busy })
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(model.project.make, "Apple")
        XCTAssertEqual(model.project.model, "MacBook Pro")
        XCTAssertEqual(model.project.problem, "Screen frozen")
        XCTAssertEqual(model.project.suggestedFields, ["make"])
        XCTAssertEqual(model.stage, .confirmation)
        XCTAssertNil(model.confirmedProject); XCTAssertNil(model.diagnosis)
        XCTAssertNil(model.errorMessage)
    }

    func testAcceptedPhotoAndLaterSpeechUseTheSameDecoderWithoutLosingPhotoSuggestions() async throws {
        let (model, voice) = makeModel()
        defer { model.cancel() }
        voice.isActive = true
        let utterance = "my mac book pro was frozen"
        // The synthetic service result exercises routing and evidence metadata;
        // this fixture does not claim to recognize the test image itself.
        let visualResponse = try intakeResponse(
            make: intakeField("Apple", source: "photo_inference"),
            model: intakeField("MacBook Pro", source: "photo_inference"),
            problem: intakeField(nil, source: "missing")
        )
        let spokenResponse = try spokenMacBookResponse(utterance)
        let jpeg = try XCTUnwrap(PhotoCanvas.examplePhoto().jpegData(compressionQuality: 0.85))
        var requests: [(text: String, photoID: String?)] = []
        model.collectProject = { current, text, image, photoID, _ in
            requests.append((text, photoID))
            XCTAssertNotNil(image); XCTAssertNotNil(photoID)
            let response = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? visualResponse : spokenResponse
            return try MendIntakeClient.decodeResponse(response, current: current, text: text, hasPhoto: image != nil)
        }
        model.startProject()
        model.acceptPhoto(jpeg, source: "Offline image fixture")
        await waitUntil("photo suggestion intake", { !model.busy })
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(requests.first?.text.isEmpty == true)
        XCTAssertEqual(model.project.make, "Apple")
        XCTAssertEqual(model.project.model, "MacBook Pro")
        XCTAssertEqual(model.project.suggestedFields, ["make", "model"])
        XCTAssertTrue(model.project.problem.isEmpty)
        XCTAssertEqual(model.stage, .capture)
        let photoID = try XCTUnwrap(model.photo?.id)

        voice.onUserSpeechStarted?()
        voice.onDelegation?("photo-followup-final", utterance)
        await waitUntil("photo and spoken symptom intake", { !model.busy })
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.last?.photoID, photoID)
        XCTAssertEqual(requests.last?.text.trimmingCharacters(in: .whitespacesAndNewlines), utterance)
        XCTAssertEqual(model.project.model, "MacBook Pro")
        XCTAssertEqual(model.project.problem, "Screen frozen")
        XCTAssertEqual(model.project.suggestedFields, ["make"])
        XCTAssertEqual(model.stage, .confirmation)
        XCTAssertNil(model.confirmedProject); XCTAssertNil(model.diagnosis)
        XCTAssertNil(model.errorMessage)
    }

    func testIntakeNeverCreatesPlanBeforeExplicitConfirmationAndAcceptsTextOnlyProject() async throws {
        let (model, _) = makeModel()
        defer { model.cancel() }
        var intakeCalls = 0, planCalls = 0
        let details = completeDetails
        model.collectProject = { _, text, image, imageID, key in
            intakeCalls += 1
            XCTAssertNil(image); XCTAssertNil(imageID); XCTAssertEqual(key, "offline-test-key")
            if intakeCalls == 1 { return MendIntakeResult(details: .init(make: "Unknown"), prompt: "What model and problem?") }
            XCTAssertTrue(text.contains("door"))
            return MendIntakeResult(details: details, prompt: "Review these details.")
        }
        model.createPlan = { confirmed, jpeg, photoID, key in
            planCalls += 1
            XCTAssertEqual(confirmed, details); XCTAssertNil(jpeg)
            XCTAssertTrue(photoID.hasPrefix("text-project-")); XCTAssertEqual(key, "offline-test-key")
            return try self.plan(photoID: photoID).validated(expectedPhotoID: photoID, hasPhoto: false)
        }
        XCTAssertEqual(model.stage, .welcome)
        model.startProject()
        XCTAssertEqual(model.stage, .capture)
        XCTAssertEqual(planCalls, 0)
        model.collectDetails(text: "The make is unknown", includePhoto: false)
        await waitUntil("first intake", { !model.busy })
        XCTAssertEqual(model.stage, .capture)
        XCTAssertEqual(model.project.missingFields, ["model", "problem"])
        XCTAssertFalse(model.canConfirmProject)
        XCTAssertEqual(planCalls, 0)
        model.collectDetails(text: "Cabinet hinge; the door is loose", includePhoto: false)
        await waitUntil("complete intake", { !model.busy })
        XCTAssertEqual(model.stage, .confirmation)
        XCTAssertNil(model.confirmedProject)
        XCTAssertNil(model.diagnosis)
        XCTAssertEqual(planCalls, 0)
        model.reviewProject()
        XCTAssertEqual(planCalls, 0)
        model.confirmProject()
        XCTAssertTrue(model.busy)
        XCTAssertEqual(model.workKind, "plan")
        XCTAssertNotNil(model.progressTitle)
        await waitUntil("text-only plan", { !model.busy })
        XCTAssertEqual(planCalls, 1)
        XCTAssertEqual(model.stage, .parts)
        XCTAssertFalse(model.partsConfirmed)
        XCTAssertEqual(model.confirmedProject, details)
        XCTAssertNil(model.photo)
        XCTAssertTrue(try XCTUnwrap(model.diagnosis).steps.allSatisfy { $0.marker == nil })
        XCTAssertNil(model.progressTitle)
        model.startGuide()
        XCTAssertEqual(model.stage, .parts, "The user confirms readiness before opening instructions")
        model.confirmParts()
        XCTAssertEqual(model.stage, .diagnosis)
        XCTAssertTrue(model.partsConfirmed)
    }

    func testPhotoThenReportedRestartProblemThenHowToQuestionPreservesConfirmationAndSpeaksTheAnswer() async throws {
        let (model, voice) = makeModel()
        defer { model.cancelVoiceReply(); model.cancel() }
        voice.isActive = true
        let reportedProblem = "my mac book pro wont restart"
        let visualResponse = try intakeResponse(
            make: intakeField("Apple", source: "photo_inference"),
            model: intakeField("MacBook Pro", source: "photo_inference"),
            problem: intakeField(nil, source: "missing"))
        let spokenResponse = try intakeResponse(
            make: intakeField("Apple", source: "unchanged"),
            model: intakeField("MacBook Pro", source: "user", quote: reportedProblem),
            problem: intakeField("Will not restart", source: "user", quote: reportedProblem))
        var intakeCalls = 0, questionCalls = 0
        model.collectProject = { current, text, jpeg, _, _ in
            intakeCalls += 1
            let response = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? visualResponse : spokenResponse
            return try MendIntakeClient.decodeResponse(response, current: current, text: text, hasPhoto: jpeg != nil)
        }
        let answer = "If the menu responds, save your work first and choose Restart from the Apple menu. If it does not respond, tell me what you see before trying a forced shutdown."
        model.answerRepairQuestion = { question, details, diagnosis, step, _, key in
            questionCalls += 1
            XCTAssertEqual(question, "how do I restart it")
            XCTAssertEqual(details.make, "Apple"); XCTAssertEqual(details.model, "MacBook Pro")
            XCTAssertEqual(details.problem, "Will not restart")
            XCTAssertNil(diagnosis); XCTAssertNil(step); XCTAssertEqual(key, "offline-test-key")
            return answer
        }
        // Both service responses are fixed fixtures, not recognition claims about this test image.
        model.startProject()
        model.acceptPhoto(try XCTUnwrap(PhotoCanvas.examplePhoto().jpegData(compressionQuality: 0.85)), source: "Offline image")
        await waitUntil("photo identification", { !model.busy })
        XCTAssertEqual(model.stage, .capture); XCTAssertTrue(model.project.problem.isEmpty)
        voice.onUserSpeechStarted?(); voice.onDelegation?("symptom", reportedProblem)
        await waitUntil("spoken restart problem", { !model.busy })
        let savedDetails = model.project, savedPhoto = model.photo?.id
        XCTAssertEqual(model.stage, .confirmation)
        voice.onUserSpeechStarted?(); voice.onDelegation?("restart-question", "how do I restart it")
        await waitUntil("restart help", { !model.voiceReplyPending })
        XCTAssertEqual(intakeCalls, 2); XCTAssertEqual(questionCalls, 1)
        XCTAssertEqual(model.project, savedDetails); XCTAssertEqual(model.photo?.id, savedPhoto)
        XCTAssertEqual(model.stage, .confirmation); XCTAssertNil(model.presentation)
        XCTAssertNil(model.confirmedProject); XCTAssertNil(model.diagnosis)
        XCTAssertEqual(model.lastAnswer, answer); XCTAssertEqual(voice.outputTranscript, answer)
        XCTAssertTrue(model.isEnabled(.confirmProject)); XCTAssertTrue(model.isEnabled(.moreDetails))
        XCTAssertTrue(model.setupHistory.isEmpty); XCTAssertTrue(voice.isActive)
    }

    func testTaskQuestionBeforeProblemIsKnownBecomesIntakeEvidenceWithoutCreatingAPlan() async {
        let (model, voice) = makeModel()
        defer { model.cancel() }
        voice.isActive = true
        model.startProject(); model.project = .init(make: "Apple", model: "MacBook Pro", suggestedFields: ["model"])
        let question = "how do I restart it"
        var intakeCalls = 0
        model.collectProject = { current, text, _, _, _ in
            intakeCalls += 1
            XCTAssertEqual(text.trimmingCharacters(in: .whitespacesAndNewlines), question)
            var details = current; details.problem = "Wants help restarting the laptop"
            return MendIntakeResult(details: details, prompt: "Review the requested task.")
        }
        voice.onUserSpeechStarted?(); voice.onDelegation?("missing-task", question)
        await waitUntil("task intake", { !model.busy })
        XCTAssertEqual(intakeCalls, 1)
        XCTAssertEqual(model.project.problem, "Wants help restarting the laptop")
        XCTAssertEqual(model.stage, .confirmation)
        XCTAssertNil(model.confirmedProject); XCTAssertNil(model.diagnosis)
    }

    func testContextQuestionDuringIncompleteIdentityDoesNotReplaceTheReportedProblem() async {
        let (model, voice) = makeModel()
        defer { model.cancelVoiceReply() }
        voice.isActive = true
        model.startProject(); model.project = .init(problem: "The display is blank")
        let details = model.project
        model.answerRepairQuestion = { question, saved, _, _, _, _ in
            XCTAssertEqual(question, "Where can I find the model number?")
            XCTAssertEqual(saved, details)
            return "Look for a model label on the outside of the item, without opening its case."
        }
        voice.onDelegation?("identity-question", "Where can I find the model number?")
        await waitUntil("identity answer", { !model.voiceReplyPending })
        XCTAssertEqual(model.project, details); XCTAssertEqual(model.stage, .capture)
        XCTAssertFalse(model.busy); XCTAssertNotNil(model.lastAnswer)
        XCTAssertTrue(model.setupHistory.isEmpty)
    }

    func testQuestionDuringIntakeHasAnExplicitBusyReplyAndDoesNotReplacePendingEvidence() async {
        let (model, voice) = makeModel()
        defer { model.cancel() }
        voice.isActive = true
        let gate = ProjectResultGate<MendIntakeResult>()
        model.collectProject = { _, _, _, _, _ in try await gate.wait() }
        model.startProject(); model.project = completeDetails
        model.collectDetails(text: "The hinge is on a cabinet", includePhoto: false)
        await waitUntil("intake gate", { gate.isWaiting })
        let evidence = model.setupHistory
        voice.onDelegation?("busy-question", "How do I support it?")
        XCTAssertTrue(model.busy); XCTAssertFalse(model.voiceReplyPending)
        XCTAssertEqual(model.setupHistory, evidence)
        XCTAssertTrue(voice.outputTranscript.contains("Please ask again"))
        gate.succeed(MendIntakeResult(details: completeDetails, prompt: "Review"))
        await waitUntil("intake completes after question", { !model.busy })
        XCTAssertEqual(model.stage, .confirmation)
    }

    func testLateQuestionAnswerCannotSpeakAfterTypedProjectChangesOrExplicitCancellation() async {
        for cancel in [false, true] {
            let (model, voice) = makeModel()
            voice.isActive = true
            let gate = ProjectResultGate<String>()
            model.answerRepairQuestion = { _, _, _, _, _, _ in try await gate.wait() }
            model.startProject(); model.project = completeDetails; model.reviewProject()
            voice.onDelegation?("delayed-question", "How do I support it?")
            await waitUntil("question gate", { gate.isWaiting })
            if cancel { model.perform(.cancel) }
            else { model.project.problem = "The drawer is jammed" }
            let previousSpeech = voice.outputTranscript
            gate.succeed("An answer for the old project.")
            await drainTasks()
            XCTAssertFalse(model.voiceReplyPending)
            XCTAssertNil(model.lastAnswer)
            XCTAssertEqual(voice.outputTranscript, previousSpeech)
            XCTAssertEqual(model.stage, .confirmation)
            XCTAssertNil(model.confirmedProject); XCTAssertNil(model.diagnosis)
        }
    }

    func testIncompleteDetailsCannotConfirmOrEnterConfirmation() {
        let (model, _) = makeModel()
        var plans = 0
        model.createPlan = { _, _, photoID, _ in plans += 1; return self.plan(photoID: photoID) }
        model.confirmProject()
        XCTAssertEqual(model.stage, .welcome)
        model.startProject(); model.project = .init(make: "IKEA", problem: "Loose door")
        model.reviewProject(); model.confirmProject()
        XCTAssertEqual(model.stage, .capture)
        XCTAssertFalse(model.canConfirmProject)
        XCTAssertNil(model.confirmedProject)
        XCTAssertNil(model.diagnosis)
        XCTAssertEqual(plans, 0)
    }

    func testReadyPlanShowsPartsThenChecklistWithoutStoppingOrUnmutingAnActiveConversation() async {
        let (model, voice) = makeModel()
        let gate = ProjectResultGate<MendDiagnosis>()
        model.createPlan = { _, _, _, _ in try await gate.wait() }
        voice.isActive = true
        model.startProject(); model.project = completeDetails; model.reviewProject(); model.confirmProject()
        XCTAssertTrue(model.busy)
        XCTAssertTrue(model.isEnabled(.muteMic), "Mic mute remains available while building the plan")
        model.perform(.muteMic)
        XCTAssertTrue(voice.isMuted)
        await waitUntil("plan gate", { gate.isWaiting })
        gate.succeed(plan(photoID: "offline-plan"))
        await waitUntil("ready checklist", { !model.busy })
        XCTAssertEqual(model.stage, .parts)
        XCTAssertFalse(model.partsConfirmed)
        XCTAssertNil(model.presentation)
        XCTAssertTrue(voice.isActive)
        XCTAssertTrue(voice.isMuted, "A plan transition must never re-enable a muted microphone")
        XCTAssertFalse(model.availableActions.contains { MendActionID.stepIDs.contains($0.id) })
        model.perform(.confirmParts)
        XCTAssertEqual(model.stage, .diagnosis)
        XCTAssertTrue(model.partsConfirmed)
        XCTAssertEqual(model.checklistActions.count, 3)
        XCTAssertFalse(model.availableActions.contains { MendActionID.checkStepIDs.contains($0.id) })
        XCTAssertTrue(model.checkedSteps.isEmpty)
        XCTAssertTrue(model.isEnabled(.unmuteMic))
        model.glasses.onAction?(MendActionID.unmuteMic.rawValue)
        XCTAssertFalse(voice.isMuted)
        voice.onUserSpeechStarted?()
        voice.onDelegation?("open-ready-step", "Step one")
        XCTAssertEqual(model.stage, .guide)
        XCTAssertTrue(model.checkedSteps.isEmpty)
        XCTAssertTrue(voice.isActive)
    }

    func testEditingProjectClearsConfirmedSnapshotAndRequiresAnotherConfirmation() {
        let (model, _) = makeModel()
        model.loadDemo()
        XCTAssertNotNil(model.confirmedProject)
        model.editProject()
        model.project.make = "Updated make"
        XCTAssertNil(model.confirmedProject)
        XCTAssertEqual(model.stage, .capture)
        model.reviewProject()
        XCTAssertEqual(model.stage, .confirmation)
        XCTAssertNil(model.confirmedProject)
    }

    func testCancelIntakeClearsImmediateProgressAndIgnoresLateResult() async {
        let (model, _) = makeModel()
        let gate = ProjectResultGate<MendIntakeResult>()
        model.collectProject = { _, _, _, _, _ in try await gate.wait() }
        model.startProject(); model.collectDetails(text: "Cabinet hinge", includePhoto: false)
        XCTAssertTrue(model.busy)
        XCTAssertEqual(model.workKind, "intake")
        XCTAssertEqual(model.progressTitle, "Noting the details…")
        XCTAssertNotNil(model.feedbackTask)
        await waitUntil("intake gate", { gate.isWaiting })
        model.cancel()
        XCTAssertFalse(model.busy)
        XCTAssertEqual(model.workKind, "")
        XCTAssertEqual(model.progressDetail, "")
        XCTAssertNil(model.progressTitle)
        XCTAssertNil(model.feedbackTask)
        gate.succeed(MendIntakeResult(details: completeDetails, prompt: "Ready"))
        await drainTasks()
        XCTAssertEqual(model.project, MendProjectDetails())
        XCTAssertEqual(model.stage, .capture)
        XCTAssertNil(model.diagnosis)
    }

    func testFailedSpokenIntakeShowsAndSpeaksTheActualReasonAndReleasesBusyState() async {
        let (model, voice) = makeModel()
        voice.isActive = true
        let gate = ProjectResultGate<MendIntakeResult>()
        model.collectProject = { _, _, _, _, _ in try await gate.wait() }
        model.startProject()
        voice.onUserSpeechStarted?()
        voice.onDelegation?("failed-restart-details", "i can't restart my mac book pro")
        await waitUntil("failing spoken intake", { gate.isWaiting })
        XCTAssertTrue(model.busy)
        XCTAssertNotNil(model.progressTitle)
        let reason = "Meta stopped before completing the details."
        gate.fail(MendError.message(reason))
        await waitUntil("visible intake failure", { !model.busy })

        XCTAssertEqual(model.errorMessage, reason)
        XCTAssertEqual(model.setupPrompt, reason)
        XCTAssertTrue(model.displayPages.joined(separator: " ").contains(reason))
        XCTAssertTrue(voice.outputTranscript.contains(reason))
        XCTAssertEqual(voice.spoken.filter { $0.contains(reason) }.count, 1)
        XCTAssertEqual(model.workKind, "")
        XCTAssertNil(model.progressTitle); XCTAssertNil(model.feedbackTask)
        XCTAssertEqual(model.stage, .capture)
        XCTAssertEqual(model.project, MendProjectDetails())
        XCTAssertNil(model.confirmedProject); XCTAssertNil(model.diagnosis)
        XCTAssertTrue(model.isEnabled(.clearError))
    }

    func testSupersededIntakeCannotOverwriteTheLatestResult() async {
        let (model, _) = makeModel()
        let first = ProjectResultGate<MendIntakeResult>(), second = ProjectResultGate<MendIntakeResult>()
        var calls = 0
        model.collectProject = { _, _, _, _, _ in
            calls += 1
            return try await (calls == 1 ? first : second).wait()
        }
        model.startProject(); model.collectDetails(text: "First statement", includePhoto: false)
        await waitUntil("first gate", { first.isWaiting })
        model.collectDetails(text: "Actually use the new details", includePhoto: false)
        await waitUntil("second gate", { second.isWaiting })
        let latest = completeDetails
        second.succeed(MendIntakeResult(details: latest, prompt: "Review"))
        await waitUntil("newest intake", { !model.busy })
        first.succeed(MendIntakeResult(details: .init(make: "Wrong old make"), prompt: "Old answer"))
        await drainTasks()
        XCTAssertEqual(model.project, latest)
        XCTAssertEqual(model.stage, .confirmation)
        XCTAssertFalse(model.busy)
    }

    func testManualFieldEditWinsOverIntakeInFlight() async {
        let (model, _) = makeModel()
        let gate = ProjectResultGate<MendIntakeResult>()
        model.collectProject = { _, _, _, _, _ in try await gate.wait() }
        model.startProject(); model.collectDetails(text: "Read this project", includePhoto: false)
        await waitUntil("intake gate", { gate.isWaiting })
        model.project.make = "Manual make"
        var suggested = completeDetails
        suggested.suggestedFields = ["make", "model"]
        gate.succeed(MendIntakeResult(details: suggested, prompt: "Review"))
        await waitUntil("manual edit merge", { !model.busy })
        XCTAssertEqual(model.project.make, "Manual make")
        XCTAssertEqual(model.project.model, completeDetails.model)
        XCTAssertEqual(model.project.problem, completeDetails.problem)
        XCTAssertEqual(model.project.suggestedFields, ["model"])
        XCTAssertEqual(model.stage, .confirmation)
    }

    func testManualConfirmationOfUnchangedValueWinsOverLateSuggestionMetadata() async {
        let (model, _) = makeModel()
        let gate = ProjectResultGate<MendIntakeResult>()
        model.startProject()
        var initial = completeDetails
        initial.suggestedFields = ["make", "model"]
        model.project = initial
        model.collectProject = { _, _, _, _, _ in try await gate.wait() }
        model.collectDetails(text: "Check the photo", includePhoto: false)
        await waitUntil("suggestion metadata gate", { gate.isWaiting })
        // The user accepts the existing value while the request is in flight.
        model.project.suggestedFields.remove("make")
        gate.succeed(MendIntakeResult(details: initial, prompt: "Review"))
        await waitUntil("manual metadata merge", { !model.busy })
        XCTAssertEqual(model.project.make, initial.make)
        XCTAssertEqual(model.project.model, initial.model)
        XCTAssertEqual(model.project.suggestedFields, ["model"])
        XCTAssertEqual(model.stage, .confirmation)
    }

    func testCommittedSpeechIsNotReplayedAfterManualCorrection() async {
        let (model, _) = makeModel()
        var inputs: [String] = []
        model.collectProject = { current, text, _, _, _ in
            inputs.append(text)
            var answer = current
            if answer.make.isEmpty { answer.make = "Bosch" }
            return MendIntakeResult(details: answer, prompt: "What model?")
        }
        model.startProject(); model.collectDetails(text: "Actually change make to Bosch", includePhoto: false)
        await waitUntil("committed correction", { !model.busy })
        model.project.make = "Manual make"
        model.collectDetails(text: "The door rattles", includePhoto: false)
        await waitUntil("new utterance", { !model.busy })
        XCTAssertEqual(inputs.count, 2)
        XCTAssertEqual(inputs.last?.trimmingCharacters(in: .whitespacesAndNewlines), "The door rattles")
        XCTAssertEqual(model.project.make, "Manual make")
    }

    func testCancelledPlanCannotPopulateANewProject() async {
        let (model, _) = makeModel()
        let gate = ProjectResultGate<MendDiagnosis>()
        var pendingID = ""
        model.createPlan = { _, _, photoID, _ in pendingID = photoID; return try await gate.wait() }
        model.startProject(); model.project = completeDetails; model.reviewProject(); model.confirmProject()
        await waitUntil("plan gate", { gate.isWaiting })
        model.newRepair()
        XCTAssertEqual(model.stage, .welcome)
        XCTAssertNil(model.progressTitle)
        gate.succeed(plan(photoID: pendingID))
        await drainTasks()
        XCTAssertEqual(model.stage, .welcome)
        XCTAssertEqual(model.project, MendProjectDetails())
        XCTAssertNil(model.confirmedProject)
        XCTAssertNil(model.diagnosis)
        XCTAssertFalse(model.busy)
    }

    func testEditingDetailsDuringPlanDiscardsResultAndReleasesBusyState() async {
        let (model, _) = makeModel()
        let gate = ProjectResultGate<MendDiagnosis>()
        var pendingID = ""
        model.createPlan = { _, _, photoID, _ in pendingID = photoID; return try await gate.wait() }
        model.startProject(); model.project = completeDetails; model.reviewProject(); model.confirmProject()
        await waitUntil("plan gate", { gate.isWaiting })
        model.project.problem = "A newly corrected problem"
        gate.succeed(plan(photoID: pendingID))
        await waitUntil("discarded edited plan", { !model.busy })
        XCTAssertNil(model.diagnosis)
        XCTAssertNil(model.confirmedProject)
        XCTAssertNil(model.progressTitle)
        XCTAssertNil(model.feedbackTask)
        XCTAssertEqual(model.stage, .capture)
        XCTAssertEqual(model.project.problem, "A newly corrected problem")
    }

    func testEditingDetailsDuringFailedPlanClearsTheOldConfirmationSnapshot() async {
        let (model, voice) = makeModel()
        let gate = ProjectResultGate<MendDiagnosis>()
        model.createPlan = { _, _, _, _ in try await gate.wait() }
        model.startProject(); model.project = completeDetails; model.reviewProject(); model.confirmProject()
        await waitUntil("failing plan gate", { gate.isWaiting })
        model.project.problem = "The corrected problem"
        gate.fail(MendError.message("Simulated offline failure"))
        await waitUntil("failed edited plan cleanup", { !model.busy })
        XCTAssertFalse(model.busy)
        XCTAssertEqual(model.workKind, "")
        XCTAssertNil(model.confirmedProject)
        XCTAssertNil(model.diagnosis)
        XCTAssertNil(model.progressTitle)
        XCTAssertNil(model.feedbackTask)
        XCTAssertEqual(model.stage, .capture)
        XCTAssertEqual(model.project.problem, "The corrected problem")
        XCTAssertTrue(voice.outputTranscript.contains("updated project details"))
        XCTAssertFalse(voice.outputTranscript.contains("Create steps"))
    }

    func testGlassesDetailsOmitSourceURLsWithoutChangingThePhoneAnswer() {
        let (model, _) = makeModel()
        let answer = "Support the door. [Source 1](<https://example.com/manual>) Tighten gently."
        model.lastAnswer = answer
        model.answerSources = [MendSource(title: "Manual", url: URL(string: "https://example.com/manual")!)]
        model.presentation = .details
        let displayed = model.displayPages.joined(separator: " ")
        XCTAssertEqual(displayed, "Support the door. Tighten gently.")
        XCTAssertFalse(displayed.contains("https://"))
        XCTAssertFalse(displayed.contains("example.com"))
        XCTAssertEqual(model.lastAnswer, answer)
        XCTAssertEqual(model.answerSources.count, 1)
    }

    func testOutOfOrderCompletionReturnsToEarlierUnfinishedWorkWithoutRecheckingCompletedSteps() {
        let (model, _) = makeModel()
        model.loadDemo(); model.startGuide(); model.openChecklistStep(2)
        XCTAssertEqual(model.stepIndex, 2)
        model.checkAndAdvance()
        XCTAssertEqual(model.stage, .guide)
        XCTAssertEqual(model.checkedSteps, ["check"])
        XCTAssertEqual(model.stepIndex, 0, "Completing the last instruction returns to earlier unfinished work")
        model.backToChecklist()
        XCTAssertEqual(model.stage, .diagnosis)
        model.checkAndAdvance()
        XCTAssertEqual(model.checkedSteps, ["check"], "Checklist visibility cannot complete another step")
        model.openChecklistStep(0)
        model.checkAndAdvance()
        XCTAssertEqual(model.stage, .guide)
        XCTAssertEqual(model.stepIndex, 1)
        XCTAssertEqual(model.checkedSteps, ["support", "check"])
        model.openChecklistStep(2); model.checkAndAdvance()
        XCTAssertEqual(model.checkedSteps, ["support", "check"], "Rechecking an instruction preserves the existing progress")
        XCTAssertEqual(model.stage, .guide)
        XCTAssertEqual(model.stepIndex, 1, "The remaining instruction stays available after inspecting completed work")
        model.checkAndAdvance()
        XCTAssertEqual(model.checkedSteps, ["support", "tighten", "check"])
        XCTAssertEqual(model.stage, .complete)
    }

    func testNewProjectClearsFieldsPhotoHelpConfirmationAndProgress() {
        let (model, voice) = makeModel()
        model.loadDemo(); model.startGuide(); model.checkAndAdvance()
        model.helpText = "Which screw?"; model.lastAnswer = "A prior answer"
        model.answerSources = [MendSource(title: "Old source", url: URL(string: "https://example.com/manual")!)]
        model.selectedHelpStepIndex = 1; model.setupText = "Old typed setup"; model.setupHistory = "Old speech"
        model.presentation = .sources
        model.newRepair()
        XCTAssertEqual(model.stage, .welcome)
        XCTAssertEqual(model.project, MendProjectDetails())
        XCTAssertNil(model.confirmedProject); XCTAssertNil(model.photo); XCTAssertNil(model.currentPhoto)
        XCTAssertNil(model.diagnosis); XCTAssertNil(model.currentMarker)
        XCTAssertTrue(model.checkedSteps.isEmpty)
        XCTAssertTrue(model.helpText.isEmpty); XCTAssertNil(model.lastAnswer); XCTAssertTrue(model.answerSources.isEmpty)
        XCTAssertNil(model.selectedHelpStepIndex); XCTAssertNil(model.presentation)
        XCTAssertTrue(model.setupText.isEmpty); XCTAssertTrue(model.setupHistory.isEmpty)
        XCTAssertNil(model.progressTitle); XCTAssertNil(model.feedbackTask)
        XCTAssertFalse(model.isDemo)
        XCTAssertEqual(voice.resetCalls, 2)
    }

    func testSpeechStartedInPreviousProjectCannotPopulateANewProject() async {
        let (model, voice) = makeModel()
        voice.isActive = true
        var intakeCalls = 0
        model.collectProject = { _, _, _, _, _ in
            intakeCalls += 1
            return MendIntakeResult(details: self.completeDetails, prompt: "Old project details")
        }
        model.startProject()
        voice.onUserSpeechStarted?()
        let previousGeneration = model.projectGeneration
        model.newRepair(); model.startProject()
        XCTAssertNotEqual(model.projectGeneration, previousGeneration)
        voice.onDelegation?("old-project-final", "The old cabinet door is loose")
        await drainTasks()
        XCTAssertEqual(intakeCalls, 0)
        XCTAssertEqual(model.project, MendProjectDetails())
        XCTAssertEqual(model.stage, .capture)
        XCTAssertFalse(model.busy)
        XCTAssertTrue(voice.outputTranscript.contains("screen changed"))
    }

    func testSlowIntakeShowsImmediateProgressThenOneSpokenAcknowledgementAndCancelClearsIt() async throws {
        let (model, voice) = makeModel()
        voice.isActive = true
        let gate = ProjectResultGate<MendIntakeResult>()
        model.collectProject = { _, _, _, _, _ in try await gate.wait() }
        model.startProject(); model.collectDetails(text: "The door is loose", includePhoto: false)
        XCTAssertEqual(model.progressTitle, "Noting the details…")
        XCTAssertTrue(voice.spoken.isEmpty, "The visual state should update before the delayed spoken cue")
        await waitUntil("slow intake gate", { gate.isWaiting })
        try await Task.sleep(for: .milliseconds(1400))
        let acknowledgement = "I’m checking the project details."
        XCTAssertEqual(voice.spoken.filter { $0 == acknowledgement }.count, 1)
        XCTAssertTrue(model.feedbackSpoken)
        let feedbackID = model.feedbackID
        model.cancel()
        XCTAssertNil(model.progressTitle); XCTAssertNil(model.feedbackTask)
        XCTAssertFalse(model.feedbackSpoken)
        XCTAssertNotEqual(model.feedbackID, feedbackID)
        XCTAssertGreaterThan(voice.interruptCalls, 0)
        gate.succeed(MendIntakeResult(details: completeDetails, prompt: "Ready"))
        await drainTasks()
        XCTAssertEqual(voice.spoken.filter { $0 == acknowledgement }.count, 1)
        XCTAssertEqual(model.project, MendProjectDetails())
    }

    func testFastIntakeCompletionNeverSpeaksALateWorkingAcknowledgement() async throws {
        let (model, voice) = makeModel()
        voice.isActive = true
        model.collectProject = { _, _, _, _, _ in
            MendIntakeResult(details: self.completeDetails, prompt: "Review the project")
        }
        model.startProject(); model.collectDetails(text: "The door is loose", includePhoto: false)
        await waitUntil("fast intake", { !model.busy })
        XCTAssertEqual(model.stage, .confirmation)
        XCTAssertNil(model.progressTitle); XCTAssertNil(model.feedbackTask)
        try await Task.sleep(for: .milliseconds(1400))
        XCTAssertFalse(voice.spoken.contains("I’m checking the project details."))
        XCTAssertFalse(model.feedbackSpoken)
    }
}

@MainActor
private final class ProjectResultGate<Value> {
    private var continuation: CheckedContinuation<Value, Error>?
    var isWaiting: Bool { continuation != nil }
    func wait() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func succeed(_ value: Value) {
        let pending = continuation; continuation = nil
        pending?.resume(returning: value)
    }
    func fail(_ error: Error) {
        let pending = continuation; continuation = nil
        pending?.resume(throwing: error)
    }
}

@MainActor
private final class ProjectFlowVoice: ConversationVoiceSession {
    var isActive = false
    var isConnecting = false
    var isMuted = false
    var isSpeaking = false
    var captureSuspended = false
    var status = "Offline test voice"
    var inputTranscript = ""
    var outputTranscript = ""
    var error: String?
    var conversationContext = ""
    var onDelegation: ((String, String) -> Void)?
    var onFailure: ((String) -> Void)?
    var onStateChange: (() -> Void)?
    var onUserSpeechStarted: (() -> Void)?
    var resetCalls = 0
    var spoken: [String] = []
    var interruptCalls = 0
    func start(apiKey: String, context: String) async throws { isActive = true }
    func stop() async { isActive = false }
    func mute() { isMuted = true }
    func unmute() { isMuted = false }
    func setOutputEnabled(_ enabled: Bool) {}
    func interruptPlayback() { interruptCalls += 1; isSpeaking = false }
    func sendContext(_ text: String) { conversationContext = text }
    func sayResult(_ text: String, delegationID: String?) { spoken.append(text); outputTranscript = text }
    func setCaptureSuspended(_ suspended: Bool) { captureSuspended = suspended }
    func resetConversation() { resetCalls += 1 }
}

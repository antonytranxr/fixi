import UIKit
import XCTest
@testable import Fixi

@MainActor final class MendPartsFlowTests: XCTestCase {
    func testPartsAnnouncementExplainsWhereLinksAreWithoutClaimingLinksForAnEmptyKit() async {
        for hasItems in [true, false] {
            let (model, voice) = fixture(tools: hasItems ? ["Screwdriver"] : [], parts: [])
            defer { model.cancel() }
            await preparePlan(model)
            let announcement = voice.spoken.last ?? ""
            XCTAssertEqual(announcement.contains("found the items"), hasItems)
            XCTAssertEqual(announcement.contains("shopping links are in the app"), hasItems)
            XCTAssertEqual(announcement.contains("doesn’t call for extra parts or tools"), !hasItems)
            XCTAssertFalse(model.partsConfirmed)
        }
    }

#if !canImport(MWDATCore)
    func testNativePartsRowsCannotOpenOrCompleteRepairSteps() async throws {
        let (model, _) = fixture()
        defer { model.cancel() }
        await preparePlan(model)
        let card = try XCTUnwrap(model.glasses.lastCard)
        XCTAssertEqual(card.staticRows, ["Screwdriver", "Replacement hinge"])
        XCTAssertTrue(card.items.isEmpty)
        XCTAssertEqual(card.text, "Shopping links are in the app.")
        model.glasses.onAction?(MendActionID.step1.rawValue)
        model.glasses.onAction?(MendActionID.checkStep1.rawValue)
        XCTAssertEqual(model.stage, .parts)
        XCTAssertTrue(model.checkedSteps.isEmpty)
        XCTAssertFalse(model.partsConfirmed)
    }

    func testLongNativePartsListPagesPreserveEveryItemAndIssueWithoutConfirmingReadiness() async throws {
        let tools = (1...12).map { "Tool \($0)" }
        let parts = (1...12).map { "Part \($0)" }
        let (model, _) = fixture(tools: tools, parts: parts)
        defer { model.cancel() }
        await preparePlan(model)
        let issue = "The replacement shown does not match the specified part. Check its label before proceeding."
        model.partsIssues = [issue]
        model.syncDisplay()
        var seen: [String] = [], notes: [String] = []
        for _ in 0..<20 {
            let card = try XCTUnwrap(model.glasses.lastCard)
            seen += card.staticRows; notes.append(card.text)
            XCTAssertTrue(card.items.isEmpty)
            XCTAssertLessThanOrEqual(card.staticRows.count, 3)
            XCTAssertLessThanOrEqual(card.actions?.count ?? 0, 3)
            XCTAssertTrue(card.actions?.contains { $0.id == MendActionID.muteMic.rawValue } == true)
            guard card.actions?.contains(where: { $0.id == MendActionID.more.rawValue }) == true else { break }
            model.perform(.more)
        }
        XCTAssertEqual(seen, tools + parts)
        XCTAssertTrue(notes.joined(separator: " ").contains(issue))
        model.perform(.back)
        XCTAssertEqual(model.stage, .parts)
        XCTAssertFalse(model.partsConfirmed)
        XCTAssertTrue(model.checkedSteps.isEmpty)
    }
#endif

    func testAmazonLinksOpenTheListedItemWithoutConfirmingPartsOrChangingTheGuide() async throws {
        let (model, voice) = fixture()
        defer { model.cancel() }
        var opened: [URL] = []
        model.openShoppingURL = { opened.append($0) }
        await preparePlan(model)
        XCTAssertEqual(model.partsShoppingLinks.map(\.title), model.partsItems)
        XCTAssertEqual(model.partsShoppingActions.count, 2)
        model.openPartsShoppingLink(0)
        XCTAssertEqual(opened, [model.partsShoppingLinks[0].url])
        voice.onDelegation?("amazon-part", "Find Replacement hinge on Amazon")
        XCTAssertEqual(opened.last, model.partsShoppingLinks[1].url)
        XCTAssertEqual(opened.count, 2)
        XCTAssertEqual(model.stage, .parts)
        XCTAssertFalse(model.partsConfirmed)
        XCTAssertTrue(model.checkedSteps.isEmpty)
        XCTAssertEqual(model.bottomActions.count, 3)
        model.presentation = .settings
        model.openPartsShoppingLink(0)
        XCTAssertEqual(opened.count, 2, "A hidden parts link cannot open from another screen")
        model.presentation = nil
        model.voiceReplyPending = true
        model.openPartsShoppingLink(1)
        XCTAssertEqual(opened.count, 2, "Wait for the active request before leaving the app")
        model.voiceReplyPending = false
        model.perform(.confirmParts)
        model.openPartsShoppingLink(0)
        XCTAssertEqual(opened.count, 2)
    }

#if !canImport(MWDATCore)
    func testAmazonLinksDoNotAddShoppingRowsOrButtonsToTheGlasses() async throws {
        let (model, _) = fixture()
        defer { model.cancel() }
        await preparePlan(model)
        let card = try XCTUnwrap(model.glasses.lastCard)
        XCTAssertTrue(model.availableActions.contains { MendActionID.shoppingIDs.contains($0.id) })
        XCTAssertFalse(card.text.contains("Amazon"))
        XCTAssertTrue(card.items.allSatisfy { !MendActionID.shoppingIDs.map(\.rawValue).contains($0.id) })
        XCTAssertTrue((card.actions ?? []).allSatisfy { !MendActionID.shoppingIDs.map(\.rawValue).contains($0.id) })
        XCTAssertLessThanOrEqual(card.actions?.count ?? 0, 3)
    }
#endif

    func testNewPlanRequiresWearerReadinessBeforeOpeningAnyStep() async throws {
        let (model, voice) = fixture()
        defer { model.cancel() }
        await preparePlan(model)
        XCTAssertEqual(model.stage, .parts); XCTAssertFalse(model.partsConfirmed)
        XCTAssertEqual(model.partsItems, ["Screwdriver", "Replacement hinge"])
        model.startGuide(); model.openChecklistStep(1)
        XCTAssertEqual(model.stage, .parts); XCTAssertTrue(model.checkedSteps.isEmpty)
        XCTAssertFalse(model.availableActions.contains { MendActionID.stepIDs.contains($0.id) })
        XCTAssertEqual(MendVoiceActions.resolve("Ready", available: model.availableActions), .action(.confirmParts))
        voice.onDelegation?("ready", "Ready")
        XCTAssertTrue(model.partsConfirmed); XCTAssertEqual(model.stage, .diagnosis)
        model.glasses.onAction?(MendActionID.step2.rawValue)
        XCTAssertEqual(model.stage, .guide); XCTAssertEqual(model.stepIndex, 1)
        XCTAssertTrue(model.checkedSteps.isEmpty)
    }

    func testNoObservedPartsIssueIsSilentAndNeverConfirmsReadiness() async throws {
        let (model, voice) = fixture()
        defer { model.cancel() }
        await preparePlan(model)
        voice.spoken = []
        model.checkParts = { details, diagnosis, text, photo, _ in
            XCTAssertEqual(details, model.project)
            XCTAssertEqual(diagnosis.parts, ["Replacement hinge"])
            XCTAssertEqual(text, "I have the screwdriver and replacement hinge")
            XCTAssertNil(photo)
            return MendPartsReview(photoID: nil, issues: [])
        }
        voice.onDelegation?("inventory", "I have the screwdriver and replacement hinge")
        await until { !model.busy }
        XCTAssertTrue(voice.spoken.isEmpty)
        XCTAssertTrue(model.partsIssues.isEmpty); XCTAssertNil(model.partsMessage)
        XCTAssertFalse(model.partsConfirmed); XCTAssertEqual(model.stage, .parts)
        XCTAssertTrue(model.checkedSteps.isEmpty)
    }

    func testPartsQuestionsAndManualLookupsUseConversationServicesInsteadOfInventoryReview() async throws {
        for research in [false, true] {
            let (model, voice) = fixture()
            defer { model.cancelVoiceReply(); model.cancel() }
            await preparePlan(model)
            let question = research ? "look up the manual" : "explain the difference between these hinge types"
            var answers = 0
            model.openAIKey = { "offline-openai" }
            model.answerRepairQuestion = { text, _, _, _, _, _ in
                XCTAssertFalse(research); XCTAssertEqual(text, question)
                answers += 1; return "Conversational explanation"
            }
            model.researchQuestion = { text, _, _, _, _, _ in
                XCTAssertTrue(research); XCTAssertEqual(text, question)
                answers += 1; return MendResearchAnswer(text: "Source lookup answer", sources: [])
            }
            model.checkParts = { _, _, _, _, _ in
                XCTFail("Questions must not be interpreted as inventory evidence")
                throw MendError.message("Unexpected parts request")
            }
            voice.onDelegation?("parts-question", question)
            await until { !model.voiceReplyPending }
            XCTAssertEqual(answers, 1)
            XCTAssertEqual(model.lastAnswer, research ? "Source lookup answer" : "Conversational explanation")
            XCTAssertEqual(model.stage, .parts); XCTAssertFalse(model.partsConfirmed)
            XCTAssertTrue(model.partsIssues.isEmpty)
        }
    }

    func testConcretePartsIssueIsShownAndSpokenWithoutReplacingThePlan() async throws {
        let (model, voice) = fixture()
        defer { model.cancel() }
        await preparePlan(model)
        let savedPlan = try XCTUnwrap(model.diagnosis)
        voice.spoken = []
        let finding = "The driver you described is flat-head; the listed hinge uses a Phillips screw. Use the matching driver."
        model.checkParts = { _, _, _, _, _ in MendPartsReview(photoID: nil, issues: [finding]) }
        model.reviewParts(text: "I only have a flat-head driver")
        await until { !model.busy }
        XCTAssertEqual(model.partsIssues, [finding]); XCTAssertEqual(voice.spoken, [finding])
        XCTAssertEqual(model.diagnosis?.photoID, savedPlan.photoID)
        XCTAssertEqual(model.diagnosis?.steps.map(\.id), savedPlan.steps.map(\.id))
        XCTAssertFalse(model.partsConfirmed); XCTAssertEqual(model.stage, .parts)
        XCTAssertTrue(model.checkedSteps.isEmpty)
    }

    func testPhotoOnPartsScreenReviewsSuppliedPhotoWithoutRestartingProjectIntake() async throws {
        let (model, voice) = fixture()
        defer { model.cancel() }
        await preparePlan(model)
        let details = model.project, planID = model.diagnosis?.photoID
        let image = PhotoCanvas.examplePhoto()
        let jpeg = try XCTUnwrap(image.jpegData(compressionQuality: 0.8))
        var reviewed: MendPhoto?
        voice.spoken = []
        model.checkParts = { current, diagnosis, _, photo, _ in
            XCTAssertEqual(current, details); XCTAssertEqual(diagnosis.photoID, planID)
            reviewed = photo
            return MendPartsReview(photoID: photo?.id, issues: [])
        }
        model.acceptPhoto(jpeg, source: "Parts photo fixture")
        await until { !model.busy }
        let supplied = try XCTUnwrap(reviewed)
        XCTAssertEqual(supplied.source, "Parts photo fixture")
        XCTAssertEqual(model.partsPhoto?.id, supplied.id)
        XCTAssertEqual(model.currentPhoto?.id, supplied.id)
        XCTAssertEqual(model.project, details); XCTAssertEqual(model.confirmedProject, details)
        XCTAssertEqual(model.diagnosis?.photoID, planID)
        XCTAssertEqual(model.stage, .parts); XCTAssertTrue(voice.spoken.isEmpty)
        model.checkParts = { _, _, text, photo, _ in
            XCTAssertEqual(text, "I have a different screwdriver now")
            XCTAssertNil(photo, "A new inventory statement must not silently reuse an older photo")
            return MendPartsReview(photoID: nil, issues: [])
        }
        model.reviewParts(text: "I have a different screwdriver now")
        await until { !model.busy }
        XCTAssertEqual(model.project, details); XCTAssertEqual(model.diagnosis?.photoID, planID)
        XCTAssertTrue(voice.spoken.isEmpty)
    }

    func testCancelledOrPreviousProjectPartsResultCannotPopulateOrSpeakFindings() async throws {
        for startNewRepair in [false, true] {
            let (model, voice) = fixture()
            defer { model.cancel() }
            await preparePlan(model)
            var pending: CheckedContinuation<MendPartsReview, Never>?
            model.checkParts = { _, _, _, _, _ in await withCheckedContinuation { pending = $0 } }
            voice.spoken = []
            model.reviewParts(text: "Check these parts")
            await until { pending != nil }
            if startNewRepair { model.newRepair() } else { model.cancel() }
            pending?.resume(returning: MendPartsReview(photoID: nil, issues: ["Obsolete finding"]))
            pending = nil
            await drain()
            XCTAssertFalse(model.busy)
            XCTAssertTrue(model.partsIssues.isEmpty); XCTAssertTrue(voice.spoken.isEmpty)
            XCTAssertFalse(model.partsConfirmed)
            if startNewRepair { XCTAssertEqual(model.stage, .welcome); XCTAssertNil(model.diagnosis) }
        }
    }

    func testEditedProjectRetiresLatePartsReviewAndReleasesBusyState() async throws {
        for failure in [false, true] {
            let (model, voice) = fixture()
            defer { model.cancel() }
            await preparePlan(model)
            var pending: CheckedContinuation<MendPartsReview, Error>?
            model.checkParts = { _, _, _, _, _ in try await withCheckedThrowingContinuation { pending = $0 } }
            voice.spoken = []
            model.reviewParts(text: "I have a hinge")
            await until { pending != nil }
            model.project.model = "Corrected hinge model"
            if failure { pending?.resume(throwing: MendError.message("Old review failed")) }
            else { pending?.resume(returning: MendPartsReview(photoID: nil, issues: ["Finding for the old model"])) }
            pending = nil
            await until { !model.busy }
            XCTAssertEqual(model.project.model, "Corrected hinge model")
            XCTAssertTrue(model.partsIssues.isEmpty); XCTAssertTrue(voice.spoken.isEmpty)
            XCTAssertNil(model.partsMessage)
            XCTAssertFalse(model.partsConfirmed)
        }
    }

    func testMismatchedPartsPhotoResponseCannotShowOrSpeakItsFindings() async throws {
        let (model, voice) = fixture()
        defer { model.cancel() }
        await preparePlan(model)
        voice.spoken = []
        model.checkParts = { _, _, _, _, _ in MendPartsReview(photoID: "different-photo", issues: ["Unrelated issue"]) }
        model.reviewParts(text: "Check my parts")
        await until { !model.busy }
        XCTAssertTrue(model.partsIssues.isEmpty); XCTAssertTrue(voice.spoken.isEmpty)
        XCTAssertNotNil(model.partsMessage)
        XCTAssertFalse(model.partsConfirmed)
    }

#if !canImport(MWDATCore)
    func testTwelveNativeChecklistRowsRemainSelectableWithOnlyThreeBottomActions() async throws {
        let (model, _) = fixture(stepCount: 12)
        defer { model.cancel() }
        await preparePlan(model)
        model.perform(.confirmParts)
        let checklist = try XCTUnwrap(model.glasses.lastCard)
        XCTAssertEqual(checklist.items.map(\.id), MendActionID.stepIDs.map(\.rawValue))
        XCTAssertLessThanOrEqual(checklist.actions?.count ?? 0, 3)
        for item in checklist.items {
            XCTAssertEqual(MendVoiceActions.resolve(item.label, available: model.availableActions), .action(MendActionID(rawValue: item.id)!))
        }
        model.glasses.onAction?(MendActionID.step12.rawValue)
        XCTAssertEqual(model.stepIndex, 11); XCTAssertEqual(model.stage, .guide)
        XCTAssertTrue(model.checkedSteps.isEmpty)
        XCTAssertEqual(model.bottomActions.map(\.id), [.nextStep, .backToChecklist, .muteMic])
        model.perform(.nextStep)
        XCTAssertEqual(model.stage, .guide); XCTAssertEqual(model.stepIndex, 0)
        XCTAssertEqual(model.checkedSteps, ["step-12"])
        XCTAssertEqual(model.bottomActions.map(\.id), [.nextStep, .backToChecklist, .muteMic])
        model.glasses.onAction?(MendActionID.backToChecklist.rawValue)
        XCTAssertEqual(model.stage, .diagnosis)
        XCTAssertEqual(model.checkedSteps, ["step-12"], "Back leaves the newly opened first step unfinished")
        XCTAssertEqual(model.glasses.lastCard?.items.count, 12)
        XCTAssertLessThanOrEqual(model.glasses.lastCard?.actions?.count ?? 0, 3)
        XCTAssertTrue(model.glasses.lastCard?.items.last?.label.hasPrefix("✓") == true)
        XCTAssertFalse(model.availableActions.contains { MendActionID.checkStepIDs.contains($0.id) })
    }
#endif

    private func fixture(stepCount: Int = 3, tools: [String] = ["Screwdriver"], parts: [String] = ["Replacement hinge"]) -> (FixiModel, PartsFlowVoice) {
        let voice = PartsFlowVoice()
        let model = FixiModel(configurationError: "Offline parts test", voiceSession: voice)
        model.prepareAudioOutputForSelection = {}
        model.modelKey = { "offline-meta" }; model.openAIKey = { "" }
        model.findPhotoGuides = { _, _, _, _ in [] }
        model.locateStepCameraTarget = { photo, _, _ in
            MendGrounding(photoID: photo.id, found: false, message: "No target in this offline view.", marker: nil)
        }
        model.findExampleImage = { _, _, _ in nil }
        model.stage = .confirmation
        model.project = MendProjectDetails(make: "Unknown", model: "Cabinet hinge", problem: "Loose door")
        model.collectProject = { _, _, _, _, _ in XCTFail("Parts must not restart intake"); throw MendError.message("No intake fixture") }
        model.createPlan = { _, _, id, _ in
            MendDiagnosis(photoID: id, status: .ready, title: "Secure the hinge", summary: "Support and inspect the hinge.",
                          evidence: ["Reported loose door"], confidence: .medium, questions: [], tools: tools,
                          precautions: ["Support the door"], steps: (1...stepCount).map { number in
                MendStep(id: "step-\(number)", title: "Instruction \(number)", instruction: "Keep the door supported.",
                         expectedResult: "The door stays supported.", caution: nil, marker: nil)
            }, parts: parts)
        }
        model.checkParts = { _, _, _, photo, _ in MendPartsReview(photoID: photo?.id, issues: []) }
        return (model, voice)
    }
    private func preparePlan(_ model: FixiModel) async {
        model.confirmProject()
        await until { !model.busy && model.diagnosis != nil }
    }
    private func drain() async { for _ in 0..<30 { await Task.yield() } }
    private func until(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<1000 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Timed out waiting for parts flow", file: file, line: line)
    }
}

@MainActor private final class PartsFlowVoice: ConversationVoiceSession {
    var isActive = true, isConnecting = false, isMuted = false, isSpeaking = false
    var status = "Offline voice", inputTranscript = "", outputTranscript = "", conversationContext = ""
    var error: String?
    var onDelegation: ((String, String) -> Void)?
    var onFailure: ((String) -> Void)?
    var onStateChange: (() -> Void)?
    var onUserSpeechStarted: (() -> Void)?
    var spoken: [String] = []
    func start(apiKey: String, context: String) async throws { isActive = true }
    func stop() async { isActive = false }
    func mute() { isMuted = true }
    func unmute() { isMuted = false }
    func setOutputEnabled(_ enabled: Bool) {}
    func interruptPlayback() {}
    func sendContext(_ text: String) { conversationContext = text }
    func sayResult(_ text: String, delegationID: String?) { spoken.append(text); outputTranscript = text }
}

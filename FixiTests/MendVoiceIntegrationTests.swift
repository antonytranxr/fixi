import AVFoundation
import UIKit
import XCTest
@testable import Fixi

@MainActor
final class MendVoiceIntegrationTests: XCTestCase {
    func testNaturalFirstPersonCompletionAdvancesWithoutAnotherConfirmation() {
        for phrase in ["I'm done", "I am finished", "Yes, I'm finished", "I've finished"] {
            for overlay: MendPresentation? in [nil, .details] {
                let (model, voice) = makeModel(listeningMode: .continuous)
                model.loadDemo(); model.openChecklistStep(0); model.presentation = overlay
                model.receiveVoice(phrase, delegationID: "natural-completion")
                XCTAssertEqual(model.checkedSteps, ["support"], phrase)
                XCTAssertEqual(model.stage, .guide); XCTAssertEqual(model.stepIndex, 1)
                XCTAssertNil(model.presentation); XCTAssertFalse(model.voiceReplyPending)
                XCTAssertTrue(voice.spoken.last?.hasPrefix("Step 2.") == true)
            }
        }
    }

    func testShortAnswersToActualCompletionQuestionsAdvanceFromHelp() async {
        for (prompt, reply) in [("Are you finished with this step?", "I am"),
                                ("Were you finished?", "I was"),
                                ("Have you completed this step?", "Yes"),
                                ("Have you finished?", "Yes I have")] {
            let (model, voice) = makeModel(listeningMode: .continuous)
            model.loadDemo(); model.openChecklistStep(0); model.modelKey = { "offline" }
            var questions: [String] = []
            model.answerRepairQuestion = { text, _, _, _, _, _ in questions.append(text); return prompt }
            model.receiveVoice("Is that the right result?", delegationID: "help-before-completion")
            await model.voiceReplyTask?.value
            XCTAssertEqual(model.presentation, .details)
            XCTAssertEqual(model.lastAnswer, prompt)
            XCTAssertNotNil(model.stepCompletionPromptContext)
            let oldPrompt = model.stepCompletionPromptContext
            voice.onUserSpeechStarted?()
            model.receiveVoice(reply, delegationID: "answer-completion-prompt")
            XCTAssertEqual(model.checkedSteps, ["support"], reply)
            XCTAssertEqual(model.stage, .guide); XCTAssertEqual(model.stepIndex, 1)
            XCTAssertNil(model.presentation)
            XCTAssertNotEqual(model.stepCompletionPromptContext, oldPrompt, "The next step has its own completion invitation")
            XCTAssertEqual(questions.count, 1, "The answer must not ask the AI for another confirmation")
            XCTAssertFalse(model.voiceReplyPending)
        }
    }

    func testGeneralYesAnswersTheQuestionWithoutCompletingAStep() async {
        let (model, _) = makeModel(listeningMode: .continuous)
        model.loadDemo(); model.openChecklistStep(0); model.modelKey = { "offline" }
        var questions: [String] = []
        model.answerRepairQuestion = { text, _, _, _, _, _ in
            questions.append(text)
            return questions.count == 1 ? "Do you have a Phillips screwdriver?" : "Use the correctly fitting screwdriver."
        }
        model.askQuestion("What tool should I use?")
        await model.voiceReplyTask?.value
        XCTAssertNil(model.stepCompletionPromptContext)
        model.receiveVoice("Yes", delegationID: "tool-answer")
        await model.voiceReplyTask?.value
        XCTAssertTrue(model.checkedSteps.isEmpty); XCTAssertEqual(model.stepIndex, 0)
        XCTAssertEqual(questions, ["What tool should I use?", "Yes"])
    }

    func testRegularStepInvitationAcceptsSelfReportButNotAcknowledgement() async {
        for phrase in ["I am", "I was", "Yes I am"] {
            let (model, _) = makeModel(listeningMode: .continuous)
            model.loadDemo(); model.openChecklistStep(0)
            XCTAssertEqual(model.stepCompletionPromptContext?.allowsBareAffirmation, false)
            model.receiveVoice(phrase, delegationID: "invitation-answer")
            XCTAssertEqual(model.checkedSteps, ["support"], phrase)
            XCTAssertEqual(model.stepIndex, 1)
        }
        let (model, _) = makeModel(listeningMode: .continuous)
        model.loadDemo(); model.openChecklistStep(0); model.modelKey = { "offline" }
        model.answerRepairQuestion = { _, _, _, _, _, _ in "Keep the door supported while you work." }
        model.receiveVoice("Yes", delegationID: "instruction-acknowledgement")
        await model.voiceReplyTask?.value
        XCTAssertTrue(model.checkedSteps.isEmpty); XCTAssertEqual(model.stepIndex, 0)
    }

    func testCompletionQuestionExpiresAfterAnUnrelatedReplyAndCannotCrossSteps() async {
        let (model, voice) = makeModel(listeningMode: .continuous)
        model.loadDemo(); model.openChecklistStep(0); model.modelKey = { "offline" }
        var count = 0
        model.answerRepairQuestion = { _, _, _, _, _, _ in
            count += 1
            return count == 1 ? "Are you finished?" : "Keep the door supported while you work."
        }
        model.askQuestion("What should I check?")
        await model.voiceReplyTask?.value
        XCTAssertNotNil(model.stepCompletionPromptContext)
        model.receiveVoice("No, I need more help", delegationID: "not-finished")
        await model.voiceReplyTask?.value
        XCTAssertNil(model.stepCompletionPromptContext)
        model.receiveVoice("I am", delegationID: "unbound-short-answer")
        await model.voiceReplyTask?.value
        XCTAssertTrue(model.checkedSteps.isEmpty)

        model.answerRepairQuestion = { _, _, _, _, _, _ in "Are you finished?" }
        model.askQuestion("What should I check?")
        await model.voiceReplyTask?.value
        voice.onUserSpeechStarted?()
        model.openChecklistStep(1)
        model.receiveVoice("I was", delegationID: "old-step-answer")
        XCTAssertEqual(model.stepIndex, 1); XCTAssertTrue(model.checkedSteps.isEmpty)
        XCTAssertTrue(voice.spoken.last?.contains("screen changed") == true)
    }

    func testACompletionQuestionArrivingDuringSpeechCannotReinterpretThatUtterance() async {
        let (model, voice) = makeModel(listeningMode: .continuous)
        model.loadDemo(); model.openChecklistStep(0); model.presentation = .details
        model.lastAnswer = "Keep the door supported while you work."
        model.speakCurrentState()
        model.modelKey = { "offline" }
        var count = 0
        model.answerRepairQuestion = { _, _, _, _, _, _ in
            count += 1
            return count == 1 ? "Are you finished?" : "Tell me a little more about what you need."
        }
        voice.onUserSpeechStarted?()
        model.askQuestion("What result should I check?")
        await model.voiceReplyTask?.value
        XCTAssertNotNil(model.stepCompletionPromptContext)
        model.receiveVoice("I am", delegationID: "speech-before-question")
        await model.voiceReplyTask?.value
        XCTAssertTrue(model.checkedSteps.isEmpty); XCTAssertEqual(model.stepIndex, 0)
        XCTAssertEqual(count, 2)
    }

    func testCompletionQuestionCannotSelectAHiddenStepControl() async {
        let (model, voice) = makeModel(listeningMode: .continuous)
        model.loadDemo(); model.openChecklistStep(0); model.modelKey = { "offline" }
        var count = 0
        model.answerRepairQuestion = { _, _, _, _, _, _ in count += 1; return "Are you finished?" }
        model.askQuestion("Does that look right?")
        await model.voiceReplyTask?.value
        model.presentation = .settings
        model.receiveVoice("I was", delegationID: "hidden-control")
        XCTAssertEqual(model.presentation, .settings); XCTAssertTrue(model.checkedSteps.isEmpty)
        XCTAssertEqual(count, 1); XCTAssertFalse(model.voiceReplyPending)
        XCTAssertTrue(voice.spoken.last?.hasPrefix("Close this screen") == true)
    }

    func testACompletionPromptCannotCarryAcrossProjectIdentityEvenWithTheSameStepID() async {
        let (model, _) = makeModel(listeningMode: .continuous)
        model.loadDemo(); model.openChecklistStep(0); model.modelKey = { "offline" }
        var count = 0
        model.answerRepairQuestion = { _, _, _, _, _, _ in
            count += 1
            return count == 1 ? "Are you finished?" : "Tell me about the current instruction."
        }
        model.askQuestion("What should I check?")
        await model.voiceReplyTask?.value
        XCTAssertNotNil(model.stepCompletionPromptContext)
        // Even if a future restore path forgets to clear its prompt, the same
        // step identifier in another project must not inherit that permission.
        model.projectGeneration = UUID()
        model.receiveVoice("I was", delegationID: "different-project")
        await model.voiceReplyTask?.value
        XCTAssertTrue(model.checkedSteps.isEmpty); XCTAssertEqual(model.stepIndex, 0)
        XCTAssertEqual(count, 2)
    }

    func testNaturalCompletionCannotConfirmProjectOrParts() {
        let (model, _) = makeModel(listeningMode: .continuous)
        model.loadDemo()
        for stage: MendStage in [.welcome, .capture, .confirmation, .parts, .diagnosis] {
            model.stage = stage; model.presentation = nil
            model.createPlan = { _, _, _, _ in XCTFail("Completion is not project confirmation"); throw CancellationError() }
            model.partsConfirmed = false
            model.receiveVoice("Yes, I'm finished", delegationID: "not-step-\(stage)")
            XCTAssertEqual(model.stage, stage); XCTAssertFalse(model.partsConfirmed)
            XCTAssertTrue(model.checkedSteps.isEmpty); XCTAssertFalse(model.busy)
        }
    }

    func testSpokenStepDoneAdvancesPastCheckedStepsWithoutReconfirming() {
        let (model, voice) = makeModel(listeningMode: .continuous)
        model.loadDemo(); model.toggleChecklistStep(1); model.openChecklistStep(0)
        let confirmed = model.confirmedProject
        model.createPlan = { _, _, _, _ in XCTFail("Completion cannot request another plan"); throw CancellationError() }
        model.receiveVoice("Step done", delegationID: "finish-support")
        XCTAssertEqual(model.stage, .guide); XCTAssertEqual(model.stepIndex, 2)
        XCTAssertEqual(model.checkedSteps, ["support", "tighten"])
        XCTAssertEqual(model.confirmedProject, confirmed)
        XCTAssertTrue(voice.spoken.last?.hasPrefix("Step 3.") == true)
        model.receiveVoice("Step done", delegationID: "finish-check")
        XCTAssertEqual(model.stage, .complete); XCTAssertEqual(model.checkedSteps.count, 3)
        XCTAssertNil(model.presentation); XCTAssertFalse(model.voiceReplyPending)
    }

    func testExplicitVoiceCompletionWorksFromStepHelpPhotoSourcesAndMenu() {
        for overlay: MendPresentation? in [nil, .details, .photo, .sources, .preview, .actions] {
            let (model, voice) = makeModel(listeningMode: .continuous)
            model.loadDemo(); model.openChecklistStep(0); model.presentation = overlay
            XCTAssertEqual(MendVoiceActions.resolve("Step done", available: model.availableActions), .action(.nextStep))
            model.receiveVoice("Step done", delegationID: "finish-\(overlay?.rawValue ?? "main")")
            XCTAssertEqual(model.stage, .guide); XCTAssertEqual(model.stepIndex, 1)
            XCTAssertEqual(model.checkedSteps, ["support"])
            XCTAssertNil(model.presentation); XCTAssertFalse(model.voiceReplyPending)
            XCTAssertTrue(voice.spoken.last?.hasPrefix("Step 2.") == true)
        }
    }

    func testCompletionOutsideAnActiveInstructionStaysLocalAndCannotConfirm() {
        let (model, voice) = makeModel(listeningMode: .continuous)
        model.loadDemo()
        model.receiveVoice("Step done", delegationID: "checklist-no-active-step")
        XCTAssertEqual(model.stage, .diagnosis); XCTAssertTrue(model.checkedSteps.isEmpty)
        XCTAssertFalse(model.voiceReplyPending)
        XCTAssertTrue(voice.spoken.last?.hasPrefix("Open a checklist step") == true)
        model.openChecklistStep(0); model.presentation = .settings
        model.receiveVoice("Step done", delegationID: "settings-no-completion")
        XCTAssertEqual(model.presentation, .settings); XCTAssertTrue(model.checkedSteps.isEmpty)
        XCTAssertFalse(model.voiceReplyPending)
        XCTAssertTrue(voice.spoken.last?.hasPrefix("Close this screen") == true)
    }

    func testStepNarrationDoesNotEchoTheCompletionCommand() {
        let (model, voice) = makeModel(listeningMode: .continuous)
        model.loadDemo(); model.openChecklistStep(0)
        let narration = voice.spoken.last ?? ""
        XCTAssertFalse(narration.lowercased().contains("step done"))
        var gate = NarrationInterruptionGate(narration: narration)
        XCTAssertEqual(gate.question(from: "Step done", final: true), "Step done")
        var echoGate = NarrationInterruptionGate(narration: narration)
        XCTAssertNil(echoGate.question(from: narration, final: true))
    }

    func testCompletionDuringProcessingExplainsTheWaitWithoutCheckingWork() {
        let (model, voice) = makeModel(listeningMode: .continuous)
        model.loadDemo(); model.reviewProject()
        model.modelKey = { "offline" }
        model.createPlan = { _, _, _, _ in throw CancellationError() }
        model.confirmProject()
        XCTAssertTrue(model.busy)
        model.receiveVoice("Step done", delegationID: "busy-step")
        XCTAssertEqual(model.stage, .confirmation); XCTAssertEqual(model.stepIndex, 0)
        XCTAssertTrue(model.checkedSteps.isEmpty); XCTAssertNil(model.presentation)
        XCTAssertTrue(voice.spoken.last?.hasPrefix(model.busyLabel) == true)
        XCTAssertFalse(model.voiceReplyPending)
        model.cancel()
    }

    func testVoiceCompletionFromLastStepReturnsToAnEarlierUnfinishedStep() {
        let (model, _) = makeModel(listeningMode: .continuous)
        model.loadDemo(); model.openChecklistStep(2)
        model.receiveVoice("Mark this step complete", delegationID: "finish-last-out-of-order")
        XCTAssertEqual(model.stage, .guide); XCTAssertEqual(model.stepIndex, 0)
        XCTAssertEqual(model.checkedSteps, ["check"])
    }
    func testBoundarySwipesBrowseEveryStepWithoutMarkingAnyComplete() {
        let (model, voice) = makeModel(listeningMode: .continuous)
        model.loadDemo()
        voice.isMuted = true
        let project = model.project, photoID = model.photo?.id
        model.glasses.onNavigateBoundary?(true)
        XCTAssertEqual(model.stage, .guide); XCTAssertEqual(model.stepIndex, 0)
        for step in 0..<3 {
            XCTAssertEqual(model.stepIndex, step)
            let pageCount = model.displayPages.count
            for _ in 0..<pageCount { model.glasses.onNavigateBoundary?(true) }
            XCTAssertTrue(model.checkedSteps.isEmpty)
        }
        XCTAssertEqual(model.stage, .diagnosis)
        XCTAssertEqual(model.project, project); XCTAssertEqual(model.photo?.id, photoID)
        XCTAssertTrue(voice.isMuted)
        model.openChecklistStep(1)
        model.glasses.onNavigateBoundary?(false)
        XCTAssertEqual(model.stepIndex, 0)
        model.glasses.onNavigateBoundary?(false)
        XCTAssertEqual(model.stage, .diagnosis)
        XCTAssertTrue(model.checkedSteps.isEmpty)
    }

    func testBoundarySwipesRespectProjectAndPartsConfirmationGates() {
        let (model, _) = makeModel()
        model.loadDemo(); model.showParts(); model.partsConfirmed = false
        let lastPage = model.displayPages.count - 1
        for _ in 0..<lastPage { model.navigateGlassesBoundary(forward: true) }
        model.navigateGlassesBoundary(forward: true)
        XCTAssertEqual(model.stage, .parts); XCTAssertEqual(model.glassesPage, lastPage)
        XCTAssertFalse(model.partsConfirmed)
        model.stage = .confirmation; model.confirmedProject = nil; model.glassesPageForDetails()
        model.createPlan = { _, _, _, _ in XCTFail("A swipe cannot confirm a project"); throw MendError.message("Offline") }
        for _ in 0..<20 { model.navigateGlassesBoundary(forward: true) }
        XCTAssertEqual(model.stage, .confirmation); XCTAssertFalse(model.busy)
        XCTAssertTrue(model.checkedSteps.isEmpty)
    }

    func testBoundaryBackAndForwardRevisitConfirmedPartsWithoutRebuilding() {
        let (model, _) = makeModel()
        model.loadDemo()
        let planID = model.diagnosis?.photoID
        model.navigateGlassesBoundary(forward: false)
        XCTAssertEqual(model.stage, .parts)
        model.navigateGlassesBoundary(forward: false)
        XCTAssertEqual(model.stage, .confirmation)
        for _ in 0..<model.displayPages.count { model.navigateGlassesBoundary(forward: true) }
        XCTAssertEqual(model.stage, .parts)
        for _ in 0..<model.displayPages.count { model.navigateGlassesBoundary(forward: true) }
        XCTAssertEqual(model.stage, .diagnosis)
        XCTAssertEqual(model.diagnosis?.photoID, planID)
        XCTAssertTrue(model.partsConfirmed)
    }

    func testBoundaryAtCompleteCannotClearTheProjectOrCompletedWork() {
        let (model, _) = makeModel()
        model.loadDemo()
        for step in 0..<3 { model.openChecklistStep(step); model.checkAndAdvance() }
        let checked = model.checkedSteps, project = model.project
        model.navigateGlassesBoundary(forward: true)
        XCTAssertEqual(model.stage, .complete)
        XCTAssertEqual(model.checkedSteps, checked); XCTAssertEqual(model.project, project)
        model.navigateGlassesBoundary(forward: false)
        XCTAssertEqual(model.stage, .diagnosis); XCTAssertEqual(model.checkedSteps, checked)
    }

    func testBoundaryModalNavigationDismissesWithoutChoosingControls() {
        let (model, voice) = makeModel(listeningMode: .continuous)
        model.loadDemo(); voice.isMuted = true
        for overlay: MendPresentation in [.settings, .actions, .photo, .checklist, .sources, .comparison] {
            model.presentation = overlay; model.metaKeyDraft = "Unsaved example"
            model.navigateGlassesBoundary(forward: true)
            XCTAssertNil(model.presentation); XCTAssertEqual(model.stage, .diagnosis)
            XCTAssertTrue(model.checkedSteps.isEmpty); XCTAssertTrue(voice.isMuted)
        }
        model.presentation = .details; model.lastAnswer = String(repeating: "Help explains the current instruction. ", count: 25)
        let pages = model.displayPages.count
        XCTAssertGreaterThan(pages, 1)
        model.navigateGlassesBoundary(forward: true)
        XCTAssertEqual(model.presentation, .details); XCTAssertEqual(model.glassesPage, 1)
        for _ in 1..<pages { model.navigateGlassesBoundary(forward: true) }
        XCTAssertNil(model.presentation); XCTAssertEqual(model.glassesPage, 0)
    }

    func testBoundarySwipesAreInertDuringWorkRepliesAndBackground() {
        let (model, _) = makeModel()
        model.loadDemo()
        for state in 0..<2 {
            model.voiceReplyPending = state == 0; model.appActive = state != 1
            model.navigateGlassesBoundary(forward: true); model.navigateGlassesBoundary(forward: false)
            XCTAssertEqual(model.stage, .diagnosis); XCTAssertTrue(model.checkedSteps.isEmpty)
        }
        model.voiceReplyPending = false; model.appActive = true; model.reviewProject()
        model.modelKey = { "offline" }
        model.createPlan = { _, _, _, _ in throw CancellationError() }
        model.confirmProject()
        XCTAssertTrue(model.busy)
        model.navigateGlassesBoundary(forward: true); model.navigateGlassesBoundary(forward: false)
        XCTAssertEqual(model.stage, .confirmation); XCTAssertTrue(model.busy)
        model.cancel()
    }

    private func makeModel(listeningMode: VoiceListeningMode = .oneTurn) -> (FixiModel, MockMendVoice) {
        let voice = MockMendVoice()
        voice.listeningMode = listeningMode
        voice.isListeningForTurn = listeningMode == .continuous
        let model = FixiModel(configurationError: "Test", voiceSession: voice)
        model.prepareAudioOutputForSelection = {} // Never activate device audio in a flow test.
        model.modelKey = { "" }; model.openAIKey = { "" } // Never read real credentials in action tests.
        model.findExampleImage = { _, _, _ in nil }
        model.findPhotoGuides = { _, _, _, _ in [] }
        model.locateStepCameraTarget = { photo, _, _ in
            MendGrounding(photoID: photo.id, found: false, message: "No target in this offline view.", marker: nil)
        }
        model.checkParts = { _, _, _, photo, _ in MendPartsReview(photoID: photo?.id, issues: []) }
        return (model, voice)
    }

    private func assertTitlesResolve(_ model: FixiModel, file: StaticString = #filePath, line: UInt = #line) {
        let available = model.availableActions
        XCTAssertLessThanOrEqual(model.bottomActions.count, 3, file: file, line: line)
        XCTAssertEqual(Set(model.bottomActions.map(\.id)).count, model.bottomActions.count, file: file, line: line)
        for action in available where action.enabled {
            XCTAssertEqual(MendVoiceActions.resolve(action.title, available: available), .action(action.id),
                "\(model.stage.rawValue) / \(String(describing: model.presentation)) / \(action.title)", file: file, line: line)
        }
    }

    func testEveryCurrentButtonTitleResolvesAcrossRepairStagesAndAppOverlays() {
        let (model, voice) = makeModel()
        assertTitlesResolve(model)
        model.loadDemo()
        assertTitlesResolve(model)
        model.perform(.showParts)
        assertTitlesResolve(model)
        model.perform(.confirmParts)
        model.perform(.startGuide)
        assertTitlesResolve(model)
        model.perform(.nextStep)
        assertTitlesResolve(model)
        for presentation: MendPresentation in [.settings, .preview, .photo, .actions, .library, .camera, .audioOutput, .checklist, .details, .sources, .comparison] {
            model.presentation = presentation
            model.actionPage = 0
            assertTitlesResolve(model)
        }
        model.presentation = nil
        model.perform(.nextStep)
        assertTitlesResolve(model)
        model.perform(.nextStep)
        XCTAssertEqual(model.stage, .complete)
        assertTitlesResolve(model)
        voice.isSpeaking = true
        assertTitlesResolve(model)
        voice.isActive = false
        assertTitlesResolve(model)
    }

    func testPhoneVoiceAndGlassesCompleteAdvanceToTheSameUnfinishedInstruction() {
        let (spoken, voice) = makeModel(listeningMode: .continuous)
        let (gestured, _) = makeModel(listeningMode: .continuous)
        let (tapped, _) = makeModel(listeningMode: .continuous)
        spoken.loadDemo(); gestured.loadDemo(); tapped.loadDemo()
        voice.onDelegation?("open-middle-step", "Step 2")
        gestured.glasses.onAction?(MendActionID.step2.rawValue)
        tapped.perform(.step2)
        for model in [spoken, gestured, tapped] {
            XCTAssertEqual(model.stage, .guide)
            XCTAssertEqual(model.stepIndex, 1)
            XCTAssertTrue(model.checkedSteps.isEmpty, "Selecting a row never completes it")
        }
        for (number, expectedNext) in [(1, 2), (2, 0), (3, 0)] {
            voice.onDelegation?("step-\(number)", "Complete")
            gestured.glasses.onAction?(MendActionID.nextStep.rawValue)
            tapped.perform(.nextStep)
            XCTAssertEqual(spoken.checkedSteps, gestured.checkedSteps)
            XCTAssertEqual(spoken.checkedSteps, tapped.checkedSteps)
            XCTAssertEqual(spoken.checkedSteps.count, number)
            for model in [spoken, gestured, tapped] {
                XCTAssertEqual(model.stage, number < 3 ? .guide : .complete)
                XCTAssertEqual(model.stepIndex, expectedNext, "Completion opens the next unfinished instruction, wrapping when necessary")
                XCTAssertNil(model.presentation)
            }
        }
        XCTAssertEqual(spoken.stage, .complete)
        XCTAssertEqual(spoken.checkedSteps.count, 3)
        let previous = spoken.stepIndex
        spoken.glasses.onAction?("unknown-action")
        spoken.glasses.onAction?(MendActionID.nextStep.rawValue)
        XCTAssertEqual(spoken.stepIndex, previous)
        XCTAssertEqual(spoken.checkedSteps.count, 3)
    }

    func testVisibleChecklistTitlesSelectTheirOwnStepWithoutCompletingIt() throws {
        let (model, voice) = makeModel(listeningMode: .continuous)
        model.loadDemo()
        let steps = try XCTUnwrap(model.diagnosis).steps
        for (index, step) in steps.enumerated() {
            XCTAssertEqual(MendVoiceActions.resolve(step.title, available: model.availableActions),
                           .action(MendActionID.stepIDs[index]))
            voice.onDelegation?("visible-step-\(index)", step.title)
            XCTAssertEqual(model.stage, .guide)
            XCTAssertEqual(model.currentStep?.id, step.id)
            XCTAssertTrue(model.checkedSteps.isEmpty, "Saying a row title opens its details without completing it")
            model.backToChecklist()
        }
    }

    func testVisibleSourceTitlesResolveOnlyWhenTheSourcesAreAvailable() {
        let (model, _) = makeModel()
        model.loadDemo()
        model.answerSources = [
            MendSource(title: "Cabinet hinge installation manual", url: URL(string: "https://example.com/installation")!),
            MendSource(title: "Hinge adjustment guide", url: URL(string: "https://example.com/adjustment")!)
        ]
        XCTAssertEqual(MendVoiceActions.resolve(model.answerSources[0].title, available: model.availableActions), .unmatched)
        model.presentation = .sources
        for (index, source) in model.answerSources.enumerated() {
            // Resolve the selection without dispatching it or opening an external URL.
            XCTAssertEqual(MendVoiceActions.resolve(source.title, available: model.availableActions),
                           .action(MendActionID.sourceIDs[index]))
        }
    }

    func testDisabledAndOutOfContextActionsCannotDispatchOrInterruptReplies() {
        let (model, voice) = makeModel()
        let before = voice.interruptCalls
        model.perform(.nextStep)
        model.glasses.onAction?(MendActionID.startGuide.rawValue)
        XCTAssertEqual(model.stage, .welcome)
        XCTAssertEqual(model.checkedSteps.count, 0)
        XCTAssertEqual(voice.interruptCalls, before)
        model.voiceStopping = true
        XCTAssertFalse(model.isEnabled(.stopVoice))
        model.perform(.stopVoice)
        XCTAssertEqual(voice.stopCalls, 0)
        model.voiceStopping = false
        model.presentation = .settings
        voice.captureSuspended = true
        XCTAssertFalse(model.isEnabled(.testSound))
        model.perform(.testSound)
        XCTAssertTrue(voice.outputChanges.isEmpty)
        XCTAssertNil(model.audioTestTask)
    }

    func testPausingRepliesPreservesListeningAndVoiceResume() {
        let (model, voice) = makeModel(listeningMode: .continuous)
        model.loadDemo(); model.perform(.startGuide)
        voice.onDelegation?("pause", "Pause replies")
        XCTAssertTrue(model.voiceRepliesPaused)
        XCTAssertEqual(voice.outputChanges, [false])
        XCTAssertTrue(voice.isActive)
        XCTAssertFalse(voice.isMuted)
        XCTAssertEqual(voice.muteCalls, 0)
        XCTAssertEqual(voice.stopCalls, 0)
        voice.onDelegation?("next", "Next step")
        XCTAssertEqual(model.stage, .guide, "Voice completion advances without reopening the checklist")
        XCTAssertEqual(model.stepIndex, 1)
        XCTAssertEqual(model.checkedSteps, ["support"])
        voice.onDelegation?("resume", "Resume replies")
        XCTAssertFalse(model.voiceRepliesPaused)
        XCTAssertEqual(voice.outputChanges, [false, true])
        XCTAssertEqual(voice.unmuteCalls, 0, "Resume changes speech output, not microphone capture")
    }

    func testMenuDoneClosesControlsWithoutCheckingARepairStep() {
        let (model, voice) = makeModel(listeningMode: .continuous)
        model.loadDemo(); model.perform(.startGuide); model.perform(.showActions)
        XCTAssertEqual(model.presentation, .actions)
        let resolution = MendVoiceActions.resolve("Done", available: model.availableActions)
        XCTAssertEqual(resolution, .action(.closeActions))
        // Avoid accidentally making a network request if a label regresses to unmatched.
        guard resolution == .action(.closeActions) else { return }
        voice.onDelegation?("close-actions", "Done")
        XCTAssertNil(model.presentation)
        XCTAssertEqual(model.stepIndex, 0)
        XCTAssertTrue(model.checkedSteps.isEmpty)
    }

    func testModalLabelsDispatchOnlyTheirOwnDismissControl() {
        let (model, voice) = makeModel(listeningMode: .continuous)
        model.loadDemo(); model.perform(.startGuide)
        for presentation: MendPresentation in [.settings, .preview, .photo] {
            model.presentation = presentation
            let expected: MendActionID = presentation == .settings ? .closeSettings : presentation == .preview ? .closePreview : .closePhoto
            let resolution = MendVoiceActions.resolve("Done", available: model.availableActions)
            XCTAssertEqual(resolution, .action(expected))
            guard resolution == .action(expected) else { continue }
            voice.onDelegation?("close-\(presentation)", "Done")
            XCTAssertNil(model.presentation)
            XCTAssertEqual(model.stepIndex, 0)
            XCTAssertTrue(model.checkedSteps.isEmpty)
        }
    }

    func testInactiveMutedAndBackgroundSessionsIgnoreIncomingCommands() {
        let (model, voice) = makeModel(listeningMode: .continuous)
        model.loadDemo(); model.perform(.startGuide)
        voice.isActive = false
        model.receiveVoice("Next step", delegationID: "inactive")
        voice.isActive = true; voice.isMuted = true
        model.receiveVoice("Next step", delegationID: "muted")
        voice.isMuted = false; model.appActive = false
        model.receiveVoice("Next step", delegationID: "background")
        XCTAssertEqual(model.stepIndex, 0)
        XCTAssertTrue(model.checkedSteps.isEmpty)
    }

    func testBackgroundRejectsTouchAndNativeGestureActions() {
        let (model, voice) = makeModel()
        model.loadDemo(); model.perform(.startGuide)
        let interruptions = voice.interruptCalls
        model.appActive = false
        model.perform(.nextStep)
        model.glasses.onAction?(MendActionID.nextStep.rawValue)
        XCTAssertEqual(model.stepIndex, 0)
        XCTAssertTrue(model.checkedSteps.isEmpty)
        XCTAssertEqual(voice.interruptCalls, interruptions)
    }

    func testCameraCannotBeginDuringConversationStartupOrShutdown() {
        let (model, _) = makeModel()
        model.voiceStarting = true
        model.capture()
        XCTAssertFalse(model.busy)
        XCTAssertNil(model.errorMessage, "Startup rejection must occur before inspecting glasses registration")
        model.voiceStarting = false; model.voiceStopping = true
        model.capture()
        XCTAssertFalse(model.busy)
        XCTAssertNil(model.errorMessage)
    }

    func testPartialsPreservePendingAnswerWhileFinalSpeechAndNewRepairCancelIt() {
        let (model, voice) = makeModel(listeningMode: .continuous)
        model.loadDemo(); model.perform(.startGuide)
        let firstTask = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
        model.voiceReplyPending = true; model.voiceReplyTask = firstTask
        let firstID = model.voiceReplyID
        voice.isReceivingSpeech = true
        voice.onUserSpeechStarted?()
        XCTAssertTrue(model.heardSpeech)
        XCTAssertTrue(model.voiceReplyPending, "An unfinished fragment must not cancel a useful answer")
        XCTAssertFalse(firstTask.isCancelled)
        XCTAssertEqual(model.voiceReplyID, firstID)
        let selection = model.voiceUtteranceContext
        voice.isReceivingSpeech = false
        voice.onStateChange?()
        XCTAssertFalse(model.heardSpeech)
        XCTAssertEqual(model.voiceUtteranceContext, selection, "Recognition end preserves the selection until final dispatch")
        voice.onDelegation?("accepted-final", "Back")
        XCTAssertFalse(model.voiceReplyPending)
        XCTAssertNil(model.voiceReplyTask)
        XCTAssertTrue(firstTask.isCancelled)
        XCTAssertNotEqual(model.voiceReplyID, firstID)
        let secondTask = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
        model.voiceReplyPending = true; model.voiceReplyTask = secondTask
        let secondID = model.voiceReplyID
        model.newRepair()
        XCTAssertFalse(model.voiceReplyPending)
        XCTAssertNil(model.voiceReplyTask)
        XCTAssertTrue(secondTask.isCancelled)
        XCTAssertNotEqual(model.voiceReplyID, secondID)
        XCTAssertEqual(model.stage, .welcome)
        XCTAssertNil(model.diagnosis)
    }

    func testQuestionNegationAndQuotedButtonTextNeverResolveAsRepairActions() {
        let (model, _) = makeModel()
        model.loadDemo(); model.perform(.startGuide)
        for text in ["What does Checked do", "Do not go next", "Say next", "next and previous", "\"Checked\"", "if next"] {
            XCTAssertEqual(MendVoiceActions.resolve(text, available: model.availableActions), .unmatched, text)
        }
        XCTAssertEqual(model.stepIndex, 0)
        XCTAssertTrue(model.checkedSteps.isEmpty)
    }

    func testSpeechStartedBeforeHandNavigationCannotAdvanceTheNewStepAgain() {
        let (model, voice) = makeModel(listeningMode: .continuous)
        model.loadDemo(); model.perform(.startGuide)
        voice.onUserSpeechStarted?()
        model.glasses.onAction?(MendActionID.nextStep.rawValue)
        XCTAssertEqual(model.stage, .guide)
        XCTAssertEqual(model.stepIndex, 1)
        voice.onDelegation?("late-next", "Checked")
        XCTAssertEqual(model.stepIndex, 1)
        XCTAssertEqual(model.checkedSteps.count, 1)
        XCTAssertTrue(voice.spoken.last?.contains("screen changed") == true)
        voice.onUserSpeechStarted?()
        voice.onDelegation?("fresh-next", "Checked")
        XCTAssertEqual(model.stepIndex, 2)
        XCTAssertEqual(model.stage, .guide)
        XCTAssertEqual(model.checkedSteps.count, 2)
    }

    func testMicrophoneMuteIsAvailableInEveryAppOverlayAndNeedsTouchOrGestureToResume() {
        let (model, voice) = makeModel(listeningMode: .continuous)
        model.loadDemo()
        for presentation: MendPresentation? in [nil, .settings, .preview, .photo, .actions, .library, .camera, .audioOutput, .checklist, .details, .sources, .comparison] {
            model.presentation = presentation
            XCTAssertTrue(model.isEnabled(.muteMic), "\(String(describing: presentation))")
            XCTAssertEqual(MendVoiceActions.resolve("mute me", available: model.availableActions), .action(.muteMic))
            model.receiveVoice("mute microphone", delegationID: "mute")
            XCTAssertTrue(voice.isMuted)
            XCTAssertTrue(voice.isActive)
            XCTAssertFalse(model.isEnabled(.muteMic))
            XCTAssertTrue(model.isEnabled(.unmuteMic))
            XCTAssertTrue(model.voiceStatus.contains("Microphone muted"))
            model.receiveVoice("unmute mic", delegationID: "ignored-while-muted")
            XCTAssertTrue(voice.isMuted, "The app must not claim voice unmute when native recognition is stopped")
            model.glasses.onAction?(MendActionID.unmuteMic.rawValue)
            XCTAssertFalse(voice.isMuted)
            XCTAssertTrue(voice.isActive)
            XCTAssertEqual(model.presentation, presentation, "Mic controls must not move the current screen")
        }
        XCTAssertEqual(voice.stopCalls, 0)
    }

    func testContinuousMicrophoneControlsStayInTheFooterWithoutTalkOrWakeWord() {
        let (model, voice) = makeModel(listeningMode: .continuous)
        model.loadDemo()
        for stage: MendStage in [.welcome, .capture, .confirmation, .parts, .diagnosis, .guide, .complete] {
            model.stage = stage
            for presentation: MendPresentation? in [nil, .settings, .preview, .photo, .actions, .library, .camera, .audioOutput, .checklist, .details, .sources, .comparison] {
                model.presentation = presentation
                voice.isMuted = false
                XCTAssertTrue(model.voiceInputIsOpen)
                XCTAssertTrue(model.bottomActions.contains { $0.id == .muteMic && $0.title == "Mute mic" && $0.enabled }, "\(stage) / \(String(describing: presentation))")
                XCTAssertFalse(model.availableActions.contains { $0.id == .talk || $0.id == .focusListening })
                XCTAssertFalse(model.voiceStatus.contains("Hey Fixi"))
                assertTitlesResolve(model)
                voice.isMuted = true
                XCTAssertFalse(model.voiceInputIsOpen)
                XCTAssertTrue(model.bottomActions.contains { $0.id == .unmuteMic && $0.enabled })
                assertTitlesResolve(model)
            }
        }
        model.presentation = nil; model.stage = .guide; voice.isMuted = false
        XCTAssertEqual(model.bottomActions.map(\.id), [.nextStep, .backToChecklist, .muteMic])
        model.perform(.backToChecklist)
        XCTAssertTrue(model.bottomActions.contains { $0.id == .showActions }, "Back keeps Menu available with three guide buttons")
    }

    func testOneTurnDefaultsClosedWithoutWakeWordAndPhysicalTalkOpensIt() {
        let (model, voice) = makeModel()
        model.loadDemo()
        XCTAssertEqual(voice.listeningMode, .oneTurn)
        XCTAssertFalse(voice.requiresAddress)
        XCTAssertFalse(voice.isListeningForTurn)
        XCTAssertTrue(model.isEnabled(.talk))
        XCTAssertFalse(model.isEnabled(.muteMic))
        XCTAssertFalse(model.isEnabled(.focusListening))
        XCTAssertFalse(model.voiceStatus.contains("Hey Fixi"))
        XCTAssertEqual(MendVoiceActions.resolve("Talk", available: model.availableActions), .action(.talk))
        XCTAssertEqual(MendVoiceActions.resolve("Require Hey Fixi", available: model.availableActions), .unmatched)
        model.glasses.onAction?(MendActionID.talk.rawValue)
        XCTAssertTrue(voice.isListeningForTurn)
        XCTAssertFalse(voice.isMuted)
        XCTAssertEqual(voice.listenCalls, 1)
        XCTAssertFalse(model.isEnabled(.talk))
        XCTAssertTrue(model.isEnabled(.muteMic))
        XCTAssertEqual(model.voiceActions.first { $0.id == .muteMic }?.title, "Stop listening")
        XCTAssertEqual(voice.stopCalls, 0)
    }

    func testVoiceCannotOpenItsOwnListeningWindowOrCancelPendingAnswerBySayingTalk() {
        let (model, voice) = makeModel()
        model.loadDemo()
        let pending = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
        defer { pending.cancel() }
        model.voiceReplyPending = true; model.voiceReplyTask = pending
        let replyID = model.voiceReplyID
        let interruptions = voice.interruptCalls
        model.receiveVoice("Talk", delegationID: "voice-cannot-open-mic")
        XCTAssertFalse(voice.isListeningForTurn)
        XCTAssertEqual(voice.listenCalls, 0)
        XCTAssertEqual(voice.interruptCalls, interruptions)
        XCTAssertTrue(model.voiceReplyPending)
        XCTAssertEqual(model.voiceReplyID, replyID)
        XCTAssertFalse(pending.isCancelled)
        model.glasses.onAction?(MendActionID.talk.rawValue)
        XCTAssertTrue(voice.isListeningForTurn)
        XCTAssertFalse(model.voiceReplyPending)
        XCTAssertNil(model.voiceReplyTask)
        XCTAssertNotEqual(model.voiceReplyID, replyID)
        XCTAssertTrue(pending.isCancelled)
        XCTAssertGreaterThan(voice.interruptCalls, interruptions)
    }

    func testTalkClearsExplicitMuteButVoiceCannotUnmuteAndBackgroundCannotOpen() {
        let (model, voice) = makeModel()
        model.loadDemo()
        voice.mute()
        XCTAssertTrue(voice.isMuted)
        XCTAssertTrue(model.isEnabled(.talk))
        XCTAssertFalse(model.isEnabled(.unmuteMic))
        model.receiveVoice("Talk", delegationID: "muted")
        XCTAssertTrue(voice.isMuted)
        XCTAssertFalse(voice.isListeningForTurn)
        model.appActive = false
        model.glasses.onAction?(MendActionID.talk.rawValue)
        XCTAssertEqual(voice.listenCalls, 0)
        model.appActive = true
        model.glasses.onAction?(MendActionID.talk.rawValue)
        XCTAssertEqual(voice.listenCalls, 1)
        XCTAssertFalse(voice.isMuted)
        XCTAssertTrue(voice.isListeningForTurn)
        XCTAssertEqual(voice.unmuteCalls, 0, "Talk explicitly opens one turn instead of continuous unmute")
    }

    func testCompletedOneTurnStillDispatchesAfterNativeMicrophoneCloses() {
        let (model, voice) = makeModel()
        model.loadDemo(); model.perform(.startGuide)
        model.glasses.onAction?(MendActionID.talk.rawValue)
        voice.onUserSpeechStarted?()
        voice.isListeningForTurn = false
        voice.onStateChange?()
        voice.onDelegation?("completed-native-turn", "Complete")
        XCTAssertEqual(model.stage, .guide)
        XCTAssertEqual(model.stepIndex, 1)
        XCTAssertEqual(model.checkedSteps, ["support"])
        XCTAssertFalse(voice.isListeningForTurn)
        XCTAssertTrue(model.isEnabled(.talk))
        XCTAssertEqual(voice.listenCalls, 1, "Completing a turn never silently opens another")
    }

    func testTalkOrStopListeningRemainsInThreeButtonFooterAcrossStagesAndOverlays() {
        let (model, voice) = makeModel()
        model.loadDemo()
        for stage: MendStage in [.welcome, .capture, .confirmation, .parts, .diagnosis, .guide, .complete] {
            model.stage = stage
            for presentation: MendPresentation? in [nil, .settings, .preview, .photo, .actions, .library, .camera, .audioOutput, .checklist, .details, .sources, .comparison] {
                model.presentation = presentation
                voice.isListeningForTurn = false; voice.isMuted = false
                XCTAssertTrue(model.bottomActions.contains { $0.id == .talk && $0.enabled }, "\(stage) / \(String(describing: presentation))")
                assertTitlesResolve(model)
                voice.isListeningForTurn = true
                XCTAssertTrue(model.bottomActions.contains { $0.id == .muteMic && $0.title == "Stop listening" && $0.enabled })
                XCTAssertFalse(model.bottomActions.contains { $0.id == .talk })
                assertTitlesResolve(model)
                voice.isListeningForTurn = false; voice.isMuted = true
                XCTAssertTrue(model.bottomActions.contains { $0.id == .talk && $0.enabled })
                assertTitlesResolve(model)
            }
        }
        model.presentation = nil; model.stage = .guide; voice.isMuted = false
        XCTAssertEqual(model.bottomActions.map(\.id), [.nextStep, .backToChecklist, .talk])
        model.perform(.backToChecklist)
        XCTAssertTrue(model.bottomActions.contains { $0.id == .showActions }, "Back keeps the menu reachable without a fourth guide button")
    }

#if !canImport(MWDATCore)
    func testNativeChecklistPrefersStepOneAcrossChecklistPresentationsAndReturns() throws {
        let (model, _) = makeModel(listeningMode: .continuous)
        model.loadDemo()
        XCTAssertEqual(model.glasses.lastCard?.preferredActionID, MendActionID.step1.rawValue)
        XCTAssertEqual(model.glasses.lastCard?.items.first?.id, MendActionID.step1.rawValue)

        model.perform(.step2)
        XCTAssertNil(model.glasses.lastCard?.preferredActionID, "Step details keep their normal controls")
        model.perform(.showChecklist)
        XCTAssertEqual(model.glasses.lastCard?.preferredActionID, MendActionID.step1.rawValue)
        model.perform(.closeChecklist)
        model.perform(.backToChecklist)
        XCTAssertEqual(model.glasses.lastCard?.preferredActionID, MendActionID.step1.rawValue)

        model.perform(.step1)
        for index in 0..<3 {
            XCTAssertEqual(model.stage, .guide)
            XCTAssertEqual(model.stepIndex, index)
            model.perform(.nextStep)
        }
        XCTAssertEqual(model.stage, .complete)
        XCTAssertEqual(model.glasses.lastCard?.preferredActionID, MendActionID.step1.rawValue,
                       "The completed checklist still starts at its first row")

        model.voiceReplyPending = true
        model.syncDisplay()
        let progress = try XCTUnwrap(model.glasses.lastCard)
        XCTAssertTrue(progress.items.isEmpty)
        XCTAssertNil(progress.preferredActionID, "A progress card cannot target a hidden checklist row")
        model.voiceReplyPending = false
    }

    func testInactiveNativeCardOverridesEveryScreenAndProgressWithoutControls() throws {
        let (model, _) = makeModel(listeningMode: .continuous)
        model.loadDemo()
        model.appActive = false
        model.voiceReplyPending = true
        model.replyLabel = "Thinking…"; model.progressDetail = "Still working…"
        for stage: MendStage in [.welcome, .capture, .confirmation, .parts, .diagnosis, .guide, .complete] {
            for presentation: MendPresentation? in [nil, .checklist, .details, .photo, .actions, .settings] {
                model.stage = stage; model.presentation = presentation
                model.syncDisplay()
                let card = try XCTUnwrap(model.glasses.lastCard)
                XCTAssertEqual(card.title, "Phone app disconnected")
                XCTAssertEqual(card.text, "Open the app to continue.")
                XCTAssertEqual(card.actions, [])
                XCTAssertTrue(card.items.isEmpty)
                XCTAssertTrue(card.staticRows.isEmpty)
                XCTAssertNil(card.image)
                XCTAssertNil(card.preferredActionID)
                XCTAssertFalse(card.previous); XCTAssertFalse(card.next); XCTAssertFalse(card.capture)
            }
        }
        model.voiceReplyPending = false
    }

    func testBackgroundNoticeSurvivesVoiceShutdownAndCallbacksUntilResume() async throws {
        let (model, voice) = makeModel(listeningMode: .continuous)
        model.loadDemo()
        model.glasses.registered = true; model.glasses.available = true
        model.glasses.connect(startCamera: false)
        let project = model.project
        model.pauseForBackground()
        XCTAssertFalse(model.appActive)
        XCTAssertEqual(model.glasses.lastCard?.title, "Phone app disconnected")
        await model.voiceLifecycle?.value
        XCTAssertFalse(voice.isActive)
        voice.onStateChange?()
        model.glasses.onStateChange?()
        model.glasses.onAction?(MendActionID.startVoice.rawValue)
        model.glasses.onAction?(MendActionID.step1.rawValue)
        let inactive = try XCTUnwrap(model.glasses.lastCard)
        XCTAssertEqual(inactive.title, "Phone app disconnected")
        XCTAssertEqual(inactive.actions, [])
        XCTAssertTrue(inactive.items.isEmpty)
        XCTAssertEqual(model.stage, .diagnosis)
        XCTAssertEqual(model.project, project)
        XCTAssertTrue(model.checkedSteps.isEmpty)
        XCTAssertFalse(voice.isActive, "A stale Glasses button cannot reopen voice while inactive")

        model.resumeFromBackground()
        let resumed = try XCTUnwrap(model.glasses.lastCard)
        XCTAssertTrue(model.appActive)
        XCTAssertTrue(resumed.title.contains("Checklist"))
        XCTAssertEqual(resumed.preferredActionID, MendActionID.step1.rawValue)
        XCTAssertEqual(resumed.items.first?.id, MendActionID.step1.rawValue)
        XCTAssertEqual(model.project, project)
    }

    func testWelcomeCardAfterTheNativeIntroShowsOnlyTheProjectPrompt() throws {
        let (model, _) = makeModel(listeningMode: .continuous)
        model.stage = .welcome
        model.syncDisplay()
        let card = try XCTUnwrap(model.glasses.lastCard)
        XCTAssertEqual(card.title, "What should we work on today?")
        XCTAssertEqual(card.text, "")
        XCTAssertNil(card.image, "The dedicated native intro already shows and fades the brand")
    }

    func testNativeLoadingCardShowsProgressOnceAndKeepsCancelAndMuteReachable() throws {
        let (model, voice) = makeModel(listeningMode: .continuous)
        model.stage = .capture
        model.glasses.registered = true; model.glasses.available = true
        model.glasses.connect(startCamera: true)
        model.glasses.deliverLiveFrame(try XCTUnwrap(UIImage(systemName: "laptopcomputer")))
        model.liveViewEnabled = true
        model.voiceReplyPending = true
        model.replyLabel = "Thinking…"
        model.progressDetail = "Still working…"
        model.renderGlasses()

        let card = try XCTUnwrap(model.glasses.lastCard)
        XCTAssertEqual(card.title, "Thinking…")
        XCTAssertEqual(card.text, "Still working…")
        let content = card.title + "\n" + card.text
        XCTAssertEqual(content.components(separatedBy: "Still working").count - 1, 1)
        XCTAssertFalse(content.contains("Listening"))
        XCTAssertFalse(content.contains("Camera"))
        XCTAssertNil(card.image)
        XCTAssertTrue(card.items.isEmpty)
        let actions = try XCTUnwrap(card.actions)
        XCTAssertLessThanOrEqual(actions.count, 3)
        XCTAssertTrue(actions.contains { $0.id == MendActionID.cancel.rawValue && $0.enabled })
        XCTAssertTrue(actions.contains { $0.id == MendActionID.muteMic.rawValue && $0.enabled })
        XCTAssertEqual(model.liveViewStatus, "Camera live", "Phone camera feedback remains available")
        XCTAssertEqual(model.voiceInputLabel, "Listening", "Phone microphone feedback remains available")

        model.glasses.onAction?(MendActionID.muteMic.rawValue)
        XCTAssertTrue(voice.isMuted)
        XCTAssertTrue(model.voiceReplyPending, "Muting must not cancel the work in progress")
        let mutedCard = try XCTUnwrap(model.glasses.lastCard)
        XCTAssertEqual(mutedCard.text, "Still working…")
        XCTAssertTrue(mutedCard.actions?.contains { $0.id == MendActionID.unmuteMic.rawValue && $0.enabled } == true)
        XCTAssertTrue(mutedCard.actions?.contains { $0.id == MendActionID.cancel.rawValue && $0.enabled } == true)
    }

    func testNativeProjectCardOmitsPassiveStatusesWhilePhoneStillReportsThem() throws {
        let (model, voice) = makeModel(listeningMode: .continuous)
        model.stage = .confirmation
        model.project = MendProjectDetails(make: "Apple", model: "MacBook Pro", problem: "Will not restart")
        model.glasses.registered = true; model.glasses.available = true
        model.glasses.connect(startCamera: true)
        model.glasses.deliverLiveFrame(try XCTUnwrap(UIImage(systemName: "laptopcomputer")))
        model.liveViewEnabled = true
        model.renderGlasses()

        let card = try XCTUnwrap(model.glasses.lastCard)
        XCTAssertEqual(card.title, "Have I got it right?")
        XCTAssertEqual(card.text, model.displayPages[0])
        XCTAssertFalse(card.text.contains("Listening"))
        XCTAssertFalse(card.text.contains("Camera"))
        XCTAssertEqual(model.statusText, "Listening")
        XCTAssertEqual(model.liveViewStatus, "Camera live")
        XCTAssertTrue(card.actions?.contains { $0.id == MendActionID.muteMic.rawValue && $0.enabled } == true)

        model.glasses.onAction?(MendActionID.muteMic.rawValue)
        XCTAssertTrue(voice.isMuted)
        XCTAssertEqual(model.statusText, "Microphone muted")
        XCTAssertEqual(model.glasses.lastCard?.text, model.displayPages[0], "Muting changes the control, not the repair instructions")
    }

    func testNativePagingKeepsTalkAndStopListeningAlongsidePageNavigation() throws {
        let (model, voice) = makeModel()
        model.project = MendProjectDetails(make: "Apple", model: "MacBook Pro",
            problem: String(repeating: "The screen freezes while restarting and the keyboard does not respond. ", count: 10))
        for stage: MendStage in [.capture, .confirmation] {
            for listening in [false, true] {
                model.stage = stage; model.presentation = nil
                // The fixture starts at page zero and each case navigates back there.
                XCTAssertEqual(model.glassesPage, 0)
                voice.isListeningForTurn = listening
                let microphone: MendActionID = listening ? .muteMic : .talk
                let pageCount = model.displayPages.count
                XCTAssertGreaterThan(pageCount, 2, "Exercise middle pages with both More and Previous page")
                model.syncDisplay()
                for page in 0..<pageCount {
                    XCTAssertEqual(model.glassesPage, page)
                    let actions = try XCTUnwrap(model.glasses.lastCard?.actions)
                    XCTAssertLessThanOrEqual(actions.count, 3)
                    XCTAssertTrue(actions.contains { $0.id == microphone.rawValue && $0.enabled })
                    if page > 0 { XCTAssertTrue(actions.contains { $0.id == MendActionID.back.rawValue && $0.enabled }) }
                    if page + 1 < pageCount {
                        XCTAssertTrue(actions.contains { $0.id == MendActionID.more.rawValue && $0.enabled })
                        model.glasses.onAction?(MendActionID.more.rawValue)
                    }
                    XCTAssertEqual(model.stage, stage, "Reading pages never confirms or advances the project")
                }
                while model.glassesPage > 0 {
                    let before = model.glassesPage
                    let actions = try XCTUnwrap(model.glasses.lastCard?.actions)
                    XCTAssertTrue(actions.contains { $0.id == microphone.rawValue && $0.enabled })
                    XCTAssertTrue(actions.contains { $0.id == MendActionID.back.rawValue && $0.enabled })
                    model.glasses.onAction?(MendActionID.back.rawValue)
                    XCTAssertEqual(model.glassesPage, before - 1)
                    if model.glassesPage >= before { break }
                }
                XCTAssertEqual(model.glassesPage, 0)
                XCTAssertEqual(model.stage, stage)
                XCTAssertEqual(voice.isListeningForTurn, listening, "Page navigation must preserve the explicit microphone window")
            }
        }
    }
#endif

    func testTalkFromMenuKeepsTheVisibleSelectionsAndCurrentRepair() {
        let (model, voice) = makeModel()
        model.loadDemo(); model.perform(.startGuide); model.perform(.showActions)
        XCTAssertEqual(model.presentation, .actions)
        let stepID = model.currentStep?.id
        model.glasses.onAction?(MendActionID.talk.rawValue)
        XCTAssertEqual(model.presentation, .actions, "Opening the microphone must not dismiss the labels the user wants to say")
        XCTAssertEqual(model.currentStep?.id, stepID)
        XCTAssertTrue(model.checkedSteps.isEmpty)
        XCTAssertTrue(voice.isListeningForTurn)
        XCTAssertEqual(model.bottomActions.map(\.id), [.closeActions, .muteMic])
        voice.onUserSpeechStarted?()
        voice.isListeningForTurn = false
        voice.onDelegation?("menu-done", "Done")
        XCTAssertNil(model.presentation)
        XCTAssertEqual(model.currentStep?.id, stepID)
        XCTAssertTrue(model.checkedSteps.isEmpty)
    }

    func testStopListeningAfterNativeTurnClosesNeverBecomesAnAIQuestion() async {
        for utterance in ["Stop listening", "mute me", "mute microphone"] {
            let (model, voice) = makeModel()
            model.loadDemo(); model.perform(.startGuide)
            model.modelKey = { "offline-test-key" }
            var questions: [String] = []
            model.answerRepairQuestion = { text, _, _, _, _, _ in questions.append(text); return "Unexpected answer" }
            model.glasses.onAction?(MendActionID.talk.rawValue)
            XCTAssertTrue(model.isEnabled(.muteMic))
            voice.onUserSpeechStarted?()
            voice.isListeningForTurn = false
            voice.onStateChange?()
            voice.onDelegation?("stop-turn", utterance)
            for _ in 0..<5 { await Task.yield() }
            XCTAssertTrue(voice.isMuted, utterance)
            XCTAssertFalse(voice.isListeningForTurn)
            XCTAssertEqual(voice.muteCalls, 1)
            XCTAssertFalse(model.voiceReplyPending)
            XCTAssertNil(model.voiceReplyTask)
            XCTAssertTrue(questions.isEmpty, "A microphone command must not enter repair reasoning")
            XCTAssertNil(model.lastAnswer)
            XCTAssertEqual(model.stage, .guide)
            XCTAssertTrue(model.checkedSteps.isEmpty)
            XCTAssertTrue(model.isEnabled(.talk))
        }
    }

    func testSlowOperationKeepsVisualProgressButDoesNotSpeakOverAnOpenedTalkTurn() async throws {
        let (listeningModel, listeningVoice) = makeModel()
        let (quietModel, quietVoice) = makeModel()
        for model in [listeningModel, quietModel] {
            model.modelKey = { "offline-test-key" }
            model.collectProject = { _, _, _, _, _ in
                try await Task.sleep(for: .seconds(60))
                throw CancellationError()
            }
            model.startProject(); model.collectDetails(text: "The door is loose", includePhoto: false)
            XCTAssertTrue(model.busy)
        }
        defer { listeningModel.cancel(); quietModel.cancel() }
        listeningModel.glasses.onAction?(MendActionID.talk.rawValue)
        XCTAssertTrue(listeningVoice.isListeningForTurn)
        XCTAssertFalse(listeningModel.heardSpeech, "No ASR partial has arrived yet")
        try await Task.sleep(for: .milliseconds(1400))
        XCTAssertTrue(listeningModel.busy, "Talk must not cancel the project extraction")
        XCTAssertNotNil(listeningModel.progressTitle)
        XCTAssertTrue(listeningVoice.spoken.isEmpty, "The delayed status cue must not speak into an open turn")
        XCTAssertFalse(listeningModel.feedbackSpoken)
        XCTAssertTrue(listeningVoice.isListeningForTurn)
        XCTAssertEqual(quietVoice.spoken, ["I’m checking the project details."], "Closed-mic operations still receive the useful spoken progress cue")
        XCTAssertTrue(quietModel.feedbackSpoken)
    }

    func testAudioOutputIsReachableByVoiceAndGestureWithoutLosingPendingRepairAnswer() {
        let (model, voice) = makeModel()
        model.loadDemo()
        var preparations = 0
        model.prepareAudioOutputForSelection = { preparations += 1 }
        let pending = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
        defer { pending.cancel() }
        model.voiceReplyPending = true; model.voiceReplyTask = pending
        let replyID = model.voiceReplyID
        model.metaKeyDraft = "private draft"; model.voiceKeyDraft = "private draft"
        XCTAssertEqual(MendVoiceActions.resolve("Choose glasses", available: model.availableActions), .action(.audioOutput))
        model.glasses.onAction?(MendActionID.audioOutput.rawValue)
        XCTAssertEqual(preparations, 1)
        XCTAssertEqual(model.presentation, .audioOutput)
        XCTAssertTrue(model.voiceReplyPending)
        XCTAssertEqual(model.voiceReplyID, replyID)
        XCTAssertTrue(model.metaKeyDraft.isEmpty); XCTAssertTrue(model.voiceKeyDraft.isEmpty)
        XCTAssertTrue(voice.isActive); XCTAssertEqual(voice.stopCalls, 0)
        model.perform(.closePicker)
        XCTAssertNil(model.presentation)
        XCTAssertTrue(model.voiceReplyPending)
        XCTAssertEqual(model.voiceReplyID, replyID)
        model.cancelVoiceReply()
    }

    func testClosingListeningPreservesPendingAnswerAndCurrentNarration() {
        let (model, voice) = makeModel()
        model.loadDemo()
        model.glasses.onAction?(MendActionID.talk.rawValue)
        let pending = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
        defer { pending.cancel() }
        model.voiceReplyPending = true; model.voiceReplyTask = pending
        let replyID = model.voiceReplyID
        voice.isSpeaking = true
        let interruptions = voice.interruptCalls
        XCTAssertTrue(model.isEnabled(.muteMic))
        model.perform(.muteMic)
        XCTAssertFalse(voice.isListeningForTurn)
        XCTAssertTrue(model.voiceReplyPending, "Closing the mic must not cancel a question already being processed")
        XCTAssertNotNil(model.voiceReplyTask)
        XCTAssertEqual(model.voiceReplyID, replyID)
        XCTAssertFalse(pending.isCancelled)
        XCTAssertEqual(voice.interruptCalls, interruptions)
        XCTAssertTrue(voice.isSpeaking)
        XCTAssertTrue(voice.isActive)
        XCTAssertTrue(model.isEnabled(.talk))
        XCTAssertFalse(model.isEnabled(.focusListening))
    }

    func testChecklistRowsOpenDetailsAndOnlyCompleteMarksThemWhileBackPreservesProgress() {
        let (model, voice) = makeModel(listeningMode: .continuous)
        model.loadDemo()
        XCTAssertEqual(MendVoiceActions.resolve("step one", available: model.availableActions), .action(.step1))
        XCTAssertEqual(MendVoiceActions.resolve("step one done", available: model.availableActions), .unmatched)
        model.glasses.onAction?(MendActionID.checkStep1.rawValue)
        XCTAssertTrue(model.checkedSteps.isEmpty, "Legacy row-check commands are no longer offered")
        model.glasses.onAction?(MendActionID.step2.rawValue)
        XCTAssertEqual(model.stage, .guide)
        XCTAssertEqual(model.stepIndex, 1)
        XCTAssertTrue(model.checkedSteps.isEmpty)
        model.receiveVoice("Back", delegationID: "back-without-completing")
        XCTAssertEqual(model.stage, .diagnosis)
        XCTAssertTrue(model.checkedSteps.isEmpty)
        for (index, nextIndex) in [(1, 2), (0, 2), (2, 2)] {
            model.glasses.onAction?(MendActionID.stepIDs[index].rawValue)
            XCTAssertEqual(model.stage, .guide)
            XCTAssertEqual(model.stepIndex, index)
            model.glasses.onAction?(MendActionID.nextStep.rawValue)
            XCTAssertTrue(model.checkedSteps.contains(model.diagnosis!.steps[index].id))
            XCTAssertEqual(model.stage, model.checkedSteps.count == 3 ? .complete : .guide)
            XCTAssertEqual(model.stepIndex, nextIndex)
            if model.stage == .guide {
                let checked = model.checkedSteps
                model.glasses.onAction?(MendActionID.backToChecklist.rawValue)
                XCTAssertEqual(model.stage, .diagnosis)
                XCTAssertEqual(model.checkedSteps, checked, "Back does not complete the newly opened instruction")
            }
        }
        XCTAssertEqual(model.stage, .complete)
        XCTAssertNil(model.presentation)
        XCTAssertEqual(model.checkedSteps.count, 3)
        model.receiveVoice("Step two", delegationID: "inspect-completed-step")
        XCTAssertEqual(model.stage, .guide); XCTAssertEqual(model.stepIndex, 1)
        XCTAssertEqual(model.checkedSteps.count, 3, "Reopening instructions does not silently undo completion")
        model.perform(.backToChecklist)
        XCTAssertEqual(model.stage, .complete)
        XCTAssertEqual(model.checkedSteps.count, 3)
        XCTAssertTrue(voice.isActive)
        XCTAssertEqual(voice.stopCalls, 0)
    }

    func testNonfatalSpeechOutputNoticeDoesNotEndNativeListening() {
        let (model, voice) = makeModel(listeningMode: .continuous)
        voice.onNotice?("Spoken replies are unavailable; microphone controls still work.")
        XCTAssertTrue(voice.isActive)
        XCTAssertEqual(voice.stopCalls, 0)
        XCTAssertFalse(model.voiceStopping)
        XCTAssertTrue(model.voiceNotice?.contains("microphone controls") == true)
        model.loadDemo()
        model.receiveVoice("Start guide", delegationID: "after-notice")
        XCTAssertEqual(model.stage, .guide)
    }

    func testChangingOpenAICredentialsRekeysOutputWithoutEndingNativeVoice() {
        let (model, voice) = makeModel()
        model.presentation = .settings
        var writes: [String?] = []
        model.writeResearchKey = { writes.append($0) }
        model.voiceKeyDraft = "offline-research-fixture"
        model.perform(.saveVoiceKey)
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(writes[0], "offline-research-fixture")
        XCTAssertEqual(voice.outputKeys, ["offline-research-fixture"])
        XCTAssertTrue(voice.isActive); XCTAssertEqual(voice.stopCalls, 0); XCTAssertFalse(model.voiceStopping)
        model.perform(.forgetVoiceKey)
        XCTAssertEqual(writes.count, 2); XCTAssertNil(writes[1])
        XCTAssertTrue(model.voiceKeyDraft.isEmpty)
        XCTAssertEqual(voice.outputKeys, ["offline-research-fixture", ""])
        XCTAssertTrue(voice.isActive); XCTAssertEqual(voice.stopCalls, 0); XCTAssertFalse(model.voiceStopping)
    }
    func testPhotoFocusControlsKeepStepAndVoiceAndRestoreOnNewStep() {
        let (model, voice) = makeModel()
        model.loadDemo(); model.openChecklistStep(1)
        let original = model.currentPhoto!
        XCTAssertTrue(model.photoIsFocused)
        XCTAssertLessThan(model.annotatedImage!.size.width, original.image.size.width)
        XCTAssertEqual(MendVoiceActions.resolve("zoom out", available: model.availableActions), .action(.showFullPhoto))
        let interruptions = voice.interruptCalls
        model.perform(.showFullPhoto)
        XCTAssertFalse(model.photoIsFocused)
        XCTAssertEqual(model.annotatedImage!.size, original.image.size)
        XCTAssertEqual(model.currentPhoto!.jpeg, original.jpeg)
        XCTAssertEqual(voice.interruptCalls, interruptions)
        XCTAssertTrue(voice.isActive); XCTAssertTrue(model.checkedSteps.isEmpty)
        model.presentation = .photo
        XCTAssertEqual(MendVoiceActions.resolve("Close-up", available: model.availableActions), .action(.focusPhoto))
        model.glasses.onAction?(MendActionID.focusPhoto.rawValue)
        XCTAssertTrue(model.photoIsFocused); XCTAssertEqual(model.presentation, .photo)
        model.perform(.showFullPhoto); model.perform(.closePhoto)
        model.openChecklistStep(2)
        XCTAssertTrue(model.photoIsFocused, "Each instruction starts focused on its own part")
    }

    func testPhotoFocusIsUnavailableWithoutAnInstructionMarker() {
        let (model, _) = makeModel()
        model.loadDemo()
        XCTAssertFalse(model.canFocusPhoto)
        XCTAssertFalse(model.photoIsFocused)
        XCTAssertFalse(model.isEnabled(.showFullPhoto))
        model.perform(.focusPhoto)
        XCTAssertEqual(model.stage, .diagnosis)
        XCTAssertTrue(model.checkedSteps.isEmpty)
    }

    func testComparingDesignsPreservesPendingAnswerRepairPhotoAndMicrophone() {
        let (model, voice) = makeModel()
        model.loadDemo(); model.openChecklistStep(1)
        model.lastAnswer = "Keep supporting the door."
        model.voiceReplyPending = true
        let pending = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
        defer { pending.cancel() }
        model.voiceReplyTask = pending
        let replyID = model.voiceReplyID, photoID = model.currentPhoto?.id
        let project = model.project, step = model.currentStep?.id
        voice.isMuted = true
        var saved: [MendExperience] = []
        model.saveExperience = { saved.append($0) }
        let interruptions = voice.interruptCalls
        for (action, expected): (MendActionID, MendExperience) in [(.useFlow, .flow), (.useGuide, .guide), (.useFocus, .focus)] {
            model.perform(.compareDesigns)
            XCTAssertEqual(model.presentation, .comparison)
            model.perform(action)
            XCTAssertEqual(model.experience, expected); XCTAssertNil(model.presentation)
            XCTAssertEqual(model.voiceReplyID, replyID); XCTAssertTrue(model.voiceReplyPending)
            XCTAssertEqual(model.lastAnswer, "Keep supporting the door.")
            XCTAssertEqual(model.project, project); XCTAssertEqual(model.currentStep?.id, step)
            XCTAssertEqual(model.currentPhoto?.id, photoID); XCTAssertTrue(model.checkedSteps.isEmpty)
            XCTAssertTrue(voice.isActive); XCTAssertTrue(voice.isMuted)
        }
        XCTAssertEqual(saved, [.flow, .guide, .focus])
        XCTAssertEqual(voice.interruptCalls, interruptions); XCTAssertEqual(voice.stopCalls, 0)
        model.cancelVoiceReply()
    }

    func testComparisonSelectionsAreScopedToThePickerAndMatchGestureControls() {
        let (model, _) = makeModel()
        XCTAssertEqual(model.experience, .focus)
        model.perform(.useFlow)
        XCTAssertEqual(model.experience, .focus)
        model.glasses.onAction?(MendActionID.compareDesigns.rawValue)
        for action in model.availableActions where [.useFocus, .useFlow, .useGuide].contains(action.id) {
            XCTAssertEqual(MendVoiceActions.resolve(action.title, available: model.availableActions), .action(action.id))
        }
        model.glasses.onAction?(MendActionID.useFlow.rawValue)
        XCTAssertEqual(model.experience, .flow); XCTAssertNil(model.presentation)
        XCTAssertEqual(MendVoiceActions.resolve("Guide", available: model.availableActions), .unmatched)
        model.perform(.compareDesigns); model.perform(.closeComparison)
        XCTAssertNil(model.presentation); XCTAssertEqual(model.experience, .flow)
    }

    func testEachDesignKeepsTheSameRepairControlsAndExplicitCompletion() {
        let (model, voice) = makeModel(listeningMode: .continuous)
        model.loadDemo()
        let originalActions = Set(model.availableActions.map(\.id))
        for (action, expected): (MendActionID, MendExperience) in [(.useFocus, .focus), (.useFlow, .flow), (.useGuide, .guide)] {
            model.perform(.compareDesigns); model.perform(action)
            XCTAssertEqual(model.experience, expected)
            XCTAssertEqual(Set(model.availableActions.map(\.id)), originalActions)
            XCTAssertTrue(model.checkedSteps.isEmpty)
            assertTitlesResolve(model)
        }
        model.receiveVoice("Step two", delegationID: "open-comparison-step")
        XCTAssertEqual(model.stage, .guide); XCTAssertEqual(model.stepIndex, 1)
        XCTAssertTrue(model.checkedSteps.isEmpty)
        model.receiveVoice("Step done", delegationID: "complete-comparison-step")
        XCTAssertEqual(model.checkedSteps.count, 1); XCTAssertTrue(voice.isActive)
        XCTAssertEqual(model.stage, .guide); XCTAssertEqual(model.stepIndex, 2)
    }

}

@MainActor
private final class MockMendVoice: ConversationVoiceSession {
    var isActive = true
    var isConnecting = false
    var isMuted = false
    var isSpeaking = false
    var isReceivingSpeech = false
    var captureSuspended = false
    var requiresAddress = false
    var listeningMode: VoiceListeningMode = .oneTurn
    var isListeningForTurn = false
    var status = "Listening"
    var inputTranscript = ""
    var outputTranscript = ""
    var error: String?
    var conversationContext = ""
    var onDelegation: ((String, String) -> Void)?
    var onFailure: ((String) -> Void)?
    var onNotice: ((String) -> Void)?
    var onStateChange: (() -> Void)?
    var onUserSpeechStarted: (() -> Void)?
    var outputChanges: [Bool] = []
    var outputKeys: [String] = []
    var spoken: [String] = []
    var interruptCalls = 0
    var muteCalls = 0
    var unmuteCalls = 0
    var stopCalls = 0
    var listenCalls = 0
    var focusChanges: [Bool] = []

    func start(apiKey: String, context: String) async throws { isActive = true }
    func stop() async { stopCalls += 1; isActive = false; isListeningForTurn = false }
    func mute() { muteCalls += 1; isMuted = true; isListeningForTurn = false }
    func unmute() { unmuteCalls += 1; isMuted = false; isListeningForTurn = listeningMode == .continuous }
    func listenForOneTurn() {
        guard isActive else { return }
        listenCalls += 1; isMuted = false; isListeningForTurn = true
    }
    func setOutputAPIKey(_ key: String) { outputKeys.append(key) }
    func setOutputEnabled(_ enabled: Bool) { outputChanges.append(enabled) }
    func interruptPlayback() { interruptCalls += 1; isSpeaking = false }
    func sendContext(_ text: String) { conversationContext = text }
    func sayResult(_ text: String, delegationID: String?) { spoken.append(text); outputTranscript = text }
    func setCaptureSuspended(_ suspended: Bool) { captureSuspended = suspended }
    func setRequiresAddress(_ enabled: Bool) { focusChanges.append(enabled); requiresAddress = enabled }
}

import XCTest
@testable import Fixi

final class VoiceActionsTests: XCTestCase {
    private let next = MendAction(id: .nextStep, title: "Checked — next")
    private let previous = MendAction(id: .previousStep, title: "Previous step")

    func testEveryRegisteredTitleCanBeSpokenExactly() {
        for id in MendActionID.allCases {
            let action = MendAction(id: id, title: "Control \(id.rawValue)")
            XCTAssertEqual(MendVoiceActions.resolve(action.title, available: [action]), .action(id), id.rawValue)
            XCTAssertEqual(MendVoiceActions.resolve("Please select the \(action.title) button.", available: [action]), .action(id), id.rawValue)
        }
    }

    func testActualTitlesAliasesAndPoliteSelectionWrappers() {
        let examples = ["Checked — next", "checked next", "NEXT!", "next step", "Please, next.",
            "Tap next", "select the next button", "Press Checked — next, please.", "choose next please"]
        for phrase in examples {
            XCTAssertEqual(MendVoiceActions.resolve(phrase, available: [next, previous]), .action(.nextStep), phrase)
        }
        let custom = MendAction(id: .startGuide, title: "Start this guide", aliases: ["begin repair"])
        XCTAssertEqual(MendVoiceActions.resolve("begin repair", available: [custom]), .action(.startGuide))
        XCTAssertEqual(MendVoiceActions.resolve("read this step", available: [MendAction(id: .repeatStep, title: "Repeat step")]), .action(.repeatStep))
    }

    func testDisabledOrAbsentControlsNeverDispatch() {
        let disabled = MendAction(id: .nextStep, title: next.title, aliases: ["continue"], enabled: false)
        for phrase in ["next", next.title, "continue", "please tap next"] {
            XCTAssertEqual(MendVoiceActions.resolve(phrase, available: [disabled]), .unmatched)
            XCTAssertEqual(MendVoiceActions.resolve(phrase, available: [previous]), .unmatched)
        }
        XCTAssertEqual(MendVoiceActions.resolve("finish repair", available: [next]), .unmatched, "Finishing is not a default alias on earlier steps")
    }

    func testNegationsQuestionsQuotedInstructionsAndMultiCommandsNeverDispatch() {
        let phrases = ["don't next", "Don’t press next", "do not tap next", "never next", "no next", "not next", "without next",
            "What does next do", "what is next", "should I press next", "can you tap next", "next?", "why next", "how do I choose next",
            "say next", "please say next", "saying next", "quote next", "\"next\"", "'next'", "“next”", "‘next’", "`next`",
            "next and previous", "next then previous", "next, cancel", "next. Previous.", "when next", "if next", "unless next",
            "next step is difficult", "the next step", "nex", "nextish", "press next now", "I finished the next step"]
        for phrase in phrases {
            XCTAssertEqual(MendVoiceActions.resolve(phrase, available: [next, previous, MendAction(id: .cancel, title: "Cancel")]), .unmatched, phrase)
        }
    }

    func testContextualAliasesCannotChooseAnAmbiguousStage() {
        let settings = MendAction(id: .closeSettings, title: "Done")
        let photo = MendAction(id: .closePhoto, title: "Close photo")
        XCTAssertEqual(MendVoiceActions.resolve("done", available: [settings]), .action(.closeSettings))
        XCTAssertEqual(MendVoiceActions.resolve("done", available: [photo]), .action(.closePhoto))
        XCTAssertEqual(MendVoiceActions.resolve("done", available: [settings, photo]), .unmatched)
        XCTAssertEqual(MendVoiceActions.resolve("close photo", available: [settings, photo]), .action(.closePhoto))
        let other = MendAction(id: .previousStep, title: "Different", aliases: ["Checked next"])
        XCTAssertEqual(MendVoiceActions.resolve(next.title, available: [next, other]), .unmatched, "Exact title cannot override another active control's identical alias")
        XCTAssertEqual(MendVoiceActions.resolve("next", available: [next, next]), .action(.nextStep), "Repeated instances of one action are not ambiguous")
    }

    func testExplicitStepCompletionIsDistinctFromClosingHelpAndConfirmingAProject() {
        let completion = MendAction(id: .nextStep, title: "Complete")
        let close = MendAction(id: .closeDetails, title: "Done")
        let confirmation = MendAction(id: .confirmProject, title: "Confirm")
        let available = [completion, close, confirmation]
        for phrase in ["Step done", "Step done.", "Please select the Step done button", "Done with this step", "I completed this step"] {
            XCTAssertEqual(MendVoiceActions.resolve(phrase, available: available), .action(.nextStep), phrase)
        }
        XCTAssertEqual(MendVoiceActions.resolve("Done", available: available), .action(.closeDetails))
        XCTAssertEqual(MendVoiceActions.resolve("Confirm", available: available), .action(.confirmProject))
        for phrase in ["Step done?", "Step not done", "I haven't completed this step", "Say step done", "\"Step done\""] {
            XCTAssertEqual(MendVoiceActions.resolve(phrase, available: available), .unmatched, phrase)
        }
    }

    func testUnavailableStepCompletionCannotBecomeProjectConfirmation() {
        let confirmation = MendAction(id: .confirmProject, title: "Confirm")
        let disabled = MendAction(id: .nextStep, title: "Complete", enabled: false)
        for phrase in ["Step done", "Done with this step", "I completed this step"] {
            XCTAssertEqual(MendVoiceActions.resolve(phrase, available: [confirmation]), .unmatched, phrase)
            XCTAssertEqual(MendVoiceActions.resolve(phrase, available: [confirmation, disabled]), .unmatched, phrase)
        }
    }

    func testExplicitStepCompletionIntentUsesWholeUtterancesAndSharedControlAliases() {
        let completion = MendAction(id: .nextStep, title: "Complete")
        for phrase in ["Step done", "STEP DONE!", "Done with this step", "I completed this step", "I finished the step",
                       "I've completed this step", "I have finished the step", "Complete step", "This step is done",
                       "Mark this step complete", "Mark the step as complete", "Please mark this step done",
                       "Please select the Step done button."] {
            XCTAssertTrue(MendVoiceActions.isExplicitStepCompletion(phrase), phrase)
            XCTAssertEqual(MendVoiceActions.resolve(phrase, available: [completion]), .action(.nextStep), phrase)
        }
        for phrase in ["Done", "Next", "Next step", "Finish", "Complete", "Checked", "I did it", "",
                       "Step done?", "Step not done", "I haven't completed this step", "Don't mark this step complete",
                       "Say step done", "\"Step done\"", "What happens after step done", "Step done and next step",
                       "I completed this step yesterday but it failed", "Mark this step complete later",
                       String(repeating: "Step done ", count: 40)] {
            XCTAssertFalse(MendVoiceActions.isExplicitStepCompletion(phrase), phrase)
        }
    }

    func testNaturalFirstPersonCompletionIsLocalWithoutMakingBareAffirmationsCommands() {
        let completion = MendAction(id: .nextStep, title: "Complete")
        for phrase in ["I'm done", "I’m finished", "I am finished", "I was finished", "Yes, I'm finished",
                       "Yeah, I am done", "I've finished", "I have completed it", "Okay, I finished it"] {
            XCTAssertTrue(MendVoiceActions.isExplicitStepCompletion(phrase), phrase)
            XCTAssertEqual(MendVoiceActions.resolve(phrase, available: [completion]), .action(.nextStep), phrase)
        }
        for phrase in ["Yes", "I am", "I was", "Yes I am", "Yes I did", "Yep"] {
            XCTAssertFalse(MendVoiceActions.isExplicitStepCompletion(phrase), phrase)
            XCTAssertEqual(MendVoiceActions.resolve(phrase, available: [completion]), .unmatched, phrase)
            XCTAssertTrue(MendVoiceActions.isStepCompletionAffirmation(phrase), phrase)
        }
        for phrase in ["I am", "I was", "Yes I am", "Yes I did"] {
            XCTAssertTrue(MendVoiceActions.isStepCompletionSelfReport(phrase), phrase)
        }
        for phrase in ["Yes", "Yeah", "Yep"] {
            XCTAssertFalse(MendVoiceActions.isStepCompletionSelfReport(phrase), phrase)
        }
        for phrase in ["I'm not done", "No, I was", "I am?", "Am I finished?", "Yes, but I need help",
                       "I'm finished with my coffee", "She said I'm finished", "\"I am\"", "I'm done and skip the next step"] {
            XCTAssertFalse(MendVoiceActions.isExplicitStepCompletion(phrase), phrase)
            XCTAssertFalse(MendVoiceActions.isStepCompletionAffirmation(phrase), phrase)
            XCTAssertFalse(MendVoiceActions.isStepCompletionSelfReport(phrase), phrase)
            XCTAssertEqual(MendVoiceActions.resolve(phrase, available: [completion]), .unmatched, phrase)
        }
    }

    func testOnlyTheLatestSpecificCompletionQuestionArmsAShortAnswer() {
        for prompt in ["Are you done?", "Were you finished?", "Have you finished this step?",
                       "Check the result first. Have you completed the step?", "Is this step complete?",
                       "Need help? Have you finished it?", "So, are you finished with this step?"] {
            XCTAssertTrue(MendVoiceActions.asksForStepCompletion(prompt), prompt)
        }
        for prompt in ["Tell me when you’ve finished.", "Are you ready to start?", "Do you have a screwdriver?",
                       "Have you completed this step? Do you need help?", "Are you not finished?",
                       "How do you know this step is complete?", "Say yes to continue", "The step is done."] {
            XCTAssertFalse(MendVoiceActions.asksForStepCompletion(prompt), prompt)
        }
    }

    func testExplicitHelpAndBoundedInput() {
        XCTAssertEqual(MendVoiceActions.resolve("voice help", available: [next]), .help)
        XCTAssertEqual(MendVoiceActions.resolve("Please, help!", available: [next]), .help)
        XCTAssertEqual(MendVoiceActions.resolve("what voice commands are available", available: [next]), .unmatched)
        XCTAssertEqual(MendVoiceActions.resolve("show actions", available: [MendAction(id: .showActions, title: "Actions")]), .action(.showActions))
        XCTAssertEqual(MendVoiceActions.resolve(String(repeating: "next ", count: 100), available: [next]), .unmatched)
        XCTAssertEqual(MendVoiceActions.resolve("  ", available: [next]), .unmatched)
    }

    func testReplyPauseKeepsASeparateResumeCommand() {
        let paused = MendAction(id: .resumeReplies, title: "Resume spoken replies")
        XCTAssertEqual(MendVoiceActions.resolve("resume replies", available: [paused]), .action(.resumeReplies))
        XCTAssertEqual(MendVoiceActions.resolve("pause replies", available: [paused]), .unmatched)
        let paging = [MendAction(id: .nextActions, title: "More actions"), MendAction(id: .previousActions, title: "Back")]
        XCTAssertEqual(MendVoiceActions.resolve("next page", available: paging), .action(.nextActions))
        XCTAssertEqual(MendVoiceActions.resolve("back", available: paging), .action(.previousActions))
    }
}

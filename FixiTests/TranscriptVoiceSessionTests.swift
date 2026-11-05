import XCTest
@testable import Fixi

@MainActor final class TranscriptVoiceSessionTests: XCTestCase {
    func testFinalizedQuestionIsDelegatedOnceWithoutRestartingRecognition() async throws {
        let (session, input, _) = fixture()
        var questions: [String] = [], starts = 0
        session.onDelegation = { _, text in questions.append(text) }
        session.onUserSpeechStarted = { starts += 1 }
        try await session.start(apiKey: "offline", context: "Task")
        input.emitAddressed("Which filter", false); input.emitAddressed("Which filter is this?", true)
        input.emitAddressed("Which filter is this?", true)
        XCTAssertEqual(questions, ["Which filter is this?"])
        XCTAssertEqual(starts, 1); XCTAssertEqual(input.startCount, 1)
        XCTAssertTrue(session.isActive)
        await session.stop()
    }

    func testPauseFallbackDoesNotReplayLateFinalOrAmbientFiller() async throws {
        let (session, input, _) = fixture(pause: .milliseconds(5))
        var questions: [String] = []
        session.onDelegation = { _, text in questions.append(text) }
        try await session.start(apiKey: "offline", context: "")
        input.emitAddressed("um uh", true); input.emitAddressed("", true)
        input.emitAddressed("How tight should this be", false)
        await until { questions.count == 1 }
        input.emitAddressed("How tight should this be", true)
        XCTAssertEqual(questions, ["How tight should this be"])
        await session.stop()
    }

    func testNarrationEchoAndNovelPartialDoNotInterruptButFinalDoes() async throws {
        let (session, input, output) = fixture()
        var questions: [String] = [], interrupted = 0
        session.onDelegation = { _, text in questions.append(text) }
        session.onUserSpeechStarted = { interrupted += 1 }
        try await session.start(apiKey: "offline", context: "")
        session.sayResult("Disconnect the power before opening the cover.")
        await until { output.texts.count == 1 }
        input.emitAddressed("Disconnect the power", false)
        XCTAssertTrue(session.isSpeaking); XCTAssertEqual(interrupted, 0)
        input.emitAddressed("Where is the power switch", false)
        XCTAssertTrue(session.isSpeaking); XCTAssertEqual(interrupted, 1)
        XCTAssertEqual(input.stopCount, 0)
        input.emitAddressed("Where is the power switch?", true)
        XCTAssertFalse(session.isSpeaking); XCTAssertEqual(interrupted, 1)
        XCTAssertEqual(questions, ["Where is the power switch?"])
        input.emitAddressed("Where is the power switch?", true)
        XCTAssertEqual(questions.count, 1); XCTAssertEqual(interrupted, 1)
        await session.stop()
    }

    func testMuteRejectsLateTextAndUnmuteReusesSameNativeInput() async throws {
        let input = TranscriptTestInput(), output = TranscriptTestOutput()
        var factories = 0, questions = 0
        let session = TranscriptVoiceSession(makeSpeechInput: { factories += 1; return input }, output: output, listeningMode: .continuous)
        session.setRequiresAddress(true)
        session.onDelegation = { _, _ in questions += 1 }
        try await session.start(apiKey: "offline", context: "")
        let stale = input.onText
        session.mute(); stale?("Hey Fixi, Next step", true)
        XCTAssertEqual(questions, 0); XCTAssertTrue(session.isMuted)
        session.unmute()
        await until { input.startCount == 2 }
        input.emitAddressed("Next step", true)
        XCTAssertEqual(factories, 1); XCTAssertEqual(questions, 1)
        await session.stop()
    }

    func testStopInvalidatesCallbacksAndPendingSpeech() async throws {
        let (session, input, output) = fixture()
        var questions = 0
        session.onDelegation = { _, _ in questions += 1 }
        try await session.start(apiKey: "offline", context: "")
        let stale = input.onText
        let cue = Task { await session.speakAndWait("Aim at the filter housing.") }
        await until { output.texts.count == 1 }
        await session.stop()
        let result = await cue.value
        stale?("Hey Fixi, Take photo", true)
        XCTAssertFalse(result); XCTAssertFalse(session.isActive); XCTAssertEqual(questions, 0)
        XCTAssertEqual(output.stopCount, 1)
    }

    func testCameraSuspensionKeepsCommandsAndDefersReplyUntilCameraOff() async throws {
        let (session, input, output) = fixture()
        var questions: [String] = []
        session.onDelegation = { _, text in questions.append(text) }
        try await session.start(apiKey: "offline", context: "")
        session.setCaptureSuspended(true)
        input.emitAddressed("Stop clip", true)
        session.sayResult("Clip ready. Choose Use clip.")
        await Task.yield()
        XCTAssertTrue(output.texts.isEmpty); XCTAssertEqual(input.stopCount, 0)
        XCTAssertEqual(questions, ["Stop clip"])
        session.setCaptureSuspended(false)
        await until { output.texts.count == 1 }
        XCTAssertEqual(output.texts, ["Clip ready. Choose Use clip."])
        output.finish(true)
        await until { !session.isSpeaking }
        await session.stop()
    }

    func testExplicitCueSupersedesReplyQueuedByCameraResume() async throws {
        let (session, _, output) = fixture()
        try await session.start(apiKey: "offline", context: "")
        session.setCaptureSuspended(true)
        session.sayResult("Old parked reply")
        session.setCaptureSuspended(false)
        let finisher = Task { @MainActor in
            await self.until { output.texts.contains("Aim at the filter") }
            output.finish(true)
        }
        let result = await session.speakAndWait("Aim at the filter")
        await finisher.value
        XCTAssertTrue(result)
        XCTAssertEqual(output.texts, ["Aim at the filter"])
        await session.stop()
    }

    func testNewQuestionRejectsOldDelegatedReply() async throws {
        let (session, input, output) = fixture()
        var ids: [String] = []
        session.onDelegation = { id, _ in ids.append(id) }
        try await session.start(apiKey: "offline", context: "")
        input.emitAddressed("What is this", true)
        input.emitAddressed("Actually how do I stop", false)
        session.sayResult("The original answer is still accepted.", delegationID: ids.first)
        await until { output.texts.count == 1 }
        XCTAssertTrue(session.isSpeaking)
        input.emitAddressed("Actually how do I stop", true)
        session.sayResult("Stale answer", delegationID: ids.first)
        session.sayResult("Stop the engine.", delegationID: ids.last)
        await until { output.texts.count == 2 }
        XCTAssertEqual(output.texts, ["The original answer is still accepted.", "Stop the engine."])
        await session.stop()
    }

    func testSpeechOffSkipsOutputButCueFenceStillCompletes() async throws {
        let (session, _, output) = fixture()
        try await session.start(apiKey: "offline", context: "")
        session.setOutputEnabled(false)
        session.sayResult("No spoken reply")
        let complete = await session.speakAndWait("Aim at the panel")
        XCTAssertTrue(complete); XCTAssertTrue(output.texts.isEmpty)
        await session.stop()
    }

    func testPausedRepliesKeepNavigationListeningAndCanResumeByVoice() async throws {
        let (session, input, output) = fixture()
        var commands: [String] = []
        session.onDelegation = { id, text in
            commands.append(text)
            if text == "Resume replies" {
                session.setOutputEnabled(true)
                session.sayResult("Spoken replies are on.", delegationID: id)
            }
        }
        try await session.start(apiKey: "offline", context: "")
        session.setOutputEnabled(false)
        input.emitAddressed("Next step", true)
        session.sayResult("Step two is ready.")
        await Task.yield()
        XCTAssertEqual(commands, ["Next step"])
        XCTAssertTrue(output.texts.isEmpty)
        XCTAssertEqual(input.stopCount, 0)
        input.emitAddressed("Resume replies", true)
        await until { output.texts.count == 1 }
        XCTAssertEqual(commands, ["Next step", "Resume replies"])
        XCTAssertEqual(output.texts, ["Spoken replies are on."])
        XCTAssertEqual(input.startCount, 1)
        await session.stop()
    }

    func testSpokenCredentialsAreRedactedBeforeDisplayDelegationOrHistory() async throws {
        let (session, input, _) = fixture()
        var questions: [String] = []
        session.onDelegation = { _, text in questions.append(text) }
        try await session.start(apiKey: "offline", context: "Repair context")
        input.emitAddressed("My API key is sk-private-test-token", false)
        XCTAssertFalse(session.inputTranscript.contains("sk-private"))
        XCTAssertFalse(session.conversationContext.contains("sk-private"))
        // A revision can drop the disclosure prefix; the turn stays redacted.
        input.emitAddressed("private test token", true)
        XCTAssertEqual(questions, ["api key is [redacted]"])
        XCTAssertFalse(session.inputTranscript.contains("private test token"))
        XCTAssertEqual(session.conversationContext, "Repair context")
        input.emitAddressed("Next step", true)
        XCTAssertEqual(questions.last, "Next step")
        XCTAssertTrue(session.conversationContext.contains("User: Next step"))
        await session.stop()
    }

    func testCredentialPauseFallbackDelegatesOnlyTheRedactedSentinel() async throws {
        let (session, input, _) = fixture(pause: .milliseconds(5))
        var questions: [String] = []
        session.onDelegation = { _, text in questions.append(text) }
        try await session.start(apiKey: "offline", context: "")
        input.emitAddressed("sk-only-secret-token", false)
        await until { questions.count == 1 }
        XCTAssertEqual(questions, ["api key is [redacted]"])
        XCTAssertFalse(session.inputTranscript.contains("sk-only"))
        XCTAssertTrue(session.conversationContext.isEmpty)
        input.emitAddressed("only secret token", true)
        XCTAssertEqual(questions, ["api key is [redacted]"])
        XCTAssertFalse(session.inputTranscript.contains("only secret token"))
        XCTAssertTrue(session.conversationContext.isEmpty)
        input.emitAddressed("Next step", true)
        XCTAssertEqual(questions.last, "Next step")
        await session.stop()
    }

    func testNewRepairClearsHistoryAndObsoleteAnswersWithoutRestartingListening() async throws {
        let (session, input, output) = fixture()
        var delegation: String?
        session.onDelegation = { id, _ in delegation = id }
        try await session.start(apiKey: "offline", context: "Current repair context")
        input.emitAddressed("Which latch should I check?", true)
        let old = try XCTUnwrap(delegation)
        session.sayResult("Check the upper latch.", delegationID: old)
        await until { output.texts.count == 1 }
        XCTAssertTrue(session.isSpeaking)
        session.resetConversation()
        XCTAssertTrue(session.isActive)
        XCTAssertFalse(session.isSpeaking)
        XCTAssertEqual(input.startCount, 1)
        XCTAssertEqual(input.stopCount, 0)
        XCTAssertTrue(session.inputTranscript.isEmpty)
        XCTAssertTrue(session.outputTranscript.isEmpty)
        XCTAssertEqual(session.conversationContext, "Current repair context")
        session.sayResult("Obsolete repair answer", delegationID: old)
        await Task.yield()
        XCTAssertEqual(output.texts, ["Check the upper latch."])
        session.sendContext("New repair context")
        input.emitAddressed("Which latch should I check?", true)
        XCTAssertNotEqual(delegation, old, "The same question in a new repair must not count as a duplicate")
        XCTAssertEqual(session.conversationContext, "New repair context\nUser: Which latch should I check?")
        await session.stop()
    }

    func testSpeakingTransitionsNotifyDisplayControlsOnStartCompletionAndInterruption() async throws {
        let (session, _, output) = fixture()
        try await session.start(apiKey: "offline", context: "")
        var speakingStates: [Bool] = []
        session.onStateChange = { speakingStates.append(session.isSpeaking) }
        session.sayResult("First instruction.")
        await until { output.texts.count == 1 }
        output.finish(true)
        await until { !session.isSpeaking }
        session.sayResult("Second instruction.")
        await until { output.texts.count == 2 }
        session.interruptPlayback()
        session.interruptPlayback()
        XCTAssertEqual(speakingStates, [true, false, true, false], "Repeated cancellation must not publish another state transition")
        session.onStateChange = nil
        await session.stop()
    }

    func testNativeSpeechFailureEndsConversationVisibly() async throws {
        let (session, input, output) = fixture()
        var failures: [String] = []
        session.onFailure = { failures.append($0) }
        try await session.start(apiKey: "offline", context: "")
        input.onFailure?("Glasses speech stopped")
        XCTAssertFalse(session.isActive)
        XCTAssertEqual(failures, ["Glasses speech stopped"])
        XCTAssertEqual(output.stopCount, 1)
    }

    func testSpeechOutputFailurePreservesListeningAndTheNextReplyCanReconnect() async throws {
        let (session, input, output) = fixture()
        var notices: [String] = [], failures: [String] = [], questions: [String] = []
        session.onNotice = { notices.append($0) }; session.onFailure = { failures.append($0) }
        session.onDelegation = { _, text in questions.append(text) }
        try await session.start(apiKey: "offline", context: "")
        session.sayResult("Review the make and model.")
        await until { output.texts.count == 1 }
        output.onFailure?("The speaker route ended.")
        XCTAssertTrue(session.isActive); XCTAssertFalse(session.isSpeaking)
        XCTAssertEqual(input.startCount, 1); XCTAssertEqual(input.stopCount, 0)
        XCTAssertTrue(failures.isEmpty); XCTAssertTrue(notices.last?.contains("speaker route ended") == true)
        input.emitAddressed("Create steps", true)
        XCTAssertEqual(questions, ["Create steps"])
        session.sayResult("Your first step is ready.")
        await until { output.texts.count == 2 }
        XCTAssertEqual(output.startCount, 2)
        output.finish(true)
        await until { !session.isSpeaking }
        XCTAssertTrue(session.isActive); XCTAssertNil(session.error)
        await session.stop()
    }

    func testOutputStartupFailureStillStartsNativeListening() async throws {
        let (session, input, output) = fixture()
        output.startError = LiveVoiceError.message("Output unavailable")
        var notices: [String] = [], questions: [String] = []
        session.onNotice = { notices.append($0) }
        session.onDelegation = { _, text in questions.append(text) }
        try await session.start(apiKey: "offline", context: "")
        XCTAssertTrue(session.isActive); XCTAssertEqual(input.startCount, 1)
        XCTAssertTrue(notices.last?.contains("Output unavailable") == true)
        input.emitAddressed("Review details", true)
        XCTAssertEqual(questions, ["Review details"])
        await session.stop()
    }

    func testTimedRenewalUsesSameInputAndRejectsCallbacksFromThePriorRun() async throws {
        let input = TranscriptTestInput(), output = TranscriptTestOutput()
        var factories = 0, questions: [String] = []
        let session = TranscriptVoiceSession(makeSpeechInput: { factories += 1; return input }, output: output,
            lifecycle: .init(renewalInterval: .milliseconds(20), utteranceGrace: .zero, pollingInterval: .milliseconds(1)), listeningMode: .continuous)
        session.setRequiresAddress(true)
        session.onDelegation = { _, text in questions.append(text) }
        try await session.start(apiKey: "offline", context: "")
        let oldText = input.onText
        await until { input.startCount == 2 }
        oldText?("Hey Fixi, Old result", true)
        input.emitAddressed("Next step", true)
        XCTAssertEqual(questions, ["Next step"])
        XCTAssertEqual(factories, 1); XCTAssertEqual(input.permissions, [true, false])
        XCTAssertTrue(session.isActive); XCTAssertEqual(output.startCount, 1)
        session.mute()
        let count = input.startCount
        try await Task.sleep(for: .milliseconds(45))
        XCTAssertEqual(input.startCount, count, "A muted microphone must not be renewed")
        await session.stop()
    }

    func testRenewalAllowsTheCurrentFinalOnceAndStopCancelsTheNextTimer() async throws {
        let input = TranscriptTestInput(), output = TranscriptTestOutput()
        let session = TranscriptVoiceSession(makeSpeechInput: { input }, output: output, pauseDelay: .seconds(10),
            lifecycle: .init(renewalInterval: .milliseconds(10), utteranceGrace: .milliseconds(80), pollingInterval: .milliseconds(1)), listeningMode: .continuous)
        session.setRequiresAddress(true)
        var questions: [String] = []
        session.onDelegation = { _, text in questions.append(text) }
        try await session.start(apiKey: "offline", context: "")
        input.emitAddressed("My MacBook", false)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(input.startCount, 1)
        input.emitAddressed("My MacBook is frozen", true)
        await until { input.startCount == 2 }
        XCTAssertEqual(questions, ["My MacBook is frozen"])
        await session.stop()
        let count = input.startCount
        try await Task.sleep(for: .milliseconds(25))
        XCTAssertEqual(input.startCount, count)
        XCTAssertEqual(questions.count, 1)
    }

    func testCleanNativeRunEndRestartsButRepeatedUnexpectedStopsAreBounded() async throws {
        let (session, input, _) = fixture()
        var failures: [String] = []
        session.onFailure = { failures.append($0) }
        try await session.start(apiKey: "offline", context: "")
        input.onRecognitionEnded?()
        await until { input.startCount == 2 }
        input.onRecognitionEnded?()
        await until { input.startCount == 3 }
        input.onRecognitionEnded?()
        XCTAssertFalse(session.isActive)
        XCTAssertEqual(input.startCount, 3)
        XCTAssertTrue(failures.last?.contains("stopped repeatedly") == true)
    }

    func testMuteClearsPartialBeforeItsPauseFallbackAndNeverDispatchesLateFinal() async throws {
        let (session, input, _) = fixture(pause: .milliseconds(10))
        var questions: [String] = []
        session.onDelegation = { _, text in questions.append(text) }
        try await session.start(apiKey: "offline", context: "")
        input.emitAddressed("Create steps", false)
        let oldText = input.onText
        session.mute()
        oldText?("Hey Fixi, Create steps", true)
        try await Task.sleep(for: .milliseconds(25))
        XCTAssertTrue(questions.isEmpty); XCTAssertTrue(session.isMuted)
        XCTAssertGreaterThan(input.stopCount, 0)
        await session.stop()
    }

    func testMicMutePreservesAcceptedAnswerAndCameraQueuedSpeech() async throws {
        let (session, input, output) = fixture()
        var delegatedID: String?
        session.onDelegation = { id, _ in delegatedID = id }
        try await session.start(apiKey: "offline", context: "")
        input.emitAddressed("What should I check?", true)
        let id = try XCTUnwrap(delegatedID)
        session.setCaptureSuspended(true)
        session.sayResult("Check the upper screw.", delegationID: id)
        session.mute()
        session.setCaptureSuspended(false)
        await until { output.texts.count == 1 }
        XCTAssertTrue(session.isMuted); XCTAssertTrue(session.isSpeaking)
        XCTAssertEqual(output.texts, ["Check the upper screw."])
        output.finish(true)
        await until { !session.isSpeaking }
        session.sayResult("The same accepted answer can still finish.", delegationID: id)
        await until { output.texts.count == 2 }
        XCTAssertTrue(session.isMuted)
        await session.stop()
    }

    func testAddressedModeIgnoresAmbientSpeechBeforeInterruptingOrSavingIt() async throws {
        let (session, input, output) = fixture()
        var questions: [String] = [], interruptions = 0
        session.onDelegation = { _, text in questions.append(text) }
        session.onUserSpeechStarted = { interruptions += 1 }
        XCTAssertTrue(session.requiresAddress)
        try await session.start(apiKey: "offline", context: "Repair")
        session.sayResult("Support the door before tightening the screw.")
        await until { output.texts.count == 1 }
        input.emit("Next step", false); input.emit("Next step", true)
        XCTAssertTrue(session.isSpeaking); XCTAssertEqual(interruptions, 0)
        XCTAssertTrue(session.inputTranscript.isEmpty)
        XCTAssertFalse(session.conversationContext.contains("User:"))
        input.emit("Hey", false); input.emit("Hey Fi", false)
        for unaddressed in ["Hey Aria, Next step", "Aria, Next step", "Fixi, Next step",
                            "Hey Fixie, Next step", "Hey MendSight, Next step",
                            "They said Hey Fixi, Next step", "Don't say Hey Fixi, Next step",
                            "\"Hey Fixi, Next step\"", "“Hey Fixi, Next step”"] {
            input.emit(unaddressed, true)
        }
        XCTAssertTrue(session.isSpeaking); XCTAssertEqual(interruptions, 0)
        XCTAssertTrue(questions.isEmpty); XCTAssertTrue(session.inputTranscript.isEmpty)
        XCTAssertFalse(session.conversationContext.contains("User:"))
        input.emit("HEY, FIXI", false)
        XCTAssertTrue(session.isSpeaking)
        input.emit("HEY, FIXI: Next step", true)
        XCTAssertEqual(questions, ["Next step"]); XCTAssertEqual(interruptions, 1)
        XCTAssertFalse(session.isSpeaking)
        XCTAssertEqual(input.startCount, 1); XCTAssertEqual(input.stopCount, 0)
        await session.stop()
    }

    func testStandaloneOrEchoedAddressDoesNotArmAnotherPersonsNextSegment() async throws {
        let (session, input, output) = fixture()
        var questions: [String] = []
        session.onDelegation = { _, text in questions.append(text) }
        XCTAssertTrue(session.requiresAddress)
        try await session.start(apiKey: "offline", context: "")
        session.sayResult("Say Hey Fixi Next step when ready.")
        await until { output.texts.count == 1 }
        input.emit("Hey Fixi Next step", true)
        input.emit("Hey Fixi", true)
        input.emit("Next step", true)
        XCTAssertTrue(session.isSpeaking); XCTAssertTrue(questions.isEmpty)
        input.emit("Hey Fixi, where is the screw?", true)
        XCTAssertEqual(questions, ["where is the screw?"])
        await session.stop()
    }

    func testAddressModeChangeClearsPendingAmbientPartialWithoutRestartingMic() async throws {
        let (session, input, _) = fixture(pause: .milliseconds(10))
        var questions: [String] = []
        session.onDelegation = { _, text in questions.append(text) }
        try await session.start(apiKey: "offline", context: "")
        XCTAssertTrue(session.requiresAddress)
        session.setRequiresAddress(false)
        input.emit("Create steps", false)
        session.setRequiresAddress(true)
        try await Task.sleep(for: .milliseconds(25))
        input.emit("Create steps", true)
        XCTAssertTrue(questions.isEmpty)
        session.setRequiresAddress(false)
        input.emit("Create steps", true)
        XCTAssertEqual(questions, ["Create steps"])
        XCTAssertEqual(input.startCount, 1); XCTAssertEqual(input.stopCount, 0)
        await session.stop()
    }

    func testAddressedCredentialsRemainRedacted() async throws {
        let (session, input, _) = fixture()
        var questions: [String] = []
        session.onDelegation = { _, text in questions.append(text) }
        XCTAssertTrue(session.requiresAddress)
        try await session.start(apiKey: "offline", context: "")
        input.emit("Hey Fixi, my API key is sk-private-offline-token", true)
        XCTAssertEqual(questions, ["api key is [redacted]"])
        XCTAssertFalse(session.inputTranscript.contains("sk-private"))
        XCTAssertFalse(session.conversationContext.contains("sk-private"))
        await session.stop()
    }

    func testExplicitAddressFilterPreservesPendingAnswerDuringBackgroundConversation() async throws {
        let (session, input, output) = fixture()
        var delegatedID: String?, questions: [String] = [], starts = 0
        session.onDelegation = { id, text in delegatedID = id; questions.append(text) }
        session.onUserSpeechStarted = { starts += 1 }
        XCTAssertTrue(session.requiresAddress)
        try await session.start(apiKey: "offline", context: "MacBook Pro restart")
        XCTAssertEqual(session.status, "Listening for Hey Fixi")
        input.emit("Hey Fixi, how do I restart it?", true)
        let id = try XCTUnwrap(delegatedID)
        input.emit("Can you pass me", false)
        input.emit("Can you pass me the remote?", true)
        input.emit("Hey MendSight, cancel", true)
        input.emit("Hey Fixi", true)
        input.emit("Cancel", true)
        XCTAssertEqual(questions, ["how do I restart it?"])
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(session.inputTranscript, "how do I restart it?")
        XCTAssertFalse(session.conversationContext.contains("remote"))
        session.sayResult("Check whether the Apple menu responds.", delegationID: id)
        await until { output.texts.count == 1 }
        XCTAssertTrue(session.isSpeaking)
        XCTAssertEqual(output.texts, ["Check whether the Apple menu responds."])
        await session.stop()
    }

    func testExplicitOpenListeningChoiceSurvivesMuteAndConversationRestart() async throws {
        let (session, input, _) = fixture()
        var questions: [String] = []
        session.onDelegation = { _, text in questions.append(text) }
        session.setRequiresAddress(false)
        try await session.start(apiKey: "offline", context: "")
        input.emit("Review details", true)
        session.mute()
        XCTAssertFalse(session.requiresAddress)
        session.unmute()
        await until { input.startCount == 2 }
        XCTAssertFalse(session.requiresAddress)
        input.emit("Create steps", true)
        await session.stop()
        try await session.start(apiKey: "offline", context: "")
        XCTAssertFalse(session.requiresAddress)
        input.emit("Next step", true)
        XCTAssertEqual(questions, ["Review details", "Create steps", "Next step"])
        await session.stop()
    }

    func testAddressRequiresWholeHeyFixiAtTheBeginning() {
        XCTAssertEqual(MendSpeechAddress.content(in: "Hey Fixi, next step"), "next step")
        XCTAssertEqual(MendSpeechAddress.content(in: "  HEY, FIXI: next step "), "next step")
        XCTAssertEqual(MendSpeechAddress.content(in: "Hey Fixi—next step"), "next step")
        XCTAssertEqual(MendSpeechAddress.content(in: "Hey Fixi"), "")
        for unaddressed in ["Hey", "Hey Fi", "Fixi, next step", "Hey Fixie, next step", "Hey Fixing, next step",
                            "Hey Fixi's friend", "HeyFixi next step", "Hey MendSight next step",
                            "Hey Aria, next step", "Aria, next step", "Hey Ariana, next step",
                            "They said Hey Fixi, next step", "Don't say Hey Fixi, next step",
                            "\"Hey Fixi, next step\"", "“Hey Fixi, next step”", "‘Hey Fixi, next step’"] {
            XCTAssertNil(MendSpeechAddress.content(in: unaddressed), unaddressed)
        }
    }

    func testAddressedQuotedOrNegatedButtonNamesRemainConversationInsteadOfActions() throws {
        let available = [MendAction(id: .nextStep, title: "Next step")]
        for utterance in ["Hey Fixi, don't select Next step", "Hey Fixi, do not select Next step",
                          "Hey Fixi, \"Next step\"", "Hey Fixi, “Next step”",
                          "Hey Fixi, what happens if I say Next step?"] {
            let content = try XCTUnwrap(MendSpeechAddress.content(in: utterance))
            XCTAssertEqual(MendVoiceActions.resolve(content, available: available), .unmatched, utterance)
        }
        XCTAssertEqual(MendVoiceActions.resolve(try XCTUnwrap(MendSpeechAddress.content(in: "Hey Fixi, Next step")),
                                               available: available), .action(.nextStep))
    }

    func testContinuousModeWithoutOpenAIKeyKeepsNativeControlsAndDoesNotUseLocalSpeech() async throws {
        let input = TranscriptTestInput()
        let session = TranscriptVoiceSession(makeSpeechInput: { input }, listeningMode: .continuous)
        session.setRequiresAddress(true)
        var notices: [String] = [], questions: [String] = []
        session.onNotice = { notices.append($0) }
        session.onDelegation = { _, text in questions.append(text) }
        try await session.start(apiKey: "", context: "MacBook Pro")
        XCTAssertTrue(session.isActive); XCTAssertTrue(session.requiresAddress)
        XCTAssertEqual(input.startCount, 1); XCTAssertEqual(input.stopCount, 0)
        XCTAssertTrue(notices.last?.contains("OpenAI API key") == true)
        input.emitAddressed("Next step", true)
        XCTAssertEqual(questions, ["Next step"])
        let spoken = await session.speakAndWait("Read the instruction on screen.")
        XCTAssertFalse(spoken); XCTAssertTrue(session.isActive)
        XCTAssertEqual(input.stopCount, 0)
        await session.stop()
    }

    func testChangingOutputKeyRetiresOnlyNarrationAndPreservesMutedDelegatedAnswer() async throws {
        let (session, input, output) = fixture()
        var delegatedID: String?, notices: [String] = []
        session.onDelegation = { id, _ in delegatedID = id }
        session.onNotice = { notices.append($0) }
        try await session.start(apiKey: "old-offline-key", context: "")
        input.emitAddressed("How do I restart it?", true)
        let id = try XCTUnwrap(delegatedID)
        session.mute()
        session.sayResult("Check the Apple menu.", delegationID: id)
        await until { output.texts.count == 1 }
        let staleFailure = output.onFailure, staleTranscript = output.onTranscript
        session.setOutputAPIKey(" new-offline-key ")
        XCTAssertFalse(session.isSpeaking); XCTAssertTrue(session.isActive); XCTAssertTrue(session.isMuted)
        XCTAssertEqual(input.startCount, 1); XCTAssertEqual(input.stopCount, 1)
        XCTAssertEqual(output.stopCount, 1)
        let noticeCount = notices.count
        staleFailure?("Old connection ended")
        staleTranscript?("Stale voice text")
        XCTAssertEqual(notices.count, noticeCount)
        session.sayResult("Choose Restart from the Apple menu.", delegationID: id)
        await until { output.texts.count == 2 }
        XCTAssertEqual(output.startKeys, ["old-offline-key", "new-offline-key"])
        XCTAssertEqual(output.texts.last, "Choose Restart from the Apple menu.")
        output.finish(true)
        await until { !session.isSpeaking }
        XCTAssertTrue(session.isMuted); XCTAssertEqual(input.stopCount, 1)
        await session.stop()
    }

    func testForgettingOutputKeyKeepsListeningAndCameraQueuedReplyUsesReplacementKey() async throws {
        let (session, input, output) = fixture()
        var questions: [String] = [], notices: [String] = []
        session.onDelegation = { _, text in questions.append(text) }
        session.onNotice = { notices.append($0) }
        try await session.start(apiKey: "old-offline-key", context: "")
        session.setCaptureSuspended(true)
        session.sayResult("Photo ready. Choose Use photo.")
        session.setOutputAPIKey("")
        XCTAssertTrue(notices.last?.contains("Add an OpenAI API key") == true)
        input.emitAddressed("What is the next step?", true)
        XCTAssertEqual(questions, ["What is the next step?"])
        // A new accepted answer can remain parked while the camera is active.
        session.sayResult("Review the photo on screen.")
        session.setOutputAPIKey("replacement-offline-key")
        session.setCaptureSuspended(false)
        await until { output.texts.count == 1 }
        XCTAssertEqual(output.startKeys, ["old-offline-key", "replacement-offline-key"])
        XCTAssertEqual(output.texts, ["Review the photo on screen."])
        XCTAssertEqual(input.startCount, 1); XCTAssertEqual(input.stopCount, 0)
        XCTAssertTrue(session.isActive)
        await session.stop()
    }

    func testSpeechPreparationFinishesBeforeOutputReconnectOrPlayback() async throws {
        let (session, input, output) = fixture()
        try await session.start(apiKey: "offline", context: "")
        session.setOutputAPIKey("replacement-offline")
        var preparation: CheckedContinuation<Void, Never>?
        var completionStates: [Bool] = []
        session.onWillSpeak = { await withCheckedContinuation { preparation = $0 } }
        session.onDidFinishSpeaking = { completionStates.append(session.isSpeaking) }
        let cue = Task { await session.speakAndWait("Turn the upper screw gently.") }
        await until { preparation != nil }
        XCTAssertTrue(session.isSpeaking)
        XCTAssertEqual(output.startCount, 1, "Camera preparation must precede reconnecting output")
        XCTAssertTrue(output.texts.isEmpty)
        XCTAssertEqual(input.stopCount, 0, "Preparing output must leave native listening active")
        preparation?.resume(); preparation = nil
        await until { output.texts.count == 1 }
        XCTAssertEqual(output.startCount, 2)
        XCTAssertTrue(completionStates.isEmpty)
        output.finish(true)
        let result = await cue.value
        XCTAssertTrue(result)
        XCTAssertEqual(completionStates, [false])
        await session.stop()
        XCTAssertEqual(completionStates, [false], "Stopping after completion must not release preparation twice")
    }

    func testFailedCameraPreparationSkipsAudioAndPreservesListening() async throws {
        let (session, input, output) = fixture()
        try await session.start(apiKey: "offline", context: "")
        var finishes = 0
        session.onWillSpeak = { throw LiveVoiceError.message("The camera did not stop") }
        session.onDidFinishSpeaking = { finishes += 1; XCTAssertFalse(session.isSpeaking) }
        let result = await session.speakAndWait("Do not play before the camera closes.")
        XCTAssertFalse(result); XCTAssertEqual(finishes, 1)
        XCTAssertTrue(output.texts.isEmpty)
        XCTAssertTrue(session.isActive); XCTAssertEqual(input.stopCount, 0)
        XCTAssertTrue(session.error?.contains("camera did not stop") == true)
        await session.stop()
        XCTAssertEqual(finishes, 1)
    }

    func testCancelledPreparationCannotReleaseOrNarrateTheNewerReply() async throws {
        let (session, _, output) = fixture()
        try await session.start(apiKey: "offline", context: "")
        var preparations: [CheckedContinuation<Void, Never>] = []
        var resumed = 0, finishes = 0
        session.onWillSpeak = {
            await withCheckedContinuation { preparations.append($0) }
            resumed += 1
        }
        session.onDidFinishSpeaking = { finishes += 1; XCTAssertFalse(session.isSpeaking) }
        session.sayResult("Obsolete reply")
        await until { preparations.count == 1 }
        session.sayResult("Current reply")
        await until { preparations.count == 2 }
        XCTAssertEqual(finishes, 1, "Superseding a pending preparation releases it immediately")
        preparations[0].resume()
        await until { resumed == 1 }
        XCTAssertTrue(session.isSpeaking)
        XCTAssertEqual(finishes, 1, "An old task's deferred cleanup must not release the new preparation")
        XCTAssertTrue(output.texts.isEmpty)
        preparations[1].resume()
        await until { output.texts.count == 1 }
        XCTAssertEqual(output.texts, ["Current reply"])
        output.finish(true)
        await until { finishes == 2 }
        XCTAssertFalse(session.isSpeaking)
        await session.stop()
    }

    func testTaskCancellationDuringPreparationReleasesHookWithoutPlaying() async throws {
        let (session, _, output) = fixture()
        try await session.start(apiKey: "offline", context: "")
        var preparation: CheckedContinuation<Void, Never>?
        var finishes = 0
        session.onWillSpeak = { await withCheckedContinuation { preparation = $0 } }
        session.onDidFinishSpeaking = { finishes += 1 }
        let cue = Task { await session.speakAndWait("Cancelled cue") }
        await until { preparation != nil }
        cue.cancel()
        preparation?.resume(); preparation = nil
        let result = await cue.value
        XCTAssertFalse(result); XCTAssertFalse(session.isSpeaking)
        XCTAssertEqual(finishes, 1); XCTAssertTrue(output.texts.isEmpty)
        XCTAssertTrue(session.isActive)
        await session.stop()
    }

    func testDefaultStartsListeningImmediatelyWithoutWakeWordAndKeepsFollowUpsOpen() async throws {
        let input = TranscriptTestInput(), output = TranscriptTestOutput()
        let session = TranscriptVoiceSession(makeSpeechInput: { input }, output: output)
        var questions: [String] = [], ids: [String] = [], starts = 0
        session.onUserSpeechStarted = { starts += 1 }
        session.onDelegation = { id, text in ids.append(id); questions.append(text) }
        try await session.start(apiKey: "offline", context: "MacBook Pro")
        XCTAssertEqual(session.listeningMode, .continuous)
        XCTAssertFalse(session.requiresAddress); XCTAssertFalse(session.isListeningForTurn)
        XCTAssertEqual(input.startCount, 1); XCTAssertEqual(input.permissions, [true])
        XCTAssertEqual(session.status, "Listening through your glasses")
        input.emit("How do I restart", false)
        input.emit("How do I restart this?", true)
        session.sayResult("Choose Restart in the Apple menu.", delegationID: ids[0])
        await until { output.texts.count == 1 }
        output.finish(true)
        await until { !session.isSpeaking }
        input.emit("What if the menu is frozen?", true)
        input.emit("How do I restart this?", true)
        XCTAssertEqual(questions, ["How do I restart this?", "What if the menu is frozen?", "How do I restart this?"])
        XCTAssertEqual(starts, 3); XCTAssertEqual(input.startCount, 1); XCTAssertEqual(input.stopCount, 0)
        XCTAssertTrue(session.isActive); XCTAssertFalse(session.isReceivingSpeech)
        await session.stop()
    }

    func testPartialCannotCancelOutstandingAnswerOrPromoteAfterReplyFinishes() async throws {
        let input = TranscriptTestInput(), output = TranscriptTestOutput()
        let session = TranscriptVoiceSession(makeSpeechInput: { input }, output: output, pauseDelay: .milliseconds(3))
        var questions: [String] = [], ids: [String] = [], starts = 0
        session.onUserSpeechStarted = { starts += 1 }
        session.onDelegation = { id, text in ids.append(id); questions.append(text) }
        try await session.start(apiKey: "offline", context: "")
        input.emit("How do I restart this?", true)
        input.emit("Can you pass", false)
        try await Task.sleep(for: .milliseconds(12))
        XCTAssertEqual(questions, ["How do I restart this?"])
        XCTAssertTrue(session.isReceivingSpeech)
        session.sayResult("Check whether the Apple menu responds.", delegationID: ids[0])
        await until { output.texts.count == 1 }
        XCTAssertTrue(session.isSpeaking)
        output.finish(true)
        await until { !session.isSpeaking }
        input.emit("Can you pass me", false)
        try await Task.sleep(for: .milliseconds(12))
        XCTAssertEqual(questions.count, 1, "An utterance heard while waiting still requires a native final")
        XCTAssertEqual(starts, 2)
        input.emit("Can you explain the Apple menu?", true)
        input.emit("Can you explain the Apple menu?", true)
        XCTAssertEqual(questions, ["How do I restart this?", "Can you explain the Apple menu?"])
        session.sayResult("Obsolete answer", delegationID: ids[0])
        await Task.yield()
        XCTAssertEqual(output.texts, ["Check whether the Apple menu responds."])
        XCTAssertFalse(session.isReceivingSpeech)
        await session.stop()
    }

    func testPartialDuringNarrationWaitsForFinalAndInterruptsExactlyOnce() async throws {
        let input = TranscriptTestInput(), output = TranscriptTestOutput()
        let session = TranscriptVoiceSession(makeSpeechInput: { input }, output: output, pauseDelay: .milliseconds(3))
        var questions: [String] = [], starts = 0, finishes = 0
        session.onUserSpeechStarted = { starts += 1 }
        session.onDidFinishSpeaking = { finishes += 1 }
        session.onDelegation = { _, text in questions.append(text) }
        try await session.start(apiKey: "offline", context: "")
        session.sayResult("Open the Apple menu and choose Restart.")
        await until { output.texts.count == 1 }
        input.emit("Open the Apple menu", false)
        XCTAssertEqual(starts, 0)
        input.emit("Where is that", false)
        try await Task.sleep(for: .milliseconds(12))
        XCTAssertTrue(session.isSpeaking); XCTAssertEqual(finishes, 0)
        XCTAssertEqual(starts, 1); XCTAssertTrue(questions.isEmpty)
        input.emit("Where is that menu?", true)
        input.emit("Where is that menu?", true)
        XCTAssertFalse(session.isSpeaking); XCTAssertEqual(finishes, 1)
        XCTAssertEqual(questions, ["Where is that menu?"])
        XCTAssertEqual(starts, 1); XCTAssertEqual(input.startCount, 1); XCTAssertEqual(input.stopCount, 0)
        await session.stop()
    }

    func testNarrationStartingAfterIdlePartialDisablesItsPauseFallback() async throws {
        let input = TranscriptTestInput(), output = TranscriptTestOutput()
        let session = TranscriptVoiceSession(makeSpeechInput: { input }, output: output, pauseDelay: .milliseconds(15))
        var questions: [String] = []
        session.onDelegation = { _, text in questions.append(text) }
        try await session.start(apiKey: "offline", context: "")
        input.emit("Maybe look", false)
        session.sayResult("What should we work on today?")
        await until { output.texts.count == 1 }
        try await Task.sleep(for: .milliseconds(25))
        XCTAssertTrue(session.isSpeaking); XCTAssertTrue(questions.isEmpty)
        output.finish(true)
        await until { !session.isSpeaking }
        input.emit("Maybe look at", false)
        try await Task.sleep(for: .milliseconds(25))
        XCTAssertTrue(questions.isEmpty)
        input.emit("Look at this computer", true)
        XCTAssertEqual(questions, ["Look at this computer"])
        await session.stop()
    }

    func testReceivingSpeechPublishesStartAndDiscardedOrAcceptedEnd() async throws {
        let input = TranscriptTestInput(), output = TranscriptTestOutput()
        let session = TranscriptVoiceSession(makeSpeechInput: { input }, output: output)
        var states: [Bool] = [], starts = 0
        try await session.start(apiKey: "offline", context: "")
        session.onStateChange = { states.append(session.isReceivingSpeech) }
        session.onUserSpeechStarted = { starts += 1 }
        input.emit("Could you", false)
        input.emit("Could you help", false)
        XCTAssertTrue(session.isReceivingSpeech)
        input.emit("um", true)
        XCTAssertFalse(session.isReceivingSpeech)
        input.emit("Where is the filter", false)
        input.emit("Where is the filter?", true)
        XCTAssertFalse(session.isReceivingSpeech)
        XCTAssertEqual(starts, 2)
        XCTAssertEqual(states, [true, false, true, false])
        session.onStateChange = nil
        await session.stop()
    }

    func testNewRepairClearsCredentialCarryoverAndPreviousNarrationEcho() async throws {
        let input = TranscriptTestInput(), output = TranscriptTestOutput()
        let session = TranscriptVoiceSession(makeSpeechInput: { input }, output: output, pauseDelay: .milliseconds(3))
        var questions: [String] = []
        session.onDelegation = { _, text in questions.append(text) }
        try await session.start(apiKey: "offline", context: "")
        input.emit("My API key is sk-offline-test-only", false)
        await until { questions.count == 1 }
        session.sayResult("Check the filter housing.")
        await until { output.texts.count == 1 }
        session.resetConversation()
        input.emit("Check the filter housing", true)
        XCTAssertEqual(questions, ["api key is [redacted]", "Check the filter housing"])
        XCTAssertEqual(session.conversationContext, "\nUser: Check the filter housing")
        XCTAssertFalse(session.isReceivingSpeech)
        await session.stop()
    }

    func testProgressCueDoesNotReleasePendingAnswerProtectionAfterPlaybackEnds() async throws {
        let input = TranscriptTestInput(), output = TranscriptTestOutput()
        let session = TranscriptVoiceSession(makeSpeechInput: { input }, output: output, pauseDelay: .milliseconds(3))
        var questions: [String] = [], ids: [String] = []
        session.onDelegation = { id, text in ids.append(id); questions.append(text) }
        try await session.start(apiKey: "offline", context: "")
        input.emit("How do I restart this?", true)
        let originalID = try XCTUnwrap(ids.first)
        let cue = Task { await session.speakAndWait("Let me check that.") }
        await until { output.texts.count == 1 }
        output.finish(true)
        let cueCompleted = await cue.value
        XCTAssertTrue(cueCompleted); XCTAssertFalse(session.isSpeaking)
        input.emit("Can you pass", false)
        try await Task.sleep(for: .milliseconds(12))
        XCTAssertEqual(questions, ["How do I restart this?"], "Transient progress speech must not make a pending answer interruptible by a partial")
        input.emit("Can you explain the restart options?", true)
        XCTAssertEqual(questions, ["How do I restart this?", "Can you explain the restart options?"])
        XCTAssertNotEqual(ids.last, originalID)
        session.sayResult("Obsolete first answer", delegationID: originalID)
        session.sayResult("Check the Apple menu first.", delegationID: ids.last)
        await until { output.texts.count == 2 }
        XCTAssertEqual(output.texts, ["Let me check that.", "Check the Apple menu first."])
        XCTAssertEqual(input.startCount, 1); XCTAssertEqual(input.stopCount, 0)
        await session.stop()
    }

    private func fixture(pause: Duration = .seconds(10)) -> (TranscriptVoiceSession, TranscriptTestInput, TranscriptTestOutput) {
        let input = TranscriptTestInput(), output = TranscriptTestOutput()
        let session = TranscriptVoiceSession(makeSpeechInput: { input }, output: output, pauseDelay: pause, listeningMode: .continuous)
        session.setRequiresAddress(true)
        return (session, input, output)
    }

    func testExplicitOneTurnStartsIdleAndAcceptsExactlyOneFinalWithoutWakeWord() async throws {
        let input = TranscriptTestInput(), output = TranscriptTestOutput()
        let session = TranscriptVoiceSession(makeSpeechInput: { input }, output: output, pauseDelay: .milliseconds(2), listeningMode: .oneTurn)
        var questions: [String] = [], starts = 0
        session.onUserSpeechStarted = { starts += 1 }
        session.onDelegation = { _, text in questions.append(text) }
        try await session.start(apiKey: "offline", context: "Air filter")
        XCTAssertEqual(session.listeningMode, .oneTurn)
        XCTAssertFalse(session.requiresAddress); XCTAssertFalse(session.isListeningForTurn)
        XCTAssertFalse(session.isMuted); XCTAssertEqual(session.status, "Tap Talk to speak")
        XCTAssertEqual(input.startCount, 0)
        session.listenForOneTurn()
        await until { input.startCount == 1 }
        XCTAssertEqual(input.permissions, [false], "The controller owns the permission handoff")
        let oldText = input.onText, oldFailure = input.onFailure, oldEnd = input.onRecognitionEnded
        input.emit("Which filter", false)
        try await Task.sleep(for: .milliseconds(8))
        XCTAssertTrue(questions.isEmpty, "A partial must never submit after a pause")
        XCTAssertEqual(starts, 1)
        input.emit("Which filter is this?", true)
        XCTAssertEqual(questions, ["Which filter is this?"])
        XCTAssertFalse(session.isListeningForTurn); XCTAssertFalse(session.isMuted)
        XCTAssertNil(input.onText); XCTAssertEqual(input.stopCount, 1)
        oldText?("Complete", true); oldFailure?("Late failure"); oldEnd?()
        XCTAssertEqual(questions.count, 1); XCTAssertTrue(session.isActive)
        XCTAssertFalse(session.conversationContext.contains("Complete"))
        await session.stop()
    }

    func testOneTurnClosesBeforeSynchronousDelegationReplyAndKeepsAnswer() async throws {
        let input = TranscriptTestInput(), output = TranscriptTestOutput()
        let session = TranscriptVoiceSession(makeSpeechInput: { input }, output: output, listeningMode: .oneTurn)
        session.onDelegation = { id, _ in
            XCTAssertFalse(session.isListeningForTurn); XCTAssertFalse(session.isMuted)
            XCTAssertNil(input.onText)
            session.sayResult("Open the filter housing.", delegationID: id)
        }
        try await session.start(apiKey: "offline", context: "")
        session.listenForOneTurn()
        await until { input.startCount == 1 }
        input.emit("What is step one?", true)
        await until { output.texts.count == 1 }
        XCTAssertEqual(output.texts, ["Open the filter housing."])
        XCTAssertTrue(session.isSpeaking)
        output.finish(true)
        await until { !session.isSpeaking }
        XCTAssertEqual(session.status, "Tap Talk to speak")
        XCTAssertEqual(input.startCount, 1)
        await session.stop()
    }

    func testOneTurnTimeoutDiscardsPartialAndExplainsHowToRetry() async throws {
        let input = TranscriptTestInput(), output = TranscriptTestOutput()
        let session = TranscriptVoiceSession(makeSpeechInput: { input }, output: output,
                                            pauseDelay: .milliseconds(1), listeningMode: .oneTurn, turnTimeout: .milliseconds(15))
        var questions: [String] = [], notices: [String] = []
        session.onDelegation = { _, text in questions.append(text) }
        session.onNotice = { notices.append($0) }
        try await session.start(apiKey: "offline", context: "")
        session.listenForOneTurn()
        await until { input.startCount == 1 }
        let stale = input.onText
        input.emit("Maybe check off", false)
        await until { !session.isListeningForTurn }
        stale?("Maybe check off every step", true)
        XCTAssertTrue(questions.isEmpty)
        XCTAssertEqual(notices, ["Listening timed out. Tap Talk to try again."])
        XCTAssertTrue(session.inputTranscript.isEmpty)
        XCTAssertFalse(session.conversationContext.contains("User:"))
        XCTAssertEqual(session.status, "Tap Talk to speak")
        await session.stop()
    }

    func testOneTurnNeverRenewsOrReopensAfterCleanRecognitionEnd() async throws {
        let input = TranscriptTestInput(), output = TranscriptTestOutput()
        let session = TranscriptVoiceSession(makeSpeechInput: { input }, output: output,
            lifecycle: .init(renewalInterval: .milliseconds(5), utteranceGrace: .zero, pollingInterval: .milliseconds(1)), listeningMode: .oneTurn)
        try await session.start(apiKey: "offline", context: "")
        session.listenForOneTurn()
        await until { input.startCount == 1 }
        try await Task.sleep(for: .milliseconds(15))
        XCTAssertEqual(input.startCount, 1)
        input.onRecognitionEnded?()
        XCTAssertFalse(session.isListeningForTurn)
        try await Task.sleep(for: .milliseconds(15))
        XCTAssertEqual(input.startCount, 1); XCTAssertTrue(session.isActive)
        XCTAssertEqual(session.status, "Tap Talk to speak")
        await session.stop()
    }

    func testOneTurnSilentTimeoutClosesWithoutNotice() async throws {
        let input = TranscriptTestInput(), output = TranscriptTestOutput()
        let session = TranscriptVoiceSession(makeSpeechInput: { input }, output: output, listeningMode: .oneTurn, turnTimeout: .milliseconds(10))
        var notices: [String] = [], questions: [String] = []
        session.onNotice = { notices.append($0) }
        session.onDelegation = { _, text in questions.append(text) }
        try await session.start(apiKey: "offline", context: "")
        session.listenForOneTurn()
        await until { input.startCount == 1 }
        await until { !session.isListeningForTurn }
        XCTAssertTrue(notices.isEmpty); XCTAssertTrue(questions.isEmpty)
        XCTAssertNil(input.onText); XCTAssertEqual(session.status, "Tap Talk to speak")
        await session.stop()
    }

    func testExplicitTalkAfterStopListeningClearsMuteAndStartsFreshTurn() async throws {
        let input = TranscriptTestInput(), output = TranscriptTestOutput()
        let session = TranscriptVoiceSession(makeSpeechInput: { input }, output: output, listeningMode: .oneTurn)
        var questions: [String] = []
        session.onDelegation = { _, text in questions.append(text) }
        try await session.start(apiKey: "offline", context: "")
        session.listenForOneTurn()
        await until { input.startCount == 1 }
        let oldText = input.onText
        session.mute()
        XCTAssertTrue(session.isMuted); XCTAssertFalse(session.isListeningForTurn)
        session.listenForOneTurn()
        XCTAssertFalse(session.isMuted)
        await until { input.startCount == 2 }
        oldText?("Complete everything", true)
        input.emit("Explain this step", true)
        XCTAssertEqual(questions, ["Explain this step"])
        XCTAssertEqual(input.permissions, [false, false])
        await session.stop()
    }

    func testUnsolicitedNarrationClosesOpenTalkBeforePreparationAndPlayback() async throws {
        let input = TranscriptTestInput(), output = TranscriptTestOutput()
        let session = TranscriptVoiceSession(makeSpeechInput: { input }, output: output, listeningMode: .oneTurn)
        var questions: [String] = [], preparations = 0
        session.onDelegation = { _, text in questions.append(text) }
        session.onWillSpeak = {
            preparations += 1
            XCTAssertFalse(session.isListeningForTurn)
            XCTAssertNil(input.onText)
            XCTAssertGreaterThanOrEqual(input.stopCount, 1)
        }
        try await session.start(apiKey: "offline", context: "")
        session.listenForOneTurn()
        await until { input.startCount == 1 }
        let stale = input.onText
        input.emit("Can you", false)
        var stopped: CheckedContinuation<Void, Never>?
        input.waitHandler = { await withCheckedContinuation { stopped = $0 } }
        session.sayResult("Aim the camera at the filter.")
        await until { stopped != nil }
        XCTAssertTrue(output.texts.isEmpty); XCTAssertEqual(preparations, 0)
        XCTAssertFalse(session.isListeningForTurn)
        input.waitHandler = nil
        stopped?.resume(); stopped = nil
        await until { output.texts.count == 1 }
        XCTAssertEqual(preparations, 1); XCTAssertFalse(session.isListeningForTurn)
        stale?("Aim the camera at the filter", true)
        XCTAssertTrue(questions.isEmpty)
        output.finish(true)
        await until { !session.isSpeaking }
        XCTAssertEqual(input.startCount, 1); XCTAssertEqual(session.status, "Tap Talk to speak")
        await session.stop()
    }

    func testOneTurnMuteUnmuteAndResetDoNotReopenMicrophone() async throws {
        let input = TranscriptTestInput(), output = TranscriptTestOutput()
        let session = TranscriptVoiceSession(makeSpeechInput: { input }, output: output, listeningMode: .oneTurn)
        var questions: [String] = []
        session.onDelegation = { _, text in questions.append(text) }
        try await session.start(apiKey: "offline", context: "")
        session.listenForOneTurn()
        await until { input.startCount == 1 }
        let beforeMute = input.onText
        session.mute(); session.unmute()
        beforeMute?("Complete", true)
        XCTAssertFalse(session.isListeningForTurn); XCTAssertFalse(session.isMuted)
        XCTAssertEqual(input.startCount, 1); XCTAssertTrue(questions.isEmpty)
        session.listenForOneTurn()
        await until { input.startCount == 2 }
        let beforeReset = input.onText
        input.emit("Complete", false)
        session.resetConversation()
        beforeReset?("Complete", true)
        XCTAssertFalse(session.isListeningForTurn); XCTAssertEqual(input.startCount, 2)
        XCTAssertTrue(questions.isEmpty); XCTAssertFalse(session.conversationContext.contains("User:"))
        await session.stop()
        try await session.start(apiKey: "offline", context: "New project")
        XCTAssertFalse(session.isListeningForTurn); XCTAssertEqual(input.startCount, 2)
        await session.stop()
    }

    func testRapidTalkSelectionsWaitForStopAndRetireOldStartTask() async throws {
        let input = TranscriptTestInput(), output = TranscriptTestOutput()
        var waits: [CheckedContinuation<Void, Never>] = []
        input.waitHandler = { await withCheckedContinuation { waits.append($0) } }
        let session = TranscriptVoiceSession(makeSpeechInput: { input }, output: output, listeningMode: .oneTurn)
        var questions: [String] = []
        session.onDelegation = { _, text in questions.append(text) }
        try await session.start(apiKey: "offline", context: "")
        session.listenForOneTurn()
        await until { waits.count == 1 }
        session.listenForOneTurn()
        await until { waits.count == 2 }
        waits[0].resume()
        try await Task.sleep(for: .milliseconds(3))
        XCTAssertEqual(input.startCount, 0, "Retired Talk startup must not start recognition")
        waits[1].resume()
        await until { input.startCount == 1 }
        input.emit("Show the filter", true)
        XCTAssertEqual(questions, ["Show the filter"])
        input.waitHandler = nil
        await session.stop()
    }

    func testStopDuringTalkStartupPreventsLateRecognitionStart() async throws {
        let input = TranscriptTestInput(), output = TranscriptTestOutput()
        var wait: CheckedContinuation<Void, Never>?
        input.waitHandler = { await withCheckedContinuation { wait = $0 } }
        let session = TranscriptVoiceSession(makeSpeechInput: { input }, output: output, listeningMode: .oneTurn)
        try await session.start(apiKey: "offline", context: "")
        session.listenForOneTurn()
        await until { wait != nil }
        input.waitHandler = nil
        await session.stop()
        wait?.resume(); wait = nil
        try await Task.sleep(for: .milliseconds(3))
        XCTAssertEqual(input.startCount, 0); XCTAssertFalse(session.isActive)
        XCTAssertFalse(session.isListeningForTurn)
    }

    func testEachExplicitTalkAllowsRepeatedQuestionButRetiresPriorAnswer() async throws {
        let input = TranscriptTestInput(), output = TranscriptTestOutput()
        let session = TranscriptVoiceSession(makeSpeechInput: { input }, output: output, listeningMode: .oneTurn)
        var ids: [String] = [], questions: [String] = []
        session.onDelegation = { id, text in ids.append(id); questions.append(text) }
        try await session.start(apiKey: "offline", context: "")
        session.listenForOneTurn()
        await until { input.startCount == 1 }
        input.emit("Which filter?", true)
        session.sayResult("Look inside the housing.", delegationID: ids[0])
        await until { output.texts.count == 1 }
        session.listenForOneTurn()
        XCTAssertFalse(session.isSpeaking, "A physical Talk selection intentionally interrupts")
        await until { input.startCount == 2 }
        session.sayResult("Stale answer", delegationID: ids[0])
        input.emit("Which filter?", true)
        XCTAssertEqual(questions, ["Which filter?", "Which filter?"])
        XCTAssertEqual(output.texts, ["Look inside the housing."])
        XCTAssertNotEqual(ids[0], ids[1])
        await session.stop()
    }

    func testOneTurnRedactsCredentialAcrossPartialRevisions() async throws {
        let input = TranscriptTestInput(), output = TranscriptTestOutput()
        let session = TranscriptVoiceSession(makeSpeechInput: { input }, output: output, listeningMode: .oneTurn)
        var questions: [String] = []
        session.onDelegation = { _, text in questions.append(text) }
        try await session.start(apiKey: "offline", context: "")
        session.listenForOneTurn()
        await until { input.startCount == 1 }
        input.emit("My API key is sk-private-offline", false)
        input.emit("private-offline", true)
        XCTAssertEqual(questions, ["api key is [redacted]"])
        XCTAssertFalse(session.inputTranscript.contains("private-offline"))
        XCTAssertFalse(session.conversationContext.contains("private-offline"))
        await session.stop()
    }

    func testOneTurnCapturesUtteranceContextOnceBeforeAcceptedFinal() async throws {
        let input = TranscriptTestInput(), output = TranscriptTestOutput()
        let session = TranscriptVoiceSession(makeSpeechInput: { input }, output: output, listeningMode: .oneTurn)
        var screen = "step one", captured = "", receivedContext = "", starts = 0
        session.onUserSpeechStarted = { captured = screen; starts += 1 }
        session.onDelegation = { _, _ in receivedContext = captured }
        try await session.start(apiKey: "offline", context: "")
        session.listenForOneTurn()
        await until { input.startCount == 1 }
        input.emit("Complete", false)
        screen = "step two"
        input.emit("Complete this step", true)
        XCTAssertEqual(starts, 1); XCTAssertEqual(receivedContext, "step one")
        await session.stop()
    }

    func testOneTurnOutputFailureDoesNotPreventExplicitVoiceControl() async throws {
        let input = TranscriptTestInput(), output = TranscriptTestOutput()
        output.startError = LiveVoiceError.message("No output key")
        let session = TranscriptVoiceSession(makeSpeechInput: { input }, output: output, listeningMode: .oneTurn)
        var questions: [String] = []
        session.onDelegation = { _, text in questions.append(text) }
        try await session.start(apiKey: "", context: "")
        XCTAssertEqual(input.startCount, 0); XCTAssertTrue(session.isActive)
        session.listenForOneTurn()
        await until { input.startCount == 1 }
        input.emit("Open step one", true)
        XCTAssertEqual(questions, ["Open step one"])
        XCTAssertFalse(session.isListeningForTurn); XCTAssertTrue(session.isActive)
        await session.stop()
    }
    private func until(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Timed out waiting for offline speech state", file: file, line: line)
    }
}

@MainActor private final class TranscriptTestInput: SceneVoiceSpeechInput {
    var onRecognitionEnded: (() -> Void)?
    var onText: ((String, Bool) -> Void)?
    var onFailure: ((String) -> Void)?
    var startCount = 0, stopCount = 0
    var permissions: [Bool] = []
    var waitHandler: (() async -> Void)?
    func start(onText: @escaping (String, Bool) -> Void, onFailure: @escaping (String) -> Void,
               onStatus: @escaping (String) -> Void, allowPermissionRequest: Bool) async throws {
        startCount += 1; permissions.append(allowPermissionRequest); self.onText = onText; self.onFailure = onFailure
    }
    func emit(_ text: String, _ final: Bool) { onText?(text, final) }
    func emitAddressed(_ text: String, _ final: Bool) { emit("Hey Fixi, " + text, final) }
    func stop() { stopCount += 1; onText = nil; onFailure = nil }
    func waitUntilStopped() async throws { await waitHandler?() }
}

@MainActor private final class TranscriptTestOutput: ConversationSpeechOutput {
    var onFailure: ((String) -> Void)?
    var onTranscript: ((String) -> Void)?
    var texts: [String] = [], stopCount = 0
    var startCount = 0
    var startKeys: [String] = []
    var startError: Error?
    private var continuation: CheckedContinuation<Bool, Never>?
    func start(apiKey: String) async throws { startCount += 1; startKeys.append(apiKey); if let startError { throw startError } }
    func speak(_ text: String) async -> Bool {
        cancel(); texts.append(text)
        return await withCheckedContinuation { continuation = $0 }
    }
    func finish(_ complete: Bool) { let next = continuation; continuation = nil; next?.resume(returning: complete) }
    func cancel() { finish(false) }
    func stop() { stopCount += 1; cancel() }
}

import AVFoundation
import Foundation
import XCTest
@testable import Fixi

@MainActor final class SystemSpeechOutputTests: XCTestCase {
    func testCompletedReplyIsExactUtteranceAndWaitsForNativeFinishWithoutAKey() async throws {
        let (output, driver) = try await fixture()
        let text = "  How do I restart it?\nDisconnect power. Wait 30 seconds; preserve 4 N·m.  "
        var transcript = "", completed = false
        output.onTranscript = { transcript = $0 }
        let task = Task { let result = await output.speak(text); completed = true; return result }
        await until { driver.utterances.count == 1 }
        XCTAssertEqual(Data(driver.utterances[0].utterance.speechString.utf8), Data(text.utf8))
        XCTAssertEqual(transcript, text)
        XCTAssertFalse(completed, "Enqueueing does not mean the user heard the reply")
        driver.finish(driver.utterances[0].id)
        let result = await task.value
        XCTAssertTrue(result); XCTAssertTrue(completed)
        output.stop()
    }

    func testEmptyReplyDoesNotInterruptAnUtteranceAlreadyPlaying() async throws {
        let (output, driver) = try await fixture()
        let task = Task { await output.speak("Current instruction") }
        await until { driver.utterances.count == 1 }
        let cancellations = driver.cancelCount
        let empty = await output.speak(" \n\t ")
        XCTAssertTrue(empty); XCTAssertEqual(driver.utterances.count, 1)
        XCTAssertEqual(driver.cancelCount, cancellations)
        driver.finish(driver.utterances[0].id)
        let result = await task.value
        XCTAssertTrue(result); output.stop()
    }

    func testOversizedUTF8ReplyFailsWithoutTruncatingOrSubmittingSpeech() async throws {
        let driver = SystemTestDriver()
        let output = SystemSpeechOutput(makeDriver: { driver }, limits: .init(textBytes: 4, completionTimeout: .seconds(1)))
        try await output.start(apiKey: "")
        var failures: [String] = []
        output.onFailure = { failures.append($0) }
        let result = await output.speak("🙂x")
        XCTAssertFalse(result); XCTAssertTrue(driver.utterances.isEmpty)
        XCTAssertEqual(failures.count, 1); XCTAssertTrue(failures[0].contains("too long"))
        XCTAssertEqual(driver.stopCount, 1)
    }

    func testCancelResolvesWithoutWaitingForNativeDidCancel() async throws {
        let (output, driver) = try await fixture()
        var failures: [String] = []
        output.onFailure = { failures.append($0) }
        let task = Task { await output.speak("Queued instruction") }
        await until { driver.utterances.count == 1 }
        output.cancel()
        let result = await task.value
        XCTAssertFalse(result); XCTAssertTrue(failures.isEmpty)
        driver.finish(driver.utterances[0].id)
        driver.onCancelled?(driver.utterances[0].id)
        XCTAssertTrue(failures.isEmpty); output.stop()
    }

    func testReplacementIgnoresLateFinishAndCancelFromOldUtterance() async throws {
        let (output, driver) = try await fixture()
        let old = Task { await output.speak("Old instruction") }
        await until { driver.utterances.count == 1 }
        var nextFinished = false
        let next = Task { let result = await output.speak("New instruction"); nextFinished = true; return result }
        await until { driver.utterances.count == 2 }
        let oldResult = await old.value
        XCTAssertFalse(oldResult)
        driver.finish(driver.utterances[0].id)
        driver.onCancelled?(driver.utterances[0].id)
        await Task.yield()
        XCTAssertFalse(nextFinished)
        driver.finish(driver.utterances[1].id)
        let result = await next.value
        XCTAssertTrue(result); output.stop()
    }

    func testTaskCancellationStopsUtteranceButAllowsAnotherReply() async throws {
        let (output, driver) = try await fixture()
        let task = Task { await output.speak("Interrupted") }
        await until { driver.utterances.count == 1 }
        task.cancel()
        let result = await task.value
        XCTAssertFalse(result); XCTAssertEqual(driver.stopCount, 0)
        let next = Task { await output.speak("Ready again") }
        await until { driver.utterances.count == 2 }
        driver.finish(driver.utterances[1].id)
        let nextResult = await next.value
        XCTAssertTrue(nextResult); output.stop()
    }

    func testStopRetiresCallbacksBeforeNewSessionStarts() async throws {
        let first = SystemTestDriver(), second = SystemTestDriver()
        var drivers = [first, second]
        let output = SystemSpeechOutput(makeDriver: { drivers.removeFirst() })
        try await output.start(apiKey: "")
        var failures: [String] = []
        output.onFailure = { failures.append($0) }
        let old = Task { await output.speak("Old session") }
        await until { first.utterances.count == 1 }
        let lateFinish = first.onFinished, lateFailure = first.onFailure
        output.stop()
        let oldResult = await old.value
        XCTAssertFalse(oldResult)
        try await output.start(apiKey: "")
        var completed = false
        let next = Task { let result = await output.speak("New session"); completed = true; return result }
        await until { second.utterances.count == 1 }
        lateFinish?(first.utterances[0].id); lateFailure?("Stale output failure")
        await Task.yield()
        XCTAssertFalse(completed); XCTAssertTrue(failures.isEmpty)
        second.finish(second.utterances[0].id)
        let result = await next.value
        XCTAssertTrue(result); output.stop()
    }

    func testUnexpectedNativeCancelReportsOnceAndNeverClaimsCompletion() async throws {
        let (output, driver) = try await fixture()
        var failures: [String] = []
        output.onFailure = { failures.append($0) }
        let task = Task { await output.speak("Safety instruction") }
        await until { driver.utterances.count == 1 }
        let cancelled = driver.onCancelled, finished = driver.onFinished
        let id = driver.utterances[0].id
        cancelled?(id); cancelled?(id); finished?(id)
        let result = await task.value
        XCTAssertFalse(result); XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(driver.stopCount, 1)
    }

    func testPrepareFailureHasSafeMessageAndReleasesDriver() async throws {
        let driver = SystemTestDriver()
        driver.prepareError = NSError(domain: "private native details", code: 1)
        let output = SystemSpeechOutput(makeDriver: { driver })
        do { try await output.start(apiKey: ""); XCTFail("Preparation must fail") }
        catch { XCTAssertFalse(error.localizedDescription.contains("private native details")) }
        XCTAssertEqual(driver.stopCount, 1); XCTAssertTrue(driver.utterances.isEmpty)
        driver.prepareError = nil
        try await output.start(apiKey: "")
        XCTAssertEqual(driver.prepareCount, 2)
        output.stop()
    }

    func testPhoneRouteAtStartPreservesActionableSelectionMessageWithoutSpeech() async throws {
        let driver = SystemTestDriver()
        driver.prepareError = LiveVoiceError.message(GlassesAudioRoute.selectionRequiredMessage)
        let output = SystemSpeechOutput(makeDriver: { driver })
        do { try await output.start(apiKey: ""); XCTFail("Phone output must not be accepted") }
        catch { XCTAssertEqual(error.localizedDescription, GlassesAudioRoute.selectionRequiredMessage) }
        XCTAssertTrue(driver.utterances.isEmpty)
        XCTAssertEqual(driver.stopCount, 1)
    }

    func testRouteIsCheckedAgainBeforeEachReplyAndPhoneFallbackIsNeverSubmitted() async throws {
        let (output, driver) = try await fixture()
        var failures: [String] = [], transcripts: [String] = []
        output.onFailure = { failures.append($0) }
        output.onTranscript = { transcripts.append($0) }
        let first = Task { await output.speak("First instruction") }
        await until { driver.utterances.count == 1 }
        driver.finish(driver.utterances[0].id)
        let firstResult = await first.value
        XCTAssertTrue(firstResult)
        driver.utterancePreparationError = LiveVoiceError.message(GlassesAudioRoute.selectionRequiredMessage)
        let secondResult = await output.speak("Reply after output switched to phone")
        XCTAssertFalse(secondResult)
        XCTAssertEqual(driver.utterancePrepareCount, 2)
        XCTAssertEqual(driver.utterances.map(\.utterance.speechString), ["First instruction"])
        XCTAssertEqual(transcripts, ["First instruction"])
        XCTAssertEqual(failures, [GlassesAudioRoute.selectionRequiredMessage])
        XCTAssertEqual(driver.stopCount, 1)
    }

    func testBluetoothSelectionCanRecoverAfterBlockedPhoneRoute() async throws {
        let driver = SystemTestDriver()
        driver.prepareError = LiveVoiceError.message(GlassesAudioRoute.selectionRequiredMessage)
        let output = SystemSpeechOutput(makeDriver: { driver })
        do { try await output.start(apiKey: ""); XCTFail("Phone output must not be accepted") } catch {}
        driver.prepareError = nil
        try await output.start(apiKey: "")
        let task = Task { await output.speak("Selected output is ready") }
        await until { driver.utterances.count == 1 }
        driver.finish(driver.utterances[0].id)
        let result = await task.value
        XCTAssertTrue(result); XCTAssertEqual(driver.utterancePrepareCount, 1)
        output.stop()
    }

    func testRouteFailureReleasesWaitingSpeechAndCanRestart() async throws {
        let (output, driver) = try await fixture()
        var failures: [String] = []
        output.onFailure = { failures.append($0) }
        let task = Task { await output.speak("Instruction") }
        await until { driver.utterances.count == 1 }
        driver.onFailure?("The audio output disconnected.")
        let result = await task.value
        XCTAssertFalse(result); XCTAssertEqual(failures, ["The audio output disconnected."])
        try await output.start(apiKey: "")
        XCTAssertEqual(driver.prepareCount, 2)
        output.stop()
    }

    func testMissingNativeCompletionHasFiniteDeadlineAndNoAutomaticRetry() async throws {
        let driver = SystemTestDriver()
        let output = SystemSpeechOutput(makeDriver: { driver }, limits: .init(completionTimeout: .milliseconds(10)))
        try await output.start(apiKey: "")
        var failures: [String] = []
        output.onFailure = { failures.append($0) }
        let result = await output.speak("Instruction whose delegate never finishes")
        XCTAssertFalse(result); XCTAssertEqual(driver.utterances.count, 1)
        XCTAssertEqual(driver.stopCount, 1); XCTAssertEqual(failures.count, 1)
    }

    func testSynchronousTranscriptCancellationNeverQueuesNativeSpeech() async throws {
        let (output, driver) = try await fixture()
        output.onTranscript = { _ in output.cancel() }
        let result = await output.speak("Cancelled before native submission")
        XCTAssertFalse(result); XCTAssertTrue(driver.utterances.isEmpty)
        output.onTranscript = nil; output.stop()
    }

    func testSystemOutputFailureKeepsNativeInputListeningWithoutAnOpenAIKey() async throws {
        let driver = SystemTestDriver(), input = SystemTestInput()
        let output = SystemSpeechOutput(makeDriver: { driver })
        let voice = TranscriptVoiceSession(makeSpeechInput: { input }, output: output, listeningMode: .continuous)
        var notices: [String] = [], fatal: [String] = [], questions: [String] = []
        voice.onNotice = { notices.append($0) }; voice.onFailure = { fatal.append($0) }
        voice.onDelegation = { _, text in questions.append(text) }
        try await voice.start(apiKey: "", context: "MacBook repair")
        voice.sayResult("Read the instruction on screen.")
        await until { driver.utterances.count == 1 }
        driver.onFailure?("Audio playback was interrupted.")
        await until { !voice.isSpeaking }
        XCTAssertTrue(voice.isActive); XCTAssertEqual(input.stopCount, 0)
        XCTAssertFalse(notices.isEmpty); XCTAssertTrue(fatal.isEmpty)
        input.onText?("How do I restart it?", true)
        XCTAssertEqual(questions, ["How do I restart it?"])
        await voice.stop()
    }

    private func fixture() async throws -> (SystemSpeechOutput, SystemTestDriver) {
        let driver = SystemTestDriver()
        let output = SystemSpeechOutput(makeDriver: { driver }, limits: .init(completionTimeout: .seconds(2)))
        try await output.start(apiKey: "")
        return (output, driver)
    }

    private func until(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Timed out waiting for offline speech state", file: file, line: line)
    }
}

@MainActor private final class SystemTestDriver: SystemSpeechDriver {
    var onFinished: ((UUID) -> Void)?
    var onCancelled: ((UUID) -> Void)?
    var onFailure: ((String) -> Void)?
    var utterances: [(id: UUID, utterance: AVSpeechUtterance)] = []
    var prepareCount = 0, cancelCount = 0, stopCount = 0
    var utterancePrepareCount = 0
    var prepareError: Error?
    var utterancePreparationError: Error?
    func prepare() throws { prepareCount += 1; if let prepareError { throw prepareError } }
    func prepareForUtterance() throws {
        utterancePrepareCount += 1
        if let utterancePreparationError { throw utterancePreparationError }
    }
    func speak(_ utterance: AVSpeechUtterance, id: UUID) { utterances.append((id, utterance)) }
    func cancel() { cancelCount += 1 }
    func stop() { stopCount += 1; cancel() }
    func finish(_ id: UUID) { onFinished?(id) }
}

@MainActor private final class SystemTestInput: SceneVoiceSpeechInput {
    var onText: ((String, Bool) -> Void)?
    var stopCount = 0
    func start(onText: @escaping (String, Bool) -> Void, onFailure: @escaping (String) -> Void,
               onStatus: @escaping (String) -> Void, allowPermissionRequest: Bool) async throws {
        self.onText = onText
    }
    func stop() { stopCount += 1; onText = nil }
    func waitUntilStopped() async throws {}
}

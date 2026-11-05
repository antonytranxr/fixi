import AVFoundation
import XCTest
@testable import Fixi

@MainActor final class AudioOutputMonitorTests: XCTestCase {
    func testSpeechRouteRejectsPhoneSpeakerHFPEmptyAndMixedOutputs() {
        XCTAssertFalse(GlassesAudioRoute.supportsSpeech(portTypes: []))
        XCTAssertFalse(GlassesAudioRoute.supportsSpeech(portTypes: [.builtInSpeaker]))
        XCTAssertFalse(GlassesAudioRoute.supportsSpeech(portTypes: [.builtInReceiver]))
        XCTAssertFalse(GlassesAudioRoute.supportsSpeech(portTypes: [.bluetoothHFP]))
        XCTAssertFalse(GlassesAudioRoute.supportsSpeech(portTypes: [.headphones]))
        XCTAssertFalse(GlassesAudioRoute.supportsSpeech(portTypes: [.airPlay]))
        XCTAssertFalse(GlassesAudioRoute.supportsSpeech(portTypes: [.bluetoothA2DP, .builtInSpeaker]))
        XCTAssertTrue(GlassesAudioRoute.supportsSpeech(portTypes: [.bluetoothA2DP]))
        XCTAssertTrue(GlassesAudioRoute.supportsSpeech(portTypes: [.bluetoothLE]))
    }

    func testRouteChangesPublishActualDeviceNameAndPauseWhenPhoneReturns() {
        var route = AudioOutputMonitor.RouteSnapshot(name: "iPhone", portTypes: [.builtInSpeaker], volume: 0.5)
        let monitor = AudioOutputMonitor(readRoute: { route })
        var states: [String] = []
        monitor.onStateChange = { states.append(monitor.routeName) }
        XCTAssertTrue(monitor.needsGlassesOutput)
        route = .init(name: "Test glasses", portTypes: [.bluetoothA2DP], volume: 0.5)
        monitor.refresh(); monitor.refresh()
        XCTAssertFalse(monitor.needsGlassesOutput)
        XCTAssertEqual(states, ["Test glasses"], "Unchanged polling must not trigger a render loop")
        route = .init(name: "iPhone", portTypes: [.builtInSpeaker], volume: 0.5)
        monitor.refresh()
        XCTAssertTrue(monitor.needsGlassesOutput)
        XCTAssertEqual(states, ["Test glasses", "iPhone"])
        monitor.onStateChange = nil
    }

    func testRoutePickerPreparationActivatesPlaybackWithoutClaimingItSelectedGlasses() {
        var activations = 0
        let monitor = AudioOutputMonitor(readRoute: {
            .init(name: "iPhone", portTypes: [.builtInSpeaker], volume: 0.5)
        }, activateRouteSelection: { activations += 1 })
        monitor.prepareForRouteSelection()
        XCTAssertEqual(activations, 1)
        XCTAssertTrue(monitor.needsGlassesOutput)
        XCTAssertEqual(monitor.routeName, "iPhone")
        XCTAssertNil(monitor.message)
    }

    func testFailedRoutePickerPreparationUsesSafeVisibleError() {
        let monitor = AudioOutputMonitor(readRoute: {
            .init(name: "iPhone", portTypes: [.builtInSpeaker], volume: 0.5)
        }, activateRouteSelection: { throw NSError(domain: "Private native details", code: 1) })
        monitor.prepareForRouteSelection()
        XCTAssertTrue(monitor.needsGlassesOutput)
        XCTAssertEqual(monitor.message, "Audio outputs are unavailable. Check Bluetooth and try again.")
    }

    func testClosingPickerKeepsOwnershipUntilVoiceEndsEvenWithoutASpeechDriver() {
        var releases = 0
        let monitor = AudioOutputMonitor(readRoute: {
            .init(name: "Test glasses", portTypes: [.bluetoothA2DP], volume: 0.5)
        }, activateRouteSelection: {}, deactivateRouteSelection: { releases += 1 })
        monitor.prepareForRouteSelection()
        monitor.finishRouteSelection(keepSessionActive: false)
        monitor.finishRouteSelection(keepSessionActive: false)
        XCTAssertEqual(releases, 1)
        monitor.prepareForRouteSelection()
        monitor.finishRouteSelection(keepSessionActive: true)
        XCTAssertEqual(releases, 1, "Closing the picker must not interrupt active voice")
        monitor.finishRouteSelection(keepSessionActive: false)
        monitor.finishRouteSelection(keepSessionActive: false)
        XCTAssertEqual(releases, 2, "End voice releases the picker session even when no speech driver owns it")
    }

    func testCancelledSoundTestPublishesStartAndStopWithoutPlayingAudio() async {
        let monitor = AudioOutputMonitor()
        var states: [Bool] = []
        monitor.onStateChange = { states.append(monitor.testPlaying) }
        defer { monitor.onStateChange = nil; monitor.cancelTest() }
        // Cancel in this actor turn, before testSound can call player.prepare().
        let task = Task { @MainActor in try await monitor.testSound() }
        task.cancel()
        do { try await task.value; XCTFail("A cancelled test must not activate playback") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(states, [true, false])
        XCTAssertFalse(monitor.testPlaying)
        XCTAssertNil(monitor.message)
        XCTAssertTrue(monitor.lastTestDiagnostics?.contains("scheduled=0; played=0") == true)
        monitor.cancelTest(); monitor.cancelTest()
        XCTAssertEqual(states, [true, false], "Repeated idle cancellation must not publish a new state transition")
    }
}

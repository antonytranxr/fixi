import AVFoundation
import XCTest
@testable import Fixi

@MainActor final class LiveVoicePCMPlayerTests: XCTestCase {
    func testPhoneRouteAfterActivationReleasesSessionBeforeStartingEngine() {
        var routes: [AVAudioSession.Port] = [.bluetoothA2DP]
        var prepared = 0, released = 0
        let player = LiveVoicePCMPlayer(readPortTypes: { routes }, prepareAudioSession: {
            prepared += 1
            // iOS can change the selected route while activating playback.
            routes = [.builtInSpeaker]
        }, deactivateAudioSession: { released += 1 })
        XCTAssertThrowsError(try player.prepare()) {
            XCTAssertEqual($0.localizedDescription, GlassesAudioRoute.selectionRequiredMessage)
        }
        XCTAssertEqual(prepared, 1); XCTAssertEqual(released, 1)
        player.stop()
        XCTAssertEqual(released, 1)
    }

    func testEveryEnqueueRejectsIneligibleRoutesBeforeSessionActivationOrScheduling() {
        for route: [AVAudioSession.Port] in [[], [.builtInSpeaker], [.builtInReceiver], [.bluetoothHFP], [.bluetoothA2DP, .builtInSpeaker]] {
            var prepared = 0, played = 0, active = 0
            let player = LiveVoicePCMPlayer(readPortTypes: { route }, prepareAudioSession: { prepared += 1 }, deactivateAudioSession: {})
            player.onBufferPlayed = { played += $0 }
            player.onActivityChange = { if $0 { active += 1 } }
            XCTAssertThrowsError(try player.enqueue(Data([1, 0]))) {
                XCTAssertEqual($0.localizedDescription, GlassesAudioRoute.selectionRequiredMessage)
            }
            XCTAssertEqual(prepared, 0); XCTAssertEqual(played, 0); XCTAssertEqual(active, 0)
            player.stop()
        }
    }
}

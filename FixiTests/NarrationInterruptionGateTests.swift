import XCTest
@testable import Fixi

final class NarrationInterruptionGateTests: XCTestCase {
    func testEchoMatchingNormalizesPunctuationAndKeepsQuestionsWithSharedWords() {
        var gate = NarrationInterruptionGate(narration: "Find the air-filter cover. Keep the engine off and cool.")
        XCTAssertNil(gate.question(from: "FIND the air filter cover!", final: true))
        XCTAssertNil(gate.question(from: "engine off and cool", final: true))
        XCTAssertEqual(gate.question(from: "Why should the engine be off and cool?", final: false),
                       "Why should the engine be off and cool?")
    }

    func testOnlyAnObservedEchoPrefixIsRemovedFromTheQuestion() {
        var gate = NarrationInterruptionGate(narration: "Keep the engine off and cool before opening the cover.")
        XCTAssertNil(gate.question(from: "Keep the engine off and cool", final: false))
        XCTAssertEqual(gate.question(from: "Keep the engine off and cool how long should I wait?", final: false),
                       "how long should I wait?")
        XCTAssertEqual(gate.question(from: "Keep the engine off and cool how long should I wait before opening it?", final: true),
                       "how long should I wait before opening it?")

        var fresh = NarrationInterruptionGate(narration: "Keep the engine off and cool before opening the cover.")
        XCTAssertEqual(fresh.question(from: "Keep the engine off for how long?", final: true),
                       "Keep the engine off for how long?")
    }

    func testMeaningfulSingleWordsNeedNoWakeWordAndFillersDoNotInterrupt() {
        var gate = NarrationInterruptionGate(narration: "Find the visible housing.")
        XCTAssertNil(gate.question(from: "  ... ", final: false))
        XCTAssertNil(gate.question(from: "Um, uh", final: false))
        XCTAssertEqual(gate.question(from: "Why?", final: false), "Why?")
    }

}

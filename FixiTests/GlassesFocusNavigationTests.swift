import XCTest
@testable import Fixi

final class GlassesFocusNavigationTests: XCTestCase {
    func testNativeNavigationDoesNotConsumeGesturesOrPromoteAListFooter() {
        XCTAssertFalse(GlassesNavigationPolicy.usesRawInputs)
        XCTAssertNil(GlassesNavigationPolicy.preferredFooterID(
            itemIDs: ["step1", "step2"], footerIDs: ["mute", "menu"], preferredID: "step1"))
        XCTAssertNil(GlassesNavigationPolicy.preferredFooterID(
            itemIDs: ["details", "settings"], footerIDs: ["back"], preferredID: "back"))
    }

    func testCardsWithoutListRowsRetainTheirDefaultFooterAction() {
        XCTAssertEqual(GlassesNavigationPolicy.preferredFooterID(
            itemIDs: [], footerIDs: ["back", "done"], preferredID: "done"), "done")
        XCTAssertEqual(GlassesNavigationPolicy.preferredFooterID(
            itemIDs: [], footerIDs: ["back", "done"], preferredID: "missing"), "back")
        XCTAssertNil(GlassesNavigationPolicy.preferredFooterID(
            itemIDs: [], footerIDs: [], preferredID: "missing"))
    }

    func testMenuWithoutAnExplicitPreferenceStartsAtFirstItem() {
        var navigation = GlassesFocusNavigation()
        navigation.reset(itemIDs: ["details", "photo", "settings"], footerIDs: ["back", "mute"], preferredID: nil)
        XCTAssertEqual(navigation.focusedID, "details")
        XCTAssertEqual(navigation.move(.down), .focused("photo"))
        XCTAssertEqual(navigation.move(.up), .focused("details"))
        XCTAssertEqual(navigation.move(.up), .unchanged)
    }

    func testIdenticalVisibleMenuDoesNotRequireAReplacementView() {
        // A new caller-side array or hidden camera status is not a display change.
        let original = content(items: [.init(id: "photo", label: "Photo"), .init(id: "settings", label: "Settings")])
        let update = content(items: [.init(id: "photo", label: "Photo"), .init(id: "settings", label: "Settings")])
        XCTAssertEqual(original, update)
    }

    func testVisibleLabelsAndHandlerIdentityRequireReplacement() {
        XCTAssertNotEqual(content(), content(title: "Checklist"))
        XCTAssertNotEqual(content(), content(text: "Finding an example…"))
        XCTAssertNotEqual(content(), content(footer: [.init(id: "unmute", label: "Unmute")]))
        XCTAssertNotEqual(content(items: [.init(id: "step1", label: "Open")]),
                          content(items: [.init(id: "step2", label: "Open")]))
        XCTAssertNotEqual(content(staticRows: ["Filter"]), content(staticRows: ["Filter", "Gloves"]))
        XCTAssertNotEqual(content(), content(usesCustomActions: false))
    }

    func testReorderingOrRemovingListItemsRequiresReplacement() {
        let first = GlassesDisplayContent.Control(id: "first", label: "First")
        let second = GlassesDisplayContent.Control(id: "second", label: "Second")
        XCTAssertNotEqual(content(items: [first, second]), content(items: [second, first]))
        XCTAssertNotEqual(content(items: [first, second]), content(items: [first]))
    }

    func testImageIdentityAvoidsEncodingButStillReplacesChangedImages() {
        let image = NSObject(), replacement = NSObject()
        XCTAssertEqual(content(imageIdentity: ObjectIdentifier(image)), content(imageIdentity: ObjectIdentifier(image)))
        XCTAssertNotEqual(content(imageIdentity: ObjectIdentifier(image)), content(imageIdentity: ObjectIdentifier(replacement)))
        XCTAssertNotEqual(content(imageIdentity: ObjectIdentifier(image)), content())
    }

    func testChecklistBeginsOnStepOneAndVisitsEveryControlBeforeForwardBoundary() {
        var navigation = GlassesFocusNavigation()
        navigation.reset(itemIDs: ["step1", "step2", "step3"], footerIDs: ["complete", "mute", "menu"], preferredID: "step1")
        XCTAssertEqual(navigation.focusedID, "step1")
        for action in ["step2", "step3", "complete", "mute", "menu"] {
            XCTAssertEqual(navigation.move(.right), .focused(action))
        }
        XCTAssertEqual(navigation.move(.right), .boundary(forward: true))
        XCTAssertEqual(navigation.focusedID, "menu")
        XCTAssertEqual(navigation.move(.down), .unchanged)
    }

    func testLeftBoundaryGoesBackButVerticalBoundaryDoesNotNavigate() {
        var navigation = GlassesFocusNavigation()
        navigation.reset(itemIDs: ["step1", "step2"], footerIDs: ["mute"], preferredID: "step1")
        XCTAssertEqual(navigation.move(.left), .boundary(forward: false))
        XCTAssertEqual(navigation.move(.up), .unchanged)
        XCTAssertEqual(navigation.move(.down), .focused("step2"))
        XCTAssertEqual(navigation.move(.up), .focused("step1"))
    }

    func testNewCardDropsOldSelectionAndIgnoresUnknownPreference() {
        var navigation = GlassesFocusNavigation()
        navigation.reset(itemIDs: ["step1"], footerIDs: ["complete", "mute"], preferredID: "step1")
        _ = navigation.move(.right)
        navigation.reset(itemIDs: [], footerIDs: ["back", "mute"], preferredID: "missing")
        XCTAssertEqual(navigation.focusedID, "back")
        XCTAssertEqual(navigation.actionIDs, ["back", "mute"])
    }

    func testNoControlsCannotNavigateAndItemsOnlyCanStillReceiveFocus() {
        var navigation = GlassesFocusNavigation()
        navigation.reset(itemIDs: [], footerIDs: [], preferredID: nil)
        XCTAssertNil(navigation.focusedID)
        XCTAssertEqual(navigation.move(.right), .unchanged)
        navigation.reset(itemIDs: ["details", "details", "tips"], footerIDs: [], preferredID: nil)
        XCTAssertEqual(navigation.actionIDs, ["details", "tips"])
        XCTAssertEqual(navigation.focusedID, "details")
    }

    func testSequenceRejectsDuplicatesReorderingAndPreviouslyDroppedInput() {
        var sequence = GlassesInputSequence()
        XCTAssertTrue(sequence.observe(100))
        XCTAssertTrue(sequence.observe(102)) // Received while a replacement card was in flight.
        XCTAssertFalse(sequence.observe(102))
        XCTAssertFalse(sequence.observe(101))
        XCTAssertTrue(sequence.observe(103))
        sequence = GlassesInputSequence() // A new device session may have another clock.
        XCTAssertTrue(sequence.observe(1))
    }

    private func content(title: String = "Menu", text: String = "", imageIdentity: ObjectIdentifier? = nil,
                         items: [GlassesDisplayContent.Control] = [],
                         footer: [GlassesDisplayContent.Control] = [.init(id: "mute", label: "Mute")],
                         staticRows: [String] = [], usesCustomActions: Bool = true) -> GlassesDisplayContent {
        GlassesDisplayContent(title: title, text: text, imageIdentity: imageIdentity,
                              items: items, footer: footer, staticRows: staticRows,
                              usesCustomActions: usesCustomActions, usesRawInputs: false,
                              preferredActionID: nil)
    }
}

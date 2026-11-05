import XCTest
import UIKit
@testable import Fixi

@MainActor
final class MendFlowTests: XCTestCase {
    func testPhoneCompleteOpensTheNextInstructionAndFinishesAfterEveryStepCheck() throws {
        let model = FixiModel(configurationError: "Test")
        model.loadDemo()
        XCTAssertEqual(model.stage, .diagnosis)
        XCTAssertEqual(model.checkedSteps.count, 0)
        _ = try XCTUnwrap(model.diagnosis).validated(expectedPhotoID: "demo-hinge")
        model.startGuide()
        XCTAssertEqual(model.currentMarker?.kind, "circle")
        model.perform(.nextStep)
        XCTAssertEqual(model.stage, .guide)
        XCTAssertEqual(model.checkedSteps, ["support"])
        XCTAssertEqual(model.stepIndex, 1)
        XCTAssertEqual(model.currentMarker?.kind, "arrow")
        model.previousStep()
        model.perform(.nextStep)
        XCTAssertEqual(model.checkedSteps.count, 1, "Rechecking a step must not double count")
        XCTAssertEqual(model.stage, .guide)
        XCTAssertEqual(model.stepIndex, 1)
        model.perform(.nextStep)
        XCTAssertEqual(model.stage, .guide)
        XCTAssertEqual(model.stepIndex, 2)
        XCTAssertEqual(model.checkedSteps, ["support", "tighten"])
        model.perform(.backToChecklist)
        XCTAssertEqual(model.stage, .diagnosis)
        XCTAssertEqual(model.checkedSteps, ["support", "tighten"], "Back leaves the current instruction unfinished")
        model.perform(.step3)
        model.perform(.nextStep)
        XCTAssertEqual(model.stage, .complete)
        XCTAssertEqual(model.checkedSteps.count, 3)
    }

    func testPhoneCompleteSkipsAnInstructionAlreadyCompletedOutOfOrder() {
        let model = FixiModel(configurationError: "Test")
        model.loadDemo()
        model.perform(.step2)
        model.perform(.nextStep)
        XCTAssertEqual(model.stage, .guide)
        XCTAssertEqual(model.stepIndex, 2)
        XCTAssertEqual(model.checkedSteps, ["tighten"])
        model.perform(.backToChecklist)
        model.perform(.step1)
        model.perform(.nextStep)
        XCTAssertEqual(model.stage, .guide)
        XCTAssertEqual(model.stepIndex, 2, "The next instruction skips work already checked off")
        XCTAssertEqual(model.checkedSteps, ["support", "tighten"])
        model.perform(.nextStep)
        XCTAssertEqual(model.stage, .complete)
        XCTAssertEqual(model.checkedSteps, ["support", "tighten", "check"])
    }

    func testStaleImportedPhotoCannotReplaceAnotherStepOrNewRepair() throws {
        let model = FixiModel(configurationError: "Test")
        model.loadDemo(); model.startGuide()
        let token = model.photoContextToken
        let data = try XCTUnwrap(model.photo?.jpeg)
        model.checkAndAdvance()
        model.acceptPhoto(data, source: "Stale import", expectedToken: token)
        XCTAssertEqual(model.currentPhoto?.source, "Illustrated example")
        model.newRepair()
        model.acceptPhoto(data, source: "Stale import", expectedToken: token)
        XCTAssertNil(model.photo)
        XCTAssertNil(model.diagnosis)
    }

    func testGlassesPagesPreserveEveryWordAndBoundLongWords() {
        let text = "Before starting, support the door. " + String(repeating: "VeryLongWord", count: 100) + " Stop if damaged."
        let pages = FixiModel.pages(text)
        XCTAssertTrue(pages.allSatisfy { $0.count <= 170 })
        XCTAssertEqual(pages.joined().filter { !$0.isWhitespace }, text.filter { !$0.isWhitespace })
        let model = FixiModel(configurationError: "Test")
        model.loadDemo(); model.startGuide()
        XCTAssertTrue(model.displayPages.joined().contains("Ask someone to help"))
        XCTAssertTrue(model.displayPages.joined().contains("The door stays supported"))
    }

    func testPortraitNormalizationPreservesAspectAndBakesOrientation() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 160)).image { ctx in
            UIColor.red.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 80, height: 160))
        }
        let rotated = UIImage(cgImage: try XCTUnwrap(image.cgImage), scale: 1, orientation: .right)
        let photo = try MendPhoto.make(data: XCTUnwrap(rotated.jpegData(compressionQuality: 0.8)), source: "Test")
        XCTAssertEqual(photo.image.imageOrientation, .up)
        XCTAssertEqual(photo.image.size.width / photo.image.size.height, 2, accuracy: 0.01)
        let marker = PhotoMarker(kind: "circle", x: 0.2, y: 0.2, width: 0.2, height: 0.2, endX: nil, endY: nil, label: "Target")
        let annotated = PhotoCanvas.render(photo.image, marker: marker)
        XCTAssertEqual(annotated.size, photo.image.size)
        XCTAssertNotEqual(annotated.pngData(), photo.image.pngData())
    }
}

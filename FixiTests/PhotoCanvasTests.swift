import UIKit
import XCTest
@testable import Fixi

@MainActor final class PhotoCanvasTests: XCTestCase {
    func testDotCropKeepsExactPointAtCenterAndImageEdges() throws {
        for size in [CGSize(width: 1600, height: 900), CGSize(width: 900, height: 1600)] {
            for point in [CGPoint(x: 0.37, y: 0.61), .zero, CGPoint(x: 1, y: 1)] {
                let marker = dot(x: point.x, y: point.y)
                let plan = try XCTUnwrap(PhotoFocus.plan(imageSize: size, marker: marker))
                checkBounds(plan.cropRect, in: size)
                XCTAssertLessThanOrEqual(size.width / plan.cropRect.width, 3)
                XCTAssertLessThanOrEqual(size.height / plan.cropRect.height, 3)
                XCTAssertEqual(plan.marker.kind, "dot")
                XCTAssertTrue(PhotoFocus.isValid(plan.marker))
                assertOriginalPoint(CGPoint(x: plan.marker.x, y: plan.marker.y), crop: plan.cropRect,
                                    equals: CGPoint(x: point.x * size.width, y: point.y * size.height))
            }
        }
    }

    func testSmallCircleBecomesDotAtItsCenterWhileBroadAreasStayCircles() {
        let small = circle(x: 0.32, y: 0.325, width: 0.06, height: 0.05)
        let compact = PhotoFocus.displayMarker(small)
        XCTAssertEqual(compact.kind, "dot")
        XCTAssertEqual(compact.x, 0.35, accuracy: 0.000001)
        XCTAssertEqual(compact.y, 0.35, accuracy: 0.000001)
        XCTAssertNil(compact.width); XCTAssertNil(compact.height)
        XCTAssertEqual(compact.label, small.label)
        for broad in [circle(x: 0.1, y: 0.1, width: 0.3, height: 0.3),
                      circle(x: 0.1, y: 0.1, width: 0.5, height: 0.02)] {
            XCTAssertEqual(PhotoFocus.displayMarker(broad), broad)
        }
    }

    func testDotPixelsStayCompactAlignedAndBoundToExactPhoto() throws {
        let photo = try fixture(), marker = dot(x: 0.35, y: 0.35)
        let original = photo.image.pngData()
        let target = CGPoint(x: marker.x * photo.image.size.width, y: marker.y * photo.image.size.height)
        for focused in [false, true] {
            let display = PhotoCanvas.presentation(photo, marker: marker, markerPhotoID: photo.id, focused: focused)
            let local = CGPoint(x: target.x - display.cropRect.minX, y: target.y - display.cropRect.minY)
            XCTAssertTrue(try containsMint(display.image, near: local))
            XCTAssertEqual(try pixel(display.image, at: CGPoint(x: local.x + 24, y: local.y)),
                           try pixel(photo.image, at: CGPoint(x: target.x + 24, y: target.y)))
        }
        XCTAssertEqual(photo.image.pngData(), original)
        for wrongID in [nil, "different-photo"] as [String?] {
            let display = PhotoCanvas.presentation(photo, marker: marker, markerPhotoID: wrongID)
            XCTAssertFalse(display.canFocus)
            XCTAssertTrue(display.image === photo.image)
        }
    }

    func testSmallCircleRenderingUsesTheSameCompactDotInFullAndFocusedViews() throws {
        let photo = try fixture()
        let small = circle(x: 0.32, y: 0.325, width: 0.06, height: 0.05)
        let compact = dot(x: 0.35, y: 0.35)
        for focused in [false, true] {
            let fromCircle = PhotoCanvas.presentation(photo, marker: small, markerPhotoID: photo.id, focused: focused)
            let fromDot = PhotoCanvas.presentation(photo, marker: compact, markerPhotoID: photo.id, focused: focused)
            XCTAssertEqual(fromCircle.cropRect, fromDot.cropRect)
            XCTAssertEqual(fromCircle.image.pngData(), fromDot.image.pngData())
        }
    }

    func testSmallCircleGetsContextAndBoundedZoomInLandscapeAndPortrait() throws {
        let marker = circle(x: 0.44, y: 0.42, width: 0.06, height: 0.05)
        for size in [CGSize(width: 1600, height: 900), CGSize(width: 900, height: 1600)] {
            let plan = try XCTUnwrap(PhotoFocus.plan(imageSize: size, marker: marker))
            checkBounds(plan.cropRect, in: size)
            XCTAssertLessThanOrEqual(size.width / plan.cropRect.width, 3)
            XCTAssertLessThanOrEqual(size.height / plan.cropRect.height, 3)
            XCTAssertLessThanOrEqual(max(plan.cropRect.width / plan.cropRect.height, plan.cropRect.height / plan.cropRect.width), 2)
            let target = CGRect(x: marker.x * size.width, y: marker.y * size.height,
                                width: marker.width! * size.width, height: marker.height! * size.height)
            XCTAssertTrue(plan.cropRect.contains(target))
            XCTAssertGreaterThan(target.minX - plan.cropRect.minX, 0)
            XCTAssertGreaterThan(target.minY - plan.cropRect.minY, 0)
            assertOriginalPoint(CGPoint(x: plan.marker.x, y: plan.marker.y), crop: plan.cropRect,
                                equals: target.origin)
            XCTAssertEqual(plan.marker.width! * plan.cropRect.width, target.width, accuracy: 0.00001)
            XCTAssertEqual(plan.marker.height! * plan.cropRect.height, target.height, accuracy: 0.00001)
        }
    }

    func testCircleAtEveryImageCornerStaysWholeAndInBounds() throws {
        let size = CGSize(width: 1200, height: 800)
        for origin in [CGPoint(x: 0, y: 0), CGPoint(x: 0.94, y: 0), CGPoint(x: 0, y: 0.9), CGPoint(x: 0.94, y: 0.9)] {
            let marker = circle(x: origin.x, y: origin.y, width: 0.06, height: 0.1)
            let plan = try XCTUnwrap(PhotoFocus.plan(imageSize: size, marker: marker))
            checkBounds(plan.cropRect, in: size)
            XCTAssertGreaterThanOrEqual(plan.marker.x, 0)
            XCTAssertGreaterThanOrEqual(plan.marker.y, 0)
            XCTAssertLessThanOrEqual(plan.marker.x + plan.marker.width!, 1.000001)
            XCTAssertLessThanOrEqual(plan.marker.y + plan.marker.height!, 1.000001)
            assertOriginalPoint(CGPoint(x: plan.marker.x, y: plan.marker.y), crop: plan.cropRect,
                                equals: CGPoint(x: origin.x * size.width, y: origin.y * size.height))
        }
    }

    func testLongArrowFocusKeepsExactTargetAndSubstantialCollinearShaft() throws {
        let size = CGSize(width: 1600, height: 900)
        let marker = arrow(x: 0.02, y: 0.08, endX: 0.92, endY: 0.85)
        let plan = try XCTUnwrap(PhotoFocus.plan(imageSize: size, marker: marker))
        checkBounds(plan.cropRect, in: size)
        let tip = CGPoint(x: marker.endX! * size.width, y: marker.endY! * size.height)
        let retainedTail = originalPoint(CGPoint(x: plan.marker.x, y: plan.marker.y), crop: plan.cropRect)
        assertOriginalPoint(CGPoint(x: plan.marker.endX!, y: plan.marker.endY!), crop: plan.cropRect, equals: tip)
        let fullVector = CGPoint(x: tip.x - marker.x * size.width, y: tip.y - marker.y * size.height)
        let focusedVector = CGPoint(x: tip.x - retainedTail.x, y: tip.y - retainedTail.y)
        XCTAssertEqual(fullVector.x * focusedVector.y - fullVector.y * focusedVector.x, 0, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(hypot(focusedVector.x, focusedVector.y), min(size.width, size.height) * 0.29)
        XCTAssertLessThan(hypot(focusedVector.x, focusedVector.y), hypot(fullVector.x, fullVector.y))
        XCTAssertTrue(plan.cropRect.contains(retainedTail)); XCTAssertTrue(plan.cropRect.contains(tip))
    }

    func testArrowTargetAtEdgeDoesNotShiftDuringCrop() throws {
        let size = CGSize(width: 1200, height: 800)
        let marker = arrow(x: 0.2, y: 0.6, endX: 1, endY: 0)
        let plan = try XCTUnwrap(PhotoFocus.plan(imageSize: size, marker: marker))
        checkBounds(plan.cropRect, in: size)
        assertOriginalPoint(CGPoint(x: plan.marker.endX!, y: plan.marker.endY!), crop: plan.cropRect,
                            equals: CGPoint(x: size.width, y: 0))
        XCTAssertEqual(plan.cropRect.maxX, size.width)
        XCTAssertEqual(plan.cropRect.minY, 0)
    }

    func testShortArrowRetainsItsEntireShaft() throws {
        let size = CGSize(width: 1000, height: 800)
        let marker = arrow(x: 0.45, y: 0.4, endX: 0.48, endY: 0.43)
        let plan = try XCTUnwrap(PhotoFocus.plan(imageSize: size, marker: marker))
        assertOriginalPoint(CGPoint(x: plan.marker.x, y: plan.marker.y), crop: plan.cropRect,
                            equals: CGPoint(x: marker.x * size.width, y: marker.y * size.height))
    }

    func testThinTargetKeepsContextInsteadOfBecomingAStrip() throws {
        let size = CGSize(width: 1000, height: 600)
        let plan = try XCTUnwrap(PhotoFocus.plan(imageSize: size, marker: circle(x: 0.1, y: 0.4, width: 0.8, height: 0.03)))
        XCTAssertGreaterThanOrEqual(plan.cropRect.height, plan.cropRect.width / 2)
        XCTAssertGreaterThan(plan.cropRect.height, 200)
        checkBounds(plan.cropRect, in: size)
    }

    func testBroadTargetAndTinySourceKeepOriginalFraming() {
        XCTAssertNil(PhotoFocus.plan(imageSize: CGSize(width: 1200, height: 800), marker: circle(x: 0.05, y: 0.05, width: 0.9, height: 0.9)))
        XCTAssertNil(PhotoFocus.plan(imageSize: CGSize(width: 80, height: 60), marker: circle(x: 0.4, y: 0.4, width: 0.1, height: 0.1)))
    }

    func testAbsentInvalidOrMismatchedMarkerCannotCreateAFocusOrAnnotation() throws {
        let photo = try fixture()
        let valid = circle(x: 0.4, y: 0.4, width: 0.1, height: 0.1)
        let invalid: [PhotoMarker?] = [nil, circle(x: .nan, y: 0.4, width: 0.1, height: 0.1),
            circle(x: 0.95, y: 0.4, width: 0.1, height: 0.1), arrow(x: 0.4, y: 0.4, endX: 0.4, endY: 0.4),
            dot(x: 1.01, y: 0.4),
            PhotoMarker(kind: "dot", x: 0.4, y: 0.4, width: 0.1, height: nil, endX: nil, endY: nil, label: "Invalid dot"),
            PhotoMarker(kind: "guess", x: 0.5, y: 0.5, width: nil, height: nil, endX: nil, endY: nil, label: "Unsupported"),
            PhotoMarker(kind: "circle", x: 0.4, y: 0.4, width: 0.1, height: 0.1, endX: nil, endY: nil, label: String(repeating: "x", count: 81))]
        for marker in invalid {
            let display = PhotoCanvas.presentation(photo, marker: marker, markerPhotoID: photo.id)
            XCTAssertFalse(display.isFocused); XCTAssertFalse(display.canFocus)
            XCTAssertTrue(display.image === photo.image)
        }
        for wrongID in [nil, "different-photo"] as [String?] {
            let display = PhotoCanvas.presentation(photo, marker: valid, markerPhotoID: wrongID)
            XCTAssertFalse(display.isFocused); XCTAssertFalse(display.canFocus)
            XCTAssertTrue(display.image === photo.image)
        }
    }

    func testFocusAndFullViewPreserveOriginalDataAndTargetPixelAlignment() throws {
        let photo = try fixture()
        let originalJPEG = photo.jpeg, originalPixels = photo.image.pngData()
        let marker = arrow(x: 0.2, y: 0.4, endX: 0.72, endY: 0.55)
        let focused = PhotoCanvas.presentation(photo, marker: marker, markerPhotoID: photo.id)
        let full = PhotoCanvas.presentation(photo, marker: marker, markerPhotoID: photo.id, focused: false)
        XCTAssertTrue(focused.isFocused); XCTAssertTrue(focused.canFocus)
        XCTAssertFalse(full.isFocused); XCTAssertTrue(full.canFocus)
        XCTAssertEqual(full.image.size, photo.image.size)
        XCTAssertEqual(focused.image.size, focused.cropRect.size, "The crop does not manufacture extra source pixels")
        XCTAssertEqual(photo.jpeg, originalJPEG); XCTAssertEqual(photo.image.pngData(), originalPixels)
        let tip = CGPoint(x: marker.endX! * photo.image.size.width, y: marker.endY! * photo.image.size.height)
        XCTAssertTrue(try containsMint(full.image, near: tip))
        XCTAssertTrue(try containsMint(focused.image, near: CGPoint(x: tip.x - focused.cropRect.minX, y: tip.y - focused.cropRect.minY)))
        // Away from the annotation, crop pixels correspond to original pixels.
        let local = CGPoint(x: 12, y: 12)
        XCTAssertEqual(try pixel(focused.image, at: local), try pixel(photo.image, at: CGPoint(x: local.x + focused.cropRect.minX, y: local.y + focused.cropRect.minY)))
    }

    private func fixture() throws -> MendPhoto {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 800), format: format).image { renderer in
            UIColor(red: 0.2, green: 0.2, blue: 0.4, alpha: 1).setFill(); renderer.fill(CGRect(x: 0, y: 0, width: 1200, height: 800))
            UIColor.red.setFill(); renderer.fill(CGRect(x: 600, y: 0, width: 600, height: 400))
            UIColor.blue.setFill(); renderer.fill(CGRect(x: 0, y: 400, width: 600, height: 400))
        }
        return MendPhoto(id: "fixture-photo", jpeg: try XCTUnwrap(image.jpegData(compressionQuality: 0.9)), image: image, source: "Test", capturedAt: .distantPast)
    }

    private func circle(x: Double, y: Double, width: Double, height: Double) -> PhotoMarker {
        PhotoMarker(kind: "circle", x: x, y: y, width: width, height: height, endX: nil, endY: nil, label: "Visible part")
    }
    private func dot(x: Double, y: Double) -> PhotoMarker {
        PhotoMarker(kind: "dot", x: x, y: y, width: nil, height: nil, endX: nil, endY: nil, label: "Visible part")
    }
    private func arrow(x: Double, y: Double, endX: Double, endY: Double) -> PhotoMarker {
        PhotoMarker(kind: "arrow", x: x, y: y, width: nil, height: nil, endX: endX, endY: endY, label: "Visible part")
    }
    private func originalPoint(_ point: CGPoint, crop: CGRect) -> CGPoint {
        CGPoint(x: crop.minX + point.x * crop.width, y: crop.minY + point.y * crop.height)
    }
    private func assertOriginalPoint(_ point: CGPoint, crop: CGRect, equals expected: CGPoint, file: StaticString = #filePath, line: UInt = #line) {
        let actual = originalPoint(point, crop: crop)
        XCTAssertEqual(actual.x, expected.x, accuracy: 0.00001, file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: 0.00001, file: file, line: line)
    }
    private func checkBounds(_ crop: CGRect, in size: CGSize, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThanOrEqual(crop.minX, 0, file: file, line: line); XCTAssertGreaterThanOrEqual(crop.minY, 0, file: file, line: line)
        XCTAssertLessThanOrEqual(crop.maxX, size.width, file: file, line: line); XCTAssertLessThanOrEqual(crop.maxY, size.height, file: file, line: line)
        XCTAssertGreaterThan(crop.width, 0, file: file, line: line); XCTAssertGreaterThan(crop.height, 0, file: file, line: line)
    }
    private func containsMint(_ image: UIImage, near point: CGPoint) throws -> Bool {
        for dy in -2...2 { for dx in -2...2 {
            let color = try pixel(image, at: CGPoint(x: point.x + CGFloat(dx), y: point.y + CGFloat(dy)))
            if color[1] > 200 && color[0] > 60 && color[0] < 150 && color[2] > 140 { return true }
        } }
        return false
    }
    private func pixel(_ image: UIImage, at point: CGPoint) throws -> [UInt8] {
        let source = try XCTUnwrap(image.cgImage)
        let sample = try XCTUnwrap(source.cropping(to: CGRect(x: point.x.rounded(.down), y: point.y.rounded(.down), width: 1, height: 1)))
        var rgba = [UInt8](repeating: 0, count: 4)
        try rgba.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return rgba
    }
}

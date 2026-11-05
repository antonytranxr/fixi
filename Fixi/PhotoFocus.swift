import Foundation
import CoreGraphics

/// A crop of the existing evidence only. Coordinates remain in the upright
/// original photo until this layout transforms the display copy's annotation.
enum PhotoFocus {
    struct Plan {
        let cropRect: CGRect
        let marker: PhotoMarker
    }

    static let maximumZoom: CGFloat = 3
    static let smallCircleMaximumExtent = 0.08

    /// A small ellipse marks one precise part. Keep its exact center while
    /// replacing the bulky outline with a compact dot, before any crop occurs.
    static func displayMarker(_ marker: PhotoMarker) -> PhotoMarker {
        guard isValid(marker), marker.kind == "circle", let width = marker.width, let height = marker.height,
              width <= smallCircleMaximumExtent, height <= smallCircleMaximumExtent else { return marker }
        return PhotoMarker(kind: "dot", x: marker.x + width / 2, y: marker.y + height / 2,
                           width: nil, height: nil, endX: nil, endY: nil, label: marker.label)
    }

    static func isValid(_ marker: PhotoMarker) -> Bool {
        func coordinate(_ value: Double) -> Bool { value.isFinite && (0...1).contains(value) }
        guard coordinate(marker.x), coordinate(marker.y),
              marker.label.count <= 80, !marker.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        switch marker.kind {
        case "dot":
            return marker.width == nil && marker.height == nil && marker.endX == nil && marker.endY == nil
        case "circle":
            guard let width = marker.width, let height = marker.height else { return false }
            return coordinate(width) && coordinate(height) && width > 0 && height > 0
                && marker.x + width <= 1 && marker.y + height <= 1 && marker.endX == nil && marker.endY == nil
        case "arrow":
            guard let endX = marker.endX, let endY = marker.endY else { return false }
            return coordinate(endX) && coordinate(endY) && marker.width == nil && marker.height == nil
                && hypot(endX - marker.x, endY - marker.y) >= 0.01
        default: return false
        }
    }

    /// Like Roomwise, retain context and avoid thin strips. Limit enlargement
    /// to 3× per dimension and keep at least 128 source pixels where available.
    static func plan(imageSize size: CGSize, marker: PhotoMarker) -> Plan? {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              isValid(marker) else { return nil }
        let bounds = CGRect(origin: .zero, size: size)
        let minimumSide = min(size.width, size.height)
        var start = CGPoint(x: marker.x * size.width, y: marker.y * size.height)
        let targetBounds: CGRect
        let end: CGPoint?
        if marker.kind == "dot" {
            end = nil
            targetBounds = CGRect(origin: start, size: .zero)
        } else if marker.kind == "circle", let width = marker.width, let height = marker.height {
            end = nil
            targetBounds = CGRect(origin: start, size: CGSize(width: width * size.width, height: height * size.height))
        } else if let endX = marker.endX, let endY = marker.endY {
            let tip = CGPoint(x: endX * size.width, y: endY * size.height)
            end = tip
            let dx = tip.x - start.x, dy = tip.y - start.y, length = hypot(dx, dy)
            // Keep the target and the last portion of a long arrow. Its tail
            // may shorten along the same vector; the arrowhead never moves.
            let retained = min(length, minimumSide * 0.30)
            start = CGPoint(x: tip.x - dx * retained / length, y: tip.y - dy * retained / length)
            targetBounds = CGRect(x: min(start.x, tip.x), y: min(start.y, tip.y),
                                  width: abs(tip.x - start.x), height: abs(tip.y - start.y))
        } else { return nil }

        let margin = max(max(targetBounds.width, targetBounds.height) * 0.25, minimumSide * 0.065)
        var width = max(targetBounds.width + margin * 2, max(size.width / maximumZoom, min(128, size.width)))
        var height = max(targetBounds.height + margin * 2, max(size.height / maximumZoom, min(128, size.height)))
        width = min(width, size.width); height = min(height, size.height)
        if width > height * 2 { height = width / 2 }
        if height > width * 2 { width = height / 2 }
        width = min(width, size.width); height = min(height, size.height)
        let x = min(max(0, targetBounds.midX - width / 2), size.width - width)
        let y = min(max(0, targetBounds.midY - height / 2), size.height - height)
        let crop = CGRect(x: x, y: y, width: width, height: height).integral.intersection(bounds)
        // A tiny framing change is not a useful close-up. Broad annotations
        // keep the original view and do not offer a redundant toggle.
        guard crop.width * crop.height <= size.width * size.height * 0.85 else { return nil }
        func normalized(_ point: CGPoint) -> CGPoint {
            CGPoint(x: (point.x - crop.minX) / crop.width, y: (point.y - crop.minY) / crop.height)
        }
        let localStart = normalized(start)
        let localMarker: PhotoMarker
        if let end {
            let localEnd = normalized(end)
            localMarker = PhotoMarker(kind: "arrow", x: localStart.x, y: localStart.y,
                                      width: nil, height: nil, endX: localEnd.x, endY: localEnd.y, label: marker.label)
        } else if marker.kind == "dot" {
            localMarker = PhotoMarker(kind: "dot", x: localStart.x, y: localStart.y,
                                      width: nil, height: nil, endX: nil, endY: nil, label: marker.label)
        } else {
            localMarker = PhotoMarker(kind: "circle", x: localStart.x, y: localStart.y,
                                      width: targetBounds.width / crop.width, height: targetBounds.height / crop.height,
                                      endX: nil, endY: nil, label: marker.label)
        }
        return Plan(cropRect: crop, marker: localMarker)
    }
}

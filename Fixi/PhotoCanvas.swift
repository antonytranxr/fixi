import UIKit
import ImageIO

/// All marker coordinates refer to the pixels of this orientation-corrected still.
struct MendPhoto {
    let id: String
    let jpeg: Data
    let image: UIImage
    let source: String
    let capturedAt: Date

    static func make(data: Data, source: String) throws -> MendPhoto {
        guard data.count <= 24 * 1024 * 1024,
              let sourceImage = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(sourceImage, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1600
              ] as CFDictionary) else { throw MendError.message("Choose a readable photo under 24 MB.") }
        let image = UIImage(cgImage: cg)
        guard let jpeg = image.jpegData(compressionQuality: 0.85) else { throw MendError.message("This photo could not be prepared.") }
        return MendPhoto(id: UUID().uuidString, jpeg: jpeg, image: image, source: source, capturedAt: Date())
    }
}

enum PhotoCanvas {
    static let mint = UIColor(red: 0.38, green: 0.93, blue: 0.73, alpha: 1)

    struct Presentation {
        let image: UIImage
        let isFocused: Bool
        let canFocus: Bool
        /// Rectangle in the upright original image's coordinate space.
        let cropRect: CGRect
    }

    /// A focused display copy never changes the photo sent to analysis. A
    /// marker without an exact source-photo match is never drawn or cropped.
    static func presentation(_ photo: MendPhoto, marker: PhotoMarker?, markerPhotoID: String?, focused: Bool = true) -> Presentation {
        let full = CGRect(origin: .zero, size: photo.image.size)
        guard markerPhotoID == photo.id, let marker, PhotoFocus.isValid(marker) else {
            return Presentation(image: photo.image, isFocused: false, canFocus: false, cropRect: full)
        }
        let displayMarker = PhotoFocus.displayMarker(marker)
        let plan = PhotoFocus.plan(imageSize: photo.image.size, marker: displayMarker)
        if focused, let plan {
            return Presentation(image: draw(photo.image, marker: plan.marker, crop: plan.cropRect),
                                isFocused: true, canFocus: true, cropRect: plan.cropRect)
        }
        return Presentation(image: render(photo.image, marker: displayMarker), isFocused: false, canFocus: plan != nil, cropRect: full)
    }

    static func render(_ image: UIImage, marker: PhotoMarker?) -> UIImage {
        guard let marker, PhotoFocus.isValid(marker) else { return image }
        return draw(image, marker: PhotoFocus.displayMarker(marker), crop: CGRect(origin: .zero, size: image.size))
    }

    private static func draw(_ image: UIImage, marker: PhotoMarker, crop: CGRect) -> UIImage {
        let size = crop.size
        guard size.width > 0, size.height > 0 else { return image }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            image.draw(in: CGRect(x: -crop.minX, y: -crop.minY, width: image.size.width, height: image.size.height))
            let c = context.cgContext
            if marker.kind == "dot" {
                // Keep the precise part visible around a small solid center.
                // Never clamp its position away from the actual evidence.
                let radius = max(3, min(size.width, size.height) * 0.007)
                let border = max(1, min(size.width, size.height) * 0.0025)
                let center = CGPoint(x: marker.x * size.width, y: marker.y * size.height)
                c.setFillColor(UIColor.black.withAlphaComponent(0.9).cgColor)
                c.fillEllipse(in: CGRect(x: center.x - radius - border, y: center.y - radius - border,
                                        width: (radius + border) * 2, height: (radius + border) * 2))
                c.setFillColor(mint.cgColor)
                c.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius,
                                        width: radius * 2, height: radius * 2))
                return
            }
            let width = max(4, min(size.width, size.height) * 0.012)
            c.setLineCap(.round); c.setLineJoin(.round)
            let path = CGMutablePath()
            if marker.kind == "circle", let w = marker.width, let h = marker.height {
                path.addEllipse(in: CGRect(x: marker.x * size.width, y: marker.y * size.height,
                                           width: w * size.width, height: h * size.height))
            } else if marker.kind == "arrow", let ex = marker.endX, let ey = marker.endY {
                let a = CGPoint(x: marker.x * size.width, y: marker.y * size.height)
                let b = CGPoint(x: ex * size.width, y: ey * size.height)
                path.move(to: a); path.addLine(to: b)
                let angle = atan2(b.y - a.y, b.x - a.x)
                let head = min(max(width * 4, 20), hypot(b.x - a.x, b.y - a.y) * 0.35)
                for offset in [-CGFloat.pi / 6, CGFloat.pi / 6] {
                    path.move(to: b)
                    path.addLine(to: CGPoint(x: b.x - head * cos(angle + offset), y: b.y - head * sin(angle + offset)))
                }
            } else { return }
            c.addPath(path); c.setStrokeColor(UIColor.black.withAlphaComponent(0.9).cgColor)
            c.setLineWidth(width + 5); c.strokePath()
            c.addPath(path); c.setStrokeColor(mint.cgColor); c.setLineWidth(width); c.strokePath()
        }
    }

    /// A clearly labeled, deterministic illustration; never masquerades as a camera photo.
    static func examplePhoto() -> UIImage {
        let size = CGSize(width: 960, height: 640)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let c = ctx.cgContext
            UIColor(red: 0.17, green: 0.23, blue: 0.24, alpha: 1).setFill(); c.fill(CGRect(origin: .zero, size: size))
            UIColor(red: 0.65, green: 0.48, blue: 0.31, alpha: 1).setFill()
            c.fill(CGRect(x: 140, y: 80, width: 300, height: 480)); c.fill(CGRect(x: 458, y: 80, width: 360, height: 480))
            c.setStrokeColor(UIColor.black.withAlphaComponent(0.12).cgColor); c.setLineWidth(2)
            for x in stride(from: 160, to: 820, by: 24) { c.move(to: CGPoint(x: x, y: 85)); c.addLine(to: CGPoint(x: x + 12, y: 555)); c.strokePath() }
            UIColor(red: 0.72, green: 0.78, blue: 0.77, alpha: 1).setFill()
            UIBezierPath(roundedRect: CGRect(x: 345, y: 235, width: 240, height: 150), cornerRadius: 15).fill()
            UIColor(red: 0.36, green: 0.43, blue: 0.43, alpha: 1).setFill()
            UIBezierPath(roundedRect: CGRect(x: 424, y: 217, width: 65, height: 184), cornerRadius: 15).fill()
            for point in [CGPoint(x: 382,y: 272), CGPoint(x: 382,y: 347), CGPoint(x: 544,y: 272), CGPoint(x: 544,y: 347)] {
                UIColor.darkGray.setFill(); UIBezierPath(ovalIn: CGRect(x: point.x - 18, y: point.y - 18, width: 36, height: 36)).fill()
                c.setStrokeColor(UIColor.white.withAlphaComponent(0.8).cgColor); c.setLineWidth(4)
                c.move(to: CGPoint(x: point.x - 10,y: point.y)); c.addLine(to: CGPoint(x: point.x + 10,y: point.y))
                c.move(to: CGPoint(x: point.x,y: point.y - 10)); c.addLine(to: CGPoint(x: point.x,y: point.y + 10)); c.strokePath()
            }
            let label = "EXAMPLE · CABINET HINGE" as NSString
            label.draw(at: CGPoint(x: 40,y: 590), withAttributes: [.font: UIFont.monospacedSystemFont(ofSize: 20, weight: .medium), .foregroundColor: UIColor.white])
        }
    }
}

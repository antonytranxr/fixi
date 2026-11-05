import Foundation
import ImageIO

// Export selected option #2 without redrawing or changing its design.
// Its opaque original is retained for reproducible app-icon exports.
let root = URL(fileURLWithPath: #filePath).standardizedFileURL.deletingLastPathComponent().deletingLastPathComponent()
let source = root.appendingPathComponent("Fixi/Resources/Brand/Fixi-liquid-glass-original.png")
let destination = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : root.appendingPathComponent("Fixi/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
let export = Process()
export.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
export.arguments = ["--resampleHeightWidth", "1024", "1024", source.path, "--out", destination.path]
try export.run()
export.waitUntilExit()
guard export.terminationStatus == 0,
      let image = CGImageSourceCreateWithURL(destination as CFURL, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
      (properties[kCGImagePropertyPixelWidth] as? Int) == 1024,
      (properties[kCGImagePropertyPixelHeight] as? Int) == 1024,
      (properties[kCGImagePropertyHasAlpha] as? Bool) != true else {
    fatalError("The Fixi icon must be 1024 × 1024 and opaque.")
}
print("Exported the selected Fixi icon at 1024 × 1024 with no alpha channel.")

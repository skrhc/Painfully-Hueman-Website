// Crops a photo of a painting (or framed work) on a wall down to the
// painting itself: finds the largest rectangle with macOS's built-in
// rectangle detection, straightens it if it was shot at a slight angle,
// and saves a PNG.
//
// Usage: crop-painting <input image> <output.png> [inset px]
// Exit codes: 0 = done, 4 = no rectangle found (nothing written),
//             1 = couldn't read or write the image

import CoreImage
import Foundation
import ImageIO
import Vision

func fail(_ message: String, _ code: Int32) -> Never {
  FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
  exit(code)
}

let args = CommandLine.arguments
guard args.count >= 3 else { fail("usage: crop-painting <input> <output.png> [inset]", 2) }
let inset = args.count > 3 ? CGFloat(Double(args[3]) ?? 0) : 0

guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
      let cg = CGImageSourceCreateImageAtIndex(source, 0, nil)
else { fail("can't read image", 1) }

// Respect the photo's orientation (phone photos are often stored sideways).
let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
let orientation = (props?[kCGImagePropertyOrientation] as? UInt32)
  .flatMap { CGImagePropertyOrientation(rawValue: $0) } ?? .up
let image = CIImage(cgImage: cg).oriented(orientation)

let request = VNDetectRectanglesRequest()
request.maximumObservations = 8
request.minimumSize = 0.15
request.minimumConfidence = 0.5
request.quadratureTolerance = 25
request.minimumAspectRatio = 0.1
request.maximumAspectRatio = 1.0

let handler = VNImageRequestHandler(ciImage: image, options: [:])
try? handler.perform([request])

func area(_ r: VNRectangleObservation) -> CGFloat { r.boundingBox.width * r.boundingBox.height }
guard let best = (request.results ?? []).max(by: { area($0) < area($1) }) else {
  fail("no rectangle found", 4)
}

let w = image.extent.width, h = image.extent.height
func pt(_ p: CGPoint) -> CIVector { CIVector(x: p.x * w, y: p.y * h) }

guard let filter = CIFilter(name: "CIPerspectiveCorrection") else { fail("no filter", 1) }
filter.setValue(image, forKey: kCIInputImageKey)
filter.setValue(pt(best.topLeft), forKey: "inputTopLeft")
filter.setValue(pt(best.topRight), forKey: "inputTopRight")
filter.setValue(pt(best.bottomLeft), forKey: "inputBottomLeft")
filter.setValue(pt(best.bottomRight), forKey: "inputBottomRight")
guard var out = filter.outputImage else { fail("correction failed", 1) }


// Shave a few pixels so no sliver of wall is left along the edges.
if inset > 0 { out = out.cropped(to: out.extent.insetBy(dx: inset, dy: inset)) }

let ctx = CIContext()
guard let result = ctx.createCGImage(out, from: out.extent),
      let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL,
                                                 "public.png" as CFString, 1, nil)
else { fail("can't write image", 1) }
CGImageDestinationAddImage(dest, result, nil)
guard CGImageDestinationFinalize(dest) else { fail("can't write image", 1) }
print(String(format: "rectangle %.0f%% of the photo, confidence %.2f, %dx%d",
             area(best) * 100, best.confidence, result.width, result.height))

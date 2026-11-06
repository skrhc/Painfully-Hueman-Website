// Removes the background from a photo using macOS's built-in subject
// detection (the same as "Lift subject from background" in Photos),
// crops to the subject, and saves a transparent PNG.
//
// Usage: remove-bg <input image> <output.png>
// Exit codes: 0 = done
//             3 = image already has a transparent background (nothing written)
//             4 = no subject found (nothing written)
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
guard args.count == 3 else { fail("usage: remove-bg <input> <output.png>", 2) }

let inURL = URL(fileURLWithPath: args[1])
let outURL = URL(fileURLWithPath: args[2])

guard let source = CGImageSourceCreateWithURL(inURL as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
else { fail("can't read image", 1) }

let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
let orientation = (props?[kCGImagePropertyOrientation] as? UInt32)
  .flatMap { CGImagePropertyOrientation(rawValue: $0) } ?? .up

// Skip images that are already cut out (any see-through pixels).
func hasTransparency(_ img: CGImage) -> Bool {
  switch img.alphaInfo {
  case .none, .noneSkipFirst, .noneSkipLast: return false
  default: break
  }
  let w = 256
  let h = max(1, Int(Double(img.height) * Double(w) / Double(img.width)))
  var pixels = [UInt8](repeating: 0, count: w * h * 4)
  let drew = pixels.withUnsafeMutableBytes { buf -> Bool in
    guard let ctx = CGContext(
      data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return false }
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    return true
  }
  guard drew else { return false }
  return stride(from: 3, to: pixels.count, by: 4).contains { pixels[$0] < 250 }
}

if hasTransparency(image) { exit(3) }

let request = VNGenerateForegroundInstanceMaskRequest()
let handler = VNImageRequestHandler(cgImage: image, orientation: orientation)

do {
  try handler.perform([request])
} catch {
  fail("subject detection failed: \(error.localizedDescription)", 4)
}

guard let result = request.results?.first, !result.allInstances.isEmpty
else { exit(4) }

do {
  let masked = try result.generateMaskedImage(
    ofInstances: result.allInstances, from: handler, croppedToInstancesExtent: true)
  let ci = CIImage(cvPixelBuffer: masked)
  try CIContext().writePNGRepresentation(
    of: ci, to: outURL, format: .RGBA8,
    colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
} catch {
  fail("couldn't save cut-out: \(error.localizedDescription)", 1)
}

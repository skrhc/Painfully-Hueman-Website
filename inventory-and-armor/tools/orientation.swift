// Which way up is a video? (Apple Vision, on the Mac, no network.)
//
//   swift orientation.swift a.jpg b.jpg ...
//   -> one line per image: "<score upright> <score turned clockwise> <score upside down> <score turned counter-clockwise>"
//
// Each score is how sure Vision is that it sees upright people (bodies and
// faces) when the picture is turned that way. best-clip.py / process-inbox.sh
// turn a video when the frames agree it's on its side.
import Foundation
import Vision
import AppKit

// the picture as stored -> how it would need turning
let turns: [CGImagePropertyOrientation] = [.up, .right, .down, .left]

for path in CommandLine.arguments.dropFirst() {
    var scores: [Double] = []
    guard let img = NSImage(contentsOfFile: path),
          let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        print("0 0 0 0"); continue
    }
    for o in turns {
        let body = VNDetectHumanBodyPoseRequest()
        let face = VNDetectFaceRectanglesRequest()
        face.revision = VNDetectFaceRectanglesRequestRevision3
        try? VNImageRequestHandler(cgImage: cg, orientation: o).perform([body, face])
        var s = 0.0
        for b in body.results ?? [] {
            // upright: head and neck above the hips
            guard let pts = try? b.recognizedPoints(.all) else { continue }
            if let n = pts[.neck], let r = pts[.root], n.confidence > 0.3, r.confidence > 0.3, n.location.y > r.location.y {
                s += Double(min(n.confidence, r.confidence))
            }
        }
        for f in face.results ?? [] {
            // a face counts when it's level (not tilted more than 30 degrees) this way up
            if let roll = f.roll?.doubleValue, abs(roll) < Double.pi / 6 {
                s += Double(f.confidence) * 0.5
            }
        }
        scores.append(s)
    }
    print(scores.map { String(format: "%.3f", $0) }.joined(separator: " "))
}

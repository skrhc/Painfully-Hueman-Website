// How much text is in each image (Apple Vision, on the Mac, no network).
//
//   swift text-in-image.swift a.jpg b.jpg ...
//   -> one line per image: <share of the picture covered by text> <tallest line's height share> <text>
//
// Used by best-clip.py to keep title cards, credits and big captions out of
// ARMORY video loops.
import Foundation
import Vision
import AppKit

for path in CommandLine.arguments.dropFirst() {
    var area = 0.0, tallest = 0.0, words: [String] = []
    if let img = NSImage(contentsOfFile: path),
       let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: cg).perform([req])
        for obs in req.results ?? [] {
            guard let top = obs.topCandidates(1).first, top.confidence > 0.3,
                  top.string.filter({ $0.isLetter || $0.isNumber }).count >= 2 else { continue }
            let b = obs.boundingBox
            area += Double(b.width * b.height)
            tallest = max(tallest, Double(b.height))
            words.append(top.string)
        }
    }
    print(String(format: "%.4f %.4f ", area, tallest) + words.joined(separator: " | ").replacingOccurrences(of: "\n", with: " "))
}

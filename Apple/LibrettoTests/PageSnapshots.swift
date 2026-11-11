import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import LibrettoEngine

/// Draws a document's pages as the PDF has them and compares each with a
/// reference image kept on disk, so a change to what is drawn — a picture
/// gone, a page broken somewhere new, a table drawn differently — fails.
///
/// References are PNGs named `page-1.png`, `page-2.png`… in a folder per
/// document. Run with `TEST_RUNNER_LIBRETTO_RECORD_REFERENCES=1` to write
/// them afresh from what is drawn now; pages that differ are written, with
/// a picture of where they differ, to `TEST_RUNNER_LIBRETTO_RENDERING_OUTPUT`
/// (or a folder in the temporary directory), and the path is printed.
enum PageSnapshots {
    /// Pixels to the point. One keeps references small; text still shows every line.
    static let scale: CGFloat = 1
    /// How far apart a pixel's channels may be and still count as the same,
    /// so smoothing that differs by a shade doesn't fail.
    static let channelTolerance = 48
    /// The share of a page's pixels that may differ.
    static let allowedDifference = 0.001

    static var isRecording: Bool {
        ProcessInfo.processInfo.environment["LIBRETTO_RECORD_REFERENCES"] != nil
    }

    static var output: URL {
        ProcessInfo.processInfo.environment["LIBRETTO_RENDERING_OUTPUT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appending(path: "LibrettoRendering")
    }

    /// The pages of a document, as the PDF draws them.
    @MainActor
    static func pages(of document: WordDocument) -> [CGImage] {
        let printed = PrintedPages(document: document)
        return (0..<printed.count).compactMap { printed.image($0, scale: scale) }
    }

    /// Compares a document's pages with the references in `folder`, and
    /// returns what differs, one line each; empty if every page matches.
    ///
    /// With no references yet, or when recording, they are written instead:
    /// `missingIsProblem` says whether having none is itself a failure.
    @MainActor
    static func compare(_ document: WordDocument, with folder: URL, name: String, missingIsProblem: Bool = true) throws -> [String] {
        let drawn = pages(of: document)
        let references = referencePages(in: folder)
        if isRecording || references.isEmpty {
            try record(drawn, in: folder)
            if isRecording || !missingIsProblem { return [] }
            return ["\(name): no reference images; recorded \(drawn.count) page(s) in \(folder.path), check and commit them"]
        }

        var problems: [String] = []
        if drawn.count != references.count {
            problems.append("\(name): \(drawn.count) page(s) drawn, \(references.count) in the references")
        }
        for (index, (page, url)) in zip(drawn, references).enumerated() {
            guard let reference = load(url) else {
                problems.append("\(name): page \(index + 1)'s reference doesn't read")
                continue
            }
            let comparison = difference(page, reference)
            guard !comparison.matches else { continue }
            let kept = output.appending(path: name)
            try FileManager.default.createDirectory(at: kept, withIntermediateDirectories: true)
            try write(page, to: kept.appending(path: "page-\(index + 1).png"))
            if let picture = comparison.picture { try write(picture, to: kept.appending(path: "page-\(index + 1)-difference.png")) }
            problems.append("\(name): page \(index + 1) \(comparison.summary); drawn and difference in \(kept.path)")
        }
        return problems
    }

    // MARK: References

    static func referencePages(in folder: URL) -> [URL] {
        var pages: [URL] = []
        while case let url = folder.appending(path: "page-\(pages.count + 1).png"),
              FileManager.default.fileExists(atPath: url.path) {
            pages.append(url)
        }
        return pages
    }

    static func record(_ pages: [CGImage], in folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for stale in referencePages(in: folder) { try FileManager.default.removeItem(at: stale) }
        for (index, page) in pages.enumerated() {
            try write(page, to: folder.appending(path: "page-\(index + 1).png"))
        }
    }

    static func load(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static func write(_ image: CGImage, to url: URL) throws {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        try (data as Data).write(to: url, options: .atomic)
    }

    // MARK: Comparing

    struct Comparison {
        var size: (drawn: CGSize, reference: CGSize)
        var differing = 0
        var total = 0
        /// Where the differing pixels are.
        var bounds = CGRect.null
        /// The reference, faded, with the differing pixels in red.
        var picture: CGImage?

        var share: Double { total == 0 ? 1 : Double(differing) / Double(total) }
        var matches: Bool { size.drawn == size.reference && share <= PageSnapshots.allowedDifference }

        var summary: String {
            if size.drawn != size.reference {
                return "is \(Int(size.drawn.width))×\(Int(size.drawn.height)) pixels, "
                    + "the reference \(Int(size.reference.width))×\(Int(size.reference.height))"
            }
            return String(format: "differs in %d pixels (%.2f%%), within x %d–%d, y %d–%d", differing, share * 100,
                          Int(bounds.minX), Int(bounds.maxX), Int(bounds.minY), Int(bounds.maxY))
        }
    }

    /// An image's pixels, as 8-bit RGBA on white.
    static func pixels(_ image: CGImage) -> [UInt8] {
        var pixels = [UInt8](repeating: 255, count: image.width * image.height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB), let context = CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return pixels
    }

    static func difference(_ drawn: CGImage, _ reference: CGImage) -> Comparison {
        var comparison = Comparison(size: (
            CGSize(width: drawn.width, height: drawn.height), CGSize(width: reference.width, height: reference.height)
        ))
        guard comparison.size.drawn == comparison.size.reference else { return comparison }
        let width = drawn.width, height = drawn.height
        let left = pixels(drawn)
        var right = pixels(reference)
        comparison.total = width * height
        for pixel in 0..<comparison.total {
            let at = pixel * 4
            let differs = (0..<3).contains { abs(Int(left[at + $0]) - Int(right[at + $0])) > channelTolerance }
            if differs {
                comparison.differing += 1
                comparison.bounds = comparison.bounds.union(
                    CGRect(x: pixel % width, y: pixel / width, width: 1, height: 1)
                )
                right[at] = 255; right[at + 1] = 0; right[at + 2] = 0
            } else {
                for channel in 0..<3 { right[at + channel] = UInt8(191 + Int(right[at + channel]) / 4) }
            }
            right[at + 3] = 255
        }
        if comparison.differing > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) {
            comparison.picture = right.withUnsafeMutableBytes { buffer in
                CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )?.makeImage()
            }
        }
        return comparison
    }
}

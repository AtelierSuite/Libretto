import SwiftUI

#if canImport(UIKit)
import UIKit

public typealias PlatformColor = UIColor
public typealias PlatformFont = UIFont
public typealias PlatformFontDescriptor = UIFontDescriptor
public typealias PlatformImage = UIImage
public typealias PlatformBezierPath = UIBezierPath
public typealias PlatformEdgeInsets = UIEdgeInsets
#else
import AppKit

public typealias PlatformColor = NSColor
public typealias PlatformFont = NSFont
public typealias PlatformFontDescriptor = NSFontDescriptor
public typealias PlatformImage = NSImage
public typealias PlatformBezierPath = NSBezierPath
public typealias PlatformEdgeInsets = NSEdgeInsets

extension NSEdgeInsets: @retroactive Equatable {
    public static func == (lhs: NSEdgeInsets, rhs: NSEdgeInsets) -> Bool {
        lhs.top == rhs.top && lhs.left == rhs.left && lhs.bottom == rhs.bottom && lhs.right == rhs.right
    }
}
#endif

// What the engine draws with, the same on either platform. Drawing is always
// done top down, as UIKit does it: AppKit contexts the engine sets up are flipped.

extension PlatformColor {
    /// The colour text is drawn in by default.
    public static var text: PlatformColor {
        #if canImport(UIKit)
        .label
        #else
        .labelColor
        #endif
    }

    /// A colour from sRGB components.
    public static func sRGB(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat = 1) -> PlatformColor {
        #if canImport(UIKit)
        PlatformColor(red: red, green: green, blue: blue, alpha: alpha)
        #else
        PlatformColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
        #endif
    }

    /// A system colour as it looks in a light or dark appearance, fixed so it no longer follows the system's.
    public func resolved(for scheme: ColorScheme) -> PlatformColor {
        #if canImport(UIKit)
        resolvedColor(with: UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light))
        #else
        var resolved = self
        NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            resolved = self.usingColorSpace(.sRGB) ?? self
        }
        return resolved
        #endif
    }
}

extension PlatformFont {
    /// The font families installed.
    public static var installedFamilyNames: [String] {
        #if canImport(UIKit)
        UIFont.familyNames
        #else
        NSFontManager.shared.availableFontFamilies
        #endif
    }

    #if !canImport(UIKit)
    /// The height of a line set in the font, as UIKit has it.
    public var lineHeight: CGFloat { ceil(ascender - descender + leading) }

    public static func italicSystemFont(ofSize size: CGFloat) -> NSFont {
        let base = NSFont.systemFont(ofSize: size)
        return NSFont(descriptor: base.fontDescriptor.withSymbolicTraits(.italic), size: size) ?? base
    }
    #endif
}

extension PlatformFontDescriptor {
    /// The descriptor with traits added, or `nil` if no font has them.
    public func adding(bold: Bool, italic: Bool) -> PlatformFontDescriptor? {
        #if canImport(UIKit)
        var traits: UIFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        return withSymbolicTraits(traits.union(symbolicTraits))
        #else
        var traits: NSFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        let descriptor = withSymbolicTraits(traits.union(symbolicTraits))
        // AppKit hands back a descriptor whether or not a font has the traits: one that has none is no match.
        guard let font = NSFont(descriptor: descriptor, size: 12) else { return nil }
        let found = font.fontDescriptor.symbolicTraits
        return found.isSuperset(of: traits) ? descriptor : nil
        #endif
    }

    /// The descriptor set in the font's own small capitals.
    public var addingSmallCaps: PlatformFontDescriptor {
        #if canImport(UIKit)
        addingAttributes([.featureSettings: [[
            UIFontDescriptor.FeatureKey.featureIdentifier: 37, UIFontDescriptor.FeatureKey.typeIdentifier: 1,
        ]]])
        #else
        addingAttributes([.featureSettings: [[
            NSFontDescriptor.FeatureKey.typeIdentifier: 37, NSFontDescriptor.FeatureKey.selectorIdentifier: 1,
        ]]])
        #endif
    }
}

extension PlatformImage {
    /// A picture drawn top down at the screen's scale, with a clear background.
    public static func drawn(size: CGSize, _ draw: (CGContext) -> Void) -> PlatformImage {
        #if canImport(UIKit)
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { renderer in draw(renderer.cgContext) }
        #else
        let scale: CGFloat = 2
        let pixelsWide = max(1, Int(ceil(size.width * scale)))
        let pixelsHigh = max(1, Int(ceil(size.height * scale)))
        let image = NSImage(size: size)
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
            bitsPerPixel: 0
        ), let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { return image }
        bitmap.size = size
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let context = graphics.cgContext
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        draw(context)
        NSGraphicsContext.current?.flushGraphics()
        image.addRepresentation(bitmap)
        return image
        #endif
    }

    /// An SF Symbol.
    public static func symbol(_ name: String) -> PlatformImage? {
        #if canImport(UIKit)
        PlatformImage(systemName: name)
        #else
        PlatformImage(systemSymbolName: name, accessibilityDescription: nil)
        #endif
    }

    #if !canImport(UIKit)
    public var cgImage: CGImage? {
        var rect = CGRect(origin: .zero, size: size)
        return cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
    #endif

    /// The picture with only `rect` of it left, in its pixels.
    public func cropped(toPixels rect: CGRect) -> PlatformImage? {
        guard let cgImage, let cropped = cgImage.cropping(to: rect) else { return nil }
        #if canImport(UIKit)
        return PlatformImage(cgImage: cropped, scale: scale, orientation: imageOrientation)
        #else
        let pointsPerPixel = size.width / CGFloat(max(1, cgImage.width))
        return PlatformImage(
            cgImage: cropped,
            size: CGSize(width: CGFloat(cropped.width) * pointsPerPixel, height: CGFloat(cropped.height) * pointsPerPixel)
        )
        #endif
    }

    /// Draws the picture the right way up in the current, top-down, context.
    public func drawUpright(in rect: CGRect) {
        #if canImport(UIKit)
        draw(in: rect)
        #else
        draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        #endif
    }

    public func drawUpright(at point: CGPoint) {
        drawUpright(in: CGRect(origin: point, size: size))
    }
}

#if !canImport(UIKit)
extension NSBezierPath {
    public convenience init(roundedRect rect: CGRect, cornerRadius: CGFloat) {
        self.init(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
    }

    public func addLine(to point: CGPoint) { line(to: point) }

    /// An arc as UIKit draws one: angles in radians, clockwise as it looks top down.
    public func addArc(withCenter center: CGPoint, radius: CGFloat, startAngle: CGFloat, endAngle: CGFloat, clockwise: Bool) {
        appendArc(
            withCenter: center, radius: radius, startAngle: startAngle * 180 / .pi, endAngle: endAngle * 180 / .pi,
            clockwise: !clockwise
        )
    }
}
#endif

/// Filling and printing, top down, on either platform.
public enum PlatformGraphics: Sendable {
    /// Fills a rectangle in the current context with its fill colour.
    public static func fill(_ rect: CGRect) {
        #if canImport(UIKit)
        UIRectFillUsingBlendMode(rect, .normal)
        #else
        rect.fill(using: .sourceOver)
        #endif
    }

    /// A PDF of pages, each its own size, drawn top down.
    public static func pdf(pages sizes: [CGSize], draw: (_ page: Int, CGContext) -> Void) -> Data {
        let first = CGRect(origin: .zero, size: sizes.first ?? CGSize(width: 612, height: 792))
        #if canImport(UIKit)
        return UIGraphicsPDFRenderer(bounds: first).pdfData { pdf in
            for (page, size) in sizes.enumerated() {
                // Each page its own size: the media box must say so, as well as the bounds.
                var box = CGRect(origin: .zero, size: size)
                pdf.beginPage(withBounds: box, pageInfo: [
                    kCGPDFContextMediaBox as String: Data(bytes: &box, count: MemoryLayout<CGRect>.size),
                ])
                draw(page, pdf.cgContext)
            }
        }
        #else
        let data = NSMutableData()
        var mediaBox = first
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return Data() }
        NSGraphicsContext.saveGraphicsState()
        for (page, size) in sizes.enumerated() {
            var box = CGRect(origin: .zero, size: size)
            context.beginPDFPage([kCGPDFContextMediaBox: Data(bytes: &box, count: MemoryLayout<CGRect>.size)] as CFDictionary)
            context.saveGState()
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            draw(page, context)
            context.restoreGState()
            context.endPDFPage()
        }
        NSGraphicsContext.restoreGraphicsState()
        context.closePDF()
        return data as Data
        #endif
    }
}

#if canImport(UIKit) || canImport(AppKit)
import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Draws shapes, text boxes, charts and SmartArt diagrams as pictures, for
/// the pages, the reader and the PDF to show.
public enum ObjectRenderer: Sendable {
    /// An object drawn at a size; in the dark scheme, text of no colour of its own set straight on the page is light, as the body's is.
    /// The picture reaches past the object's frame as far as its `overhang`: what is turned, and its effects.
    public static func image(for object: DrawingObject, size: CGSize, scheme: ColorScheme = .light) -> PlatformImage {
        let frame = CGSize(width: max(1, size.width), height: max(1, size.height))
        let past = overhang(for: object, size: frame)
        let canvas = CGSize(width: frame.width + past.left + past.right, height: frame.height + past.top + past.bottom)
        return PlatformImage.drawn(size: canvas) { context in
            context.translateBy(x: past.left, y: past.top)
            let bounds = CGRect(origin: .zero, size: frame)
            switch object {
            case .shape(let shape):
                draw(shape, in: bounds, context: context, scheme: scheme)
            case .diagram(let shapes):
                drawDiagram(shapes, in: bounds, context: context)
            case .group(let group):
                drawGroup(group, in: bounds, context: context, scheme: scheme)
            case .chart(let chart):
                ChartDrawing(chart: chart, bounds: bounds).draw()
            }
        }
    }

    public static func color(_ hex: String?, fallback: PlatformColor = .clear) -> PlatformColor {
        guard let hex, hex.count == 6, let value = Int(hex, radix: 16) else { return fallback }
        return PlatformColor.sRGB(
            red: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255, alpha: 1
        )
    }

    // MARK: - Past the frame

    /// How far an object is drawn past each edge of its frame, in points.
    public struct Overhang: Equatable, Sendable {
        public var top: CGFloat = 0, left: CGFloat = 0, bottom: CGFloat = 0, right: CGFloat = 0

        public static let zero = Overhang()

        public init(top: CGFloat = 0, left: CGFloat = 0, bottom: CGFloat = 0, right: CGFloat = 0) {
            self.top = top
            self.left = left
            self.bottom = bottom
            self.right = right
        }

        /// The same, for the object drawn `scale` times as large.
        public func scaled(by scale: CGFloat) -> Overhang {
            Overhang(top: top * scale, left: left * scale, bottom: bottom * scale, right: right * scale)
        }

        /// A frame grown by this much on each side.
        public func around(_ frame: CGRect) -> CGRect {
            CGRect(x: frame.minX - left, y: frame.minY - top, width: frame.width + left + right, height: frame.height + top + bottom)
        }
    }

    /// How far an object at a size is drawn past its frame: the corners of a turned shape, and
    /// with `effects`, its shadow and glow and the heads on its line's ends. Text keeps clear
    /// of a turned shape's corners, as in Word, but not of its effects.
    public static func overhang(for object: DrawingObject, size: CGSize, effects: Bool = true) -> Overhang {
        let bounds = CGRect(origin: .zero, size: size)
        let drawn: CGRect
        switch object {
        case .shape(let shape):
            drawn = drawnBounds(of: shape, in: bounds, effects: effects)
        case .group(let group):
            let scaleX = size.width / max(group.width, 0.01)
            let scaleY = size.height / max(group.height, 0.01)
            drawn = group.shapes.reduce(bounds) { union, shape in
                guard let frame = shape.frame else { return union }
                let rect = CGRect(x: frame.x * scaleX, y: frame.y * scaleY, width: frame.width * scaleX, height: frame.height * scaleY)
                return union.union(drawnBounds(of: shape, in: rect, effects: effects))
            }
        case .chart, .diagram:
            return .zero
        }
        func past(_ value: CGFloat) -> CGFloat { value > 0.01 ? ceil(value * 4) / 4 : 0 }
        return Overhang(
            top: past(bounds.minY - drawn.minY), left: past(bounds.minX - drawn.minX),
            bottom: past(drawn.maxY - bounds.maxY), right: past(drawn.maxX - bounds.maxX)
        )
    }

    /// Where a shape in a frame is drawn, turned and with its effects.
    static func drawnBounds(of shape: ShapeSpec, in rect: CGRect, effects: Bool) -> CGRect {
        let turned = rect.applying(turn(shape, in: rect))
        guard effects else { return turned }
        var drawn = turned
        if let shadow = shape.shadow {
            let offset = shadowOffset(shadow, of: shape)
            drawn = drawn.union(turned.offsetBy(dx: offset.width, dy: offset.height).insetBy(dx: -shadow.blur, dy: -shadow.blur))
        }
        if let glow = shape.glow {
            drawn = drawn.union(turned.insetBy(dx: -glow.radius, dy: -glow.radius))
        }
        return drawn
    }

    /// How far a shadow is set off on the page: the way the shape is turned too, if it turns with it.
    static func shadowOffset(_ shadow: ShapeShadow, of shape: ShapeSpec) -> CGSize {
        let offset = CGPoint(x: shadow.offset.x, y: shadow.offset.y)
        guard shadow.turnsWithShape else { return CGSize(width: offset.x, height: offset.y) }
        let turned = offset.applying(CGAffineTransform(rotationAngle: shape.rotation * .pi / 180))
        return CGSize(width: turned.x, height: turned.y)
    }

    /// Casts a shadow from what is drawn next, set off and blurred as much on the page as it says.
    /// Core Graphics measures a shadow in the context's base space, so it is turned and scaled there,
    /// from the page's space: the context's, less the shape's own turn.
    private static func castShadow(_ shadow: ShapeShadow, of shape: ShapeSpec, in rect: CGRect, context: CGContext) {
        let offset = shadowOffset(shadow, of: shape)
        let ctm = turn(shape, in: rect).inverted().concatenating(context.ctm)
        var base = CGSize(width: offset.width * ctm.a + offset.height * ctm.c, height: offset.width * ctm.b + offset.height * ctm.d)
        #if canImport(UIKit)
        // UIKit's contexts set shadows off down their own flipped space, not up the base space.
        base.height = -base.height
        #endif
        let scale = sqrt(abs(ctm.a * ctm.d - ctm.b * ctm.c))
        let ink = color(shadow.colorHex).withAlphaComponent(CGFloat(shadow.alpha)).cgColor
        context.setShadow(offset: base, blur: CGFloat(shadow.blur) * scale, color: ink)
    }

    /// How a shape is turned about its middle.
    static func turn(_ shape: ShapeSpec, in rect: CGRect) -> CGAffineTransform {
        guard shape.rotation.truncatingRemainder(dividingBy: 360) != 0 else { return .identity }
        return CGAffineTransform(translationX: rect.midX, y: rect.midY)
            .rotated(by: shape.rotation * .pi / 180)
            .translatedBy(x: -rect.midX, y: -rect.midY)
    }

    // MARK: - Shapes

    /// Where a shape's outline runs within its picture: in from each edge by half its line, so
    /// the stroke stays inside, but never past the middle, so a line as thin as a rule keeps a
    /// place to run along rather than having nowhere at all.
    public static func outlineRect(for shape: ShapeSpec, in rect: CGRect) -> CGRect {
        let margin = shape.lineWidth / 2 + 0.5
        return rect.insetBy(dx: min(margin, rect.width / 2), dy: min(margin, rect.height / 2))
    }

    /// A shape in a frame, turned about its middle with its text, as its own transform says.
    public static func draw(_ shape: ShapeSpec, in rect: CGRect, context: CGContext, scheme: ColorScheme = .light) {
        context.saveGState()
        defer { context.restoreGState() }
        context.concatenate(turn(shape, in: rect))
        drawUnturned(shape, in: rect, context: context, scheme: scheme)
    }

    private static func drawUnturned(_ shape: ShapeSpec, in rect: CGRect, context: CGContext, scheme: ColorScheme) {
        context.saveGState()
        if let glow = shape.glow {
            context.saveGState()
            context.concatenate(mirror(shape, in: rect))
            draw(glow, around: outlinePath(shape, in: rect), context: context)
            context.restoreGState()
        }
        // The fill and line cast one shadow together; the text, none of its own.
        if let shadow = shape.shadow {
            castShadow(shadow, of: shape, in: rect, context: context)
            context.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        context.concatenate(mirror(shape, in: rect))
        drawOutline(shape, in: rect, context: context)
        if shape.shadow != nil { context.endTransparencyLayer() }
        context.restoreGState()
        guard !shape.text.isEmpty else { return }
        // Text is never mirrored; flipped top to bottom, it is upside down.
        context.saveGState()
        defer { context.restoreGState() }
        if shape.flipsVertically {
            context.concatenate(CGAffineTransform(translationX: rect.midX, y: rect.midY).rotated(by: .pi)
                .translatedBy(x: -rect.midX, y: -rect.midY))
        }
        drawText(shape, in: rect, context: context, scheme: scheme)
    }

    /// How a shape's outline and fill are mirrored about its middle.
    static func mirror(_ shape: ShapeSpec, in rect: CGRect) -> CGAffineTransform {
        guard shape.flipsHorizontally || shape.flipsVertically else { return .identity }
        return CGAffineTransform(translationX: rect.midX, y: rect.midY)
            .scaledBy(x: shape.flipsHorizontally ? -1 : 1, y: shape.flipsVertically ? -1 : 1)
            .translatedBy(x: -rect.midX, y: -rect.midY)
    }

    /// The path a shape's outline runs along.
    static func outlinePath(_ shape: ShapeSpec, in rect: CGRect) -> PlatformBezierPath {
        let inset = outlineRect(for: shape, in: rect)
        return shape.outline.map { self.path($0, in: inset) } ?? self.path(shape.geometry, in: inset)
    }

    /// A glow around a path: its silhouette in the glow's colour, a little wider, blurred out as far as
    /// the glow reaches, and cleared again inside the outline, so only the glow around it is seen.
    private static func draw(_ glow: ShapeGlow, around path: PlatformBezierPath, context: CGContext) {
        let ctm = context.ctm
        let scale = sqrt(abs(ctm.a * ctm.d - ctm.b * ctm.c))
        let ink = color(glow.colorHex).withAlphaComponent(CGFloat(glow.alpha))
        context.saveGState()
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.setShadow(offset: .zero, blur: CGFloat(glow.radius) * scale, color: ink.cgColor)
        ink.setFill()
        ink.setStroke()
        path.lineWidth = CGFloat(glow.radius) * 0.6
        path.fill()
        path.stroke()
        context.setShadow(offset: .zero, blur: 0, color: nil)
        context.setBlendMode(.clear)
        path.fill()
        context.endTransparencyLayer()
        context.restoreGState()
    }

    /// A shape's fill and its line.
    private static func drawOutline(_ shape: ShapeSpec, in rect: CGRect, context: CGContext) {
        let path = outlinePath(shape, in: rect)
        if let gradient = shape.gradient {
            context.saveGState()
            path.addClip()
            fill(gradient, of: shape, in: rect, context: context)
            context.restoreGState()
        } else if let pattern = shape.pattern {
            context.saveGState()
            path.addClip()
            fill(pattern, in: rect, context: context)
            context.restoreGState()
        } else if let fill = shape.fillHex {
            color(fill).withAlphaComponent(CGFloat(shape.fillAlpha)).setFill()
            path.fill()
        }
        if let line = shape.lineHex {
            color(line).withAlphaComponent(CGFloat(shape.lineAlpha)).setStroke()
            path.lineWidth = max(0.5, shape.lineWidth)
            if shape.hasRoundCaps { path.lineCapStyle = .round }
            if let dashes = shape.lineDashes, !dashes.isEmpty {
                let lengths = dashes.map { CGFloat($0) * path.lineWidth }
                path.setLineDash(lengths, count: lengths.count, phase: 0)
            }
            path.stroke()
        }
    }

    /// A gradient across a shape's frame, in whatever it is clipped to.
    private static func fill(_ gradient: ShapeGradient, of shape: ShapeSpec, in rect: CGRect, context: CGContext) {
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let colors = gradient.stops.map { stop -> CGColor in
            let value = Int(stop.colorHex, radix: 16) ?? 0
            return CGColor(
                srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255, alpha: CGFloat(stop.alpha)
            )
        }
        var locations = gradient.stops.map { CGFloat($0.position) }
        guard let drawn = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: &locations) else { return }
        // One that doesn't turn with its shape is drawn unturned.
        if !gradient.turnsWithShape { context.concatenate(turn(shape, in: rect).inverted()) }
        let ends: CGGradientDrawingOptions = [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        switch gradient.kind {
        case .linear(let angle, let scaled):
            var box = rect
            if scaled {
                // At its angle in a square, the square then stretched to the frame.
                context.translateBy(x: rect.minX, y: rect.minY)
                context.scaleBy(x: max(rect.width, 0.01), y: max(rect.height, 0.01))
                box = CGRect(x: 0, y: 0, width: 1, height: 1)
            }
            let radians = angle * .pi / 180
            let direction = CGPoint(x: cos(radians), y: sin(radians))
            // From corner to corner along it, so the first and last colours just reach the frame's corners.
            let half = (abs(direction.x) * box.width + abs(direction.y) * box.height) / 2
            let start = CGPoint(x: box.midX - direction.x * half, y: box.midY - direction.y * half)
            let end = CGPoint(x: box.midX + direction.x * half, y: box.midY + direction.y * half)
            context.drawLinearGradient(drawn, start: start, end: end, options: ends)
        case .path(let focus, _):
            // Out from the middle of the focus to the farthest corner, stretched with the frame.
            context.translateBy(x: rect.minX, y: rect.minY)
            context.scaleBy(x: max(rect.width, 0.01), y: max(rect.height, 0.01))
            let center = CGPoint(x: (focus.left + 1 - focus.right) / 2, y: (focus.top + 1 - focus.bottom) / 2)
            let radius = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 1)]
                .map { hypot($0.x - center.x, $0.y - center.y) }.max() ?? 1
            context.drawRadialGradient(
                drawn, startCenter: center, startRadius: 0, endCenter: center, endRadius: max(radius, 0.01), options: ends
            )
        }
    }

    /// How large a pattern's pixel is, in points: as on a screen at 96 to the inch.
    static let patternPixel: CGFloat = 0.75

    /// A pattern's tile, over and over from the frame's top left corner, in whatever it is clipped to.
    /// A preset not drawn as Word draws it is filled with its two colours mixed half and half.
    private static func fill(_ pattern: ShapePattern, in rect: CGRect, context: CGContext) {
        color(pattern.backgroundHex).setFill()
        PlatformGraphics.fill(rect)
        let unit = patternPixel
        let columns = Int(ceil(rect.width / unit)), rows = Int(ceil(rect.height / unit))
        let path = CGMutablePath()
        for row in 0..<rows {
            var run: Int?
            for column in 0...columns {
                let on = column < columns
                    && (ShapePattern.isForeground(pattern.preset, x: column % 8, y: row % 8) ?? ShapePattern.isForeground(
                        "pct50", x: column % 8, y: row % 8) ?? false)
                if on, run == nil { run = column }
                if !on, let start = run {
                    path.addRect(CGRect(x: rect.minX + CGFloat(start) * unit, y: rect.minY + CGFloat(row) * unit,
                                        width: CGFloat(column - start) * unit, height: unit))
                    run = nil
                }
            }
        }
        context.addPath(path)
        context.setFillColor(color(pattern.foregroundHex).cgColor)
        context.fillPath()
    }

    /// A shape's text, in its own area, or its part of the text its linked boxes share.
    private static func drawText(_ shape: ShapeSpec, in rect: CGRect, context: CGContext, scheme: ColorScheme) {
        let ink: PlatformColor = shape.fillHex == nil && scheme == .dark ? .white : .black
        let fallbackColor = color(shape.textColorHex, fallback: shape.isTextBox || shape.fillHex == nil ? ink : .white)
        let text: NSAttributedString
        if let paragraphs = shape.formattedParagraphs {
            text = formattedText(paragraphs, color: fallbackColor, centred: !shape.isTextBox)
        } else {
            let style = NSMutableParagraphStyle()
            style.alignment = shape.isTextBox ? .natural : .center
            text = NSAttributedString(string: shape.text, attributes: [
                .font: PlatformFont.systemFont(ofSize: shape.fontSize ?? 11), .foregroundColor: fallbackColor,
                .paragraphStyle: style,
            ])
        }
        var area = textArea(for: shape, in: rect)
        // Text running down or up is set across the area's height, and turned a quarter about its middle.
        if shape.textDirection != .horizontal {
            context.translateBy(x: area.midX, y: area.midY)
            context.rotate(by: shape.textDirection == .down ? .pi / 2 : -.pi / 2)
            area = CGRect(x: -area.height / 2, y: -area.width / 2, width: area.height, height: area.width)
        }
        if let linked = shape.linkedText, linked.areas.indices.contains(linked.index) {
            drawLinked(text, linked, in: area)
            return
        }
        let height = ceil(text.boundingRect(with: CGSize(width: area.width, height: .greatestFiniteMagnitude),
                                            options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).height)
        // Where the document says; else a text box's text runs from the top, and a shape's sits in its middle.
        let top: CGFloat
        switch shape.textAnchor ?? (shape.isTextBox ? .top : .middle) {
        case .top: top = area.minY
        case .middle: top = area.midY - min(height, area.height) / 2
        case .bottom: top = area.maxY - min(height, area.height)
        }
        text.draw(with: CGRect(x: area.minX, y: top, width: area.width, height: min(height, area.height)),
                  options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine], context: nil)
    }

    /// A linked text box's part of the text that runs through its boxes: what is left after the
    /// boxes before it are full, as much as fits in its own area, from the top.
    private static func drawLinked(_ text: NSAttributedString, _ linked: LinkedText, in area: CGRect) {
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        for (index, frame) in linked.areas.enumerated() {
            let size = index == linked.index ? area.size : CGSize(width: frame.width, height: frame.height)
            let container = NSTextContainer(size: size)
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
        }
        let container = layout.textContainers[linked.index]
        let glyphs = layout.glyphRange(for: container)
        guard glyphs.length > 0 else { return }
        layout.drawGlyphs(forGlyphRange: glyphs, at: area.origin)
    }

    /// Where a shape's text goes: in from its edges by the document's insets, else by Libretto's own from its outline.
    public static func textArea(for shape: ShapeSpec, in rect: CGRect) -> CGRect {
        guard let insets = shape.textInsets else { return outlineRect(for: shape, in: rect).insetBy(dx: 7, dy: 4) }
        return CGRect(
            x: rect.minX + insets.left, y: rect.minY + insets.top,
            width: max(1, rect.width - insets.left - insets.right), height: max(1, rect.height - insets.top - insets.bottom)
        )
    }

    /// A shape's text in the formatting each of its paragraphs and runs has.
    public static func formattedText(_ paragraphs: [ShapeParagraph], color fallback: PlatformColor, centred: Bool) -> NSAttributedString {
        let text = NSMutableAttributedString()
        for (index, paragraph) in paragraphs.enumerated() {
            let style = NSMutableParagraphStyle()
            switch paragraph.alignment {
            case .center?: style.alignment = .center
            case .trailing?: style.alignment = .right
            case .justified?: style.alignment = .justified
            case .leading?: style.alignment = .left
            default: style.alignment = centred ? .center : .natural
            }
            style.paragraphSpacingBefore = paragraph.spaceBefore
            style.paragraphSpacing = paragraph.spaceAfter
            if let multiple = paragraph.lineHeightMultiple { style.lineHeightMultiple = multiple }
            let runs = paragraph.runs.isEmpty ? [ShapeRun(text: "")] : paragraph.runs
            for (runIndex, run) in runs.enumerated() {
                var string = run.text
                if runIndex == runs.count - 1, index < paragraphs.count - 1 { string += "\n" }
                guard !string.isEmpty else { continue }
                var attributes: [NSAttributedString.Key: Any] = [
                    .font: Typography.font(for: run.style, styles: StyleSheet()),
                    .foregroundColor: run.style.colorHex.map { color($0) } ?? fallback,
                    .paragraphStyle: style,
                ]
                if run.style.underline == true { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                if run.style.isStruckThrough == true { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                text.append(NSAttributedString(string: run.style.allCaps == true ? string.uppercased() : string, attributes: attributes))
            }
        }
        return text
    }

    /// An outline of a shape's own, scaled from the size it was drawn at to fill a rectangle.
    public static func path(_ outline: ShapeOutline, in rect: CGRect) -> PlatformBezierPath {
        let scaleX = outline.width > 0 ? rect.width / outline.width : 1
        let scaleY = outline.height > 0 ? rect.height / outline.height : 1
        func point(_ point: ShapePoint) -> CGPoint {
            CGPoint(x: rect.minX + point.x * scaleX, y: rect.minY + point.y * scaleY)
        }
        let path = PlatformBezierPath()
        var isOpen = false
        for element in outline.elements {
            switch element {
            case .move(let to):
                path.move(to: point(to))
                isOpen = true
            case .line(let to) where isOpen:
                path.addLine(to: point(to))
            case .quadCurve(let to, let control) where isOpen:
                path.addQuadCurve(to: point(to), controlPoint: point(control))
            case .curve(let to, let control1, let control2) where isOpen:
                path.addCurve(to: point(to), controlPoint1: point(control1), controlPoint2: point(control2))
            case .close where isOpen:
                path.close()
            default:
                break
            }
        }
        return path
    }

    /// A preset geometry's outline, as near as these come to Word's.
    public static func path(_ geometry: String, in rect: CGRect) -> PlatformBezierPath {
        let (x, y, w, h) = (rect.minX, rect.minY, rect.width, rect.height)
        func polygon(_ points: [(CGFloat, CGFloat)]) -> PlatformBezierPath {
            let path = PlatformBezierPath()
            for (index, point) in points.enumerated() {
                let location = CGPoint(x: x + w * point.0, y: y + h * point.1)
                if index == 0 { path.move(to: location) } else { path.addLine(to: location) }
            }
            path.close()
            return path
        }
        switch geometry {
        case "roundRect", "flowChartAlternateProcess", "wedgeRoundRectCallout":
            return PlatformBezierPath(roundedRect: rect, cornerRadius: min(w, h) * 0.16)
        case "ellipse", "flowChartConnector", "donut", "cloud", "wedgeEllipseCallout":
            return PlatformBezierPath(ovalIn: rect)
        case "triangle", "flowChartExtract":
            return polygon([(0.5, 0), (1, 1), (0, 1)])
        case "rtTriangle":
            return polygon([(0, 0), (1, 1), (0, 1)])
        case "diamond", "flowChartDecision":
            return polygon([(0.5, 0), (1, 0.5), (0.5, 1), (0, 0.5)])
        case "parallelogram", "flowChartInputOutput":
            return polygon([(0.25, 0), (1, 0), (0.75, 1), (0, 1)])
        case "trapezoid":
            return polygon([(0.2, 0), (0.8, 0), (1, 1), (0, 1)])
        case "pentagon", "homePlate":
            return geometry == "homePlate" ? polygon([(0, 0), (0.8, 0), (1, 0.5), (0.8, 1), (0, 1)])
                : polygon([(0.5, 0), (1, 0.38), (0.81, 1), (0.19, 1), (0, 0.38)])
        case "hexagon":
            return polygon([(0.25, 0), (0.75, 0), (1, 0.5), (0.75, 1), (0.25, 1), (0, 0.5)])
        case "octagon":
            return polygon([(0.3, 0), (0.7, 0), (1, 0.3), (1, 0.7), (0.7, 1), (0.3, 1), (0, 0.7), (0, 0.3)])
        case "chevron":
            return polygon([(0, 0), (0.75, 0), (1, 0.5), (0.75, 1), (0, 1), (0.25, 0.5)])
        case "rightArrow":
            return polygon([(0, 0.25), (0.6, 0.25), (0.6, 0), (1, 0.5), (0.6, 1), (0.6, 0.75), (0, 0.75)])
        case "leftArrow":
            return polygon([(1, 0.25), (0.4, 0.25), (0.4, 0), (0, 0.5), (0.4, 1), (0.4, 0.75), (1, 0.75)])
        case "upArrow":
            return polygon([(0.25, 1), (0.25, 0.4), (0, 0.4), (0.5, 0), (1, 0.4), (0.75, 0.4), (0.75, 1)])
        case "downArrow":
            return polygon([(0.25, 0), (0.25, 0.6), (0, 0.6), (0.5, 1), (1, 0.6), (0.75, 0.6), (0.75, 0)])
        case "plus", "mathPlus":
            return polygon([(0.35, 0), (0.65, 0), (0.65, 0.35), (1, 0.35), (1, 0.65), (0.65, 0.65), (0.65, 1),
                            (0.35, 1), (0.35, 0.65), (0, 0.65), (0, 0.35), (0.35, 0.35)])
        case "star5":
            let points = (0..<10).map { index -> (CGFloat, CGFloat) in
                let angle = CGFloat(index) * .pi / 5 - .pi / 2
                let radius: CGFloat = index % 2 == 0 ? 0.5 : 0.2
                return (0.5 + cos(angle) * radius, 0.5 + sin(angle) * radius + 0.03)
            }
            return polygon(points)
        case "line", "straightConnector1", "bentConnector3", "curvedConnector3":
            let path = PlatformBezierPath()
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            return path
        default:
            return PlatformBezierPath(rect: rect)
        }
    }

    // MARK: - Groups

    /// A group's shapes, each in its frame, the group stretched to fill the picture as Word stretches it.
    private static func drawGroup(_ group: ShapeGroup, in bounds: CGRect, context: CGContext, scheme: ColorScheme) {
        let scaleX = bounds.width / max(group.width, 0.01)
        let scaleY = bounds.height / max(group.height, 0.01)
        for shape in group.shapes {
            guard let frame = shape.frame else { continue }
            let rect = CGRect(
                x: bounds.minX + frame.x * scaleX, y: bounds.minY + frame.y * scaleY,
                width: frame.width * scaleX, height: frame.height * scaleY
            )
            draw(shape, in: rect, context: context, scheme: scheme)
        }
    }

    // MARK: - Diagrams

    private static func drawDiagram(_ shapes: [ShapeSpec], in bounds: CGRect, context: CGContext) {
        let frames = shapes.compactMap(\.frame)
        let width = frames.map { $0.x + $0.width }.max() ?? 1
        let height = frames.map { $0.y + $0.height }.max() ?? 1
        let scale = min(bounds.width / max(width, 1), bounds.height / max(height, 1))
        for shape in shapes {
            guard let frame = shape.frame else { continue }
            var scaled = shape
            scaled.fontSize = (shape.fontSize ?? 11) * scale
            draw(scaled, in: CGRect(x: frame.x * scale, y: frame.y * scale, width: frame.width * scale, height: frame.height * scale),
                 context: context)
        }
    }
}

/// A chart drawn from its cached values: title, plot, axes and legend.
private struct ChartDrawing {
    let chart: ChartSpec
    let bounds: CGRect

    static let palette = ["4472C4", "ED7D31", "A5A5A5", "FFC000", "5B9BD5", "70AD47", "264478", "9E480E"]

    private let labelFont = PlatformFont.systemFont(ofSize: 8)

    /// How a series is drawn: its own kind in a combined chart, else the chart's.
    private func kind(of index: Int) -> ChartSpec.Kind {
        chart.series[index].kind ?? chart.kind
    }

    private func seriesColor(_ index: Int) -> PlatformColor {
        ObjectRenderer.color(chart.series[index].colorHex ?? Self.palette[index % Self.palette.count])
    }

    private func label(_ text: String, at point: CGPoint, alignment: NSTextAlignment = .center, width: CGFloat = 60) {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        let attributes: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: PlatformColor.darkGray, .paragraphStyle: style]
        let x = alignment == .center ? point.x - width / 2 : alignment == .right ? point.x - width : point.x
        (text as NSString).draw(in: CGRect(x: x, y: point.y, width: width, height: 11), withAttributes: attributes)
    }

    func draw() {
        PlatformColor.white.setFill()
        PlatformGraphics.fill(bounds)
        var area = bounds.insetBy(dx: 8, dy: 8)
        if let title = chart.title {
            let attributes: [NSAttributedString.Key: Any] = [.font: PlatformFont.boldSystemFont(ofSize: 11), .foregroundColor: PlatformColor.black]
            let size = (title as NSString).size(withAttributes: attributes)
            (title as NSString).draw(at: CGPoint(x: area.midX - size.width / 2, y: area.minY), withAttributes: attributes)
            area.origin.y += size.height + 6
            area.size.height -= size.height + 6
        }
        let isRound = chart.kind == .pie || chart.kind == .doughnut
        let names = isRound ? chart.categories : chart.series.map(\.name)
        if let position = chart.legend, !names.isEmpty {
            area = drawLegend(names, at: position, in: area, round: isRound)
        }
        switch chart.kind {
        case .pie, .doughnut: drawPie(in: area)
        case .radar: drawRadar(in: area)
        default: drawAxes(in: area)
        }
    }

    private var legendAttributes: [NSAttributedString.Key: Any] { [.font: labelFont, .foregroundColor: PlatformColor.darkGray] }

    private func legendColor(_ index: Int, round: Bool) -> PlatformColor {
        round ? sliceColor(index) : seriesColor(index)
    }

    /// The legend, in a row above or below the plot or a column beside it; what is left for the plot.
    private func drawLegend(_ names: [String], at position: ChartSpec.LegendPosition, in area: CGRect, round: Bool) -> CGRect {
        let widths = names.map { ($0 as NSString).size(withAttributes: legendAttributes).width + 16 }
        func key(_ index: Int, at point: CGPoint) {
            legendColor(index, round: round).setFill()
            PlatformGraphics.fill(CGRect(x: point.x, y: point.y + 2, width: 7, height: 7))
            (names[index] as NSString).draw(at: CGPoint(x: point.x + 10, y: point.y), withAttributes: legendAttributes)
        }
        switch position {
        case .bottom, .top:
            let y = position == .bottom ? area.maxY - 12 : area.minY
            var x = area.midX - widths.reduce(0, +) / 2
            for index in names.indices {
                key(index, at: CGPoint(x: x, y: y))
                x += widths[index]
            }
            var rest = area
            rest.size.height -= 18
            if position == .top { rest.origin.y += 18 }
            return rest
        case .left, .right:
            let column = min(widths.max() ?? 0, area.width / 3)
            let x = position == .right ? area.maxX - column : area.minX
            var y = area.midY - CGFloat(names.count) * 13 / 2
            for index in names.indices {
                key(index, at: CGPoint(x: x, y: y))
                y += 13
            }
            var rest = area
            rest.size.width -= column + 6
            if position == .left { rest.origin.x += column + 6 }
            return rest
        }
    }

    /// A pie's slice: its own colour, else the palette's.
    private func sliceColor(_ index: Int) -> PlatformColor {
        ObjectRenderer.color(chart.series.first?.pointColorsHex[index] ?? Self.palette[index % Self.palette.count])
    }

    /// A radar chart: a spoke for each category, a ring for each step, and each series a closed line.
    private func drawRadar(in area: CGRect) {
        let count = max(chart.categories.count, chart.series.map(\.values.count).max() ?? 0)
        guard count > 2 else { return }
        let (top, step) = scale(for: chart.series.flatMap(\.values).max() ?? 0)
        let center = CGPoint(x: area.midX, y: area.midY + 4)
        let radius = max(1, min(area.width, area.height) / 2 - 14)
        func point(_ index: Int, _ fraction: CGFloat) -> CGPoint {
            let angle = CGFloat(index) / CGFloat(count) * 2 * .pi - .pi / 2
            return CGPoint(x: center.x + cos(angle) * radius * fraction, y: center.y + sin(angle) * radius * fraction)
        }
        PlatformColor(white: 0.85, alpha: 1).setStroke()
        var value = step
        while value <= top + step / 2 {
            let ring = PlatformBezierPath()
            ring.move(to: point(0, CGFloat(value / top)))
            (1..<count).forEach { ring.addLine(to: point($0, CGFloat(value / top))) }
            ring.close()
            ring.lineWidth = 0.5
            ring.stroke()
            value += step
        }
        for index in 0..<count {
            PlatformColor(white: 0.85, alpha: 1).setStroke()
            let spoke = PlatformBezierPath()
            spoke.move(to: center)
            spoke.addLine(to: point(index, 1))
            spoke.lineWidth = 0.5
            spoke.stroke()
            if index < chart.categories.count {
                let outer = point(index, 1)
                let below = outer.y >= center.y
                label(chart.categories[index], at: CGPoint(x: outer.x, y: below ? outer.y + 2 : outer.y - 12))
            }
        }
        for (seriesIndex, series) in chart.series.enumerated() {
            let path = PlatformBezierPath()
            for (index, value) in series.values.prefix(count).enumerated() {
                let location = point(index, CGFloat(max(0, value) / top))
                if index == 0 { path.move(to: location) } else { path.addLine(to: location) }
            }
            path.close()
            seriesColor(seriesIndex).setStroke()
            path.lineWidth = 2
            path.stroke()
        }
    }

    private func drawPie(in area: CGRect) {
        let values = chart.series.first?.values.map { max(0, $0) } ?? []
        let total = values.reduce(0, +)
        guard total > 0 else { return }
        let radius = min(area.width, area.height) / 2
        let center = CGPoint(x: area.midX, y: area.midY)
        var angle = -CGFloat.pi / 2
        for (index, value) in values.enumerated() {
            let sweep = CGFloat(value / total) * 2 * .pi
            let path = PlatformBezierPath()
            path.move(to: center)
            path.addArc(withCenter: center, radius: radius, startAngle: angle, endAngle: angle + sweep, clockwise: true)
            path.close()
            sliceColor(index).setFill()
            path.fill()
            PlatformColor.white.setStroke()
            path.lineWidth = 1
            path.stroke()
            angle += sweep
        }
        if chart.kind == .doughnut {
            PlatformColor.white.setFill()
            PlatformBezierPath(ovalIn: CGRect(x: center.x - radius / 2, y: center.y - radius / 2, width: radius, height: radius)).fill()
        }
    }

    /// A round number of steps from zero to past the largest value.
    private func scale(for maximum: Double) -> (top: Double, step: Double) {
        guard maximum > 0 else { return (1, 0.2) }
        let rough = maximum / 5
        let magnitude = pow(10, floor(log10(rough)))
        let step = [1.0, 2, 2.5, 5, 10].map { $0 * magnitude }.first { $0 >= rough } ?? rough
        return (ceil(maximum / step) * step, step)
    }

    private func drawAxes(in area: CGRect) {
        let count = max(chart.categories.count, chart.series.map(\.values.count).max() ?? 0)
        guard count > 0 else { return }
        let maximum = chart.isStacked
            ? (0..<count).map { index in chart.series.reduce(0) { $0 + max(0, $1.values.indices.contains(index) ? $1.values[index] : 0) } }.max() ?? 0
            : chart.series.flatMap(\.values).max() ?? 0
        let (top, step) = scale(for: maximum)
        let horizontal = chart.kind == .bar
        let plot = CGRect(x: area.minX + (horizontal ? 50 : 28), y: area.minY + 4,
                          width: area.width - (horizontal ? 54 : 32), height: area.height - 18)
        // Gridlines and their values.
        PlatformColor(white: 0.85, alpha: 1).setStroke()
        var value = 0.0
        while value <= top + step / 2 {
            let fraction = CGFloat(value / top)
            let path = PlatformBezierPath()
            if horizontal {
                let x = plot.minX + plot.width * fraction
                path.move(to: CGPoint(x: x, y: plot.minY))
                path.addLine(to: CGPoint(x: x, y: plot.maxY))
                label(Self.format(value), at: CGPoint(x: x, y: plot.maxY + 3))
            } else {
                let y = plot.maxY - plot.height * fraction
                path.move(to: CGPoint(x: plot.minX, y: y))
                path.addLine(to: CGPoint(x: plot.maxX, y: y))
                label(Self.format(value), at: CGPoint(x: plot.minX - 3, y: y - 5), alignment: .right, width: 26)
            }
            // Drawing a label leaves its own colour set, so the line's is set each time.
            PlatformColor(white: 0.85, alpha: 1).setStroke()
            path.lineWidth = 0.5
            path.stroke()
            value += step
        }
        let band = (horizontal ? plot.height : plot.width) / CGFloat(count)
        for index in 0..<count where index < chart.categories.count {
            if horizontal {
                label(chart.categories[index], at: CGPoint(x: plot.minX - 3, y: plot.minY + band * (CGFloat(index) + 0.5) - 5),
                      alignment: .right, width: 46)
            } else {
                label(chart.categories[index], at: CGPoint(x: plot.minX + band * (CGFloat(index) + 0.5), y: plot.maxY + 3),
                      width: band)
            }
        }
        func position(_ value: Double) -> CGFloat { CGFloat(value / top) }
        // Columns first, then areas and lines over them, as a combined chart draws them.
        let columns = chart.series.indices.filter { kind(of: $0) == .column || kind(of: $0) == .bar }
        if !columns.isEmpty {
            let seriesCount = CGFloat(chart.isStacked ? 1 : columns.count)
            let barWidth = band * 0.7 / max(1, seriesCount)
            var stacks = Array(repeating: 0.0, count: count)
            for (order, seriesIndex) in columns.enumerated() {
                let series = chart.series[seriesIndex]
                seriesColor(seriesIndex).setFill()
                for (index, value) in series.values.enumerated() where index < count {
                    let base = chart.isStacked ? stacks[index] : 0
                    let offset = chart.isStacked ? 0 : CGFloat(order) * barWidth
                    let start = band * CGFloat(index) + band * 0.15 + offset
                    let rect = horizontal
                        ? CGRect(x: plot.minX + plot.width * position(base), y: plot.minY + start,
                                 width: plot.width * position(max(0, value)), height: barWidth)
                        : CGRect(x: plot.minX + start, y: plot.maxY - plot.height * position(base + max(0, value)),
                                 width: barWidth, height: plot.height * position(max(0, value)))
                    PlatformGraphics.fill(rect)
                    stacks[index] += max(0, value)
                }
            }
        }
        let others = chart.series.indices.filter { !columns.contains($0) }.sorted { kind(of: $0) == .area && kind(of: $1) != .area }
        for seriesIndex in others {
            let series = chart.series[seriesIndex]
            let kind = kind(of: seriesIndex)
            let points = series.values.enumerated().map { index, value in
                CGPoint(x: plot.minX + band * (CGFloat(index) + 0.5), y: plot.maxY - plot.height * position(value))
            }
            guard let first = points.first else { continue }
            let path = PlatformBezierPath()
            path.move(to: first)
            points.dropFirst().forEach(path.addLine)
            let color = seriesColor(seriesIndex)
            if kind == .area, let last = points.last {
                path.addLine(to: CGPoint(x: last.x, y: plot.maxY))
                path.addLine(to: CGPoint(x: first.x, y: plot.maxY))
                path.close()
                color.withAlphaComponent(0.65).setFill()
                path.fill()
            } else if kind == .line {
                color.setStroke()
                path.lineWidth = 2
                path.stroke()
            }
            color.setFill()
            for point in points where kind != .area {
                PlatformBezierPath(ovalIn: CGRect(x: point.x - 2.5, y: point.y - 2.5, width: 5, height: 5)).fill()
            }
        }
        PlatformColor.gray.setStroke()
        let axis = PlatformBezierPath()
        axis.move(to: CGPoint(x: plot.minX, y: plot.minY))
        axis.addLine(to: CGPoint(x: plot.minX, y: plot.maxY))
        axis.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
        axis.lineWidth = 0.75
        axis.stroke()
    }

    private static func format(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)))
    }
}
#endif

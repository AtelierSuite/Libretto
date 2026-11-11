#if canImport(UIKit) || canImport(AppKit)
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
import CoreText

/// Lays out and draws Office Math (OMML): fractions, scripts, radicals,
/// big operators, delimiters, functions, accents, bars, limits, matrices and
/// equation arrays, each a box with a width, an ascent and a descent.
public enum MathRenderer: Sendable {
    public static let namespace = LinearMath.namespace

    nonisolated(unsafe) private static let equationPattern = #/^<(?:[\w.\-]+:)?oMath(?:Para)?\b/#

    nonisolated(unsafe) private static let displayPattern = #/^<(?:[\w.\-]+:)?oMathPara\b/#

    /// How a paragraph's display equation lines up, if it holds one: as its `m:jc` says, centred by default.
    public static func displayAlignment(of kept: [String]) -> NSTextAlignment? {
        guard let xml = kept.first(where: { $0.firstMatch(of: displayPattern) != nil }) else { return nil }
        switch element(xml)?.firstChild(named: "oMathParaPr")?.firstChild(named: "jc")?.attribute("val") {
        case "left": return .left
        case "right": return .right
        default: return .center
        }
    }

    /// Whether a kept element is an equation.
    public static func isEquation(_ xml: String) -> Bool { xml.firstMatch(of: equationPattern) != nil }

    /// Whether an OMML on-off property is on: present without a value means on.
    static func isOn(_ value: String?, default fallback: Bool) -> Bool {
        guard let value else { return fallback }
        return !["0", "off", "false"].contains(value)
    }

    /// A string's glyph outlines, from its baseline's left end with y going up.
    static func glyphPath(_ string: String, font: PlatformFont) -> CGPath {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [.font: font]))
        let path = CGMutablePath()
        for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
            let attributes = CTRunGetAttributes(run) as NSDictionary
            guard let value = attributes[kCTFontAttributeName], CFGetTypeID(value as CFTypeRef) == CTFontGetTypeID() else { continue }
            let runFont = value as! CTFont
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
            for index in 0..<count {
                guard let glyph = CTFontCreatePathForGlyph(runFont, glyphs[index], nil) else { continue }
                path.addPath(glyph, transform: CGAffineTransform(translationX: positions[index].x, y: positions[index].y))
            }
        }
        return path
    }

    /// Fills a path in the current context.
    static func fill(_ path: CGPath, color: PlatformColor) {
        #if canImport(UIKit)
        guard let context = UIGraphicsGetCurrentContext() else { return }
        #else
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        #endif
        context.saveGState()
        context.addPath(path)
        context.setFillColor(color.cgColor)
        context.fillPath()
        context.restoreGState()
    }

    private static func element(_ xml: String) -> XMLElement? {
        var namespaces = DOCXPatcher.namespaceBindings(for: xml)
        namespaces["m"] = namespace
        return XMLLite.fragment(xml, namespaces: namespaces)
    }

    /// An equation drawn: the picture, and how far it reaches below the baseline.
    public static func image(forXML xml: String, fontSize: CGFloat, color: PlatformColor) -> (image: PlatformImage, descent: CGFloat)? {
        guard let element = element(xml) else { return nil }
        let box = Layout(size: fontSize, color: color).box(element)
        let pad: CGFloat = 1
        let size = CGSize(width: ceil(box.width) + pad * 2, height: ceil(box.ascent + box.descent) + pad * 2)
        let image = PlatformImage.drawn(size: size) { _ in
            box.draw(CGPoint(x: pad, y: pad + box.ascent))
        }
        return (image, box.descent + pad)
    }

    /// Something laid out: drawn with its baseline's left end at a point.
    public struct Box {
        public var width: CGFloat
        public var ascent: CGFloat
        public var descent: CGFloat
        public var draw: (CGPoint) -> Void

        public static var empty: Box { Box(width: 0, ascent: 0, descent: 0) { _ in } }

        public static func space(_ width: CGFloat) -> Box { Box(width: width, ascent: 0, descent: 0) { _ in } }

        /// Boxes side by side on one baseline.
        public static func row(_ boxes: [Box]) -> Box {
            guard !boxes.isEmpty else { return .empty }
            return Box(
                width: boxes.reduce(0) { $0 + $1.width }, ascent: boxes.map(\.ascent).max() ?? 0,
                descent: boxes.map(\.descent).max() ?? 0
            ) { origin in
                var x = origin.x
                for box in boxes {
                    box.draw(CGPoint(x: x, y: origin.y))
                    x += box.width
                }
            }
        }

        public init(width: CGFloat, ascent: CGFloat, descent: CGFloat, draw: @escaping (CGPoint) -> Void) {
            self.width = width
            self.ascent = ascent
            self.descent = descent
            self.draw = draw
        }
    }

    /// Lays out at one size: scripts and limits shrink as they nest.
    public struct Layout: Sendable {
        public var size: CGFloat
        public var color: PlatformColor

        private var smaller: Layout { Layout(size: max(5, size * 0.7), color: color) }
        /// Where fraction bars and minus signs sit above the baseline.
        private var axis: CGFloat { size * 0.27 }

        private func font(italic: Bool) -> PlatformFont {
            let names = italic ? ["STIXTwoMath-Italic", "TimesNewRomanPS-ItalicMT", "Georgia-Italic"]
                : ["STIXTwoMath-Regular", "TimesNewRomanPSMT", "Georgia"]
            for name in names { if let font = PlatformFont(name: name, size: size) { return font } }
            return italic ? PlatformFont.italicSystemFont(ofSize: size) : PlatformFont.systemFont(ofSize: size)
        }

        public func text(_ string: String, italic: Bool = false) -> Box {
            let font = self.font(italic: italic)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let width = (string as NSString).size(withAttributes: attributes).width
            // How far the ink reaches, as Word measures it: accents, bars and fraction parts sit close.
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
            let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
            let ascent = ink.isNull ? 0 : max(0, ink.maxY)
            let descent = ink.isNull ? 0 : max(0, -ink.minY)
            return Box(width: width, ascent: ascent, descent: descent) { origin in
                (string as NSString).draw(at: CGPoint(x: origin.x, y: origin.y - font.ascender), withAttributes: attributes)
            }
        }

        private static let operators: Set<Character> = ["+", "−", "-", "=", "<", ">", "±", "∓", "×", "÷", "≤", "≥", "≠", "≈",
                                                         "≡", "→", "←", "⇒", "⇔", "∈", "∉", "⊂", "⊃", "∪", "∩", "·", "∝"]

        /// A run's text: letters in italic unless the run says plain, operators spaced out.
        private static let signs: Set<Character> = ["+", "−", "-", "±", "∓"]
        /// What, coming before a sign, makes it a sign of what follows rather than an operator between two things.
        private static let openings: Set<Character> = ["(", "[", "{", "⟨", ",", ";"]

        /// Whether a sign coming after this text stands for the sign of what follows.
        private static func leavesSignUnary(_ text: String, before: Bool) -> Bool {
            guard let last = text.last(where: { !$0.isWhitespace }) else { return before }
            return operators.contains(last) || openings.contains(last)
        }

        /// - Parameter unary: whether a sign at its start begins its line or follows an operator, so stands as
        ///   the sign of what follows (`−b`, `=−1`), set close to it as Word does rather than spaced out.
        private func run(_ element: XMLElement, text content: String? = nil, unary: Bool = false) -> Box {
            let content = content ?? Self.runText(element)
            let plain = element.firstChild(named: "rPr")?.firstChild(named: "sty")?.attribute("val") == "p"
            var boxes: [Box] = []
            var pending = ""
            var pendingItalic = false
            func flush() {
                if !pending.isEmpty { boxes.append(text(pending, italic: pendingItalic)) }
                pending = ""
            }
            var unary = unary
            for character in content {
                if Self.operators.contains(character) {
                    flush()
                    let symbol = character == "-" ? "−" : String(character)
                    if unary && Self.signs.contains(character) {
                        boxes.append(text(symbol))
                    } else {
                        boxes += [.space(size * 0.22), text(symbol), .space(size * 0.22)]
                    }
                    unary = true
                    continue
                }
                unary = Self.openings.contains(character) || (unary && character.isWhitespace)
                let italic = !plain && character.isLetter
                if italic != pendingItalic { flush() }
                pendingItalic = italic
                pending.append(character)
            }
            flush()
            return .row(boxes)
        }

        private static func runText(_ element: XMLElement) -> String { element.children(named: "t").map(\.text).joined() }

        /// An element's children, side by side, their properties left out.
        public func row(_ element: XMLElement?) -> Box {
            guard let element else { return .empty }
            var unary = true
            var boxes: [Box] = []
            for child in element.children where !child.name.hasSuffix("Pr") {
                guard child.name == "r" else {
                    boxes.append(box(child))
                    unary = false
                    continue
                }
                boxes.append(run(child, unary: unary))
                unary = Self.leavesSignUnary(Self.runText(child), before: unary)
            }
            return .row(boxes)
        }

        private func property(_ element: XMLElement, _ properties: String, _ name: String) -> String? {
            element.firstChild(named: properties)?.firstChild(named: name)?.attribute("val")
        }

        public func box(_ element: XMLElement) -> Box {
            switch element.name {
            case "oMathPara":
                let lines = element.children(named: "oMath").map(box)
                return stack(lines, centered: true)
            case "oMath", "e", "num", "den", "sup", "sub", "deg", "fName", "lim":
                return row(element)
            case "r":
                return run(element)
            case "f":
                return fraction(element)
            case "sSup", "sSub", "sSubSup":
                return scripts(base: row(element.firstChild(named: "e")), sub: element.firstChild(named: "sub"),
                               sup: element.firstChild(named: "sup"))
            case "sPre":
                return scripts(base: row(element.firstChild(named: "e")), sub: element.firstChild(named: "sub"),
                               sup: element.firstChild(named: "sup"), before: true)
            case "rad":
                return radical(element)
            case "nary":
                return nary(element)
            case "d":
                return delimited(element)
            case "func":
                return .row([row(element.firstChild(named: "fName")), .space(size * 0.17), row(element.firstChild(named: "e"))])
            case "acc":
                return accent(element)
            case "bar":
                return overline(row(element.firstChild(named: "e")), below: property(element, "barPr", "pos") != "top")
            case "groupChr":
                let character = property(element, "groupChrPr", "chr") ?? "\u{23DF}"
                let below = property(element, "groupChrPr", "pos") != "top"
                let base = row(element.firstChild(named: "e"))
                return limit(base, across(character, width: base.width), below: below, gap: size * 0.15)
            case "limLow", "limUpp":
                return limit(row(element.firstChild(named: "e")), smaller.row(element.firstChild(named: "lim")), below: element.name == "limLow")
            case "m":
                return matrix(element)
            case "eqArr":
                return equationArray(element)
            case "borderBox":
                let inner = row(element.firstChild(named: "e"))
                let pad = max(2, size * 0.15)
                return Box(width: inner.width + pad * 2, ascent: inner.ascent + pad, descent: inner.descent + pad) { origin in
                    inner.draw(CGPoint(x: origin.x + pad, y: origin.y))
                    color.setStroke()
                    PlatformBezierPath(rect: CGRect(x: origin.x + 0.5, y: origin.y - inner.ascent - pad + 0.5, width: inner.width + pad * 2 - 1,
                                              height: inner.ascent + inner.descent + pad * 2 - 1)).stroke()
                }
            case "phant":
                // Shown unless it says not to; taking its room unless told to take none across, above or below.
                let inner = row(element.firstChild(named: "e"))
                func on(_ name: String, _ fallback: Bool) -> Bool { MathRenderer.isOn(
                    element.firstChild(named: "phantPr")?.firstChild(named: name).map { $0.attribute("val") ?? "1" }, default: fallback) }
                let shown = on("show", true)
                return Box(
                    width: on("zeroWid", false) ? 0 : inner.width, ascent: on("zeroAsc", false) ? 0 : inner.ascent,
                    descent: on("zeroDesc", false) ? 0 : inner.descent
                ) { origin in if shown { inner.draw(origin) } }
            default:
                return element.name.hasSuffix("Pr") ? .empty : row(element)
            }
        }

        // MARK: Pieces

        /// A line of a matrix or of lines one above another: at least as tall as a line of text, so rows space evenly.
        private func strut(_ box: Box) -> Box {
            Box(width: box.width, ascent: max(box.ascent, size * 0.72), descent: max(box.descent, size * 0.24), draw: box.draw)
        }

        private func fraction(_ element: XMLElement) -> Box {
            let type = property(element, "fPr", "type")
            let inner = Layout(size: size * 0.9, color: color)
            let numerator = inner.row(element.firstChild(named: "num"))
            let denominator = inner.row(element.firstChild(named: "den"))
            if type == "lin" {
                return .row([numerator, text("/"), denominator])
            }
            if type == "skw" {
                return skewed(element)
            }
            let gap = size * 0.18
            let width = max(numerator.width, denominator.width) + size * 0.3
            let axis = self.axis
            return Box(
                width: width, ascent: axis + gap + numerator.descent + numerator.ascent,
                descent: denominator.ascent + gap + denominator.descent - axis
            ) { origin in
                numerator.draw(CGPoint(x: origin.x + (width - numerator.width) / 2, y: origin.y - axis - gap - numerator.descent))
                denominator.draw(CGPoint(x: origin.x + (width - denominator.width) / 2, y: origin.y - axis + gap + denominator.ascent))
                if type != "noBar" {
                    color.setFill()
                    PlatformGraphics.fill(CGRect(x: origin.x + 1, y: origin.y - axis - 0.4, width: width - 2, height: 0.8))
                }
            }
        }

        /// - Parameter before: whether the scripts come before the base, as in ¹⁴₆C: set flush right against it, as Word does.
        /// A skewed fraction, as Word draws it: the numerator raised and the denominator lowered, either side of a
        /// tall slash.
        private func skewed(_ element: XMLElement) -> Box {
            let inner = Layout(size: size * 0.8, color: color)
            let numerator = inner.row(element.firstChild(named: "num"))
            let denominator = inner.row(element.firstChild(named: "den"))
            let slash = Layout(size: size * 1.15, color: color).text("/")
            let raise = axis + size * 0.08 + numerator.descent
            let lower = max(0, denominator.ascent - axis + size * 0.08)
            let kern = size * 0.08
            let width = numerator.width + slash.width + denominator.width - kern * 2
            let shift = axis - (slash.ascent - slash.descent) / 2
            return Box(
                width: width, ascent: max(raise + numerator.ascent, slash.ascent + shift),
                descent: max(lower + denominator.descent, slash.descent - shift)
            ) { origin in
                numerator.draw(CGPoint(x: origin.x, y: origin.y - raise))
                slash.draw(CGPoint(x: origin.x + numerator.width - kern, y: origin.y - shift))
                denominator.draw(CGPoint(x: origin.x + numerator.width + slash.width - kern * 2, y: origin.y + lower))
            }
        }

        private func scripts(base: Box, sub: XMLElement?, sup: XMLElement?, before: Bool = false) -> Box {
            let raised = sup.map { smaller.row($0) }
            let lowered = sub.map { smaller.row($0) }
            let raise = max(size * 0.42, base.ascent - (raised?.ascent ?? 0) * 0.5)
            let lower = max(size * 0.2, base.descent)
            let scriptsWidth = max(raised?.width ?? 0, lowered?.width ?? 0)
            return Box(
                width: base.width + scriptsWidth + 1,
                ascent: max(base.ascent, raise + (raised?.ascent ?? 0)),
                descent: max(base.descent, lower + (lowered?.descent ?? 0))
            ) { origin in
                if before {
                    raised.map { $0.draw(CGPoint(x: origin.x + scriptsWidth - $0.width, y: origin.y - raise)) }
                    lowered.map { $0.draw(CGPoint(x: origin.x + scriptsWidth - $0.width, y: origin.y + lower)) }
                    base.draw(CGPoint(x: origin.x + scriptsWidth + 1, y: origin.y))
                    return
                }
                base.draw(origin)
                raised?.draw(CGPoint(x: origin.x + base.width + 1, y: origin.y - raise))
                lowered?.draw(CGPoint(x: origin.x + base.width + 1, y: origin.y + lower))
            }
        }

        private func radical(_ element: XMLElement) -> Box {
            let inner = row(element.firstChild(named: "e"))
            let hidesDegree = property(element, "radPr", "degHide") == "1" || property(element, "radPr", "degHide") == "on"
            let degree = hidesDegree ? nil : element.firstChild(named: "deg").map { smaller.row($0) }
            let gap = size * 0.12
            let sign = size * 0.55
            let lead = max(sign, (degree?.width ?? 0) + sign * 0.4)
            let height = inner.ascent + inner.descent + gap * 2
            return Box(width: lead + inner.width + 2, ascent: inner.ascent + gap * 2, descent: inner.descent) { origin in
                let top = origin.y - inner.ascent - gap * 1.5
                let bottom = origin.y + inner.descent
                let path = PlatformBezierPath()
                path.move(to: CGPoint(x: origin.x + lead - sign, y: bottom - height * 0.35))
                path.addLine(to: CGPoint(x: origin.x + lead - sign * 0.7, y: bottom - height * 0.42))
                path.addLine(to: CGPoint(x: origin.x + lead - sign * 0.4, y: bottom))
                path.addLine(to: CGPoint(x: origin.x + lead - 1, y: top))
                path.addLine(to: CGPoint(x: origin.x + lead + inner.width + 2, y: top))
                path.lineWidth = max(0.8, size * 0.06)
                color.setStroke()
                path.stroke()
                degree?.draw(CGPoint(x: origin.x, y: bottom - height * 0.5))
                inner.draw(CGPoint(x: origin.x + lead + 1, y: origin.y))
            }
        }

        private func nary(_ element: XMLElement) -> Box {
            let character = property(element, "naryPr", "chr") ?? "\u{222B}"
            let isIntegral = ("\u{222B}"..."\u{2233}").contains(character) || character == "\u{2A0C}"
            let underOver = (property(element, "naryPr", "limLoc") ?? (isIntegral ? "subSup" : "undOvr")) == "undOvr"
            let symbol = Layout(size: size * 1.4, color: color).text(character)
            func hidden(_ name: String) -> Bool { MathRenderer.isOn(
                element.firstChild(named: "naryPr")?.firstChild(named: name).map { $0.attribute("val") ?? "1" }, default: false) }
            let lower = hidden("subHide") ? .empty : element.firstChild(named: "sub").map { smaller.row($0) } ?? .empty
            let upper = hidden("supHide") ? .empty : element.firstChild(named: "sup").map { smaller.row($0) } ?? .empty
            let body = row(element.firstChild(named: "e"))
            let operatorBox: Box
            if underOver {
                operatorBox = limit(limit(symbol, lower, below: true, gap: size * 0.12), upper, below: false, gap: size * 0.12)
            } else {
                let raise = symbol.ascent * 0.7
                let drop = symbol.descent + lower.ascent * 0.5
                // An integral's lower limit tucks in under its slant; any other operator's sits clear of it.
                let lowerX = isIntegral ? symbol.width * 0.7 : symbol.width + 1
                operatorBox = Box(
                    width: max(symbol.width + 1 + upper.width, lowerX + lower.width),
                    ascent: max(symbol.ascent, raise + upper.ascent), descent: max(symbol.descent, drop + lower.descent)
                ) { origin in
                    symbol.draw(origin)
                    upper.draw(CGPoint(x: origin.x + symbol.width + 1, y: origin.y - raise))
                    lower.draw(CGPoint(x: origin.x + lowerX, y: origin.y + drop))
                }
            }
            return .row([operatorBox, .space(size * 0.17), body])
        }

        private func delimited(_ element: XMLElement) -> Box {
            let open = property(element, "dPr", "begChr") ?? "("
            let close = property(element, "dPr", "endChr") ?? ")"
            let separator = property(element, "dPr", "sepChr") ?? "|"
            let grows = MathRenderer.isOn(property(element, "dPr", "grow"), default: true)
            let items = element.children(named: "e").map(row)
            let content = Box.row(items)
            // As Word does: centred on the math axis, reaching as far above it as below, to cover what they hold.
            let reach = max(content.ascent - axis, content.descent + axis) + size * 0.08
            func fence(_ character: String) -> Box {
                guard !character.isEmpty else { return .empty }
                return grows ? stretched(character, height: reach * 2) : text(character)
            }
            var parts: [Box] = [fence(open)]
            for (index, item) in items.enumerated() {
                if index > 0 { parts.append(fence(separator)) }
                parts.append(item)
            }
            parts.append(fence(close))
            return .row(parts)
        }

        /// A delimiter drawn at least a height tall, centred on the axis: taller ones are drawn stretched
        /// upright, so their strokes stay as thin as the text's, as Word's grown delimiters are.
        private func stretched(_ character: String, height: CGFloat) -> Box {
            let natural = text(character)
            let font = self.font(italic: false)
            let glyph = MathRenderer.glyphPath(character, font: font).boundingBoxOfPath
            guard !glyph.isNull, glyph.height > 0, height > glyph.height * 1.05 else { return natural }
            // Brackets and bars built from strokes, so their ends stay as thin as their stems.
            let path = bracketPath(character, height: height) ?? MathRenderer.glyphPath(character, font: font)
            let bounds = path.boundingBoxOfPath
            let scaleY = height / bounds.height
            let scaleX = min(1.6, 1 + (scaleY - 1) * 0.12)
            let side = size * 0.06
            let axis = self.axis
            let color = self.color
            let inkWidth = bounds.width * scaleX
            return Box(width: inkWidth + side * 2, ascent: axis + height / 2, descent: height / 2 - axis) { origin in
                // From glyph space (y up from the baseline) to the page (y down).
                var transform = CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY)
                    .concatenating(CGAffineTransform(scaleX: scaleX, y: scaleY))
                    .concatenating(CGAffineTransform(translationX: side, y: axis - height / 2))
                    .concatenating(CGAffineTransform(scaleX: 1, y: -1))
                    .concatenating(CGAffineTransform(translationX: origin.x, y: origin.y))
                guard let placed = path.copy(using: &transform) else { return }
                MathRenderer.fill(placed, color: color)
            }
        }

        /// A brace, bracket or arrow set over or under something, stretched across it as Word does.
        private func across(_ character: String, width: CGFloat) -> Box {
            let path = MathRenderer.glyphPath(character, font: font(italic: false))
            let bounds = path.boundingBoxOfPath
            guard !bounds.isNull, bounds.width > 0, width > bounds.width * 1.05 else { return text(character) }
            let scaleX = width / bounds.width
            let scaleY = min(1.2, 1 + (scaleX - 1) * 0.03)
            let height = bounds.height * scaleY
            let color = self.color
            return Box(width: width, ascent: height, descent: 0) { origin in
                var transform = CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY)
                    .concatenating(CGAffineTransform(scaleX: scaleX, y: scaleY))
                    .concatenating(CGAffineTransform(scaleX: 1, y: -1))
                    .concatenating(CGAffineTransform(translationX: origin.x, y: origin.y))
                guard let placed = path.copy(using: &transform) else { return }
                MathRenderer.fill(placed, color: color)
            }
        }

        /// Square brackets and bars as rectangles, in glyph space, a height tall.
        private func bracketPath(_ character: String, height: CGFloat) -> CGPath? {
            let stem = max(0.6, size * 0.07)
            let arm = size * 0.22
            let path = CGMutablePath()
            switch character {
            case "[", "⌈", "⌊":
                path.addRect(CGRect(x: 0, y: 0, width: stem, height: height))
                if character != "⌊" { path.addRect(CGRect(x: 0, y: height - stem, width: arm, height: stem)) }
                if character != "⌈" { path.addRect(CGRect(x: 0, y: 0, width: arm, height: stem)) }
            case "]", "⌉", "⌋":
                path.addRect(CGRect(x: arm - stem, y: 0, width: stem, height: height))
                if character != "⌋" { path.addRect(CGRect(x: 0, y: height - stem, width: arm, height: stem)) }
                if character != "⌉" { path.addRect(CGRect(x: 0, y: 0, width: arm, height: stem)) }
            case "|":
                path.addRect(CGRect(x: 0, y: 0, width: stem, height: height))
            case "‖":
                path.addRect(CGRect(x: 0, y: 0, width: stem, height: height))
                path.addRect(CGRect(x: stem * 3, y: 0, width: stem, height: height))
            default:
                return nil
            }
            return path
        }

        private func accent(_ element: XMLElement) -> Box {
            let mark = property(element, "accPr", "chr") ?? "\u{0302}"
            let inner = row(element.firstChild(named: "e"))
            let spacing: [String: String] = [
                "\u{0302}": "^", "\u{0303}": "~", "\u{0307}": "˙", "\u{0308}": "¨", "\u{0301}": "´", "\u{0300}": "`",
                "\u{20D7}": "→", "\u{2192}": "→", "\u{030C}": "ˇ", "\u{0306}": "˘",
            ]
            if mark == "\u{0305}" || mark == "\u{0304}" || mark == "\u{00AF}" { return overline(inner, below: false) }
            let symbol = smaller.text(spacing[mark] ?? mark)
            return limit(inner, symbol, below: false)
        }

        private func overline(_ inner: Box, below: Bool) -> Box {
            let gap = size * 0.1
            return Box(width: inner.width, ascent: inner.ascent + (below ? 0 : gap * 2), descent: inner.descent + (below ? gap * 2 : 0)) { origin in
                inner.draw(origin)
                color.setFill()
                let y = below ? origin.y + inner.descent + gap : origin.y - inner.ascent - gap
                PlatformGraphics.fill(CGRect(x: origin.x, y: y - 0.35, width: inner.width, height: 0.7))
            }
        }

        /// Something set centred above or below another.
        private func limit(_ base: Box, _ attached: Box, below: Bool, gap: CGFloat? = nil) -> Box {
            let width = max(base.width, attached.width)
            let gap = gap ?? size * 0.08
            return Box(
                width: width,
                ascent: below ? base.ascent : base.ascent + gap + attached.ascent + attached.descent,
                descent: below ? base.descent + gap + attached.ascent + attached.descent : base.descent
            ) { origin in
                base.draw(CGPoint(x: origin.x + (width - base.width) / 2, y: origin.y))
                let y = below ? origin.y + base.descent + gap + attached.ascent : origin.y - base.ascent - gap - attached.descent
                attached.draw(CGPoint(x: origin.x + (width - attached.width) / 2, y: y))
            }
        }

        private func matrix(_ element: XMLElement) -> Box {
            let rows = element.children(named: "mr").map { $0.children(named: "e").map { strut(row($0)) } }
            let columns = rows.map(\.count).max() ?? 0
            let widths = (0..<columns).map { column in rows.compactMap { $0.indices.contains(column) ? $0[column].width : nil }.max() ?? 0 }
            let gap = size * 0.6
            let heights = rows.map { cells in (cells.map(\.ascent).max() ?? 0, cells.map(\.descent).max() ?? 0) }
            let total = heights.reduce(0) { $0 + $1.0 + $1.1 } + CGFloat(max(0, rows.count - 1)) * size * 0.2
            let width = widths.reduce(0, +) + gap * CGFloat(max(0, columns - 1))
            let axis = self.axis
            return Box(width: width, ascent: total / 2 + axis, descent: total / 2 - axis) { origin in
                var y = origin.y - total / 2 - axis
                for (index, cells) in rows.enumerated() {
                    y += heights[index].0
                    var x = origin.x
                    for (column, cell) in cells.enumerated() {
                        cell.draw(CGPoint(x: x + (widths[column] - cell.width) / 2, y: y))
                        x += widths[column] + gap
                    }
                    y += heights[index].1 + size * 0.2
                }
            }
        }

        /// An equation array's line, cut where it aligns: at each `&` in its text, and before each run marked `aln`.
        private func alignedPieces(_ element: XMLElement) -> [Box] {
            var pieces: [[Box]] = [[]]
            for child in element.children where !child.name.hasSuffix("Pr") {
                guard child.name == "r" else {
                    pieces[pieces.count - 1].append(box(child))
                    continue
                }
                if child.firstChild(named: "rPr")?.firstChild(named: "aln") != nil { pieces.append([]) }
                for (index, part) in Self.runText(child).split(separator: "&", omittingEmptySubsequences: false).enumerated() {
                    if index > 0 { pieces.append([]) }
                    if !part.isEmpty {
                        pieces[pieces.count - 1].append(run(child, text: String(part), unary: pieces[pieces.count - 1].isEmpty))
                    }
                }
            }
            return pieces.map(Box.row)
        }

        /// Lines one above another, as Word sets them: lined up at their alignment points (pieces between them
        /// right- then left-aligned, by turns), lines with none centred, the whole centred on the math axis
        /// unless its base is the top or bottom line.
        private func equationArray(_ element: XMLElement) -> Box {
            let lines = element.children(named: "e").map(alignedPieces)
            let columns = lines.map(\.count).max() ?? 0
            guard columns > 0 else { return .empty }
            let widths = (0..<columns).map { column in
                lines.compactMap { $0.indices.contains(column) ? $0[column].width : nil }.max() ?? 0
            }
            let width = widths.reduce(0, +)
            let rows: [Box] = lines.map { pieces in
                let row = strut(.row(pieces))
                return Box(width: width, ascent: row.ascent, descent: row.descent) { origin in
                    if columns == 1 {
                        pieces[0].draw(CGPoint(x: origin.x + (width - pieces[0].width) / 2, y: origin.y))
                        return
                    }
                    var x = origin.x
                    for (column, piece) in pieces.enumerated() {
                        let left = column.isMultiple(of: 2) ? widths[column] - piece.width : 0
                        piece.draw(CGPoint(x: x + left, y: origin.y))
                        x += widths[column]
                    }
                }
            }
            let leading = size * 0.2
            let total = rows.reduce(0) { $0 + $1.ascent + $1.descent } + leading * CGFloat(rows.count - 1)
            // Where the array's own baseline falls, measured down from its top.
            let baseline: CGFloat
            switch property(element, "eqArrPr", "baseJc") {
            case "top": baseline = rows[0].ascent
            case "bot", "bottom": baseline = total - rows[rows.count - 1].descent
            default: baseline = total / 2 + axis
            }
            return Box(width: width, ascent: baseline, descent: total - baseline) { origin in
                var y = origin.y - baseline
                for row in rows {
                    y += row.ascent
                    row.draw(CGPoint(x: origin.x, y: y))
                    y += row.descent + leading
                }
            }
        }

        /// Lines one above another, the first on the baseline.
        private func stack(_ lines: [Box], centered: Bool) -> Box {
            let lines = lines.map(strut)
            guard let first = lines.first else { return .empty }
            let width = lines.map(\.width).max() ?? 0
            let leading = size * 0.3
            let rest = lines.dropFirst().reduce(0) { $0 + $1.ascent + $1.descent + leading }
            return Box(width: width, ascent: first.ascent, descent: first.descent + rest) { origin in
                var y = origin.y
                for (index, line) in lines.enumerated() {
                    if index > 0 { y += lines[index - 1].descent + leading + line.ascent }
                    line.draw(CGPoint(x: origin.x + (centered ? (width - line.width) / 2 : 0), y: y))
                }
            }
        }

        public init(size: CGFloat, color: PlatformColor) {
            self.size = size
            self.color = color
        }
    }
}
#endif

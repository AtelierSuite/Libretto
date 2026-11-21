import Foundation
import Testing
import UIKit
@testable import Libretto
@testable import LibrettoEngine

@MainActor
@Suite("Equations")
struct EquationTests {
    @Test("A line of math reads into Office Math, and back")
    func linear() throws {
        let omml = LinearMath.omml("x^2 + y_1 = sqrt(a/b)")
        #expect(omml == "<m:oMath><m:sSup><m:e><m:r><m:t>x</m:t></m:r></m:e><m:sup><m:r><m:t>2</m:t></m:r></m:sup></m:sSup>"
            + "<m:r><m:t>+</m:t></m:r><m:sSub><m:e><m:r><m:t>y</m:t></m:r></m:e><m:sub><m:r><m:t>1</m:t></m:r></m:sub></m:sSub>"
            + "<m:r><m:t>=</m:t></m:r><m:rad><m:radPr><m:degHide m:val=\"1\"/></m:radPr><m:deg/><m:e><m:f><m:num><m:r><m:t>a</m:t></m:r></m:num>"
            + "<m:den><m:r><m:t>b</m:t></m:r></m:den></m:f></m:e></m:rad></m:oMath>")
        #expect(LinearMath.linear(fromXML: omml) == "x^2+y_1=sqrt(a/b)")
        #expect(LinearMath.omml("sum_(i=1)^n i").contains("<m:chr m:val=\"∑\"/>"))
        #expect(LinearMath.omml("\\alpha").contains("<m:t>α</m:t>"))
        #expect(MathRenderer.image(forXML: omml, fontSize: 12, color: .black).map { $0.image.size.width > 30 } == true)
    }

    @Test("An equation goes in as a drawing in its line, and is written as Office Math")
    func inserts() throws {
        var document = WordDocument()
        document.body = [.paragraph(Paragraph(text: "Area: "))]
        let controller = DocumentTextController(document: document, scheme: .light)
        let state = EditorState()
        controller.state = state
        state.controller = controller
        var latest: WordDocument?
        controller.onChange = { latest = $0 }
        controller.textView.selectedRange = NSRange(location: 6, length: 0)
        controller.insertEquation("\\pi r^2")
        #expect(controller.textView.textStorage.attribute(.attachment, at: 6, effectiveRange: nil) != nil)
        controller.textView.selectedRange = NSRange(location: 7, length: 0)
        #expect(state.isOnEquation)

        let saved = try #require(latest)
        let xml = Fixtures.text(try Fixtures.written(saved), "word/document.xml")
        #expect(xml.contains("xmlns:m=\"\(MathRenderer.namespace)\""))
        #expect(xml.contains("<m:oMath><m:r><m:t>π</m:t></m:r><m:sSup>"))
        let reread = try DOCXReader.document(fromParts: try Fixtures.written(saved))
        #expect(reread.unsupportedFeatures.isEmpty)
        guard case .paragraphChild(let kept, _)? = reread.allParagraphs.first?.inlines.last?.content else {
            Issue.record("the equation went missing")
            return
        }
        #expect(MathRenderer.isEquation(kept))

        // Edited in place.
        controller.insertEquation("\\pi r^3")
        #expect(Fixtures.text(try Fixtures.written(try #require(latest)), "word/document.xml").contains("<m:t>3</m:t>"))
    }

    // MARK: Laid out as Word lays them out

    private static let m = "xmlns:m=\"\(MathRenderer.namespace)\""
    private static let size: CGFloat = 20
    private static var axis: CGFloat { size * 0.27 }

    private func box(_ omml: String) throws -> MathRenderer.Box {
        let xml = omml.replacingOccurrences(of: "<m:oMath>", with: "<m:oMath \(Self.m)>", options: .anchored)
        return try #require(MathRenderer.box(forXML: xml, fontSize: Self.size, color: .black))
    }

    private func r(_ text: String) -> String { "<m:r><m:t>\(text)</m:t></m:r>" }
    private func fraction(_ type: String? = nil) -> String {
        let properties = type.map { "<m:fPr><m:type m:val=\"\($0)\"/></m:fPr>" } ?? ""
        return "<m:f>\(properties)<m:num>\(r("a"))</m:num><m:den>\(r("b"))</m:den></m:f>"
    }

    @Test("Every structure in the equation set reads from Word's file and draws")
    func equationSet() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Resources/Equations.docx")
        let document = try DOCXReader.document(from: Data(contentsOf: url))
        let equations = document.allParagraphs.flatMap(\.inlines).compactMap { inline -> String? in
            guard case .paragraphChild(let xml, _) = inline.content, MathRenderer.isEquation(xml) else { return nil }
            return xml
        }
        #expect(equations.count == 33)
        for xml in equations {
            let drawn = MathRenderer.image(forXML: xml, fontSize: 12, color: .black)
            #expect(drawn.map { $0.image.size.width > 5 && $0.image.size.height > 5 } == true, "\(xml)")
        }
        let structures = ["m:f>", "m:type m:val=\"skw\"", "m:type m:val=\"lin\"", "m:type m:val=\"noBar\"", "m:nary>",
                          "m:m>", "m:eqArr>", "m:d>", "m:acc>", "m:bar>", "m:borderBox>", "m:box>", "m:groupChr>",
                          "m:sPre>", "m:phant>", "m:rad>", "m:func>", "m:limLow>", "m:limUpp>", "m:oMathPara>"]
        for structure in structures {
            #expect(equations.contains { $0.contains(structure) }, "no \(structure)")
        }
        // The display equation is centred, whatever its paragraph says.
        let display = try #require(document.allParagraphs.first { paragraph in
            paragraph.inlines.contains { if case .paragraphChild(let xml, _) = $0.content { xml.hasPrefix("<m:oMathPara") } else { false } }
        })
        let context = RenderContext(document: document, scheme: .light, images: ImageStore())
        #expect(DocumentRenderer.paragraphStyle(display, context: context, isListItem: false).alignment == .center)
    }

    @Test("The phone reader draws equations: inline ones in their line, display ones on their own")
    func readerEquations() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Resources/Equations.docx")
        let document = try DOCXReader.document(from: Data(contentsOf: url))
        let equations = document.body.flatMap(\.paragraphs).flatMap(\.inlines).compactMap { inline -> String? in
            guard case .paragraphChild(let xml, _) = inline.content, MathRenderer.isEquation(xml) else { return nil }
            return xml
        }
        let displays = equations.filter { MathRenderer.displayAlignment(of: [$0]) != nil }
        #expect(!displays.isEmpty)

        let items = MobileLayout(document: document, scheme: .light).items
        let inline = items.flatMap { item -> [MobileText.Piece] in
            guard case .paragraph(let paragraph) = item.content else { return [] }
            return paragraph.text.pieces
        }.filter { if case .equation = $0 { true } else { false } }
        let standing = items.filter { $0.id.contains("-equation-") }
        #expect(inline.count == equations.count - displays.count)
        #expect(standing.count == displays.count)
        // The fraction reads as its linear form to VoiceOver, not as its letters run together.
        let labels = inline.compactMap { piece -> String? in if case .equation(_, _, let label) = piece { label } else { nil } }
        #expect(labels.contains { $0.contains("/") })
    }

    @Test("An n-ary operator set to grow is as tall as what it applies to")
    func naryGrows() throws {
        let tall = "<m:f><m:num><m:f><m:num>\(r("a"))</m:num><m:den>\(r("b"))</m:den></m:f></m:num>"
            + "<m:den><m:f><m:num>\(r("c"))</m:num><m:den>\(r("d"))</m:den></m:f></m:den></m:f>"
        func sum(_ body: String, grow: Bool, chr: String = "∑") throws -> MathRenderer.Box {
            let properties = "<m:chr m:val=\"\(chr)\"/><m:limLoc m:val=\"subSup\"/>" + (grow ? "<m:grow m:val=\"1\"/>" : "")
                + "<m:subHide m:val=\"1\"/><m:supHide m:val=\"1\"/>"
            return try box("<m:oMath><m:nary><m:naryPr>\(properties)</m:naryPr><m:sub/><m:sup/><m:e>\(body)</m:e></m:nary></m:oMath>")
        }
        let fraction = try box("<m:oMath>\(tall)</m:oMath>")
        let fixed = try sum(tall, grow: false)
        let grown = try sum(tall, grow: true)
        #expect(grown.width > fixed.width + 1)
        #expect(grown.ascent >= fraction.ascent - 0.5)
        #expect(grown.descent >= fraction.descent - 0.5)
        // A body no taller than the operator leaves it as it is.
        #expect(try sum(r("x"), grow: true).width == (try sum(r("x"), grow: false)).width)
        // An integral grows tall but stays slim.
        let integral = try sum(tall, grow: true, chr: "∫")
        #expect(integral.width < grown.width)
    }

    /// The left and right ends of the ink in the top and bottom halves of an equation's picture.
    private func inkEnds(_ omml: String) throws -> (top: ClosedRange<Int>, bottom: ClosedRange<Int>) {
        let xml = omml.replacingOccurrences(of: "<m:oMath>", with: "<m:oMath \(Self.m)>", options: .anchored)
        let image = try #require(MathRenderer.image(forXML: xml, fontSize: 40, color: .black)?.image.cgImage)
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        func ends(_ rows: Range<Int>) -> ClosedRange<Int> {
            var columns: [Int] = []
            for y in rows { for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 128 { columns.append(x) } }
            return (columns.min() ?? 0)...(columns.max() ?? 0)
        }
        return (ends(0..<height / 2), ends(height / 2..<height))
    }

    @Test("A matrix lines its columns up and spaces its rows and columns as its properties say")
    func matrixProperties() throws {
        func matrix(_ properties: String, _ rows: [[String]]) -> String {
            let cells = rows.map { "<m:mr>" + $0.map { "<m:e>\(r($0))</m:e>" }.joined() + "</m:mr>" }.joined()
            return "<m:oMath><m:m><m:mPr>\(properties)</m:mPr>\(cells)</m:m></m:oMath>"
        }
        let column = [["x"], ["xxxx"]]
        let left = try inkEnds(matrix("<m:mcs><m:mc><m:mcPr><m:count m:val=\"1\"/><m:mcJc m:val=\"left\"/></m:mcPr></m:mc></m:mcs>", column))
        #expect(abs(left.top.lowerBound - left.bottom.lowerBound) <= 3)
        let right = try inkEnds(matrix("<m:mcs><m:mc><m:mcPr><m:count m:val=\"1\"/><m:mcJc m:val=\"right\"/></m:mcPr></m:mc></m:mcs>", column))
        #expect(abs(right.top.upperBound - right.bottom.upperBound) <= 3)
        let centred = try inkEnds(matrix("", column))
        #expect(centred.top.lowerBound - centred.bottom.lowerBound > 10)

        let cells = [["a", "b"], ["c", "d"]]
        let plain = try box(matrix("", cells))
        #expect(try box(matrix("<m:cGpRule m:val=\"2\"/>", cells)).width > plain.width + 1)
        #expect(abs(try box(matrix("<m:cGpRule m:val=\"3\"/><m:cGp m:val=\"1440\"/>", cells)).width - plain.width - (72 - Self.size * 0.6)) < 0.5)
        #expect(try box(matrix("<m:cSp m:val=\"2880\"/>", cells)).width >= 144)
        let doubled = try box(matrix("<m:rSpRule m:val=\"2\"/>", cells))
        #expect(doubled.ascent + doubled.descent > plain.ascent + plain.descent + Self.size)
        let top = try box(matrix("<m:baseJc m:val=\"top\"/>", cells))
        #expect(top.ascent < plain.ascent)
    }

    @Test("An equation array spaces its lines as its row spacing says")
    func equationArrayRowSpacing() throws {
        func array(_ properties: String) throws -> MathRenderer.Box {
            try box("<m:oMath><m:eqArr><m:eqArrPr>\(properties)</m:eqArrPr><m:e>\(r("a=b"))</m:e><m:e>\(r("c=d"))</m:e></m:eqArr></m:oMath>")
        }
        let single = try array("")
        let exact = try array("<m:rSpRule m:val=\"3\"/><m:rSp m:val=\"400\"/>")
        #expect(abs((exact.ascent + exact.descent) - (single.ascent + single.descent) - (20 - Self.size * 0.2)) < 0.5)
    }

    @Test("A display equation is centred unless it says left or right")
    func displayAlignment() {
        #expect(MathRenderer.displayAlignment(of: ["<m:oMathPara \(Self.m)><m:oMath/></m:oMathPara>"]) == .center)
        #expect(MathRenderer.displayAlignment(of: [
            "<m:oMathPara \(Self.m)><m:oMathParaPr><m:jc m:val=\"left\"/></m:oMathParaPr><m:oMath/></m:oMathPara>",
        ]) == .left)
        #expect(MathRenderer.displayAlignment(of: ["<m:oMath \(Self.m)/>"]) == nil)
    }

    @Test("Equation array rows line up at & and at aligned runs, which are not drawn, and centre on the axis")
    func equationArrays() throws {
        let ampersand = try box("<m:oMath><m:eqArr><m:e>\(r("a&amp;=b"))</m:e></m:eqArr></m:oMath>")
        let plain = try box("<m:oMath>\(r("a=b"))</m:oMath>")
        #expect(abs(ampersand.width - plain.width) < 0.5)

        let left = try box("<m:oMath>\(r("x+yy"))</m:oMath>").width
        let right = try box("<m:oMath>\(r("=55"))</m:oMath>").width
        let aligned = try box(
            "<m:oMath><m:eqArr><m:e>\(r("x+yy"))<m:r><m:rPr><m:aln/></m:rPr><m:t>=5</m:t></m:r></m:e>"
                + "<m:e>\(r("y"))<m:r><m:rPr><m:aln/></m:rPr><m:t>=55</m:t></m:r></m:e></m:eqArr></m:oMath>"
        )
        #expect(abs(aligned.width - (left + right)) < 0.5)
        // Two lines, centred on the math axis rather than sitting on the first line's baseline.
        #expect(abs((aligned.ascent - aligned.descent) / 2 - Self.axis) < 0.5)
    }

    @Test("Delimiters grow thin about the axis, or keep their size when grow is off")
    func delimiters() throws {
        let content = try box("<m:oMath>\(fraction())</m:oMath>")
        let grown = try box("<m:oMath><m:d>\("<m:e>\(fraction())</m:e>")</m:d></m:oMath>")
        #expect(grown.ascent >= content.ascent && grown.descent >= content.descent)
        #expect(abs((grown.ascent - grown.descent) / 2 - Self.axis) < 0.5)
        // Stretched upright, not scaled up: each parenthesis stays narrow.
        #expect(grown.width - content.width < Self.size * 0.9)
        let fixed = try box("<m:oMath><m:d><m:dPr><m:grow m:val=\"0\"/></m:dPr><m:e>\(fraction())</m:e></m:d></m:oMath>")
        #expect(fixed.ascent <= content.ascent + 0.5)
    }

    @Test("A sign that starts a term sits close to it; one between terms is spaced out")
    func signs() throws {
        let minus = try box("<m:oMath>\(r("−"))</m:oMath>").width
        let b = try box("<m:oMath>\(r("b"))</m:oMath>").width
        #expect(abs(try box("<m:oMath>\(r("−b"))</m:oMath>").width - (minus + b)) < 0.5)
        let a = try box("<m:oMath>\(r("a"))</m:oMath>").width
        #expect(try box("<m:oMath>\(r("a−b"))</m:oMath>").width > a + minus + b + Self.size * 0.3)
        // After an operator, a sign belongs to what follows.
        let equals = try box("<m:oMath>\(r("x="))</m:oMath>").width
        #expect(abs(try box("<m:oMath>\(r("x=−b"))</m:oMath>").width - (equals + minus + b)) < 0.5)
    }

    @Test("Phantoms are drawn unless hidden, and take no room where told")
    func phantoms() throws {
        let inner = "<m:e>\(r("WW"))</m:e>"
        let shown = try box("<m:oMath><m:phant>\(inner)</m:phant></m:oMath>")
        let zero = try box("<m:oMath><m:phant><m:phantPr><m:zeroWid/><m:zeroDesc m:val=\"1\"/></m:phantPr>\(inner)</m:phant></m:oMath>")
        #expect(shown.width > 10 && zero.width == 0)
        func png(_ omml: String) -> Data? {
            MathRenderer.image(forXML: omml.replacingOccurrences(of: "<m:oMath>", with: "<m:oMath \(Self.m)>"), fontSize: 20, color: .black)?
                .image.pngData()
        }
        let visible = png("<m:oMath><m:phant>\(inner)</m:phant></m:oMath>")
        let hidden = png("<m:oMath><m:phant><m:phantPr><m:show m:val=\"0\"/></m:phantPr>\(inner)</m:phant></m:oMath>")
        let blank = png("<m:oMath><m:phant><m:phantPr><m:show m:val=\"off\"/></m:phantPr>\(inner)</m:phant></m:oMath>")
        #expect(visible != hidden)
        #expect(hidden == blank)
    }

    @Test("A skewed fraction raises its numerator and lowers its denominator; a linear one keeps them on the line")
    func skewedFractions() throws {
        let linear = try box("<m:oMath>\(fraction("lin"))</m:oMath>")
        let skewed = try box("<m:oMath>\(fraction("skw"))</m:oMath>")
        #expect(skewed.ascent > linear.ascent)
        #expect(skewed.descent > linear.descent)
    }

    @Test("Group characters stretch across what they group")
    func groupCharacters() throws {
        let base = try box("<m:oMath>\(r("a+b+c+d+e"))</m:oMath>")
        let grouped = try box(
            "<m:oMath><m:groupChr><m:groupChrPr><m:chr m:val=\"⏟\"/></m:groupChrPr><m:e>\(r("a+b+c+d+e"))</m:e></m:groupChr></m:oMath>"
        )
        #expect(abs(grouped.width - base.width) < 0.5)
        #expect(grouped.descent > Self.size * 0.2)
    }
}

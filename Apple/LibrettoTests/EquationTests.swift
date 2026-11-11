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

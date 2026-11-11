import Foundation
import Testing
import UIKit
@testable import Libretto
@testable import LibrettoEngine

/// Telling the user which of a document's fonts are not installed, and what is shown instead.
@Suite("Fonts not installed")
struct FontSubstitutionTests {
    private func run(_ text: String, font: String?) -> Inline {
        var inline = Inline(.text(text))
        inline.format.style.fontName = font
        return inline
    }

    @Test("The fonts text is set in that are not installed, each with what is drawn instead")
    func substitutions() {
        var document = WordDocument()
        document.styles.minorFont = "Calibri"
        document.body = [
            .paragraph(Paragraph(inlines: [run("Theme", font: RunStyle.minorThemeFont), run("Serif", font: "Cambria")])),
            .paragraph(Paragraph(inlines: [run("Installed", font: "Helvetica"), run("", font: "Wingdings")])),
        ]
        var unused = StyleSheet.Style(id: "Unused", name: "Unused", kind: .paragraph)
        unused.runStyle.fontName = "Garamond"
        document.styles.styles["Unused"] = unused

        let substitutions = Typography.fontSubstitutions(in: document)
        // An empty run and a style no text is in are not drawn, so they are not reported.
        #expect(substitutions == [
            FontSubstitution(requested: "Calibri", replacement: nil),
            FontSubstitution(requested: "Cambria", replacement: "Georgia"),
        ])
        // In whatever language the tests run in.
        let systemFont = String(localized: "Notice.MissingFonts.SystemFont", bundle: .engine)
        #expect(substitutions[0].label.contains("Calibri") && substitutions[0].label.contains(systemFont))
        #expect(substitutions[1].label.contains("Cambria") && substitutions[1].label.contains("Georgia"))
        #expect(!systemFont.contains("Notice."))
        // And they are drawn in what is reported.
        #expect(Typography.font(for: RunStyle(fontName: "Cambria"), styles: document.styles).familyName == "Georgia")
    }

    @Test("A document in installed fonts has nothing to report")
    func installed() {
        var document = WordDocument()
        document.body = [.paragraph(Paragraph(inlines: [run("Text", font: "Helvetica"), run("Plain", font: nil)]))]
        #expect(Typography.fontSubstitutions(in: document).isEmpty)
    }

    @Test("An opened file reports its fonts that are not installed")
    func opened() {
        var document = WordDocument()
        document.body = [.paragraph(Paragraph(inlines: [run("Text", font: "Cambria")]))]
        #expect(LibrettoDocument(document: document).fontSubstitutions.map(\.requested) == ["Cambria"])
    }
}

import Foundation
import Testing
@testable import Libretto
@testable import LibrettoEngine

@Suite("Plain text")
struct PlainTextTests {
    @Test("Each line is a paragraph, and tabs stay tabs")
    func lines() {
        let document = PlainText.document(from: Data("First line\n\nA\ttab\n".utf8))
        let paragraphs = document.body.compactMap { block -> Paragraph? in
            guard case .paragraph(let paragraph) = block else { return nil }
            return paragraph
        }
        #expect(paragraphs.map(\.plainText) == ["First line", "", "A\ttab"])
        #expect(paragraphs[2].inlines.map(\.content) == [.text("A"), .tab, .text("tab")])
    }

    @Test("Text saves back as it was read")
    func roundTrip() {
        let text = "One\n\n  Two\twith a tab\nThree\n"
        let document = PlainText.document(from: Data(text.utf8))
        #expect(String(decoding: PlainText.data(from: document), as: UTF8.self) == text)
    }

    @Test("Byte order marks and Windows line endings are read through")
    func encodings() {
        var utf16 = Data([0xFF, 0xFE])
        utf16.append("Hello\r\nWorld".data(using: .utf16LittleEndian)!)
        #expect(PlainText.string(from: utf16) == "Hello\nWorld")
        #expect(PlainText.string(from: Data([0xEF, 0xBB, 0xBF]) + Data("Hi\r".utf8)) == "Hi\n")
        #expect(PlainText.string(from: Data([0x63, 0x61, 0x66, 0xE9])) == "café")
    }

    @Test("Line endings are found as the file has them, and saved back the same", arguments: [
        ("One\r\nTwo\r\n\r\nThree\r\n", LineEnding.crlf),
        ("One\rTwo\r\rThree\r", .cr),
        ("One\nTwo\n\nThree\n", .lf),
    ])
    func lineEndings(file: String, ending: LineEnding) {
        let document = PlainText.document(from: Data(file.utf8))
        #expect(document.lineEnding == ending)
        #expect(PlainText.text(of: document) == "One\nTwo\n\nThree")
        #expect(PlainText.data(from: document) == Data(file.utf8))
    }

    @Test("Mixed line endings are taken as the one most lines have, and saved all alike")
    func mixedLineEndings() {
        var document = PlainText.document(from: Data("a\r\nb\r\nc\nd".utf8))
        #expect(document.lineEnding == .crlf)
        #expect(PlainText.data(from: document) == Data("a\r\nb\r\nc\r\nd\r\n".utf8))
        // A file of one line has no ending to go by.
        document = PlainText.document(from: Data("one line".utf8))
        #expect(document.lineEnding == .lf)
    }

    @Test("Each encoding is found from the file, and saved back to the same bytes", arguments: [
        (TextEncoding.utf8, "Grüße, 世界\n"),
        (.utf8WithBOM, "Grüße, 世界\n"),
        (.utf16LittleEndian, "Grüße, 世界\n"),
        (.utf16BigEndian, "Grüße, 世界\n"),
        (.shiftJIS, "// こんにちは、世界。\nlet カタカナ = \"ｶﾀｶﾅ\"\n"),
        (.eucJP, "// こんにちは、世界。\n漢字とひらがな\n"),
        (.windowsLatin1, "résumé naïve café – “quoted”\n"),
    ])
    func encodings(encoding: TextEncoding, text: String) throws {
        let file = try #require(encoding.data(for: text))
        let document = PlainText.document(from: file)
        #expect(document.textEncoding == encoding)
        #expect(PlainText.text(of: document) + "\n" == text)
        #expect(PlainText.data(from: document) == file)
    }

    @Test("A file valid as no encoding reads as Latin-1, which reads anything")
    func latin1() {
        // 0x81 begins a Shift JIS character and is no character at all in Windows Latin 1.
        let file = Data([0x41, 0x81, 0x0A])
        let document = PlainText.document(from: file)
        #expect(document.textEncoding == .isoLatin1)
        #expect(PlainText.data(from: document) == file)
    }

    @Test("A changed line ending and encoding are what the file is saved with")
    func changing() throws {
        var document = PlainText.document(from: Data("日本語\nテキスト\n".utf8))
        document.lineEnding = .crlf
        document.textEncoding = .shiftJIS
        let saved = PlainText.data(from: document)
        #expect(saved == "日本語\r\nテキスト\r\n".data(using: .shiftJIS))
        let reopened = PlainText.document(from: saved)
        #expect(reopened.lineEnding == .crlf)
        #expect(reopened.textEncoding == .shiftJIS)
        #expect(PlainText.text(of: reopened) == "日本語\nテキスト")
    }

    @Test("Text an encoding cannot write is saved in UTF-8 rather than lost")
    func unwritable() {
        var document = PlainText.document(from: Data("caf\u{E9}\n".utf8))
        document.textEncoding = .shiftJIS
        #expect(!TextEncoding.shiftJIS.canEncode("café"))
        #expect(TextEncoding.shiftJIS.fitting("café") == .utf8)
        #expect(TextEncoding.windowsLatin1.fitting("café") == .windowsLatin1)
        #expect(PlainText.data(from: document) == Data("café\n".utf8))
    }

    @Test("A source file opens and saves through its type with its line endings and encoding")
    func sourceFile() throws {
        let file = try #require("let 挨拶 = \"こんにちは\"\r\nprint(挨拶)\r\n".data(using: .shiftJIS))
        let wrapper = FileWrapper(regularFileWithContents: file)
        wrapper.preferredFilename = "Greeting.swift"
        let document = try DocumentFile.read(wrapper, contentType: .swiftSource)
        #expect(document.sourceLanguage == .swift)
        #expect(document.lineEnding == .crlf)
        #expect(document.textEncoding == .shiftJIS)
        let saved = try DocumentFile.fileWrapper(for: document, contentType: .swiftSource)
        #expect(saved.regularFileContents == file)
    }

    @Test("Formatting and tables come out as their text")
    func writing() {
        var document = WordDocument()
        var bold = Inline(.text("Bold"))
        bold.format.style.isBold = true
        let cell = { (text: String) in TableCell(blocks: [.paragraph(Paragraph(text: text))]) }
        document.body = [
            .paragraph(Paragraph(inlines: [bold, Inline(.lineBreak), Inline(.text("next"))])),
            .table(Table(rows: [TableRow(cells: [cell("a"), cell("b")])], gridColumns: [], hasBorders: false)),
        ]
        #expect(String(decoding: PlainText.data(from: document), as: UTF8.self) == "Bold\nnext\na\tb\n")
    }
}

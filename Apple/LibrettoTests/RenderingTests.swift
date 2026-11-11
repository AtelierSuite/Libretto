import Foundation
import Testing
@testable import LibrettoEngine

/// Draws each small document in `Resources/Rendering` and compares its pages
/// with the reference images beside it. See `Resources/Rendering/README.md`
/// for adding a document, and `PageSnapshots` for how pages are compared.
@Suite("Rendering")
struct RenderingTests {
    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Resources/Rendering")

    /// The references for this platform: text is set a little differently on each.
    static let references = folder.appending(path: "References/iOS")

    static var fixtures: [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasSuffix(".docx") }.map { String($0.dropLast(5)) }.sorted()
    }

    @Test("There are documents to draw")
    func hasFixtures() {
        #expect(!Self.fixtures.isEmpty)
    }

    @Test("Each document is drawn as its reference images show", arguments: fixtures)
    @MainActor
    func matchesReferences(_ name: String) throws {
        let document = try DOCXReader.document(from: Data(contentsOf: Self.folder.appending(path: name + ".docx")))
        let problems = try PageSnapshots.compare(document, with: Self.references.appending(path: name), name: name)
        for problem in problems { Issue.record(Comment(rawValue: problem)) }
    }

    @Test("A page that differs is caught")
    @MainActor
    func catchesDifference() throws {
        let document = try DOCXReader.document(from: Data(contentsOf: Self.folder.appending(path: "text.docx")))
        let page = try #require(PageSnapshots.pages(of: document).first)
        let same = PageSnapshots.difference(page, page)
        #expect(same.matches && same.differing == 0)

        var changed = document
        changed.body.removeFirst()
        let other = try #require(PageSnapshots.pages(of: changed).first)
        let comparison = PageSnapshots.difference(other, page)
        #expect(!comparison.matches)
        #expect(comparison.picture != nil)
    }

    @Test("A different number of pages is caught")
    @MainActor
    func catchesPageCount() throws {
        let document = try DOCXReader.document(from: Data(contentsOf: Self.folder.appending(path: "pages.docx")))
        let folder = FileManager.default.temporaryDirectory.appending(path: "LibrettoRendering-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = try #require(PageSnapshots.pages(of: document).first)
        try PageSnapshots.record([first], in: folder)
        let problems = try PageSnapshots.compare(document, with: folder, name: "pages")
        #expect(problems.contains { $0.contains("page(s) drawn") })
    }
}

import Foundation

/// The headers and footers, as the page backgrounds need them: which each
/// page shows, and where.
///
/// Each section shows its own, and carries on the section before's for any
/// kind it has none of, as Word does; its first page is the section's first.
struct WordDocumentHeaderFooter: Equatable {
    struct Section: Equatable {
        var headers: [HeaderFooterKind: HeaderFooterText] = [:]
        var footers: [HeaderFooterKind: HeaderFooterText] = [:]
        var titlePage = false
        /// Points from the page's top and bottom edges.
        var headerDistance: CGFloat = 35
        var footerDistance: CGFloat = 35
        /// How the page number shows, such as `lowerRoman`; `nil` for 1, 2, 3.
        var pageNumberFormat: String?
    }

    var sections: [Section] = [Section()]
    /// Which section each page is in, as laid out; pages past the end are in the last.
    var pageSections: [Int] = []
    var evenAndOdd = false

    init() {}

    init(document: WordDocument, sections setups: [PageSetup]? = nil, pageSections: [Int] = []) {
        var headers: [HeaderFooterKind: HeaderFooterText] = [:]
        var footers: [HeaderFooterKind: HeaderFooterText] = [:]
        sections = (setups ?? [document.pageSetup]).map { setup in
            for kind in HeaderFooterKind.allCases {
                if let id = setup.headerFooters.headers[kind] { headers[kind] = document.headerFooters[id] }
                if let id = setup.headerFooters.footers[kind] { footers[kind] = document.headerFooters[id] }
            }
            return Section(
                headers: headers, footers: footers, titlePage: setup.headerFooters.titlePage,
                headerDistance: CGFloat(setup.headerDistance) / 20, footerDistance: CGFloat(setup.footerDistance) / 20,
                pageNumberFormat: setup.pageNumberFormat
            )
        }
        if sections.isEmpty { sections = [Section()] }
        self.pageSections = pageSections
        evenAndOdd = document.evenAndOddHeaders
    }

    func section(forPage index: Int) -> Section {
        let section = index < pageSections.count ? pageSections[index] : sections.count - 1
        return sections[min(max(0, section), sections.count - 1)]
    }

    private func kind(forPage index: Int) -> HeaderFooterKind {
        let section = index < pageSections.count ? pageSections[index] : sections.count - 1
        let isFirst = index == 0 || (index < pageSections.count && pageSections[index - 1] != section)
        if isFirst, self.section(forPage: index).titlePage { return .first }
        if evenAndOdd, index % 2 == 1 { return .even }
        return .default
    }

    /// What page `index` shows, if anything: an empty header shows nothing.
    func header(forPage index: Int) -> HeaderFooterText? {
        section(forPage: index).headers[kind(forPage: index)].flatMap { $0.text.trimmed.isEmpty ? nil : $0 }
    }

    func footer(forPage index: Int) -> HeaderFooterText? {
        section(forPage: index).footers[kind(forPage: index)].flatMap { $0.text.trimmed.isEmpty ? nil : $0 }
    }
}

/// The notes each page sets at its foot, and the room they take.
struct PageNotes: Equatable {
    var byPage: [Int: [NSAttributedString]] = [:]
    var heights: [Int: CGFloat] = [:]
}

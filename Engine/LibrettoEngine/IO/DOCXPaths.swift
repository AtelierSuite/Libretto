import Foundation

public enum DOCXError: LocalizedError, Sendable {
    case missingMainDocument
    case missingBody

    public var errorDescription: String? {
        switch self {
        case .missingMainDocument:
            return String(localized: "Error.MissingMainDocument", bundle: .engine)
        case .missingBody:
            return String(localized: "Error.MissingBody", bundle: .engine)
        }
    }
}

/// Namespaces and relationship types of WordprocessingML packages.
public enum OOXML: Sendable {
    public static let wordNamespace = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
    public static let relationshipsNamespace = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    public static let drawingNamespace = "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"
    public static let drawingMainNamespace = "http://schemas.openxmlformats.org/drawingml/2006/main"
    public static let pictureNamespace = "http://schemas.openxmlformats.org/drawingml/2006/picture"
    public static let packageRelationshipsNamespace = "http://schemas.openxmlformats.org/package/2006/relationships"
    public static let contentTypesNamespace = "http://schemas.openxmlformats.org/package/2006/content-types"

    public static let officeDocumentType = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument"
    public static let stylesType = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles"
    public static let numberingType = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering"
    public static let themeType = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme"
    public static let imageType = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image"
    public static let headerType = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/header"
    public static let footerType = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/footer"
    public static let hyperlinkType = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink"
    public static let settingsType = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/settings"
    public static let commentsType = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/comments"
    public static let commentsExtendedType = "http://schemas.microsoft.com/office/2011/relationships/commentsExtended"
    public static let commentsContentType = "application/vnd.openxmlformats-officedocument.wordprocessingml.comments+xml"
    public static let commentsExtendedContentType =
        "application/vnd.openxmlformats-officedocument.wordprocessingml.commentsExtended+xml"
    public static func notesType(_ kind: NoteKind) -> String {
        "http://schemas.openxmlformats.org/officeDocument/2006/relationships/\(kind.rawValue)s"
    }

    public static func notesContentType(_ kind: NoteKind) -> String {
        "application/vnd.openxmlformats-officedocument.wordprocessingml.\(kind.rawValue)s+xml"
    }

    public static let w14Namespace = "http://schemas.microsoft.com/office/word/2010/wordml"
    public static let w15Namespace = "http://schemas.microsoft.com/office/word/2012/wordml"
    public static let headerContentType = "application/vnd.openxmlformats-officedocument.wordprocessingml.header+xml"
    public static let footerContentType = "application/vnd.openxmlformats-officedocument.wordprocessingml.footer+xml"

    public static let numberingContentType = "application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"

    /// The prefixes a freshly written document part declares.
    public static let standardNamespaces: [String: String] = [
        "w": wordNamespace,
        "r": relationshipsNamespace,
        "wp": drawingNamespace,
        "a": drawingMainNamespace,
        "pic": pictureNamespace,
        "wps": "http://schemas.microsoft.com/office/word/2010/wordprocessingShape",
        "m": "http://schemas.openxmlformats.org/officeDocument/2006/math",
    ]
}

public enum DOCXPaths: Sendable {
    /// Resolves a relationship target against the part that holds the relationship.
    public static func resolve(_ target: String, relativeTo source: String) -> String {
        if target.hasPrefix("/") { return String(target.dropFirst()) }
        var components = source.split(separator: "/").map(String.init)
        // The part's own name; what is left is the folder it sits in.
        _ = components.popLast()
        for step in target.split(separator: "/") {
            switch step {
            case ".": continue
            case "..": if !components.isEmpty { components.removeLast() }
            default: components.append(String(step))
            }
        }
        return components.joined(separator: "/")
    }

    /// `word/document.xml` → `word/_rels/document.xml.rels`.
    public static func relationshipsPath(for part: String) -> String {
        var components = part.split(separator: "/").map(String.init)
        let name = components.removeLast()
        return (components + ["_rels", name + ".rels"]).joined(separator: "/")
    }
}

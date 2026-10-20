import Foundation
import UniformTypeIdentifiers

extension UTType {
    /// TypeScript, declared by the app. The system gives `.ts` to MPEG-2
    /// transport streams, so a TypeScript file usually arrives as one of those.
    public static let typeScriptSource = UTType("com.microsoft.typescript") ?? .sourceCode
    // Each declared by the app as well, for the systems that have no type of their own for them.
    public static let cSharpSource = UTType(importedAs: "com.microsoft.c-sharp", conformingTo: .sourceCode)
    public static let javaSource = UTType(importedAs: "com.sun.java-source", conformingTo: .sourceCode)
    public static let kotlinSource = UTType(importedAs: "org.kotlinlang.source", conformingTo: .sourceCode)
    public static let goSource = UTType(importedAs: "org.golang.go-script", conformingTo: .sourceCode)
    public static let rustSource = UTType(importedAs: "org.rust-lang.rust-script", conformingTo: .sourceCode)
    public static let sqlSource = UTType(importedAs: "org.iso.sql", conformingTo: .sourceCode)
}

/// The language of a file opened in the code editor. Plain text has no syntax colouring.
///
/// The cases are in the order a menu of them lists them: plain text, then the rest by name.
public enum SourceLanguage: String, CaseIterable, Sendable {
    case plainText
    case c
    case cPlusPlus
    case cSharp
    case css
    case go
    case html
    case java
    case javaScript
    case json
    case kotlin
    case objectiveC
    case php
    case python
    case ruby
    case rust
    case shell
    case sql
    case swift
    case typeScript
    case yaml

    /// The types Libretto opens as source, most particular first.
    public static let contentTypes: [UTType] = [
        .swiftSource, .pythonScript, .typeScriptSource, .javaScript, .html, .css, .shellScript,
        .objectiveCSource, .objectiveCPlusPlusSource, .cPlusPlusSource, .cPlusPlusHeader, .cSource, .cHeader,
        .cSharpSource, .javaSource, .kotlinSource, .goSource, .rustSource, .rubyScript, .phpScript, .sqlSource,
        .json, .yaml, .mpeg2TransportStream,
    ]

    /// The language's name, as a menu of them shows it.
    public var displayName: String {
        switch self {
        case .plainText: return String(localized: "Language.PlainText", bundle: .engine)
        case .c: return "C"
        case .cPlusPlus: return "C++"
        case .cSharp: return "C#"
        case .css: return "CSS"
        case .go: return "Go"
        case .html: return "HTML"
        case .java: return "Java"
        case .javaScript: return "JavaScript"
        case .json: return "JSON"
        case .kotlin: return "Kotlin"
        case .objectiveC: return "Objective-C"
        case .php: return "PHP"
        case .python: return "Python"
        case .ruby: return "Ruby"
        case .rust: return "Rust"
        case .shell: return "Shell"
        case .sql: return "SQL"
        case .swift: return "Swift"
        case .typeScript: return "TypeScript"
        case .yaml: return "YAML"
        }
    }

    public var fileExtensions: [String] {
        switch self {
        case .plainText: return ["txt"]
        case .c: return ["c", "h"]
        case .cPlusPlus: return ["cpp", "cc", "cxx", "c++", "hpp", "hh", "hxx"]
        case .cSharp: return ["cs"]
        case .css: return ["css"]
        case .go: return ["go"]
        case .html: return ["html", "htm"]
        case .java: return ["java"]
        case .javaScript: return ["js", "mjs", "cjs"]
        case .json: return ["json"]
        case .kotlin: return ["kt", "kts"]
        case .objectiveC: return ["m", "mm"]
        case .php: return ["php"]
        case .python: return ["py"]
        case .ruby: return ["rb"]
        case .rust: return ["rs"]
        case .shell: return ["sh", "bash", "zsh"]
        case .sql: return ["sql"]
        case .swift: return ["swift"]
        case .typeScript: return ["ts", "mts", "cts"]
        case .yaml: return ["yaml", "yml"]
        }
    }

    /// The language of a file, from its name if it has one, or else its type.
    public init?(contentType: UTType, filename: String?) {
        let pathExtension = (filename as NSString?)?.pathExtension.lowercased() ?? ""
        if let language = Self.allCases.first(where: { $0.fileExtensions.contains(pathExtension) }) {
            self = language
            return
        }
        // The more particular types first, as some conform to broader ones in this list.
        let types: [(UTType, SourceLanguage)] = [
            (.swiftSource, .swift), (.pythonScript, .python), (.typeScriptSource, .typeScript),
            (.mpeg2TransportStream, .typeScript), (.json, .json), (.javaScript, .javaScript), (.html, .html),
            (.css, .css), (.objectiveCSource, .objectiveC), (.objectiveCPlusPlusSource, .objectiveC),
            (.cPlusPlusSource, .cPlusPlus), (.cPlusPlusHeader, .cPlusPlus), (.cSource, .c), (.cHeader, .c),
            (.cSharpSource, .cSharp), (.javaSource, .java), (.kotlinSource, .kotlin), (.goSource, .go),
            (.rustSource, .rust), (.rubyScript, .ruby), (.phpScript, .php), (.sqlSource, .sql), (.yaml, .yaml),
            (.shellScript, .shell),
        ]
        if let language = types.first(where: { contentType.conforms(to: $0.0) })?.1 {
            self = language
        } else if contentType.conforms(to: .plainText) && !contentType.conforms(to: .markdownDocument) {
            self = .plainText
        } else {
            return nil
        }
    }
}

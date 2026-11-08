import Foundation
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers

extension UTType {
    /// TypeScript, declared by the app. The system gives `.ts` to MPEG-2
    /// transport streams, so a TypeScript file usually arrives as one of those.
    public static let typeScriptSource = UTType("com.microsoft.typescript") ?? .sourceCode
    /// JavaScript with JSX in it, which the system has no type for.
    public static let jsxSource = UTType(importedAs: "org.reactjs.jsx", conformingTo: .javaScript)
    // Each declared by the app as well, for the systems that have no type of their own for them.
    public static let cSharpSource = UTType(importedAs: "com.microsoft.c-sharp", conformingTo: .sourceCode)
    public static let javaSource = UTType(importedAs: "com.sun.java-source", conformingTo: .sourceCode)
    public static let kotlinSource = UTType(importedAs: "org.kotlinlang.source", conformingTo: .sourceCode)
    public static let goSource = UTType(importedAs: "org.golang.go-script", conformingTo: .sourceCode)
    public static let rustSource = UTType(importedAs: "org.rust-lang.rust-script", conformingTo: .sourceCode)
    public static let sqlSource = UTType(importedAs: "org.iso.sql", conformingTo: .sourceCode)
    public static let scssSource = UTType(importedAs: "org.sass-lang.scss", conformingTo: .sourceCode)
    public static let lessSource = UTType(importedAs: "org.lesscss.less", conformingTo: .sourceCode)
    public static let toml = UTType(importedAs: "org.toml-lang.toml", conformingTo: .plainText)
    public static let ini = UTType(importedAs: "com.microsoft.ini", conformingTo: .plainText)
    public static let javaProperties = UTType(importedAs: "com.sun.java-properties", conformingTo: .plainText)
    public static let dockerfile = UTType(importedAs: "com.docker.dockerfile", conformingTo: .sourceCode)
    public static let makefile = UTType(importedAs: "org.gnu.makefile", conformingTo: .sourceCode)
    public static let diff = UTType(importedAs: "org.gnu.diff", conformingTo: .plainText)
    public static let luaSource = UTType(importedAs: "org.lua.lua-source", conformingTo: .sourceCode)
    public static let dartSource = UTType(importedAs: "org.dartlang.dart-source", conformingTo: .sourceCode)
    public static let scalaSource = UTType(importedAs: "org.scala-lang.scala-source", conformingTo: .sourceCode)
    public static let rSource = UTType(importedAs: "org.r-project.r-source", conformingTo: .sourceCode)
    public static let zigSource = UTType(importedAs: "org.ziglang.zig-source", conformingTo: .sourceCode)
    public static let elixirSource = UTType(importedAs: "org.elixir-lang.elixir-source", conformingTo: .sourceCode)
    public static let haskellSource = UTType(importedAs: "org.haskell.haskell-source", conformingTo: .sourceCode)
    public static let graphQLSource = UTType(importedAs: "org.graphql.graphql-source", conformingTo: .sourceCode)
    public static let jsonWithComments = UTType(importedAs: "com.microsoft.jsonc", conformingTo: .json)
    public static let json5 = UTType(importedAs: "org.json5", conformingTo: .json)
    public static let interfaceBuilderDocument = UTType(
        importedAs: "com.apple.interfacebuilder.document.cocoa", conformingTo: .xml
    )
    public static let storyboard = UTType(importedAs: "com.apple.InterfaceBuilder3.Storyboard.XIB", conformingTo: .xml)
    public static let msBuildProject = UTType(importedAs: "com.microsoft.msbuild-project", conformingTo: .xml)
}
#endif

/// The language of a file opened in the code editor. Plain text has no syntax colouring.
///
/// The cases are in the order a menu of them lists them: plain text, then the rest by name.
public enum SourceLanguage: String, CaseIterable, Sendable {
    case plainText
    case c
    case cPlusPlus
    case cSharp
    case css
    case dart
    case diff
    case dockerfile
    case elixir
    case go
    case graphQL
    case haskell
    case html
    case ini
    case java
    case javaScript
    case json
    case kotlin
    case less
    case lua
    case makefile
    case objectiveC
    case perl
    case php
    case python
    case r
    case ruby
    case rust
    case scala
    case scss
    case shell
    case sql
    case swift
    case toml
    case typeScript
    case xml
    case yaml
    case zig

    #if canImport(UniformTypeIdentifiers)
    /// The types Libretto opens as source, most particular first.
    public static let contentTypes: [UTType] = [
        .swiftSource, .pythonScript, .typeScriptSource, .jsxSource, .javaScript, .html, .scssSource, .lessSource, .css,
        .shellScript, .objectiveCSource, .objectiveCPlusPlusSource, .cPlusPlusSource, .cPlusPlusHeader, .cSource,
        .cHeader, .cSharpSource, .javaSource, .kotlinSource, .goSource, .rustSource, .rubyScript, .phpScript,
        .perlScript, .sqlSource, .luaSource, .dartSource, .scalaSource, .rSource, .zigSource, .elixirSource,
        .haskellSource, .graphQLSource, .dockerfile, .makefile, .diff, .jsonWithComments, .json5, .json, .yaml, .toml,
        .ini, .javaProperties, .interfaceBuilderDocument, .storyboard, .msBuildProject, .propertyList, .svg, .xml,
        .mpeg2TransportStream,
    ]
    #endif

    /// The language's name, as a menu of them shows it.
    public var displayName: String {
        switch self {
        case .plainText: return String(localized: "Language.PlainText", bundle: .engine)
        case .c: return "C"
        case .cPlusPlus: return "C++"
        case .cSharp: return "C#"
        case .css: return "CSS"
        case .dart: return "Dart"
        case .diff: return String(localized: "Language.Diff", bundle: .engine)
        case .dockerfile: return "Dockerfile"
        case .elixir: return "Elixir"
        case .go: return "Go"
        case .graphQL: return "GraphQL"
        case .haskell: return "Haskell"
        case .html: return "HTML"
        case .ini: return "INI"
        case .java: return "Java"
        case .javaScript: return "JavaScript"
        case .json: return "JSON"
        case .kotlin: return "Kotlin"
        case .less: return "Less"
        case .lua: return "Lua"
        case .makefile: return "Makefile"
        case .objectiveC: return "Objective-C"
        case .perl: return "Perl"
        case .php: return "PHP"
        case .python: return "Python"
        case .r: return "R"
        case .ruby: return "Ruby"
        case .rust: return "Rust"
        case .scala: return "Scala"
        case .scss: return "SCSS"
        case .shell: return "Shell"
        case .sql: return "SQL"
        case .swift: return "Swift"
        case .toml: return "TOML"
        case .typeScript: return "TypeScript"
        case .xml: return "XML"
        case .yaml: return "YAML"
        case .zig: return "Zig"
        }
    }

    public var fileExtensions: [String] {
        switch self {
        case .plainText: return ["txt"]
        case .c: return ["c", "h"]
        case .cPlusPlus: return ["cpp", "cc", "cxx", "c++", "hpp", "hh", "hxx", "h++", "ipp"]
        case .cSharp: return ["cs"]
        case .css: return ["css"]
        case .dart: return ["dart"]
        case .diff: return ["diff", "patch"]
        case .dockerfile: return ["dockerfile", "containerfile"]
        case .elixir: return ["ex", "exs"]
        case .go: return ["go"]
        case .graphQL: return ["graphql", "gql"]
        case .haskell: return ["hs"]
        case .html: return ["html", "htm"]
        case .ini: return ["ini", "cfg", "properties"]
        case .java: return ["java"]
        case .javaScript: return ["js", "mjs", "cjs", "jsx"]
        case .json: return ["json", "jsonc", "json5"]
        case .kotlin: return ["kt", "kts"]
        case .less: return ["less"]
        case .lua: return ["lua"]
        case .makefile: return ["mk", "mak"]
        case .objectiveC: return ["m", "mm"]
        case .perl: return ["pl", "pm"]
        case .php: return ["php", "phtml"]
        case .python: return ["py", "pyi", "pyw"]
        case .r: return ["r"]
        case .ruby: return ["rb", "rake", "gemspec", "ru"]
        case .rust: return ["rs"]
        case .scala: return ["scala", "sc"]
        case .scss: return ["scss"]
        case .shell: return ["sh", "bash", "zsh", "ksh"]
        case .sql: return ["sql"]
        case .swift: return ["swift"]
        case .toml: return ["toml"]
        case .typeScript: return ["ts", "mts", "cts", "tsx"]
        case .xml: return ["xml", "plist", "svg", "xib", "storyboard", "csproj", "vbproj", "fsproj"]
        case .yaml: return ["yaml", "yml"]
        case .zig: return ["zig", "zon"]
        }
    }

    /// Files known by their whole name rather than an extension, in lower case.
    public static let filenames: [String: SourceLanguage] = [
        "dockerfile": .dockerfile, "containerfile": .dockerfile, "makefile": .makefile, "gnumakefile": .makefile,
        "gemfile": .ruby, "podfile": .ruby, "rakefile": .ruby, "brewfile": .ruby, "vagrantfile": .ruby,
        "fastfile": .ruby, "appfile": .ruby, "guardfile": .ruby, "dangerfile": .ruby,
        ".bashrc": .shell, ".bash_profile": .shell, ".bash_logout": .shell, ".profile": .shell,
        ".zshrc": .shell, ".zshenv": .shell, ".zprofile": .shell, ".zlogin": .shell, ".zlogout": .shell,
        ".kshrc": .shell, "pkgbuild": .shell,
        // Their `#` comments read as the shell's, and little else in them looks like code.
        ".gitignore": .shell, ".gitattributes": .shell, ".dockerignore": .shell, ".npmignore": .shell,
        ".env": .ini, ".editorconfig": .ini, ".gitconfig": .ini, ".gitmodules": .ini, ".npmrc": .ini,
        "pipfile": .toml, "cargo.lock": .toml, "poetry.lock": .toml, "uv.lock": .toml,
    ]

    /// The language a file's whole name, in lower case, gives it.
    private static func language(named name: String) -> SourceLanguage? {
        if let language = filenames[name] { return language }
        // `.env.local`, `.env.production` and the rest, and `Dockerfile.dev`.
        if name.hasPrefix(".env.") { return .ini }
        if name.hasPrefix("dockerfile.") || name.hasPrefix("containerfile.") { return .dockerfile }
        return nil
    }

    /// The language of a file, from its whole name or else its extension.
    public init?(filename: String) {
        // A name the language is known by comes before an extension, which `.zshrc` would seem to be.
        let name = (filename as NSString).lastPathComponent.lowercased()
        if let language = Self.language(named: name) {
            self = language
            return
        }
        let pathExtension = (name as NSString).pathExtension
        guard let language = Self.allCases.first(where: { $0.fileExtensions.contains(pathExtension) }) else {
            return nil
        }
        self = language
    }

    #if canImport(UniformTypeIdentifiers)
    /// The language of a file, from its name if it has one, or else its type.
    public init?(contentType: UTType, filename: String?) {
        if let filename, let language = SourceLanguage(filename: filename) {
            self = language
            return
        }
        // The more particular types first, as some conform to broader ones in this list.
        let types: [(UTType, SourceLanguage)] = [
            (.swiftSource, .swift), (.pythonScript, .python), (.typeScriptSource, .typeScript),
            (.mpeg2TransportStream, .typeScript), (.json, .json), (.javaScript, .javaScript), (.html, .html),
            (.scssSource, .scss), (.lessSource, .less), (.css, .css), (.objectiveCSource, .objectiveC),
            (.objectiveCPlusPlusSource, .objectiveC), (.cPlusPlusSource, .cPlusPlus), (.cPlusPlusHeader, .cPlusPlus),
            (.cSource, .c), (.cHeader, .c), (.cSharpSource, .cSharp), (.javaSource, .java), (.kotlinSource, .kotlin),
            (.goSource, .go), (.rustSource, .rust), (.rubyScript, .ruby), (.phpScript, .php), (.sqlSource, .sql),
            (.perlScript, .perl), (.luaSource, .lua), (.dartSource, .dart), (.scalaSource, .scala), (.rSource, .r),
            (.zigSource, .zig), (.elixirSource, .elixir), (.haskellSource, .haskell), (.graphQLSource, .graphQL),
            (.dockerfile, .dockerfile), (.makefile, .makefile), (.diff, .diff),
            (.yaml, .yaml), (.toml, .toml), (.ini, .ini), (.javaProperties, .ini), (.propertyList, .xml),
            (.svg, .xml), (.xml, .xml), (.shellScript, .shell),
        ]
        if let language = types.first(where: { contentType.conforms(to: $0.0) })?.1 {
            self = language
        } else if contentType.conforms(to: .plainText) && !contentType.conforms(to: .markdownDocument) {
            self = .plainText
        } else {
            return nil
        }
    }
    #endif
}

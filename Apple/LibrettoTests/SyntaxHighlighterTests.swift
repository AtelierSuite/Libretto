import Foundation
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import Libretto
@testable import LibrettoEngine

@Suite("Syntax highlighting")
struct SyntaxHighlighterTests {
    /// Each token's text and kind.
    private func tokens(_ text: String, _ language: SourceLanguage) -> [String: SyntaxKind] {
        let string = text as NSString
        var result: [String: SyntaxKind] = [:]
        for token in SyntaxHighlighter.tokens(in: text, language: language) {
            result[string.substring(with: token.range)] = token.kind
        }
        return result
    }

    @Test("Swift keywords, types, strings, comments, numbers and attributes")
    func swift() {
        let found = tokens("""
            @MainActor final class View { // note
                let name: String = "a \\"b\\""
                /* block
                   comment */ var count = 42
            #if DEBUG
            }
            """, .swift)
        #expect(found["@MainActor"] == .attribute)
        #expect(found["final"] == .keyword)
        #expect(found["View"] == .type)
        #expect(found["String"] == .type)
        #expect(found["// note"] == .comment)
        #expect(found["\"a \\\"b\\\"\""] == .string)
        #expect(found.first { $0.key.hasPrefix("/* block\n") && $0.key.hasSuffix("comment */") }?.value == .comment)
        #expect(found["42"] == .number)
        #expect(found["#if"] == .keyword)
        #expect(found["name"] == nil)
    }

    @Test("Python strings and comments, and keywords only where they are words")
    func python() {
        let found = tokens("def f(x):\n    '''doc\n    string'''\n    return x.def  # done\n", .python)
        #expect(found["def"] == .keyword)
        #expect(found["'''doc\n    string'''"] == .string)
        #expect(found["return"] == .keyword)
        #expect(found["# done"] == .comment)
        #expect(tokens("x.def", .python)["def"] == nil)
    }

    @Test("TypeScript has its own keywords and keeps template strings whole")
    func scripts() {
        let found = tokens("interface A { b: number }\nconst s = `x\ny`", .typeScript)
        #expect(found["interface"] == .keyword)
        #expect(found["number"] == .keyword)
        #expect(found["`x\ny`"] == .string)
        #expect(tokens("interface A {}", .javaScript)["interface"] == nil)
    }

    @Test("Shell variables, and # only as a comment at the start of a word")
    func shell() {
        let found = tokens("if [ -n \"$HOME\" ]; then echo ${#ARR} $1 # done\nfi", .shell)
        #expect(found["if"] == .keyword)
        #expect(found["\"$HOME\""] == .string)
        #expect(found["${#ARR}"] == .variable)
        #expect(found["$1"] == .variable)
        #expect(found["# done"] == .comment)
        #expect(found["fi"] == .keyword)
    }

    @Test("Dockerfile instructions around the shell's commands")
    func dockerfile() {
        let found = tokens("""
            # syntax=docker/dockerfile:1
            FROM node:20 AS build
            ARG VERSION=1
            ENV PATH=/app/bin:${PATH}
            RUN if [ -n "$VERSION" ]; then echo ok; fi
            CMD ["node", "server.js"]
            """, .dockerfile)
        #expect(found["# syntax=docker/dockerfile:1"] == .comment)
        #expect(found["FROM"] == .keyword)
        #expect(found["AS"] == .keyword)
        #expect(found["ARG"] == .keyword)
        #expect(found["${PATH}"] == .variable)
        #expect(found["RUN"] == .keyword)
        #expect(found["if"] == .keyword)
        #expect(found["\"node\""] == .string)
        #expect(tokens("FROM x", .shell)["FROM"] == nil)
        #expect(SourceLanguage(contentType: .data, filename: "Dockerfile") == .dockerfile)
        #expect(SourceLanguage(contentType: .data, filename: "Dockerfile.dev") == .dockerfile)
        #expect(SourceLanguage(contentType: .plainText, filename: "web.dockerfile") == .dockerfile)
    }

    @Test("Makefile targets, variables and directives")
    func makefile() {
        let found = tokens("""
            CC ?= clang
            CFLAGS := -O2 # fast
            .PHONY: all clean
            all: $(OBJ)
            %.o: %.c
            \t$(CC) $(CFLAGS) -c $< -o $@ $(patsubst %.c,%.o,$(SRC))
            ifeq ($(OS),Windows_NT)
            -include deps.mk
            endif
            """, .makefile)
        #expect(found["CC"] == .variable)
        #expect(found["CFLAGS"] == .variable)
        #expect(found["# fast"] == .comment)
        #expect(found[".PHONY"] == .keyword)
        #expect(found["all"] == .property)
        #expect(found["$(OBJ)"] == .variable)
        #expect(found["%.o"] == .property)
        #expect(found["$(CC)"] == .variable)
        #expect(found["$<"] == .variable)
        #expect(found["$@"] == .variable)
        #expect(found["$(patsubst %.c,%.o,$(SRC))"] == .variable)
        #expect(found["ifeq"] == .keyword)
        #expect(found["include"] == .keyword)
        #expect(found["endif"] == .keyword)
        #expect(SourceLanguage(contentType: .data, filename: "Makefile") == .makefile)
        #expect(SourceLanguage(contentType: .data, filename: "GNUmakefile") == .makefile)
        #expect(SourceLanguage(contentType: .plainText, filename: "rules.mk") == .makefile)
    }

    @Test("HTML tags and attributes, with the script and style inside them")
    func html() {
        let found = tokens("""
            <!-- c --><a href="x" hidden>&amp;</a>
            <script>let n = 1</script><style>p { color: red }</style>
            """, .html)
        #expect(found["<!-- c -->"] == .comment)
        #expect(found["<a"] == .tag)
        #expect(found["href"] == .property)
        #expect(found["\"x\""] == .string)
        #expect(found["hidden"] == .property)
        #expect(found["&amp;"] == .number)
        #expect(found["</a"] == .tag)
        #expect(found["let"] == .keyword)
        #expect(found["p"] == .tag)
        #expect(found["color"] == .property)
    }

    @Test("XML tags, attributes and CDATA, with no script or style inside them")
    func xml() {
        let found = tokens("""
            <?xml version="1.0"?>
            <!-- c --><plist version="1.0"><key>a</key><script>let n = 1</script>
            <data><![CDATA[<raw> & more]]></data>&lt;</plist>
            """, .xml)
        #expect(found["<?xml version=\"1.0\"?>"] == .keyword)
        #expect(found["<!-- c -->"] == .comment)
        #expect(found["<plist"] == .tag)
        #expect(found["version"] == .property)
        #expect(found["\"1.0\""] == .string)
        #expect(found["</key"] == .tag)
        #expect(found["<![CDATA[<raw> & more]]>"] == .string)
        #expect(found["&lt;"] == .number)
        #expect(found["let"] == nil)
        #expect(SourceLanguage(contentType: .plainText, filename: "Info.plist") == .xml)
        #expect(SourceLanguage(contentType: .plainText, filename: "Main.storyboard") == .xml)
        #expect(SourceLanguage(contentType: .svg, filename: nil) == .xml)
        #expect(SourceLanguage(contentType: .xml, filename: nil) == .xml)
    }

    @Test("CSS selectors, properties, numbers and at-rules")
    func css() {
        let found = tokens("@media screen { .card > h1:hover { margin: -4px 1.5em; color: #fff !important; } }", .css)
        #expect(found["@media"] == .keyword)
        #expect(found[".card"] == .attribute)
        #expect(found["h1"] == .tag)
        #expect(found[":hover"] == .keyword)
        #expect(found["margin"] == .property)
        #expect(found["4px"] == .number)
        #expect(found["1.5em"] == .number)
        #expect(found["#fff"] == .number)
        #expect(found["!important"] == .keyword)
    }

    @Test("SCSS's comments, variables, nesting and placeholders")
    func scss() {
        let found = tokens("""
            // Colours
            $accent-color: #f80;
            %card { padding: 4px; }
            .button { color: $accent-color; &:hover { background: url(http://a.b/c.png); } .icon-#{$size} { } }
            @mixin round($r) { border-radius: $r; }
            """, .scss)
        #expect(found["// Colours"] == .comment)
        #expect(found["$accent-color"] == .variable)
        #expect(found["#f80"] == .number)
        #expect(found["%card"] == .attribute)
        #expect(found["padding"] == .property)
        #expect(found[".button"] == .attribute)
        #expect(found["&"] == .keyword)
        #expect(found[":hover"] == .keyword)
        #expect(found["background"] == .property)
        #expect(found.keys.contains { $0.hasPrefix("//a.b") } == false)
        #expect(found["#{$size}"] == .variable)
        #expect(found["@mixin"] == .keyword)
        #expect(found["border-radius"] == .property)
        #expect(SourceLanguage(contentType: .plainText, filename: "app.scss") == .scss)
    }

    @Test("Less's comments, and its variables apart from its at-rules")
    func less() {
        let found = tokens("""
            @import "base"; // shared
            @width: 10px;
            @media screen { .box { width: @width; .@{name}-x { } } }
            """, .less)
        #expect(found["@import"] == .keyword)
        #expect(found["// shared"] == .comment)
        #expect(found["@width"] == .variable)
        #expect(found["10px"] == .number)
        #expect(found["@media"] == .keyword)
        #expect(found[".box"] == .attribute)
        #expect(found["width"] == .property)
        #expect(found["@{name}"] == .variable)
        #expect(tokens("a { b: c } // d", .css)["// d"] == nil)
        #expect(SourceLanguage(contentType: .plainText, filename: "theme.less") == .less)
    }

    @Test("C's preprocessor and built-in types, and C++'s own keywords")
    func cFamily() {
        let found = tokens("#include <stdio.h>\nstatic int count = 0; // c\nnamespace a {}", .cPlusPlus)
        #expect(found["#include"] == .keyword)
        #expect(found["static"] == .keyword)
        #expect(found["int"] == .type)
        #expect(found["0"] == .number)
        #expect(found["// c"] == .comment)
        #expect(found["namespace"] == .keyword)
        #expect(tokens("namespace a {}", .c)["namespace"] == nil)
        #expect(tokens("@interface View : NSObject", .objectiveC)["@interface"] == .attribute)
    }

    @Test("Go's raw strings, and capitals that mark exports rather than types")
    func go() {
        let found = tokens("func Run(n int) string {\n\treturn `a\nb`\n}", .go)
        #expect(found["func"] == .keyword)
        #expect(found["Run"] == nil)
        #expect(found["int"] == .type)
        #expect(found["`a\nb`"] == .string)
    }

    @Test("Rust lifetimes are not strings")
    func rust() {
        let found = tokens("fn first<'a>(s: &'a str) -> Option<u8> { None }", .rust)
        #expect(found["fn"] == .keyword)
        #expect(found["str"] == .type)
        #expect(found["Option"] == .type)
        #expect(found.keys.contains { $0.hasPrefix("'") } == false)
    }

    @Test("PHP variables, and both its line comments")
    func php() {
        let found = tokens("<?php\n$name = 'a'; // one\n# two\necho $name;", .php)
        #expect(found["$name"] == .variable)
        #expect(found["'a'"] == .string)
        #expect(found["// one"] == .comment)
        #expect(found["# two"] == .comment)
        #expect(found["echo"] == .keyword)
    }

    @Test("SQL keywords in any case")
    func sql() {
        let found = tokens("SELECT name FROM users where id = 1 -- first", .sql)
        #expect(found["SELECT"] == .keyword)
        #expect(found["where"] == .keyword)
        #expect(found["users"] == nil)
        #expect(found["-- first"] == .comment)
    }

    @Test("Lua's long comments and long strings")
    func lua() {
        let found = tokens("local s = [[a\nb]] -- note\n--[[ long\ncomment ]]\nfunction f() return nil end", .lua)
        #expect(found["local"] == .keyword)
        #expect(found["[[a\nb]]"] == .string)
        #expect(found["-- note"] == .comment)
        #expect(found["--[[ long\ncomment ]]"] == .comment)
        #expect(found["function"] == .keyword)
        #expect(found["end"] == .keyword)
    }

    @Test("Lua's long strings open with brackets, which are no quotes")
    func luaQuotes() {
        #expect(SyntaxHighlighter.quotes(for: .lua) == [0x22, 0x27])
    }

    @Test("Dart and Scala keywords, types and annotations")
    func dartAndScala() {
        let dart = tokens("@override\nfinal int count = 0; // c\nlate String name = '''a\nb''';", .dart)
        #expect(dart["@override"] == .attribute)
        #expect(dart["final"] == .keyword)
        #expect(dart["int"] == .type)
        #expect(dart["String"] == .type)
        #expect(dart["'''a\nb'''"] == .string)
        #expect(dart["// c"] == .comment)
        let scala = tokens("case class Point(x: Int) extends Shape /* s */\nval s = \"\"\"raw\\n\"\"\"", .scala)
        #expect(scala["case"] == .keyword)
        #expect(scala["val"] == .keyword)
        #expect(scala["Int"] == .type)
        #expect(scala["/* s */"] == .comment)
        #expect(scala["\"\"\"raw\\n\"\"\""] == .string)
    }

    @Test("Perl's scalars, arrays and hashes")
    func perl() {
        let found = tokens(
            "my @items = qw(a b); my %seen; # c\nforeach my $item (@items) { print \"$item\\n\" }", .perl
        )
        #expect(found["my"] == .keyword)
        #expect(found["@items"] == .variable)
        #expect(found["%seen"] == .variable)
        #expect(found["$item"] == .variable)
        #expect(found["# c"] == .comment)
        #expect(found["foreach"] == .keyword)
        #expect(tokens("$a % 2", .perl)["% 2"] == nil)
    }

    @Test("R, Zig and Elixir keywords, comments and strings")
    func rZigElixir() {
        let r = tokens("f <- function(x) { if (is.na(x)) NULL else TRUE } # r", .r)
        #expect(r["function"] == .keyword)
        #expect(r["NULL"] == .keyword)
        #expect(r["TRUE"] == .keyword)
        #expect(r["# r"] == .comment)
        let zig = tokens("const std = @import(\"std\");\npub fn main() !void { var n: u32 = 0; }", .zig)
        #expect(zig["const"] == .keyword)
        #expect(zig["@import"] == .attribute)
        #expect(zig["\"std\""] == .string)
        #expect(zig["void"] == .type)
        #expect(zig["u32"] == .type)
        let elixir = tokens(
            "defmodule Greeter do\n  @doc \"\"\"\n  Hi\n  \"\"\"\n  def hi(name), do: name # e\nend", .elixir
        )
        #expect(elixir["defmodule"] == .keyword)
        #expect(elixir["Greeter"] == .type)
        #expect(elixir["@doc"] == .attribute)
        #expect(elixir["\"\"\"\n  Hi\n  \"\"\""] == .string)
        #expect(elixir["# e"] == .comment)
        #expect(elixir["end"] == .keyword)
    }

    @Test("Haskell's comments, and the primes in its names")
    func haskell() {
        let found = tokens(
            "{-# LANGUAGE GADTs #-}\nmodule Main where -- m\nsum' :: [Int] -> Int\nsum' = foldl' (+) 0", .haskell
        )
        #expect(found["{-# LANGUAGE GADTs #-}"] == .comment)
        #expect(found["module"] == .keyword)
        #expect(found["where"] == .keyword)
        #expect(found["-- m"] == .comment)
        #expect(found["Int"] == .type)
        #expect(found.values.contains(.string) == false)
    }

    @Test("GraphQL operations, variables and directives")
    func graphQL() {
        let found = tokens("query Book($id: ID!) { # q\n  book(id: $id) @include(if: true) { title } }", .graphQL)
        #expect(found["query"] == .keyword)
        #expect(found["Book"] == .type)
        #expect(found["$id"] == .variable)
        #expect(found["ID"] == .type)
        #expect(found["# q"] == .comment)
        #expect(found["@include"] == .attribute)
        #expect(found["true"] == .keyword)
    }

    @Test("A diff's headers, hunks, and the lines it adds and removes")
    func diff() {
        let found = tokens("""
            diff --git a/main.lua b/main.lua
            index 3b18e51..a2c4f9d 100644
            --- a/main.lua
            +++ b/main.lua
            @@ -1,3 +1,3 @@ local function greet()
             local name = "world"
            --- say hello
            +-- say hi
            \\ No newline at end of file
             print(name)
            -- not in a hunk
            """, .diff)
        #expect(found["diff --git a/main.lua b/main.lua"] == .keyword)
        #expect(found["index 3b18e51..a2c4f9d 100644"] == .keyword)
        #expect(found["--- a/main.lua"] == .keyword)
        #expect(found["+++ b/main.lua"] == .keyword)
        #expect(found["@@ -1,3 +1,3 @@"] == .tag)
        #expect(found["--- say hello"] == .removed)
        #expect(found["+-- say hi"] == .added)
        #expect(found["\\ No newline at end of file"] == .comment)
        #expect(found[" print(name)"] == nil)
        #expect(found["-- not in a hunk"] == nil)
        #expect(tokens("@@ -5 +5 @@\n-a\n+b\n-c", .diff)["-c"] == nil)
        #expect(tokens("@@ -1 +1 @@\r\n-a\r\n+b\r\n", .diff)["+b"] == .added)
        #expect(SourceLanguage(contentType: .plainText, filename: "fix.patch") == .diff)
        #expect(SourceLanguage.diff.displayName != "Language.Diff")
    }

    @Test("Each colour has the contrast of the rest against its background")
    func diffColours() {
        func luminance(_ color: UIColor) -> CGFloat {
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            let linear = { (value: CGFloat) in value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        }
        for kind in [SyntaxKind.added, .removed] {
            #expect(1.05 / (luminance(SyntaxHighlighter.color(for: kind, scheme: .light)) + 0.05) >= 7.5)
            #expect((luminance(SyntaxHighlighter.color(for: kind, scheme: .dark)) + 0.05) / 0.05 >= 10)
        }
    }

    @Test("JSON and YAML keys apart from their values")
    func data() {
        let json = tokens("{\"name\" : \"Libretto\", \"open\": true, \"count\": 3}", .json)
        #expect(json["\"name\""] == .property)
        #expect(json["\"Libretto\""] == .string)
        #expect(json["true"] == .keyword)
        #expect(json["3"] == .number)
        let yaml = tokens("name: Libretto # app\nurl: http://example.com\nshared: yes\n", .yaml)
        #expect(yaml["name"] == .property)
        #expect(yaml["# app"] == .comment)
        #expect(yaml["http"] == nil)
        #expect(yaml["yes"] == .keyword)
    }

    @Test("JSX and TSX open as JavaScript and TypeScript")
    func jsx() {
        #expect(SourceLanguage(contentType: .plainText, filename: "App.jsx") == .javaScript)
        #expect(SourceLanguage(contentType: .plainText, filename: "App.tsx") == .typeScript)
        #expect(SourceLanguage(contentType: .jsxSource, filename: nil) == .javaScript)
        let found = tokens("export const App = () => <div className=\"app\">{count}</div>", .javaScript)
        #expect(found["export"] == .keyword)
        #expect(found["\"app\""] == .string)
    }

    @Test("JSON with comments, as tsconfig.json and VS Code's settings have them")
    func jsonComments() {
        let found = tokens("{\n  // strict\n  \"strict\": true, /* all */\n  'quoted': 1\n}", .json)
        #expect(found["// strict"] == .comment)
        #expect(found["/* all */"] == .comment)
        #expect(found["\"strict\""] == .property)
        #expect(found["'quoted'"] == .property)
        #expect(SourceLanguage(contentType: .plainText, filename: "settings.jsonc") == .json)
        #expect(SourceLanguage(contentType: .plainText, filename: "config.json5") == .json)
        #expect(SourceLanguage(contentType: .jsonWithComments, filename: nil) == .json)
    }

    @Test("The less common extensions of the languages already coloured")
    func moreExtensions() {
        let expected: [String: SourceLanguage] = [
            "types.pyi": .python, "app.pyw": .python, "build.rake": .ruby, "libretto.gemspec": .ruby,
            "config.ru": .ruby, "setup.ksh": .shell, "list.h++": .cPlusPlus, "list.ipp": .cPlusPlus,
            "page.phtml": .php,
        ]
        for (filename, language) in expected {
            #expect(SourceLanguage(contentType: .plainText, filename: filename) == language)
        }
    }

    @Test("Files known by their name rather than their extension")
    func filenames() {
        #expect(SourceLanguage(contentType: .data, filename: "Gemfile") == .ruby)
        #expect(SourceLanguage(contentType: .data, filename: "Podfile") == .ruby)
        #expect(SourceLanguage(contentType: .data, filename: "Rakefile") == .ruby)
        #expect(SourceLanguage(contentType: .data, filename: ".zshrc") == .shell)
        #expect(SourceLanguage(contentType: .data, filename: "/Users/me/.bashrc") == .shell)
        #expect(SourceLanguage(contentType: .data, filename: ".profile") == .shell)
        #expect(SourceLanguage(contentType: .data, filename: ".gitignore") == .shell)
        #expect(SourceLanguage(contentType: .data, filename: "Gemfile.lock") == nil)
        #expect(SourceLanguage(contentType: .data, filename: "notes") == nil)
    }

    @Test("TOML's keys, tables, strings and values")
    func toml() {
        let found = tokens("""
            # Cargo
            [package]
            name = "libretto"
            "quoted key" = 'raw\\path'
            version.major = 1
            [[bin]]
            features = [
              ["a", "b"],
            ]
            enabled = true # on
            """, .toml)
        #expect(found["# Cargo"] == .comment)
        #expect(found["[package]"] == .tag)
        #expect(found["name"] == .property)
        #expect(found["\"libretto\""] == .string)
        #expect(found["\"quoted key\""] == .property)
        #expect(found["'raw\\path'"] == .string)
        #expect(found["version.major"] == .property)
        #expect(found["1"] == .number)
        #expect(found["[[bin]]"] == .tag)
        #expect(found["[\"a\", \"b\"]"] == nil)
        #expect(found["\"a\""] == .string)
        #expect(found["true"] == .keyword)
        #expect(found["# on"] == .comment)
        #expect(SourceLanguage(contentType: .plainText, filename: "Cargo.toml") == .toml)
        #expect(SourceLanguage(contentType: .data, filename: "Pipfile") == .toml)
    }

    @Test("INI, .properties and .env keys, sections and comments")
    func ini() {
        let found = tokens("""
            ; settings
            [server]
            host = example.com
            path=a;b
            debug: on
            # done
            """, .ini)
        #expect(found["; settings"] == .comment)
        #expect(found["[server]"] == .tag)
        #expect(found["host"] == .property)
        #expect(found["path"] == .property)
        #expect(found.keys.contains(";b") == false)
        #expect(found["debug"] == .property)
        #expect(found["on"] == .keyword)
        #expect(found["# done"] == .comment)
        let env = tokens("export API_KEY=\"abc\"\nHOME_DIR=${HOME}/x\n", .ini)
        #expect(env["export"] == .keyword)
        #expect(env["API_KEY"] == .property)
        #expect(env["\"abc\""] == .string)
        #expect(env["${HOME}"] == .variable)
        #expect(tokens("log4j.rootLogger=INFO, stdout", .ini)["log4j.rootLogger"] == .property)
        #expect(SourceLanguage(contentType: .plainText, filename: "setup.cfg") == .ini)
        #expect(SourceLanguage(contentType: .plainText, filename: "app.properties") == .ini)
        #expect(SourceLanguage(contentType: .data, filename: ".env") == .ini)
        #expect(SourceLanguage(contentType: .data, filename: ".env.local") == .ini)
        #expect(SourceLanguage(contentType: .data, filename: ".editorconfig") == .ini)
    }

    @Test("Every language has a name for the menu")
    func names() {
        #expect(SourceLanguage.allCases.first == .plainText)
        #expect(SourceLanguage.cPlusPlus.displayName == "C++")
        #expect(SourceLanguage.allCases.allSatisfy { !$0.displayName.isEmpty })
    }

    @Test("A file's language comes from its name, or its type")
    func languages() {
        #expect(SourceLanguage(contentType: .plainText, filename: "main.cpp") == .cPlusPlus)
        #expect(SourceLanguage(contentType: .plainText, filename: "View.m") == .objectiveC)
        #expect(SourceLanguage(contentType: .plainText, filename: "config.yml") == .yaml)
        #expect(SourceLanguage(contentType: .json, filename: nil) == .json)
        #expect(SourceLanguage(contentType: .cHeader, filename: nil) == .c)
        #expect(SourceLanguage(contentType: .goSource, filename: nil) == .go)
        #expect(SourceLanguage(contentType: .mpeg2TransportStream, filename: "app.ts") == .typeScript)
        #expect(SourceLanguage(contentType: .plainText, filename: "run.sh") == .shell)
        #expect(SourceLanguage(contentType: .pythonScript, filename: nil) == .python)
        #expect(SourceLanguage(contentType: .plainText, filename: "init.lua") == .lua)
        #expect(SourceLanguage(contentType: .plainText, filename: "main.dart") == .dart)
        #expect(SourceLanguage(contentType: .plainText, filename: "App.scala") == .scala)
        #expect(SourceLanguage(contentType: .plainText, filename: "build.pl") == .perl)
        #expect(SourceLanguage(contentType: .perlScript, filename: nil) == .perl)
        #expect(SourceLanguage(contentType: .plainText, filename: "plot.R") == .r)
        #expect(SourceLanguage(contentType: .plainText, filename: "main.zig") == .zig)
        #expect(SourceLanguage(contentType: .plainText, filename: "mix.exs") == .elixir)
        #expect(SourceLanguage(contentType: .plainText, filename: "Main.hs") == .haskell)
        #expect(SourceLanguage(contentType: .plainText, filename: "schema.graphql") == .graphQL)
        #expect(SourceLanguage(contentType: .plainText, filename: "notes.txt") == .plainText)
        #expect(SourceLanguage(contentType: .plainText, filename: "NOTES.TXT") == .plainText)
        #expect(SourceLanguage(contentType: .plainText, filename: nil) == .plainText)
        #expect(SourceLanguage(contentType: .markdownDocument, filename: "README.md") == nil)
        #expect(SourceLanguage(contentType: .markdownDocument, filename: nil) == nil)
        #expect(SourceLanguage(contentType: .openXMLDocument, filename: nil) == nil)
    }

    @Test("Colouring changes only colours, so the text reads back the same")
    func applying() {
        let text = NSMutableAttributedString(string: "let x = 1 // c", attributes: [.foregroundColor: UIColor.black])
        SyntaxHighlighter.apply(.swift, to: text, scheme: .light, plainColor: .black)
        let keyword = text.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor
        let plain = text.attribute(.foregroundColor, at: 4, effectiveRange: nil) as? UIColor
        #expect(keyword == SyntaxHighlighter.color(for: .keyword, scheme: .light))
        #expect(plain == .black)
        #expect(text.string == "let x = 1 // c")

        SyntaxHighlighter.apply(.plainText, to: text, scheme: .light, plainColor: .black)
        #expect(SyntaxHighlighter.tokens(in: text.string, language: .plainText).isEmpty)
        text.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: text.length)) { color, _, _ in
            #expect(color as? UIColor == .black)
        }
        #expect(text.string == "let x = 1 // c")
    }

    // MARK: - Edits

    /// A little of each language, with what spans lines in it.
    private static let samples: [SourceLanguage: String] = [
        .swift: """
            @MainActor final class View { // note
                let name: String = "a \\"b\\""
                /* block
                   comment */ var count = 42
                let text = \"""
                    many \\(name)
                    lines
                    \"""
            #if DEBUG
            }
            """,
        .python: "def f(x):\n    '''doc\n    string'''\n    s = \"\"\"a\nb\"\"\"\n    return x.def  # done\n@decorator\nclass A: pass\n",
        .javaScript: "/* a\n b */ const s = `x\n${y}`\nfunction f() { return 'q' // c\n}\n",
        .typeScript: "interface A { b: number }\nconst s = `x\ny` /* c\n */ @dec class B {}\n",
        .shell: "if [ -n \"$HOME\n\" ]; then echo ${#ARR} $1 # done\nfi\nx='a\nb' set -e\n",
        .c: "#include <stdio.h>\n/* multi\n line */ static int count = 0; // c\nchar *s = \"a\\\"b\";\n",
        .cPlusPlus: "namespace a {\n/* c */ template <typename T> class B {};\n}\n",
        .objectiveC: "@interface View : NSObject\n@property (nonatomic) BOOL on; /* x\n */\n@end\n",
        .cSharp: "var s = \"\"\"\nraw\n\"\"\"; // c\n#region A\nclass B { int c; }\n",
        .java: "@Override public void f() { String s = \"\"\"\n  text\n  \"\"\"; /* c */ }\n",
        .kotlin: "fun f(): Int { val s = \"\"\"\nraw\\\n\"\"\" // c\nreturn 1 }\n",
        .go: "func Run(n int) string {\n\treturn `a\nb` /* c\n */\n}\n",
        .rust: "fn first<'a>(s: &'a str) -> Option<u8> { let t = \"a\nb\"; /* c */ None }\n",
        .ruby: "def f\n  @name = $global # c\n  'a'\nend\n",
        .php: "<?php\n$name = 'a\nb'; // one\n# two\n/* three\n */ echo \"$name\";\n",
        .sql: "SELECT name FROM users /* a\n b */ where id = 1 -- first\nINSERT INTO t VALUES ('x');\n",
        .json: "{\"name\" : \"Libretto\", // c\n \"open\": true, /* x\n */\n 'count': 3}\n",
        .yaml: "name: Libretto # app\nurl: http://example.com\nshared: yes\nlist:\n  - 'a'\n",
        .html: """
            <!-- c
             d --><a href="x
            y" hidden>&amp;</a>
            <script>let n = 1 /* x
            */ let s = `a
            b`</script><style>p {
             color: red }</style>
            <p class=x>text</p>
            """,
        .css: "@media screen {\n  .card > h1:hover,\n  a { margin: -4px 1.5em; /* c\n */ color: #fff !important; }\n}\np\n{ content: \"a\" }\n",
        .xml: "<?xml version=\"1.0\"?>\n<!-- c\n d --><plist><dict>\n<key a='x\ny'>Name</key><![CDATA[a\n<b>]]>\n<script>let a = 1</script></dict>\n",
        .scss: "$size: 4px; // c\n.card { &:hover { margin: #{$size} } /* x\n */ }\n%base { color: red }\n",
        .less: "@size: 4px; // c\n@media screen { .card { margin: @size; } }\n.a-@{name} { color: #fff /* x\n */ }\n",
        .toml: "[server] # c\nname = \"Libretto\"\ntext = \"\"\"\nmany\nlines\"\"\"\n[[bin]]\nports = [ [1, 2], [3] ]\npath = '''a\nb'''\n",
        .ini: "; c\n[core]\nname = Libretto\nexport HOME=$HOME:/bin\nurl: \"http://x\" # not\n! bang\n",
        .dockerfile: "FROM swift:6 AS build # c\nRUN apt-get update \\\n  && echo \"$HOME\n\"\nCOPY . /app\n",
        .makefile: ".PHONY: all\nSRC := $(wildcard *.c) # c\nall: $(SRC)\n\tcc -o $@ $^ \"a\nb\"\n-include deps.mk\nx ?= 1\n",
        .lua: "--[[ block\n comment ]] local s = [[long\nstring]] -- c\nfunction f() return 'a' end\n",
        .dart: "@override\nString f() => '''a\nb''' /* c\n */ + \"x\"; // d\n",
        .scala: "@main def run(): Unit = { val s = \"\"\"raw\\\nline\"\"\" /* c\n */ }\n",
        .perl: "my %h = (a => 1); # c\nmy @list = `ls`;\nprint \"$name\n\";\n",
        .r: "f <- function(x) { `odd name` + 'a\n' } # c\nTRUE\n",
        .zig: "const std = @import(\"std\"); // c\npub fn main() u8 { return 'a'; }\n",
        .elixir: "defmodule A do\n  @doc \"\"\"\n  many\n  \"\"\" # c\n  def f, do: :ok\nend\n",
        .haskell: "{- block\n comment -} main :: IO () -- c\nmain = foldl' f 0 \"a\"\n",
        .graphQL: "\"\"\"\ndoc\n\"\"\" type Query @key { user(id: $id): User } # c\n",
        .diff: "diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1,3 +1,3 @@ f\n x\n--- y\n+++ z\n\\ No newline at end of file\n w\n",
    ]

    /// Pieces that open and close what spans lines, and the rest.
    private static let fragments = [
        "/*", "*/", "\"", "\"\"\"", "'''", "'", "`", "\n", "\n", "\r\n", "\u{2028}", "\\", "#", "//", "--", "<!--", "-->",
        "<script>", "</script>", "<style>", "</style>", "<", ">", "{", "}", ";", ":", "$", "${", "@", "&amp;", "=",
        "let", "class", "x", "42", " ", "\t", "é", "", "", "",
    ]

    /// Pieces of diffs: what starts their lines, and hunks' headers, whose counts the lines after them depend on.
    private static let diffFragments = [
        "\n", "\n", "\r\n", "+", "-", " ", "\\", "@@ -1,2 +1,3 @@", "@@ -1 +1 @@", "@@ ", " @@", ",", "2", "--- a", "x", "",
    ]

    /// Edits `text` at random, checking after each edit that what was found
    /// again around it is what a scan of the whole text finds.
    private func checkEdits(
        _ text: String, _ language: SourceLanguage, count: Int, seed: UInt64,
        fragments: [String] = SyntaxHighlighterTests.fragments
    ) {
        var random = SeededRandom(seed)
        let text = NSMutableString(string: text)
        var highlights = SyntaxHighlights(text as String, language: language)
        for step in 0..<count {
            // Now and then at the end, which what runs to the end depends on.
            let atEnd = Int.random(in: 0..<10, using: &random) == 0
            let location = atEnd ? text.length : Int.random(in: 0...text.length, using: &random)
            let longest = Int.random(in: 0..<8, using: &random) == 0 ? 40 : 3
            let removed = min(Int.random(in: 0...longest, using: &random), text.length - location)
            let inserted = fragments.randomElement(using: &random)!
            let before = text.substring(with: NSRange(location: location, length: removed))
            text.replaceCharacters(in: NSRange(location: location, length: removed), with: inserted)
            let length = (inserted as NSString).length
            _ = highlights.update(
                text as String, edited: NSRange(location: location, length: length), changeInLength: length - removed
            )
            let expected = SyntaxHighlights(text as String, language: language).tokens
            #expect(
                highlights.tokens == expected,
                "\(language), edit \(step): \(before.debugDescription) at \(location) became \(inserted.debugDescription)"
            )
            guard highlights.tokens == expected else { return }
        }
    }

    @Test("Scanning again around an edit finds what scanning the whole text does", arguments: SourceLanguage.allCases)
    func edits(language: SourceLanguage) {
        let sample = Self.samples[language] ?? "plain text\nand more"
        // Many lines, so that edits fall far from each end.
        let text = Array(repeating: sample, count: 6).joined(separator: "\n")
        for seed in 1...8 {
            checkEdits(text, language, count: 150, seed: UInt64(seed * 7919 + language.rawValue.utf16.count))
        }
    }

    @Test("Editing a diff's hunks and their headers")
    func diffEdits() {
        let text = Array(repeating: Self.samples[.diff]!, count: 6).joined(separator: "\n")
        for seed in 1...8 {
            checkEdits(text, .diff, count: 150, seed: UInt64(seed * 104_729), fragments: Self.diffFragments)
        }
    }

    @Test("Opening and closing block comments and strings that span lines")
    func spanningEdits() {
        let cases: [(SourceLanguage, String, [(String, String)])] = [
            (.swift, "let a = 1\nlet b = \"x\"\nlet c = 3\nlet d = 4\n", [
                ("let b", "/* let b"), ("let d", "*/ let d"), ("/* ", ""), ("*/ ", ""),
                ("let b", "\"\"\"\nlet b"), ("let d", "\"\"\"\nlet d"), ("\"\"\"\nlet b", "let b"),
            ]),
            (.python, "x = 1\ny = 'a'\nz = 2\n", [("y", "'''y"), ("z = 2", "z = 2'''"), ("'''y", "y")]),
            (.javaScript, "let a = 1\nlet b = 2\nlet c = 3\n", [("let b", "`let b"), ("let c", "`let c"), ("`let b", "let b")]),
            (.html, "<p>a</p>\n<p>b</p>\n<p>c</p>\n<p>d</p>\n", [
                ("<p>b</p>", "<script>let x = 1\n"), ("<p>d</p>", "</script><p>d</p>"),
                ("<script>", "<style>"), ("</script>", "</style>"), ("let x", "/* let x"), ("<style>", ""),
                ("<p>a", "<!-- <p>a"), ("<p>c", "--> <p>c"),
            ]),
            (.css, "a { color: red }\nb { color: blue }\nc { margin: 0 }\n", [
                ("b {", "b"), ("c {", "/* c {"), ("margin", "*/ margin"), ("b", "b {"),
            ]),
        ]
        for (language, start, edits) in cases {
            let text = NSMutableString(string: start)
            var highlights = SyntaxHighlights(start, language: language)
            for (old, new) in edits {
                let range = text.range(of: old)
                #expect(range.location != NSNotFound)
                text.replaceCharacters(in: range, with: new)
                let length = (new as NSString).length
                let changed = highlights.update(
                    text as String, edited: NSRange(location: range.location, length: length),
                    changeInLength: length - range.length
                )
                #expect(changed.text.location <= range.location && NSMaxRange(changed.text) >= range.location + length)
                #expect(
                    highlights.tokens == SyntaxHighlights(text as String, language: language).tokens,
                    "\(language): \(old.debugDescription) became \(new.debugDescription)"
                )
            }
        }
    }

    @Test("Text added at the end changes what ran to the end, across lines")
    func editsAtTheEnd() {
        // A selector with no block after it is one only until a declaration's end follows.
        let cases: [(SourceLanguage, String, String)] = [
            (.css, "a\nb", ";"), (.css, "a\nb", " {"), (.css, "a {\n b\n c", ": red"), (.yaml, "a:\nname:", "x"),
            (.swift, "let a = 1\n/* b\nc", " */"), (.html, "<p>\n<script>\nlet a", "</script>"),
        ]
        for (language, start, added) in cases {
            let text = NSMutableString(string: start)
            var highlights = SyntaxHighlights(start, language: language)
            let length = (added as NSString).length
            text.append(added)
            _ = highlights.update(text as String, edited: NSRange(location: text.length - length, length: length), changeInLength: length)
            #expect(highlights.tokens == SyntaxHighlights(text as String, language: language).tokens, "\(language): \(added)")
            text.deleteCharacters(in: NSRange(location: text.length - length, length: length))
            _ = highlights.update(text as String, edited: NSRange(location: text.length, length: 0), changeInLength: -length)
            #expect(highlights.tokens == SyntaxHighlights(text as String, language: language).tokens, "\(language): \(added)")
        }
    }

    @Test("An edit is scanned again only as far as the lines around it")
    func editsStayLocal() {
        let lines = (0..<2000).map { "let value\($0) = \"\($0)\" // \($0)" }
        let text = NSMutableString(string: lines.joined(separator: "\n"))
        var highlights = SyntaxHighlights(text as String, language: .swift)
        let location = text.range(of: "value1000").location
        text.insert("x", at: location)
        let changed = highlights.update(text as String, edited: NSRange(location: location, length: 1), changeInLength: 1)
        #expect(changed.text.length < 200)
        #expect(changed.tokens.count < 10)
        #expect(highlights.tokens == SyntaxHighlights(text as String, language: .swift).tokens)

        // Opening a comment colours the rest of the text, and closing it colours the rest back.
        text.insert("/*", at: location)
        let opened = highlights.update(text as String, edited: NSRange(location: location, length: 2), changeInLength: 2)
        #expect(NSMaxRange(opened.text) == text.length)
        let end = text.range(of: "value1001").location
        text.insert("*/", at: end)
        let closed = highlights.update(text as String, edited: NSRange(location: end, length: 2), changeInLength: 2)
        #expect(NSMaxRange(closed.text) == text.length)
        #expect(highlights.tokens == SyntaxHighlights(text as String, language: .swift).tokens)
    }

    @Test("Colouring after edits colours the text as colouring it whole does")
    func coloringEdits() {
        for language in [SourceLanguage.swift, .html, .css, .python] {
            let sample = Array(repeating: Self.samples[language]!, count: 4).joined(separator: "\n")
            let text = NSMutableAttributedString(string: sample, attributes: [.foregroundColor: UIColor.black])
            var coloring = SyntaxColoring()
            coloring.apply(language, to: text, scheme: .light, plainColor: .black)
            var random = SeededRandom(UInt64(sample.utf16.count))
            for step in 0..<120 {
                // Sometimes two edits between colourings, as a replacement makes.
                for _ in 0..<(step % 5 == 0 ? 2 : 1) {
                    let location = Int.random(in: 0...text.length, using: &random)
                    let removed = min(Int.random(in: 0...3, using: &random), text.length - location)
                    let inserted = Self.fragments.randomElement(using: &random)!
                    text.replaceCharacters(in: NSRange(location: location, length: removed), with: inserted)
                    let length = (inserted as NSString).length
                    coloring.noteEdit(NSRange(location: location, length: length), changeInLength: length - removed)
                }
                coloring.apply(language, to: text, scheme: .light, plainColor: .black)
                let whole = NSMutableAttributedString(attributedString: text)
                SyntaxHighlighter.apply(language, to: whole, scheme: .light, plainColor: .black)
                #expect(colors(of: text) == colors(of: whole), "\(language), edit \(step)")
            }
            // A new scheme colours the whole text again.
            coloring.noteEdit(NSRange(location: 0, length: 0), changeInLength: 0)
            coloring.apply(language, to: text, scheme: .dark, plainColor: .white)
            let whole = NSMutableAttributedString(attributedString: text)
            SyntaxHighlighter.apply(language, to: whole, scheme: .dark, plainColor: .white)
            #expect(colors(of: text) == colors(of: whole))
        }
    }

    @Test("Colouring with nothing edited since leaves the text alone, until the scheme changes")
    func coloringWithoutEdits() {
        let sample = Array(repeating: Self.samples[.swift]!, count: 4).joined(separator: "\n")
        let text = NSMutableAttributedString(string: sample, attributes: [.foregroundColor: UIColor.black])
        var coloring = SyntaxColoring()
        coloring.apply(.swift, to: text, scheme: .light, plainColor: .black)
        let colored = colors(of: text)

        // A keyboard committing what it composed says the text changed when its characters did not:
        // the colouring is not scanned or set again. A colour it was not told of shows it was left alone.
        let marked = NSRange(location: 0, length: 3)
        text.addAttribute(.foregroundColor, value: UIColor.green, range: marked)
        coloring.apply(.swift, to: text, scheme: .light, plainColor: .black)
        #expect(text.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor == .green)

        text.addAttribute(.foregroundColor, value: SyntaxHighlighter.color(for: .attribute, scheme: .light), range: marked)
        #expect(colors(of: text) == colored)
        coloring.apply(.swift, to: text, scheme: .dark, plainColor: .white)
        let whole = NSMutableAttributedString(attributedString: text)
        SyntaxHighlighter.apply(.swift, to: whole, scheme: .dark, plainColor: .white)
        #expect(colors(of: text) == colors(of: whole))
    }

    /// The text's colours, run by run.
    private func colors(of text: NSAttributedString) -> [String] {
        var runs: [String] = []
        text.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: text.length)) { color, range, _ in
            runs.append("\(range.location) \(range.length) \((color as? UIColor)?.description ?? "none")")
        }
        return runs
    }

    @Test("Typing in a large file scans a few lines, not the whole file")
    func largeFile() {
        let chunk = """
            /// A view of the document, as the reader sees it.
            @MainActor final class DocumentView<Content: View>: UIView {
                private var pages: [Page] = []
                let title = "Libretto \\(version)"
                /* The margins, in points,
                   around each page. */
                var margins = UIEdgeInsets(top: 72, left: 54, bottom: 72, right: 54)

                func layout(_ width: CGFloat) -> CGFloat {
                    let help = \"""
                        Pinch to zoom.
                        \"""
                    return pages.reduce(0) { $0 + $1.height(for: width) } // total
                }
            }

            """
        let source = String(repeating: chunk, count: 1500)
        let storage = NSTextStorage(string: source, attributes: [.foregroundColor: UIColor.label])
        let clock = ContinuousClock()
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).count

        var coloring = SyntaxColoring()
        coloring.apply(.swift, to: storage, scheme: .light, plainColor: .label)
        var random = SeededRandom(28)
        var full = Duration.zero
        var incremental = Duration.zero
        let keystrokes = 20
        for _ in 0..<keystrokes {
            let location = Int.random(in: 0...storage.length, using: &random)
            storage.replaceCharacters(in: NSRange(location: location, length: 0), with: "a")
            coloring.noteEdit(NSRange(location: location, length: 1), changeInLength: 1)
            incremental += clock.measure {
                coloring.apply(.swift, to: storage, scheme: .light, plainColor: .label)
            }
            let whole = NSTextStorage(attributedString: storage)
            SyntaxHighlighter.apply(.swift, to: whole, scheme: .light, plainColor: .label)
            #expect(colors(of: storage) == colors(of: whole))
            // As the editor coloured before: the whole file again, though little of it changes colour.
            full += clock.measure {
                SyntaxHighlighter.apply(.swift, to: storage, scheme: .light, plainColor: .label)
            }
        }
        let fullTime = full / keystrokes
        let incrementalTime = incremental / keystrokes
        print("Colouring \(lines) lines (\(storage.length) units) per keystroke: whole file \(fullTime), around the edit \(incrementalTime)")
        #expect(incrementalTime * 4 < fullTime)
    }
}

/// The same numbers every run, so a failing edit can be found again.
private struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64

    init(_ seed: UInt64) {
        state = seed
    }

    /// SplitMix64.
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

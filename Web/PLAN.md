# Plan: Libretto for the web (WebAssembly + offline PWA)

## Goal

Ship Libretto as an installable Progressive Web App that runs **entirely on the device**: after the first visit it opens, edits and saves Word documents, Markdown, plain text and source code, and opens Pages documents, with no network connection and no server. The engine is the same Swift code the Apple apps use, compiled to WebAssembly, so the file formats behave identically on every platform.

Constraints, as for Tables: **no Node packages** (the build is Swift and a shell script; the page is plain HTML, CSS and JavaScript modules), and **the web build reads nothing from `Apple/`** (its catalogue only borrows the Apple apps' translations when it is written).

## Where things stand

The base app works end to end: start screen, new documents and text files, opening `.docx`, `.docm`, `.pages`, Markdown, plain text and source code, typing, paragraphs split and joined, character formatting (bold, italic, underline, strikethrough, size, font, colour, highlight, baseline), paragraph styles, alignment, spacing, lists and indents, tables (insert, rows and columns, header rows, delete), pictures, page breaks, find and replace, accepting and rejecting tracked changes, page size, orientation and margins, pages with headers, footers and page numbers, zoom, printing, undo and redo, saving and exporting in every format the document can be saved in, autosave and Open Recent, light and dark, five languages, and an installable PWA whose service worker serves every file offline.

| Part | Where | Notes |
| --- | --- | --- |
| Engine | `Engine/` (Swift package) | Shared by the Xcode project (compiled in place) and the web build. Model and file formats build for WebAssembly; the Apple layout and drawing (TextKit, Core Text, PDF) is compiled only on Apple platforms. All 278 Apple engine tests pass after the port |
| WebAssembly interface | `Web/engine/` | C exports with JSON requests, a WASI host, the worker, a strings tool, Node smoke tests |
| Window | `Web/app/` | Pages, code editor, menus, toolbar, inspector, find bar, files, storage |
| Design system | `Web/design/` | Tables' tokens, components, menus and lint, in Libretto's blue, with pages and a code editor |

### What porting the engine took

| Problem | Fix |
| --- | --- |
| `Compression` (ZIP deflate) | Tables' plain-Swift raw DEFLATE (`Engine/LibrettoEngine/Portable/RawDeflate.swift`) |
| SwiftUI `Color` and `ColorScheme` in `AdaptiveColor` | Stand-ins where SwiftUI doesn't exist; `argbHex` reads the components back |
| `UniformTypeIdentifiers` in `DocumentFile`, `SourceLanguage`, `IWorkArchive` | Kept on Apple platforms; a format by file name (`DocumentFile.Format`, `SourceLanguage(filename:)`) everywhere |
| Core Text font lookups and ImageIO in the Pages reader and writer | Apple-only; elsewhere fonts are taken apart by PostScript name, as for uninstalled fonts, and only PNG and JPEG pictures are kept |
| Core Graphics colour conversion in the Pages '09 reader | Apple-only; calibrated colours are read as they are |
| `XMLParser` (in `FoundationXML`) | Conditional import |
| String catalogues and `Bundle(for:)` | A bundle on Apple platforms; elsewhere a string table the host loads, converted from the same catalogue |
| Word breaking (`.byWords`) for the word count | Runs of letters and digits, each Chinese or Japanese character a word of its own |
| Guessing a text file's older encoding (`NSString.stringEncoding`) | The first of Shift JIS, EUC-JP and Windows-1252 that reads |
| List numbering, special characters and highlight colours lived in the Apple renderers | Moved into the model (`ListCounter`, `TextCharacters`, `RunStyle.highlightColors`); the syntax highlighter's scanner is portable and only its colouring Apple-only |

## Architecture

```
┌─────────────────────────── Browser tab / installed app window ───────────────────────────┐
│ Main thread (plain JavaScript modules)                                                   │
│   app/window.js   menu bar · toolbar · find bar · status bar · inspector · start screen  │
│   app/pages.js    blocks drawn editable over pages · pagination · reading edits back     │
│   app/code.js     plain text and source code, coloured by the engine                     │
│   app/files.js · app/storage.js   File System Access / picker / download · autosave      │
│             ▲  JSON requests + transferable bytes                                         │
│             ▼                                                                            │
│ Engine worker (engine/worker.js)                                                         │
│   libretto-engine.wasm: Engine/LibrettoEngine + engine/swift/Sources/LibrettoWasm        │
│   engine/wasi.js: clocks, randomness, console; no file system, no network                │
├──────────────────────────────────────────────────────────────────────────────────────────┤
│ Service worker (sw.js): caches every file listed in build/version.json at install and    │
│ answers every request from that cache. New builds download only from the Update button.  │
└──────────────────────────────────────────────────────────────────────────────────────────┘
```

Decisions as built:

1. **One engine, in Swift.** `Engine/` is a Swift package. Xcode compiles its folder in place; the web build depends on it with `.package(path: "../../../Engine")`.
2. **A plain C interface, no JavaScriptKit.** `libretto_alloc`, `libretto_free`, `libretto_call` and response accessors; JSON requests, files as raw bytes.
3. **The model is edited in Swift; the browser types.** Where Tables draws its grid itself, a word processor's text is the browser's to lay out and edit: the page is `contenteditable`, and Swift reads back what changed, as `AttributedReader` reads back the Apple text views. Formatting, styles, lists and tables are changed in Swift on the selection, given as paragraph IDs and offsets, and drawn again.
4. **Pages are laid out a block at a time.** A paragraph that would cross the foot of a page moves to the next, and a table breaks between rows; a paragraph taller than a page runs on over the gap.
5. **No framework, no bundler.** ES modules served as they are; the design lint runs over all of it.
6. **Strings come from catalogues.** `Web/strings/Localizable.xcstrings` (its strings shared with the Apple apps' catalogues) plus the engine's are converted to per-language JSON at build time.

## Next

### Fidelity

- [ ] Break a paragraph across pages by line, rather than moving it whole or letting it run over the gap; keep with next and widow control.
- [ ] Repeat table header rows on each page a table runs on to.
- [ ] Tab stops at their positions and alignments (now one tab width from the first stop), drop caps, columns.
- [ ] Equations drawn (now their linear form), shapes, charts and SmartArt drawn (now a box with their text), floating pictures placed where they are anchored.
- [ ] Footnotes and endnotes at the foot of the page and the end.
- [ ] EMF and WMF pictures.

### Editing parity with the Apple apps

1. Tracked changes while typing (typing with Track Changes on isn't marked yet), accepting and rejecting one at a time.
2. Comments: adding, replying, resolving and deleting, and their ranges highlighted.
3. Links, headers and footers, notes, fields, cross references, symbols, equations and the style editor.
4. Table cells merged and split, shading, borders and styles; picture size, crop and wrap.
5. Rich paste from other apps and copying with formatting.
6. The code editor's comment toggling and indentation menu.

### Engine quality

- [ ] Run the engine test suite under WASI (`Apple/LibrettoTests` mostly needs only `LibrettoEngine`).
- [ ] **Size.** The release module is 57 MB (about 20 MB gzipped), mostly ICU data Foundation links. As for Tables: `wasm-opt -Oz`, `FoundationEssentials`, or trimmed ICU data.
- [ ] Older text encodings: Foundation on WebAssembly may not read Shift JIS or EUC-JP; decode them in the page with `TextDecoder` if so.

### Release

- [ ] Browser tests in Chromium, WebKit and Firefox through WebDriver.
- [ ] Accessibility passes with VoiceOver and keyboard only.
- [ ] A social sharing picture, as Tables has.

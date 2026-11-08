# Libretto

Word processor that opens and saves Word documents, Markdown, plain text, and source code, and opens Pages documents to share as Word documents.

- **Libretto** is the iOS and iPadOS app, in `Apple/Libretto`.
- **Libretto for Mac** is the native AppKit app, in `Apple/LibrettoMac`.
- **LibrettoEngine** (`com.tsubuzaki.Libretto.Engine`) is the framework both build on: the document model, reading and writing every file format, and laying documents out in pages and drawing them, in `Engine/LibrettoEngine`.
- **Libretto for the web** is the offline web app, with the engine compiled to WebAssembly, in `Web`. See [Web/README.md](Web/README.md) and [Web/PLAN.md](Web/PLAN.md).

The engine is a Swift package (`Engine/Package.swift`) that the Xcode project, `Apple/Libretto.xcodeproj`, compiles in place, and the web build depends on.

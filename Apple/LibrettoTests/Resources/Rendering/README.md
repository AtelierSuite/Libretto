# Rendering fixtures

Small Word documents that `RenderingTests` (`LibrettoTests/RenderingTests.swift`)
draws page by page, as the PDF export draws them, and compares with the
reference images in `References/<platform>/<document>/page-N.png`. A page that
differs in more than 0.1% of its pixels, or a different number of pages, fails
the test; what was drawn and a picture of where it differs (the reference
faded, differing pixels in red) are written to a folder the failure names.

The documents are written by `make_fixtures.py`, one function per document, so
each one's XML is in plain view and needs nothing installed but Python 3.

## Adding a document for a rendering change

1. Add a function to `make_fixtures.py` that returns the body XML, the final
   `<w:sectPr>` and any pictures (`png(...)` makes a plain one), and add it to
   `FIXTURES` under a short name, such as `"columns"`. Use fonts every Apple
   platform has (Georgia, Helvetica, Times New Roman…), keep it to a page or
   two, and let it exercise just the feature. A document saved from Word works
   as well: put the `.docx` here under the same kind of name.
2. Run `python3 make_fixtures.py` here.
3. Make the change that draws it right, then record its references from the
   iOS simulator (Xcode passes `TEST_RUNNER_`-prefixed variables to the tests):

   ```sh
   cd Apple
   TEST_RUNNER_LIBRETTO_RECORD_REFERENCES=1 xcodebuild test -project Libretto.xcodeproj \
     -scheme Libretto -destination 'id=<simulator>' -only-testing:LibrettoTests/RenderingTests
   ```

   Recording rewrites every document's references, so check with
   `git status` that only the new document's and those your change meant to
   alter have changed. A document with no references at all is recorded on
   its first run too, and that run fails to say so.
4. Look at each new `page-N.png` (compare with Word or Pages where you can)
   before committing it with the document.

When a change is meant to alter how an existing document is drawn, record
again and commit the new references with the change, so the review shows
the before and after.

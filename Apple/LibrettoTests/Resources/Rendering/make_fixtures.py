"""Writes the small Word documents RenderingTests draws and compares with
reference images. Each fixture is a function below that returns the body of
word/document.xml (and any pictures); run `python3 make_fixtures.py` to
rewrite every .docx in this folder. See README.md beside it."""
import os, struct, zipfile, zlib

HERE = os.path.dirname(os.path.abspath(__file__))

W = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
R = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
WP = "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"
A = "http://schemas.openxmlformats.org/drawingml/2006/main"
PIC = "http://schemas.openxmlformats.org/drawingml/2006/picture"
REL = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

# Fonts every iOS and macOS install has, so the references don't depend on
# what happens to be installed.
STYLES = f"""<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:styles xmlns:w="{W}"><w:docDefaults><w:rPrDefault><w:rPr>\
<w:rFonts w:ascii="Georgia" w:hAnsi="Georgia" w:cs="Georgia"/><w:sz w:val="22"/></w:rPr></w:rPrDefault>\
<w:pPrDefault><w:pPr><w:spacing w:after="160" w:line="259" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults>\
<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/></w:style>\
<w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/>\
<w:next w:val="Normal"/><w:pPr><w:keepNext/><w:spacing w:before="240"/><w:outlineLvl w:val="0"/></w:pPr>\
<w:rPr><w:rFonts w:ascii="Helvetica" w:hAnsi="Helvetica"/><w:b/><w:color w:val="1F3864"/><w:sz w:val="32"/></w:rPr></w:style>\
<w:style w:type="paragraph" w:styleId="ListParagraph"><w:name w:val="List Paragraph"/><w:basedOn w:val="Normal"/>\
<w:pPr><w:ind w:left="720"/></w:pPr></w:style>\
<w:style w:type="table" w:styleId="TableGrid"><w:name w:val="Table Grid"/><w:tblPr><w:tblBorders>\
<w:top w:val="single" w:sz="4" w:space="0" w:color="auto"/><w:left w:val="single" w:sz="4" w:space="0" w:color="auto"/>\
<w:bottom w:val="single" w:sz="4" w:space="0" w:color="auto"/><w:right w:val="single" w:sz="4" w:space="0" w:color="auto"/>\
<w:insideH w:val="single" w:sz="4" w:space="0" w:color="auto"/><w:insideV w:val="single" w:sz="4" w:space="0" w:color="auto"/>\
</w:tblBorders></w:tblPr></w:style></w:styles>"""

NUMBERING = f"""<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:numbering xmlns:w="{W}"><w:abstractNum w:abstractNumId="0">\
<w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="decimal"/><w:lvlText w:val="%1."/>\
<w:pPr><w:ind w:left="720" w:hanging="360"/></w:pPr></w:lvl></w:abstractNum>\
<w:abstractNum w:abstractNumId="1"><w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="bullet"/>\
<w:lvlText w:val="•"/><w:pPr><w:ind w:left="720" w:hanging="360"/></w:pPr></w:lvl></w:abstractNum>\
<w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num><w:num w:numId="2"><w:abstractNumId w:val="1"/></w:num></w:numbering>"""

LOREM = ("Libretto lays this paragraph out in lines and pages, and the test compares what it draws "
         "with the picture kept beside it. A change that moves a line, drops a picture or breaks a "
         "page somewhere new shows up as pixels that differ.")

LETTER = '<w:pgSz w:w="12240" w:h="15840"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" ' \
         'w:left="1440" w:header="720" w:footer="720" w:gutter="0"/>'


def p(text, style=None, props="", run_props=""):
    ppr = (f'<w:pStyle w:val="{style}"/>' if style else "") + props
    return (f'<w:p>{"<w:pPr>" + ppr + "</w:pPr>" if ppr else ""}'
            f'<w:r>{"<w:rPr>" + run_props + "</w:rPr>" if run_props else ""}'
            f'<w:t xml:space="preserve">{text}</w:t></w:r></w:p>')


def runs(*pieces):
    """A paragraph of runs, each (text, run properties)."""
    return "<w:p>" + "".join(
        f'<w:r>{"<w:rPr>" + props + "</w:rPr>" if props else ""}<w:t xml:space="preserve">{text}</w:t></w:r>'
        for text, props in pieces) + "</w:p>"


def png(width, height, colour):
    """A plain picture of one colour, with a darker band across it, so its edges and placement show."""
    r, g, b = colour
    rows = b""
    for y in range(height):
        band = height // 3 <= y < 2 * height // 3
        pixel = bytes((r // 2, g // 2, b // 2)) if band else bytes((r, g, b))
        rows += b"\x00" + pixel * width
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


# Fixtures. Each returns (body XML, final section XML, {media name: bytes}).

def text():
    body = (p("Text and lists", "Heading1")
            + runs(("Plain, ", ""), ("bold, ", "<w:b/>"), ("italic, ", "<w:i/>"),
                   ("underlined, ", '<w:u w:val="single"/>'), ("red, ", '<w:color w:val="C00000"/>'),
                   ("highlighted", '<w:highlight w:val="yellow"/>'), (" and larger.", '<w:sz w:val="32"/>'))
            + p(LOREM, props='<w:jc w:val="both"/>')
            + p("Centred.", props='<w:jc w:val="center"/>')
            + p("To the right.", props='<w:jc w:val="right"/>')
            + p("First numbered item", "ListParagraph", '<w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr>')
            + p("Second numbered item", "ListParagraph", '<w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr>')
            + p("A bullet", "ListParagraph", '<w:numPr><w:ilvl w:val="0"/><w:numId w:val="2"/></w:numPr>')
            + p("Indented and shaded, with a border.",
                props='<w:pBdr><w:left w:val="single" w:sz="24" w:space="4" w:color="2F5496"/></w:pBdr>'
                      '<w:shd w:val="clear" w:color="auto" w:fill="DEEAF6"/><w:ind w:left="720" w:right="720"/>')
            + p("In Helvetica.", run_props='<w:rFonts w:ascii="Helvetica" w:hAnsi="Helvetica"/>'))
    return body, f"<w:sectPr>{LETTER}</w:sectPr>", {}


def table():
    def cell(text, width, extra=""):
        return f'<w:tc><w:tcPr><w:tcW w:w="{width}" w:type="dxa"/>{extra}</w:tcPr>{p(text)}</w:tc>'
    restart, merged, span = '<w:vMerge w:val="restart"/>', '<w:vMerge/>', '<w:gridSpan w:val="2"/>'
    shade = '<w:shd w:val="clear" w:color="auto" w:fill="D9E2F3"/>'
    rows = (f'<w:tr><w:trPr><w:tblHeader/></w:trPr>{cell("Region", 3000, shade)}{cell("Quarter", 3000, shade)}'
            f'{cell("Total", 3000, shade)}</w:tr>'
            f'<w:tr>{cell("North", 3000, restart)}{cell("First", 3000)}{cell("1,200", 3000)}</w:tr>'
            f'<w:tr>{cell("", 3000, merged)}{cell("Second", 3000)}{cell("1,450", 3000)}</w:tr>'
            f'<w:tr>{cell("Across two columns", 6000, span)}{cell("2,650", 3000)}</w:tr>')
    body = (p("A table", "Heading1") + p("Before the table.")
            + '<w:tbl><w:tblPr><w:tblStyle w:val="TableGrid"/><w:tblW w:w="9000" w:type="dxa"/></w:tblPr>'
              '<w:tblGrid><w:gridCol w:w="3000"/><w:gridCol w:w="3000"/><w:gridCol w:w="3000"/></w:tblGrid>'
            + rows + "</w:tbl>" + p("After the table."))
    return body, f"<w:sectPr>{LETTER}</w:sectPr>", {}


def pages():
    footer = '<w:footerReference w:type="default" r:id="rIdFooter"/>'
    body = (p("First page", "Heading1") + p(LOREM)
            + '<w:p><w:r><w:br w:type="page"/></w:r></w:p>'
            + p("Second page, after a page break", "Heading1") + p(LOREM)
            + p("The end of a portrait section.",
                props=f'<w:sectPr>{footer}{LETTER}</w:sectPr>')
            + p("A landscape section", "Heading1") + p(LOREM))
    landscape = ('<w:pgSz w:w="15840" w:h="12240" w:orient="landscape"/><w:pgMar w:top="1440" w:right="1440" '
                 'w:bottom="1440" w:left="1440" w:header="720" w:footer="720" w:gutter="0"/>')
    return body, f"<w:sectPr>{footer}{landscape}</w:sectPr>", {}


def floating_picture():
    def anchor(rid, ident, align, cx, cy):
        return (f'<w:r><w:drawing><wp:anchor distT="0" distB="0" distL="114300" distR="114300" simplePos="0" '
                f'relativeHeight="1" behindDoc="0" locked="0" layoutInCell="1" allowOverlap="1">'
                f'<wp:simplePos x="0" y="0"/><wp:positionH relativeFrom="margin"><wp:align>{align}</wp:align>'
                f'</wp:positionH><wp:positionV relativeFrom="paragraph"><wp:posOffset>0</wp:posOffset></wp:positionV>'
                f'<wp:extent cx="{cx}" cy="{cy}"/><wp:effectExtent l="0" t="0" r="0" b="0"/>'
                f'<wp:wrapSquare wrapText="bothSides"/><wp:docPr id="{ident}" name="Picture {ident}"/>'
                f'<wp:cNvGraphicFramePr/><a:graphic><a:graphicData uri="{PIC}"><pic:pic>'
                f'<pic:nvPicPr><pic:cNvPr id="{ident}" name="picture{ident}.png"/><pic:cNvPicPr/></pic:nvPicPr>'
                f'<pic:blipFill><a:blip r:embed="{rid}"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>'
                f'<pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="{cx}" cy="{cy}"/></a:xfrm>'
                f'<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic>'
                f'</wp:anchor></w:drawing></w:r>')
    inline = ('<w:p><w:pPr><w:jc w:val="center"/></w:pPr><w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0">'
              '<wp:extent cx="2540000" cy="635000"/><wp:docPr id="3" name="Picture 3"/><a:graphic>'
              f'<a:graphicData uri="{PIC}"><pic:pic><pic:nvPicPr><pic:cNvPr id="3" name="picture3.png"/><pic:cNvPicPr/>'
              '</pic:nvPicPr><pic:blipFill><a:blip r:embed="rIdImage2"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>'
              '<pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="2540000" cy="635000"/></a:xfrm>'
              '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic>'
              '</wp:inline></w:drawing></w:r></w:p>')
    body = (p("Pictures", "Heading1")
            + "<w:p>" + anchor("rIdImage1", 1, "left", 1270000, 1270000)
            + f'<w:r><w:t xml:space="preserve">Square wrapping on the left. {LOREM} {LOREM}</w:t></w:r></w:p>'
            + "<w:p>" + anchor("rIdImage2", 2, "right", 1524000, 1016000)
            + f'<w:r><w:t xml:space="preserve">Square wrapping on the right. {LOREM} {LOREM}</w:t></w:r></w:p>'
            + p("An inline picture, centred:") + inline)
    media = {"image1.png": png(40, 40, (220, 120, 40)), "image2.png": png(60, 40, (60, 140, 200))}
    return body, f"<w:sectPr>{LETTER}</w:sectPr>", media


FIXTURES = {"text": text, "table": table, "pages": pages, "floating-picture": floating_picture}


def write(name, body, section, media):
    footer = (f'<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n<w:ftr xmlns:w="{W}">'
              '<w:p><w:pPr><w:jc w:val="center"/></w:pPr><w:r><w:t xml:space="preserve">Page </w:t></w:r>'
              '<w:r><w:fldChar w:fldCharType="begin"/></w:r><w:r><w:instrText>PAGE</w:instrText></w:r>'
              '<w:r><w:fldChar w:fldCharType="separate"/></w:r><w:r><w:t>1</w:t></w:r>'
              '<w:r><w:fldChar w:fldCharType="end"/></w:r></w:p></w:ftr>')
    document = (f'<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n<w:document xmlns:w="{W}" xmlns:r="{R}" '
                f'xmlns:wp="{WP}" xmlns:a="{A}" xmlns:pic="{PIC}"><w:body>{body}{section}</w:body></w:document>')
    rels = [f'<Relationship Id="rIdStyles" Type="{REL}/styles" Target="styles.xml"/>',
            f'<Relationship Id="rIdNumbering" Type="{REL}/numbering" Target="numbering.xml"/>']
    overrides = [
        '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>',
        '<Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>',
        '<Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/>']
    if "rIdFooter" in body + section:
        rels.append(f'<Relationship Id="rIdFooter" Type="{REL}/footer" Target="footer1.xml"/>')
        overrides.append('<Override PartName="/word/footer1.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.footer+xml"/>')
    for index, media_name in enumerate(sorted(media), 1):
        rels.append(f'<Relationship Id="rIdImage{index}" Type="{REL}/image" Target="media/{media_name}"/>')
    content_types = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
                     '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
                     '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
                     '<Default Extension="xml" ContentType="application/xml"/>'
                     '<Default Extension="png" ContentType="image/png"/>' + "".join(overrides) + '</Types>')
    package_rels = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
                    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
                    f'<Relationship Id="rId1" Type="{REL}/officeDocument" Target="word/document.xml"/></Relationships>')
    document_rels = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
                     '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
                     + "".join(rels) + '</Relationships>')
    path = os.path.join(HERE, name + ".docx")
    # A fixed date on every entry, so rewriting a fixture that hasn't changed leaves the file the same.
    def entry(archive, part, data):
        info = zipfile.ZipInfo(part, date_time=(2026, 1, 1, 0, 0, 0))
        info.compress_type = zipfile.ZIP_DEFLATED
        archive.writestr(info, data)
    with zipfile.ZipFile(path, "w") as archive:
        entry(archive, "[Content_Types].xml", content_types)
        entry(archive, "_rels/.rels", package_rels)
        entry(archive, "word/document.xml", document)
        entry(archive, "word/_rels/document.xml.rels", document_rels)
        entry(archive, "word/styles.xml", STYLES)
        entry(archive, "word/numbering.xml", NUMBERING)
        if "rIdFooter" in body + section:
            entry(archive, "word/footer1.xml", footer)
        for media_name, data in media.items():
            entry(archive, "word/media/" + media_name, data)
    print("wrote", path)


if __name__ == "__main__":
    for name, make in FIXTURES.items():
        write(name, *make())

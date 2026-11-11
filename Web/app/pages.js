// The document laid out in pages, and edited in place: the web's counterpart
// of the Apple apps' page view and its text view.
//
// The engine renders the document as blocks (web/engine/swift WebRenderer):
// paragraphs of runs that each name the inline they came from, tables of
// cells of blocks, and kept blocks shown as they read. This draws them in one
// editable flow over a column of pages, moving each block, or each table row,
// that would cross the foot of a page to the top of the next, as Word lays
// out a page at a time. Headers, footers and page numbers are drawn on the
// pages behind the flow.
//
// The browser does the typing. What it changed is read back from the flow and
// sent to the engine as blocks: those it left alone as their IDs, the rest as
// runs that name the inlines they came from, which is how formatting, links,
// fields and tracked changes the page cannot show survive an edit.
//
// Places in the text are a paragraph's ID and a count of UTF-16 units into it,
// counting a tab, break or picture as one, a field as what it shows, and the
// list label not at all, as the engine counts them.

const PT = 96 / 72;
const PAGE_GAP = 24;
const SYNC_DELAY = 350;

/** Every element a paragraph's text can be in, and what kind of run each is. */
const KIND = "data-k";

export class PageEditor extends EventTarget {
  /**
   * @param {HTMLElement} host
   * @param {import("./engine-client.js").EngineClient} engine
   * @param {{ t: (key: string, ...values: any[]) => string, language: string }} options
   */
  constructor(host, engine, { t, language }) {
    super();
    this.host = host;
    this.engine = engine;
    this.t = t;
    this.language = language;
    this.zoom = 1;
    this.doc = null;
    this.pictures = new Map(); // relationship ID → object URL
    this.dirty = new Set(); // top-level block elements the browser changed
    this.structureChanged = false;
    this.syncTimer = null;
    this.syncing = Promise.resolve();
    this.pendingStyle = null; // run formatting for what is typed next, with nothing selected
    this.newStep = false;

    host.classList.add("ds-page-canvas", "pages");
    host.innerHTML = `
      <div class="pages__sizer">
        <div class="pages__column">
          <div class="pages__sheets" aria-hidden="true"></div>
          <div class="pages__flow ds-document-content" contenteditable="true" spellcheck="true" role="textbox" aria-multiline="true"></div>
        </div>
      </div>
      <style class="pages__styles"></style>`;
    this.sizer = host.querySelector(".pages__sizer");
    this.column = host.querySelector(".pages__column");
    this.sheets = host.querySelector(".pages__sheets");
    this.flow = host.querySelector(".pages__flow");
    this.styleSheet = host.querySelector(".pages__styles");
    this.flow.setAttribute("aria-label", t("Web.Pages.Label"));

    try {
      document.execCommand("defaultParagraphSeparator", false, "p");
    } catch {
      // Older browsers make <div>s, which read back the same.
    }
    this.observer = new MutationObserver((records) => this.noteMutations(records));
    this.observer.observe(this.flow, { childList: true, subtree: true, characterData: true, attributes: false });
    this.bindInput();
    new ResizeObserver(() => this.paginate()).observe(this.host);
    document.addEventListener("selectionchange", () => {
      if (this.flow.contains(document.getSelection()?.anchorNode ?? null)) {
        this.dispatchEvent(new CustomEvent("selection"));
      }
    });
  }

  // MARK: - Drawing

  /** Draws the document again from the engine, keeping the selection where it was. */
  async refresh({ keepSelection = true } = {}) {
    const selection = keepSelection ? this.selection() : null;
    const doc = await this.engine.call("render");
    this.render(doc);
    if (selection) this.select(selection.anchor, selection.focus);
  }

  render(doc) {
    this.doc = doc;
    this.observer.disconnect();
    this.dirty.clear();
    this.structureChanged = false;
    this.pendingStyle = null;
    this.styleSheet.textContent = this.styles(doc);
    const fragment = document.createDocumentFragment();
    for (const block of doc.blocks) fragment.append(this.block(block));
    this.flow.replaceChildren(fragment);
    this.loadPictures();
    this.observer.observe(this.flow, { childList: true, subtree: true, characterData: true });
    this.paginate();
  }

  /** The run looks as CSS classes, `.r0`, `.r1`…, with their dark appearance under the app's theme. */
  styles(doc) {
    const light = [];
    const dark = [];
    doc.runStyles.forEach((look, index) => {
      const css = [];
      if (look.f) css.push(`font-family:${look.f}`);
      css.push(`font-size:${look.v ? look.z * 0.65 : look.z}pt`);
      if (look.b) css.push("font-weight:700");
      if (look.i) css.push("font-style:italic");
      const lines = [];
      if (look.u) lines.push("underline");
      if (look.x) lines.push("line-through");
      if (lines.length) css.push(`text-decoration-line:${lines.join(" ")}`);
      if (look.u && ["double", "dotted", "dash", "wave", "thick"].some((kind) => look.u.toLowerCase().includes(kind))) {
        const kind = look.u.toLowerCase();
        css.push(`text-decoration-style:${kind.includes("double") ? "double" : kind.includes("dot") ? "dotted" : kind.includes("dash") ? "dashed" : kind.includes("wave") ? "wavy" : "solid"}`);
      }
      if (look.x === 2) css.push("text-decoration-style:double");
      if (look.v === "super") css.push("vertical-align:super");
      if (look.v === "sub") css.push("vertical-align:sub");
      if (look.pos) css.push(`position:relative;top:${-look.pos}pt`);
      if (look.caps) css.push("text-transform:uppercase"); // design-lint-allow: a document's own all caps is content
      if (look.sc) css.push("font-variant-caps:small-caps"); // design-lint-allow: content
      if (look.ls) css.push(`letter-spacing:${look.ls}pt`); // design-lint-allow: content
      if (look.o) css.push("-webkit-text-stroke:0.75px currentColor;color:transparent");
      if (look.sh) css.push("text-shadow:1px 1px 1px color-mix(in srgb, currentColor 45%, transparent)");
      if (look.c && !look.o) css.push(`color:${look.c[0]}`);
      if (look.hl) css.push(`background-color:${look.hl[0]}`);
      light.push(`.pages .r${index}{${css.join(";")}}`);
      const darkCSS = [];
      if (look.c && !look.o) darkCSS.push(`color:${look.c[1]}`);
      if (look.hl) darkCSS.push(`background-color:${look.hl[1]}`);
      if (darkCSS.length) dark.push(`.pages .r${index}{${darkCSS.join(";")}}`);
    });
    const darkRules = dark.join("\n");
    return `${light.join("\n")}
@media (prefers-color-scheme: dark) { :root:not([data-theme="light"]) ${darkRules.replaceAll("\n", "\n:root:not([data-theme=\"light\"]) ")} }
${darkRules.split("\n").filter(Boolean).map((rule) => `:root[data-theme="dark"] ${rule}`).join("\n")}`;
  }

  /** A block's element. Top-level blocks are what the flow paginates. */
  block(block) {
    if (block.k === "t") return this.table(block);
    if (block.k === "x") {
      const kept = document.createElement("div");
      kept.className = "pages__kept";
      kept.dataset.id = block.id;
      kept.setAttribute(KIND, "x");
      kept.contentEditable = "false";
      kept.textContent = block.t;
      return kept;
    }
    return this.paragraph(block);
  }

  paragraph(block) {
    const p = document.createElement("p");
    p.className = "pages__p";
    p.dataset.id = block.id;
    if (block.st) p.dataset.st = block.st;
    if (block.h) p.dataset.h = String(block.h);
    if (block.m) p.dataset.m = block.m.join(",");
    if (block.pb) p.dataset.pb = "1";
    if (block.kn) p.dataset.kn = "1";
    if (block.sb) p.dataset.sb = block.sb;
    const s = block.s ?? {};
    const style = p.style;
    if (s.a) style.textAlign = s.a;
    if (s.il) style.paddingLeft = `${s.il}pt`;
    if (s.ir) style.paddingRight = `${s.ir}pt`;
    if (s.fi && !s.li) style.textIndent = `${s.fi}pt`;
    style.paddingTop = `${s.sb ?? 0}pt`;
    style.paddingBottom = `${s.sa ?? 0}pt`;
    if (s.lm) style.lineHeight = String(Math.max(0.6, 1.15 * s.lm));
    if (s.le) style.lineHeight = `${s.le}pt`;
    if (s.ll) style.minHeight = `${s.ll}pt`;
    if (s.bg) {
      style.setProperty("--pages-shading", s.bg[0]);
      style.setProperty("--pages-shading-dark", s.bg[1]);
      p.classList.add("pages__p--shaded");
    }
    if (s.bd) {
      for (const [edge, side] of [["t", "Top"], ["l", "Left"], ["b", "Bottom"], ["r", "Right"]]) {
        const line = s.bd[edge];
        if (!line) continue;
        style[`border${side}`] = `${line.w}pt ${line.s} ${line.c[0]}`;
      }
    }
    if (s.tabs?.length) style.tabSize = `${Math.max(12, s.tabs[0].p - (s.il ?? 0))}pt`;
    if (block.l !== undefined) {
      p.dataset.l = block.l;
      p.classList.add("pages__p--listed", `rl${block.ls ?? 0}`);
      style.setProperty("--pages-label-x", `${Math.max(0, (s.il ?? 0) + (s.fi ?? 0))}pt`);
      p.dataset.ls = String(block.ls ?? 0);
    }
    if (block.rev) p.classList.add(block.rev.k === "ins" ? "pages__mark-ins" : "pages__mark-del");
    for (const run of block.r) p.append(this.run(run));
    const last = block.r.at(-1);
    // An empty paragraph, or one ending in a line break, needs a break the caret can stand after.
    if (!block.r.length || last?.k === "br") p.append(placeholder());
    return p;
  }

  run(run) {
    let element;
    switch (run.k) {
      case "tab":
        element = document.createElement("span");
        element.className = "pages__tab";
        element.textContent = "\t";
        break;
      case "br":
        element = document.createElement("br");
        break;
      case "page":
      case "col":
        element = document.createElement("span");
        element.className = "pages__break";
        element.contentEditable = "false";
        element.title = this.t(run.k === "page" ? "Insert.PageBreak" : "Insert.ColumnBreak");
        break;
      case "img":
        element = this.picture(run);
        break;
      case "tok":
        element = document.createElement("span");
        element.className = run.note ? "pages__field pages__note" : run.eq ? "pages__field pages__equation" : "pages__field";
        element.contentEditable = "false";
        if (run.pc) {
          // Its runs, each in its own formatting; read back whole, by its text.
          for (const piece of run.pc) {
            const part = document.createElement("span");
            part.className = `r${piece.s}`;
            part.textContent = piece.t;
            element.append(part);
          }
        } else {
          element.textContent = run.t;
        }
        break;
      default:
        element = document.createElement("span");
        element.textContent = run.t ?? "";
    }
    if (run.k) element.setAttribute(KIND, run.k);
    if (run.r !== undefined) element.dataset.r = String(run.r);
    if (run.m) element.dataset.m = run.m.join(",");
    if (run.s !== undefined && run.k !== "br") element.classList.add(`r${run.s}`);
    if (run.href) {
      element.classList.add("pages__link");
      element.dataset.href = run.href;
      element.title = run.href;
    }
    if (run.rev) {
      element.classList.add(run.rev.k === "ins" ? "pages__ins" : "pages__del");
      element.style.setProperty("--pages-reviewer", reviewerColor(run.rev.a));
      element.title = `${run.rev.a}`;
    }
    return element;
  }

  picture(run) {
    if (run.obj) {
      const box = document.createElement("span");
      box.className = "pages__object";
      box.contentEditable = "false";
      box.style.width = `${run.w}pt`;
      box.style.height = `${run.h}pt`;
      if (run.fill) {
        box.style.setProperty("--pages-object-fill", run.fill[0]);
        box.style.setProperty("--pages-object-fill-dark", run.fill[1]);
      }
      box.textContent = run.text ?? "";
      return box;
    }
    const image = document.createElement("img");
    image.className = "pages__picture";
    image.draggable = false;
    image.alt = "";
    image.style.width = `${run.w}pt`;
    image.style.height = `${run.h}pt`;
    image.dataset.picture = run.id;
    if (run.crop) {
      const [left, top, right, bottom] = run.crop;
      image.style.objectFit = "cover";
      image.style.objectPosition = `${(left / Math.max(0.0001, left + right || 1)) * 100}% ${(top / Math.max(0.0001, top + bottom || 1)) * 100}%`;
    }
    if (run.wrap && ["square", "tight", "through", "topAndBottom"].includes(run.wrap)) {
      image.classList.add(run.align === "right" ? "pages__picture--right" : run.align === "center" ? "pages__picture--centre" : "pages__picture--left");
    }
    const url = this.pictures.get(run.id);
    if (url) image.src = url;
    return image;
  }

  /** Asks the engine for the bytes of pictures not loaded yet, and shows them. */
  async loadPictures() {
    for (const image of this.flow.querySelectorAll("img[data-picture]:not([src])")) {
      const id = image.dataset.picture;
      let url = this.pictures.get(id);
      if (!url) {
        try {
          const { result, payload } = await this.engine.call("media", { id });
          if (!["image/png", "image/jpeg", "image/gif", "image/webp", "image/bmp", "image/svg+xml"].includes(result.mime)) {
            image.classList.add("pages__picture--missing");
            continue;
          }
          url = URL.createObjectURL(new Blob([payload], { type: result.mime }));
          this.pictures.set(id, url);
        } catch {
          image.classList.add("pages__picture--missing");
          continue;
        }
      }
      for (const same of this.flow.querySelectorAll(`img[data-picture="${CSS.escape(id)}"]`)) same.src = url;
    }
  }

  table(block) {
    const table = document.createElement("table");
    table.className = "pages__table";
    table.dataset.id = block.id;
    table.setAttribute(KIND, "t");
    if (block.b) table.classList.add("pages__table--bordered");
    if (block.bc) {
      table.style.setProperty("--pages-table-border", block.bc[0]);
      table.style.setProperty("--pages-table-border-dark", block.bc[1]);
    }
    const columns = document.createElement("colgroup");
    for (const width of block.w) {
      const column = document.createElement("col");
      column.style.width = `${width}pt`;
      columns.append(column);
    }
    table.append(columns);
    const body = document.createElement("tbody");
    // A cell merged down takes the rows of the cells that carry it on, which are not drawn.
    const spans = block.rows.map((row) => row.c.map(() => 1));
    const starts = block.rows.map((row) => {
      let column = 0;
      return row.c.map((cell) => {
        const start = column;
        column += cell.span ?? 1;
        return start;
      });
    });
    block.rows.forEach((row, rowIndex) => {
      row.c.forEach((cell, cellIndex) => {
        if (cell.vm !== "r") return;
        for (let below = rowIndex + 1; below < block.rows.length; below++) {
          const index = starts[below].indexOf(starts[rowIndex][cellIndex]);
          if (index < 0 || block.rows[below].c[index].vm !== "c") break;
          spans[rowIndex][cellIndex]++;
        }
      });
    });
    block.rows.forEach((row, rowIndex) => {
      const tr = document.createElement("tr");
      tr.dataset.id = row.id;
      if (row.hd) tr.dataset.header = "1";
      row.c.forEach((cell, cellIndex) => {
        if (cell.vm === "c") return;
        const td = document.createElement("td");
        td.dataset.id = cell.id;
        if (cell.span > 1) td.colSpan = cell.span;
        if (spans[rowIndex][cellIndex] > 1) td.rowSpan = spans[rowIndex][cellIndex];
        if (cell.bg) {
          td.style.setProperty("--pages-shading", cell.bg[0]);
          td.style.setProperty("--pages-shading-dark", cell.bg[1]);
          td.classList.add("pages__cell--shaded");
        }
        for (const inner of cell.b) td.append(this.block(inner));
        if (!cell.b.length) td.append(this.paragraph({ id: "", r: [] }));
        tr.append(td);
      });
      body.append(tr);
    });
    table.append(body);
    return table;
  }

  // MARK: - Pages

  /** The section each top-level block is in, and the pages they fall on, as page backgrounds and pushes. */
  paginate() {
    if (!this.doc) return;
    cancelAnimationFrame(this.paginateFrame);
    this.paginateFrame = requestAnimationFrame(() => this.layoutPages());
  }

  layoutPages() {
    const doc = this.doc;
    if (!doc) return;
    const sections = doc.sections.map((section) => ({
      ...section,
      width: section.w * PT, height: section.h * PT,
      top: section.mt * PT, bottom: section.mb * PT, left: section.ml * PT, right: section.mr * PT,
    }));
    const widest = Math.max(...sections.map((section) => section.width));
    this.column.style.width = `${widest}px`;

    this.observer.disconnect();
    // Undo the last layout's pushes, then measure every block as it falls with none.
    for (const spacer of this.flow.querySelectorAll(".pages__spacer")) spacer.remove();
    const blocks = [...this.flow.children];
    let sectionIndex = 0;
    for (const element of blocks) {
      const section = sections[Math.min(sectionIndex, sections.length - 1)];
      element.style.marginTop = "";
      element.style.marginLeft = `${(widest - section.width) / 2 + section.left}px`;
      if (element.tagName !== "TABLE") element.style.width = `${section.width - section.left - section.right}px`;
      if (element.dataset.sb) sectionIndex++;
    }
    const heights = blocks.map((element) => element.offsetHeight);
    const rowHeights = new Map();
    for (const element of blocks) {
      if (element.tagName === "TABLE") rowHeights.set(element, [...element.rows].map((row) => row.offsetHeight));
    }

    const pages = [];
    let section = 0;
    const newPage = () => {
      const index = Math.min(section, sections.length - 1);
      const setup = sections[index];
      const top = pages.length ? pages.at(-1).top + pages.at(-1).height + PAGE_GAP : 0;
      pages.push({ top, height: setup.height, width: setup.width, section: index });
      return { top: top + setup.top, bottom: top + setup.height - setup.bottom };
    };
    // Everything is in the column's coordinates: a block's push is how far
    // below where it would fall its page lets it start.
    let area = newPage();
    const flowTop = area.top;
    let cursor = flowTop; // where the last block ended
    blocks.forEach((element, index) => {
      let top = Math.max(cursor, area.top);
      const startPage = () => {
        area = newPage();
        top = area.top;
      };
      if (element.dataset.pb === "1" && top > area.top) startPage();
      const height = heights[index];
      if (element.tagName === "TABLE") {
        // A table breaks between its rows.
        const rows = [...element.rows];
        const measured = rowHeights.get(element);
        if (top + (measured[0] ?? 0) > area.bottom && top > area.top) startPage();
        element.style.marginTop = top > cursor ? `${top - cursor}px` : "";
        const frame = height - measured.reduce((sum, rowHeight) => sum + rowHeight, 0);
        let rowY = top;
        measured.forEach((rowHeight, rowIndex) => {
          if (rowY + rowHeight > area.bottom && rowY > area.top) {
            area = newPage();
            const spacer = document.createElement("tr");
            spacer.className = "pages__spacer";
            spacer.contentEditable = "false";
            spacer.setAttribute("aria-hidden", "true");
            const cell = document.createElement("td");
            cell.colSpan = Math.max(1, element.querySelector("colgroup")?.children.length ?? 1);
            cell.style.height = `${area.top - rowY}px`;
            spacer.append(cell);
            rows[rowIndex].before(spacer);
            rowY = area.top;
          }
          rowY += rowHeight;
        });
        cursor = rowY + Math.max(0, frame);
      } else {
        if (top + height > area.bottom && top > area.top) startPage();
        element.style.marginTop = top > cursor ? `${top - cursor}px` : "";
        cursor = top + height;
      }
      // A block taller than its page runs on over the gap; the next starts where it ends.
      while (cursor > area.bottom + 0.5) area = newPage();
      // A page break ending a paragraph, or a section that starts a new page, moves what follows on.
      const last = element.tagName === "P" ? [...element.childNodes].filter((child) => !child.classList?.contains("pages__placeholder")).at(-1) : null;
      const endsInBreak = last?.getAttribute?.(KIND) === "page";
      if (element.dataset.sb) {
        section++;
        if (element.dataset.sb !== "continuous" && index < blocks.length - 1) area = newPage();
      } else if (endsInBreak && index < blocks.length - 1) {
        area = newPage();
      }
    });
    this.flow.style.top = `${flowTop}px`;
    this.flow.style.minHeight = `${Math.max(0, pages.at(-1).top + pages.at(-1).height - (sections[pages.at(-1).section].bottom) - flowTop)}px`;
    this.drawPages(pages, sections, widest);
    const height = pages.at(-1).top + pages.at(-1).height;
    this.column.style.height = `${height}px`;
    this.sizer.style.width = `${widest * this.zoom}px`;
    this.sizer.style.height = `${height * this.zoom}px`;
    this.column.style.transform = this.zoom === 1 ? "" : `scale(${this.zoom})`;
    this.pageCount = pages.length;
    this.pageTops = pages.map((page) => page.top);
    this.observer.observe(this.flow, { childList: true, subtree: true, characterData: true });
    this.dispatchEvent(new CustomEvent("pages", { detail: { count: pages.length } }));
  }

  drawPages(pages, sections, widest) {
    const doc = this.doc;
    const sheets = pages.map((page, index) => {
      const setup = sections[page.section];
      const sheet = document.createElement("div");
      sheet.className = "ds-page pages__sheet";
      sheet.style.top = `${page.top}px`;
      sheet.style.left = `${(widest - page.width) / 2}px`;
      sheet.style.width = `${page.width}px`;
      sheet.style.height = `${page.height}px`;
      const firstOfSection = index === 0 || pages[index - 1].section !== page.section;
      const kind = firstOfSection && setup.title ? "first" : doc.evenAndOdd && index % 2 === 1 ? "even" : "default";
      const number = formatPageNumber(index + 1, setup.nf);
      for (const [part, isFooter] of [[setup.head, false], [setup.foot, true]]) {
        const text = part?.[kind] ?? (kind !== "default" ? null : part?.default);
        if (!text) continue;
        const element = document.createElement("div");
        element.className = `pages__margin-text ${isFooter ? "pages__footer" : "pages__header"}`;
        element.style.left = `${setup.left}px`;
        element.style.right = `${setup.right}px`;
        element.style[isFooter ? "bottom" : "top"] = `${(isFooter ? setup.fd : setup.hd) * PT}px`;
        element.style.textAlign = { center: "center", right: "right", both: "justify" }[text.a] ?? "left";
        element.textContent = text.t.replaceAll("{PAGE}", number).replaceAll("{NUMPAGES}", String(pages.length));
        sheet.append(element);
      }
      return sheet;
    });
    this.sheets.replaceChildren(...sheets);
  }

  setZoom(zoom) {
    this.zoom = Math.min(4, Math.max(0.25, zoom));
    this.layoutPages();
    this.dispatchEvent(new CustomEvent("zoom", { detail: this.zoom }));
  }

  /** The page the selection is on, counting from 1. */
  currentPage() {
    const range = document.getSelection()?.rangeCount ? document.getSelection().getRangeAt(0) : null;
    if (!range || !this.flow.contains(range.startContainer) || !this.pageTops) return 1;
    const rect = range.getBoundingClientRect();
    const columnRect = this.column.getBoundingClientRect();
    const y = (rect.top - columnRect.top) / this.zoom;
    let page = 1;
    this.pageTops.forEach((top, index) => {
      if (y >= top) page = index + 1;
    });
    return page;
  }

  // MARK: - Positions

  /** The paragraph element holding a node, or null. */
  paragraphOf(node) {
    const element = node?.nodeType === Node.ELEMENT_NODE ? node : node?.parentElement;
    const paragraph = element?.closest("p, div:not(.pages__flow):not(.pages__kept)");
    return paragraph && this.flow.contains(paragraph) ? paragraph : null;
  }

  /** How long a run element is, as the engine counts it. */
  static length(node) {
    if (node.nodeType === Node.TEXT_NODE) return node.data.length;
    if (node.nodeType !== Node.ELEMENT_NODE) return 0;
    if (node.classList.contains("pages__placeholder")) return 0;
    const kind = node.getAttribute(KIND);
    if (kind === "tab" || kind === "page" || kind === "col" || kind === "img" || node.tagName === "BR" || node.tagName === "IMG") return 1;
    if (kind === "tok") return node.textContent.length;
    let total = 0;
    for (const child of node.childNodes) total += PageEditor.length(child);
    return total;
  }

  /** A DOM point as { p: paragraph ID, o: offset }. */
  position(node, offset) {
    let paragraph = this.paragraphOf(node);
    if (!paragraph) {
      // Between blocks: the start of the next paragraph, or the end of the last.
      const child = node === this.flow ? this.flow.children[Math.min(offset, this.flow.children.length - 1)] : null;
      paragraph = child?.matches?.("p") ? child : child?.querySelector?.("p") ?? this.flow.querySelector("p");
      if (!paragraph) return null;
      return { p: paragraph.dataset.id, o: 0 };
    }
    let total = 0;
    const walk = (current) => {
      if (current === node) {
        if (node.nodeType === Node.TEXT_NODE) {
          total += offset;
        } else {
          for (let index = 0; index < offset && index < node.childNodes.length; index++) total += PageEditor.length(node.childNodes[index]);
        }
        return true;
      }
      if (current.nodeType === Node.ELEMENT_NODE && current !== paragraph && current.getAttribute(KIND)) {
        if (current.contains(node)) {
          // Inside a run that counts as a whole, such as a field: before or after it.
          // Its text may be in parts, each in its own span: at its start only before the first character of the first.
          let atStart = offset === 0;
          for (let inner = node; atStart && inner !== current; inner = inner.parentNode) atStart = inner === inner.parentNode.firstChild;
          if (!atStart) total += PageEditor.length(current);
          return true;
        }
        total += PageEditor.length(current);
        return false;
      }
      if (current.nodeType === Node.TEXT_NODE) {
        total += current.data.length;
        return false;
      }
      for (const child of current.childNodes) if (walk(child)) return true;
      return false;
    };
    walk(paragraph);
    return { p: paragraph.dataset.id, o: total };
  }

  /** The selection as engine positions: { anchor, focus, collapsed }, or null when it isn't in the pages. */
  selection() {
    const selection = document.getSelection();
    if (!selection?.rangeCount || !this.flow.contains(selection.anchorNode)) return this.lastSelection ?? null;
    const anchor = this.position(selection.anchorNode, selection.anchorOffset);
    const focus = this.position(selection.focusNode, selection.focusOffset);
    if (!anchor || !focus) return null;
    this.lastSelection = { anchor, focus, collapsed: selection.isCollapsed };
    return this.lastSelection;
  }

  /** The DOM point for an engine position. */
  point({ p, o }) {
    const paragraph = this.flow.querySelector(`[data-id="${CSS.escape(p)}"]`);
    if (!paragraph) return null;
    let remaining = o;
    let found = null;
    const walk = (current) => {
      for (const child of current.childNodes) {
        if (found) return;
        if (child.nodeType === Node.TEXT_NODE) {
          if (remaining <= child.data.length) {
            found = { node: child, offset: remaining };
            return;
          }
          remaining -= child.data.length;
        } else if (child.nodeType === Node.ELEMENT_NODE) {
          if (child.classList.contains("pages__placeholder")) continue;
          if (child.getAttribute(KIND) || child.tagName === "BR" || child.tagName === "IMG") {
            const length = PageEditor.length(child);
            if (remaining === 0) {
              found = { node: current, offset: [...current.childNodes].indexOf(child) };
              return;
            }
            if (remaining < length) {
              found = { node: current, offset: [...current.childNodes].indexOf(child) + 1 };
              return;
            }
            remaining -= length;
          } else {
            walk(child);
          }
        }
      }
    };
    walk(paragraph);
    if (found) return found;
    const last = paragraph.lastChild;
    if (last?.nodeType === Node.TEXT_NODE) return { node: last, offset: last.data.length };
    const placeholderIndex = [...paragraph.childNodes].findIndex((child) => child.classList?.contains("pages__placeholder"));
    return { node: paragraph, offset: placeholderIndex >= 0 ? placeholderIndex : paragraph.childNodes.length };
  }

  select(anchor, focus = anchor) {
    const start = anchor && this.point(anchor);
    const end = focus && this.point(focus);
    if (!start || !end) return;
    const selection = document.getSelection();
    try {
      selection.setBaseAndExtent(start.node, start.offset, end.node, end.offset);
    } catch {
      // A place that no longer exists: leave the selection be.
    }
  }

  focus() {
    if (!this.flow.contains(document.activeElement)) this.flow.focus({ preventScroll: true });
  }

  // MARK: - Reading edits back

  noteMutations(records) {
    for (const record of records) {
      if (record.target === this.flow) {
        this.structureChanged = true;
        for (const node of record.addedNodes) if (node.nodeType === Node.ELEMENT_NODE) this.dirty.add(node);
        continue;
      }
      const top = this.topLevel(record.target);
      if (top) this.dirty.add(top);
      if (record.type === "childList" && [...record.addedNodes, ...record.removedNodes].some((node) => node.nodeName === "P" || node.nodeName === "DIV")) {
        this.structureChanged = true;
      }
    }
    this.scheduleSync();
    this.paginate();
  }

  topLevel(node) {
    let current = node.nodeType === Node.ELEMENT_NODE ? node : node.parentNode;
    while (current && current.parentNode !== this.flow) current = current.parentNode;
    return current && current.parentNode === this.flow ? current : null;
  }

  scheduleSync() {
    clearTimeout(this.syncTimer);
    this.syncTimer = setTimeout(() => this.sync(), SYNC_DELAY);
  }

  /** Sends what the browser changed to the engine, if anything. Resolves once the engine has it. */
  sync() {
    clearTimeout(this.syncTimer);
    this.syncTimer = null;
    if (!this.dirty.size && !this.structureChanged) return this.syncing;
    const ids = new Map();
    for (const element of this.flow.children) {
      const id = element.dataset?.id;
      if (id) ids.set(id, (ids.get(id) ?? 0) + 1);
    }
    const blocks = [];
    for (const element of this.flow.children) {
      const id = element.dataset?.id;
      if (element.classList?.contains("pages__spacer")) continue;
      if (id && !this.dirty.has(element) && ids.get(id) === 1) blocks.push({ id });
      else blocks.push(...this.read(element));
    }
    const step = this.newStep || this.structureChanged;
    this.dirty.clear();
    this.structureChanged = false;
    this.newStep = false;
    this.syncing = this.syncing.then(async () => {
      const result = await this.engine.call("edit", { blocks, step });
      this.relabel(result?.labels ?? {});
      this.dispatchEvent(new CustomEvent("edited"));
    }).catch((error) => this.dispatchEvent(new CustomEvent("message", { detail: error.message })));
    return this.syncing;
  }

  /** Updates list labels that the edit moved on, and gives new paragraphs the IDs they now have. */
  relabel(labels) {
    for (const [id, label] of Object.entries(labels)) {
      for (const paragraph of this.flow.querySelectorAll(`[data-id="${CSS.escape(id)}"]`)) {
        if (label) paragraph.dataset.l = label;
        else delete paragraph.dataset.l;
      }
    }
    // Paragraphs the browser made, or split off, have no lasting ID until drawn again.
    const seen = new Set();
    let stale = false;
    for (const paragraph of this.flow.querySelectorAll("p")) {
      const id = paragraph.dataset.id;
      if (!id || seen.has(id)) stale = true;
      seen.add(id);
    }
    if (stale) this.refresh();
  }

  /** What an element shows, as the engine reads blocks. */
  read(element) {
    if (element.nodeType !== Node.ELEMENT_NODE) {
      const text = element.textContent ?? "";
      return text ? [{ k: "p", r: [{ t: text }] }] : [];
    }
    if (element.getAttribute(KIND) === "x") return [{ k: "x", id: element.dataset.id }];
    if (element.tagName === "TABLE") {
      return [{
        k: "t", id: element.dataset.id,
        rows: [...element.rows].filter((row) => !row.classList.contains("pages__spacer")).map((row) => ({
          id: row.dataset.id,
          c: [...row.cells].map((cell) => ({ id: cell.dataset.id, b: [...cell.children].flatMap((child) => this.read(child)) })),
        })),
      }];
    }
    // A block the browser nested inside another, such as a <div> in a paragraph: each its own paragraph.
    const nested = [...element.children].filter((child) => ["P", "DIV", "TABLE"].includes(child.tagName) && !child.getAttribute(KIND));
    if (nested.length && element.tagName !== "P") return [...element.childNodes].flatMap((child) => this.read(child));
    return [this.readParagraph(element)];
  }

  readParagraph(paragraph) {
    const runs = [];
    let trailingBreak = null;
    const visit = (node, inherited) => {
      if (node.nodeType === Node.TEXT_NODE) {
        if (node.data) runs.push({ ...inherited, t: node.data.replaceAll(" ", " ") });
        return;
      }
      if (node.nodeType !== Node.ELEMENT_NODE || node.classList.contains("pages__placeholder")) return;
      const run = { ...inherited };
      if (node.dataset.r !== undefined) run.r = Number(node.dataset.r);
      if (node.dataset.m) run.m = node.dataset.m.split(",").map(Number);
      if (node.dataset.p) run.p = JSON.parse(node.dataset.p);
      const kind = node.getAttribute(KIND);
      if (node.tagName === "BR") {
        const entry = { r: run.r, k: "br", ...(run.p ? { p: run.p } : {}) };
        runs.push(entry);
        trailingBreak = entry;
        return;
      }
      if (kind && kind !== "tab" && node.tagName !== "SPAN" && kind !== "img") return;
      if (kind === "tab" || kind === "page" || kind === "col" || kind === "img") {
        runs.push({ r: run.r, k: kind, ...(run.m ? { m: run.m } : {}), ...(run.p ? { p: run.p } : {}) });
        return;
      }
      if (kind === "tok") {
        runs.push({ r: run.r, k: "tok", t: node.textContent, ...(run.m ? { m: run.m } : {}) });
        return;
      }
      if (node.tagName === "IMG") return;
      const before = runs.length;
      const { m, ...rest } = run;
      for (const child of node.childNodes) visit(child, rest);
      // Markers ride on the first run they came with.
      if (m && runs.length > before) runs[before].m = m;
      else if (m) runs.push({ ...rest, t: "", m });
    };
    for (const child of paragraph.childNodes) visit(child, {});
    // The browser's own break at the end of a block shows nothing.
    if (trailingBreak && runs.at(-1) === trailingBreak && paragraph.lastChild?.nodeName === "BR") runs.pop();
    const block = { k: "p", r: runs };
    if (paragraph.dataset.id) block.id = paragraph.dataset.id;
    if (paragraph.dataset.m) block.m = paragraph.dataset.m.split(",").map(Number);
    return block;
  }

  // MARK: - Typing

  bindInput() {
    const flow = this.flow;
    flow.addEventListener("beforeinput", (event) => this.beforeInput(event));
    flow.addEventListener("keydown", (event) => this.keyDown(event));
    flow.addEventListener("paste", (event) => {
      event.preventDefault();
      const text = event.clipboardData?.getData("text/plain") ?? "";
      if (!text) return;
      this.newStep = true;
      this.insertText(text);
    });
    flow.addEventListener("drop", (event) => {
      // Only text moves within the pages; files are opened by the window.
      if ([...(event.dataTransfer?.types ?? [])].includes("Files")) return;
      event.preventDefault();
    });
    flow.addEventListener("click", (event) => {
      const link = event.target.closest?.("[data-href]");
      const mod = /Mac|iPhone|iPad/.test(navigator.platform || navigator.userAgent) ? event.metaKey : event.ctrlKey;
      if (link && mod) {
        const href = link.dataset.href;
        if (href.startsWith("#")) return;
        window.open(href, "_blank", "noopener");
      }
    });
    flow.addEventListener("focusout", () => this.sync());
    // Pinching zooms the pages: a trackpad pinch arrives as a wheel with Control held, Safari's as gestures.
    this.host.addEventListener("wheel", (event) => {
      if (!event.ctrlKey) return;
      event.preventDefault();
      this.setZoom(this.zoom * Math.exp(-event.deltaY / 100));
    }, { passive: false });
    let gestureZoom = 1;
    this.host.addEventListener("gesturestart", () => {
      gestureZoom = this.zoom;
    });
    this.host.addEventListener("gesturechange", (event) => this.setZoom(gestureZoom * event.scale));
  }

  beforeInput(event) {
    switch (event.inputType) {
      case "historyUndo":
      case "historyRedo":
        event.preventDefault();
        this.dispatchEvent(new CustomEvent("command", { detail: event.inputType === "historyUndo" ? "undo" : "redo" }));
        return;
      case "formatBold":
      case "formatItalic":
      case "formatUnderline":
      case "formatStrikeThrough":
        event.preventDefault();
        this.dispatchEvent(new CustomEvent("command", { detail: { formatBold: "bold", formatItalic: "italic", formatUnderline: "underline", formatStrikeThrough: "strike" }[event.inputType] }));
        return;
      case "insertParagraph":
        this.newStep = true;
        this.pendingStyle = null;
        return;
      case "insertFromDrop":
      case "insertFromPaste":
        this.newStep = true;
        return;
      case "insertText":
      case "insertReplacementText":
        if (this.pendingStyle && event.data) {
          event.preventDefault();
          this.insertText(event.data, this.pendingStyle);
        }
        return;
      default:
        if (event.inputType.startsWith("format")) event.preventDefault();
    }
  }

  keyDown(event) {
    if (event.key === "Tab" && !event.metaKey && !event.ctrlKey && !event.altKey) {
      event.preventDefault();
      const paragraph = this.paragraphOf(document.getSelection()?.anchorNode);
      if (paragraph?.dataset.l !== undefined) {
        this.dispatchEvent(new CustomEvent("command", { detail: event.shiftKey ? "outdent" : "indent" }));
        return;
      }
      if (event.shiftKey) return;
      this.insertElement(() => {
        const tab = document.createElement("span");
        tab.className = "pages__tab";
        tab.setAttribute(KIND, "tab");
        tab.textContent = "\t";
        return tab;
      });
      return;
    }
    if (event.key === "Enter" && (event.metaKey || event.ctrlKey) && !event.altKey) {
      event.preventDefault();
      this.insertPageBreak();
    }
  }

  /** The run a new element typed at the caret should take its look from. */
  runAtCaret() {
    const selection = document.getSelection();
    let node = selection?.anchorNode;
    if (node?.nodeType === Node.TEXT_NODE) node = node.parentElement;
    if (node?.dataset?.r !== undefined) return node;
    const paragraph = this.paragraphOf(node);
    if (!paragraph) return null;
    const children = [...paragraph.childNodes];
    const before = children.slice(0, selection.anchorOffset).reverse().find((child) => child.dataset?.r !== undefined);
    return before ?? children.find((child) => child.dataset?.r !== undefined) ?? null;
  }

  /** Puts an element in at the caret, in the look of the run there. */
  insertElement(make) {
    const selection = document.getSelection();
    if (!selection?.rangeCount) return;
    const range = selection.getRangeAt(0);
    range.deleteContents();
    const element = make();
    const run = this.runAtCaret();
    if (run) {
      element.dataset.r = run.dataset.r;
      for (const name of run.classList) if (/^r\d+$/.test(name)) element.classList.add(name);
    }
    // Inside a span of text, split it so the element stands between its halves.
    const container = range.startContainer;
    const span = container.nodeType === Node.TEXT_NODE ? container.parentElement : null;
    if (span?.tagName === "SPAN" && span.dataset.r !== undefined && !span.getAttribute(KIND)) {
      const after = span.cloneNode(false);
      after.removeAttribute("data-m");
      const tail = container.splitText(range.startOffset);
      for (let node = tail; node; ) {
        const next = node.nextSibling;
        after.append(node);
        node = next;
      }
      span.after(element);
      if (after.textContent) element.after(after);
    } else {
      range.insertNode(element);
    }
    const caret = document.createRange();
    caret.setStartAfter(element);
    caret.collapse(true);
    selection.removeAllRanges();
    selection.addRange(caret);
  }

  /** Types text at the caret: plain, or in a look turned on with nothing selected. */
  insertText(text, style = null) {
    const lines = text.replace(/\r\n?/g, "\n").split("\n");
    if (lines.length > 1 && !style) {
      // Pasted lines become paragraphs, as typing them would make them.
      this.newStep = true;
      document.execCommand("insertText", false, lines[0]);
      for (const line of lines.slice(1)) {
        document.execCommand("insertParagraph");
        if (line) document.execCommand("insertText", false, line);
      }
      return;
    }
    if (!style) {
      document.execCommand("insertText", false, text);
      return;
    }
    this.insertElement(() => {
      const span = document.createElement("span");
      span.dataset.p = JSON.stringify(style);
      span.textContent = text;
      if (style.b) span.style.fontWeight = "700";
      if (style.b === false) span.style.fontWeight = "400";
      if (style.i) span.style.fontStyle = "italic";
      if (style.i === false) span.style.fontStyle = "normal";
      if (style.u) span.style.textDecorationLine = "underline";
      if (style.x) span.style.textDecorationLine = "line-through";
      return span;
    });
    // What follows is typed into that run.
    const selection = document.getSelection();
    const span = selection.anchorNode?.previousSibling ?? selection.anchorNode?.childNodes?.[selection.anchorOffset - 1];
    if (span?.firstChild) {
      const caret = document.createRange();
      caret.setStart(span.firstChild, span.firstChild.data.length);
      caret.collapse(true);
      selection.removeAllRanges();
      selection.addRange(caret);
    }
    this.pendingStyle = null;
  }

  insertPageBreak() {
    this.newStep = true;
    this.insertElement(() => {
      const element = document.createElement("span");
      element.className = "pages__break";
      element.setAttribute(KIND, "page");
      element.contentEditable = "false";
      return element;
    });
  }

  /** The run formatting of the text at the selection's start, as the engine's run look. */
  lookAtSelection() {
    const selection = document.getSelection();
    if (!this.doc || !selection?.rangeCount || !this.flow.contains(selection.anchorNode)) return null;
    const range = selection.getRangeAt(0);
    let node = range.startContainer;
    if (node.nodeType !== Node.TEXT_NODE) {
      node = node.childNodes[Math.max(0, range.startOffset - (selection.isCollapsed ? 1 : 0))] ?? node;
    }
    const element = node.nodeType === Node.TEXT_NODE ? node.parentElement : node;
    const run = element?.closest?.("[class*='r']");
    const index = run ? [...run.classList].find((name) => /^r\d+$/.test(name))?.slice(1) : undefined;
    const look = index !== undefined ? { ...this.doc.runStyles[Number(index)] } : { ...this.doc.runStyles[this.doc.defaults.r] };
    if (this.pendingStyle) Object.assign(look, this.pendingStyle);
    const paragraph = this.paragraphOf(range.startContainer);
    look.paragraphStyle = paragraph?.dataset.st ?? "";
    look.align = paragraph?.style.textAlign || "left";
    look.listed = paragraph?.dataset.l !== undefined;
    look.inTable = Boolean(paragraph?.closest("td"));
    look.cell = paragraph?.closest("td")?.dataset.id ?? null;
    return look;
  }

  /** Turns run formatting on or off for what is typed next. */
  setPendingStyle(patch) {
    this.pendingStyle = { ...(this.pendingStyle ?? {}), ...patch };
    this.dispatchEvent(new CustomEvent("selection"));
  }

  /** Every top-level paragraph's text, for find. */
  find(query, { caseSensitive = false } = {}) {
    const matches = [];
    if (!query) return matches;
    const needle = caseSensitive ? query : query.toLocaleLowerCase(this.language);
    for (const paragraph of this.flow.querySelectorAll("p")) {
      const walker = document.createTreeWalker(paragraph, NodeFilter.SHOW_TEXT);
      const nodes = [];
      let text = "";
      for (let node = walker.nextNode(); node; node = walker.nextNode()) {
        if (node.parentElement.closest("[contenteditable='false']")) continue;
        nodes.push({ node, start: text.length });
        text += node.data;
      }
      const haystack = caseSensitive ? text : text.toLocaleLowerCase(this.language);
      for (let index = haystack.indexOf(needle); index >= 0; index = haystack.indexOf(needle, index + needle.length)) {
        const locate = (offset, atEnd) => {
          const entry = nodes.findLast((candidate) => candidate.start < offset || (!atEnd && candidate.start === offset)) ?? nodes[0];
          return { node: entry.node, offset: offset - entry.start };
        };
        matches.push({ start: locate(index, false), end: locate(index + needle.length, true) });
      }
    }
    return matches;
  }

  /** Selects a match from `find`, scrolling it into view. */
  showMatch(match) {
    const selection = document.getSelection();
    selection.setBaseAndExtent(match.start.node, match.start.offset, match.end.node, match.end.offset);
    const rect = selection.getRangeAt(0).getBoundingClientRect();
    const host = this.host.getBoundingClientRect();
    if (rect.top < host.top + 40 || rect.bottom > host.bottom - 40) {
      this.host.scrollTop += rect.top - host.top - host.height / 3;
    }
  }

  /** Replaces the selected match with text, as typing it would. */
  replaceSelection(text) {
    this.newStep = true;
    document.execCommand("insertText", false, text);
  }

  /** Every place a picture is cleared away, when the document closes. */
  dispose() {
    for (const url of this.pictures.values()) URL.revokeObjectURL(url);
    this.pictures.clear();
  }
}

function placeholder() {
  const br = document.createElement("br");
  br.className = "pages__placeholder";
  return br;
}

/** A colour of its own for each reviewer, as Word gives them. */
function reviewerColor(author = "") {
  const palette = ["#da1e28", "#0f62fe", "#24a148", "#8a3ffc", "#ff832b", "#007d79"];
  let hash = 5381;
  for (const char of author) hash = ((hash * 33) + char.codePointAt(0)) | 0;
  return palette[Math.abs(hash) % palette.length];
}

function formatPageNumber(number, format) {
  switch (format) {
    case "lowerRoman": return roman(number).toLowerCase();
    case "upperRoman": return roman(number);
    case "lowerLetter": return letters(number).toLowerCase();
    case "upperLetter": return letters(number);
    default: return String(number);
  }
}

function roman(value) {
  const table = [[1000, "M"], [900, "CM"], [500, "D"], [400, "CD"], [100, "C"], [90, "XC"], [50, "L"], [40, "XL"], [10, "X"], [9, "IX"], [5, "V"], [4, "IV"], [1, "I"]];
  let remaining = value;
  let result = "";
  for (const [amount, numeral] of table) {
    while (remaining >= amount) {
      result += numeral;
      remaining -= amount;
    }
  }
  return result;
}

function letters(value) {
  const letter = String.fromCharCode(65 + ((value - 1) % 26));
  return letter.repeat(Math.floor((value - 1) / 26) + 1);
}

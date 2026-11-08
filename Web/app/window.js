// The document window: menu bar, toolbar, find bar, pages (or the code
// editor), status bar and inspector, and the start screen shown when no
// document is open. Every change to a document goes through the engine; this
// keeps the window in step with what it reports.

import { PageEditor } from "./pages.js";
import { CodeEditor } from "./code.js";
import { t, language } from "./i18n.js";
import * as files from "./files.js";
import * as storage from "./storage.js";
import { attachMenuBar, attachToolbarOverflow } from "../design/menus.js";
import { dismissSheet } from "../design/sheets.js";
import * as fonts from "./fonts.js";

const isApple = /Mac|iPhone|iPad/.test(navigator.platform || navigator.userAgent);
/** Libretto for iPhone, iPad and Mac: one App Store listing, opened in the visitor's own storefront. */
const APP_STORE_URL = "https://apps.apple.com/app/atelier-libretto/id6819683632";
const SOURCE_CODE_URL = "https://github.com/AtelierSuite/Libretto";
/**
 * Which Apple app to offer, from the device the page is open on: "ios" on an
 * iPhone or iPad, "mac" on a Mac, null elsewhere. iPadOS asks for desktop
 * pages and calls itself a Mac, but a Mac has no touch screen.
 */
const appStorePlatform = (() => {
  const agent = navigator.userAgent;
  if (/iPhone|iPad|iPod/.test(agent)) return "ios";
  if (/Macintosh/.test(agent)) return navigator.maxTouchPoints > 1 ? "ios" : "mac";
  return null;
})();
const AUTOSAVE_DELAY = 1500;
const ZOOMS = [0.5, 0.75, 1, 1.25, 1.5, 2, 3];
/** Word's paper sizes, in points. */
const PAPERS = [
  { key: "PageSetup.Paper.A4", width: 595.3, height: 841.9 },
  { key: "PageSetup.Paper.Letter", width: 612, height: 792 },
  { key: "PageSetup.Paper.Legal", width: 612, height: 1008 },
  { key: "Web.PageSetup.Paper.A5", width: 419.55, height: 595.3 },
  { key: "Web.PageSetup.Paper.B5", width: 515.9, height: 728.5 },
];
const HIGHLIGHTS = ["yellow", "green", "cyan", "magenta", "red", "blue", "lightGray", "darkYellow"];

const ICONS = {
  undo: '<path d="M5 4L2 7l3 3M2 7h7.5a3.5 3.5 0 010 7H7" fill="none" stroke="currentColor" stroke-width="1.5"/>',
  redo: '<path d="M11 4l3 3-3 3M14 7H6.5a3.5 3.5 0 000 7H9" fill="none" stroke="currentColor" stroke-width="1.5"/>',
  alignLeft: '<path d="M2 3.5h12M2 6.5h8M2 9.5h12M2 12.5h8" stroke="currentColor" stroke-width="1.5"/>',
  alignCenter: '<path d="M2 3.5h12M4 6.5h8M2 9.5h12M4 12.5h8" stroke="currentColor" stroke-width="1.5"/>',
  alignRight: '<path d="M2 3.5h12M6 6.5h8M2 9.5h12M6 12.5h8" stroke="currentColor" stroke-width="1.5"/>',
  alignJustify: '<path d="M2 3.5h12M2 6.5h12M2 9.5h12M2 12.5h12" stroke="currentColor" stroke-width="1.5"/>',
  bullets: '<path d="M6 4h8M6 8h8M6 12h8" stroke="currentColor" stroke-width="1.5"/><circle cx="3" cy="4" r="1.1"/><circle cx="3" cy="8" r="1.1"/><circle cx="3" cy="12" r="1.1"/>',
  numbers: '<path d="M6.5 4h7.5M6.5 8h7.5M6.5 12h7.5" stroke="currentColor" stroke-width="1.5"/><path d="M2.2 2.8h1v2.7M1.9 5.5h1.7M1.8 9.6c.2-.5.6-.8 1.1-.8.6 0 1 .4 1 .9 0 .8-1.3 1.1-2.1 2h2.2" fill="none" stroke="currentColor" stroke-width=".9"/>',
  table: '<rect x="1.75" y="2.75" width="12.5" height="10.5" fill="none" stroke="currentColor" stroke-width="1.5"/><path d="M2 6.5h12M2 10h12M6 3v10" stroke="currentColor" stroke-width="1.2"/>',
  picture: '<rect x="1.75" y="2.75" width="12.5" height="10.5" fill="none" stroke="currentColor" stroke-width="1.5"/><path d="M2.5 12l3.5-4 2.5 2.5L10.5 8l3 4" fill="none" stroke="currentColor" stroke-width="1.3"/><circle cx="10.5" cy="5.5" r="1.1"/>',
  search: '<circle cx="7" cy="7" r="4.25" fill="none" stroke="currentColor" stroke-width="1.5"/><path d="M10.2 10.2L14 14" stroke="currentColor" stroke-width="1.5"/>',
  inspector: '<rect x="1.75" y="2.75" width="12.5" height="10.5" fill="none" stroke="currentColor" stroke-width="1.5"/><path d="M10 3v10" stroke="currentColor" stroke-width="1.5"/>',
  chevronDown: '<path d="M4 6l4 4 4-4" fill="none" stroke="currentColor" stroke-width="1.5"/>',
  chevronUp: '<path d="M4 10l4-4 4 4" fill="none" stroke="currentColor" stroke-width="1.5"/>',
  close: '<path d="M4 4l8 8M12 4l-8 8" stroke="currentColor" stroke-width="1.5"/>',
  info: '<path d="M8 1a7 7 0 100 14A7 7 0 008 1zm.75 10.5h-1.5V7h1.5zM8 5.75a1 1 0 110-2 1 1 0 010 2z"/>',
  warning: '<path d="M8 1L.5 15h15zm.75 11.5h-1.5V11h1.5zm0-2.5h-1.5V6h1.5z"/>',
  error: '<path d="M8 1a7 7 0 100 14A7 7 0 008 1zm3 9.6L10.6 11 8 8.4 5.4 11 5 10.6 7.6 8 5 5.4 5.4 5 8 7.6 10.6 5l.4.4L8.4 8z"/>',
  document: '<path d="M3.75 1.75h6l2.5 2.5v10h-8.5z" fill="none" stroke="currentColor" stroke-width="1.5"/><path d="M5.5 7h5M5.5 9.5h5M5.5 12h3" stroke="currentColor" stroke-width="1.2"/>',
  code: '<path d="M5.5 4.5L2 8l3.5 3.5M10.5 4.5L14 8l-3.5 3.5" fill="none" stroke="currentColor" stroke-width="1.5"/>',
  download: '<path d="M8 2v8M4.5 6.5L8 10l3.5-3.5M2.5 11v2.5h11V11" fill="none" stroke="currentColor" stroke-width="1.5"/>',
};

const icon = (name, extra = "") => `<svg class="ds-icon ${extra}" viewBox="0 0 16 16" aria-hidden="true">${ICONS[name]}</svg>`;

/** A shortcut as the platform writes it: ⇧⌘S on Apple devices, Ctrl+Shift+S elsewhere. */
function shortcut(key, { shift = false, alt = false } = {}) {
  if (isApple) return `${alt ? "⌥" : ""}${shift ? "⇧" : ""}⌘${key}`;
  return `Ctrl+${shift ? "Shift+" : ""}${alt ? "Alt+" : ""}${key}`;
}

function escapeHTML(text) {
  return String(text).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
}

/** Whether two style entries are the same style. */
const sameStyle = (entry, other) => Boolean(entry && other && (entry.choice ?? entry.id) === (other.choice ?? other.id));

function readSetting(key, fallback) {
  try {
    return localStorage.getItem(`libretto.${key}`) ?? fallback;
  } catch {
    return fallback;
  }
}

function writeSetting(key, value) {
  try {
    localStorage.setItem(`libretto.${key}`, value);
  } catch {
    // Settings are a convenience.
  }
}

export class DocumentWindow {
  /** @param {HTMLElement} root @param {import("./engine-client.js").EngineClient} engine */
  constructor(root, engine) {
    this.root = root;
    this.engine = engine;
    this.document = null; // { id, name, handle? }
    this.autosaveTimer = null;
    this.numberFormat = new Intl.NumberFormat(language);
    this.look = null;

    this.build();
    this.pages = new PageEditor(this.root.querySelector(".app__pages"), engine, { t, language });
    this.code = new CodeEditor(this.root.querySelector(".app__code"), engine, { t });
    this.bindEngine();
    this.bindKeyboard();
    this.applyAppearance(readSetting("appearance", ""));
    // On a phone the inspector covers the page, so it starts closed there.
    this.setInspectorVisible(readSetting("inspector", "1") === "1" && !matchMedia("(max-width: 720px)").matches, { remember: false });

    files.onLaunchFiles((file) => file && this.openFile(file));
    files.onDroppedFiles(document.body, (file) => file && this.openFile(file), (hovering) => {
      this.root.classList.toggle("is-dropping", hovering);
    });
    window.addEventListener("beforeunload", (event) => {
      if (this.hasUnkeptChanges) {
        event.preventDefault();
        event.returnValue = "";
      }
    });
  }

  get isText() {
    return Boolean(this.engine.info?.isText);
  }

  // MARK: - Building

  build() {
    this.root.className = "app ds-window";
    this.root.innerHTML = `
      <div class="ds-menu-bar" id="menu-bar"></div>
      <div class="ds-toolbar" id="toolbar">
        <div class="ds-toolbar__title" data-overflow="never"><span class="app__title"></span><span class="ds-toolbar__subtitle app__subtitle"></span></div>
        <div class="ds-toolbar__separator"></div>
        <button class="ds-button ds-button--ghost ds-button--icon" data-command="undo">${icon("undo")}</button>
        <button class="ds-button ds-button--ghost ds-button--icon" data-command="redo">${icon("redo")}</button>
        <div class="ds-toolbar__separator app__rich"></div>
        <span class="ds-popup ds-popup--xs app__rich app__style-popup"><select class="ds-popup__select app__style-select" aria-label="${escapeHTML(t("ActionBar.Style"))}" title="${escapeHTML(t("ActionBar.Style"))}"></select>${icon("chevronDown", "ds-popup__chevron")}</span>
        <div class="ds-segmented ds-segmented--xs ds-segmented--icons app__rich" role="group" data-overflow-label="${escapeHTML(t("Mac.Menu.Font"))}" aria-label="${escapeHTML(t("Mac.Menu.Font"))}">
          <button class="ds-segmented__segment" data-command="bold" aria-pressed="false"><strong>B</strong></button>
          <button class="ds-segmented__segment" data-command="italic" aria-pressed="false"><em>I</em></button>
          <button class="ds-segmented__segment" data-command="underline" aria-pressed="false"><u>U</u></button>
          <button class="ds-segmented__segment" data-command="strike" aria-pressed="false"><s>S</s></button>
        </div>
        <div class="ds-segmented ds-segmented--xs ds-segmented--icons app__rich" role="radiogroup" data-overflow-label="${escapeHTML(t("ActionBar.Alignment"))}" aria-label="${escapeHTML(t("ActionBar.Alignment"))}">
          <button class="ds-segmented__segment" role="radio" data-align="left" aria-checked="false">${icon("alignLeft")}</button>
          <button class="ds-segmented__segment" role="radio" data-align="center" aria-checked="false">${icon("alignCenter")}</button>
          <button class="ds-segmented__segment" role="radio" data-align="right" aria-checked="false">${icon("alignRight")}</button>
          <button class="ds-segmented__segment" role="radio" data-align="justify" aria-checked="false">${icon("alignJustify")}</button>
        </div>
        <div class="ds-segmented ds-segmented--xs ds-segmented--icons app__rich" role="group" data-overflow-label="${escapeHTML(t("Mac.Toolbar.Lists"))}" aria-label="${escapeHTML(t("Mac.Toolbar.Lists"))}">
          <button class="ds-segmented__segment" data-command="bullets" aria-pressed="false">${icon("bullets")}</button>
          <button class="ds-segmented__segment" data-command="numbering" aria-pressed="false">${icon("numbers")}</button>
        </div>
        <div class="ds-toolbar__separator app__rich"></div>
        <button class="ds-button ds-button--ghost ds-button--icon app__rich" data-command="insertTable">${icon("table")}</button>
        <button class="ds-button ds-button--ghost ds-button--icon app__rich" data-command="insertPicture">${icon("picture")}</button>
        <span class="ds-popup ds-popup--xs app__plain app__language-popup"><select class="ds-popup__select app__language-select" aria-label="${escapeHTML(t("Mac.Toolbar.Language"))}" title="${escapeHTML(t("Mac.Toolbar.Language"))}"></select>${icon("chevronDown", "ds-popup__chevron")}</span>
        <div class="ds-toolbar__spacer"></div>
        <button class="ds-button ds-button--ghost ds-button--icon" data-command="find">${icon("search")}</button>
        <button class="ds-button ds-button--ghost ds-button--icon" data-command="toggleInspector" data-overflow="never" id="inspector-toggle">${icon("inspector")}</button>
      </div>
      <div class="ds-window__accessory app__accessory">
        <form class="app__find" hidden>
          <span class="ds-search ds-search--xs app__find-field">${icon("search", "ds-search__icon")}<input class="ds-search__input app__find-input" type="search" spellcheck="false" autocomplete="off"></span>
          <span class="ds-caption ds-numeric app__find-count" aria-live="polite"></span>
          <button class="ds-button ds-button--ghost ds-button--icon ds-button--xs" type="button" data-find="previous">${icon("chevronUp")}</button>
          <button class="ds-button ds-button--ghost ds-button--icon ds-button--xs" type="button" data-find="next">${icon("chevronDown")}</button>
          <input class="ds-text-input ds-text-input--xs app__replace-input" spellcheck="false" autocomplete="off">
          <button class="ds-button ds-button--bordered ds-button--xs" type="button" data-find="replace"></button>
          <button class="ds-button ds-button--bordered ds-button--xs" type="button" data-find="replaceAll"></button>
          <button class="ds-button ds-button--ghost ds-button--xs" type="button" data-find="done"></button>
        </form>
        <div class="app__banners" aria-live="polite"></div>
      </div>
      <div class="ds-window__content app__content">
        <div class="app__pages"></div>
        <div class="app__code" hidden></div>
        <section class="app__start" hidden></section>
        <div class="app__drop" aria-hidden="true"><p class="ds-heading-03"></p></div>
      </div>
      <div class="ds-status-bar app__status">
        <span class="app__status-page ds-numeric"></span><span class="app__status-words ds-numeric"></span>
        <span class="app__status-encoding"></span>
        <span class="ds-status-bar__spacer"></span>
        <span class="ds-popup ds-popup--xs app__zoom"><select class="ds-popup__select" aria-label="${escapeHTML(t("Mac.Menu.Zoom"))}">
          ${ZOOMS.map((z) => `<option value="${z}">${Math.round(z * 100)}%</option>`).join("")}
        </select>${icon("chevronDown", "ds-popup__chevron")}</span>
      </div>
      <aside class="ds-inspector ds-on-layer app__inspector" aria-label="${escapeHTML(t("Web.Inspector.Title"))}"></aside>`;

    this.titleElement = this.root.querySelector(".app__title");
    this.subtitleElement = this.root.querySelector(".app__subtitle");
    this.start = this.root.querySelector(".app__start");
    this.banners = this.root.querySelector(".app__banners");
    this.inspector = this.root.querySelector(".app__inspector");
    this.zoomSelect = this.root.querySelector(".app__zoom select");
    this.styleSelect = this.root.querySelector(".app__style-select");
    this.languageSelect = this.root.querySelector(".app__language-select");
    this.root.querySelector(".app__drop p").textContent = t("Web.Drop");

    this.buildToolbar();
    this.buildMenus();
    this.buildFind();
    this.inspectorPane = readSetting("inspectorPane", "text");
    this.zoomSelect.value = "1";
    this.zoomSelect.addEventListener("change", () => {
      this.pages.setZoom(Number(this.zoomSelect.value));
      this.focusEditor();
    });
    this.styleSelect.addEventListener("change", () => {
      const [kind, value] = this.styleSelect.value.split(":");
      this.withSelection((selection) => this.engine.call("style", { ...selection, ...(kind === "choice" ? { choice: value } : { id: value }) }));
    });
    this.languageSelect.addEventListener("change", async () => {
      await this.engine.call("setLanguage", { language: this.languageSelect.value });
      this.code.highlight();
      this.code.focus();
    });
  }

  buildToolbar() {
    const toolbar = this.root.querySelector("#toolbar");
    const labels = {
      undo: t("Toolbar.Undo"), redo: t("Toolbar.Redo"), bold: t("Toolbar.Bold"), italic: t("Toolbar.Italic"),
      underline: t("Toolbar.Underline"), strike: t("Toolbar.Strikethrough"), bullets: t("ActionBar.Bullets"),
      numbering: t("ActionBar.Numbering"), insertTable: t("Insert.Table").replace("…", ""),
      insertPicture: t("Insert.Picture").replace("…", ""), find: t("Toolbar.Find"), toggleInspector: t("Mac.Menu.ShowInspector"),
    };
    for (const button of toolbar.querySelectorAll("[data-command]")) {
      const label = labels[button.dataset.command];
      button.title = label;
      button.setAttribute("aria-label", label);
      // Keep the selection in the pages while a button is pressed.
      button.addEventListener("mousedown", (event) => event.preventDefault());
      button.addEventListener("click", () => this.run(button.dataset.command));
    }
    const alignLabels = { left: t("Mac.Menu.AlignLeft"), center: t("Mac.Menu.AlignCenter"), right: t("Mac.Menu.AlignRight"), justify: t("Mac.Menu.AlignJustified") };
    for (const button of toolbar.querySelectorAll("[data-align]")) {
      button.title = alignLabels[button.dataset.align];
      button.setAttribute("aria-label", button.title);
      button.addEventListener("mousedown", (event) => event.preventDefault());
      button.addEventListener("click", () => this.align(button.dataset.align));
    }
    this.toolbarOverflow = attachToolbarOverflow(toolbar, { label: t("Toolbar.More"), before: toolbar.querySelector("#inspector-toggle") });
  }

  buildFind() {
    const form = this.root.querySelector(".app__find");
    this.findForm = form;
    this.findInput = form.querySelector(".app__find-input");
    this.replaceInput = form.querySelector(".app__replace-input");
    this.findInput.placeholder = t("Web.Find.Placeholder");
    this.findInput.ariaLabel = t("Web.Find.Placeholder");
    this.replaceInput.placeholder = t("Web.Find.ReplacePlaceholder");
    this.replaceInput.ariaLabel = t("Web.Find.ReplacePlaceholder");
    const labels = {
      previous: t("Mac.Menu.Find.Previous"), next: t("Mac.Menu.Find.Next"), replace: t("Web.Find.Replace"),
      replaceAll: t("Web.Find.ReplaceAll"), done: t("Web.Common.Done"),
    };
    for (const button of form.querySelectorAll("[data-find]")) {
      const label = labels[button.dataset.find];
      if (button.classList.contains("ds-button--icon")) {
        button.title = label;
        button.ariaLabel = label;
      } else {
        button.textContent = label;
      }
      button.addEventListener("click", () => this.findAction(button.dataset.find));
    }
    form.addEventListener("submit", (event) => {
      event.preventDefault();
      this.findAction("next");
    });
    this.findInput.addEventListener("input", () => {
      this.findIndex = -1;
      this.updateFindCount();
    });
    form.addEventListener("keydown", (event) => {
      if (event.key === "Escape") this.findAction("done");
      if (event.key === "Enter" && event.target === this.findInput && event.shiftKey) {
        event.preventDefault();
        this.findAction("previous");
      }
    });
  }

  // MARK: - Commands

  get commands() {
    const state = this.engine.state;
    const info = this.engine.info;
    const hasDocument = Boolean(this.document);
    const rich = hasDocument && !this.isText;
    const look = this.look ?? {};
    const inTable = rich && Boolean(look.cell);
    return {
      new: { label: t("Mac.Menu.New"), shortcut: shortcut("N"), run: () => this.newDocument() },
      newText: { label: t("Web.Menu.NewTextFile"), run: () => this.newDocument({ text: true }) },
      open: { label: t("Mac.Menu.Open"), shortcut: shortcut("O"), run: () => this.openPicked() },
      close: { label: t("Mac.Menu.Close"), shortcut: shortcut("W"), enabled: hasDocument, run: () => this.closeDocument() },
      save: { label: t("Web.Menu.Save"), shortcut: shortcut("S"), enabled: hasDocument, run: () => this.save() },
      saveAs: { label: t("Web.Menu.SaveAs"), shortcut: shortcut("S", { shift: true }), enabled: hasDocument, run: () => this.saveAs() },
      rename: { label: t("Mac.Menu.Rename"), enabled: hasDocument, run: () => this.renameDocument() },
      print: { label: t("Mac.Menu.Print"), shortcut: shortcut("P"), enabled: rich, run: () => this.print() },
      undo: { label: t("Toolbar.Undo"), shortcut: shortcut("Z"), enabled: hasDocument && (this.isText || state?.canUndo || this.pages.dirty.size > 0), run: () => this.undo() },
      redo: { label: t("Toolbar.Redo"), shortcut: shortcut("Z", { shift: true }), enabled: hasDocument && (this.isText || state?.canRedo), run: () => this.redo() },
      cut: { label: t("Toolbar.Cut"), shortcut: shortcut("X"), enabled: hasDocument, run: () => this.clipboard("cut") },
      copy: { label: t("Toolbar.Copy"), shortcut: shortcut("C"), enabled: hasDocument, run: () => this.clipboard("copy") },
      paste: { label: t("Toolbar.Paste"), shortcut: shortcut("V"), enabled: hasDocument, run: () => this.clipboard("paste") },
      selectAll: { label: t("Mac.Menu.SelectAll"), shortcut: shortcut("A"), enabled: hasDocument, run: () => this.selectAll() },
      find: { label: t("Mac.Menu.Find.Find"), shortcut: shortcut("F"), enabled: hasDocument, run: () => this.showFind(false) },
      findReplace: { label: t("Mac.Menu.Find.FindReplace"), shortcut: shortcut("F", { alt: true }), enabled: hasDocument, run: () => this.showFind(true) },
      findNext: { label: t("Mac.Menu.Find.Next"), shortcut: shortcut("G"), enabled: hasDocument, run: () => this.findAction("next") },
      findPrevious: { label: t("Mac.Menu.Find.Previous"), shortcut: shortcut("G", { shift: true }), enabled: hasDocument, run: () => this.findAction("previous") },
      goToLine: { label: t("CodeEditor.GoToLine"), shortcut: shortcut("L"), enabled: hasDocument && this.isText, run: () => this.goToLine() },
      insertTable: { label: t("Insert.Table"), enabled: rich, run: () => this.insertTable() },
      insertPicture: { label: t("Insert.Picture"), enabled: rich, run: () => this.insertPicture() },
      pageBreak: { label: t("Insert.PageBreak"), shortcut: shortcut("↩"), enabled: rich, run: () => this.pages.insertPageBreak() },
      bold: { label: t("Toolbar.Bold"), shortcut: shortcut("B"), enabled: rich, checked: look.b, run: () => this.toggle("b") },
      italic: { label: t("Toolbar.Italic"), shortcut: shortcut("I"), enabled: rich, checked: look.i, run: () => this.toggle("i") },
      underline: { label: t("Toolbar.Underline"), shortcut: shortcut("U"), enabled: rich, checked: Boolean(look.u), run: () => this.toggle("u") },
      strike: { label: t("Toolbar.Strikethrough"), shortcut: shortcut("X", { shift: true }), enabled: rich, checked: Boolean(look.x), run: () => this.toggle("x") },
      bigger: { label: t("Format.Text.Size.Increase"), shortcut: shortcut("+"), enabled: rich, run: () => this.format({ zStep: 1 }) },
      smaller: { label: t("Format.Text.Size.Decrease"), shortcut: shortcut("-"), enabled: rich, run: () => this.format({ zStep: -1 }) },
      superscript: { label: t("Format.Superscript"), enabled: rich, checked: look.v === "super", run: () => this.format({ v: look.v === "super" ? null : "superscript" }) },
      subscript: { label: t("Format.Subscript"), enabled: rich, checked: look.v === "sub", run: () => this.format({ v: look.v === "sub" ? null : "subscript" }) },
      baseline: { label: t("Mac.Menu.Baseline.Default"), enabled: rich, run: () => this.format({ v: null }) },
      alignLeft: { label: t("Mac.Menu.AlignLeft"), enabled: rich, checked: look.align === "left" || look.align === "start", run: () => this.align("left") },
      alignCenter: { label: t("Mac.Menu.AlignCenter"), enabled: rich, checked: look.align === "center", run: () => this.align("center") },
      alignJustified: { label: t("Mac.Menu.AlignJustified"), enabled: rich, checked: look.align === "justify", run: () => this.align("justify") },
      alignRight: { label: t("Mac.Menu.AlignRight"), enabled: rich, checked: look.align === "right", run: () => this.align("right") },
      bullets: { label: t("ActionBar.Bullets"), shortcut: shortcut("L", { alt: true }), enabled: rich, checked: look.listed && this.listKind === "bulleted", run: () => this.list("bulleted") },
      numbering: { label: t("ActionBar.Numbering"), enabled: rich, checked: look.listed && this.listKind === "numbered", run: () => this.list("numbered") },
      indent: { label: t("Mac.Menu.IncreaseIndent"), shortcut: shortcut("]"), enabled: rich, run: () => this.withSelection((selection) => this.engine.call("indent", { ...selection, step: 1 })) },
      outdent: { label: t("Mac.Menu.DecreaseIndent"), shortcut: shortcut("["), enabled: rich, run: () => this.withSelection((selection) => this.engine.call("indent", { ...selection, step: -1 })) },
      clearFormatting: { label: t("Format.ClearAll"), enabled: rich, run: () => this.format({ clear: true }) },
      rowAbove: { label: t("Table.InsertAbove"), enabled: inTable, run: () => this.tableOperation("rowAbove") },
      rowBelow: { label: t("Table.InsertBelow"), enabled: inTable, run: () => this.tableOperation("rowBelow") },
      columnBefore: { label: t("Table.InsertLeft"), enabled: inTable, run: () => this.tableOperation("columnBefore") },
      columnAfter: { label: t("Table.InsertRight"), enabled: inTable, run: () => this.tableOperation("columnAfter") },
      deleteRow: { label: t("Table.DeleteRow"), enabled: inTable, run: () => this.tableOperation("deleteRow") },
      deleteColumn: { label: t("Table.DeleteColumn"), enabled: inTable, run: () => this.tableOperation("deleteColumn") },
      headerRow: { label: t("Table.Look.HeaderRow"), enabled: inTable, run: () => this.tableOperation("headerRow") },
      deleteTable: { label: t("ActionBar.DeleteTable"), enabled: inTable, run: () => this.tableOperation("deleteTable") },
      trackChanges: { label: t("Review.TrackChanges"), enabled: rich, checked: info?.trackRevisions, run: () => this.engine.call("trackChanges", { on: !info?.trackRevisions }) },
      acceptAll: { label: t("Review.AcceptAll"), enabled: rich && info?.hasRevisions, run: () => this.resolveRevisions(true) },
      rejectAll: { label: t("Review.RejectAll"), enabled: rich && info?.hasRevisions, run: () => this.resolveRevisions(false) },
      zoomIn: { label: t("Mac.Menu.ZoomIn"), shortcut: shortcut("="), enabled: rich, run: () => this.stepZoom(1) },
      zoomOut: { label: t("Mac.Menu.ZoomOut"), shortcut: shortcut("-", { alt: true }), enabled: rich, run: () => this.stepZoom(-1) },
      actualSize: { label: t("Mac.Menu.ActualSize"), shortcut: shortcut("0"), enabled: rich, run: () => this.pages.setZoom(1) },
      toggleInspector: { label: t("Mac.Menu.ShowInspector"), shortcut: shortcut("I", { alt: true }), checked: !this.inspector.hidden, run: () => this.setInspectorVisible(this.inspector.hidden) },
      fullScreen: {
        label: t("Mac.Menu.FullScreen"), enabled: Boolean(document.fullscreenEnabled), checked: Boolean(document.fullscreenElement),
        run: () => (document.fullscreenElement ? document.exitFullscreen() : document.documentElement.requestFullscreen()),
      },
      about: { label: t("Mac.Menu.About", "Libretto"), run: () => this.showAbout() },
      downloadApp: {
        label: t(appStorePlatform === "mac" ? "Web.Help.DownloadMacApp" : "Web.Help.DownloadiOSApp"),
        run: () => window.open(`${APP_STORE_URL}?platform=${appStorePlatform === "mac" ? "mac" : "iphone"}`, "_blank", "noopener"),
      },
    };
  }

  stepZoom(direction) {
    const current = this.pages.zoom;
    const next = direction > 0 ? ZOOMS.find((z) => z > current + 0.001) : [...ZOOMS].reverse().find((z) => z < current - 0.001);
    if (next) this.pages.setZoom(next);
  }

  run(id) {
    const command = this.commands[id];
    if (!command || command.enabled === false) return;
    return Promise.resolve(command.run()).catch((error) => this.showMessage(error.message, "error"));
  }

  item(id) {
    const command = this.commands[id];
    return {
      label: command.label,
      shortcut: command.shortcut,
      checked: command.checked === undefined ? undefined : Boolean(command.checked),
      disabled: "enabled" in command && !command.enabled,
      action: () => this.run(id),
    };
  }

  items(...ids) {
    return ids.map((id) => (id === "-" ? { separator: true } : this.item(id)));
  }

  buildMenus() {
    const self = this;
    const menus = [
      { label: t("Mac.Menu.File"), get items() { return self.fileMenu(); } },
      { label: t("Mac.Menu.Edit"), get items() {
        return [
          ...self.items("undo", "redo", "-", "cut", "copy", "paste", "selectAll", "-"),
          { label: t("Mac.Menu.Find"), submenu: self.items("find", "findReplace", "findNext", "findPrevious", "-", "goToLine") },
        ];
      } },
      { label: t("ActionBar.Insert"), get items() { return self.items("insertTable", "insertPicture", "-", "pageBreak"); } },
      { label: t("ActionBar.Format"), get items() { return self.formatMenu(); } },
      { label: t("Panel.Review.Title"), get items() { return self.items("trackChanges", "-", "acceptAll", "rejectAll"); } },
      { label: t("Mac.Menu.View"), get items() {
        const current = readSetting("appearance", "");
        return [
          ...self.items("zoomIn", "zoomOut", "actualSize", "-", "toggleInspector"),
          { label: t("Web.Menu.Appearance"), submenu: [
            { label: t("Web.Appearance.System"), checked: current === "", action: () => self.applyAppearance("") },
            { label: t("Web.Appearance.Light"), checked: current === "light", action: () => self.applyAppearance("light") },
            { label: t("Web.Appearance.Dark"), checked: current === "dark", action: () => self.applyAppearance("dark") },
          ] },
          { separator: true },
          self.item("fullScreen"),
        ];
      } },
      { label: t("Mac.Menu.Window"), get items() {
        return self.document ? [{ label: self.document.name, checked: true, action: () => self.focusEditor() }] : [{ label: "Libretto", disabled: true }];
      } },
      { label: t("Mac.Menu.Help"), get items() { return self.items(...(appStorePlatform ? ["downloadApp", "-"] : []), "about"); } },
    ];
    const bar = this.root.querySelector("#menu-bar");
    this.menuBarOverflow = attachMenuBar(bar, menus, { label: t("Web.Menu.Label"), overflowLabel: t("Toolbar.More") });
    // At the menu bar's trailing end. Added after the menus, so it never moves
    // into the » menu, and hidden until offerUpdate() shows it.
    const update = document.createElement("button");
    update.type = "button";
    update.className = "ds-button ds-button--ghost ds-button--xs app__update";
    update.innerHTML = `${icon("download")}<span></span>`;
    update.querySelector("span").textContent = t("Web.Update.Button");
    update.title = t("Web.Update.Available");
    update.hidden = true;
    bar.append(update);
    this.updateButton = update;
  }

  fileMenu() {
    const formats = this.engine.info?.saveFormats ?? [];
    return [
      ...this.items("new", "newText", "open"),
      { label: t("Mac.Menu.OpenRecent"), submenu: this.recentItems() },
      { separator: true },
      ...this.items("close", "save", "saveAs", "rename"),
      { separator: true },
      {
        label: t("Web.Menu.ExportTo"),
        disabled: !this.document || this.isText,
        submenu: formats.map((format) => ({ label: this.formatLabel(format.key), action: () => this.exportAs(format) })),
      },
      { separator: true },
      this.item("print"),
    ];
  }

  formatLabel(key) {
    const keys = { docx: "Web.Export.Word", docm: "Web.Export.MacroWord", md: "Web.Export.Markdown", txt: "Web.Export.PlainText", pages: "Web.Export.Pages" };
    return t(keys[key] ?? "Web.Export.PlainText");
  }

  recentItems() {
    const recents = this.recents ?? [];
    if (!recents.length) return [{ label: t("Web.Start.NoRecent"), disabled: true }];
    return [
      ...recents.slice(0, 10).map((record) => ({ label: record.name, action: () => this.openRecord(record) })),
      { separator: true },
      { label: t("Mac.Menu.ClearRecent"), action: async () => {
        await storage.clearRecents();
        await this.refreshRecents();
      } },
    ];
  }

  formatMenu() {
    const rich = Boolean(this.document) && !this.isText;
    const look = this.look ?? {};
    return [
      { label: t("Mac.Menu.Font"), submenu: this.items("bold", "italic", "underline", "strike", "-", "bigger", "smaller") },
      { label: t("Mac.Menu.Baseline"), submenu: this.items("superscript", "subscript", "-", "baseline") },
      { label: t("Mac.Menu.Text"), submenu: this.items("alignLeft", "alignCenter", "alignJustified", "alignRight") },
      { label: t("Mac.Toolbar.Lists"), submenu: this.items("bullets", "numbering", "-", "indent", "outdent") },
      {
        label: t("ActionBar.Style"), disabled: !rich,
        submenu: this.styleEntries().map((entry) => ({
          label: entry.label, checked: sameStyle(entry, this.styleEntry(look.paragraphStyle)),
          action: () => this.withSelection((selection) => this.engine.call("style", { ...selection, ...(entry.choice ? { choice: entry.choice } : { id: entry.id }) })),
        })),
      },
      { label: t("Panel.Table.Title"), disabled: !look.cell, submenu: this.items("rowAbove", "rowBelow", "columnBefore", "columnAfter", "-", "deleteRow", "deleteColumn", "-", "headerRow", "-", "deleteTable") },
      { separator: true },
      this.item("clearFormatting"),
    ];
  }

  /** The style entry a paragraph is in: its own, or Body for the document's default style. */
  styleEntry(styleID) {
    const entries = this.styleEntries();
    const info = this.engine.info;
    return entries.find((entry) => entry.id && entry.id === styleID)
      ?? (!styleID || styleID === info?.defaultStyle ? entries.find((entry) => entry.choice === "body") : null);
  }

  /** The paragraph styles to offer: the menu's built-in choices, then the document's own. */
  styleEntries() {
    const info = this.engine.info;
    if (!info) return [];
    const entries = info.styleChoices.map((choice) => ({ label: choice.label, choice: choice.choice, id: choice.id }));
    const taken = new Set(entries.map((entry) => entry.id).filter(Boolean));
    for (const style of info.paragraphStyles) {
      if (!taken.has(style.id)) entries.push({ label: style.name, id: style.id });
    }
    return entries;
  }

  // MARK: - Editing

  focusEditor() {
    if (this.isText) this.code.focus();
    else this.pages.focus();
  }

  /** Runs `body` with the selection, after the engine has every edit typed so far, then draws the result. */
  async withSelection(body) {
    if (!this.document || this.isText) return;
    await this.pages.sync();
    const selection = this.pages.selection();
    if (!selection) return;
    await body({ a: selection.anchor, f: selection.focus });
    this.pages.focus();
  }

  /** Sets run formatting on the selection, or, with nothing selected, on what is typed next. */
  async format(set) {
    if (!this.document || this.isText) return;
    const selection = this.pages.selection();
    if (!selection) return;
    const empty = selection.anchor.p === selection.focus.p && selection.anchor.o === selection.focus.o;
    if (empty) {
      const patch = {};
      for (const [key, value] of Object.entries(set)) {
        if (["b", "i", "u", "x"].includes(key)) patch[key] = value;
        if (key === "v") patch.v = value;
      }
      if (Object.keys(patch).length) {
        this.pages.setPendingStyle(patch);
        this.updateLook();
        return;
      }
    }
    await this.withSelection((positions) => this.engine.call("format", { ...positions, set }));
  }

  toggle(key) {
    const look = this.pages.lookAtSelection() ?? {};
    return this.format({ [key]: !look[key] });
  }

  align(alignment) {
    const value = { left: "left", center: "center", right: "right", justify: "both" }[alignment];
    return this.withSelection((selection) => this.engine.call("paragraph", { ...selection, set: { align: value } }));
  }

  async list(kind) {
    await this.withSelection((selection) => this.engine.call("list", { ...selection, kind }));
  }

  async tableOperation(op) {
    const look = this.pages.lookAtSelection();
    if (!look?.cell) return;
    await this.pages.sync();
    await this.engine.call("table", { cell: look.cell, op });
  }

  async resolveRevisions(accept) {
    await this.pages.sync();
    await this.engine.call("revisions", { accept });
  }

  async undo() {
    if (this.isText) {
      document.execCommand("undo");
      return;
    }
    await this.pages.sync();
    await this.engine.call("undo");
  }

  async redo() {
    if (this.isText) {
      document.execCommand("redo");
      return;
    }
    await this.pages.sync();
    await this.engine.call("redo");
  }

  clipboard(action) {
    this.focusEditor();
    if (action === "paste") {
      navigator.clipboard?.readText?.().then((text) => {
        if (this.isText) this.code.insert(text);
        else this.pages.insertText(text);
      }).catch(() => this.showMessage(t("Web.Clipboard.PasteShortcut", shortcut("V")), "info"));
      return;
    }
    document.execCommand(action);
  }

  selectAll() {
    if (this.isText) {
      this.code.selectAll();
      return;
    }
    this.pages.focus();
    const selection = document.getSelection();
    selection.selectAllChildren(this.pages.flow);
  }

  async insertTable() {
    const size = await this.askTableSize();
    if (!size) return;
    await this.withSelection((selection) => this.engine.call("insertTable", { at: selection.focus, ...size }));
  }

  async insertPicture() {
    const file = await files.pickFile({ pictures: true }).catch(() => null);
    if (!file) return;
    await this.insertPictureBytes(file.bytes);
  }

  async insertPictureBytes(bytes) {
    const size = await new Promise((resolve) => {
      const image = new Image();
      const url = URL.createObjectURL(new Blob([bytes]));
      image.onload = () => {
        resolve({ width: image.naturalWidth * 0.75, height: image.naturalHeight * 0.75 });
        URL.revokeObjectURL(url);
      };
      image.onerror = () => {
        resolve(null);
        URL.revokeObjectURL(url);
      };
      image.src = url;
    });
    if (!size) {
      this.showMessage(t("Alert.Picture.Failed"), "error");
      return;
    }
    await this.withSelection((selection) => this.engine.call("insertImage", { at: selection.focus, ...size }, bytes))
      .catch(() => this.showMessage(t("Alert.Picture.Failed"), "error"));
  }

  print() {
    window.print();
  }

  // MARK: - Find

  showFind(replacing) {
    this.findForm.hidden = false;
    this.findForm.classList.toggle("is-replacing", replacing);
    const selected = this.isText ? this.code.selectedText() : document.getSelection()?.toString();
    if (selected && !selected.includes("\n")) this.findInput.value = selected;
    this.findIndex = -1;
    this.updateFindCount();
    this.findInput.focus();
    this.findInput.select();
  }

  matches() {
    const query = this.findInput.value;
    return this.isText ? this.code.find(query) : this.pages.find(query);
  }

  updateFindCount(index = -1) {
    const count = this.findInput.value ? this.matches().length : 0;
    const output = this.root.querySelector(".app__find-count");
    if (!this.findInput.value) output.textContent = "";
    else if (!count) output.textContent = t("Web.Find.NoMatches");
    else output.textContent = index >= 0 ? t("Web.Find.Count", index + 1, count) : t("Web.Find.Total", count);
  }

  async findAction(action) {
    if (action === "done") {
      this.findForm.hidden = true;
      this.focusEditor();
      return;
    }
    if (this.findForm.hidden) this.showFind(false);
    const matches = this.matches();
    if (action === "replaceAll") {
      if (!matches.length) return;
      if (this.isText) {
        this.code.replaceAll(this.findInput.value, this.replaceInput.value);
      } else {
        // From the end, so earlier matches stay where they were found.
        for (const match of [...matches].reverse()) {
          this.pages.showMatch(match);
          this.pages.replaceSelection(this.replaceInput.value);
        }
        await this.pages.sync();
      }
      this.updateFindCount();
      return;
    }
    if (action === "replace" && this.findIndex >= 0 && matches[this.findIndex]) {
      if (this.isText) this.code.replaceSelection(this.replaceInput.value);
      else this.pages.replaceSelection(this.replaceInput.value);
    }
    const fresh = this.matches();
    if (!fresh.length) {
      this.updateFindCount();
      return;
    }
    const step = action === "previous" ? -1 : action === "replace" ? 0 : 1;
    this.findIndex = ((this.findIndex < 0 && step <= 0 ? 0 : this.findIndex + step) + fresh.length) % fresh.length;
    if (this.isText) this.code.showMatch(fresh[this.findIndex]);
    else this.pages.showMatch(fresh[this.findIndex]);
    this.updateFindCount(this.findIndex);
  }

  async goToLine() {
    const lines = this.code.lineCount();
    const answer = await this.askText(t("CodeEditor.GoToLine.Title"), "", t("CodeEditor.GoToLine.Go"), {
      message: t("CodeEditor.GoToLine.Message", lines), placeholder: t("CodeEditor.GoToLine.Placeholder"), numeric: true,
    });
    const line = Number(answer);
    if (Number.isInteger(line) && line >= 1) this.code.goToLine(Math.min(line, lines));
  }

  // MARK: - Inspector

  renderInspector() {
    const info = this.engine.info;
    if (!info || !this.document) {
      this.inspector.replaceChildren();
      return;
    }
    const look = this.look ?? {};
    const panes = this.isText
      ? [["document", t("Web.Inspector.Document")]]
      : [["text", t("Format.Section.Text")], ["paragraph", t("Panel.Paragraph.Title")], ["document", t("Web.Inspector.Document")],
        ...(look.cell ? [["table", t("Panel.Table.Title")]] : [])];
    if (!panes.some(([key]) => key === this.inspectorPane)) this.inspectorPane = panes[0][0];
    const section = (title, body, open = true) => `
      <details class="ds-disclosure"${open ? " open" : ""}>
        <summary>${icon("chevronDown", "ds-disclosure__triangle app__triangle")}${escapeHTML(title)}</summary>
        <div class="ds-disclosure__body ds-form">${body}</div>
      </details>`;
    const row = (label, control) => `<span class="ds-form__label">${label ? escapeHTML(label) : ""}</span><span class="ds-form__control">${control}</span>`;
    const popup = (name, label, options) => `<span class="ds-popup ds-popup--xs app__inspector-popup"><select class="ds-popup__select" data-field="${name}" aria-label="${escapeHTML(label)}">${options}</select>${icon("chevronDown", "ds-popup__chevron")}</span>`;
    const stepper = (name, label, value, step = 1) => `
      <span class="ds-stepper ds-stepper--xs"><input class="ds-stepper__input" type="number" step="${step}" data-field="${name}" value="${value}" aria-label="${escapeHTML(label)}">
        <span class="ds-stepper__arrows">
          <button class="ds-stepper__arrow" type="button" data-step="${step}" aria-label="${escapeHTML(t("Format.Text.Size.Increase"))}">${icon("chevronUp")}</button>
          <button class="ds-stepper__arrow" type="button" data-step="${-step}" aria-label="${escapeHTML(t("Format.Text.Size.Decrease"))}">${icon("chevronDown")}</button>
        </span></span>`;
    const button = (command) => {
      const entry = this.commands[command];
      return `<button class="ds-button ds-button--bordered ds-button--xs" type="button" data-run="${command}"${entry.enabled === false ? " disabled" : ""}>${escapeHTML(entry.label.replace("…", ""))}</button>`;
    };
    const check = (name, label, checked) => `<label class="ds-check"><input type="checkbox" data-field="${name}"${checked ? " checked" : ""}>${escapeHTML(label)}</label>`;

    let body = "";
    if (this.inspectorPane === "text") {
      const families = [...new Set([...(info.fonts ?? []).filter((name) => !name.startsWith("+")), ...fonts.installedFamilies()])].sort((a, b) => a.localeCompare(b, language));
      const current = look.font ?? "";
      const fontOptions = [`<option value="">${escapeHTML(t("Mac.Format.SystemFont"))}</option>`,
        ...(current && !families.includes(current) ? [current] : []).concat(families)
          .map((family) => `<option value="${escapeHTML(family)}"${family === current ? " selected" : ""}>${escapeHTML(family)}</option>`)].join("");
      const highlightOptions = [`<option value="">${escapeHTML(t("Highlight.None"))}</option>`,
        ...HIGHLIGHTS.map((name) => `<option value="${name}"${look.highlight === name ? " selected" : ""}>${escapeHTML(t(`Highlight.${name}`))}</option>`)].join("");
      body = section(t("Format.Font"),
        row(t("Format.Font"), popup("font", t("Format.Font"), fontOptions))
        + row(t("Format.Text.Size"), stepper("size", t("Format.Text.Size"), look.z ?? 11, 1))
        + row(t("Mac.Format.Colour"), `<input type="color" class="ds-color-well" data-field="color" value="${escapeHTML(look.color ?? "#000000")}" aria-label="${escapeHTML(t("Mac.Format.Colour"))}">`)
        + row(t("Format.Section.Highlight"), popup("highlight", t("Format.Section.Highlight"), highlightOptions)))
        + section(t("Format.Section.Text"), `<span class="ds-form__label"></span><span class="ds-form__control app__inspector-buttons">${["bold", "italic", "underline", "strike", "superscript", "subscript"].map(button).join("")}</span>`
        + `<span class="ds-form__label"></span><span class="ds-form__control">${button("clearFormatting")}</span>`);
    } else if (this.inspectorPane === "paragraph") {
      const currentStyle = this.styleEntry(look.paragraphStyle);
      const styleOptions = this.styleEntries().map((entry) => `<option value="${entry.choice ? `choice:${entry.choice}` : `id:${escapeHTML(entry.id)}`}"${sameStyle(entry, currentStyle) ? " selected" : ""}>${escapeHTML(entry.label)}</option>`).join("");
      const spacing = look.spacing ?? {};
      body = section(t("Paragraph.Section.Style"), row(t("ActionBar.Style"), popup("style", t("ActionBar.Style"), styleOptions)))
        + section(t("Paragraph.Section.Alignment"), `<span class="ds-form__label"></span><span class="ds-form__control app__inspector-buttons">${["alignLeft", "alignCenter", "alignJustified", "alignRight"].map(button).join("")}</span>`
          + `<span class="ds-form__label"></span><span class="ds-form__control app__inspector-buttons">${["bullets", "numbering", "indent", "outdent"].map(button).join("")}</span>`)
        + section(t("Paragraph.Section.Spacing"),
          row(t("Mac.Format.SpacingBefore"), stepper("before", t("Mac.Format.SpacingBefore"), spacing.before ?? 0, 2))
          + row(t("Mac.Format.SpacingAfter"), stepper("after", t("Mac.Format.SpacingAfter"), spacing.after ?? 0, 2))
          + row(t("Paragraph.LineSpacing"), popup("line", t("Paragraph.LineSpacing"), [1, 1.15, 1.5, 2, 2.5, 3].map((value) => `<option value="${value}"${Math.abs((spacing.line ?? 1) - value) < 0.01 ? " selected" : ""}>${this.numberFormat.format(value)}</option>`).join(""))))
        + section(t("Paragraph.Section.Pagination"),
          `<span class="ds-form__label"></span><span class="ds-form__control">${check("keepNext", t("Paragraph.KeepWithNext"), spacing.keepNext)}</span>`
          + `<span class="ds-form__label"></span><span class="ds-form__control">${check("pageBreakBefore", t("Paragraph.PageBreakBefore"), spacing.pageBreakBefore)}</span>`);
    } else if (this.inspectorPane === "table") {
      body = section(t("Table.Section.RowsColumns"), `<span class="ds-form__label"></span><span class="ds-form__control app__inspector-buttons">${["rowAbove", "rowBelow", "columnBefore", "columnAfter"].map(button).join("")}</span>`
        + `<span class="ds-form__label"></span><span class="ds-form__control app__inspector-buttons">${["deleteRow", "deleteColumn"].map(button).join("")}</span>`)
        + section(t("Table.Section.Table"), `<span class="ds-form__label"></span><span class="ds-form__control app__inspector-buttons">${["headerRow", "deleteTable"].map(button).join("")}</span>`);
    } else if (this.isText) {
      body = section(t("CodeEditor.TextFile"),
        row(t("Mac.Toolbar.Language"), `<span class="ds-caption">${escapeHTML(info.languages?.find((entry) => entry.id === info.language)?.name ?? "")}</span>`)
        + row(t("Mac.CodeEditor.Encoding"), `<span class="ds-caption">${escapeHTML(info.encoding ?? "")}</span>`)
        + row(t("Mac.CodeEditor.LineEndings"), `<span class="ds-caption">${escapeHTML((info.lineEnding ?? "").toUpperCase())}</span>`));
    } else {
      const setup = info.pageSetup;
      const portrait = setup.width <= setup.height;
      const short = Math.min(setup.width, setup.height);
      const long = Math.max(setup.width, setup.height);
      const paper = PAPERS.find((candidate) => Math.abs(candidate.width - short) < 2 && Math.abs(candidate.height - long) < 2);
      const paperOptions = [...PAPERS.map((candidate) => `<option value="${candidate.key}"${candidate === paper ? " selected" : ""}>${escapeHTML(t(candidate.key))}</option>`),
        ...(paper ? [] : [`<option value="" selected>${escapeHTML(t("PageSetup.Paper.Custom", Math.round(short / 72 * 25.4), Math.round(long / 72 * 25.4)))}</option>`])].join("");
      const margin = (key, label) => row(label, stepper(`margin:${key}`, label, Math.round(setup[key] / 72 * 25.4 * 10) / 10, 1) + `<span class="ds-caption">mm</span>`);
      body = section(t("PageSetup.Section.Paper"),
        row(t("PageSetup.Paper"), popup("paper", t("PageSetup.Paper"), paperOptions))
        + row(t("PageSetup.Orientation"), popup("orientation", t("PageSetup.Orientation"),
          `<option value="portrait"${portrait ? " selected" : ""}>${escapeHTML(t("PageSetup.Portrait"))}</option><option value="landscape"${portrait ? "" : " selected"}>${escapeHTML(t("PageSetup.Landscape"))}</option>`)))
        + section(t("PageSetup.Section.Margins"), margin("top", t("Mac.Page.Top")) + margin("bottom", t("Mac.Page.Bottom")) + margin("left", t("Mac.Page.Left")) + margin("right", t("Mac.Page.Right")))
        + section(t("Review.Section.Changes"),
          `<span class="ds-form__label"></span><span class="ds-form__control">${check("track", t("Review.TrackChanges"), info.trackRevisions)}</span>`
          + `<span class="ds-form__label"></span><span class="ds-form__control app__inspector-buttons">${["acceptAll", "rejectAll"].map(button).join("")}</span>`)
        + section(t("Panel.Comments.Title"), info.comments.length
          ? `<ul class="app__comments">${info.comments.map((comment) => `<li class="app__comment${comment.done ? " is-done" : ""}"><span class="ds-heading-compact">${escapeHTML(comment.author)}</span><span class="ds-document-content app__comment-text">${escapeHTML(comment.text)}</span></li>`).join("")}</ul>`
          : `<p class="ds-caption">${escapeHTML(t("Comments.None"))}</p>`, info.comments.length > 0);
    }

    this.inspector.innerHTML = `
      <div class="ds-inspector__switcher">
        <div class="ds-segmented ds-segmented--xs ds-segmented--fill" role="tablist">
          ${panes.map(([key, label]) => `<button class="ds-segmented__segment" role="tab" type="button" data-pane="${key}" aria-selected="${key === this.inspectorPane}">${escapeHTML(label)}</button>`).join("")}
        </div>
      </div>
      <div class="ds-inspector__body">${body}</div>`;
    this.bindInspector();
  }

  bindInspector() {
    const inspector = this.inspector;
    for (const tab of inspector.querySelectorAll("[data-pane]")) {
      tab.addEventListener("click", () => {
        this.inspectorPane = tab.dataset.pane;
        writeSetting("inspectorPane", this.inspectorPane);
        this.renderInspector();
      });
    }
    for (const element of inspector.querySelectorAll("[data-run]")) {
      element.addEventListener("mousedown", (event) => event.preventDefault());
      element.addEventListener("click", () => this.run(element.dataset.run));
    }
    for (const arrow of inspector.querySelectorAll(".ds-stepper__arrow")) {
      arrow.addEventListener("mousedown", (event) => event.preventDefault());
      arrow.addEventListener("click", () => {
        const input = arrow.closest(".ds-stepper").querySelector("input");
        input.value = String(Math.max(0, Number(input.value || 0) + Number(arrow.dataset.step)));
        input.dispatchEvent(new Event("change"));
      });
    }
    for (const field of inspector.querySelectorAll("[data-field]")) {
      field.addEventListener("change", () => this.inspectorChanged(field));
    }
  }

  async inspectorChanged(field) {
    const name = field.dataset.field;
    const value = field.type === "checkbox" ? field.checked : field.value;
    const setup = this.engine.info?.pageSetup;
    switch (name) {
      case "font": return this.format({ f: value || null });
      case "size": return Number(value) > 0 && this.format({ z: Number(value) });
      case "color": return this.format({ c: value });
      case "highlight": return this.format({ hl: value || null });
      case "style": {
        const [kind, id] = value.split(":");
        return this.withSelection((selection) => this.engine.call("style", { ...selection, ...(kind === "choice" ? { choice: id } : { id }) }));
      }
      case "before":
      case "after":
        return this.withSelection((selection) => this.engine.call("paragraph", { ...selection, set: { [name]: Number(value) } }));
      case "line":
        return this.withSelection((selection) => this.engine.call("paragraph", { ...selection, set: { line: Number(value) } }));
      case "keepNext":
      case "pageBreakBefore":
        return this.withSelection((selection) => this.engine.call("paragraph", { ...selection, set: { [name]: value || null } }));
      case "track":
        return this.engine.call("trackChanges", { on: value });
      case "paper": {
        const paper = PAPERS.find((candidate) => candidate.key === value);
        if (!paper || !setup) return;
        const landscape = setup.width > setup.height;
        return this.engine.call("pageSetup", landscape ? { width: paper.height, height: paper.width } : { width: paper.width, height: paper.height });
      }
      case "orientation": {
        if (!setup) return;
        const landscape = value === "landscape";
        if (landscape === setup.width > setup.height) return;
        return this.engine.call("pageSetup", {
          width: setup.height, height: setup.width,
          top: landscape ? setup.left : setup.right, bottom: landscape ? setup.right : setup.left,
          left: landscape ? setup.bottom : setup.top, right: landscape ? setup.top : setup.bottom,
        });
      }
      default:
        if (name.startsWith("margin:")) {
          const millimetres = Number(value);
          if (millimetres >= 0) return this.engine.call("pageSetup", { [name.slice(7)]: millimetres / 25.4 * 72 });
        }
    }
  }

  setInspectorVisible(visible, { remember = true } = {}) {
    this.inspector.hidden = !visible;
    this.root.querySelector("#inspector-toggle").setAttribute("aria-pressed", String(visible));
    if (remember) writeSetting("inspector", visible ? "1" : "0");
    if (visible) this.renderInspector();
  }

  // MARK: - Engine events

  bindEngine() {
    this.engine.addEventListener("state", () => this.update());
    this.engine.addEventListener("document", () => {
      this.updateTitle();
      this.updateStyles();
      this.renderInspector();
    });
    this.engine.addEventListener("content", async (event) => {
      if (!this.document && !event.detail.isNew) return;
      if (this.isText) {
        await this.code.load();
      } else {
        await this.pages.refresh({ keepSelection: !event.detail.isNew });
      }
      this.updateLook();
    });
    this.engine.addEventListener("fatal", () => this.showMessage(t("Web.Error.Engine"), "error", {
      action: { label: t("Web.Error.Reload"), run: () => location.reload() },
      sticky: true,
    }));
    for (const editor of [this.pages, this.code]) {
      editor.addEventListener("command", (event) => this.run(event.detail));
      editor.addEventListener("message", (event) => this.showMessage(event.detail, "error"));
    }
    this.pages.addEventListener("selection", () => this.updateLook());
    this.pages.addEventListener("pages", () => this.updateStatus());
    this.pages.addEventListener("edited", () => this.scheduleWordCount());
    this.code.addEventListener("edited", () => this.updateStatus());
    this.pages.addEventListener("zoom", (event) => {
      const zoom = event.detail;
      const preset = [...this.zoomSelect.options].find((option) => !option.dataset.custom && Math.abs(Number(option.value) - zoom) < 0.005);
      let custom = this.zoomSelect.querySelector("[data-custom]");
      if (preset) {
        custom?.remove();
        this.zoomSelect.value = preset.value;
        return;
      }
      if (!custom) {
        custom = new Option("", "");
        custom.dataset.custom = "1";
        this.zoomSelect.add(custom);
      }
      custom.value = String(zoom);
      custom.textContent = new Intl.NumberFormat(language, { style: "percent" }).format(zoom);
      this.zoomSelect.value = custom.value;
    });
    this.pages.flow.addEventListener("paste", (event) => {
      const file = [...(event.clipboardData?.files ?? [])].find((candidate) => candidate.type.startsWith("image/"));
      if (!file) return;
      event.stopImmediatePropagation();
      file.arrayBuffer().then((buffer) => this.insertPictureBytes(new Uint8Array(buffer)));
    }, true);
  }

  /** The look at the selection, for the toolbar and inspector, a frame after it moves. */
  updateLook() {
    cancelAnimationFrame(this.lookFrame);
    this.lookFrame = requestAnimationFrame(() => {
      if (!this.document || this.isText) return;
      const look = this.pages.lookAtSelection();
      if (!look) return;
      const paragraph = this.pages.paragraphOf(document.getSelection()?.anchorNode);
      const style = paragraph?.style;
      look.spacing = {
        before: Math.round(parseFloat(style?.paddingTop || "0") * 10) / 10,
        after: Math.round(parseFloat(style?.paddingBottom || "0") * 10) / 10,
        line: style?.lineHeight && !style.lineHeight.endsWith("pt") ? Number(style.lineHeight) / 1.15 : 1,
        keepNext: paragraph?.dataset.kn === "1",
        pageBreakBefore: paragraph?.dataset.pb === "1",
      };
      look.font = look.f?.match(/^"([^"]+)"/)?.[1] ?? null;
      look.color = look.c?.[0] ?? null;
      look.highlight = Object.entries({ yellow: "#ffff00", green: "#00ff00", cyan: "#00ffff", magenta: "#ff00ff", red: "#ff0000", blue: "#0000ff", lightGray: "#c0c0c0", darkYellow: "#808000" })
        .find(([, hex]) => hex === look.hl?.[0])?.[0] ?? null;
      const label = paragraph?.dataset.l ?? "";
      this.listKind = /^[0-9a-zA-Z]/.test(label) ? "numbered" : label ? "bulleted" : null;
      const previousCell = this.look?.cell ?? null;
      const previousParagraph = this.look?.paragraph;
      this.look = { ...look, paragraph: paragraph?.dataset.id };
      const toolbar = this.root.querySelector("#toolbar");
      for (const [command, key] of [["bold", "b"], ["italic", "i"], ["underline", "u"], ["strike", "x"]]) {
        toolbar.querySelector(`[data-command="${command}"]`).setAttribute("aria-pressed", String(Boolean(look[key])));
      }
      const align = look.align === "start" ? "left" : look.align;
      for (const button of toolbar.querySelectorAll("[data-align]")) button.setAttribute("aria-checked", String(button.dataset.align === align));
      toolbar.querySelector('[data-command="bullets"]').setAttribute("aria-pressed", String(this.listKind === "bulleted"));
      toolbar.querySelector('[data-command="numbering"]').setAttribute("aria-pressed", String(this.listKind === "numbered"));
      const selectedStyle = this.styleEntry(look.paragraphStyle);
      this.styleSelect.value = selectedStyle ? (selectedStyle.choice ? `choice:${selectedStyle.choice}` : `id:${selectedStyle.id}`) : "";
      if (!this.inspector.hidden && (previousCell !== this.look.cell || previousParagraph !== this.look.paragraph || this.inspectorPane !== "document")) {
        if (!this.inspector.contains(document.activeElement)) this.renderInspector();
      }
      this.updateStatus();
    });
  }

  updateStyles() {
    const entries = this.styleEntries();
    this.styleSelect.innerHTML = [`<option value="" hidden></option>`,
      ...entries.map((entry) => `<option value="${entry.choice ? `choice:${escapeHTML(entry.choice)}` : `id:${escapeHTML(entry.id)}`}">${escapeHTML(entry.label)}</option>`)].join("");
    const info = this.engine.info;
    if (info?.languages) {
      this.languageSelect.innerHTML = info.languages.map((entry) => `<option value="${escapeHTML(entry.id)}">${escapeHTML(entry.name)}</option>`).join("");
      this.languageSelect.value = info.language;
    }
  }

  update() {
    const state = this.engine.state;
    if (!state) return;
    const toolbar = this.root.querySelector("#toolbar");
    toolbar.querySelector('[data-command="undo"]').disabled = !this.isText && !state.canUndo;
    toolbar.querySelector('[data-command="redo"]').disabled = !this.isText && !state.canRedo;
    this.updateTitle();
    if (this.hasUnkeptChanges && !this.autosaveTimer) this.scheduleAutosave();
  }

  scheduleWordCount() {
    clearTimeout(this.wordCountTimer);
    this.wordCountTimer = setTimeout(async () => {
      if (!this.document) return;
      await this.engine.refreshInfo().catch(() => {});
      this.updateStatus();
    }, 1200);
  }

  updateStatus() {
    const info = this.engine.info;
    const page = this.root.querySelector(".app__status-page");
    const words = this.root.querySelector(".app__status-words");
    const encoding = this.root.querySelector(".app__status-encoding");
    if (!this.document || !info) {
      page.textContent = words.textContent = encoding.textContent = "";
      return;
    }
    if (this.isText) {
      const { line, column } = this.code.caret();
      page.textContent = t("Web.Status.LineColumn", line, column);
      words.textContent = "";
      encoding.textContent = `${info.encoding ?? ""} · ${(info.lineEnding ?? "").toUpperCase()}`;
      return;
    }
    page.textContent = t("Web.Status.Page", this.pages.currentPage(), this.pages.pageCount ?? 1);
    words.textContent = t("Mobile.WordCount", info.wordCount ?? 0);
    encoding.textContent = "";
  }

  updateTitle() {
    const name = this.document?.name ?? "Libretto";
    this.titleElement.textContent = name;
    const edited = this.engine.state?.edited;
    this.subtitleElement.textContent = this.document ? (edited ? t("Web.Document.Edited") : this.document.handle ? t("Web.Document.Saved") : "") : "";
    document.title = this.document ? `${name}${edited ? " — " + t("Web.Document.Edited") : ""}` : "Libretto";
    this.root.classList.toggle("is-text", this.isText);
  }

  // MARK: - Messages

  showMessage(text, kind = "info", { action = null, sticky = false } = {}) {
    if (!text) return;
    const banner = document.createElement("div");
    banner.className = `ds-notification ds-notification--${kind === "info" ? "info" : kind} app__banner`;
    banner.setAttribute("role", kind === "error" ? "alert" : "status");
    banner.innerHTML = `${icon(kind === "error" ? "error" : kind === "warning" ? "warning" : "info", "ds-icon--20")}<div></div>
      <span class="app__banner-actions"></span>`;
    banner.querySelector("div").textContent = text;
    const actions = banner.querySelector(".app__banner-actions");
    if (action) {
      const button = document.createElement("button");
      button.className = "ds-button ds-button--bordered ds-button--xs";
      button.textContent = action.label;
      button.addEventListener("click", () => {
        banner.remove();
        action.run();
      });
      actions.append(button);
    }
    const close = document.createElement("button");
    close.className = "ds-button ds-button--ghost ds-button--icon ds-button--xs";
    close.innerHTML = icon("close");
    close.ariaLabel = close.title = t("Web.Common.Close");
    close.addEventListener("click", () => banner.remove());
    actions.append(close);
    this.banners.append(banner);
    if (!sticky) setTimeout(() => banner.remove(), kind === "error" ? 8000 : 5000);
  }

  /** What the document has that Libretto keeps but can't edit, and what can't be saved back. */
  showNotices() {
    const info = this.engine.info;
    if (!info) return;
    if (info.unsupported?.length) {
      this.showMessage(`${t("Notice.UnsupportedFeatures.Message")} ${new Intl.ListFormat(language, { type: "conjunction" }).format(info.unsupported)}`, "info");
    }
    if (info.format === "pages" && !info.saveFormats.some((format) => format.key === "pages")) {
      this.showMessage(t("Mac.Notice.Converted"), "info");
    }
  }

  showAbout() {
    const backdrop = document.createElement("div");
    backdrop.className = "ds-sheet-backdrop app__sheet-backdrop";
    backdrop.innerHTML = `
      <div class="ds-sheet ds-alert app__about" role="alertdialog" aria-labelledby="about-title" aria-describedby="about-message">
        <div class="ds-sheet__body">
          <img class="app__about-icon" src="app/icons/icon.svg" width="48" height="48" alt="" draggable="false">
          <div>
            <h2 class="ds-sheet__title" id="about-title">Libretto</h2>
            <p class="ds-caption app__about-version"></p>
            <p class="ds-sheet__message" id="about-message"></p>
            <p class="ds-sheet__message app__about-suite"><a href="https://atelier.ktgk.app" target="_blank" rel="noopener"></a></p>
          </div>
        </div>
        <div class="ds-sheet__buttons">
          <button class="ds-button" type="button" data-source>${escapeHTML(t("Toolbar.SourceCode"))}</button>
          <button class="ds-button ds-button--primary" type="button" data-close>${escapeHTML(t("Web.Common.Close"))}</button>
        </div>
      </div>`;
    backdrop.querySelector("#about-message").textContent = t("Web.About.Message");
    backdrop.querySelector(".app__about-version").textContent = t("Web.About.Version", self.LIBRETTO_APP_VERSION ?? "");
    backdrop.querySelector(".app__about-suite a").textContent = t("Web.About.Suite");
    const close = () => {
      dismissSheet(backdrop);
      this.focusEditor();
    };
    backdrop.querySelector("[data-close]").addEventListener("click", close);
    backdrop.querySelector("[data-source]").addEventListener("click", () => window.open(SOURCE_CODE_URL, "_blank", "noopener"));
    backdrop.addEventListener("keydown", (event) => event.key === "Escape" && close());
    this.root.append(backdrop);
    backdrop.querySelector("[data-close]").focus();
  }

  /**
   * Shows the menu bar's Update button. Pressing it downloads the new version
   * with `download(onProgress)` in a sheet, then reloads into it.
   */
  offerUpdate(download) {
    this.updateButton.hidden = false;
    this.menuBarOverflow.layout();
    this.updateButton.onclick = () => this.showUpdate(download);
  }

  showUpdate(download) {
    const backdrop = document.createElement("div");
    backdrop.className = "ds-sheet-backdrop app__sheet-backdrop";
    backdrop.innerHTML = `
      <div class="ds-sheet" role="dialog" aria-labelledby="update-title" aria-describedby="update-message">
        <div class="ds-sheet__body app__update-body">
          <h2 class="ds-sheet__title" id="update-title">${escapeHTML(t("Web.Update.Title"))}</h2>
          <p class="ds-sheet__message" id="update-message"></p>
          <div class="ds-progress" role="progressbar" aria-labelledby="update-title" aria-valuemin="0" aria-valuemax="100" aria-valuenow="0"><div class="ds-progress__bar"></div></div>
        </div>
        <div class="ds-sheet__buttons">
          <button class="ds-button" type="button" data-cancel>${escapeHTML(t("Web.Common.Cancel"))}</button>
          <button class="ds-button ds-button--primary" type="button" data-retry hidden>${escapeHTML(t("Web.Update.TryAgain"))}</button>
        </div>
      </div>`;
    const message = backdrop.querySelector("#update-message");
    const progress = backdrop.querySelector(".ds-progress");
    const retry = backdrop.querySelector("[data-retry]");
    const setProgress = (fraction) => {
      const percent = Math.round(Math.min(Math.max(fraction, 0), 1) * 100);
      progress.style.setProperty("--ds-progress", `${percent}%`);
      progress.setAttribute("aria-valuenow", String(percent));
    };
    let open = true;
    const close = () => {
      // The download carries on in the service worker; the next attempt picks up from there.
      open = false;
      dismissSheet(backdrop);
      this.focusEditor();
    };
    const attempt = async () => {
      message.textContent = t("Web.Update.Downloading");
      retry.hidden = true;
      progress.hidden = false;
      setProgress(0);
      try {
        await download((fraction) => open && setProgress(fraction));
      } catch {
        if (!open) return;
        message.textContent = t("Web.Update.Failed");
        progress.hidden = true;
        retry.hidden = false;
        retry.focus();
        return;
      }
      if (!open) return;
      await this.flushAutosave();
      location.reload();
    };
    backdrop.querySelector("[data-cancel]").addEventListener("click", close);
    retry.addEventListener("click", attempt);
    backdrop.addEventListener("keydown", (event) => event.key === "Escape" && close());
    this.root.append(backdrop);
    backdrop.querySelector("[data-cancel]").focus();
    attempt();
  }

  /** A window-modal sheet asking for one line of text. Resolves with it, or null on Cancel. */
  askText(title, value, confirmLabel, { message = "", placeholder = "", numeric = false } = {}) {
    return new Promise((resolve) => {
      const backdrop = document.createElement("div");
      backdrop.className = "ds-sheet-backdrop app__sheet-backdrop";
      backdrop.innerHTML = `
        <form class="ds-sheet" role="dialog" aria-labelledby="ask-title">
          <div class="ds-sheet__body">
            <h2 class="ds-sheet__title" id="ask-title"></h2>
            <p class="ds-sheet__message" hidden></p>
            <input class="ds-text-input" spellcheck="false" aria-labelledby="ask-title">
          </div>
          <div class="ds-sheet__buttons">
            <button class="ds-button" type="button" data-cancel>${escapeHTML(t("Web.Common.Cancel"))}</button>
            <button class="ds-button ds-button--primary" type="submit"></button>
          </div>
        </form>`;
      backdrop.querySelector("#ask-title").textContent = title;
      const messageElement = backdrop.querySelector(".ds-sheet__message");
      messageElement.textContent = message;
      messageElement.hidden = !message;
      backdrop.querySelector('[type="submit"]').textContent = confirmLabel;
      const input = backdrop.querySelector("input");
      input.value = value;
      input.placeholder = placeholder;
      if (numeric) input.inputMode = "numeric";
      const finish = (result) => {
        dismissSheet(backdrop);
        this.focusEditor();
        resolve(result);
      };
      backdrop.querySelector("form").addEventListener("submit", (event) => {
        event.preventDefault();
        finish(input.value.trim() || null);
      });
      backdrop.querySelector("[data-cancel]").addEventListener("click", () => finish(null));
      backdrop.addEventListener("keydown", (event) => event.key === "Escape" && finish(null));
      this.root.append(backdrop);
      input.focus();
      const dot = value.lastIndexOf(".");
      input.setSelectionRange(0, dot > 0 ? dot : value.length);
    });
  }

  /** Asks how many rows and columns a new table has. Resolves with { rows, columns }, or null. */
  askTableSize() {
    return new Promise((resolve) => {
      const backdrop = document.createElement("div");
      backdrop.className = "ds-sheet-backdrop app__sheet-backdrop";
      backdrop.innerHTML = `
        <form class="ds-sheet" role="dialog" aria-labelledby="table-title">
          <div class="ds-sheet__body">
            <h2 class="ds-sheet__title" id="table-title">${escapeHTML(t("Panel.InsertTable.Title"))}</h2>
            <div class="ds-form">
              <label class="ds-form__label" for="table-rows">${escapeHTML(t("Mac.InsertTable.Rows"))}</label>
              <span class="ds-form__control"><input class="ds-text-input ds-text-input--xs app__table-size" id="table-rows" type="number" min="1" max="100" value="3"></span>
              <label class="ds-form__label" for="table-columns">${escapeHTML(t("Mac.InsertTable.Columns"))}</label>
              <span class="ds-form__control"><input class="ds-text-input ds-text-input--xs app__table-size" id="table-columns" type="number" min="1" max="30" value="3"></span>
            </div>
          </div>
          <div class="ds-sheet__buttons">
            <button class="ds-button" type="button" data-cancel>${escapeHTML(t("Web.Common.Cancel"))}</button>
            <button class="ds-button ds-button--primary" type="submit">${escapeHTML(t("InsertTable.Insert"))}</button>
          </div>
        </form>`;
      const finish = (result) => {
        dismissSheet(backdrop);
        this.focusEditor();
        resolve(result);
      };
      backdrop.querySelector("form").addEventListener("submit", (event) => {
        event.preventDefault();
        const rows = Math.min(100, Math.max(1, Number(backdrop.querySelector("#table-rows").value) || 1));
        const columns = Math.min(30, Math.max(1, Number(backdrop.querySelector("#table-columns").value) || 1));
        finish({ rows, columns });
      });
      backdrop.querySelector("[data-cancel]").addEventListener("click", () => finish(null));
      backdrop.addEventListener("keydown", (event) => event.key === "Escape" && finish(null));
      this.root.append(backdrop);
      backdrop.querySelector("#table-rows").select();
    });
  }

  applyAppearance(value) {
    if (value) document.documentElement.dataset.theme = value;
    else delete document.documentElement.dataset.theme;
    writeSetting("appearance", value);
    this.code?.highlight();
  }

  // MARK: - Keyboard

  bindKeyboard() {
    window.addEventListener("keydown", (event) => {
      const mod = isApple ? event.metaKey : event.ctrlKey;
      if (!mod) return;
      const key = event.key.toLowerCase();
      const inField = event.target instanceof HTMLInputElement || event.target instanceof HTMLSelectElement
        || (event.target instanceof HTMLTextAreaElement && !event.target.closest(".app__code"));
      const map = {
        n: "new", o: "open", s: event.shiftKey ? "saveAs" : "save", w: "close", p: "print",
        z: event.shiftKey ? "redo" : "undo", y: "redo", b: "bold", i: event.altKey ? "toggleInspector" : "italic", u: "underline",
        f: event.altKey ? "findReplace" : "find", g: event.shiftKey ? "findPrevious" : "findNext", l: this.isText ? "goToLine" : null,
        "=": "zoomIn", "+": event.shiftKey ? "bigger" : "zoomIn", "-": event.altKey ? "zoomOut" : "smaller", "0": "actualSize",
        "]": "indent", "[": "outdent",
      };
      if (event.shiftKey && key === "x") map.x = "strike";
      if (event.altKey && key === "l") map.l = "bullets";
      const command = map[key];
      if (!command) return;
      // Text fields keep their own undo, select all and text styling.
      if (inField && ["undo", "redo", "bold", "italic", "underline", "strike"].includes(command)) return;
      // The code editor keeps its own undo.
      if (this.isText && ["undo", "redo"].includes(command)) return;
      event.preventDefault();
      this.run(command);
    });
  }

  // MARK: - Documents

  async refreshRecents() {
    this.recents = await storage.recentDocuments();
    if (!this.document) this.renderStart();
  }

  showStart() {
    this.document = null;
    this.look = null;
    this.root.classList.add("is-empty");
    this.root.classList.remove("is-text");
    this.toolbarOverflow.layout();
    this.start.hidden = false;
    this.findForm.hidden = true;
    this.updateTitle();
    this.updateStatus();
    this.renderInspector();
    this.refreshRecents();
  }

  renderStart() {
    const recents = this.recents ?? [];
    const relative = new Intl.RelativeTimeFormat(language, { numeric: "auto" });
    const when = (time) => {
      const minutes = Math.round((time - Date.now()) / 60000);
      if (Math.abs(minutes) < 60) return relative.format(minutes, "minute");
      const hours = Math.round(minutes / 60);
      if (Math.abs(hours) < 24) return relative.format(hours, "hour");
      return new Intl.DateTimeFormat(language, { dateStyle: "medium" }).format(time);
    };
    const isCode = (name) => !/\.(docx|docm|dotx|pages|md|markdown)$/i.test(name);
    this.start.innerHTML = `
      <div class="app__start-inner">
        <h1 class="ds-heading-04">Libretto</h1>
        <p class="ds-body app__start-intro"></p>
        <div class="app__start-actions">
          <button class="ds-button ds-button--primary" data-start="new">${escapeHTML(t("Launch.NewDocument"))}</button>
          <button class="ds-button ds-button--bordered" data-start="text">${escapeHTML(t("Web.Menu.NewTextFile"))}</button>
          <button class="ds-button ds-button--bordered" data-start="open">${escapeHTML(t("Mac.Menu.Open"))}</button>
        </div>
        <h2 class="ds-heading-compact app__start-heading">${escapeHTML(t("Mac.Menu.OpenRecent"))}</h2>
        ${recents.length ? `<table class="ds-table app__recents"><tbody>
          ${recents.map((record) => {
            const name = record.draftAt && !record.handle ? record.draftName ?? record.name : record.name;
            return `<tr data-id="${record.id}" tabindex="0">
            <td>${icon(isCode(name) ? "code" : "document")} <span>${escapeHTML(name)}</span></td>
            <td class="app__recent-note">${record.draftAt ? escapeHTML(t("Web.Start.Unsaved")) : ""}</td>
            <td class="ds-numeric app__recent-date">${escapeHTML(when(Math.max(record.openedAt, record.draftAt ?? 0)))}</td>
            <td class="app__recent-remove"><button class="ds-button ds-button--ghost ds-button--icon ds-button--xs" data-remove="${record.id}" aria-label="${escapeHTML(t("Web.Start.Remove"))}" title="${escapeHTML(t("Web.Start.Remove"))}">${icon("close")}</button></td>
          </tr>`;
          }).join("")}</tbody></table>`
        : `<p class="ds-caption">${escapeHTML(t("Web.Start.NoRecent"))}</p>`}
      </div>`;
    this.start.querySelector(".app__start-intro").textContent = t("Web.Start.Intro");
    this.start.querySelector('[data-start="new"]').addEventListener("click", () => this.newDocument());
    this.start.querySelector('[data-start="text"]').addEventListener("click", () => this.newDocument({ text: true }));
    this.start.querySelector('[data-start="open"]').addEventListener("click", () => this.openPicked());
    for (const row of this.start.querySelectorAll("tr[data-id]")) {
      const record = recents.find((r) => r.id === row.dataset.id);
      row.addEventListener("click", (event) => {
        if (event.target.closest("[data-remove]")) return;
        this.openRecord(record);
      });
      row.addEventListener("keydown", (event) => event.key === "Enter" && this.openRecord(record));
    }
    for (const button of this.start.querySelectorAll("[data-remove]")) {
      button.addEventListener("click", async () => {
        await storage.removeRecord(button.dataset.remove);
        this.refreshRecents();
      });
    }
  }

  showDocument(record) {
    this.document = record;
    this.keptVersion = this.engine.state?.version;
    this.root.classList.remove("is-empty");
    this.root.classList.toggle("is-text", this.isText);
    this.root.querySelector(".app__pages").hidden = this.isText;
    this.root.querySelector(".app__code").hidden = !this.isText;
    // The toolbar's items come back without the toolbar resizing, so its overflow needs laying out again.
    this.toolbarOverflow.layout();
    this.start.hidden = true;
    this.banners.replaceChildren();
    this.findForm.hidden = true;
    this.updateTitle();
    this.updateStyles();
    this.renderInspector();
    storage.saveRecord({ ...record, openedAt: Date.now() });
    storage.persist();
    requestAnimationFrame(() => {
      this.focusEditor();
      if (!this.isText) {
        const first = this.pages.flow.querySelector("p[data-id]");
        if (first) this.pages.select({ p: first.dataset.id, o: 0 });
      }
      this.updateStatus();
    });
  }

  async flushAutosave() {
    if (this.autosaveTimer) {
      clearTimeout(this.autosaveTimer);
      this.autosaveTimer = null;
      await this.autosave();
    }
  }

  /** Every edit typed so far, with the engine. */
  async flushEdits() {
    if (!this.document) return;
    if (this.isText) await this.code.sync();
    else await this.pages.sync();
  }

  async newDocument({ text = false } = {}) {
    await this.flushEdits();
    await this.flushAutosave();
    const name = text ? t("Web.Document.UntitledText") : t("Web.Document.Untitled");
    this.pages.dispose();
    await this.engine.call("new", { name });
    this.showDocument({ id: crypto.randomUUID(), name, openedAt: Date.now() });
  }

  async openPicked() {
    try {
      const file = await files.pickFile();
      if (file) await this.openFile(file);
    } catch (error) {
      this.showMessage(error.message, "error");
    }
  }

  /** @param {{ name: string, bytes: Uint8Array, handle?: FileSystemFileHandle }} file */
  async openFile(file, { id = null, draftOf = null } = {}) {
    await this.flushEdits();
    await this.flushAutosave();
    this.pages.dispose();
    try {
      await this.engine.call("open", { name: file.name }, file.bytes);
    } catch (error) {
      this.showMessage(t("Web.Error.Open", file.name, error.message), "error");
      return;
    }
    const recents = await storage.recentDocuments();
    const existing = file.handle
      ? await (async () => {
        for (const record of recents) if (record.handle && (await record.handle.isSameEntry?.(file.handle))) return record;
        return null;
      })()
      : null;
    const record = draftOf ?? existing ?? { id: id ?? crypto.randomUUID() };
    this.showDocument({ ...record, name: file.name, handle: file.handle ?? record.handle, openedAt: Date.now() });
    this.showNotices();
  }

  async openRecord(record) {
    if (record.draftAt) {
      const bytes = await storage.readDraft(record.id);
      if (bytes) {
        await this.openFile({ name: record.draftName ?? record.name, bytes, handle: record.handle }, { draftOf: record });
        // The draft has unsaved changes: show it as edited.
        this.engine.state.edited = true;
        this.updateTitle();
        return;
      }
    }
    if (!record.handle) {
      this.showMessage(t("Web.Error.Missing", record.name), "error");
      return;
    }
    try {
      const file = await files.readHandle(record.handle);
      if (file) await this.openFile(file, { draftOf: record });
    } catch (error) {
      this.showMessage(t("Web.Error.Open", record.name, error.message), "error");
    }
  }

  async closeDocument() {
    await this.flushEdits();
    await this.flushAutosave();
    this.pages.dispose();
    this.showStart();
  }

  /** Changes neither saved nor autosaved yet. */
  get hasUnkeptChanges() {
    const state = this.engine.state;
    return Boolean(this.document && (state?.edited && state.version !== this.keptVersion));
  }

  scheduleAutosave() {
    if (!this.document) return;
    clearTimeout(this.autosaveTimer);
    this.autosaveTimer = setTimeout(() => {
      this.autosaveTimer = null;
      this.autosave();
    }, AUTOSAVE_DELAY);
  }

  /** Keeps a copy of the open document on this device, so closing the window loses nothing. */
  async autosave() {
    const record = this.document;
    if (!this.hasUnkeptChanges) return;
    const version = this.engine.state.version;
    try {
      const { result, payload } = await this.engine.call("save", { keep: true });
      if (await storage.writeDraft(record.id, payload)) {
        record.draftAt = Date.now();
        record.draftName = result.fileName;
        this.keptVersion = version;
        await storage.saveRecord(record);
      }
    } catch {
      // A failed autosave leaves the last one in place; saving will report errors.
    }
  }

  defaultFormat() {
    const info = this.engine.info;
    return info?.saveFormats?.[0] ?? { key: "docx", extension: "docx", mime: "application/vnd.openxmlformats-officedocument.wordprocessingml.document" };
  }

  async save() {
    const record = this.document;
    if (!record) return;
    await this.flushEdits();
    const format = this.defaultFormat();
    const sameKind = record.handle && record.handle.name === format.fileName;
    if (!sameKind) return this.saveAs();
    try {
      const { payload } = await this.engine.call("save", { format: format.key });
      if (!(await files.writeHandle(record.handle, payload))) return;
      await this.saved(record);
    } catch (error) {
      this.showMessage(error.message, "error");
    }
  }

  async saveAs(format = this.defaultFormat()) {
    const record = this.document;
    if (!record) return;
    await this.flushEdits();
    try {
      const { result, payload } = await this.engine.call("save", { format: format.key, keep: true });
      const saved = await files.saveFileAs(payload, result.fileName, { ...format, description: this.formatLabel(format.key).replace("…", "") });
      if (!saved) return;
      await this.engine.call("rename", { name: saved.name });
      await this.engine.call("save", { format: format.key, keep: false }).catch(() => {});
      record.name = saved.name;
      if (saved.handle) record.handle = saved.handle;
      await this.saved(record);
    } catch (error) {
      this.showMessage(error.message, "error");
    }
  }

  /** Saves a copy in another format, leaving the open document as it is. */
  async exportAs(format) {
    if (!this.document) return;
    await this.flushEdits();
    try {
      const { result, payload } = await this.engine.call("save", { format: format.key, keep: true });
      await files.saveFileAs(payload, result.fileName, { ...format, description: this.formatLabel(format.key).replace("…", "") });
    } catch (error) {
      this.showMessage(error.message, "error");
    }
  }

  async saved(record) {
    clearTimeout(this.autosaveTimer);
    this.autosaveTimer = null;
    await storage.removeDraft(record.id);
    delete record.draftAt;
    delete record.draftName;
    await storage.saveRecord({ ...record, openedAt: Date.now() });
    if (this.engine.state) this.engine.state.edited = false;
    this.keptVersion = this.engine.state?.version;
    this.updateTitle();
    this.showMessage(t("Web.Document.SavedAs", record.name), "success");
  }

  async renameDocument() {
    const record = this.document;
    if (!record) return;
    const name = await this.askText(t("Web.Document.RenamePrompt"), record.name, t("Mac.Menu.Rename").replace("…", ""));
    if (!name || name === record.name) return;
    await this.engine.call("rename", { name });
    record.name = name;
    if (record.handle?.move) {
      try {
        await record.handle.move(name);
      } catch {
        // The file keeps its name on disk; the next save asks where.
        delete record.handle;
      }
    }
    await storage.saveRecord(record);
    this.updateTitle();
  }
}

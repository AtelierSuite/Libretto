// The code editor: plain text and source code in numbered lines, coloured by
// the engine's syntax highlighter (the same one the Apple apps' code editor
// uses), the web's counterpart of their code text view.
//
// The text is typed into a textarea laid exactly over the coloured copy of
// it, so the browser does the typing, the caret and undo, and the colour
// follows a moment behind.

const SYNC_DELAY = 400;

export class CodeEditor extends EventTarget {
  /**
   * @param {HTMLElement} host
   * @param {import("./engine-client.js").EngineClient} engine
   * @param {{ t: (key: string, ...values: any[]) => string }} options
   */
  constructor(host, engine, { t }) {
    super();
    this.host = host;
    this.engine = engine;
    this.t = t;
    this.syncTimer = null;
    this.highlightTimer = null;
    this.syncing = Promise.resolve();
    this.changed = false;

    host.classList.add("ds-code-editor", "app__code-editor");
    host.innerHTML = `
      <div class="ds-code-editor__gutter app__code-editor-gutter" aria-hidden="true"></div>
      <div class="app__code-editor-stack">
        <div class="ds-code-editor__text app__code-editor-colours" aria-hidden="true"></div>
        <textarea class="ds-code-editor__text app__code-editor-input" spellcheck="false" autocomplete="off" autocapitalize="off" wrap="off"></textarea>
      </div>`;
    this.gutter = host.querySelector(".app__code-editor-gutter");
    this.colours = host.querySelector(".app__code-editor-colours");
    this.input = host.querySelector(".app__code-editor-input");
    this.input.setAttribute("aria-label", t("CodeEditor.TextFile"));

    this.input.addEventListener("input", () => {
      this.changed = true;
      this.showText(this.input.value);
      this.scheduleSync();
      clearTimeout(this.highlightTimer);
      this.highlightTimer = setTimeout(() => this.highlight(), 150);
      this.dispatchEvent(new CustomEvent("edited"));
    });
    this.input.addEventListener("keydown", (event) => this.keyDown(event));
    for (const type of ["keyup", "click", "select"]) this.input.addEventListener(type, () => this.dispatchEvent(new CustomEvent("edited")));
    this.input.addEventListener("blur", () => this.sync());
    matchMedia("(prefers-color-scheme: dark)").addEventListener("change", () => this.highlight());
  }

  /** Shows the document's text, from the engine. */
  async load() {
    const { text } = await this.engine.call("text");
    this.input.value = text;
    this.changed = false;
    this.showText(text);
    this.input.setSelectionRange(0, 0);
    this.highlight();
  }

  /** Lays the text out uncoloured, and numbers its lines, until the colour arrives. */
  showText(text) {
    const lines = text.split("\n").length;
    if (lines !== this.lineTotal) {
      this.lineTotal = lines;
      this.gutter.textContent = Array.from({ length: lines }, (_, index) => index + 1).join("\n");
    }
    if (this.colours.textContent !== text + "\n") this.colours.textContent = text + "\n";
  }

  get isDark() {
    const theme = document.documentElement.dataset.theme;
    return theme ? theme === "dark" : matchMedia("(prefers-color-scheme: dark)").matches;
  }

  /** Colours the text by its syntax, as the engine reads it. */
  async highlight() {
    const text = this.input.value;
    if (!text) return;
    let tokens = [];
    try {
      tokens = await this.engine.call("highlight", { text, dark: this.isDark });
    } catch {
      return;
    }
    if (text !== this.input.value) return;
    const fragment = document.createDocumentFragment();
    let location = 0;
    for (const [start, length, colour] of tokens) {
      if (start > location) fragment.append(text.slice(location, start));
      const span = document.createElement("span");
      span.style.color = colour;
      span.textContent = text.slice(start, start + length);
      fragment.append(span);
      location = start + length;
    }
    fragment.append(text.slice(location) + "\n");
    this.colours.replaceChildren(fragment);
  }

  scheduleSync() {
    clearTimeout(this.syncTimer);
    this.syncTimer = setTimeout(() => this.sync(), SYNC_DELAY);
  }

  /** Gives the engine the text as typed. Resolves once it has it. */
  sync() {
    clearTimeout(this.syncTimer);
    if (!this.changed) return this.syncing;
    this.changed = false;
    const text = this.input.value;
    this.syncing = this.syncing.then(() => this.engine.call("setText", { text }))
      .catch((error) => this.dispatchEvent(new CustomEvent("message", { detail: error.message })));
    return this.syncing;
  }

  keyDown(event) {
    if (event.key === "Tab" && !event.metaKey && !event.ctrlKey && !event.altKey) {
      event.preventDefault();
      const { selectionStart: start, selectionEnd: end, value } = this.input;
      const unit = this.indentUnit();
      if (start === end && !event.shiftKey) {
        this.insert(unit);
        return;
      }
      // Indent or outdent every selected line.
      const lineStart = value.lastIndexOf("\n", start - 1) + 1;
      const block = value.slice(lineStart, end);
      const lines = block.split("\n");
      const changed = lines.map((line) => {
        if (!event.shiftKey) return line.length ? unit + line : line;
        if (line.startsWith("\t")) return line.slice(1);
        return line.replace(new RegExp(`^ {1,${unit === "\t" ? 4 : unit.length}}`), "");
      }).join("\n");
      this.input.setSelectionRange(lineStart, end);
      document.execCommand("insertText", false, changed);
      this.input.setSelectionRange(lineStart, lineStart + changed.length);
      return;
    }
    if (event.key === "Enter" && !event.metaKey && !event.ctrlKey) {
      // A new line starts as indented as the one it follows.
      event.preventDefault();
      const { selectionStart: start, value } = this.input;
      const lineStart = value.lastIndexOf("\n", start - 1) + 1;
      const indent = /^[ \t]*/.exec(value.slice(lineStart, start))[0];
      this.insert(`\n${indent}`);
    }
  }

  /** What one level of indentation is in this file: a tab, or as many spaces as its lines are indented by. */
  indentUnit() {
    const lines = this.input.value.split("\n").slice(0, 400);
    let tabs = 0;
    const widths = new Map();
    for (const line of lines) {
      if (line.startsWith("\t")) tabs++;
      const spaces = /^ +(?=\S)/.exec(line)?.[0].length;
      if (spaces) widths.set(spaces, (widths.get(spaces) ?? 0) + 1);
    }
    const spaced = [...widths.values()].reduce((sum, count) => sum + count, 0);
    if (tabs >= spaced) return tabs ? "\t" : "    ";
    const smallest = Math.min(...widths.keys());
    return " ".repeat(smallest === 2 ? 2 : 4);
  }

  /** Types text at the caret, as if typed, so the browser can undo it. */
  insert(text) {
    this.input.focus();
    if (!document.execCommand("insertText", false, text)) {
      const { selectionStart: start, selectionEnd: end } = this.input;
      this.input.setRangeText(text, start, end, "end");
      this.input.dispatchEvent(new Event("input"));
    }
  }

  focus() {
    this.input.focus({ preventScroll: true });
  }

  selectAll() {
    this.input.focus();
    this.input.select();
  }

  selectedText() {
    return this.input.value.slice(this.input.selectionStart, this.input.selectionEnd);
  }

  lineCount() {
    return this.input.value.split("\n").length;
  }

  /** Where the caret is, counting lines and columns from 1. */
  caret() {
    const before = this.input.value.slice(0, this.input.selectionStart);
    const line = before.split("\n").length;
    return { line, column: before.length - before.lastIndexOf("\n") };
  }

  goToLine(number) {
    const lines = this.input.value.split("\n");
    const start = lines.slice(0, number - 1).reduce((sum, line) => sum + line.length + 1, 0);
    this.input.focus();
    this.input.setSelectionRange(start, start + (lines[number - 1]?.length ?? 0));
    this.reveal(start);
  }

  /** Scrolls a place in the text into view. */
  reveal(index) {
    const line = this.input.value.slice(0, index).split("\n").length - 1;
    const lineHeight = parseFloat(getComputedStyle(this.input).lineHeight) || 20;
    const top = line * lineHeight;
    if (top < this.host.scrollTop || top > this.host.scrollTop + this.host.clientHeight - lineHeight * 2) {
      this.host.scrollTop = Math.max(0, top - this.host.clientHeight / 3);
    }
  }

  find(query) {
    if (!query) return [];
    const haystack = this.input.value.toLocaleLowerCase();
    const needle = query.toLocaleLowerCase();
    const matches = [];
    for (let index = haystack.indexOf(needle); index >= 0; index = haystack.indexOf(needle, index + needle.length)) {
      matches.push({ start: index, end: index + needle.length });
    }
    return matches;
  }

  showMatch(match) {
    this.input.focus();
    this.input.setSelectionRange(match.start, match.end);
    this.reveal(match.start);
  }

  replaceSelection(text) {
    this.insert(text);
  }

  replaceAll(query, replacement) {
    const matches = this.find(query);
    for (const match of matches.reverse()) {
      this.input.setSelectionRange(match.start, match.end);
      this.insert(replacement);
    }
  }
}

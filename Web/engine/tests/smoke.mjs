// Smoke tests for the WebAssembly engine, run with Node's built-ins only:
//
//   node Web/engine/tests/smoke.mjs [file.docx|file.md|file.pages|file.txt ...]
//
// Loads build/libretto-engine.wasm through the same engine.js the app uses,
// edits a document the way the page does, saves and reopens it in each
// format, and opens any files given.

import { readFile } from "node:fs/promises";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { basename } from "node:path";
import { strict as assert } from "node:assert";
import { Engine } from "../engine.js";

const web = new URL("../../", import.meta.url);
const engine = await Engine.load(readFile(fileURLToPath(new URL("build/libretto-engine.wasm", web))));
const strings = JSON.parse(await readFile(fileURLToPath(new URL("build/strings/app-en.json", web)), "utf8"));

let failures = 0;
function test(name, body) {
  try {
    body();
    console.log(`✔ ${name}`);
  } catch (error) {
    failures++;
    console.log(`✘ ${name}\n  ${error.stack}`);
  }
}

function call(cmd, args = {}, payload) {
  const { response, payload: output } = engine.call({ cmd, ...args }, payload);
  assert.ok(response.ok, `${cmd} failed: ${response.error}`);
  return { result: response.result, state: response.state, payload: output };
}

const render = () => call("render").result;
/** Each paragraph's text, as the page shows it. */
const texts = (doc = render()) => doc.blocks.filter((block) => block.k === "p")
  .map((block) => block.r.map((run) => run.t ?? (run.k === "tab" ? "\t" : "")).join(""));
/** A paragraph as the page sends it back after an edit: its runs, with their references. */
const typed = (block, text) => ({ k: "p", id: block.id, r: [{ r: block.r[0]?.r, t: text }] });

test("starts with the strings loaded", () => {
  call("init", { strings, locale: "en-US" });
  const { result } = call("new", { name: "Smoke.docx" });
  assert.equal(result.fileName, "Smoke.docx");
  assert.equal(result.isText, false);
  assert.equal(render().blocks.length, 1);
});

test("takes typed paragraphs back, keeping their IDs, and splits one in two", () => {
  const [first] = render().blocks;
  call("edit", { blocks: [{ k: "p", id: first.id, r: [{ t: "Hello world" }] }] });
  assert.deepEqual(texts(), ["Hello world"]);
  // Return in the middle: the browser copies the paragraph, ID and all.
  const { result } = call("edit", { blocks: [{ k: "p", id: first.id, r: [{ t: "Hello" }] }, { k: "p", id: first.id, r: [{ t: "world" }] }] });
  const doc = render();
  assert.deepEqual(texts(doc), ["Hello", "world"]);
  assert.notEqual(doc.blocks[0].id, doc.blocks[1].id);
  assert.equal(doc.blocks[1].id, first.id, "the second half keeps the paragraph's ID");
  assert.deepEqual(result.labels, {});
});

test("formats a selection, splitting runs where it starts and ends", () => {
  const doc = render();
  const second = doc.blocks[1];
  call("format", { a: { p: second.id, o: 1 }, f: { p: second.id, o: 3 }, set: { b: true } });
  const after = render();
  const runs = after.blocks[1].r;
  assert.deepEqual(runs.map((run) => run.t), ["w", "or", "ld"]);
  assert.equal(after.runStyles[runs[1].s].b, true);
  assert.notEqual(after.runStyles[runs[0].s].b, true);
});

test("keeps formatting when unchanged runs come back", () => {
  const doc = render();
  const block = doc.blocks[1];
  call("edit", { blocks: [{ id: doc.blocks[0].id }, { k: "p", id: block.id, r: block.r.map((run) => ({ r: run.r, t: run.t })) }] });
  const after = render();
  assert.equal(after.runStyles[after.blocks[1].r[1].s].b, true);
});

test("styles, aligns and lists paragraphs", () => {
  const doc = render();
  const [first, second] = doc.blocks;
  call("style", { a: { p: first.id, o: 0 }, choice: "heading1" });
  call("paragraph", { a: { p: second.id, o: 0 }, set: { align: "center" } });
  call("list", { a: { p: second.id, o: 0 }, kind: "numbered" });
  const after = render();
  assert.equal(after.blocks[0].h, 1);
  assert.equal(after.blocks[1].s.a, "center");
  assert.equal(after.blocks[1].l, "1.");
});

test("relabels list items the page splits", () => {
  const doc = render();
  const item = doc.blocks[1];
  const { result } = call("edit", { blocks: [{ id: doc.blocks[0].id }, typed(item, "one"), typed(item, "two")] });
  assert.deepEqual(Object.values(result.labels).sort(), ["1.", "2."]);
});

test("undoes and redoes", () => {
  const before = texts();
  const doc = render();
  call("edit", { blocks: [typed(doc.blocks[0], "Changed"), ...doc.blocks.slice(1).map((block) => ({ id: block.id }))], step: true });
  assert.equal(texts()[0], "Changed");
  call("undo");
  assert.deepEqual(texts(), before);
  call("redo");
  assert.equal(texts()[0], "Changed");
});

test("inserts a table and edits it", () => {
  const doc = render();
  call("insertTable", { at: { p: doc.blocks.at(-1).id, o: 0 }, rows: 2, columns: 3 });
  let table = render().blocks.find((block) => block.k === "t");
  assert.equal(table.rows.length, 2);
  assert.equal(table.rows[0].c.length, 3);
  call("table", { cell: table.rows[0].c[0].id, op: "rowBelow" });
  table = render().blocks.find((block) => block.k === "t");
  assert.equal(table.rows.length, 3);
  const cell = table.rows[0].c[1];
  const paragraph = cell.b[0];
  const rows = table.rows.map((row) => ({ id: row.id, c: row.c.map((c) => ({ id: c.id, b: c === cell ? [{ k: "p", id: paragraph.id, r: [{ t: "Cell" }] }] : c.b.map((b) => ({ id: b.id })) })) }));
  const blocks = render().blocks.map((block) => (block.k === "t" ? { k: "t", id: block.id, rows } : { id: block.id }));
  call("edit", { blocks });
  table = render().blocks.find((block) => block.k === "t");
  assert.equal(table.rows[0].c[1].b[0].r[0].t, "Cell");
});

let saved;
test("saves as a Word document and opens it again", () => {
  const { result, payload, state } = call("save", { format: "docx" });
  assert.equal(result.fileName, "Smoke.docx");
  assert.equal(state.edited, false);
  assert.equal(payload[0], 0x50);
  saved = payload;
  call("open", { name: "Smoke.docx" }, payload);
  const doc = render();
  assert.equal(doc.blocks[0].h, 1);
  assert.equal(texts(doc)[0], "Changed");
  assert.ok(doc.blocks.some((block) => block.k === "t"));
});

test("saves as Markdown and plain text", () => {
  const md = new TextDecoder().decode(call("save", { format: "md", keep: true }).payload);
  assert.ok(md.startsWith("# Changed"), md);
  const txt = new TextDecoder().decode(call("save", { format: "txt", keep: true }).payload);
  assert.ok(txt.startsWith("Changed\n"), txt);
});

test("opens Markdown with its headings and emphasis", () => {
  const source = new TextEncoder().encode("# Title\n\nSome *emphasis* and **strength**.\n\n- one\n- two\n");
  const { result } = call("open", { name: "Notes.md" }, source);
  assert.equal(result.format, "md");
  const doc = render();
  assert.equal(doc.blocks[0].h, 1);
  const runs = doc.blocks[1].r;
  assert.equal(doc.runStyles[runs.find((run) => run.t === "emphasis").s].i, true);
  assert.equal(doc.blocks[2].l, "•");
});

test("opens source code in the code editor, colours it and saves it as it came", () => {
  const source = new TextEncoder().encode("let answer = 42 // the answer\r\n");
  const { result } = call("open", { name: "main.swift" }, source);
  assert.equal(result.isText, true);
  assert.equal(result.language, "swift");
  assert.equal(result.lineEnding, "crlf");
  const { result: text } = call("text");
  assert.equal(text.text, "let answer = 42 // the answer");
  const tokens = call("highlight", {}).result;
  assert.ok(tokens.length >= 3, JSON.stringify(tokens));
  call("setText", { text: "let answer = 43" });
  const out = new TextDecoder().decode(call("save").payload);
  assert.equal(out, "let answer = 43\r\n");
  assert.equal(call("save").result.fileName, "main.swift");
});

test("gives pictures' bytes to the page", () => {
  // The smallest PNG: one transparent pixel.
  const png = Uint8Array.from(atob("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="), (c) => c.charCodeAt(0));
  call("new", { name: "Pictures.docx" });
  const [first] = render().blocks;
  call("insertImage", { at: { p: first.id, o: 0 }, width: 10, height: 10 }, png);
  const doc = render();
  const picture = doc.blocks[0].r.find((run) => run.k === "img");
  assert.ok(picture, JSON.stringify(doc.blocks[0]));
  const { result, payload } = call("media", { id: picture.id });
  assert.equal(result.mime, "image/png");
  assert.equal(payload.length, png.length);
});

test("reports a malformed request rather than trapping", () => {
  const { response } = engine.call({ cmd: "nonsense" });
  assert.equal(response.ok, false);
  assert.ok(response.error.includes("nonsense"));
});

for (const path of process.argv.slice(2)) {
  test(`opens ${basename(path)}`, () => {
    const bytes = new Uint8Array(readFileSync(path));
    const { result } = call("open", { name: basename(path) }, bytes);
    if (result.isText) {
      assert.equal(typeof call("text").result.text, "string");
    } else {
      const doc = render();
      assert.ok(doc.blocks.length > 0);
      console.log(`  ${doc.blocks.length} blocks, ${result.wordCount} words, ${doc.sections.length} section(s)`);
    }
    const { payload } = call("save", { keep: true });
    assert.ok(payload.length > 0);
  });
}

if (saved === undefined) failures++;
console.log(failures ? `\n${failures} failed.` : "\nAll passed.");
process.exit(failures ? 1 : 0);

// The page's side of the engine worker: sends requests, keeps the latest
// session state, and tells listeners what changed.
//
//   const engine = new EngineClient();
//   engine.addEventListener("state", ...)    // every response
//   engine.addEventListener("content", ...)  // the document changed other than by the page's own typing: draw it again
//   engine.addEventListener("document", ...) // file, format, styles or capabilities changed
//   engine.addEventListener("progress", ...) // while starting: { loaded, total } bytes of the engine downloaded

export class EngineError extends Error {
  constructor(message, { fatal = false } = {}) {
    super(message);
    this.fatal = fatal;
  }
}

/** Commands whose changes the page has already drawn itself. */
const PAGE_EDITS = new Set(["edit", "setText"]);
/** Commands after which the document's details may have changed. */
const DOCUMENT_COMMANDS = new Set([
  "new", "open", "rename", "save", "undo", "redo", "style", "revisions", "trackChanges", "setLanguage", "pageSetup",
]);

export class EngineClient extends EventTarget {
  /** @param {{ keepForOffline?: boolean }} [options] keepForOffline: leave the downloaded engine for the service worker's first install */
  constructor({ keepForOffline = false } = {}) {
    super();
    const url = new URL("../engine/worker.js", import.meta.url);
    url.searchParams.set("tz", Intl.DateTimeFormat().resolvedOptions().timeZone ?? "UTC");
    if (keepForOffline) url.searchParams.set("keep", "1");
    this.worker = new Worker(url, { type: "module" });
    this.pending = new Map();
    this.nextId = 1;
    this.state = null;
    this.info = null;
    this.worker.addEventListener("message", (event) => this.receive(event.data));
    this.worker.addEventListener("error", (event) => {
      for (const { reject } of this.pending.values()) reject(new EngineError(event.message || "The engine could not start.", { fatal: true }));
      this.pending.clear();
      this.dispatchEvent(new CustomEvent("fatal", { detail: event.message }));
    });
  }

  receive({ id, response, payload, error, fatal, progress }) {
    if (progress) {
      this.dispatchEvent(new CustomEvent("progress", { detail: progress }));
      return;
    }
    const entry = this.pending.get(id);
    if (!entry) return;
    this.pending.delete(id);
    if (error) {
      entry.reject(new EngineError(error, { fatal }));
      if (fatal) this.dispatchEvent(new CustomEvent("fatal", { detail: error }));
      return;
    }
    entry.resolve({ response, payload });
  }

  /** Sends a raw request; resolves with { response, payload }. */
  send(request, payload) {
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.worker.postMessage({ id, request, payload }, payload ? [payload.buffer] : []);
    });
  }

  /**
   * Runs a command and applies the state it returns. Resolves with the
   * command's result (with the bytes it gave back, if any); rejects with the
   * engine's message when it fails.
   */
  async call(cmd, args = {}, payload) {
    const { response, payload: output } = await this.send({ cmd, ...args }, payload);
    await this.apply(response.state, cmd);
    if (!response.ok) throw new EngineError(response.error);
    if (output) return { result: response.result, payload: output };
    return response.result;
  }

  async apply(state, cmd) {
    if (!state) return;
    const previous = this.state;
    this.state = state;
    if (DOCUMENT_COMMANDS.has(cmd) || !this.info) {
      const { response } = await this.send({ cmd: "info" });
      this.info = response.result;
      this.dispatchEvent(new CustomEvent("document", { detail: this.info }));
    }
    const isNew = cmd === "new" || cmd === "open";
    if (isNew || (previous && previous.version !== state.version && !PAGE_EDITS.has(cmd))) {
      this.dispatchEvent(new CustomEvent("content", { detail: { cmd, isNew } }));
    }
    this.dispatchEvent(new CustomEvent("state", { detail: state }));
  }

  /** The document's details again, such as its word count after typing. */
  async refreshInfo() {
    const { response } = await this.send({ cmd: "info" });
    this.info = response.result;
    this.dispatchEvent(new CustomEvent("document", { detail: this.info }));
    return this.info;
  }
}

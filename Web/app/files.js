// Opening and saving files on the user's device. Where the browser has the File
// System Access API, documents save back in place; elsewhere they open through
// a file picker and save as downloads.

import { t } from "./i18n.js";

const openTypes = () => [
  {
    description: t("Web.FileType.Documents"),
    accept: {
      "application/vnd.openxmlformats-officedocument.wordprocessingml.document": [".docx", ".dotx"],
      "application/vnd.ms-word.document.macroEnabled.12": [".docm"],
      "application/vnd.apple.pages": [".pages"],
      "text/markdown": [".md", ".markdown"],
      "text/plain": [".txt", ".text"],
    },
  },
  {
    description: t("Web.FileType.SourceCode"),
    accept: {
      "text/plain": [".swift", ".py", ".js", ".mjs", ".ts", ".tsx", ".jsx", ".json", ".html", ".css", ".scss", ".xml", ".yaml", ".yml",
        ".toml", ".ini", ".c", ".h", ".cpp", ".hpp", ".m", ".cs", ".java", ".kt", ".go", ".rs", ".rb", ".php", ".pl", ".sql",
        ".sh", ".lua", ".dart", ".scala", ".r", ".zig", ".ex", ".hs", ".graphql", ".diff", ".patch"],
    },
  },
];

const pictureTypes = () => [
  { description: t("Web.FileType.Pictures"), accept: { "image/png": [".png"], "image/jpeg": [".jpg", ".jpeg"], "image/gif": [".gif"] } },
];

export const canSaveInPlace = typeof window.showSaveFilePicker === "function";

/**
 * Asks the user for a file to open, or a picture to put in.
 * @returns {Promise<{ name: string, bytes: Uint8Array, handle?: FileSystemFileHandle } | null>}
 */
export async function pickFile({ pictures = false } = {}) {
  const types = pictures ? pictureTypes() : openTypes();
  if (typeof window.showOpenFilePicker === "function") {
    try {
      const [handle] = await window.showOpenFilePicker({ types, excludeAcceptAllOption: false, multiple: false });
      return readHandle(handle);
    } catch (error) {
      if (error?.name === "AbortError") return null;
      throw error;
    }
  }
  return new Promise((resolve) => {
    const input = document.createElement("input");
    input.type = "file";
    input.accept = types.flatMap((type) => Object.values(type.accept).flat()).join(",");
    input.addEventListener("change", async () => {
      const file = input.files?.[0];
      resolve(file ? { name: file.name, bytes: new Uint8Array(await file.arrayBuffer()) } : null);
    });
    input.addEventListener("cancel", () => resolve(null));
    input.click();
  });
}

/** Reads a file the user picked earlier, asking again for permission when the browser wants that. */
export async function readHandle(handle) {
  if (handle.queryPermission && (await handle.queryPermission({ mode: "read" })) !== "granted") {
    if ((await handle.requestPermission({ mode: "read" })) !== "granted") return null;
  }
  const file = await handle.getFile();
  return { name: file.name, bytes: new Uint8Array(await file.arrayBuffer()), handle };
}

/** Writes bytes into a file the user picked, asking for permission to write when needed. */
export async function writeHandle(handle, bytes) {
  if (handle.queryPermission && (await handle.queryPermission({ mode: "readwrite" })) !== "granted") {
    if ((await handle.requestPermission({ mode: "readwrite" })) !== "granted") return false;
  }
  const writable = await handle.createWritable();
  await writable.write(bytes);
  await writable.close();
  return true;
}

/**
 * Asks where to save, and saves there; downloads instead where the browser can't ask.
 * @returns {Promise<{ name: string, handle?: FileSystemFileHandle } | null>}
 */
export async function saveFileAs(bytes, suggestedName, { mime, extension, description }) {
  if (canSaveInPlace) {
    try {
      const handle = await window.showSaveFilePicker({
        suggestedName,
        types: [{ description, accept: { [mime]: [`.${extension}`] } }],
      });
      await writeHandle(handle, bytes);
      return { name: handle.name, handle };
    } catch (error) {
      if (error?.name === "AbortError") return null;
      throw error;
    }
  }
  download(bytes, suggestedName, mime);
  return { name: suggestedName };
}

export function download(bytes, name, mime) {
  const url = URL.createObjectURL(new Blob([bytes], { type: mime }));
  const link = document.createElement("a");
  link.href = url;
  link.download = name;
  link.hidden = true;
  document.body.append(link);
  link.click();
  link.remove();
  setTimeout(() => URL.revokeObjectURL(url), 10_000);
}

/** Files the operating system asked the installed app to open (manifest file_handlers). */
export function onLaunchFiles(callback) {
  if (!("launchQueue" in window)) return;
  window.launchQueue.setConsumer(async (params) => {
    const handle = params.files?.[0];
    if (handle) callback(await readHandle(handle));
  });
}

/** Files dropped onto the window. */
export function onDroppedFiles(element, callback, onHover) {
  element.addEventListener("dragover", (event) => {
    if (![...(event.dataTransfer?.types ?? [])].includes("Files")) return;
    event.preventDefault();
    onHover?.(true);
  });
  element.addEventListener("dragleave", (event) => {
    if (event.relatedTarget && element.contains(event.relatedTarget)) return;
    onHover?.(false);
  });
  element.addEventListener("drop", async (event) => {
    onHover?.(false);
    const item = [...(event.dataTransfer?.items ?? [])].find((entry) => entry.kind === "file");
    if (!item) return;
    event.preventDefault();
    const handle = await item.getAsFileSystemHandle?.();
    if (handle?.kind === "file") {
      callback(await readHandle(handle));
      return;
    }
    const file = item.getAsFile();
    if (file) callback({ name: file.name, bytes: new Uint8Array(await file.arrayBuffer()) });
  });
}

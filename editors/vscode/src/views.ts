// Renders the results of the server's inspection requests (`zig-analyzer/status`, `fileStatus`,
// `syntaxTree`, `moduleGraph`) as text with styled ranges and a target for each line. Needs no VS
// Code, so that the unit tests can run it.

export type Style = "type" | "token" | "string" | "comment" | "number" | "title" | "label" | "path" | "error";

/** What a line leads to: a file, another line of the view, or a byte range of the source file */
export type Target = { file: string } | { line: number } | { range: [number, number] };

export interface View {
  lines: string[];
  /** Line (0-based), start and end column (UTF-16), style */
  styles: { line: number; start: number; end: number; style: Style }[];
  /** By line (0-based) */
  targets: Map<number, Target>;
}

export type Kind = "status" | "fileStatus" | "syntaxTree" | "moduleGraph";

/** How paths and times are shown */
export interface Format {
  path(p: string): string;
  time(ms: number): string;
}

/** A piece of a line: plain text, or text with a style */
type Chunk = string | [string, Style | undefined];

class Builder implements View {
  lines: string[] = [];
  styles: View["styles"] = [];
  targets = new Map<number, Target>();

  add(chunks: Chunk[], target?: Target): number {
    let text = "";
    for (const c of chunks) {
      if (typeof c === "string") {
        text += c;
        continue;
      }
      if (c[1] && c[0]) this.styles.push({ line: this.lines.length, start: text.length, end: text.length + c[0].length, style: c[1] });
      text += c[0];
    }
    this.lines.push(text);
    if (target) this.targets.set(this.lines.length - 1, target);
    return this.lines.length - 1;
  }
}

/** The module index of the standard library in `moduleGraph` imports */
const stdModule = 4294967295;

export function bytes(n: number): string {
  const units = ["B", "KiB", "MiB", "GiB", "TiB"];
  let i = 0;
  while (n >= 1024 && i < units.length - 1) {
    n /= 1024;
    i++;
  }
  return i === 0 ? `${n} B` : `${n.toFixed(1)} ${units[i]}`;
}

const nonempty = (v: unknown): v is string => typeof v === "string" && v !== "";

/** `rows` (lists of cells) as columns, all but the first aligned to the right; the first row is the header */
function table(b: Builder, rows: string[][], indent: string, styles: (Style | undefined)[] = []): void {
  const widths: number[] = [];
  for (const row of rows) row.forEach((cell, i) => (widths[i] = Math.max(widths[i] ?? 0, cell.length)));
  rows.forEach((row, r) => {
    const chunks: Chunk[] = [indent];
    row.forEach((cell, i) => {
      const pad = " ".repeat(widths[i] - cell.length);
      if (i > 0) chunks.push("  " + pad);
      chunks.push([cell, r === 0 ? "title" : styles[i]]);
      if (i === 0 && row.length > 1) chunks.push(pad);
    });
    b.add(chunks);
  });
}

/** One line of a field value, and where it leads */
type Value = [Chunk[], Target?];

/** Aligned `label value` lines; a list value continues on the following lines */
function fields(b: Builder, items: [string, string | Value[]][]): void {
  const width = Math.max(...items.map(([label]) => label.length));
  for (const [label, value] of items) {
    let values: Value[] = typeof value === "string" ? [[[value]]] : value;
    if (values.length === 0) values = [[[["none", "comment"]]]];
    values.forEach(([chunks, target], i) => {
      const l = i === 0 ? label : "";
      b.add([[l, "label"], " ".repeat(width - l.length + 2), ...chunks], target);
    });
  }
}

function syntaxTree(result: string): View {
  const b = new Builder();
  for (const line of result.split("\n")) {
    if (line === "") continue;
    const err = /^error@(\d+): (.*)$/.exec(line);
    const m = /^(\s*)(\w+)@(\d+)\.\.(\d+)(.*)$/.exec(line);
    if (err) {
      const at = Number(err[1]);
      b.add([["error", "error"], ["@" + err[1], "comment"], ": ", [err[2], "error"]], { range: [at, at] });
    } else if (m) {
      const style: Style = m[2] === "error_node" ? "error" : m[5] ? "token" : "type";
      b.add([m[1], [m[2], style], [`@${m[3]}..${m[4]}`, "comment"], [m[5], "string"]], { range: [Number(m[3]), Number(m[4])] });
    } else {
      // A token without a range (servers before token ranges)
      const t = /^(\s*)(\w+)( .*)$/.exec(line);
      b.add(t ? [t[1], [t[2], "token"], [t[3], "string"]] : [line]);
    }
  }
  return b;
}

interface ModuleGraphResult {
  std_root: string | null;
  modules: { root: string | null; builtin?: string | null; imports: { name: string; module: number }[]; files: number }[];
}

function moduleGraph(result: ModuleGraphResult, f: Format): View {
  const b = new Builder();
  const std = result.std_root;
  const stdTarget = nonempty(std) ? { file: std } : undefined;
  b.add([["std", "title"], "  ", nonempty(std) ? [f.path(std), "path"] : ["unknown", "comment"]], stdTarget);
  const name = (i: number): string => {
    const m = result.modules[i];
    if (!m) return "unknown";
    return nonempty(m.root) ? f.path(m.root) : "(generated, path not known yet)";
  };
  const headers = new Map<number, number>();
  const imports: [number, number][] = [];
  result.modules.forEach((m, i) => {
    b.add([""]);
    headers.set(
      i,
      b.add(
        [[`[${i}]`, "number"], " ", [name(i), nonempty(m.root) ? "path" : "comment"], "  ", [`${m.files} file${m.files === 1 ? "" : "s"}`, "comment"]],
        nonempty(m.root) ? { file: m.root } : undefined,
      ),
    );
    if (nonempty(m.builtin)) b.add(["    ", ["builtin", "label"], " ", [f.path(m.builtin), "path"]], { file: m.builtin });
    for (const imp of [...m.imports].sort((x, y) => (x.name < y.name ? -1 : x.name > y.name ? 1 : 0))) {
      if (imp.module === stdModule) {
        b.add(["    ", ["import", "label"], " ", [imp.name, "token"], [" → ", "comment"], ["std", "title"]], stdTarget);
      } else {
        const line = b.add(["    ", ["import", "label"], " ", [imp.name, "token"], [" → ", "comment"], [`[${imp.module}]`, "number"], " ", name(imp.module)]);
        imports.push([line, imp.module]);
      }
    }
  });
  // Imports refer to modules by index: they lead to the header lines
  for (const [line, module] of imports) {
    const header = headers.get(module);
    if (header !== undefined) b.targets.set(line, { line: header });
  }
  return b;
}

interface FileStatusResult {
  path: string;
  origin: string;
  context: string;
  open: boolean;
  modules: string[];
  projects: { root: string; last_build: { at_ms: number; files: number; diagnostics: number } | null }[];
  single_file_roots: string[];
}

function fileStatus(result: FileStatusResult, f: Format): View {
  const b = new Builder();
  const modules: Value[] = result.modules.map((m) =>
    m === "" ? [[["(generated, path not known yet)", "comment"]]] : [[[m === "std" ? "std" : f.path(m), "path"]], m === "std" ? undefined : { file: m }],
  );
  const projects: Value[] = result.projects.map((p) => {
    const l = p.last_build;
    const build = l ? `last build ${f.time(l.at_ms)}: ${l.files} files, ${l.diagnostics} diagnostics` : "no build yet";
    return [[[f.path(p.root), "path"], "  ", [build, "comment"]]];
  });
  fields(b, [
    ["File", [[[[f.path(result.path), "path"]], { file: result.path }]]],
    ["Origin", result.origin],
    ["Context", result.context],
    ["Open", result.open ? "yes" : "no"],
    ["Modules", modules],
    ["Projects", projects],
    ["Single-file roots", result.single_file_roots.map((r): Value => [[[f.path(r), "path"]], { file: r }])],
  ]);
  return b;
}

interface Query {
  name: string;
  executions: number;
  hits: number;
  cutoffs: number;
  total_ms: number;
  self_ms: number;
  max_ms: number;
  memos: number;
  keys: number;
  bytes: number;
  deps: number;
  incomplete: number;
}

interface StatusResult {
  revision: number;
  files: number;
  deep_verifications: number;
  writes: number;
  max_rss_kb: number;
  intern_pool_items: number;
  intern_pool_bytes: number;
  heap_bytes: number;
  allocator: {
    small: number;
    peak_small: number;
    resident: number;
    live_slots: number;
    retained: number;
    returned: number;
    segments: number;
    decommits: number;
    recommits: number;
    large: number;
    occupancy: number[];
    classes: { size: number; pages: number; live: number; allocs: number; occupancy: number[] }[];
  } | null;
  queries: Query[];
  incomplete_causes?: { cycle: number; stack: number };
}

function status(result: StatusResult): View {
  const b = new Builder();
  const causes = result.incomplete_causes ?? { cycle: 0, stack: 0 };
  fields(b, [
    ["Revision", String(result.revision)],
    ["Files", String(result.files)],
    ["Writes", String(result.writes)],
    ["Deep verifications", String(result.deep_verifications)],
    ["Max RSS", result.max_rss_kb > 0 ? bytes(result.max_rss_kb * 1024) : "unknown"],
    ["Heap", result.heap_bytes > 0 ? bytes(result.heap_bytes) : "not counted"],
    ["InternPool", `${result.intern_pool_items} items, ${bytes(result.intern_pool_bytes)}`],
    ["Incomplete", `${causes.cycle} by cycles, ${causes.stack} by stack depth`],
  ]);

  const a = result.allocator;
  if (a) {
    b.add([""]);
    b.add([["Allocator", "title"]]);
    fields(b, [
      ["  Small", `${bytes(a.small)} (peak ${bytes(a.peak_small)})`],
      ["  Resident", bytes(a.resident)],
      ["  Live slots", bytes(a.live_slots)],
      ["  Retained", bytes(a.retained)],
      ["  Returned", bytes(a.returned)],
      ["  Large", bytes(a.large)],
      ["  Segments", `${a.segments} (decommits ${a.decommits}, recommits ${a.recommits})`],
      ["  Occupancy", a.occupancy.join(" ")],
    ]);
    b.add([""]);
    table(b, [
      ["Size", "Pages", "Live", "Allocs", "Occupancy"],
      ...a.classes.map((c) => [String(c.size), bytes(c.pages), String(c.live), String(c.allocs), c.occupancy.join(" ")]),
    ], "  ");
  }

  b.add([""]);
  b.add([["Queries", "title"], [" (by total time)", "comment"]]);
  const queries = [...result.queries].sort((x, y) => y.total_ms - x.total_ms || (x.name < y.name ? -1 : x.name > y.name ? 1 : 0));
  table(b, [
    ["Query", "Runs", "Hits", "Cutoffs", "Total ms", "Self ms", "Max ms", "Memos", "Keys", "Bytes", "Deps", "Incomplete"],
    ...queries.map((q) => [
      q.name, String(q.executions), String(q.hits), String(q.cutoffs),
      q.total_ms.toFixed(2), q.self_ms.toFixed(2), q.max_ms.toFixed(2),
      String(q.memos), String(q.keys), bytes(q.bytes), String(q.deps), String(q.incomplete),
    ]),
  ], "  ", ["token"]);
  return b;
}

export function render(kind: Kind, result: unknown, f: Format): View {
  switch (kind) {
    case "syntaxTree":
      return syntaxTree(typeof result === "string" ? result : "");
    case "moduleGraph":
      return moduleGraph(result as ModuleGraphResult, f);
    case "fileStatus":
      return fileStatus(result as FileStatusResult, f);
    case "status":
      return status(result as StatusResult);
  }
}

/**
 * Converts the byte offsets of the server (UTF-8) to lines and UTF-16 columns of `text`. Line
 * breaks are `\n`; a `\r` before one belongs to its line, as the server sees it.
 */
export class ByteIndex {
  private readonly lines: string[];
  /** Byte offset of each line start */
  private readonly starts: number[] = [];

  constructor(text: string) {
    this.lines = text.split("\n");
    let at = 0;
    for (const line of this.lines) {
      this.starts.push(at);
      at += Buffer.byteLength(line) + 1;
    }
  }

  position(offset: number): { line: number; character: number } {
    let lo = 0;
    let hi = this.starts.length - 1;
    while (lo < hi) {
      const mid = (lo + hi + 1) >> 1;
      if (this.starts[mid] <= offset) lo = mid;
      else hi = mid - 1;
    }
    const prefix = Buffer.from(this.lines[lo]).subarray(0, Math.max(0, offset - this.starts[lo]));
    return { line: lo, character: prefix.toString("utf8").length };
  }
}

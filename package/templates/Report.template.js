(async () => {
  "use strict";
  const el = id => document.getElementById(id);
  // The report description. In the portal it only says {"served": true}: the description, the rows and the details come from the local API
  // of the portal (Portal, below).
  const embedded = JSON.parse(el("report-meta").textContent), served = embedded.served === true;
  // Whole numbers (nearly every number of a table) are grouped by hand: toLocaleString and Date cost microseconds a call.
  const number = n => { if (n == null || n === "") return ""; const x = Number(n); return Number.isSafeInteger(x) ? String(x).replace(/\B(?=(\d{3})+(?!\d))/g, ",") : x.toLocaleString("en-GB"); };
  const pad = n => String(n).padStart(2, "0");
  // Times are local wall-clock seconds of the report time zone, displayed with getUTC*.
  const dayText = new Map();
  const stamp = s => {
    if (s == null) return "";
    const whole = Math.floor(s), day = Math.floor(whole / 86400); let t = dayText.get(day);
    if (t === undefined) { const d = new Date(day * 86400000); t = `${d.getUTCFullYear()}-${pad(d.getUTCMonth() + 1)}-${pad(d.getUTCDate())} `; if (dayText.size > 5000) dayText.clear(); dayText.set(day, t); }
    const r = whole - day * 86400;
    return t + pad((r / 3600) | 0) + ":" + pad(((r % 3600) / 60) | 0) + ":" + pad(r % 60);
  };
  const make = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; };
  const portal = served ? Portal() : null;
  const meta = served ? await portal.start() : embedded;
  if (!meta) return;

  // ---- Header -------------------------------------------------------------------
  el("title").textContent = meta.title || "Exchange Server usage";
  const scope = [];
  if (meta.edge) {
    el("origin").textContent = "Exchange Server SE / Edge Transport";
    document.title = "Exchange Server | Edge Transport mail flow";
    el("servers-caption").textContent = "Real mail flow only: SMTP sessions with a message and tracking events, without load balancer and monitoring probes. Click a server for details.";
    scope.push(`Edge Transport report: mail flow only (an Edge Transport server has no client access). SMTP clients: who sends mail to the Edge (internet servers, partners, the Exchange organization). SMTP destinations: where the Edge sends it (Exchange Online, internet MX, the organization).${meta.detailed ? " Messages: one row per message with its route, including the mail refused during the SMTP conversation." : ""}`);
  }
  else scope.push(meta.detailed ? "Detailed report: one row per client session with its timeline across the front-end and back-end logs, failed and slow requests with their resolution, users with their clients and devices, operations and their latency, one row per message with its route, SMTP clients." : "Usage report: which servers are really used, by whom, with which protocols, clients, devices and operations, and which SMTP clients send mail through them.");
  if (meta.users.length) scope.push(`Users: ${meta.users.join(", ")}.`);
  if (meta.servers.length) scope.push(`Servers: ${meta.servers.join(", ")}.`);
  el("subtitle").textContent = scope.join(" ");
  for (const [label, value] of [["From", meta.periodStart], ["To", meta.periodEnd]]) el("range").append(make("div", null, `${label} ${value}`));
  el("range").append(make("small", null, `${meta.timeZone} - end excluded`));

  // Timing marks (ms from navigation start) read by the measurement scripts.
  // decodeMs: time the loader of a table waited for its blocks to be decoded; appendMs: time spent adding their rows to the table.
  // preview: first draw of the rows of the table that opens while it is still loading; previewRows: the rows it showed.
  const timing = window.__exlTiming = { scriptStart: performance.now(), overview: null, firstTab: null, complete: null, files: 0, firstFile: null, ready: {}, decodeMs: {}, appendMs: {}, preview: null, previewRows: null };
  // Test hook: counts the passes that rebuilt the table, the rows they showed and the duration of the last one; previewPasses
  // counts the draws of a table still loading (they do not change seq).
  const stats = window.__exlStats = { seq: 0, shown: 0, passMs: 0, previewPasses: 0 };
  const collator = new Intl.Collator(undefined, { sensitivity: "base", numeric: true });
  // A pass that waits for a repaint (to show "Indexing..." or "Sorting...") before a long synchronous step.
  const paint = () => new Promise(r => { const t = setTimeout(r, 60); requestAnimationFrame(() => setTimeout(() => { clearTimeout(t); r(); }, 0)); });

  // ---- Compact store ---------------------------------------------------------------------------------
  // A table keeps one typed column per field: numbers and times in a Float64Array (NaN = empty), text and lists as ids into a
  // dictionary of distinct strings (a Rope: a few large strings, not one object per value). A row is rebuilt only to draw it,
  // open it or export it; filters, sort and search work on the ids and on the dictionaries.
  const SEP = "\u0001", SEGMENT_CHARS = 1 << 26;
  const lowerUnits = t => { let out = ""; for (const ch of t) { const l = ch.toLowerCase(); out += l.length === ch.length ? l : ch; } return out; };
  // Text in lower case as the filters compare it (and as the server does): the dotted capital I, the one letter whose lower case mapping changes the
  // length, becomes i first, as in the lower-case copy of a dictionary.
  const lower = s => s.replace(/\u0130/g, "i").toLowerCase();
  class Rope {
    // Entry 0 is the empty value, entries 1..count are the strings. A segment is  SEP e1 SEP e2 SEP ... en SEP  (the separator
    // keeps a search from matching across two entries); off[e] is the global offset of entry e, base[s] that of segment s.
    static from(list) {
      const r = new Rope(), n = list.length;
      r.seg = []; r.base = []; r.first = []; r.count = n; r.low = null;
      r.off = new Uint32Array(n + 2); r.segOf = new Uint8Array(n + 2);
      let start = 0, g = 0;
      while (start < n) {
        let end = start, len = 1;
        while (end < n && (end === start || len + list[end].length + 1 <= SEGMENT_CHARS)) { len += list[end].length + 1; end++; }
        const s = r.seg.length; let p = g + 1;
        for (let j = start; j < end; j++) { r.off[j + 1] = p; r.segOf[j + 1] = s; p += list[j].length + 1; }
        r.seg.push(SEP + (end - start === 1 ? list[start] : list.slice(start, end).join(SEP)) + SEP);
        r.base.push(g); r.first.push(start + 1); g = p; start = end;
      }
      return r;
    }
    get(e) {
      if (!e) return "";
      const s = this.segOf[e], b = this.base[s];
      const last = e < this.count && this.segOf[e + 1] === s ? this.off[e + 1] - b - 1 : this.seg[s].length - 1;
      return this.seg[s].substring(this.off[e] - b, last);
    }
    // Entry that holds the character at `pos` of segment s.
    idAt(s, pos) {
      const g = this.base[s] + pos;
      let lo = this.first[s], hi = (s + 1 < this.seg.length ? this.first[s + 1] : this.count + 1) - 1;
      while (lo < hi) { const m = (lo + hi + 1) >> 1; if (this.off[m] <= g) lo = m; else hi = m - 1; }
      return lo;
    }
    findAll(text) {
      const needle = SEP + text + SEP, out = [];
      for (let s = 0; s < this.seg.length; s++) {
        const t = this.seg[s]; let p = t.indexOf(needle);
        while (p >= 0) { out.push(this.idAt(s, p + 1)); p = t.indexOf(needle, p + text.length + 1); }
      }
      return out;
    }
    lowered() {
      if (!this.low) this.low = this.seg.map(t => {
        let l = t.toLowerCase();
        // Offsets must stay valid: the only lower case mapping that changes the length is U+0130.
        if (l.length !== t.length) { l = t.replace(/İ/g, "i").toLowerCase(); if (l.length !== t.length) l = lowerUnits(t); }
        return l;
      });
      return this.low;
    }
    dropLowered() { this.low = null; }
    // Entries whose text contains `word` (lower case): Uint8Array over entry ids, and how many.
    indexOfAll(word) {
      const hit = new Uint8Array(this.count + 1), low = this.lowered(); let n = 0;
      if (!word) { hit.fill(1, 1); return { hit, n: this.count }; }
      for (let s = 0; s < low.length; s++) {
        const t = low[s]; let pos = t.indexOf(word);
        while (pos >= 0) {
          const e = this.idAt(s, pos);
          if (!hit[e]) { hit[e] = 1; n++; }
          pos = e < this.count && this.segOf[e + 1] === s ? t.indexOf(word, this.off[e + 1] - this.base[s]) : -1;
        }
      }
      return { hit, n };
    }
  }
  // Ids of the strings of a column, assigned as they arrive. A column whose values are nearly all different (message and
  // request IDs) stops looking them up: one entry per row costs less than a map of a million strings.
  class Dictionary {
    constructor() { this.map = new Map(); this.list = []; this.unique = false; }
    id(s) {
      if (this.unique) { this.list.push(s); return this.list.length; }
      let id = this.map.get(s);
      if (id === undefined) { this.list.push(s); id = this.list.length; this.map.set(s, id); }
      return id;
    }
    seen(rows) { if (!this.unique && rows >= 20000 && this.list.length > 0.9 * rows) { this.unique = true; this.map = null; } }
    finish() { const rope = Rope.from(this.list); this.list = null; if (this.map && this.map.size > 100000) this.map = null; return rope; }
  }
  // A text or list test compiled for a dictionary: Uint8Array over entry ids (1 = the entry matches).
  function entryHits(rope, expr) {
    if (expr.contains !== undefined) return rope.indexOfAll(expr.contains).hit;
    const hit = new Uint8Array(rope.count + 1), item = expr.list;
    for (let e = 1; e <= rope.count; e++) hit[e] = expr.inner(item ? [rope.get(e)] : rope.get(e)) ? 1 : 0;
    return hit;
  }
  class NumCol {
    constructor(n) { this.a = new Float64Array(n); }
    append(at, rows, k, start) {
      const a = this.a;
      for (let r = start; r < rows.length; r++) { const v = rows[r][k]; if (typeof v === "number") a[at + r] = v; else if (v == null) a[at + r] = NaN; else return r; }
      return -1;
    }
    finish() { }
    get(i) { const v = this.a[i]; return v === v ? v : null; }
    // `f.clearRows(mask)` clears the rows that fail in one pass over the column; a number test with a range needs no call per row.
    pred(expr) {
      const a = this.a, test = expr.test, f = i => { const v = a[i]; return test(v === v ? v : null); };
      if (expr.range) {
        const r = expr.range, lo = r.lo ?? -Infinity, hi = r.hi ?? Infinity, loOpen = !!r.loOpen, hiOpen = !!r.hiOpen;
        f.clearRows = mask => { for (let i = 0; i < a.length; i++) { const v = a[i]; if (!(loOpen ? v > lo : v >= lo) || !(hiOpen ? v < hi : v <= hi)) mask[i] = 0; } };
      }
      return f;
    }
    sum() { let s = 0; const a = this.a; for (let i = 0; i < a.length; i++) { const v = a[i]; if (v === v) s += v; } return s; }
  }
  class TextCol {
    constructor(n) { this.ids = new Uint32Array(n); this.dict = new Dictionary(); this.rope = null; }
    append(at, rows, k, start) {
      const ids = this.ids, dict = this.dict;
      for (let r = start; r < rows.length; r++) {
        let v = rows[r][k];
        if (v == null || v === "") { ids[at + r] = 0; continue; }
        if (typeof v !== "string") { if (typeof v === "object") return r; v = String(v); }
        ids[at + r] = dict.id(v);
      }
      dict.seen(at + rows.length);
      return -1;
    }
    finish() { this.rope = this.dict.finish(); this.map = this.dict.map; this.dict = null; }
    str(e) { return this.rope ? this.rope.get(e) : this.dict.list[e - 1]; }
    get(i) { const e = this.ids[i]; return e ? this.str(e) : null; }
    pred(expr) {
      const hit = entryHits(this.rope, expr);
      hit[0] = expr.inner(null) ? 1 : 0;
      if (expr.not) for (let e = 0; e < hit.length; e++) hit[e] ^= 1;
      return this.byEntry(hit);
    }
    byEntry(hit) {
      const ids = this.ids, f = i => hit[ids[i]] === 1;
      f.clearRows = mask => { for (let i = 0; i < ids.length; i++) mask[i] &= hit[ids[i]]; };
      return f;
    }
    // A selection in a list of values: `split` also accepts the parts of a value joined with ", ".
    multiPred(sel, not, split) {
      const rope = this.rope, hit = new Uint8Array(rope.count + 1);
      for (let e = 1; e <= rope.count; e++) {
        const text = rope.get(e);
        if (sel.has(text)) hit[e] = 1;
        else if (split && text.includes(", ")) for (const p of text.split(", ")) if (sel.has(p)) { hit[e] = 1; break; }
      }
      if (not) for (let e = 0; e < hit.length; e++) hit[e] ^= 1;
      return this.byEntry(hit);
    }
    rowsWhere(text, first) {
      const out = [], ids = this.ids, n = ids.length;
      const want = this.map ? (this.map.has(text) ? [this.map.get(text)] : []) : this.rope.findAll(text);
      if (!want.length) return out;
      const one = want.length === 1 ? want[0] : 0, set = new Set(want);
      for (let i = 0; i < n; i++) if (one ? ids[i] === one : set.has(ids[i])) { out.push(i); if (first) break; }
      return out;
    }
  }
  class ListCol {
    constructor(n) { this.starts = new Uint32Array(n + 1); this.items = new Uint32Array(Math.max(1024, n * 2)); this.size = 0; this.dict = new Dictionary(); this.rope = null; }
    append(at, rows, k, start) {
      const starts = this.starts, dict = this.dict;
      for (let r = start; r < rows.length; r++) {
        starts[at + r] = this.size;
        const v = rows[r][k];
        if (v == null) continue;
        if (!Array.isArray(v)) return r;
        for (const x of v) {
          if (this.size === this.items.length) { const bigger = new Uint32Array(this.items.length * 2); bigger.set(this.items); this.items = bigger; }
          this.items[this.size++] = dict.id(typeof x === "string" ? x : String(x));
        }
      }
      starts[at + rows.length] = this.size;
      return -1;
    }
    finish() { this.rope = this.dict.finish(); this.map = this.dict.map; this.dict = null; this.items = this.items.slice(0, this.size); }
    str(e) { return this.rope ? this.rope.get(e) : this.dict.list[e - 1]; }
    get(i) {
      const a = this.starts[i], b = this.starts[i + 1];
      if (a === b) return null;
      const out = new Array(b - a);
      for (let j = a; j < b; j++) out[j - a] = this.str(this.items[j]);
      return out;
    }
    pred(expr) {
      if (expr.rowLevel) return i => expr.test(this.get(i));
      return this.byItem(entryHits(this.rope, { ...expr, list: true }), expr.not);
    }
    multiPred(sel, not) {
      const rope = this.rope, hit = new Uint8Array(rope.count + 1);
      for (let e = 1; e <= rope.count; e++) if (sel.has(rope.get(e))) hit[e] = 1;
      return this.byItem(hit, not);
    }
    // A row passes when one of its items is in `hit` (or none is, with `not`).
    byItem(hit, not) {
      const starts = this.starts, items = this.items, want = not ? 0 : 1, n = starts.length - 1;
      const f = i => { let any = 0; for (let j = starts[i], e = starts[i + 1]; j < e; j++) if (hit[items[j]]) { any = 1; break; } return any === want; };
      f.clearRows = mask => { for (let i = 0; i < n; i++) { let any = 0; for (let j = starts[i], e = starts[i + 1]; j < e; j++) if (hit[items[j]]) { any = 1; break; } if (any !== want) mask[i] = 0; } };
      return f;
    }
  }
  // Values of a type the typed columns do not expect are kept as they are.
  class AnyCol {
    constructor(n) { this.v = new Array(n).fill(null); }
    static from(col, upto, n) { const c = new AnyCol(n); for (let i = 0; i < upto; i++) c.v[i] = col.get(i); return c; }
    append(at, rows, k, start) { for (let r = start; r < rows.length; r++) this.v[at + r] = rows[r][k]; return -1; }
    finish() { }
    get(i) { return this.v[i]; }
    pred(expr) { const v = this.v, test = expr.test; return i => test(v[i]); }
    multiPred(sel, not, split) {
      const v = this.v;
      return i => {
        const x = v[i]; let hit = false;
        if (Array.isArray(x)) { for (const p of x) if (sel.has(String(p))) { hit = true; break; } }
        else if (x != null && x !== "") {
          const text = typeof x === "string" ? x : String(x); hit = sel.has(text);
          if (!hit && split && text.includes(", ")) for (const p of text.split(", ")) if (sel.has(p)) { hit = true; break; }
        }
        return hit !== not;
      };
    }
    sum() { let s = 0; for (const x of this.v) s += Number(x) || 0; return s; }
  }
  class Table {
    constructor(def, n) {
      this.def = def; this.n = n; this.len = 0;
      this.cols = def.columns.map(c => c.kind === "num" || c.kind === "time" ? new NumCol(n) : c.kind === "text" ? new TextCol(n) : c.kind === "list" ? new ListCol(n) : null);
      if (!n) this.finish();
    }
    append(rows) {
      const at = this.len;
      if (at + rows.length > this.n) throw new ExlError("The data does not match the report description (more rows than announced).");
      for (let k = 0; k < this.cols.length; k++) {
        const col = this.cols[k]; if (!col) continue;
        const failed = col.append(at, rows, k, 0);
        if (failed >= 0) { const any = AnyCol.from(col, at + failed, this.n); this.cols[k] = any; any.append(at, rows, k, failed); }
      }
      this.len += rows.length;
    }
    finish() { for (const c of this.cols) if (c) c.finish(); }
    dropLowered() { for (const c of this.cols) if (c && c.rope) c.rope.dropLowered(); }
    get(i, k) { const c = this.cols[k]; return c ? c.get(i) : null; }
    row(i) { const out = new Array(this.cols.length); for (let k = 0; k < out.length; k++) { const c = this.cols[k]; out[k] = c ? c.get(i) : null; } return out; }
    sum(k) { const c = this.cols[k]; return c && c.sum ? c.sum() : 0; }
    // Rows whose text column k equals `text` (the first one only with `first`).
    rowsWhere(k, text, first) {
      const c = this.cols[k];
      if (c instanceof TextCol) return c.rowsWhere(text, first);
      const out = [];
      for (let i = 0; i < this.len; i++) if (this.get(i, k) === text) { out.push(i); if (first) break; }
      return out;
    }
  }
  // A failure the page can explain to the person who opens it.
  class ExlError extends Error { }
  const rowOf = (set, i) => { const d = data[set]; return Array.isArray(d) ? d[i] : d.row(i); };

  // ---- Data files ---------------------------------------------------------------------------------------
  // The engine writes every table as data files: lines of __exl.file(id, name) and __exl.push(kind, set, first, count, data),
  // one push per block (kind c: summary rows of a table, d: the detail columns of up to 500 rows), each as JSON -> gzip -> base64.
  // In a single-file report the files are scripts of this page; otherwise they are loaded from the folder next to it, two at a
  // time. The tables arrive in the order of the manifest and each one is usable as soon as all its rows are there.
  const dataInfo = meta.data || { id: "", folder: null, files: [] };
  const inlineLayout = !dataInfo.folder;
  const PLAIN = new Set(["servers", "daily"]);
  const data = {}, ready = {}, skipped = {}; let total = 0, loaded = 0, allLoaded = false;
  for (const name in meta.datasets) {
    const d = meta.datasets[name];
    data[name] = PLAIN.has(name) ? [] : null; ready[name] = !d.rows; total += d.rows;
    if (!d.rows && !PLAIN.has(name)) data[name] = new Table(d, 0);
  }
  async function decode(b64) {
    let bytes;
    if (Uint8Array.fromBase64) bytes = Uint8Array.fromBase64(b64);
    else { const bin = atob(b64); bytes = new Uint8Array(bin.length); for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i); }
    const stream = new Blob([bytes]).stream().pipeThrough(new DecompressionStream("gzip"));
    return JSON.parse(await new Response(stream).text());
  }
  const yieldNow = () => globalThis.scheduler && scheduler.yield ? scheduler.yield() : new Promise(r => setTimeout(r, 0));

  // Records of the files already run: the statements of a file reach the page through __exl, attributed to their script element.
  const records = new WeakMap(), inlineFiles = new Map();
  const record = script => { let r = records.get(script); if (!r) { r = { id: null, name: null, entries: [], script }; records.set(script, r); } return r; };
  const live = window.__exl;
  live.file = (id, name) => { const r = record(document.currentScript); r.id = id; r.name = name; };
  live.push = (k, set, first, count, payload) => { record(document.currentScript).entries.push({ k, set, first, count, data: payload }); };
  {
    // What the inline scripts of a single-file report queued before this script ran (block scope: the queue is released).
    for (const item of live.q.splice(0)) {
      const r = record(item[item.length - 1]);
      if (item[0] === "f") { r.id = item[1]; r.name = item[2]; inlineFiles.set(r.name, r); }
      else r.entries.push({ k: item[0], set: item[1], first: item[2], count: item[3], data: item[4] });
    }
  }
  // Detail blocks of a single-file report are already in memory: their elements are not needed any more.
  for (const [name, r] of inlineFiles) if (r.entries.length && r.entries[0].k === "d" && r.script) { r.script.remove(); r.script = null; }

  const fileUrl = name => new URL(`${dataInfo.folder.split("/").map(encodeURIComponent).join("/")}/${encodeURIComponent(name)}`, location.href).href;
  const missing = name => new ExlError(`The data folder "${dataInfo.folder}" was not found next to this page (file ${name}). Keep the page and its folder together as they were written; a zipped report must be extracted first.`);
  const inFlight = new Map();
  function getFile(f) {
    if (inlineLayout) {
      const r = inlineFiles.get(f.name);
      return r ? Promise.resolve(r) : Promise.reject(new ExlError(`The page does not contain the data file ${f.name}: the file is damaged.`));
    }
    let p = inFlight.get(f.name); if (p) return p;
    p = new Promise((resolve, reject) => {
      const s = document.createElement("script");
      s.onload = () => {
        const r = records.get(s); s.remove();
        if (!r || r.name !== f.name) return reject(missing(f.name));
        if (r.id !== dataInfo.id) return reject(new ExlError(`The folder next to this page belongs to another report (file ${f.name}). Keep the page and the folder written with it together.`));
        timing.files++; timing.firstFile ??= performance.now();
        resolve(r);
      };
      s.onerror = () => { s.remove(); reject(missing(f.name)); };
      s.src = fileUrl(f.name); document.head.append(s);
    });
    inFlight.set(f.name, p);
    const done = () => { if (inFlight.get(f.name) === p) inFlight.delete(f.name); };
    p.then(done, done);
    return p;
  }
  // Checksums (#verify in the address, or __exlVerifyAll()): the text of a file is rebuilt from its statements and compared to the manifest.
  const crcTable = Array.from({ length: 256 }, (_, n) => { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1; return c >>> 0; });
  function crcOf(f, r) {
    let text = `__exl.file("${r.id}","${r.name}");\n`, c = 0xFFFFFFFF;
    for (const e of r.entries) text += `__exl.push("${e.k}","${e.set}",${e.first},${e.count},"${e.data}");\n`;
    for (let i = 0; i < text.length; i++) c = crcTable[(c ^ text.charCodeAt(i)) & 0xFF] ^ (c >>> 8);
    return { crc: (~c) >>> 0, bytes: text.length };
  }
  // In a single-file report the statements of a table file are dropped once its rows are loaded: such a file is checked while
  // it loads (#verify) and listed in `unchecked` otherwise.
  const verified = window.__exlVerify = { checked: 0, bad: [], unchecked: [] }, consumed = new Set();
  function check(f, r) {
    const rows = r.entries.reduce((a, e) => a + e.count, 0), sum = crcOf(f, r);
    verified.checked++;
    if (rows !== f.rows || sum.bytes !== f.bytes || sum.crc !== f.crc) verified.bad.push(f.name);
  }
  // In a folder report every file is read again by a script of its own (the loader may be releasing the blocks of the copy it
  // is reading), and checked as soon as it has run.
  window.__exlVerifyAll = async () => {
    for (const f of dataInfo.files) {
      if (consumed.has(f.name)) { if (!verifyMode && !verified.unchecked.includes(f.name)) verified.unchecked.push(f.name); continue; }
      if (!inlineLayout) inFlight.delete(f.name);
      check(f, await getFile(f)); if (!inlineLayout) inFlight.delete(f.name);
    }
    if (verified.unchecked.length) verified.note = "Files of tables already loaded are checked while loading: open the page with #verify to check them.";
    return verified;
  };

  // Loading line above the tabs once the overview is displayed (the full-screen overlay is only for the first seconds).
  const progress = el("progress"), progressText = el("progress-text"), progressFill = el("progress-fill");
  const summaryFiles = dataInfo.files.filter(f => f.kind === "c");
  let filesDone = 0;
  function showProgress(set) {
    const title = ((tabs.find(t => t.name === set) || {}).title || set).toLowerCase(), t = data[set];
    const part = inlineLayout || summaryFiles.length < 2 ? "" : ` (file ${Math.min(filesDone + 1, summaryFiles.length)} of ${summaryFiles.length})`;
    const text = `Loading ${title}: ${number(Array.isArray(t) ? t.length : t.len)} of ${number(meta.datasets[set].rows)} rows${part}`, pct = total ? loaded / total * 100 : 100;
    if (!el("loading").hidden) { el("loading-text").textContent = `${text}...`; el("loading-fill").style.width = `${pct}%`; }
    else { progressText.textContent = text; progressFill.style.width = `${pct}%`; }
  }

  // Detail columns (timelines, routes, transcripts) stay compressed: the block that holds a row is decoded when the row is opened.
  // In a folder report the file that holds the block is loaded then (the last files opened are kept, up to 256 MB), the blocks
  // decoded last are kept as well.
  const detailFiles = {}, detailCache = new Map(), detailLoaded = new Map(); let detailBytes = 0;
  for (const f of dataInfo.files) if (f.kind === "d") (detailFiles[f.set] ||= []).push(f);
  // fullRow searches by first row: do not depend on the order of the files.
  for (const list of Object.values(detailFiles)) list.sort((a, b) => a.first - b.first);
  const lastBefore = (list, i, first) => { let lo = 0, hi = list.length - 1; while (lo < hi) { const m = (lo + hi + 1) >> 1; if (first(list[m]) <= i) lo = m; else hi = m - 1; } return list[lo]; };
  async function detailFile(f) {
    const kept = detailLoaded.get(f.name);
    if (kept) { detailLoaded.delete(f.name); detailLoaded.set(f.name, kept); return kept.record; }
    const r = await getFile(f);
    if (!inlineLayout) {
      detailLoaded.set(f.name, { record: r, bytes: f.bytes }); detailBytes += f.bytes;
      while (detailBytes > 256 * 1048576 && detailLoaded.size > 1) { const [name, old] = detailLoaded.entries().next().value; detailLoaded.delete(name); detailBytes -= old.bytes; }
    }
    return r;
  }
  async function fullRow(set, i) {
    if (served) return portal.fullRow(set, i);
    const row = rowOf(set, i), cols = meta.datasets[set].detailColumns, files = detailFiles[set];
    if (!cols || !files) return row;
    const f = lastBefore(files, i, x => x.first); if (i < f.first || i >= f.first + f.rows) return row;
    const entries = (await detailFile(f)).entries, b = lastBefore(entries, i, x => x.first);
    if (i < b.first || i >= b.first + b.count) return row;
    let rows = detailCache.get(b);
    if (rows) detailCache.delete(b);
    else rows = (await decode(b.data)).rows;
    detailCache.set(b, rows);
    if (detailCache.size > 16) detailCache.delete(detailCache.keys().next().value);
    const full = row.slice(); cols.forEach((k, j) => { full[k] = rows[i - b.first][j]; });
    return full;
  }

  const col = (set, name) => meta.datasets[set] ? meta.datasets[set].columns.findIndex(c => c.name === name) : -1;
  const tone = v => {
    const s = String(v || "");
    // On an Edge Transport server, a message handed over to the organization or to the internet is the normal outcome.
    if (meta.edge && /^(Handed off outside collection|Sent)$/.test(s)) return "good";
    // A message accepted by a mail server outside the organization (internet, partner) is not a problem either.
    if (/^(Delivered|Accepted|Sent|Success|Recovered|In use|OK|Sent to external|Delivered and sent to external)$/.test(s)) return "good";
    if (/^(Failed|Rejected|Unresolved|ServerError|No real usage|Dropped|Poison|Failed at end|Rejected \(SMTP\))$/.test(s)) return "bad";
    if (/^(Deferred|Partially|Recovered later|ClientError|Incomplete|Handed off outside collection|Delivered and handed off|In transit|Client access only|Mail flow only|Intermittent errors|OK \(slow\)|Slow|Not completed)/.test(s)) return "warn";
    // Authentication types of client access: a token is the goal, a password sent with every request the type to move away from.
    if (s === "OAuth") return "good";
    if (s === "Basic") return "warn";
    return "";
  };
  const pillColumns = new Set(["Verdict", "Status", "Resolution", "Outcome"]);
  // The authentication types of client access are pills in the tables that list them (not the SMTP authentication of the SMTP clients).
  const authPillSets = new Set(["authentication", "users", "clients", "sessions"]);
  const pill = (set, name) => pillColumns.has(name) || (name === "Authentication" && authPillSets.has(set));
  // A user still stored as a security identifier: Exchange logged its token requests by SID and no log line paired that SID with an account.
  const SID_FORM = /^s-1-\d+(-\d+)+$/;
  const SID_HELP = "Unresolved security identifier: Exchange logs token (OAuth) requests by SID, and no log line pairs this SID with an account. Open the user for the evidence, or name it in Collection.IdentityMapFile.";
  const sidCell = (name, text) => {
    if (name !== "User" || !SID_FORM.test(text)) return null;
    const p = make("span", "pill warn", text); p.title = SID_HELP; return p;
  };

  // ---- Overview: tiles, server cards, activity chart -----------------------------------
  function renderOverview() {
    overviewDone = true;
    const S = data.servers || [], sc = n => col("servers", n);
    const usedServers = S.filter(r => r[sc("Verdict")] !== "No real usage").length;
    el("metric-servers").textContent = `${usedServers} / ${S.length}`;
    el("metric-servers-note").textContent = S.length - usedServers ? `${S.length - usedServers} server(s) without real usage` : "Every server has real activity";
    usersTile();
    authTile();
    const sum = serverSum;
    const requests = sum("Requests"), failed = sum("Failed requests"), unresolved = sum("Unresolved failures");
    el("metric-requests").textContent = number(requests);
    el("metric-requests-note").textContent = requests ? `${(failed / requests * 100).toLocaleString("en-GB", { maximumFractionDigits: 1 })}% failed, ${number(unresolved)} unresolved` : "No client activity";
    el("metric-messages").textContent = number(sum("Messages"));
    el("metric-messages-note").textContent = `${number(sum("SMTP received"))} SMTP received, ${number(sum("SMTP sent"))} sent`;
    if (meta.edge) {
      // Edge Transport: inbound and outbound SMTP instead of users and client requests.
      el("metric-servers-label").textContent = "Edge servers with mail flow";
      el("metric-servers-note").textContent = S.length - usedServers ? `${S.length - usedServers} Edge server(s) without mail flow` : "Every Edge server has mail flow";
      el("metric-users-label").textContent = "Inbound SMTP";
      el("metric-users").textContent = number(sum("SMTP received"));
      el("metric-requests-label").textContent = "Outbound SMTP";
      el("metric-requests").textContent = number(sum("SMTP sent"));
      el("metric-messages-note").textContent = `${number(sum("Message failures"))} with a failure (tracking)`;
      el("legend-a").lastChild.textContent = "SMTP received";
      el("legend-b").lastChild.textContent = "SMTP sent";
      el("activity-block").querySelector("svg").setAttribute("aria-label", "SMTP received and sent per day");
      edgeTiles();
    }

    const D = data.daily || [], dc = n => col("daily", n);
    for (const r of S) {
      const name = r[sc("Server")], card = make("article", "card");
      const head = make("div", "card-head"); head.append(make("strong", null, name), make("span", `pill ${tone(r[sc("Verdict")])}`, r[sc("Verdict")]));
      const kv = make("div", "kv");
      const figures = meta.edge
        ? [["SMTP in", r[sc("SMTP received")]], ["Refused", r[sc("SMTP rejected")]], ["SMTP out", r[sc("SMTP sent")]], ["Messages", r[sc("Messages")]], ["Msg failures", r[sc("Message failures")]], ["Active days", r[sc("Active days")]]]
        : [["Real users", r[sc("Real users")]], ["Requests", r[sc("Requests")]], ["Unresolved", r[sc("Unresolved failures")]], ["SMTP in", r[sc("SMTP received")]], ["SMTP out", r[sc("SMTP sent")]], ["Messages", r[sc("Messages")]]];
      for (const [label, value] of figures) { const d = make("div", null, label); d.prepend(make("b", null, number(value))); kv.append(d); }
      const bars = make("div", "bars"), protocols = (r[sc("Protocol detail")] || []).slice(0, 5), top = protocols.length ? protocols[0][1] : 0;
      for (const p of protocols) {
        const line = make("div", "bar-row"), track = make("div", "track"), fill = make("div", "fill");
        fill.style.width = `${top ? p[1] / top * 100 : 0}%`; track.append(fill);
        line.append(make("span", null, p[0]), track, make("span", "num", number(p[1]))); bars.append(line);
      }
      const days = D.filter(x => x[dc("Server")] === name).map(x => meta.edge ? (Number(x[dc("SMTP received")]) || 0) + (Number(x[dc("SMTP sent")]) || 0) : (Number(x[dc("Requests")]) || 0) + (Number(x[dc("Messages")]) || 0));
      const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg"); svg.setAttribute("class", "spark"); svg.setAttribute("viewBox", "0 0 100 30"); svg.setAttribute("preserveAspectRatio", "none");
      if (days.length > 1) {
        const max = Math.max(...days, 1), pts = days.map((v, i) => `${(i / (days.length - 1) * 100).toFixed(2)},${(28 - v / max * 26).toFixed(2)}`);
        const area = document.createElementNS(svg.namespaceURI, "polygon"); area.setAttribute("class", "area"); area.setAttribute("points", `0,30 ${pts.join(" ")} 100,30`);
        const line = document.createElementNS(svg.namespaceURI, "polyline"); line.setAttribute("points", pts.join(" ")); svg.append(area, line);
      }
      const last = r[sc("Last activity")];
      card.append(head, kv, bars, svg, make("div", "card-foot", last ? `Last real activity ${stamp(last).slice(0, 16)}` : "No real activity in the period"));
      card.addEventListener("click", () => showDetails("servers", S.indexOf(r)));
      el("cards").append(card);
    }
    {
      const byDay = new Map();
      const [seriesA, seriesB, labelA, labelB] = meta.edge ? ["SMTP received", "SMTP sent", "SMTP received", "SMTP sent"] : ["Requests", "Messages", "requests", "messages"];
      for (const r of D) { const k = r[dc("Day")], v = byDay.get(k) || [0, 0]; v[0] += Number(r[dc(seriesA)]) || 0; v[1] += Number(r[dc(seriesB)]) || 0; byDay.set(k, v); }
      const days = Array.from(byDay.keys()).sort(), svg = el("chart");
      if (!days.length) el("activity-block").hidden = true;
      else {
        const W = Math.max(600, svg.clientWidth || 900), H = 150, maxR = Math.max(1, ...days.map(d => byDay.get(d)[0])), maxM = Math.max(1, ...days.map(d => byDay.get(d)[1]));
        svg.setAttribute("viewBox", `0 0 ${W} ${H}`);
        const slot = (W - 40) / days.length, bw = Math.min(26, Math.max(2, slot * 0.36));
        days.forEach((d, i) => {
          const [req, msg] = byDay.get(d), x = 30 + i * slot;
          const a = document.createElementNS(svg.namespaceURI, "rect"); a.setAttribute("x", x); a.setAttribute("width", bw); a.setAttribute("y", 125 - req / maxR * 110); a.setAttribute("height", Math.max(1, req / maxR * 110));
          const b = document.createElementNS(svg.namespaceURI, "rect"); b.setAttribute("class", "msg"); b.setAttribute("x", x + bw + 1); b.setAttribute("width", bw); b.setAttribute("y", 125 - msg / maxM * 110); b.setAttribute("height", Math.max(1, msg / maxM * 110));
          const t = document.createElementNS(svg.namespaceURI, "title"); t.textContent = `${d}: ${number(req)} ${labelA}, ${number(msg)} ${labelB}`; a.append(t); b.append(t.cloneNode(true));
          svg.append(a, b);
          if (days.length <= 16 || i % Math.ceil(days.length / 12) === 0) { const tx = document.createElementNS(svg.namespaceURI, "text"); tx.setAttribute("x", x); tx.setAttribute("y", 142); tx.textContent = d.slice(5); svg.append(tx); }
        });
      }
    }
    el("loading").hidden = true; progress.hidden = allLoaded;
    timing.overview = performance.now();
    // The first rows of the table that opens arrived before the overview was drawn.
    if (pendingPreview) { const set = pendingPreview; pendingPreview = null; showPreview(set); }
  }
  const serverSum = name => (data.servers || []).reduce((a, r) => a + (Number(r[col("servers", name)]) || 0), 0);
  // Real users tile: the count is in the report description (the Edge Transport tile is set by edgeTiles).
  const usersTile = () => { if (!meta.edge) el("metric-users").textContent = meta.datasets.users ? number(meta.datasets.users.total) : "0"; };
  // Users on OAuth tile: from the Authentication cell of the users (a user of two types counts under each) and the Basic rows of the authentication
  // table, once both tables are complete. A report without the authentication table (Edge Transport) has four tiles.
  function authTile() {
    if (!meta.datasets.authentication || !meta.datasets.users) { const tile = el("metric-auth-tile"); if (tile) { tile.remove(); document.querySelector(".metrics").classList.add("four"); } return; }
    if (!ready.users || !ready.authentication || !data.users || !data.authentication) return;
    const size = set => { const t = data[set]; return Array.isArray(t) ? t.length : t.len; };
    const ua = col("users", "Authentication");
    let known = 0, oauth = 0, basic = 0, integrated = 0;
    for (let i = 0; i < size("users"); i++) {
      const modes = String(rowOf("users", i)[ua] || "").split(", ").filter(x => x);
      if (!modes.some(m => m !== "Unknown")) continue;
      known++;
      if (modes.includes("OAuth")) oauth++;
      if (modes.includes("Basic")) basic++;
      if (modes.some(m => m === "Negotiate" || m === "NTLM" || m === "Kerberos")) integrated++;
    }
    const ap = col("authentication", "Protocol"), am = col("authentication", "Authentication"), au = col("authentication", "Users"), byBasic = [];
    for (let i = 0; i < size("authentication"); i++) { const r = rowOf("authentication", i); if (r[am] === "Basic") byBasic.push([r[ap], Number(r[au]) || 0]); }
    byBasic.sort((a, b) => b[1] - a[1] || String(a[0]).localeCompare(String(b[0])));
    const top = byBasic.slice(0, 2).map(x => `${x[0]} ${number(x[1])}`).join(", ");
    el("metric-auth").textContent = known ? `${Math.round(100 * oauth / known)} %` : "–";
    const segments = [];
    if (basic) segments.push(`${number(basic)} on Basic${top ? ` (${top})` : ""}`);
    if (integrated) segments.push(`${number(integrated)} on Negotiate, NTLM or Kerberos`);
    el("metric-auth-note").textContent = !known ? "No authentication type recorded in this period" : segments.length ? segments.join(" · ") : "Every recorded user used OAuth";
  }
  // The Edge tiles that count SMTP clients and destinations: the counts are in the report description, the
  // deferred and failed total needs the destinations table, so the tile is drawn again when it is complete.
  function edgeTiles() {
    const clients = meta.datasets.smtpclients, out = meta.datasets.smtpdestinations, oc = n => col("smtpdestinations", n);
    el("metric-users-note").textContent = `${number(serverSum("SMTP rejected"))} refused during the SMTP conversation, ${number(clients ? clients.total : 0)} SMTP client(s)`;
    const bad = out && !ready.smtpdestinations ? "..." : number(data.smtpdestinations ? data.smtpdestinations.sum(oc("Deferred")) + data.smtpdestinations.sum(oc("Failed")) : 0);
    el("metric-requests-note").textContent = `${bad} deferred or failed, ${number(out ? out.total : 0)} destination(s)`;
  }

  // ---- Tabs ------------------------------------------------------------------------
  const tabs = [
    { name: "sessions", title: "Client sessions", caption: "One row per client session: what one client (Outlook, a mobile device, a browser, an IMAP client...) did for one user, until idle for a while. Front-end (HttpProxy, IIS) and back-end logs (MAPI, ActiveSync, IMAP/POP) are joined. Click a session to see its timeline, then a step to see its detail and where its raw lines are.", filters: ["Outcome", "Protocol", "Client", "Front ends", "Back ends", "Authentication"], sort: [0, -1] },
    { name: "issues", title: "Failed and slow requests", caption: `Failed requests of real users, plus successful requests slower than ${number(meta.slowRequestMs)} ms (long-polling requests excluded), plus every request of the users listed in FullDetailUsers. Useful for a server-side incident (all the errors of one server at one time). Resolution: Recovered = a success of the same user and protocol within the recovery window; Recovered later = later the same day; Unresolved = no success afterwards.`, filters: ["Server", "Protocol", "Outcome", "Resolution"], sort: [0, -1] },
    { name: "users", title: "Users", caption: "Real users (accounts that authenticated), with the protocols, clients and servers they used. Click a user to see each client and device (versions, addresses, servers) and its client sessions. A user shown as s-1-5-21-... is a security identifier of token (OAuth) requests that no log line names yet: open it for its evidence.", filters: ["Servers", "Protocols", "Clients"], sort: [5, -1] },
    { name: "operations", title: "Operations", caption: "One row per protocol and operation (MAPI request type, ActiveSync command, OWA action, IMAP/POP command, or method and page), all users: volume, failures and latency. Slow = successful requests above the slow threshold.", filters: ["Protocol", "Servers"], sort: [2, -1] },
    { name: "authentication", title: "Authentication", caption: "One row per protocol and authentication type, as the front end logged it: who still signs in with a user name and password (Basic), with Windows authentication (Negotiate, NTLM, Kerberos) or with a token (OAuth). A user or a device that used two types in the period is counted once under each. Unknown: no type recorded (ActiveSync/EWS/MAPI logs collected before 3.0, IMAP4 and POP3, logons rejected by IIS). OAuth possible follows Microsoft's table of the protocols that support modern authentication. Click a row to see its users and devices.", filters: ["Protocol", "Authentication", "OAuth possible"], sort: [3, -1] },
    { name: "messages", title: "Messages", caption: meta.edge ? "One row per message (Message-ID) that went through the Edge, inbound and outbound, plus the mail refused during the SMTP conversation (relay denied, blocked sender or recipient: no Message-ID). Click a message to see its route: every tracking event and SMTP session, in order." : "One row per message (Message-ID), consolidated over all servers, plus the mail refused during the SMTP conversation (relay denied, unknown recipient: no Message-ID). Click a message to see its route: every tracking event and SMTP session, in order.", filters: ["Status", "Direction"], sort: [0, -1] },
    { name: "smtpclients", title: "SMTP clients", caption: meta.edge ? "One row per SMTP client of the Edge (address and HELO name): internet servers and partners (inbound), and the mailbox servers of the organization (outbound mail handed over to the Edge), with their volume and refusals. Click a client to see its transactions and their SMTP transcript." : "One row per SMTP client (address and HELO name): the applications, devices, servers and users that send mail to the collected servers, with their volume and refusals. Hops between the collected Exchange servers are not listed. Click a client to see its transactions and their SMTP transcript.", filters: ["Servers", "Connectors", "TLS", "Authentication", "Authentication mechanism", "Authentication result"], sort: [4, -1] },
    { name: "smtpdestinations", title: "SMTP destinations", caption: "One row per destination of the Edge (remote address and send connector): Exchange Online, the MX of the internet domains, the mailbox servers of the organization (inbound mail handed over by the Edge). Remote host: name of its 220 banner. Click a destination to see its transactions, deferrals and failures with their SMTP transcript.", filters: ["Connector", "Servers", "TLS"], sort: [4, -1] }
  ].filter(t => meta.datasets[t.name]);
  // The SMTP clients of the portal are grouped per server, direction, role, connector, address, HELO name and account: their lists and their
  // first sort (most transactions first) name the portal's columns.
  if (served) {
    const t = tabs.find(x => x.name === "smtpclients"), k = col("smtpclients", "Transactions");
    if (t) { t.filters = ["Server", "Direction", "Role", "Connector", "TLS", "Authentication mechanisms", "Authentication results"]; if (k >= 0) t.sort = [k, -1]; }
  }
  let pendingHash = null;
  let tab = null, view = new Int32Array(0), sortState = null, filterDefs = [];
  // The table drawn in the grid: the open tab, or the table that will open while its rows are still loading (preview).
  let grid = null, previewIds = null, previewAt = 0, pendingPreview = null;
  for (const t of tabs) {
    const b = make("button", null, t.title); b.type = "button"; b.setAttribute("role", "tab");
    b.append(make("span", "count", number(meta.datasets[t.name].total)));
    b.disabled = !ready[t.name]; b.classList.toggle("loading", b.disabled); if (b.disabled) b.title = "Loading...";
    b.addEventListener("click", () => openTab(t)); t.button = b; el("tabs").append(b);
  }
  // Everything under the tabs waits for the first table.
  const filterRow = el("grid-filter"), dataParts = [el("filters"), el("clear-filters").parentNode, el("grid-head").closest(".grid")];
  for (const p of dataParts) p.hidden = true;
  el("tab-caption").textContent = "The tables open as soon as their rows are loaded.";

  const widthOf = c => c.kind === "time" ? "160px" : c.kind === "num" ? "minmax(90px,0.5fr)" : (c.name === "Message ID" || c.name === "Request ID" || c.name === "User agent" || c.name === "Last user agent") ? "minmax(180px,1.2fr)" : (c.name === "Subject" || c.name === "URL" || c.name === "Operations" || c.name === "Last error" || c.name === "First error") ? "minmax(200px,1.6fr)" : "minmax(120px,1fr)";
  const cellText = (c, v) => {
    if (v == null) return "";
    if (c.kind === "time") return stamp(v);
    if (c.kind === "num") return number(v);
    if (c.kind === "list") return v.length ? (v.length > 1 ? `${v[0]} (+${v.length - 1})` : v[0]) : "";
    return String(v);
  };

  // ---- Period: applied to the first time column of every table -----------------------------------
  // The values typed are local wall-clock seconds of the report time zone, like the data: no conversion.
  const periodInputs = { from: el("period-from"), to: el("period-to") };
  for (const [key, label] of [["from", "From"], ["to", "To"]]) {
    const i = periodInputs[key]; i.title = `${label} (${meta.timeZone}); applied to the first time column of each table, end excluded`;
    i.addEventListener("input", later); i.addEventListener("change", later);
  }
  el("clear-period").addEventListener("click", () => { periodInputs.from.value = ""; periodInputs.to.value = ""; applyFilters(); });
  el("period-note").textContent = `${meta.timeZone}; applied to the first time column of each table, end excluded.`;
  // The portal chooses its period with the day bar alone: the period inputs of the static report are not shown there (they stay empty).
  if (served) el("period-from").closest(".period-bar").hidden = true;
  const wallClock = v => { const m = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})(?::(\d{2}))?$/.exec(v); return m ? Date.UTC(+m[1], +m[2] - 1, +m[3], +m[4], +m[5], +(m[6] || 0)) / 1000 : null; };
  const periodBounds = () => ({ from: wallClock(periodInputs.from.value), to: wallClock(periodInputs.to.value) });

  // ---- Per-dataset caches --------------------------------------------------------------------------
  // Distinct values of a column with the number of rows holding each one, counted once per dataset.
  // null when there are more than `cap` values: such a column gets a text box instead of a list.
  const distinctCache = new Map();
  function distinctValues(set, c, multi, cap) {
    const id = `${set}:${c.i}`; if (distinctCache.has(id)) return distinctCache.get(id);
    const table = data[set], col = table.cols[c.i], counts = new Map();
    const add = (p, n) => { const x = counts.get(p); if (x === undefined) { if (counts.size >= cap) return false; counts.set(p, n); } else counts.set(p, x + n); return true; };
    let fits = true;
    if (col instanceof TextCol || col instanceof ListCol) {
      // One histogram over the ids, then one look at each distinct string (a value joined with ", " is split once).
      const rope = col.rope, hist = new Uint32Array(rope.count + 1), list = col instanceof ListCol;
      if (list) for (let j = 0; j < col.size; j++) hist[col.items[j]]++; else { const ids = col.ids; for (let i = 0; i < ids.length; i++) hist[ids[i]]++; }
      hist[0] = 0;
      let used = 0; for (let e = 1; e <= rope.count; e++) if (hist[e]) used++;
      if (used > cap && (list || !multi)) fits = false;
      else for (let e = 1; e <= rope.count && fits; e++) {
        const n = hist[e]; if (!n) continue;
        const text = rope.get(e);
        if (!list && multi && text.includes(", ")) { for (const p of text.split(", ")) if (p && !add(p, n)) { fits = false; break; } }
        else if (!add(text, n)) fits = false;
      }
    } else {
      scan: for (let i = 0; i < table.len; i++) {
        const v = col ? col.get(i) : null; if (v == null || v === "") continue;
        if (Array.isArray(v)) { for (const p of v) if (!add(String(p), 1)) { fits = false; break scan; } }
        else if (multi && typeof v === "string" && v.includes(", ")) { for (const p of v.split(", ")) if (p && !add(p, 1)) { fits = false; break scan; } }
        else if (!add(String(v), 1)) { fits = false; break; }
      }
    }
    const result = fits ? counts : null; distinctCache.set(id, result); return result;
  }
  // Rows that contain a free word (lower case) in one of their text values or list items, as a 0/1 byte per row. A word is looked
  // up once per dictionary (a native search over its lower-case text), then marked on the rows column by column.
  const wordCache = new Map();
  const wordKey = (set, w) => `${set}\u0001${w}`;
  const wordKnown = (set, w) => wordCache.has(wordKey(set, w));
  function wordRows(set, w) {
    const key = wordKey(set, w), cached = wordCache.get(key);
    if (cached) { wordCache.delete(key); wordCache.set(key, cached); return cached; }
    const table = data[set], n = table.len, rows = new Uint8Array(n);
    for (const col of table.cols) {
      if (col instanceof TextCol) {
        const found = col.rope.indexOfAll(w); if (!found.n) continue;
        const ids = col.ids, hit = found.hit; for (let i = 0; i < n; i++) if (hit[ids[i]]) rows[i] = 1;
      } else if (col instanceof ListCol) {
        const found = col.rope.indexOfAll(w); if (!found.n) continue;
        const starts = col.starts, items = col.items, hit = found.hit;
        for (let i = 0; i < n; i++) for (let j = starts[i], e = starts[i + 1]; j < e; j++) if (hit[items[j]]) { rows[i] = 1; break; }
      } else if (col instanceof AnyCol) {
        for (let i = 0; i < n; i++) {
          const v = col.v[i]; if (v == null || typeof v === "number") continue;
          if (typeof v === "string" ? lower(v).includes(w) : Array.isArray(v) && v.some(p => typeof p === "string" && lower(p).includes(w))) rows[i] = 1;
        }
      }
    }
    wordCache.set(key, rows); if (wordCache.size > 6) wordCache.delete(wordCache.keys().next().value);
    return rows;
  }
  // Sort key of every row for one column, as a whole number from 0: numbers keep their order (shifted to start at 0 when they are
  // whole numbers), text takes the rank of its string in collator order (equal text shares a rank, the collator is applied to the
  // distinct strings only), an empty cell takes `empty`, above every other key. Sorting then compares whole numbers only.
  const keyCache = new Map();
  function sortKeys(set, c) {
    const id = `${set}:${c.i}`, cached = keyCache.get(id);
    if (cached) { keyCache.delete(id); keyCache.set(id, cached); return cached; }
    const table = data[set], col = table.cols[c.i], n = table.len, keys = new Uint32Array(n);
    let empty = 0;
    if (col instanceof NumCol) {
      const a = col.a; let min = Infinity, max = -Infinity, whole = true;
      for (let i = 0; i < n; i++) { const v = a[i]; if (v !== v) continue; if (v < min) min = v; if (v > max) max = v; if (whole && v !== Math.floor(v)) whole = false; }
      if (min === Infinity) { empty = 0; keys.fill(0); }
      else if (whole && max - min < 2 ** 31 - 2) {
        empty = max - min + 1;
        for (let i = 0; i < n; i++) { const v = a[i]; keys[i] = v === v ? v - min : empty; }
      } else {
        // Fractions or a very wide range: the rank among the distinct values.
        const sorted = Float64Array.from(a).sort(); let m = 0;
        for (let j = 0; j < n; j++) { const v = sorted[j]; if (v !== v) break; if (!m || v !== sorted[m - 1]) sorted[m++] = v; }
        empty = m;
        for (let i = 0; i < n; i++) {
          const v = a[i]; if (v !== v) { keys[i] = empty; continue; }
          let lo = 0, hi = m - 1; while (lo < hi) { const mid = (lo + hi) >> 1; if (sorted[mid] < v) lo = mid + 1; else hi = mid; }
          keys[i] = lo;
        }
      }
    } else if (col instanceof TextCol) {
      const rope = col.rope, count = rope.count, order = new Array(count), strings = new Array(count + 1);
      for (let e = 1; e <= count; e++) { order[e - 1] = e; strings[e] = rope.get(e); }
      order.sort((x, y) => collator.compare(strings[x], strings[y]));
      const rank = new Uint32Array(count + 1); let r = 0;
      for (let j = 0; j < count; j++) { if (j && collator.compare(strings[order[j - 1]], strings[order[j]]) !== 0) r++; rank[order[j]] = r; }
      empty = count ? r + 1 : 0;
      const ids = col.ids; for (let i = 0; i < n; i++) keys[i] = ids[i] ? rank[ids[i]] : empty;
    } else {
      // Lists (and the rare column of mixed values): the text of the whole cell.
      const texts = new Array(n), distinct = new Set();
      for (let i = 0; i < n; i++) { const v = col ? col.get(i) : null; if (v == null) continue; const t = Array.isArray(v) ? v.join() : String(v); texts[i] = t; distinct.add(t); }
      const sorted = Array.from(distinct).sort(collator.compare), rank = new Map();
      for (let j = 0, r = 0; j < sorted.length; j++) { if (j && collator.compare(sorted[j - 1], sorted[j]) !== 0) r++; rank.set(sorted[j], r); }
      empty = sorted.length ? rank.get(sorted[sorted.length - 1]) + 1 : 0;
      for (let i = 0; i < n; i++) keys[i] = texts[i] === undefined ? empty : rank.get(texts[i]);
    }
    const result = { keys, empty };
    keyCache.set(id, result); if (keyCache.size > 8) keyCache.delete(keyCache.keys().next().value);
    return result;
  }

  // ---- Column expressions: what is typed in a filter box or after "field:" in the search ------------------
  // Each compiler returns { test(value) }, { error } or null (nothing typed).
  const NUM = "-?\\d+(?:\\.\\d+)?", numRange = new RegExp(`^(${NUM})?\\.\\.(${NUM})?$`), numOne = new RegExp(`^(<=|>=|<|>|=|!=)?(${NUM})$`);
  function compileNum(text) {
    const t = text.replace(/[\s,]/g, ""); let m = numRange.exec(t);
    if (m && (m[1] !== undefined || m[2] !== undefined)) {
      const lo = m[1] === undefined ? -Infinity : +m[1], hi = m[2] === undefined ? Infinity : +m[2];
      return lo > hi ? { error: "The start of the range is above its end." } : { test: v => typeof v === "number" && v >= lo && v <= hi, range: { lo, hi } };
    }
    m = numOne.exec(t); if (!m) return { error: "A number is expected: 5000, >5000, >=10, <3, <=3, 100..200, =0, !=0." };
    const n = +m[2];
    switch (m[1]) {
      case ">": return { test: v => typeof v === "number" && v > n, range: { lo: n, loOpen: true } };
      case ">=": return { test: v => typeof v === "number" && v >= n, range: { lo: n } };
      case "<": return { test: v => typeof v === "number" && v < n, range: { hi: n, hiOpen: true } };
      case "<=": return { test: v => typeof v === "number" && v <= n, range: { hi: n } };
      case "!=": return { test: v => typeof v !== "number" || v !== n };
      default: return { test: v => v === n, range: { lo: n, hi: n } };
    }
  }
  // A time bound: a date, a date and time, or a time of day (any day of the report). lo..hi covers what was typed
  // (the day, the minute or the second).
  const TIME = /^(?:(\d{4})-(\d{2})-(\d{2})(?:[ T]+(\d{1,2}):(\d{2})(?::(\d{2}))?)?|(\d{1,2}):(\d{2})(?::(\d{2}))?)$/;
  function timeOperand(text) {
    const m = TIME.exec(text.trim()); if (!m) return null;
    const date = m[1] !== undefined, hh = date ? m[4] : m[7], mm = date ? m[5] : m[8], ss = date ? m[6] : m[9];
    const h = hh === undefined ? 0 : +hh, mi = mm === undefined ? 0 : +mm, s = ss === undefined ? 0 : +ss;
    if (h > 23 || mi > 59 || s > 59) return null;
    const unit = ss !== undefined ? 1 : hh !== undefined ? 60 : 86400, clock = h * 3600 + mi * 60 + s;
    if (!date) return { tod: true, lo: clock, hi: clock + unit };
    const day = Date.UTC(+m[1], +m[2] - 1, +m[3]), d = new Date(day);
    if (d.getUTCMonth() !== +m[2] - 1 || d.getUTCDate() !== +m[3]) return null;
    return { tod: false, lo: day / 1000 + clock, hi: day / 1000 + clock + unit };
  }
  const timeOfDay = v => ((v % 86400) + 86400) % 86400;
  function compileTime(text) {
    const t = text.trim(), bad = { error: "A time is expected: 2026-10-10, >=2026-10-10 10:00, <10:30, 10:00..10:15, 2026-10-10..2026-10-12." };
    const cut = t.indexOf("..");
    if (cut >= 0) {
      const sa = t.slice(0, cut).trim(), sb = t.slice(cut + 2).trim(), a = sa ? timeOperand(sa) : null, b = sb ? timeOperand(sb) : null;
      if ((sa && !a) || (sb && !b) || (!a && !b)) return bad;
      if (a && b && a.tod !== b.tod) return { error: "A range cannot mix dates and times of day." };
      const tod = (a || b).tod, lo = a ? a.lo : -Infinity, hi = b ? b.hi : Infinity;
      if (!tod && lo >= hi) return { error: "The start of the range is after its end." };
      // 22:00..02:00 wraps over midnight.
      return { test: v => { if (typeof v !== "number") return false; const x = tod ? timeOfDay(v) : v; return lo < hi ? x >= lo && x < hi : x >= lo || x < hi; }, range: tod ? undefined : { lo, hi, hiOpen: true } };
    }
    const m = /^(<=|>=|<|>|=)?\s*(.+)$/.exec(t), o = m && timeOperand(m[2]); if (!o) return bad;
    const { tod, lo, hi } = o, compare = { ">": x => x >= hi, ">=": x => x >= lo, "<": x => x < lo, "<=": x => x < hi }[m[1]] || (x => x >= lo && x < hi);
    const ranges = { ">": { lo: hi }, ">=": { lo }, "<": { hi: lo, hiOpen: true }, "<=": { hi, hiOpen: true } };
    return { test: v => typeof v === "number" && compare(tod ? timeOfDay(v) : v), range: tod ? undefined : ranges[m[1]] || { lo, hi, hiOpen: true } };
  }
  // Text: contains, case-insensitive; "=x" is exactly x, "!x" does not contain x, "!=x" is not exactly x ("=" alone: empty).
  // `split`: the column joins several values with ", " (servers, protocols...), so "=x" matches one of the parts.
  function compileText(text, split) {
    let t = text.trim(), exact = false, not = false;
    if (t.startsWith("!=")) { exact = true; not = true; t = t.slice(2); }
    else if (t[0] === "=") { exact = true; t = t.slice(1); }
    else if (t[0] === "!") { not = true; t = t.slice(1); }
    t = lower(t.trim());
    if (!t && !exact) return { error: "Some text is expected after !." };
    const flat = v => v == null ? "" : Array.isArray(v) ? v.join(", ") : String(v);
    // The test of one value; `contains` is the plain case that a search over a whole dictionary can answer, `rowLevel` the cases
    // that need the whole cell of a list (a comma in the text, or "=" alone).
    let inner;
    const same = v => { const s = lower(flat(v)); return s === t || (split && s.includes(", ") && s.split(", ").includes(t)); };
    if (exact) inner = !t ? v => flat(v) === "" : v => Array.isArray(v) ? v.some(p => lower(String(p)) === t) : same(v);
    // A list is searched element by element (same result unless the text itself holds ", ").
    else if (t.includes(",")) inner = v => v != null && lower(flat(v)).includes(t);
    else inner = v => v != null && (typeof v === "string" ? lower(v).includes(t) : Array.isArray(v) ? v.some(p => lower(String(p)).includes(t)) : lower(String(v)).includes(t));
    const rowLevel = exact ? !t : t.includes(",");
    return { test: not ? v => !inner(v) : inner, inner, not, rowLevel, contains: exact || rowLevel ? undefined : t };
  }
  function compileColumn(c, text, split) {
    if (!text.trim()) return null;
    return c.kind === "num" ? compileNum(text) : c.kind === "time" ? compileTime(text) : compileText(text, split);
  }
  // Columns shown as a list of joined values are the ones named in the filters of their table.
  const joined = (set, c) => { const t = tabs.find(x => x.name === set); return !!t && t.filters.includes(c.name); };
  const FIELD_HELP = {
    text: "Contains (case-insensitive). =exact, !excluded, !=not exactly.",
    list: "Contains (case-insensitive). =exact, !excluded, !=not exactly.",
    num: "5000, >5000, >=10, <3, <=3, 100..200, =0, !=0.",
    time: "2026-10-10 (that day), >=2026-10-10 10:00, <10:30, 10:00..10:15 (any day), 2026-10-10..2026-10-12."
  };

  // ---- Search syntax: free words (all must match), field:value, -field:value, field>n, field:a..b, "quoted phrase" -------
  // A token that does not name a field of the table (http://host/path, fe80::1) still counts as a free word.
  const TERM = /(-?)([A-Za-z][A-Za-z0-9]*)(:|>=|<=|>|<)("[^"]*"|\S*)|"([^"]*)"|(\S+)/g;
  const normal = s => s.toLowerCase().replace(/[^a-z0-9]/g, "");
  const searchColumns = {};
  function parseSearch(text, set) {
    const cols = searchColumns[set] ||= meta.datasets[set].columns.map((c, i) => ({ ...c, i, key: normal(c.name) })).filter(c => c.kind !== "steps");
    const words = [], fields = [], hints = [];
    for (const m of text.matchAll(TERM)) {
      if (m[2] === undefined) { const w = lower(m[5] !== undefined ? m[5] : m[6]); if (w) words.push(w); continue; }
      const key = normal(m[2]), op = m[3], value = m[4].replace(/^"|"$/g, "");
      if (!value.trim()) continue;
      let c = cols.find(x => x.key === key);
      if (!c) {
        const near = cols.filter(x => x.key.startsWith(key));
        if (near.length !== 1) { hints.push(near.length ? `Ambiguous field "${m[2]}": ${near.map(x => x.name).join(", ")}` : `Unknown field "${m[2]}"`); words.push(lower(m[0])); continue; }
        c = near[0];
      }
      if (op !== ":" && c.kind !== "num" && c.kind !== "time") { hints.push(`"${m[2]}" is a text field: use ${m[2]}:value`); words.push(lower(m[0])); continue; }
      const expr = compileColumn(c, op === ":" ? value : op + value, joined(set, c));
      if (expr.error) { hints.push(`${c.name}: ${expr.error}`); continue; }
      fields.push({ c, expr, not: m[1] === "-", text: m[0] });
    }
    return { words, fields, hints };
  }

  // ---- Filter controls under the header ----------------------------------------------------------------
  // A list of values (checkboxes with their row counts, optionally "exclude selected") when a column has few
  // distinct values, a text box with the expressions above otherwise.
  let openPanel = null;
  function closePanel() { if (openPanel) { openPanel.remove(); openPanel = null; } }
  document.addEventListener("click", e => { if (openPanel && !openPanel.contains(e.target) && !e.target.closest(".multi-button")) closePanel(); });
  document.addEventListener("keydown", e => { if (e.key === "Escape") closePanel(); });
  document.addEventListener("scroll", e => { if (openPanel && !openPanel.contains(e.target)) closePanel(); }, true);
  window.addEventListener("resize", closePanel);
  function refreshMulti(f) {
    const n = f.sel.size;
    f.button.textContent = !n ? "All" : (f.exclude ? "Not " : "") + (n === 1 ? Array.from(f.sel)[0] : `${n} values`);
    f.button.classList.toggle("active", n > 0);
    f.button.title = n ? `${f.exclude ? "Excluded" : "Selected"}: ${Array.from(f.sel).join("; ")}` : `Choose ${f.c.name} values`;
  }
  function showPanel(f) {
    const same = openPanel && openPanel.owner === f; closePanel(); if (same) return;
    const panel = make("div", "multi-panel"); panel.owner = f;
    const bar = make("div", "bar"), exLabel = make("label"), ex = make("input"), none = make("button", null, "Clear"); ex.type = "checkbox"; ex.checked = f.exclude; none.type = "button";
    exLabel.append(ex, make("span", null, "Exclude selected")); bar.append(exLabel, none); panel.append(bar);
    const rowsBox = make("div"), labels = [];
    if (f.values.size > 12) {
      const find = make("input"); find.type = "search"; find.placeholder = "Find a value";
      find.addEventListener("input", () => { const q = find.value.trim().toLowerCase(); for (const [value, label] of labels) label.hidden = !!q && !value.toLowerCase().includes(q); });
      panel.append(find);
    }
    for (const [value, n] of Array.from(f.values).sort((a, b) => collator.compare(a[0], b[0]))) {
      const label = make("label"), box = make("input"); box.type = "checkbox"; box.checked = f.sel.has(value);
      box.addEventListener("change", () => { if (box.checked) f.sel.add(value); else f.sel.delete(value); refreshMulti(f); applyFilters(); });
      // A list counted on the server shows its counts while the days are still being counted.
      label.append(box, make("span", null, value), make("span", "n", f.counting ? `${number(n)} (counting...)` : number(n))); rowsBox.append(label); labels.push([value, label]);
    }
    panel.append(rowsBox);
    ex.addEventListener("change", () => { f.exclude = ex.checked; refreshMulti(f); applyFilters(); });
    none.addEventListener("click", () => { f.sel.clear(); for (const input of rowsBox.querySelectorAll("input")) input.checked = false; refreshMulti(f); applyFilters(); });
    const r = f.button.getBoundingClientRect();
    panel.style.left = `${Math.max(8, Math.min(r.left, innerWidth - 316))}px`; panel.style.top = `${Math.max(8, Math.min(r.bottom + 4, innerHeight - 370))}px`;
    document.body.append(panel); openPanel = panel;
  }
  function multiControl(c, values, multi) {
    const f = { type: "multi", c, values, multi, sel: new Set(), exclude: false, button: make("button") };
    f.button.type = "button"; f.button.className = "multi-button"; f.button.setAttribute("aria-haspopup", "true");
    f.button.addEventListener("click", () => showPanel(f)); refreshMulti(f);
    return f;
  }
  function boxControl(c, split) {
    const input = make("input"); input.type = "text"; input.autocomplete = "off"; input.spellcheck = false;
    input.placeholder = c.kind === "num" ? ">5000" : c.kind === "time" ? "2026-10-10" : "contains"; input.title = FIELD_HELP[c.kind] || FIELD_HELP.text; input.setAttribute("aria-label", `Filter ${c.name}`);
    input.addEventListener("input", later);
    return { type: "box", c, input, split, help: input.title };
  }
  function buildFilters(t, def, columns, restore) {
    const box = el("filters"); box.replaceChildren(); filterRow.replaceChildren(); filterDefs = [];
    const search = make("label", null, "Search all fields"), input = make("input"), hint = make("small", "hint");
    input.type = "search"; input.placeholder = "Words, field:value, -field:value, field>5, field:a..b";
    input.title = "Words must all match. field:value, -field:value, field>5, field>=5, field<5, field:a..b, \"quoted phrase\"; the field is a column name without spaces, a unique prefix is enough (client:\"Outlook 16\").";
    input.addEventListener("input", later); search.append(input, hint); box.append(search); filterDefs.push({ type: "search", input, hint });
    const named = columns.map(c => c.name);
    // The value lists of a table browsed on the server come from the server (/facets), as they arrive.
    const remote = served && portal.remote(t.name);
    const valuesOf = (c, listed) => remote ? portal.facetValues(t.name, c) : distinctValues(t.name, c, listed, listed ? 300 : 50);
    for (const c of columns) {
      const cell = make("div"); filterRow.append(cell);
      let f = null;
      if (c.kind === "text" || c.kind === "list") {
        const listed = t.filters.includes(c.name), values = valuesOf(c, listed), kept = remote && restore ? restore.getAll(`m.${c.name}`) : [];
        if (values && values.size >= 2) f = multiControl(c, values, listed);
        // An address that selects values of a list not counted yet keeps them.
        else if (kept.length) f = multiControl(c, new Map([...(values || new Map()), ...kept.filter(v => !(values && values.has(v))).map(v => [v, 0])]), listed);
      }
      f ||= boxControl(c, t.filters.includes(c.name));
      if (remote && f.type === "box") { const help = portal.boxHelp(t.name, c); if (help) f.input.title = f.help = `${f.help} ${help}`; }
      cell.append(f.button || f.input); filterDefs.push(f);
    }
    // A listed column that is not in the grid keeps its list above the grid.
    for (const name of t.filters) {
      if (named.includes(name)) continue;
      const i = def.columns.findIndex(c => c.name === name); if (i < 0) continue;
      const c = { ...def.columns[i], i }, values = valuesOf(c, true); if (!values || values.size < 2) continue;
      const f = multiControl(c, values, true), label = make("label", null, name); label.append(f.button); box.append(label); filterDefs.push(f);
    }
    if (remote) portal.facets(t.name);
    if (!restore) return;
    for (const f of filterDefs) {
      if (f.type === "search") f.input.value = restore.get("q") || "";
      else if (f.type === "box") f.input.value = restore.get(`f.${f.c.name}`) || "";
      else { f.sel = new Set(restore.getAll(`m.${f.c.name}`).filter(v => f.values.has(v))); f.exclude = restore.get(`x.${f.c.name}`) === "1"; refreshMulti(f); }
    }
  }

  // ---- State in the address: tab, period, search, column filters, lists, sort ------------------------------------
  const parseHash = () => new URLSearchParams(location.hash.replace(/^#/, ""));
  function stateHash() {
    const p = new URLSearchParams(); p.set("tab", tab.name);
    if (periodInputs.from.value) p.set("from", periodInputs.from.value);
    if (periodInputs.to.value) p.set("to", periodInputs.to.value);
    for (const f of filterDefs) {
      if (f.type === "search") { if (f.input.value.trim()) p.set("q", f.input.value); }
      else if (f.type === "box") { if (f.input.value.trim()) p.set(`f.${f.c.name}`, f.input.value); }
      else if (f.sel.size) { for (const v of f.sel) p.append(`m.${f.c.name}`, v); if (f.exclude) p.set(`x.${f.c.name}`, "1"); }
    }
    if (guardOverride > 0) p.set("maxbytes", String(guardOverride));
    if (sortState && !(tab.sort && sortState[0] === tab.sort[0] && sortState[1] === tab.sort[1])) p.set("sort", `${meta.datasets[tab.name].columns[sortState[0]].name}:${sortState[1]}`);
    // The portal: the selection of the day bar and the open row.
    if (served) portal.hash(p);
    return p.toString();
  }
  let hashTimer = null;
  function hashLater() { clearTimeout(hashTimer); hashTimer = setTimeout(() => { try { history.replaceState(null, "", `#${stateHash()}`); } catch { } }, 300); }
  function restorePeriod(p) {
    if (served) return;
    for (const key of ["from", "to"]) { const v = p.get(key); periodInputs[key].value = v && wallClock(v) != null ? v : ""; }
  }
  function restoreSort(p, def) {
    const m = /^(.*):(-?1)$/.exec(p.get("sort") || ""), i = m ? def.columns.findIndex(c => c.grid && c.name === m[1]) : -1;
    if (i >= 0) sortState = [i, +m[2]];
  }

  // Columns, widths and head of the grid for table t; a head that is not sortable has no click handler. sortable: true, false, or a test of a
  // column (a table browsed on the server sorts by its list key only; the other heads say when they sort).
  function prepareGrid(t, def, sortable) {
    const columns = def.columns.map((c, i) => ({ ...c, i })).filter(c => c.grid);
    t.columns = columns;
    document.documentElement.style.setProperty("--columns", columns.map(widthOf).join(" "));
    document.documentElement.style.setProperty("--min-width", `${columns.length * 130}px`);
    const head = el("grid-head"); head.replaceChildren();
    for (const c of columns) {
      const d = make("div", c.kind === "num" ? "num" : null, c.name);
      if (typeof sortable === "function" && !sortable(c)) { d.title = portal.sortTitle(c); d.classList.add("nosort"); }
      else if (sortable) {
        d.title = `Sort by ${c.name}`;
        d.addEventListener("click", () => { sortState = sortState && sortState[0] === c.i ? [c.i, -sortState[1]] : [c.i, c.kind === "text" ? 1 : -1]; markSort(); resort(); });
      }
      c.head = d; head.append(d);
    }
    return columns;
  }
  const captionOf = (t, def) => t.caption + (served ? portal.caption(t.name) : def.total > def.rows ? ` Showing the first ${number(def.rows)} of ${number(def.total)} rows: the CSV file has them all.` : "");
  function openTab(t, restore) {
    if (!ready[t.name] && !skipped[t.name]) return;
    closePanel(); tab = t; pendingHash = null; noticeSet = null; grid = null; previewIds = null;
    // The rows of another table must not be drawn with this table before its first pass has run.
    view = new Int32Array(0);
    // Lower-case copies of the dictionaries (free search) are kept for the open table only.
    for (const name in data) if (name !== t.name && data[name] && data[name].dropLowered) data[name].dropLowered();
    wordCache.clear();
    for (const x of tabs) x.button.classList.toggle("active", x === t);
    const def = meta.datasets[t.name];
    el("tab-caption").textContent = captionOf(t, def);
    if (skipped[t.name]) { showSkipped(t); return; }
    el("tab-notice").hidden = true;
    // A table browsed on the server (the portal, above clientRowsMax rows) sorts by its list key, in both directions.
    const remote = served && portal.remote(t.name);
    const columns = prepareGrid(t, def, remote ? c => portal.sortable(t.name, c) : true);
    grid = { set: t.name, columns, preview: false };
    for (const id of ["clear-filters", "export"]) { const b = el(id); b.disabled = false; b.removeAttribute("aria-disabled"); b.removeAttribute("title"); }
    sortState = remote ? portal.defaultSort(t.name) : t.sort ? [t.sort[0], t.sort[1]] : null;
    if (restore) restoreSort(restore, def);
    if (remote && sortState && !portal.sortable(t.name, { i: sortState[0] })) sortState = portal.defaultSort(t.name);
    if (remote) portal.exportTitle();
    buildFilters(t, def, columns, restore);
    if (served) portal.opened(t.name);
    for (const p of dataParts) p.hidden = false;
    applyFilters();
  }

  // ---- Preview: the first rows of the table that will open, while it is still loading ----------------------------
  // The rows already added are drawn in file order (not sorted) with the head of the grid; the search, the column filters, the
  // sort, "Clear filters" and the export are disabled until the table is complete, when the tab opens as usual (with the
  // filters and sort of the address). The preview never writes the address and does not count as a pass (__exlStats.seq).
  const PREVIEW_OFF = "Available when the table is complete";
  const previewSet = () => noticeSet || (wanted ? wanted.name : null);
  function showPreview(set) {
    // A static report draws its overview first; the portal draws the first rows as they arrive and the overview when its request answers.
    if (!overviewDone && !served) { pendingPreview = set; return; }
    const t = tabs.find(x => x.name === set);
    if (tab || grid || !t || ready[set] || skipped[set] || set !== previewSet()) return;
    const def = meta.datasets[set], columns = prepareGrid(t, def, false);
    grid = { set, columns, preview: true };
    const box = el("filters"); box.replaceChildren(); filterRow.replaceChildren();
    const search = make("label", null, "Search all fields"), input = make("input");
    input.type = "search"; input.placeholder = "Words, field:value, -field:value, field>5, field:a..b"; search.append(input); box.append(search);
    for (const c of columns) { const cell = make("div"), i = make("input"); i.type = "text"; i.setAttribute("aria-label", `Filter ${c.name}`); cell.append(i); filterRow.append(cell); }
    for (const i of [...box.querySelectorAll("input, button"), ...filterRow.querySelectorAll("input, button")]) { i.disabled = true; i.title = PREVIEW_OFF; }
    for (const id of ["clear-filters", "export"]) { const b = el(id); b.disabled = true; b.title = PREVIEW_OFF; b.setAttribute("aria-disabled", "true"); }
    for (const x of tabs) x.button.classList.toggle("active", x === t);
    el("tab-notice").hidden = true;
    const restored = initialHash.get("tab") === set && [...initialHash.keys()].some(k => /^(f\.|m\.|x\.|q$|sort$)/.test(k));
    el("tab-caption").textContent = captionOf(t, def) + (restored ? " Filters of the address are applied when the table is complete." : "");
    for (const p of dataParts) p.hidden = false;
    viewport.scrollTop = 0;
    refreshPreview();
    timing.preview = performance.now(); timing.previewRows = data[set].len;
  }
  function refreshPreview() {
    const set = grid.set, def = meta.datasets[set], n = data[set].len;
    if (!previewIds) { previewIds = new Int32Array(def.rows); for (let i = 0; i < previewIds.length; i++) previewIds[i] = i; }
    view = previewIds.subarray(0, n);
    render(false);
    // A portal table whose count comes with its rows says only how many are in.
    const of = served && def.total == null ? "" : ` of ${number(served ? Math.min(def.total, meta.clientRowsMax) : def.rows)}`;
    el("result-state").textContent = `Loading ${number(n)}${of} rows: filters, sort, search and export open when the table is complete`;
    stats.previewPasses++; previewAt = performance.now();
  }
  // A table that failed or starts again is not previewed any more (the loading line carries the reason).
  function endPreview(set) {
    if (!grid || !grid.preview || (set && grid.set !== set)) return;
    grid = null; previewIds = null; view = new Int32Array(0); spacer.replaceChildren(); el("result-state").textContent = "";
    for (const x of tabs) x.button.classList.remove("active");
    for (const p of dataParts) p.hidden = true;
  }
  function markSort() { for (const c of tab.columns) { c.head.classList.toggle("sorted", !!sortState && sortState[0] === c.i); c.head.classList.toggle("asc", !!sortState && sortState[0] === c.i && sortState[1] > 0); } }

  // Compiles every active filter once into a predicate (row number) -> boolean: period and numbers first, then
  // lists, text, fields of the search, and last the free words. Text and lists are tested once per distinct value of the
  // column (its dictionary), never once per row.
  function buildPredicates() {
    const set = tab.name, def = meta.datasets[set], table = data[set], numeric = [], lists = [], texts = [], words = [], active = [];
    const timeColumn = def.columns.findIndex(c => c.kind === "time"), { from, to } = periodBounds();
    if (from != null || to != null) {
      const lo = from ?? -Infinity, hi = to ?? Infinity;
      if (timeColumn >= 0) {
        const col = table.cols[timeColumn], period = { test: v => typeof v === "number" && v >= lo && v < hi, range: { lo, hi, hiOpen: true } };
        numeric.push(col.pred(period));
        active.push(["period", from != null && `from ${periodInputs.from.value.replace("T", " ")}`, to != null && `to ${periodInputs.to.value.replace("T", " ")}`].filter(Boolean).join(" "));
      }
      else active.push("period ignored (no time column)");
    }
    for (const f of filterDefs) {
      if (f.type === "multi") {
        if (!f.sel.size) continue;
        // Values are compared as text on both sides (the lists were built with String()); a value joined with ", " is split once.
        const sel = f.sel, not = f.exclude, col = table.cols[f.c.i];
        lists.push(col ? col.multiPred(sel, not, f.multi) : () => not);
        active.push(`${f.c.name} ${not ? "not in" : "in"} ${sel.size <= 2 ? Array.from(sel).join(", ") : `${sel.size} values`}`);
      } else if (f.type === "box") {
        const expr = compileColumn(f.c, f.input.value, f.split), invalid = !!expr && !!expr.error;
        f.input.classList.toggle("invalid", invalid); f.input.title = invalid ? expr.error : f.help;
        if (!expr || invalid) continue;
        const col = table.cols[f.c.i], pred = col ? col.pred(expr) : () => expr.test(null);
        (f.c.kind === "text" || f.c.kind === "list" ? texts : numeric).push(pred);
        active.push(`${f.c.name} ${f.input.value.trim()}`);
      }
    }
    const search = filterDefs[0], q = search.input.value.trim();
    const parsed = q ? parseSearch(q, set) : { words: [], fields: [], hints: [] };
    search.hint.textContent = parsed.hints.slice(0, 3).join(" | ");
    for (const x of parsed.fields) {
      const col = table.cols[x.c.i], pred = col ? col.pred(x.expr) : () => x.expr.test(null);
      texts.push(x.not ? i => !pred(i) : pred); active.push(x.text);
    }
    for (const w of parsed.words) {
      const rows = wordRows(set, w), f = i => rows[i] === 1;
      f.clearRows = mask => { for (let i = 0; i < rows.length; i++) mask[i] &= rows[i]; };
      words.push(f);
    }
    if (parsed.words.length) active.push(`words ${parsed.words.map(w => `"${w}"`).join(" ")}`);
    return { preds: [...numeric, ...lists, ...texts, ...words], active };
  }
  // Tables of at least this many rows keep one ordering of all their rows per sorted column.
  const LARGE = 100000, orderCache = new Map();
  async function sortedOrder(set, state) {
    const id = `${set}:${state[0]}:${state[1]}`, cached = orderCache.get(id);
    if (cached) { orderCache.delete(id); orderCache.set(id, cached); return cached; }
    const ids = new Int32Array(data[set].len); for (let i = 0; i < ids.length; i++) ids[i] = i;
    await sortView(set, ids, state);
    orderCache.set(id, ids); if (orderCache.size > 4) orderCache.delete(orderCache.keys().next().value);
    return ids;
  }
  // Passes (filter, sort, draw) run one after the other. A pass may wait for a repaint before a long step so that the
  // page can say "Indexing..." or "Sorting...", and it reads the state of the page when it starts.
  let chain = Promise.resolve();
  const queue = work => { chain = chain.then(work).catch(() => { el("result-state").textContent = "The table could not be updated."; }); return chain; };
  const applyFilters = () => queue(filterPass);
  const resort = () => queue(sortPass);
  async function filterPass() {
    if (!tab) return;
    // A list browsed on the server counts on the server: the pass does not hold the queue (a newer pass cancels it).
    if (served && portal.remote(tab.name)) { portal.remotePass().catch(e => { el("result-state").textContent = e.message; }); return; }
    const set = tab.name, t0 = performance.now(), q = filterDefs[0].input.value.trim(), table = data[set], state = sortState && [sortState[0], sortState[1]];
    if (q && table.len >= 200000) { const w = parseSearch(q, set).words; if (w.some(x => !wordKnown(set, x))) { el("result-state").textContent = "Indexing..."; await paint(); if (!tab || tab.name !== set) return; } }
    const n = table.len, { preds, active } = buildPredicates(), np = preds.length, t1 = performance.now();
    // A large table walks its rows in the order of the sort (kept per column and direction): the rows that pass come out sorted.
    const order = state && n >= LARGE ? await sortedOrder(set, state) : null;
    if (!tab || tab.name !== set) return;
    // Each predicate runs over the rows in row order (the columns are read sequentially) and clears the rows it rejects;
    // the rows that remain are then listed, in the order of the sort for a large table.
    let mask = null;
    if (np) {
      mask = new Uint8Array(n).fill(1);
      for (const f of preds) {
        if (f.clearRows) f.clearRows(mask);
        else for (let i = 0; i < n; i++) if (mask[i] && !f(i)) mask[i] = 0;
      }
    }
    const tm = performance.now();
    let out = new Int32Array(n), count = 0;
    if (order) { for (let k = 0; k < n; k++) { const i = order[k]; if (!mask || mask[i]) out[count++] = i; } }
    else if (!mask) { for (let i = 0; i < n; i++) out[i] = i; count = n; }
    else for (let i = 0; i < n; i++) if (mask[i]) out[count++] = i;
    if (count !== n) out = out.slice(0, count);
    const t2 = performance.now();
    if (!order) await sortView(set, out, state);
    if (!tab || tab.name !== set) return;
    const t3 = performance.now();
    view = out;
    el("export").title = view.length > 500000 ? "Exports the rows shown (a large file). The CSV file of the report holds every row of the table." : "";
    render(true); markSort();
    const text = `${number(view.length)} of ${number(n)} rows${served ? portal.resultNote(set) : ""}${active.length ? ` - ${active.join("; ")}` : ""}`;
    el("result-state").textContent = text.length > 300 ? `${text.slice(0, 297)}...` : text;
    stats.passMs = performance.now() - t0; stats.shown = view.length; stats.seq++;
    stats.parts = { predicates: Math.round(t1 - t0), mask: Math.round(tm - t1), collect: Math.round(t2 - tm), sort: Math.round(t3 - t2), draw: Math.round(performance.now() - t3) };
    timing.firstTab ||= performance.now();
    hashLater();
  }
  async function sortPass() {
    if (!tab) return;
    if (served && portal.remote(tab.name)) { portal.remotePass().catch(e => { el("result-state").textContent = e.message; }); return; }
    // A large table filters again in the new order (cheaper than sorting what passed).
    if (data[tab.name].len >= LARGE) return filterPass();
    const set = tab.name, v = view, t0 = performance.now(), state = el("result-state").textContent;
    await sortView(set, v);
    if (!tab || tab.name !== set || view !== v) return;
    el("result-state").textContent = state;
    render(true); markSort();
    stats.passMs = performance.now() - t0; stats.seq++;
    hashLater();
  }
  // Sorts `ids` (row numbers of `set`) in place by the current sort: the sort key and the row number are packed in one number
  // (exact below 2^53) so that the native numeric sort of a typed array does the work; equal keys keep the order of the rows,
  // empty cells come last in both directions. The first sort on a column ranks its values.
  async function sortView(set, ids, state = sortState) {
    if (!state) return;
    const [index, dir] = state, c = { ...meta.datasets[set].columns[index], i: index }, table = data[set];
    if (!keyCache.has(`${set}:${index}`) && (c.kind !== "num" && c.kind !== "time" || table.len >= 200000)) { el("result-state").textContent = "Sorting..."; await paint(); }
    const { keys, empty } = sortKeys(set, c), m = ids.length;
    if (m < 2) return;
    const mult = 2 ** Math.ceil(Math.log2(table.len + 1));
    if ((empty + 1) * mult <= 2 ** 53) {
      const packed = new Float64Array(m);
      if (dir > 0) for (let j = 0; j < m; j++) { const i = ids[j]; packed[j] = keys[i] * mult + i; }
      else for (let j = 0; j < m; j++) { const i = ids[j], k = keys[i]; packed[j] = (k === empty ? empty : empty - 1 - k) * mult + i; }
      packed.sort();
      for (let j = 0; j < m; j++) { const x = packed[j]; ids[j] = x - Math.floor(x / mult) * mult; }
    } else {
      ids.sort((a, b) => {
        const x = keys[a], y = keys[b];
        if (x === empty) return y === empty ? a - b : 1;
        if (y === empty) return -1;
        return (x - y) * dir || a - b;
      });
    }
  }

  // ---- Virtual scrolling: only the visible rows exist in the page -----------------------------
  // The scroll height is the rows times ROW up to MAX_HEIGHT (browsers cap the height of a box); above, the scrollbar is scaled: its position
  // is the share of the ranks above the window, every rank stays reachable, and the visible rows are placed around the scroll position.
  // A table browsed on the server (portal) draws the rows of its page cache and a placeholder for a row still being read.
  const ROW = 36, MAX_HEIGHT = 16000000, viewport = el("viewport"), spacer = el("spacer");
  // The rank at the top of the grid (a fraction while the scrollbar is scaled).
  function topRank(n) {
    const height = Math.min(n * ROW, MAX_HEIGHT), range = Math.max(0, height - viewport.clientHeight);
    return range > 0 ? Math.min(viewport.scrollTop, range) / range * Math.max(0, n - viewport.clientHeight / ROW) : 0;
  }
  // Scrolls the grid so that rank r is at its top.
  function scrollToRank(r, n) {
    const height = Math.min(n * ROW, MAX_HEIGHT), range = Math.max(0, height - viewport.clientHeight), span = Math.max(0, n - viewport.clientHeight / ROW);
    viewport.scrollTop = span > 0 ? Math.min(r, span) / span * range : 0;
  }
  function render(reset) {
    if (reset) viewport.scrollTop = 0;
    const table = data[grid.set], remote = !!(table && table.remote), n = remote ? table.len : view.length;
    const height = Math.min(n * ROW, MAX_HEIGHT);
    spacer.style.height = `${height}px`;
    el("empty").hidden = n > 0 || (remote && table.counting);
    const pos = topRank(n), top = viewport.scrollTop;
    const first = Math.max(0, Math.floor(pos) - 10), last = Math.min(n, Math.ceil(pos + viewport.clientHeight / ROW) + 10);
    const fragment = document.createDocumentFragment();
    let missing = false;
    for (let p = first; p < last; p++) {
      const y = height === n * ROW ? p * ROW : top + (p - pos) * ROW;
      if (y + ROW > height) break;
      const i = remote ? p : view[p], line = make("div", "grid-row"); line.setAttribute("role", "row"); line.style.top = `${y}px`; line.dataset.row = i; line.tabIndex = 0;
      if (remote && !table.has(i)) {
        line.classList.add("loading"); missing = true;
        for (const c of grid.columns) line.append(make("div", null, ""));
        fragment.append(line); continue;
      }
      for (const c of grid.columns) {
        const v = table.get(i, c.i), text = cellText(c, v), cell = make("div", c.kind === "num" ? "num" : (c.name.endsWith(" ID") ? "mono" : null));
        const sid = sidCell(c.name, text);
        if (sid) cell.append(sid); else if (pill(grid.set, c.name) && text) cell.append(make("span", `pill ${tone(text)}`, text)); else cell.textContent = text;
        cell.title = c.kind === "list" && v ? v.join("; ") : text; line.append(cell);
      }
      fragment.append(line);
    }
    spacer.replaceChildren(fragment);
    stats.topRank = Math.floor(pos);
    if (remote) {
      portal.visible(grid.set, Math.floor(pos));
      if (missing || last < n) table.ensure(first, last, () => { if (grid && data[grid.set] === table) render(false); });
    }
  }
  let ticking = false;
  viewport.addEventListener("scroll", () => { if (!ticking) { ticking = true; requestAnimationFrame(() => { if (grid) render(false); ticking = false; }); } });
  window.addEventListener("resize", () => { if (grid) render(false); });

  let timer = null;
  function later() { clearTimeout(timer); timer = setTimeout(applyFilters, 250); }
  // Clears the search, the column filters, the lists and the sort of the current table; the period stays.
  el("clear-filters").addEventListener("click", () => {
    if (!tab) return;
    for (const f of filterDefs) { if (f.input) f.input.value = ""; if (f.sel) { f.sel.clear(); f.exclude = false; refreshMulti(f); } }
    sortState = tab.sort ? [tab.sort[0], tab.sort[1]] : null; closePanel(); applyFilters();
  });
  window.addEventListener("hashchange", () => {
    const p = parseHash(), t = tabs.find(x => x.name === p.get("tab"));
    // The portal reads another selection by reloading the page.
    if (served && !portal.sameSelection(p)) { location.reload(); return; }
    restorePeriod(p);
    if (t && (ready[t.name] || skipped[t.name])) openTab(t, p); else if (t) pendingHash = { t, p };
  });

  // ---- Details dialog --------------------------------------------------------------------------
  // Small table of nested rows; kinds: { index: "num" | "time" }.
  function miniTable(parent, headers, rows, kinds) {
    const table = make("table", "mini"), head = make("tr");
    headers.forEach((h, j) => head.append(make("th", kinds[j] === "num" ? "num" : null, h)));
    table.append(head);
    for (const s of rows) {
      const row = make("tr");
      headers.forEach((h, j) => { const x = s[j]; row.append(make("td", kinds[j] === "num" ? "num nowrap" : kinds[j] === "time" ? "nowrap" : null, x == null ? "" : kinds[j] === "time" ? stamp(x) : kinds[j] === "num" ? number(x) : String(x))); });
      table.append(row);
    }
    parent.append(table);
  }
  // Detail of one timeline step: fields kept for the request (failed / slow / watched requests are in the
  // "issues" dataset, joined on the request ID) and the log files that hold its raw lines.
  const quote = t => `'${String(t).replace(/'/g, "''")}'`;
  function stepDetails(s, user) {
    const box = make("div", "step-more");
    box.addEventListener("click", e => e.stopPropagation());
    const id = s[10], logs = s[11] || [];
    const issues = meta.datasets.issues && ready.issues ? data.issues : null, ri = col("issues", "Request ID");
    const at = id && ri >= 0 && issues ? issues.rowsWhere(ri, id, true)[0] : undefined, kept = at === undefined ? null : issues.row(at);
    const keptList = row => {
      const dl = make("dl");
      meta.datasets.issues.columns.forEach((c, k) => {
        const val = row[k]; if (val == null || val === "") return;
        dl.append(make("dt", null, c.name), make("dd", null, cellText(c, val)));
      });
      return dl;
    };
    const stepFields = () => {
      const dl = make("dl");
      for (const [label, val] of [["Request ID", id], ["Time", stamp(s[0])], ["Servers", s[1]], ["Action", s[2]], ["Status", s[3]], ["Duration (ms)", s[5] != null ? number(s[5]) : null], ["Detail", s[7]]])
        if (val != null && val !== "") dl.append(make("dt", null, label), make("dd", null, val));
      return [dl, make("p", "muted", s[8] === "fail"
        ? "The front end answered with a success: the failure comes from the back-end log (detail above). Every field is kept for HTTP failures, slow requests and the users listed in FullDetailUsers; the raw lines below hold everything."
        : "Successful request: the report keeps the fields above. Every field is kept for failures, slow requests and the users listed in FullDetailUsers.")];
    };
    box.append(make("h4", null, "Fields kept for this request"));
    // The portal reads the request from the server when the failed and slow requests of the page do not hold every row of the selection.
    const remote = served && id && !kept && s[8] !== "batch" && meta.datasets.issues && (!ready.issues || skipped.issues || portal.isCut("issues")) ? portal.keptFields(s, user, keptList, stepFields) : null;
    if (kept) box.append(keptList(kept));
    else if (s[8] === "batch") {
      box.append(make("p", "muted", `${number(s[4])} successful requests folded together: only their number, duration and servers are kept. Add the user to FullDetailUsers to keep every request one by one during an incident.`));
    } else if (remote) box.append(remote);
    else if (id && meta.datasets.issues && skipped.issues) {
      box.append(make("p", "muted", "The failed and slow requests are not loaded on this computer: open that tab and choose Load anyway."));
    } else if (id && meta.datasets.issues && !ready.issues) {
      box.append(make("p", "muted", "The failed and slow requests are still loading: close this step and open it again in a few seconds."));
    } else box.append(...stepFields());
    if (logs.length) {
      box.append(make("h4", null, "Raw lines in the Exchange logs"));
      for (const [role, server, kind, path, needle, needle2] of logs) {
        const block = make("div", "log");
        const head = make("div"); head.append(make("b", null, `${role} - ${server}`), document.createTextNode(` (${kind})`));
        block.append(head, make("div", "file", path));
        const search = needle || user;
        if (search) {
          let cmd = `Select-String -LiteralPath ${quote(path)} -SimpleMatch ${quote(search)}`;
          if (needle && needle2) cmd += ` | Where-Object { $_.Line -like ${quote("*" + needle2 + "*")} }`;
          const line = make("div", "cmd"), pre = make("pre", null, cmd), copy = make("button", null, "Copy"); copy.type = "button";
          copy.addEventListener("click", async () => {
            try { await navigator.clipboard.writeText(cmd); copy.textContent = "Copied"; }
            catch { const range = document.createRange(); range.selectNodeContents(pre); const sel = getSelection(); sel.removeAllRanges(); sel.addRange(range); copy.textContent = "Selected"; }
            setTimeout(() => { copy.textContent = "Copy"; }, 1500);
          });
          line.append(pre, copy); block.append(line);
        }
        box.append(block);
      }
      box.append(make("p", "muted", "Paths as seen by the collector. Exchange deletes its logs after their own retention: an old file may be gone."));
    }
    return box;
  }

  // Only the last click draws: the block that holds a row may take a moment to decode. byId: i is the id of the row (the portal opens a row of a
  // table browsed on the server, or of an address, by its id).
  let detailSeq = 0;
  async function showDetails(set, i, byId) {
    const seq = ++detailSeq, dialog = el("detail");
    try {
      const r = byId ? await portal.fullRowById(set, i) : await fullRow(set, i);
      if (seq !== detailSeq) return;
      drawDetails(set, r);
    } catch (error) {
      if (seq !== detailSeq) return;
      el("detail-title").textContent = "Details unavailable";
      el("detail-body").replaceChildren(make("p", "muted", error instanceof ExlError || (served && error && error.portal) ? error.message : "The details of this row could not be read: this browser may not support the compressed data, or the file is damaged. The CSV files of the same folder have them."));
    }
    if (!dialog.open) dialog.showModal();
  }
  function drawDetails(set, r) {
    const def = meta.datasets[set], body = el("detail-body"); body.replaceChildren();
    const titleColumn = { servers: "Server", users: "User", messages: "Subject", smtp: "Mail from", issues: "User", daily: "Day", sessions: "User", clients: "User", operations: "Operation", authentication: "Protocol", smtpclients: "Remote IP", smtpdestinations: "Remote IP" }[set];
    const t = set === "smtpdestinations" ? (r[col(set, "Remote host")] || r[col(set, "Remote IP")]) : r[col(set, titleColumn)];
    el("detail-title").textContent = (t == null || t === "" ? (set === "messages" ? `(no subject) - ${r[col(set, "Status")]}` : "(no subject)") : t) + (set === "issues" ? ` - ${r[col(set, "Protocol")]} ${r[col(set, "Status")]}` : set === "sessions" ? ` - ${r[col(set, "Protocol")]} - ${r[col(set, "Client")]}` : set === "clients" ? ` - ${r[col(set, "Client")]}` : set === "operations" ? ` - ${r[col(set, "Protocol")]}` : set === "authentication" ? ` - ${r[col(set, "Authentication")]}` : set === "smtpclients" && r[col(set, "HELO")] ? ` - ${r[col(set, "HELO")]}` : set === "smtpdestinations" ? ` - ${r[col(set, "Connector")]}` : "");
    const dl = make("dl");
    def.columns.forEach((c, k) => {
      if (c.kind === "steps" || c.kind === "list" || (!c.grid && c.kind === "text")) return;
      const v = r[k]; if (v == null || v === "") return;
      const dd = make("dd"); const text = cellText(c, v);
      const sid = sidCell(c.name, text);
      if (sid) dd.append(sid); else if (pill(set, c.name)) dd.append(make("span", `pill ${tone(text)}`, text)); else dd.textContent = text;
      dl.append(make("dt", null, c.name), dd);
    });
    body.append(dl);
    def.columns.forEach((c, k) => {
      const v = r[k]; if (v == null || (Array.isArray(v) && !v.length) || v === "") return;
      if (c.kind === "list") {
        let heading = `${c.name} (${v.length})`;
        if (set === "messages" && c.name === "Recipients") {
          // A list that was replaced by its members is shown but is not a recipient; mail handed to a server outside the collected logs, and mail
          // accepted by a server outside the organization, are counted apart.
          const lists = v.filter(p => /\((Expanded|Resolved|Redirected)\)$/.test(p)).length, handed = v.filter(p => /\(Handed off\)$/.test(p)).length;
          const external = v.filter(p => /\(Sent to external\)$/.test(p)).length, status = r[col(set, "Status")];
          const n = v.length - lists;
          heading = `${n} recipient${n === 1 ? "" : "s"}` + (lists ? ` + ${lists} expanded list${lists === 1 ? "" : "s"}` : "")
            + (/^(Delivered and handed off|Delivered and sent to external|Handed off outside collection)$/.test(status) && external && external < n ? `, ${external} sent to external` : "")
            + ((status === "Delivered and handed off" || (status === "Handed off outside collection" && external)) && handed ? `, ${handed} handed off outside collection` : "");
        }
        body.append(make("h3", null, heading)); const ol = make("ol", "people"); for (const p of v) ol.append(make("li", null, p)); body.append(ol);
      } else if (c.kind === "steps" && c.name === "Timeline") {
        body.append(make("h3", null, `Timeline (${v.length} step${v.length > 1 ? "s" : ""}, front end > back end)`));
        const legend = make("div", "legend-line");
        for (const [label, style] of [["request", "var(--cp-accent)"], ["failure", "var(--cp-danger)"], ["back-end log", "var(--cp-link)"], ["successes folded together", "var(--cp-border-strong)"]]) {
          const s = make("span", null, label), i = make("i"); i.style.borderColor = style; s.prepend(i); legend.append(s);
        }
        body.append(legend);
        body.append(make("p", "muted", "Click a step to see what is kept for that request and where its raw lines are in the Exchange logs."));
        const ul = make("ul", "timeline");
        for (const s of v) {
          // [time, path, action, status, count, avg ms, max ms, detail, kind, until, request id, logs]
          const li = make("li", s[8] === "ok" ? null : s[8]);
          const when = make("div", "when", stamp(s[0]) + (s[9] ? ` - ${s[9]}` : ""));
          if (s[1]) when.append(make("span", "path", s[1]));
          const what = make("div", "what", `${s[2] || ""}${s[3] != null && s[8] !== "batch" ? "  " + s[3] : ""}`);
          const timing = s[4] > 1 ? `avg ${number(s[5])} ms, max ${number(s[6])} ms` : (s[5] != null ? `${number(s[5])} ms` : "");
          if (timing) what.append(make("span", "metric", timing));
          li.append(when, what);
          if (s[7]) li.append(make("div", "detail", s[7]));
          if (s[10] || (s[11] || []).length) {
            li.classList.add("clickable");
            let more = null;
            const toggle = () => {
              if (more) { more.remove(); more = null; li.classList.remove("open"); return; }
              more = stepDetails(s, r[col(set, "User")]); li.append(more); li.classList.add("open");
            };
            when.addEventListener("click", toggle); what.addEventListener("click", toggle);
          }
          ul.append(li);
        }
        body.append(ul);
      } else if (c.kind === "steps" && c.name === "Route") {
        // Steps are grouped by submission (slot 5): a message can enter the organization several times. A route without the slot stays one list.
        // Slot 6, when present, is the UTC millisecond: the order of events within a second matters when reading a route.
        const shortHost = h => String(h || "").split(".")[0].toLowerCase();
        const collected = new Set((meta.configuredServers || []).map(shortHost));
        const bySub = new Map(), subs = [];
        for (const s of v) { const no = s[5] == null ? 0 : s[5]; let g = bySub.get(no); if (!g) { g = { no, steps: [] }; bySub.set(no, g); subs.push(g); } g.steps.push(s); }
        const grouped = !(subs.length === 1 && subs[0].no === 0);
        const subHead = g => {
          // Who submitted the message: the front end that accepted it, or the host a server received it from. A host whose logs are collected
          // but which holds no sending step of this submission means the submission started before the collected logs.
          const first = g.steps[0], fe = g.steps.find(s => String(s[2]).startsWith("SMTP Receive"));
          let text = `Submission ${g.no} — ${stamp(first[0]).slice(11)}`;
          if (fe) {
            const d = String(fe[4] || ""), helo = /HELO ([^ |]+)/.exec(d), remote = /remote ([^ |]+)/.exec(d), host = /Hostname=([^\],\s|]+)/.exec(d);
            text += ` from ${helo ? helo[1] : remote ? remote[1] : "?"} via ${fe[1]}${host ? " → " + host[1].split(".")[0] : ""}`;
          } else if (first[2] === "Tracking" && first[3] === "RECEIVE") {
            const from = /\bfrom ([^ |]+)/.exec(String(first[4] || ""));
            if (!from) text += ` on ${first[1]}`;
            else {
              const origin = shortHost(from[1]);
              const sent = collected.has(origin) && g.steps.some(s => s[2] === "Tracking" && /^(SEND|SUBMIT)/.test(String(s[3])) && shortHost(s[1]) === origin);
              text += collected.has(origin) && !sent ? ` from ${from[1]} — origin outside collected logs, first seen on ${first[1]}` : ` from ${from[1]} → ${first[1]}`;
            }
          }
          return text;
        };
        const agents = v.filter(s => s[3] === "AGENTINFO").length;
        const lists = [];
        body.append(make("h3", null, grouped ? "Route (tracking events and SMTP sessions, by submission)" : "Route (tracking events and SMTP sessions, in order)"));
        if (agents) {
          const toggle = make("button", null, `Show agent steps (${agents})`); toggle.type = "button";
          toggle.addEventListener("click", () => {
            const on = !lists[0].classList.contains("agents");
            for (const ul of lists) ul.classList.toggle("agents", on);
            toggle.textContent = `${on ? "Hide" : "Show"} agent steps (${agents})`;
          });
          body.append(toggle);
        }
        for (const g of subs) {
          if (grouped) { const h = make("div", "sub-head", subHead(g)); h.append(make("span", "muted", `  ${g.steps.length} step${g.steps.length === 1 ? "" : "s"}`)); body.append(h); }
          const ul = make("ul", "timeline"); lists.push(ul);
          for (const s of g.steps) {
            const evt = String(s[3] || ""), detail = String(s[4] || ""), classes = [];
            if (String(s[2]).startsWith("SMTP")) classes.push("smtp");
            if (evt === "AGENTINFO") classes.push("agent");
            // A drop the organization chose (empty list, out-of-office, automatic forward or reply, suppressed recipient) is not a problem to look at.
            if (/^DROP/.test(evt)) classes.push(/distribution list is empty|out-of-office|auto-forward|auto-reply|recipient suppressed/.test(detail) ? "suppressed" : "warn");
            else if (/^(FAIL|DELIVERFAIL|POISON)/.test(evt)) classes.push("fail");
            else if (/^DEFER/.test(evt)) classes.push("warn");
            else if (/^EXPAND/.test(evt)) classes.push("info");
            else if (/ > /.test(evt)) classes.push("hop");
            const li = make("li", classes.join(" ") || null);
            const ms = s[6] == null ? "" : "." + String(Math.floor(s[6]) % 1000).padStart(3, "0");
            const what = make("div", "what"), arrow = evt.split(" > ");
            if (arrow.length > 1) arrow.forEach((p, k) => { if (k) what.append(make("span", "arrow", "→")); what.append(document.createTextNode(p)); });
            else what.textContent = evt;
            li.append(make("div", "when", `${stamp(s[0])}${ms}  ${s[1]}  ${s[2]}`), what);
            if (arrow.length > 1) {
              // A hop folded with its delivery: "to B | n recipients: a (Inbox); b (folder X) | delivered hh:mm:ss | status" -> header line, then one chip per recipient.
              const parts = detail.split(" | "), rcp = parts.find(p => /^\d+ recipients?: /.test(p));
              li.append(make("div", "detail", parts.filter(p => p !== rcp).join("  ·  ") + (rcp ? "  ·  " + rcp.slice(0, rcp.indexOf(":")) : "")));
              if (rcp) {
                // The "(+n)" the engine appends when it lists only the first recipients says how many are not shown; it is no recipient, so it is not a chip.
                const box = make("div", "rcpts"), listed = /^(.*?)(?: \(\+(\d+)\))?$/s.exec(rcp.slice(rcp.indexOf(":") + 2));
                for (const x of listed[1].split("; ")) box.append(make("span", null, x));
                if (listed[2]) box.append(make("em", "more", `(+${listed[2]})`));
                li.append(box);
              }
            } else li.append(make("div", "detail", detail));
            ul.append(li);
          }
          body.append(ul);
        }
      } else if (c.kind === "steps" && c.name === "SMTP transcripts") {
        body.append(make("h3", null, "SMTP session transcripts"));
        for (const s of v) { const d = make("details"); d.append(make("summary", null, `${stamp(s[0])}  ${s[1]}  ${s[2]}`), make("pre", null, s[3])); body.append(d); }
      } else if (c.kind === "steps" && c.name === "Clients and devices") {
        body.append(make("h3", null, `Clients and devices (${v.length})`));
        miniTable(body, ["Protocol", "Client", "Device type", "Device ID", "Client IPs", "Servers", "Requests", "Failures", "Last seen", "Authentication"], v, { 6: "num", 7: "num", 8: "time" });
      } else if (c.kind === "steps" && c.name === "Identifiers") {
        // [security identifier, status, evidence, hints, requests, first seen, last seen]
        body.append(make("h3", null, `Identifiers (${v.length})`));
        body.append(make("p", "muted", "Exchange logs token (OAuth) requests by security identifier (SID). Evidence: the log lines that pair the SID with an account, by kind (anchor: the account's own ActiveSync or OWA lines; mapi-backend: the Outlook back-end lines of the same client, on two days at least; file: Collection.IdentityMapFile) and number of lines. Hints: the account the device sent, and the account the ActiveSync back end logged for the same device (eas-backend); never used to merge."));
        miniTable(body, ["Security identifier", "Status", "Evidence", "Hints", "Requests", "First seen", "Last seen"], v, { 4: "num", 5: "time", 6: "time" });
      } else if (c.kind === "steps" && c.name === "Clients detail") {
        // [user, client, device type, device ID, servers, requests, failures, last seen]
        body.append(make("h3", null, `Users and devices (${v.length})`));
        miniTable(body, ["User", "Client", "Device type", "Device ID", "Servers", "Requests", "Failures", "Last seen"], v, { 5: "num", 6: "num", 7: "time" });
      } else if (c.kind === "steps" && c.name === "Transactions detail") {
        // [time, server, connector, status, mail from, recipients, response, message id, transcript, mechanism, result, last attempt, authenticated user, identity evidence]
        const total = r[col(set, "Transactions")];
        const authentication = set === "smtpclients";
        body.append(make("h3", null, `Transactions (${v.length}${total > v.length ? ` of ${number(total)}: ${set === "smtpdestinations" ? "deferrals and failures" : "refusals"} first, then the latest${served ? "" : "; the SmtpSessions CSV has them all"}` : ""})`));
        const table = make("table", "mini"), head = make("tr");
        const headers = ["Time", "Server", "Connector", "Status", "Mail from", "Recipients", "Response", "Message ID"];
        if (authentication) headers.push("Authentication mechanism", "Authentication result", "Last AUTH attempt", "Authenticated user", "Identity evidence");
        for (const h of headers) head.append(make("th", h === "Recipients" ? "num" : null, h));
        table.append(head);
        for (const s of v) {
          const row = make("tr");
          const cells = [stamp(s[0]), s[1], s[2], null, s[4], number(s[5]), s[6], s[7]];
          if (authentication) cells.push(s[9], s[10], s[11], s[12], s[13]);
          cells.forEach((x, j) => {
            const td = make("td", j === 5 ? "num nowrap" : j === 0 || j === 1 || j === 3 ? "nowrap" : null);
            if (j === 3) td.append(make("span", `pill ${tone(s[3])}`, s[3])); else td.textContent = x == null ? "" : x;
            row.append(td);
          });
          table.append(row);
          // The portal reads the transcript (and the response) of a transaction when its line is opened.
          if (s[8] || (served && s.transaction)) {
            const tr2 = make("tr"), td2 = make("td"); td2.colSpan = headers.length;
            const d = make("details"), pre = make("pre", null, s[8]); d.append(make("summary", null, "SMTP transcript"), pre); td2.append(d); tr2.append(td2); table.append(tr2);
            if (!s[8]) d.addEventListener("toggle", () => { if (d.open && !d.dataset.read) { d.dataset.read = "1"; portal.transcript(s, pre, row.children[6]); } });
          }
        }
        body.append(table);
      } else if (c.kind === "steps") {
        body.append(make("h3", null, c.name));
        miniTable(body, ["Protocol", "Requests", "Failed", "Last seen", "Servers"].slice(0, v[0].length), v, { 1: "num", 2: "num", 3: "time" });
      } else if (!c.grid && c.kind === "text") {
        body.append(make("h3", null, c.name), make("pre", null, v));
      }
    });
    // A user: the client sessions of this report (Detailed), each one opens its own detail.
    // In the portal, a user whose client sessions are not all in the page reads them from the server.
    if (set === "users" && meta.datasets.sessions && served && ready.sessions && !portal.whole("sessions")) body.append(...portal.userSessions(r[col(set, "User")]));
    else if (set === "users" && meta.datasets.sessions && !ready.sessions) body.append(make("h3", null, "Client sessions"), make("p", "muted", skipped.sessions ? "The client sessions are not loaded on this computer: open that tab and choose Load anyway." : "The client sessions are still loading: open this user again in a few seconds."));
    else if (set === "users" && meta.datasets.sessions) {
      const su = col("sessions", "User"), user = r[col(set, "User")];
      const sessions = data.sessions, list = sessions.rowsWhere(su, user).map(k => [sessions.row(k), k]);
      body.append(make("h3", null, `Client sessions (${list.length})`));
      if (list.length) {
        const table = make("table", "mini"), head = make("tr");
        for (const h of ["Start", "Duration", "Outcome", "Protocol", "Client", "Authentication", "Client IP", "Requests", "Failures", "Last error"]) head.append(make("th", h === "Requests" || h === "Failures" ? "num" : null, h));
        table.append(head);
        for (const [x, k] of list) {
          const row = make("tr"); row.style.cursor = "pointer"; row.title = "Open this session";
          for (const name of ["Start", "Duration", "Outcome", "Protocol", "Client", "Authentication", "Client IP", "Requests", "Failures", "Last error"]) {
            const cdef = meta.datasets.sessions.columns[col("sessions", name)], val = x[col("sessions", name)], td = make("td", cdef.kind === "num" ? "num nowrap" : name === "Last error" || name === "Client" ? null : "nowrap");
            if (name === "Outcome") td.append(make("span", `pill ${tone(val)}`, val)); else td.textContent = cellText(cdef, val);
            row.append(td);
          }
          row.addEventListener("click", () => { el("detail").close(); showDetails("sessions", k); });
          table.append(row);
        }
        body.append(table);
      }
    }
    if (set === "messages" && !meta.includeRouting) body.append(make("p", "muted", "The route was not included in this report (IncludeRoutingDetails is off)."));
    if (set === "sessions" && !(r[col(set, "Timeline")] || []).length) body.append(make("p", "muted", "No timeline step was kept for this session."));
  }
  // A placeholder row (still being read from the server) does not open.
  spacer.addEventListener("click", e => { const r = e.target.closest(".grid-row"); if (r && grid && !r.classList.contains("loading")) showDetails(grid.set, Number(r.dataset.row)); });
  spacer.addEventListener("keydown", e => { if (e.key === "Enter") { const r = e.target.closest(".grid-row"); if (r && grid && !r.classList.contains("loading")) showDetails(grid.set, Number(r.dataset.row)); } });
  el("detail-close").addEventListener("click", () => el("detail").close());

  // ---- Export of the current view -----------------------------------------------------------------
  el("export").addEventListener("click", () => {
    const esc = v => { v = v == null ? "" : String(v); if (/^[=+\-@\t\r]/.test(v)) v = "'" + v; return /[";\r\n]/.test(v) ? `"${v.replace(/"/g, '""')}"` : v; };
    if (!tab) return;
    // A list browsed on the server is exported by the server (the same columns and cells), every row of the selection with its filters.
    if (served && portal.remote(tab.name)) { portal.exportRemote(tab.name); return; }
    const table = data[tab.name], cols = tab.columns;
    const parts = ["\ufeff" + cols.map(c => esc(c.name)).join(";") + "\r\n"];
    let block = "";
    for (let k = 0; k < view.length; k++) {
      const i = view[k]; let line = "";
      for (let j = 0; j < cols.length; j++) { const c = cols[j], v = table.get(i, c.i); line += (j ? ";" : "") + esc(c.kind === "list" && v ? v.join("; ") : cellText(c, v)); }
      block += line + "\r\n";
      if ((k & 1023) === 1023) { parts.push(block); block = ""; }
    }
    parts.push(block);
    const a = document.createElement("a"); a.href = URL.createObjectURL(new Blob(parts, { type: "text/csv;charset=utf-8" }));
    a.download = `${tab.name}-view.csv`; document.body.append(a); a.click(); setTimeout(() => { URL.revokeObjectURL(a.href); a.remove(); }, 1000);
  });

  // ---- Footer ---------------------------------------------------------------------------------------
  const footer = el("footer");
  if (meta.notes.length) { footer.append(make("strong", null, "Notes")); const ul = make("ul"); for (const n of meta.notes) ul.append(make("li", null, n)); footer.append(ul); }
  footer.append(make("p", null, meta.edge
    ? `Times are shown in ${meta.timeZone}. Real mail flow only: SMTP connections without any message (load balancer and monitoring probes) and probe or system messages are removed before storage. This file contains e-mail addresses: store and share it accordingly. Generated ${meta.generated} by Exchange Log Report ${meta.toolVersion}.`
    : `Times are shown in ${meta.timeZone}. Real activity only: health mailboxes, system mailboxes, monitoring probes, anonymous authentication challenges and SMTP connections without any message are removed before storage. ${served ? "This page shows user names and e-mail addresses: share its exports accordingly. Read" : "This file contains user names and e-mail addresses: store and share it accordingly. Generated"} ${meta.generated} by Exchange Log Report ${meta.toolVersion}.`));

  // ---- Portal (served mode) -------------------------------------------------------------------------------
  // The same page, served by the portal of this computer (Serve): the description, the rows and the details come from its local read-only API
  // instead of the data files. The portal adds the day bar (the period, read day by day, newest first, with a server and a user filter), Stop
  // portal and the theme button. The token of the launch address is moved to the session storage of the tab and sent in the X-Portal-Token
  // header, never in an address. A period, server or user chosen in the day bar reloads the page with the new selection in its address. A list
  // (client sessions, failed and slow requests, messages) of at most clientRowsMax rows (report-meta) is loaded whole and works as in a static
  // report; a larger one is browsed on the server (RemoteTable): the same columns, filters, value lists and details, every row reachable.
  // Nothing here runs in a static report.
  function Portal() {
    const TOKEN = "exl-serve-token", THEME = "exl-serve-theme", HOUR = 3600000, DAY = 86400000;
    // The lists: keyset pages of 2,000 rows when loaded whole, pages of 500 ranks when browsed on the server (the first page of a list is one of them).
    const PAGE = 500, KEYSET_PAGE = 2000;
    // The longest selection, in days of the report time zone: the overview and the users of a period read every day of it.
    const MAX_DAYS = 31;
    const ISO = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,9}))?(Z|[+-]\d{2}:\d{2})$/;
    let token = "", info = null, clock = null, days = null, selection = null, report = null, stopped = false;
    const ids = {}, cut = {}, expected = {}, loads = new Set();
    let openKey = null;

    // ---- Time zone: the report time zone of the portal (report-meta timeZoneIana), else the zone of this browser.
    function zoneClock(name) {
      let format = null;
      if (name) try { format = new Intl.DateTimeFormat("en-US", { timeZone: name, hourCycle: "h23", year: "numeric", month: "numeric", day: "numeric", hour: "numeric", minute: "numeric", second: "numeric" }); } catch { format = null; }
      // Offset (ms added to UTC to read the wall clock) of each quarter of an hour: every change of offset happens on a quarter of an hour.
      const cache = new Map();
      const offset = ms => {
        const q = Math.floor(ms / 900000); let o = cache.get(q);
        if (o === undefined) {
          const at = q * 900000;
          if (format) { const p = {}; for (const x of format.formatToParts(new Date(at))) p[x.type] = Number(x.value); o = Date.UTC(p.year, p.month - 1, p.day, p.hour % 24, p.minute, p.second) - at; }
          else o = -new Date(at).getTimezoneOffset() * 60000;
          if (cache.size > 20000) cache.clear();
          cache.set(q, o);
        }
        return o;
      };
      // The instant of a wall-clock time (ms of Date.UTC of its fields): the first one when the clock is set back (the hour is repeated), the
      // one the clock would read with the offset of before when it moves forward (the hour does not exist), as Date does in the browser zone.
      const utc = w => {
        const a = w - offset(w - 2 * DAY), b = w - offset(w + 2 * DAY), okA = a + offset(a) === w, okB = b + offset(b) === w;
        if (okA && okB) return Math.min(a, b);
        return okB && !okA ? b : a;
      };
      return { name: format ? name : null, offset, wall: ms => ms + offset(ms), utc };
    }
    // Days of a time zone (the port of the day navigation of the portal): a day is [D 00:00, D+1 00:00) of the wall clock, 23 or 25 hours on
    // a daylight-saving change; a period is { from, to } in ms, end excluded.
    function Days(z) {
      const text = t => { const d = new Date(t); return `${d.getUTCFullYear()}-${pad(d.getUTCMonth() + 1)}-${pad(d.getUTCDate())}`; };
      const parse = key => { const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(key || ""); if (!m) throw new Error(`Invalid day: ${key}.`); return [+m[1], +m[2] - 1, +m[3]]; };
      const add = (key, n) => { const [y, mo, d] = parse(key); return text(Date.UTC(y, mo, d + n)); };
      const start = key => { const [y, mo, d] = parse(key); return z.utc(Date.UTC(y, mo, d)); };
      const key = ms => text(z.wall(ms));
      const of = ms => { const k = key(ms); return ms < start(k) ? add(k, -1) : ms >= start(add(k, 1)) ? add(k, 1) : k; };
      const dayPeriod = k => ({ from: start(k), to: start(add(k, 1)) });
      const slices = p => {
        if (!(p.from < p.to)) throw new Error("Choose a valid period with an end later than its start.");
        const out = [];
        for (let k = of(p.to - 1); ; k = add(k, -1)) {
          const s = start(k), e = start(add(k, 1));
          out.push({ day: k, from: Math.max(s, p.from), to: Math.min(e, p.to) });
          if (s <= p.from || out.length >= 400) return out;
        }
      };
      // Day-aligned bounds stay day-aligned (23 and 25 hour days included); other bounds move by n x 24 hours.
      const shift = (p, n) => { const move = v => { const k = of(v); return v === start(k) ? start(add(k, n)) : v + n * 24 * HOUR; }; return { from: move(p.from), to: move(p.to) }; };
      const ending = (end, n) => ({ from: start(add(end, 1 - n)), to: start(add(end, 1)) });
      const endDay = p => of(p.to - 1);
      const defaultPeriod = (coveredTo, now = Date.now()) => dayPeriod(of(Number.isFinite(coveredTo) ? coveredTo : now));
      const isDay = p => p.from === start(of(p.from)) && p.to === start(of(p.to));
      return { key, of, add, start, dayPeriod, slices, count: p => slices(p).length, shift, ending, endDay, defaultPeriod, isDay };
    }
    const isoMs = s => {
      const m = ISO.exec(s); if (!m) return null;
      let ms = Date.UTC(+m[1], +m[2] - 1, +m[3], +m[4], +m[5], +m[6], m[7] ? +(m[7] + "00").slice(0, 3) : 0);
      if (m[8] !== "Z") ms -= (m[8][0] === "-" ? -1 : 1) * (+m[8].slice(1, 3) * 60 + +m[8].slice(4, 6)) * 60000;
      return ms;
    };
    const iso = ms => new Date(ms).toISOString();
    const wallText = (ms, seconds) => { const d = new Date(clock.wall(ms)); return `${d.getUTCFullYear()}-${pad(d.getUTCMonth() + 1)}-${pad(d.getUTCDate())}T${pad(d.getUTCHours())}:${pad(d.getUTCMinutes())}${seconds ? `:${pad(d.getUTCSeconds())}` : ""}`; };
    const wallInput = v => { const m = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})$/.exec(v || ""); return m ? clock.utc(Date.UTC(+m[1], +m[2] - 1, +m[3], +m[4], +m[5])) : null; };
    // ISO times of the API as the page keeps times: wall-clock seconds of the report time zone. A step of a detail keeps its UTC instant in .utc.
    const toWall = v => { const ms = typeof v === "string" ? isoMs(v) : null; return ms == null ? v : clock.wall(ms) / 1000; };
    function adapt(kind, v) {
      if (v == null) return null;
      if (kind === "time") return toWall(v);
      if (kind === "steps" && Array.isArray(v)) return v.map(s => {
        if (!Array.isArray(s)) return s;
        const out = s.map(x => typeof x === "string" && ISO.test(x) ? toWall(x) : x), at = typeof s[0] === "string" ? isoMs(s[0]) : null;
        if (at != null) out.utc = at;
        return out;
      });
      return v;
    }

    // ---- Requests: the token in a header, a retry of what the server could not take now, a signal that cancels a superseded load.
    const failure = (message, status, code) => { const e = new Error(message); e.portal = true; e.status = status; e.code = code; return e; };
    const aborted = () => { const e = new Error("The request was cancelled by a newer one."); e.name = "AbortError"; return e; };
    const sleep = (ms, signal) => new Promise((resolve, reject) => {
      if (signal && signal.aborted) { reject(aborted()); return; }
      const stop = () => { clearTimeout(t); reject(aborted()); }, t = setTimeout(() => { if (signal) signal.removeEventListener("abort", stop); resolve(); }, ms);
      if (signal) signal.addEventListener("abort", stop, { once: true });
    });
    // Milliseconds before a request is sent again, or null: 429 (busy) and 503 (database busy, collection not reconciled yet) up to three times,
    // 504 (deadline) once; 503 and 504 only when the answer says retryable, after the retryAfterSeconds it gives.
    function retryDelay(status, error, after, attempt) {
      if (status === 429) return attempt < 3 ? Math.min(10, Math.max(1, Number(after) || 1)) * 1000 : null;
      if (status !== 503 && status !== 504) return null;
      if (attempt >= (status === 503 ? 3 : 1) || !error || error.retryable !== true) return null;
      const s = error.retryAfterSeconds;
      return typeof s === "number" && s >= 0 && s <= 60 ? s * 1000 : status === 504 ? 2000 : 1000;
    }
    // The request scheduler: the loading lanes run at most MAX_LANES background requests at once, so that one worker of the server (four by
    // default) stays free for what the user does (details, a step, the SMTP transactions of a client); an interactive request waits for none.
    // The value lists of the open list ("facets") take the slots that the loading lanes leave.
    const MAX_LANES = 3, waiting = [], deferred = [];
    let inFlight = 0, listing = 0;
    // The value lists take a slot when no loading request waits for one: one slot while the tables load, two once nothing else is in flight.
    const listingRoom = () => !waiting.length && inFlight < MAX_LANES && listing < (inFlight > listing ? 1 : 2);
    function slot(signal, low) {
      if (low ? listingRoom() : inFlight < MAX_LANES) { inFlight++; if (low) listing++; return Promise.resolve(); }
      return new Promise((resolve, reject) => {
        const queue = low ? deferred : waiting, entry = { resolve, signal, stop: null, low };
        if (signal) { entry.stop = () => { const k = queue.indexOf(entry); if (k >= 0) queue.splice(k, 1); reject(aborted()); }; signal.addEventListener("abort", entry.stop, { once: true }); }
        queue.push(entry);
      });
    }
    function grant(entry) {
      if (entry.signal) entry.signal.removeEventListener("abort", entry.stop);
      inFlight++; if (entry.low) listing++;
      entry.resolve();
    }
    function release(low) {
      inFlight--; if (low) listing--;
      if (waiting.length) grant(waiting.shift());
      while (deferred.length && listingRoom()) grant(deferred.shift());
    }
    async function schedule(kind, work, signal) {
      if (kind === "interactive") return work();
      if (signal && signal.aborted) throw aborted();
      const low = kind === "facets";
      await slot(signal, low);
      try { return await work(); } finally { release(low); }
    }
    // A request the server still turns away as busy after its retries says so in the words of the page.
    const errorText = (status, error) => status === 401 || status === 403
      ? "Access refused. Open the private launch address of the portal in this browser tab (Start-Portal opens it); never put its token in a ticket."
      : status === 429 ? "The server is busy with other requests: try again in a moment."
      : error && typeof error.message === "string" ? error.message : `Request failed (HTTP ${status}). Narrow the period or look at the Serve window.`;
    // A loading request (a lane, or the start of the page) or a patient one (the counts and the pages of a filter) that the server turns away
    // because its workers are busy waits for them, up to the aggregate deadline of the server: an aggregate holds its worker until it ends.
    // options.busy says so where the person is looking (the result line of a filter); by default the loading line.
    function patience() { return 1000 * (report && Number(report.aggregateTimeoutSeconds) > 0 ? Number(report.aggregateTimeoutSeconds) : 60); }
    function busyServer() {
      const text = "Waiting for the server: other requests are in progress...";
      if (!el("loading").hidden) el("loading-text").textContent = text; else el("progress-text").textContent = text;
    }
    async function request(path, params, options = {}) {
      if (stopped) throw failure("The portal is stopped.", 0);
      const query = params ? new URLSearchParams(Object.entries(params).filter(([, v]) => v != null && v !== "")).toString() : "";
      const began = performance.now();
      for (let attempt = 0; ; attempt++) {
        // A background request holds its lane slot while it is sent and read, not while it waits to be retried.
        const answer = await schedule(options.facets ? "facets" : options.lane ? "background" : "interactive", async () => {
          let response;
          const headers = options.body != null ? { "X-Portal-Token": token, "Content-Type": "application/json" } : { "X-Portal-Token": token };
          try { response = await fetch(path + (query ? `?${query}` : ""), { method: options.method || "GET", headers, body: options.body, cache: "no-store", credentials: "same-origin", signal: options.signal }); }
          catch (e) { if (e && e.name === "AbortError") throw e; throw failure("The portal does not answer: keep the Serve window open, then try again.", 0); }
          if (response.ok) return { ok: true, value: await response.json() };
          let body = null; try { body = await response.json(); } catch { body = null; }
          return { ok: false, response, body };
        }, options.signal);
        if (answer.ok) return answer.value;
        const { response, body } = answer;
        const error = body && body.error, after = response.headers.get("Retry-After");
        // options.busyMessage: a request that the server turns away as busy for a reason of its own is not retried and shows the server's words.
        const ownBusy = response.status === 429 && options.busyMessage && error && typeof error.message === "string";
        let delay = ownBusy ? null : retryDelay(response.status, error, after, attempt);
        if (delay == null && response.status === 429 && (options.lane || options.patient) && performance.now() - began < patience()) delay = Math.min(10, Math.max(1, Number(after) || 1)) * 1000;
        if (delay != null) { if (response.status === 429 && (options.lane || options.patient)) (options.busy || busyServer)(); await sleep(delay, options.signal); continue; }
        throw failure(ownBusy ? error.message : errorText(response.status, error), response.status, error && error.code);
      }
    }
    // The selection as API parameters (from, to, server, user).
    const params = (extra, noUser) => ({ from: iso(selection.from), to: iso(selection.to), server: selection.server, user: noUser ? null : selection.user, ...extra });

    // ---- The selection in the address: day=YYYY-MM-DD and days=n, or start and end (wall clock of the report time zone), server, user.
    function readSelection(p) {
      const covered = info.coveredTo ? Date.parse(info.coveredTo) : NaN;
      let period = null, preset = null;
      const s = wallInput(p.get("start")), e = wallInput(p.get("end"));
      if (s != null && e != null && s < e && days.count({ from: s, to: e }) <= MAX_DAYS) period = { from: s, to: e };
      else {
        const n = Number(p.get("days")), count = Number.isInteger(n) && n >= 1 && n <= MAX_DAYS ? n : 1;
        let end = p.get("day");
        try { days.start(end); } catch { end = days.endDay(days.defaultPeriod(covered)); }
        period = days.ending(end, count); preset = count;
      }
      const servers = info.servers || [], wanted = p.get("server"), server = wanted ? servers.find(x => x.toLowerCase() === wanted.toLowerCase()) || null : null;
      const user = (p.get("user") || "").trim().slice(0, 256) || null;
      return { ...period, preset, server, user };
    }
    function writeSelection(p, next) {
      for (const k of ["day", "days", "start", "end", "server", "user"]) p.delete(k);
      if (next.preset) { p.set("day", days.endDay(next)); p.set("days", String(next.preset)); }
      else { p.set("start", wallText(next.from)); p.set("end", wallText(next.to)); }
      if (next.server) p.set("server", next.server);
      if (next.user) p.set("user", next.user);
    }
    // A new selection reloads the page: the tab and the filters of the address are kept, an open detail is not.
    function go(next) {
      const p = new URLSearchParams(location.hash.replace(/^#/, ""));
      writeSelection(p, next); p.delete("open");
      try { history.replaceState(null, "", `#${p}`); } catch { location.hash = p.toString(); }
      for (const c of loads) c.abort();
      location.reload();
    }
    const sameSelection = p => { const x = readSelection(p); return x.from === selection.from && x.to === selection.to && x.server === selection.server && x.user === selection.user; };

    // ---- Start: token, database, selection, report description and the counts of the lists.
    function halt(message) {
      el("loading-text").textContent = message; el("loading-fill").style.width = "0";
      el("loading").querySelector(".label").textContent = "Portal";
      return null;
    }
    async function start() {
      try { const theme = sessionStorage.getItem(THEME); if (theme === "dark" || theme === "light") document.documentElement.setAttribute("data-theme", theme); } catch { }
      const hash = new URLSearchParams(location.hash.replace(/^#/, ""));
      if (hash.has("token")) {
        token = hash.get("token") || ""; hash.delete("token");
        try { sessionStorage.setItem(TOKEN, token); } catch { }
        history.replaceState(history.state, "", location.pathname + location.search + (hash.toString() ? `#${hash}` : ""));
      } else try { token = sessionStorage.getItem(TOKEN) || ""; } catch { token = ""; }
      window.__exlPortal = { days: name => Days(zoneClock(name)), retryDelay };
      if (!token) return halt("Open the private launch address of the portal in this browser tab: Start-Portal opens it, and it is valid until the portal stops.");
      el("loading-text").textContent = "Reading the database...";
      try { info = await request("/api/meta", null, { patient: true }); } catch (e) { return halt(e.message); }
      if (info.requiresMigration) return halt(info.schemaVersion
        ? `This database has schema ${info.schemaVersion}; the portal reads schema ${info.supportedSchemaVersion} and never migrates a database. Run one collection (Run-Collector.cmd) or migrate a copy (Database-Storage.cmd --storage-copy --migrate).`
        : "No Exchange Log Report database was found at the path of the portal: run a collection first, or start the portal with -DatabasePath.");
      clock = zoneClock(info.timeZoneIana); days = Days(clock);
      selection = readSelection(hash);
      anyCasePending = hash.get("anyCase") === "1";
      el("loading-text").textContent = "Reading the description of the selection...";
      try { report = await request("/api/report-meta", params(), { patient: true }); }
      catch (e) { return halt(e.message); }
      return describe(report);
    }
    // The description of a static report, built from report-meta: the same datasets and columns (the SMTP transactions have no tab: an SMTP
    // client lists its own), one pack per period dataset and per (list, day). Row counts: users and operations from report-meta; the lists are
    // counted day by day when they load (/count); the other counts are known when their rows are in.
    function describe(rm) {
      const datasets = {}, files = [];
      for (const [name, d] of Object.entries(rm.datasets)) {
        if (name === "smtp") continue;
        const columns = d.columns.map(c => ({ name: c.name, kind: c.kind, grid: c.grid }));
        if (name === "smtpclients") columns.push({ name: "Transactions detail", kind: "steps", grid: false });
        const count = d.rows != null ? d.rows : null;
        expected[name] = count;
        // rows: what the table is sized for while it loads (1 when the count comes with the rows), total: what the tab shows.
        datasets[name] = { rows: count == null ? 1 : Math.min(count, rm.clientRowsMax), total: count, columns,
          detailColumns: columns.map((c, i) => c.kind === "steps" ? i : -1).filter(i => i >= 0), served: { list: d.list, detail: d.detail, listColumns: d.listColumns, daySliced: d.daySliced } };
        if (count === 0) datasets[name].rows = 0;
      }
      for (const f of rm.data.files) if (datasets[f.set]) files.push({ name: f.name, kind: "c", set: f.set, day: f.day || null, url: f.url,
        orderFrom: f.orderFrom ? Date.parse(f.orderFrom) : null, orderTo: f.orderTo ? Date.parse(f.orderTo) : null });
      return { served: true, title: rm.title, toolVersion: rm.toolVersion, generated: rm.generated, timeZone: rm.timeZone, periodStart: rm.periodStart, periodEnd: rm.periodEnd,
        detailed: true, edge: false, includeRouting: rm.includeRouting, includeSessions: rm.includeSessions, slowRequestMs: rm.slowRequestMs, users: rm.users, servers: rm.servers,
        configuredServers: rm.configuredServers, notes: rm.notes, clientRowsMax: rm.clientRowsMax, datasets, data: { id: "", folder: null, files } };
    }

    // ---- Day bar (above the overview and the tabs), hero buttons, footer.
    function controls() {
      el("loading").hidden = true; progress.hidden = false;
      for (const id of ["metric-servers", "metric-users", "metric-requests", "metric-messages", "metric-auth"]) if (el(id)) el(id).textContent = "...";
      el("servers-caption").textContent = `${el("servers-caption").textContent} Reading the overview of the selection...`;
      el("subtitle").textContent += " Portal: read-only, on this computer, from the database of the collection; choose the days above the overview.";
      // Hero: theme and Stop portal.
      const actions = make("div", "hero-actions"), theme = make("button", null, ""), stop = make("button", null, "Stop portal");
      theme.type = "button"; stop.type = "button"; theme.id = "portal-theme"; stop.id = "portal-stop";
      const themeText = () => { theme.textContent = document.documentElement.getAttribute("data-theme") === "dark" ? "Light theme" : "Dark theme"; };
      theme.addEventListener("click", () => {
        const next = document.documentElement.getAttribute("data-theme") === "dark" ? "light" : "dark";
        document.documentElement.setAttribute("data-theme", next); themeText();
        try { sessionStorage.setItem(THEME, next); } catch { }
      });
      stop.addEventListener("click", () => stopPortal(stop));
      themeText(); actions.append(theme, stop); el("range").parentNode.append(actions);

      // Day bar: presets keep the end day, Previous / Next day move the period by one day, Jump to day keeps its length, From / To set any
      // period; the server and the user filter the rows the server sends. Apply reads the selection.
      const bar = make("section", "block day-bar"); bar.id = "day-bar";
      const head = make("div", "day-row"), label = make("span", "label", "Days");
      const button = (text, title, action) => { const b = make("button", null, text); b.type = "button"; if (title) b.title = title; b.addEventListener("click", action); return b; };
      const n = days.count(selection), end = days.endDay(selection);
      const presets = make("div", "day-presets");
      for (const k of [1, 3, 7]) {
        const b = button(k === 1 ? "1 day" : `${k} days`, `${k === 1 ? "The day" : `${k} days`} ending ${end}`, () => go({ ...days.ending(end, k), preset: k, server: selection.server, user: selection.user }));
        if (selection.preset === k) b.classList.add("active");
        presets.append(b);
      }
      const prev = button("Previous day", "The same period, one day earlier", () => go({ ...days.shift(selection, -1), preset: selection.preset, server: selection.server, user: selection.user }));
      const next = button("Next day", "The same period, one day later", () => go({ ...days.shift(selection, 1), preset: selection.preset, server: selection.server, user: selection.user }));
      const jumpLabel = make("label", null, "Jump to day"), jump = make("input"); jump.type = "date"; jump.value = end; jump.id = "day-jump";
      jump.title = "The period keeps its length and ends with this day";
      jump.addEventListener("change", () => { try { days.start(jump.value); } catch { return; } go({ ...days.ending(jump.value, selection.preset || n), preset: selection.preset || n, server: selection.server, user: selection.user }); });
      jumpLabel.append(jump);
      const fromLabel = make("label", null, "From"), toLabel = make("label", null, "To"), from = make("input"), to = make("input");
      from.type = to.type = "datetime-local"; from.id = "day-from"; to.id = "day-to"; from.value = wallText(selection.from); to.value = wallText(selection.to);
      from.title = to.title = `Wall clock of ${report.timeZone}; end excluded`;
      fromLabel.append(from); toLabel.append(to);
      const serverLabel = make("label", null, "Server"), server = make("select"); server.id = "day-server";
      server.append(new Option("All servers", ""));
      for (const s of info.servers || []) server.append(new Option(s, s, false, s === selection.server));
      serverLabel.append(server);
      const userLabel = make("label", null, "User"), user = make("input"); user.type = "search"; user.id = "day-user"; user.placeholder = "contains"; user.value = selection.user || "";
      user.title = "Rows of the users whose name or mailbox contains this text (read on the server)";
      userLabel.append(user);
      const apply = button("Apply", "Read this period with this server and user", () => {
        const f = wallInput(from.value), t = wallInput(to.value);
        if (f == null || t == null || f >= t) { from.classList.toggle("invalid", f == null || (t != null && f >= t)); to.classList.toggle("invalid", t == null); return; }
        const whole = { from: f, to: t }, n = days.count(whole);
        if (n > MAX_DAYS) {
          from.classList.add("invalid"); to.classList.remove("invalid");
          notice(`Choose at most ${MAX_DAYS} days: this period has ${number(n)}.`);
          return;
        }
        go({ ...whole, preset: days.isDay(whole) ? n : null, server: server.value || null, user: user.value.trim() || null });
      });
      apply.classList.add("primary-button"); apply.id = "day-apply";
      user.addEventListener("keydown", e => { if (e.key === "Enter") apply.click(); });
      head.append(label, presets, prev, next, jumpLabel, fromLabel, toLabel, serverLabel, userLabel, apply);
      // A day of the period: reads that day alone; on a table browsed on the server, scrolls to the first row of that day (the rows of the newer
      // days come before it) and shows the rows of that day. The title says which (dayCounts).
      const list = make("div", "day-list");
      for (const s of days.slices(selection)) {
        const chip = button(s.day, `Read ${s.day} alone`, () => {
          if (tab && remote(tab.name) && data[tab.name].scrollToDay(s.day)) return;
          go({ ...days.dayPeriod(s.day), preset: 1, server: selection.server, user: selection.user });
        });
        chip.classList.add("day-chip"); chip.dataset.day = s.day; chip.append(make("span", "n")); list.append(chip);
      }
      const caption = make("p", "caption day-caption"); caption.id = "day-caption";
      const mib = info.databaseBytes ? `${number(Math.max(1, Math.round(info.databaseBytes / 1048576)))} MiB` : "";
      caption.textContent = `${n === 1 ? `Day ${end}` : `${number(n)} days, ${days.slices(selection).slice(-1)[0].day} to ${end}`} (${report.timeZone}, end excluded)` +
        `${selection.server ? `, server ${selection.server}` : ""}${selection.user ? `, users containing "${selection.user}"` : ""}. ` +
        `Newest collected data: ${info.coveredTo ? wallText(Date.parse(info.coveredTo)).replace("T", " ") : "none"}. Database ${mib}, schema ${info.schemaVersion}, read-only.`;
      bar.append(head, list, caption);
      document.querySelector("header").after(bar);
      el("detail").addEventListener("close", () => { if (openKey) { openKey = null; hashLater(); } });
    }
    const tabTitle = set => { const t = tabs.find(x => x.name === set); return t ? t.title : set; };
    async function stopPortal(button) {
      button.disabled = true;
      try { await request("/api/shutdown", null, { method: "POST" }); }
      catch (e) { button.disabled = false; notice(e.message); return; }
      stopped = true;
      for (const c of loads) c.abort();
      try { sessionStorage.removeItem(TOKEN); } catch { }
      for (const x of el("day-bar").querySelectorAll("input, select, button")) x.disabled = true;
      button.textContent = "Portal stopped";
      notice("The portal is stopped. You can close this tab; Start-Portal opens a new one.");
    }
    function notice(text) {
      let box = el("portal-notice");
      if (!box) { box = make("div", "notice"); box.id = "portal-notice"; box.setAttribute("role", "status"); el("day-bar").append(box); }
      box.textContent = text;
    }

    // ---- Loading: every table of the selection, in three lanes (the overview; the period tables; the lists, the open tab first), through the
    // request scheduler: a slow overview delays neither the users and operations nor the lists.
    const progressState = {};
    function progressText(set) {
      const s = progressState[set] || {}, t = data[set], n = Array.isArray(t) ? t.length : t ? t.len : 0, of = expected[set];
      const part = s.days > 1 ? ` (day ${Math.min(s.day + 1, s.days)} of ${s.days})` : "";
      return `Loading ${tabTitle(set).toLowerCase()}: ${number(n)}${of != null ? ` of ${number(of)}` : ""} rows${part}`;
    }
    function showLoading(set) {
      const sets = Object.keys(meta.datasets), done = sets.filter(x => ready[x] || skipped[x]).length;
      progressText.last = performance.now();
      el("progress-text").textContent = progressText(set);
      el("progress-fill").style.width = `${sets.length ? done / sets.length * 100 : 100}%`;
    }
    // The list columns of a dataset in the order of its report columns: a column the list does not carry is empty until the row is opened.
    function converter(set) {
      const def = meta.datasets[set], list = def.served.listColumns, at = def.columns.map(c => list.indexOf(c.name)), kinds = def.columns.map(c => c.kind);
      return cells => { const row = new Array(at.length); for (let k = 0; k < at.length; k++) { const j = at[k]; row[k] = j < 0 ? null : adapt(kinds[k], cells[j]); } return row; };
    }
    function grow(set, need) {
      const t = data[set]; if (t.len + need <= t.n) return t;
      const def = meta.datasets[set], next = new Table(def, Math.max(t.n * 2, t.len + need, 1024));
      for (let i = 0; i < t.len; i += 2000) { const rows = []; for (let j = i; j < Math.min(t.len, i + 2000); j++) rows.push(t.row(j)); next.append(rows); }
      data[set] = next; def.rows = next.n;
      if (grid && grid.preview && grid.set === set) previewIds = null;
      return next;
    }
    async function loadSets(order) {
      // The lists lane first reads the first page and the counts of every list (the open tab first), then the lists loaded whole: the first rows
      // of a list never wait behind the whole load of another one.
      const lane = async sets => {
        const rest = [];
        for (const set of sets) {
          if (ready[set] || skipped[set]) continue;
          if (!allowed(set)) { skipSet(set); continue; }
          const more = await loadSet(set);
          if (typeof more === "function") rest.push(more);
        }
        for (const more of rest) await more();
      };
      const OVERVIEW = new Set(["servers", "daily"]);
      const lanes = [lane(order.filter(s => OVERVIEW.has(s))), lane(order.filter(s => !OVERVIEW.has(s) && !HEAVY.has(s))), lane(order.filter(s => HEAVY.has(s)))];
      try { await Promise.all(lanes); }
      catch (error) { for (const c of loads) c.abort(); await Promise.allSettled(lanes); throw error; }
    }
    // Adds the rows of a page to the table of set (grown as needed); false once it holds limit rows (state.full).
    function appender(set, convert, limit, state) {
      let slice = performance.now();
      return async rows => {
        if (!rows.length) return true;
        const room = limit - data[set].len, take = rows.length > room ? rows.slice(0, room) : rows;
        const table = grow(set, take.length), at = performance.now();
        table.append(take.map(r => convert(r.cells))); for (const r of take) ids[set].push(r.id);
        timing.appendMs[set] = (timing.appendMs[set] || 0) + performance.now() - at;
        if (performance.now() - (progressText.last || 0) > 100) showLoading(set);
        if (!tab && set === previewSet()) {
          if (!grid) showPreview(set);
          else if (grid.preview && grid.set === set && performance.now() - previewAt > 500) refreshPreview();
        }
        if (performance.now() - slice > 30) { await yieldNow(); slice = performance.now(); }
        if (take.length < rows.length || data[set].len >= limit) { state.full = true; return false; }
        return true;
      };
    }
    // The table of set sized to its rows and finished (a table without rows is finished when it is made).
    function shrink(set) {
      const def = meta.datasets[set];
      let table = data[set];
      if (table.len < table.n) { const t = new Table(def, table.len); for (let i = 0; i < table.len; i += 2000) { const rows = []; for (let j = i; j < Math.min(table.len, i + 2000); j++) rows.push(table.row(j)); t.append(rows); } data[set] = table = t; }
      if (table.n) table.finish();
      def.rows = table.len;
      return table;
    }
    // The rows of a dataset; a list loaded whole returns the load of its other rows, run by its lane once the first page of every list is in.
    async function loadSet(set) {
      const def = meta.datasets[set], control = new AbortController();
      loads.add(control);
      let kept = false;
      try {
        endPreview(set);
        if (set === "servers" || set === "daily") return await loadOverview(control.signal);
        if (LISTS.has(set)) {
          const rest = await loadList(set, control.signal);
          if (!rest) return;
          kept = true;
          return async () => { try { await rest(); } finally { loads.delete(control); } };
        }
        const limit = report.clientRowsMax, packs = dataInfo.files.filter(f => f.set === set), state = { full: false };
        ids[set] = []; delete cut[set];
        data[set] = new Table(def, Math.max(1, Math.min(expected[set] != null ? expected[set] : 4096, limit)));
        progressState[set] = { day: 0, days: packs.length };
        const emit = appender(set, converter(set), limit, state);
        for (let k = 0; k < packs.length && !state.full; k++) { progressState[set].day = k; await getFile(packs[k], emit, control.signal); }
        if (state.full) cut[set] = { reason: "max" };
        const table = shrink(set);
        if (def.total == null || (!cut[set] && def.total !== table.len)) def.total = cut[set] ? null : table.len;
        if (grid && grid.preview && grid.set === set) previewIds = null;
        ready[set] = true; timing.ready[set] = performance.now();
        showLoading(set);
        datasetReady(set);
      } finally { if (!kept) loads.delete(control); }
    }
    // The overview: servers and daily, from one request over the whole selection.
    async function loadOverview(signal) {
      const o = await request("/api/overview/servers", params(), { signal, lane: true });
      for (const [set, part] of [["servers", o.servers], ["daily", o.daily]]) {
        const def = meta.datasets[set], kinds = def.columns.map(c => c.kind), at = def.columns.map(c => part.columns.findIndex(x => x.name === c.name));
        data[set] = part.rows.map(r => at.map((j, k) => j < 0 ? null : adapt(kinds[k], r.cells[j])));
        def.rows = def.total = data[set].length;
      }
      el("servers-caption").textContent = el("servers-caption").textContent.replace(" Reading the overview of the selection...", "");
      for (const set of ["servers", "daily"]) { ready[set] = true; timing.ready[set] = performance.now(); }
      datasetReady("servers"); datasetReady("daily");
    }
    // The rows of a period list (users and operations whole, the SMTP clients in one page of at most clientRowsMax groups: the server groups the
    // whole selection for any page), given to emit.
    async function getFile(f, emit, signal) {
      const url = f.url.split("?"), path = url[0], base = Object.fromEntries(new URLSearchParams(url[1] || ""));
      const r = await request(path, f.set === "smtpclients" ? { ...base, page: 1, size: report.clientRowsMax } : base, { signal, lane: true });
      await emit(r.rows);
    }

    // ---- The lists of the selection (client sessions, failed and slow requests, messages). For every list, whatever it becomes: the first page of
    // the newest day at once (drawn while the rest loads), then the exact count of each day (/count, with its 15-minute histogram). A list of at
    // most rowsMax rows is then loaded whole (keyset pages, newest day first) and its tab works as in a static report ("Loaded"); a larger one is
    // browsed on the server ("Remote"): the first page is already its first page, the scrollbar takes the exact total.
    const LISTS = new Set(["sessions", "issues", "messages"]), KEY = { sessions: "Start", issues: "Time", messages: "Last event" };
    const mode = {}, whole = {}, remoteBase = {}, chips = {}, listDays = {}, facetState = {};
    const remote = set => mode[set] === "remote";
    const dayWindow = d => ({ orderFrom: d.lo == null ? null : iso(d.lo), orderTo: d.hi == null ? null : iso(d.hi) });
    const packDays = set => dataInfo.files.filter(f => f.set === set).map(f => ({ day: f.day, lo: f.orderFrom, hi: f.orderTo, total: null, buckets: [], partial: false }));
    const keyIndex = set => meta.datasets[set].columns.findIndex(c => c.name === KEY[set]);
    // The largest list loaded whole: clientRowsMax, and what the memory guard of the page leaves for it (estimate() of a list row).
    function rowsMax(set) {
      const d = meta.datasets[set]; let per = 8;
      for (const c of d.columns) per += c.kind === "num" || c.kind === "time" ? 8 : c.kind === "text" ? 6 : c.kind === "list" ? 16 : 0;
      return Math.max(0, Math.min(report.clientRowsMax, Math.floor((guardLimit - estimated - 12 * 1048576) / ((per + 40) * 1.3))));
    }
    // The exact count of day d of set with the filters of query (the list parameters f., m., x., q), and its histogram [key, rows, width]: a scan
    // answers what it counted within its budget and is asked again from where it stopped. options: dir, bucketMs, signal, lane, patient, busy.
    async function countDay(set, d, query, options = {}) {
      const path = `${meta.datasets[set].served.list}/count`, buckets = new Map();
      let total = 0, cursor = null;
      d.requests = 0; d.exactMiss = false;
      for (;;) {
        const r = await request(path, { ...params(), ...query, ...dayWindow(d), cursor, dir: options.dir === "asc" ? "asc" : null, bucketMs: options.bucketMs },
          { signal: options.signal, lane: options.lane, patient: options.patient, busy: options.busy });
        d.requests++;
        if (r.exactMiss) d.exactMiss = true;
        for (const [k, n] of r.buckets) buckets.set(k, (buckets.get(k) || 0) + n);
        total += r.total;
        d.total = total; d.partial = !r.complete;
        d.buckets = Array.from(buckets, ([k, n]) => [k, n, options.bucketMs || 900000]).sort((a, b) => a[0] - b[0]);
        if (r.complete) return d;
        cursor = r.scannedTo;
        if (options.progress) options.progress(d);
      }
    }
    // Runs work(item) for every item, at most n at once, in the order of the items; the first error ends the others' next items and is thrown.
    async function pool(items, n, work) {
      let next = 0, failed = false;
      const run = async () => {
        while (!failed && next < items.length) { const item = items[next++]; try { await work(item); } catch (e) { failed = true; throw e; } }
      };
      await Promise.all(Array.from({ length: Math.min(n, items.length) }, run));
    }
    // The rows of days of a list with the filters of query, read whole (keyset pages of KEYSET_PAGE rows, two days at a time, in the order of the
    // days): one array of rows per day.
    async function dayRows(set, days, query, signal) {
      const path = meta.datasets[set].served.list, parts = days.map(() => []);
      await pool(days.map((d, k) => k), 2, async k => {
        let cursor = null;
        for (;;) {
          const r = await request(path, { ...params(), ...query, ...dayWindow(days[k]), size: KEYSET_PAGE, cursor }, { signal, patient: true });
          for (const x of r.rows) parts[k].push(x);
          if (r.exhausted || !r.nextCursor) break;
          cursor = r.nextCursor;
        }
      });
      return parts;
    }
    // The count of each day on the tab and on the day bar (with a "+" while some day is still being counted).
    function showCount(set, days) {
      const t = tabs.find(x => x.name === set); if (!t) return;
      const sum = days.reduce((a, d) => a + (d.total || 0), 0), done = days.every(d => d.total != null && !d.partial), count = t.button.querySelector(".count");
      if (count) count.textContent = done ? number(sum) : `${number(sum)}+`;
      if (tab && tab.name === set) dayCounts(set);
    }
    // The rows of each day of the open list on the day bar; the day being counted is marked.
    function dayCounts(set) {
      const table = set ? data[set] : null, days = table && table.remote ? table.days : set ? listDays[set] : null;
      for (const chip of document.querySelectorAll("#day-bar .day-chip")) {
        const d = days ? days.find(x => x.day === chip.dataset.day) : null, n = chip.querySelector(".n");
        if (n) n.textContent = d && d.total != null ? number(d.total) : "";
        chip.classList.toggle("counting", !!d && (d.total == null || d.partial));
        if (!table || !table.remote) chip.classList.remove("current");
        chip.title = table && table.remote ? `Scroll to ${chip.dataset.day}` : `Read ${chip.dataset.day} alone`;
      }
    }
    async function loadList(set, signal) {
      const def = meta.datasets[set], path = def.served.list, days = listDays[set] = packDays(set), state = { full: false };
      ids[set] = []; delete cut[set]; whole[set] = false; delete chips[set];
      data[set] = new Table(def, 1024); def.rows = data[set].n;
      progressState[set] = { day: 0, days: days.length };
      const emit = appender(set, converter(set), Infinity, state);
      const first = request(path, { ...params(), ...dayWindow(days[0]), size: PAGE }, { signal, lane: true });
      const counts = Promise.all(days.map(d => countDay(set, d, {}, { signal, lane: true }).then(() => showCount(set, days))));
      counts.catch(() => { });
      const page = await first;
      await emit(page.rows);
      await counts;
      const total = days.reduce((a, d) => a + d.total, 0);
      def.total = expected[set] = total;
      const done = () => {
        if (grid && grid.preview && grid.set === set) previewIds = null;
        ready[set] = true; timing.ready[set] = performance.now();
        showLoading(set);
        datasetReady(set);
      };
      if (total > rowsMax(set)) {
        mode[set] = "remote";
        data[set] = remoteBase[set] = new RemoteTable(set, days, {}, "desc", page.rows);
        def.rows = def.total;
        done();
        return null;
      }
      // Loaded whole: its memory is counted at once (the next list decides with it); the rest of its rows, the rest of the newest day and then the
      // older days, is read by the lane once every list has its first page.
      const reserved = estimate(set, total);
      estimated += reserved;
      return async () => {
        for (let k = 0; k < days.length; k++) {
          progressState[set].day = k;
          let cursor = k === 0 ? page.nextCursor : null;
          if (k === 0 && (page.exhausted || !cursor)) continue;
          for (;;) {
            const r = await request(path, { ...params(), ...dayWindow(days[k]), size: KEYSET_PAGE, cursor }, { signal, lane: true });
            await emit(r.rows);
            if (r.exhausted || !r.nextCursor) break;
            cursor = r.nextCursor;
          }
        }
        const table = shrink(set);
        // The rows are the selection: a count read before a collection committed more is replaced by the rows read.
        def.total = table.len;
        estimated += estimate(set) - reserved;
        mode[set] = "client"; whole[set] = true;
        done();
      };
    }

    // ---- A list browsed on the server: the ranks of the selection in the list order (newest first, or oldest first with dir asc) over the days of
    // the period with their exact counts and histograms, and a cache of pages of PAGE ranks read when they are drawn. A rank is found in its day
    // (cumulative counts), its bucket and an offset in the bucket (skip, at most 10,000: a fuller bucket is counted again per minute, then per
    // second); the request reads the window from the bucket to the far end of the day, so a page may run over several buckets.
    const PAGES = 64;
    class RemoteTable {
      constructor(set, days, query, dir, firstRows) {
        this.remote = true; this.set = set; this.def = meta.datasets[set]; this.convert = converter(set); this.cols = this.def.columns.map(() => null);
        this.days = days; this.query = query; this.key = JSON.stringify(query); this.dir = dir; this.complete = days.every(d => d.total != null && !d.partial);
        this.pages = new Map(); this.reading = new Map(); this.counting = false; this.stopped = false;
        // A filtered list may be scanned by the server: its page reads run two at a time (turn) and are not cancelled once sent.
        this.filtered = Object.keys(query).length > 0; this.queue = []; this.active = 0; this.gen = 0;
        this.layout();
        if (firstRows && dir === "desc" && days.length && days[0].total) this.put(days[0], 0, firstRows.slice(0, Math.min(PAGE, days[0].total)));
      }
      ordered() { return this.dir === "asc" ? this.days.slice().reverse() : this.days; }
      // safe: the ranks of the leading days counted to their end, which a count still running does not move.
      layout() {
        let at = 0, safe = null;
        for (const d of this.ordered()) { d.first = at; if (safe == null && (d.total == null || d.partial)) safe = at; at += d.total || 0; }
        this.len = at; this.safe = safe == null ? at : safe;
      }
      setDir(dir) {
        if (dir === this.dir) return;
        this.dir = dir; this.pages.clear(); this.gen++;
        for (const r of this.reading.values()) if (!this.filtered || !r.sent) r.control.abort();
        this.reading.clear(); this.layout();
      }
      locate(i) {
        const list = this.ordered(); let lo = 0, hi = list.length - 1;
        while (lo < hi) { const m = (lo + hi + 1) >> 1; if (list[m].first <= i) lo = m; else hi = m - 1; }
        const d = list[lo], o = i - d.first;
        return { d, page: Math.floor(o / PAGE), at: o % PAGE };
      }
      put(d, page, rows) {
        const key = `${d.day}:${page}`;
        this.pages.delete(key); this.pages.set(key, { rows: rows.map(r => this.convert(r.cells)), ids: rows.map(r => r.id) });
        while (this.pages.size > PAGES) this.pages.delete(this.pages.keys().next().value);
      }
      cached(i) {
        if (!(i >= 0 && i < this.len)) return null;
        const { d, page, at } = this.locate(i), p = this.pages.get(`${d.day}:${page}`);
        return p && at < p.rows.length ? { p, at } : null;
      }
      has(i) { return !!this.cached(i); }
      get(i, k) { const c = this.cached(i); return c ? c.p.rows[c.at][k] : undefined; }
      row(i) { const c = this.cached(i); return c ? c.p.rows[c.at] : undefined; }
      idOf(i) { const c = this.cached(i); return c ? c.p.ids[c.at] : undefined; }
      finish() { }
      dropLowered() { }
      // Reads the pages of ranks [a, b) that are not cached, and the page after them; done() once the missing pages of [a, b) are in. A read whose
      // page left the window by more than two pages is cancelled; on a filtered list only while it waits for its turn (a page the server is
      // scanning costs it the same whether it is read to its end or not: it is kept).
      ensure(a, b, done) {
        if (this.counting) b = Math.min(b, this.safe);
        if (!this.len || a >= b) return;
        const want = new Map(), add = i => { if (i < 0 || i >= this.len) return; const { d, page } = this.locate(i), key = `${d.day}:${page}`; if (!want.has(key)) want.set(key, { d, page, key }); };
        for (let i = a; i < b; i += PAGE) add(i);
        add(b - 1);
        const visible = new Set(want.keys());
        add(b + PAGE - 1);
        for (const [key, r] of this.reading) if (!want.has(key) && Math.abs(r.rank - a) > 3 * PAGE && (!this.filtered || !r.sent)) { r.control.abort(); this.reading.delete(key); }
        const missing = [];
        for (const w of want.values()) if (!this.pages.has(w.key)) { const p = this.fetch(w); if (visible.has(w.key)) missing.push(p); }
        if (missing.length) Promise.all(missing).then(() => { if (done) done(); }, e => { if (e && e.name !== "AbortError") el("result-state").textContent = e.message; });
      }
      fetch(w) {
        let r = this.reading.get(w.key);
        if (r) return r.promise;
        const control = new AbortController(), gen = this.gen;
        r = { control, rank: w.d.first + w.page * PAGE, sent: false };
        r.promise = this.turn(r).then(() => this.read(w.d, w.page, control.signal)).then(rows => { if (gen === this.gen) this.put(w.d, w.page, rows); })
          .finally(() => { this.done(r); if (this.reading.get(w.key) === r) this.reading.delete(w.key); });
        r.promise.catch(() => { });
        this.reading.set(w.key, r);
        return r.promise;
      }
      // The page of rank i, read again when it left the cache.
      need(i) {
        if (this.has(i) || !(i >= 0 && i < this.len)) return Promise.resolve();
        const { d, page } = this.locate(i);
        return this.fetch({ d, page, key: `${d.day}:${page}` });
      }
      // The reads of a filtered list run two at a time, in the order they were asked; a read of the whole list is sent at once.
      turn(r) {
        if (!this.filtered || this.active < 2) { this.active++; r.sent = true; return Promise.resolve(); }
        return new Promise((resolve, reject) => {
          const drop = () => { const k = this.queue.indexOf(r); if (k >= 0) this.queue.splice(k, 1); reject(aborted()); };
          r.start = () => { r.control.signal.removeEventListener("abort", drop); this.active++; r.sent = true; resolve(); };
          r.control.signal.addEventListener("abort", drop, { once: true });
          this.queue.push(r);
        });
      }
      done(r) {
        if (!r.sent) return;
        this.active--;
        const next = this.queue.shift();
        if (next) next.start();
      }
      // The bucket of the rank start of day d in the list order and the rows of the day before it in that bucket.
      async bucketOf(d, start, signal) {
        for (;;) {
          const list = this.dir === "asc" ? d.buckets : d.buckets.slice().reverse();
          let cum = 0, at = -1;
          for (let j = 0; j < list.length; j++) { if (start < cum + list[j][1]) { at = j; break; } cum += list[j][1]; }
          if (at < 0) throw failure("The rows of this part of the list could not be found again: reload the page.", 0);
          const b = list[at], skip = start - cum;
          if (skip <= 10000) return { bucket: b, skip };
          if (b[2] <= 1000) throw failure("More than 10,000 rows of this list share one second: narrow the selection with a filter to browse them.", 0);
          const width = Math.max(1000, Math.round(b[2] / 15 / 1000) * 1000), part = { day: d.day, lo: Math.max(b[0], d.lo == null ? b[0] : d.lo), hi: d.hi == null ? b[0] + b[2] : Math.min(d.hi, b[0] + b[2]) };
          await countDay(this.set, part, this.query, { signal, bucketMs: width, patient: true });
          d.buckets = d.buckets.filter(x => x !== b).concat(part.buckets).sort((x, y) => x[0] - y[0]);
        }
      }
      // The rows of page `page` of day d: a window from the bucket of its first rank to the far end of the day, skip rows of that bucket.
      async read(d, page, signal) {
        const start = page * PAGE, want = Math.min(PAGE, d.total - start), desc = this.dir !== "asc";
        let { bucket, skip } = await this.bucketOf(d, start, signal);
        const low = d.buckets.length ? d.buckets[0][0] : 0, last = d.buckets[d.buckets.length - 1], high = last ? last[0] + last[2] : 0;
        const window = desc ? { orderFrom: iso(d.lo == null ? low : d.lo), orderTo: iso(d.hi == null ? bucket[0] + bucket[2] : Math.min(d.hi, bucket[0] + bucket[2])) }
          : { orderFrom: iso(d.lo == null ? bucket[0] : Math.max(d.lo, bucket[0])), orderTo: iso(d.hi == null ? high : d.hi) };
        const rows = [];
        let cursor = null;
        for (;;) {
          const r = await request(this.def.served.list, { ...params(), ...this.query, ...window, dir: desc ? null : "asc", skip: skip > 0 ? skip : null, size: want - rows.length, cursor }, { signal, patient: true });
          for (const x of r.rows) rows.push(x);
          if (r.skipped != null) skip -= r.skipped; else if (r.rows.length) skip = 0;
          if (rows.length >= want || r.exhausted || !r.nextCursor) break;
          cursor = r.nextCursor;
        }
        if (rows.length < want) throw failure("The rows of this part of the list could not be read again: reload the page.", 0);
        return rows;
      }
      // Scrolls the grid to the first row of a day of the list.
      scrollToDay(day) {
        const d = this.days.find(x => x.day === day);
        if (!d) return false;
        if (d.total) { scrollToRank(d.first, this.len); render(false); }
        return true;
      }
    }

    // ---- The mode of the open list: its sort, its export, its value lists, its filters on the server.
    const sortable = (set, c) => c.i === keyIndex(set);
    const sortTitle = c => `Sort by ${c.name} is available when the selection holds at most ${number(report.clientRowsMax)} rows: narrow the period or filter the list`;
    // The help of a filter box of a list browsed on the server, added to the help of its kind.
    const boxHelp = (set, c) => set === "messages" && c.name === "Message ID" ? "An exact Message-ID (=<id>) is found at once when it is stored as typed, in lower case or in upper case; Search every spelling finds another case by reading every message." : "";
    const defaultSort = set => [keyIndex(set), -1];
    // Export view of a list browsed on the server: the server writes the CSV file of every row of the selection with the filters of the list, in the
    // order of the list, day by day; the browser downloads it from a single-use address valid for a minute (an export ticket), so that the
    // download list of the browser shows its progress and can cancel it, whatever its size.
    function exportTitle() {
      el("export").title = "Exports every row of the selection with the filters of the list, in the order of the list: the server writes the file day by day, and the download list of the browser shows its progress.";
    }
    async function exportRemote(set) {
      const b = el("export");
      if (b.disabled) return;
      b.disabled = true;
      try {
        const { query } = serverQuery(set), dir = sortState && sortState[1] > 0 ? "asc" : null;
        const list = new URLSearchParams(Object.entries({ ...params(), ...query, dir }).filter(([, v]) => v != null && v !== "")).toString();
        // A ticket refused as busy says why (the exports waiting to be downloaded): waiting a few seconds would not change it.
        const t = await request("/api/export/ticket", null, { method: "POST", body: JSON.stringify({ view: set, query: list }), busyMessage: true });
        const a = document.createElement("a"); a.href = t.url; a.download = ""; document.body.append(a); a.click(); a.remove();
      } catch (e) { el("result-state").textContent = `The export could not start: ${e.message}`; }
      finally { b.disabled = false; }
    }
    // The value lists of a list browsed on the server: per day (/facets, every text and list column of the grid and the listed columns), summed;
    // a column with more values than the page lists is a text box, as in the static report. The lists that an index answers (Status, Direction and
    // Servers of the messages) are asked first, for every day, in requests of their own: they appear at once, the others as they are counted.
    const QUICK_LISTS = { messages: new Set(["Status", "Direction", "Servers"]) };
    function facetValues(set, c) {
      const st = facetState[set];
      if (!st) return undefined;
      if (st.truncated.has(c.name)) return null;
      const m = st.values.get(c.name);
      return m ? new Map(m) : undefined;
    }
    function facets(set) {
      if (facetState[set]) { updateFacets(set); return; }
      const t = tabs.find(x => x.name === set), def = meta.datasets[set], days = listDays[set] || [];
      const names = [...new Set([...t.columns.map(c => c.name), ...t.filters])].filter(n => def.columns.some(c => c.name === n && (c.kind === "text" || c.kind === "list")));
      const quick = names.filter(n => QUICK_LISTS[set] && QUICK_LISTS[set].has(n)), rest = names.filter(n => !quick.includes(n));
      // done: the days counted of each column.
      const st = facetState[set] = { values: new Map(), truncated: new Set(), done: new Map(), days: days.length };
      const cap = name => t.filters.includes(name) ? 300 : 50;
      const merge = r => {
        for (const name of r.truncated) { st.truncated.add(name); st.values.delete(name); }
        for (const [name, list] of Object.entries(r.columns)) {
          if (st.truncated.has(name)) continue;
          let m = st.values.get(name); if (!m) st.values.set(name, m = new Map());
          for (const [v, n] of list) m.set(v, (m.get(v) || 0) + n);
          if (m.size > cap(name)) { st.truncated.add(name); st.values.delete(name); }
        }
      };
      for (const d of days) (async () => {
        for (const columns of [quick, rest]) {
          if (!columns.length) continue;
          let cursor = null;
          for (;;) {
            const r = await request(`${def.served.list}/facets`, { ...params(), ...dayWindow(d), columns: columns.join("|"), cursor }, { lane: true, facets: true });
            merge(r);
            if (r.complete) break;
            cursor = r.scannedTo; updateFacets(set);
          }
          for (const name of columns) st.done.set(name, (st.done.get(name) || 0) + 1);
          updateFacets(set);
        }
      })().catch(e => { if (!(e && e.name === "AbortError") && tab && tab.name === set && remote(set)) el("result-state").textContent = `The value lists could not be counted: ${e.message}`; });
    }
    // The filter row of the open list with the value lists counted so far: an empty box whose column now fits a list becomes the list.
    function updateFacets(set) {
      if (!tab || tab.name !== set || !remote(set)) return;
      const st = facetState[set], counting = name => (st.done.get(name) || 0) < st.days, def = meta.datasets[set];
      for (let k = 0; k < filterDefs.length; k++) {
        const f = filterDefs[k];
        if (f.type === "search") continue;
        const values = facetValues(set, f.c);
        if (f.type === "multi") {
          if (values) { for (const v of f.sel) if (!values.has(v)) values.set(v, 0); f.values = values; }
          f.counting = counting(f.c.name); continue;
        }
        if (values && values.size >= 2 && !f.input.value.trim() && document.activeElement !== f.input) {
          const m = multiControl(f.c, values, tab.filters.includes(f.c.name)); m.counting = counting(f.c.name);
          f.input.replaceWith(m.button); filterDefs[k] = m;
        }
      }
      for (const name of tab.filters) {
        if (filterDefs.some(f => f.c && f.c.name === name)) continue;
        const i = def.columns.findIndex(c => c.name === name); if (i < 0) continue;
        const c = { ...def.columns[i], i }, values = facetValues(set, c);
        if (!values || values.size < 2) continue;
        const m = multiControl(c, values, true), label = make("label", null, name); m.counting = counting(name); label.append(m.button); el("filters").append(label); filterDefs.push(m);
      }
    }
    // The filters of the controls as list parameters (the search text as it is typed: the server reads it as the page does) and what they say.
    function serverQuery(set) {
      const query = {}, active = [];
      for (const f of filterDefs) {
        if (f.type === "search") {
          const q = f.input.value.trim(), parsed = q ? parseSearch(q, set) : { words: [], fields: [], hints: [] };
          f.hint.textContent = parsed.hints.slice(0, 3).join(" | ");
          if (!q) continue;
          query.q = q;
          for (const x of parsed.fields) active.push(x.text);
          if (parsed.words.length) active.push(`words ${parsed.words.map(w => `"${w}"`).join(" ")}`);
        } else if (f.type === "box") {
          const expr = compileColumn(f.c, f.input.value, f.split), invalid = !!expr && !!expr.error;
          f.input.classList.toggle("invalid", invalid); f.input.title = invalid ? expr.error : f.help;
          if (!expr || invalid) continue;
          query[`f.${f.c.name}`] = f.input.value; active.push(`${f.c.name} ${f.input.value.trim()}`);
        } else if (f.sel.size) {
          query[`m.${f.c.name}`] = Array.from(f.sel).join("|");
          if (f.exclude) query[`x.${f.c.name}`] = "1";
          active.push(`${f.c.name} ${f.exclude ? "not in" : "in"} ${f.sel.size <= 2 ? Array.from(f.sel).join(", ") : `${f.sel.size} values`}`);
        }
      }
      // An exact Message-ID that the index does not hold in any of its spellings is searched in every row when the person asks for it (and in an
      // address that asked for it).
      const key = JSON.stringify(query);
      if (anyCasePending && Object.keys(query).length) { anyCase = { set, key }; anyCasePending = false; }
      if (anyCase && anyCase.set === set && anyCase.key === key) { query.anyCase = "1"; active.push("Message ID in any case"); }
      return { query, active };
    }
    let anyCase = null, anyCasePending = false, anyCaseUsed = null;
    // The button that searches every spelling of an exact Message-ID the index does not hold, next to the result line.
    function spellingButton(set) {
      let b = el("scan-spellings");
      if (!b) { b = make("button", null, "Search every spelling"); b.type = "button"; b.id = "scan-spellings"; el("result-state").before(b); }
      b.hidden = !set;
      b.title = "Reads every message of the selection for this Message-ID in any case: this takes a while on a large selection.";
      b.onclick = set ? () => { anyCase = { set, key: JSON.stringify(serverQuery(set).query) }; b.hidden = true; remotePass().catch(e => { el("result-state").textContent = e.message; }); } : null;
    }
    // Stop: ends the count of a filter that the server scans, the rows found so far stay browsable.
    let passControl = null;
    function stopButton(table) {
      let b = el("scan-stop");
      if (!b) { b = make("button", null, "Stop"); b.type = "button"; b.id = "scan-stop"; el("result-state").before(b); }
      b.hidden = !table;
      b.onclick = table ? () => { table.stopped = true; if (passControl) passControl.abort(); } : null;
    }
    // A filter pass of a list browsed on the server: the count of each day with the filters (seek: one answer per day, two days at a time; scan:
    // newest day first, the matches so far shown and browsable); a selection of at most rowsMax rows is then loaded whole (the switch to the page)
    // once the filters have been left as they are for SETTLE ms. The counts wait for a busy server (the result line says so).
    const SETTLE = 1000;
    async function remotePass() {
      const set = tab.name, base = remoteBase[set], def = meta.datasets[set], began = performance.now();
      if (passControl) passControl.abort();
      const control = passControl = new AbortController(), signal = control.signal;
      const { query, active } = serverQuery(set), dir = sortState && sortState[1] > 0 ? "asc" : "desc", key = JSON.stringify(query);
      anyCasePending = false; anyCaseUsed = query.anyCase ? set : null;
      stopButton(null); spellingButton(null);
      let table = data[set];
      if (!Object.keys(query).length) table = base;
      else if (!(table && table.remote && table !== base && table.key === key && table.complete)) table = new RemoteTable(set, packDays(set), query, dir, null);
      table.setDir(dir); data[set] = table;
      el("tab-caption").textContent = captionOf(tab, def);
      if (!table.complete) {
        table.counting = true; table.stopped = false; table.layout(); render(true);
        el("result-state").textContent = "Counting...";
        const order = table.ordered(), order0 = order.length ? [order[0]] : [];
        const progress = () => {
          if (data[set] !== table) return;
          table.layout(); render(false);
          const searched = order.filter(d => d.total != null && !d.partial).length;
          el("result-state").textContent = `${number(table.len)} matches so far - searched ${searched} of ${order.length} days (${dir === "asc" ? "oldest" : "newest"} first)...`;
          stopButton(table);
          showCount(set, table.days);
        };
        const ask = { dir, signal, patient: true, busy: () => { if (data[set] === table) el("result-state").textContent = "Waiting for the server: other requests are in progress..."; } };
        try {
          for (const d of order0) await countDay(set, d, query, { ...ask, progress });
          // The other days are counted two at a time, newest first: a filter that an index answers counts a day in one answer, a scan shows its
          // matches as they are counted.
          if (order0.length && order0[0].requests === 1) await pool(order.slice(1), 2, d => countDay(set, d, query, ask));
          else { progress(); await pool(order.slice(1), 2, d => countDay(set, d, query, { ...ask, progress }).then(progress)); }
          table.complete = true;
        } catch (e) {
          if (!(e && e.name === "AbortError")) { table.counting = false; stopButton(null); el("result-state").textContent = e.message; return; }
          if (!table.stopped) return;
        }
        table.counting = false; table.layout(); stopButton(null);
      }
      if (!tab || tab.name !== set || data[set] !== table) return;
      showCount(set, table.days); dayCounts(set);
      // A Message-ID the index does not hold is not loaded: the result line offers to search its other spellings.
      if (table !== base && table.complete && table.len <= rowsMax(set) && !table.days.some(d => d.exactMiss)) {
        // A filter still being typed is not loaded: the pass waits until the filters have been left as they are, and a changed filter has its own pass.
        try { await sleep(Math.max(0, began + SETTLE - performance.now()), signal); } catch { return; }
        if (!tab || tab.name !== set || data[set] !== table || JSON.stringify(serverQuery(set).query) !== key) return;
        return narrow(set, table, active, signal, key);
      }
      el("tab-caption").textContent = captionOf(tab, def);
      render(true); markSort();
      const searched = table.days.filter(d => d.total != null && !d.partial).length;
      const miss = !table.stopped && table.days.some(d => d.exactMiss);
      const text = table.stopped ? `Stopped: ${number(table.len)} matches so far - searched ${searched} of ${table.days.length} days (${dir === "asc" ? "oldest" : "newest"} first)`
        : `${number(table.len)} of ${number(base.len)} rows${active.length ? ` - ${active.join("; ")}` : ""}`;
      const note = miss ? " (no message holds this Message-ID as typed, in lower case or in upper case)" : "";
      el("result-state").textContent = (text.length + note.length > 300 ? `${text.slice(0, 297 - note.length)}...` : text) + note;
      spellingButton(miss ? set : null);
      stats.shown = table.len; stats.seq++; stats.remote = (stats.remote || 0) + 1;
      timing.firstTab ||= performance.now();
      hashLater();
    }
    // The switch to the page: the rows of a filtered selection of at most rowsMax rows are loaded whole (two days at a time); the filters of the
    // server become the server selection of the tab (its chip), and every control of the page works inside it. A filter changed while the rows
    // were read is not dropped: the switch does not happen, the pass of the new filter decides.
    async function narrow(set, table, active, signal, key) {
      const def = meta.datasets[set], convert = converter(set), rows = [], rowIds = [];
      el("result-state").textContent = `Loading the ${number(table.len)} rows of the server selection...`;
      let parts;
      try { parts = await dayRows(set, table.ordered().filter(d => d.total), table.query, signal); }
      catch (e) { if (!(e && e.name === "AbortError")) el("result-state").textContent = e.message; return; }
      if (!tab || tab.name !== set || data[set] !== table || JSON.stringify(serverQuery(set).query) !== key) return;
      for (const part of parts) for (const x of part) { rows.push(convert(x.cells)); rowIds.push(x.id); }
      const loaded = new Table(def, rows.length);
      for (let i = 0; i < rows.length; i += 2000) loaded.append(rows.slice(i, i + 2000));
      if (rows.length) loaded.finish();
      forget(set);
      data[set] = loaded; ids[set] = rowIds; mode[set] = "client"; chips[set] = { query: table.query, label: active.join("; ") };
      showCount(set, table.days);
      openTab(tab, null);
    }
    // Back to the whole selection, browsed on the server.
    function removeChip(set) {
      delete chips[set]; forget(set);
      data[set] = remoteBase[set]; mode[set] = "remote"; ids[set] = [];
      showCount(set, listDays[set]);
      if (tab && tab.name === set) openTab(tab, null);
    }
    // The caches of the page computed on the rows of a table that is replaced.
    function forget(set) {
      for (const cache of [distinctCache, keyCache, orderCache]) for (const k of Array.from(cache.keys())) if (k.startsWith(`${set}:`)) cache.delete(k);
      wordCache.clear();
    }
    // A tab opens: its server selection (chip), the rows of each day on the day bar.
    let chipBox = null;
    function opened(set) {
      if (!chipBox) { chipBox = make("div", "server-chip"); chipBox.id = "server-chip"; el("filters").before(chipBox); }
      const c = chips[set];
      chipBox.hidden = !(c && mode[set] === "client");
      if (chipBox.hidden) chipBox.replaceChildren();
      else {
        const remove = make("button", null, "\u00d7"); remove.type = "button"; remove.title = "Remove the server selection and browse every row of the selection again"; remove.setAttribute("aria-label", remove.title);
        remove.addEventListener("click", () => removeChip(set));
        chipBox.replaceChildren(make("span", null, `Server selection: ${c.label}`), remove);
      }
      dayCounts(LISTS.has(set) ? set : null);
      modePill(set);
    }
    // The day of the first visible row of a list browsed on the server, marked on the day bar.
    let visibleDay = null;
    function visible(set, rank) {
      const t = data[set];
      if (!t || !t.remote || !t.len) return;
      const { d } = t.locate(Math.min(rank, t.len - 1));
      if (d.day === visibleDay) return;
      visibleDay = d.day;
      for (const chip of document.querySelectorAll("#day-bar .day-chip")) chip.classList.toggle("current", chip.dataset.day === d.day);
    }
    // The spellings of a user that the Users table of the selection knows (the same name in another case is another row there), the name first.
    function userSpellings(user) {
      const name = String(user), low = lower(name), out = [name], t = data.users, k = col("users", "User"), n = !t || k < 0 ? 0 : Array.isArray(t) ? t.length : t.len;
      for (let i = 0; i < n; i++) { const v = rowOf("users", i)[k]; if (typeof v === "string" && lower(v) === low && !out.includes(v)) out.push(v); }
      return out;
    }
    // A user of a selection whose client sessions are not all in the page: the newest 200 and their count, read from the server (ix_session_user),
    // for every spelling of the user.
    function userSessions(user) {
      const head = make("h3", null, "Client sessions"), box = make("div"), def = meta.datasets.sessions, convert = converter("sessions");
      box.append(make("p", "muted", "Reading the client sessions of this user..."));
      const spellings = userSpellings(user);
      const query = spellings.some(s => s.includes("|")) ? { "f.User": `=${user}` } : { "m.User": spellings.join("|") };
      (async () => {
        const rows = [];
        let cursor = null;
        for (;;) {
          const r = await request(def.served.list, { ...params(), ...query, size: 200 - rows.length, cursor }, { patient: true });
          rows.push(...r.rows);
          if (rows.length >= 200 || r.exhausted || !r.nextCursor) break;
          cursor = r.nextCursor;
        }
        const days = (listDays.sessions || []).map(d => ({ day: d.day, lo: d.lo, hi: d.hi }));
        await pool(days, 2, d => countDay("sessions", d, query, { patient: true }));
        const total = days.reduce((a, d) => a + d.total, 0);
        head.textContent = total > rows.length ? `Client sessions (first ${number(rows.length)} of ${number(total)}, newest first)` : `Client sessions (${number(rows.length)})`;
        box.replaceChildren();
        if (!rows.length) return;
        const table = make("table", "mini"), top = make("tr"), names = ["Start", "Duration", "Outcome", "Protocol", "Client", "Authentication", "Client IP", "Requests", "Failures", "Last error"];
        for (const h of names) top.append(make("th", h === "Requests" || h === "Failures" ? "num" : null, h));
        table.append(top);
        for (const r of rows) {
          const x = convert(r.cells), line = make("tr"); line.style.cursor = "pointer"; line.title = "Open this session";
          for (const name of names) {
            const k = col("sessions", name), cdef = def.columns[k], val = x[k], td = make("td", cdef.kind === "num" ? "num nowrap" : name === "Last error" || name === "Client" ? null : "nowrap");
            if (name === "Outcome") td.append(make("span", `pill ${tone(val)}`, val)); else td.textContent = cellText(cdef, val);
            line.append(td);
          }
          line.addEventListener("click", () => { el("detail").close(); showDetails("sessions", r.id, true); });
          table.append(line);
        }
        box.append(table);
      })().catch(e => { box.replaceChildren(make("p", "muted", e.message)); });
      return [head, box];
    }

    // ---- Details: one request per opened row; the SMTP client composes its transactions.
    let detailControl = null;
    async function fullRow(set, i) {
      const def = meta.datasets[set], table = data[set];
      // A row of a list browsed on the server may have left the page cache since it was drawn: its page is read again.
      if (table && table.remote) {
        await table.need(i);
        if (!table.has(i)) throw failure("This row could not be read again: scroll to it and open it again.", 0);
      }
      const row = rowOf(set, i), id = table && table.remote ? table.idOf(i) : ids[set] ? ids[set][i] : undefined;
      if (!def.served || !def.served.detail || id === undefined) return row;
      return detail(set, id, row.slice());
    }
    // A row opened by its id (a row of an address, or of the client sessions of a user): the detail holds every column of its dataset.
    async function fullRowById(set, id) {
      const def = meta.datasets[set];
      if (!def.served || !def.served.detail) throw failure("This row cannot be opened from its address: find it in the table.", 0);
      return detail(set, id, def.columns.map(() => null));
    }
    async function detail(set, id, full) {
      const def = meta.datasets[set];
      if (detailControl) detailControl.abort();
      const control = detailControl = new AbortController();
      const d = await request(def.served.detail.replace("{id}", encodeURIComponent(id)), params(null, set === "operations"), { signal: control.signal });
      d.columns.forEach((c, j) => { const k = def.columns.findIndex(x => x.name === c.name); if (k >= 0) full[k] = adapt(def.columns[k].kind, d.cells[j]); });
      if (set === "smtpclients") full[def.columns.findIndex(c => c.name === "Transactions detail")] = await transactions(id, control.signal);
      openKey = `${set === (tab && tab.name) ? "" : `${set}:`}${id}`; hashLater();
      return full;
    }
    // Transactions of an SMTP client in the report's shape: refusals first, then the latest, 50 at most; each transcript is read when opened.
    async function transactions(id, signal) {
      const path = `/api/smtp/clients/${encodeURIComponent(id)}/transactions`;
      // A client without a refused transaction answers 404 to the refusals.
      const none = e => { if (e && e.status === 404) return { rows: [] }; throw e; };
      const [refused, latest] = await Promise.all([request(path, params({ status: "Rejected", size: 50 }), { signal }).catch(none), request(path, params({ size: 50 }), { signal })]);
      const rows = [], taken = new Set();
      for (const r of [...refused.rows, ...latest.rows]) if (!taken.has(r.id) && rows.length < 50) { taken.add(r.id); rows.push(r); }
      const at = name => SMTP_COLUMNS.indexOf(name);
      return rows.map(r => {
        const c = r.cells, step = [toWall(c[at("Time")]), c[at("Server")], c[at("Connector")], c[at("Status")], c[at("Mail from")], c[at("Recipient count")], null, c[at("Message ID")], null,
          c[at("Authentication mechanism")], c[at("Authentication result")], c[at("Last AUTH attempt")], c[at("Authenticated user")], c[at("Identity evidence")]];
        step.transaction = r.id;
        return step;
      });
    }
    const SMTP_COLUMNS = ["Time", "End", "Server", "Direction", "Role", "Connector", "Remote", "Mail from", "Recipient count", "Recipients", "Message ID", "Status",
      "Authentication mechanism", "Authentication result", "Last AUTH attempt", "Authenticated user", "Identity evidence"];
    // The response and the transcript of one SMTP transaction, read when its line is opened.
    async function transcript(step, pre, response) {
      pre.textContent = "Reading the transcript...";
      try {
        const d = await request(`/api/smtp/transactions/${encodeURIComponent(step.transaction)}`, params());
        const at = name => d.columns.findIndex(c => c.name === name);
        pre.textContent = d.cells[at("Transcript")] || "No transcript was kept for this transaction.";
        if (response && !response.textContent) response.textContent = d.cells[at("Response")] || "";
      } catch (e) { pre.textContent = e.message; }
    }
    // The fields kept for the request of a timeline step: the issue row of its request ID, read for the user of the session around the step.
    function keptFields(s, user, list, fallback) {
      const wait = make("p", "muted", "Reading the fields kept for this request...");
      const at = s.utc != null ? s.utc : null;
      if (at == null || !user) return null;
      request(`/api/requests/${encodeURIComponent(s[10])}`, { from: iso(at - 60000), to: iso(at + 60000 + (Number(s[6]) || 0)), user })
        .then(d => { const def = meta.datasets.issues, kinds = def.columns.map(c => c.kind); wait.replaceWith(list(def.columns.map((c, k) => adapt(kinds[k], d.rows[0].cells[d.columns.findIndex(x => x.name === c.name)])))); })
        .catch(e => { if (e.status === 404) wait.replaceWith(...fallback()); else wait.textContent = e.message; });
      return wait;
    }
    // The mode of a list next to its tab count: its rows in the page, or browsed on the server.
    function modePill(set) {
      const t = tabs.find(x => x.name === set);
      if (!t || !LISTS.has(set) || !mode[set]) return;
      let pill = t.button.querySelector(".mode");
      if (!pill) { pill = make("span", "pill mode"); t.button.append(pill); }
      pill.textContent = remote(set) ? "Remote" : "Loaded";
      pill.title = remote(set) ? `More than ${number(rowsMax(set))} rows: browsed on the server` : chips[set] ? "The rows of the server selection are loaded in the page" : "Every row of the selection is loaded in the page";
    }
    // A row named by open= in the address opens when its table is ready.
    let pendingOpen = null;
    function tableReady(set) {
      const t = tabs.find(x => x.name === set);
      if (t) {
        const def = meta.datasets[set], count = t.button.querySelector(".count");
        if (count) count.textContent = def.total != null ? number(def.total) : `${number(def.rows)}+`;
        modePill(set);
      }
      if (pendingOpen && pendingOpen.set === set && tab) {
        const open = pendingOpen;
        pendingOpen = null;
        // A row of a list browsed on the server is opened by its id, without its rank.
        if (remote(set)) { if (meta.datasets[set].served.detail) showDetails(set, open.id, true); return; }
        const i = ids[set] ? ids[set].findIndex(x => String(x) === open.id) : -1;
        if (i >= 0) showDetails(set, i);
      }
    }
    function restoreOpen(p, wanted) {
      const v = p.get("open"); if (!v || !wanted) return;
      const m = /^(?:([a-z]+):)?(.{1,256})$/.exec(v);
      if (m) pendingOpen = { set: m[1] || wanted.name, id: m[2] };
    }
    // Captions and result lines of a table that does not hold every row of the selection.
    function caption(set) {
      const c = cut[set], def = meta.datasets[set];
      if (remote(set)) {
        const t = data[set], base = remoteBase[set], order = t && t.dir === "asc" ? "oldest first" : "newest first";
        const rows = t && t !== base && t.complete && !t.stopped ? `${number(t.len)} of the ${number(base.len)} rows of the selection` : `the ${number(base.len)} rows of the selection`;
        return ` Browsing ${rows} on the server - sorted by ${KEY[set]}, ${order}. Filters, value lists, the search and Export view run on the server over the whole period; sorting by another column opens when the selection holds at most ${number(report.clientRowsMax)} rows.`;
      }
      if (!c) return set === "smtpclients" ? " In the portal an SMTP client is one server, direction, role, connector, address, HELO name and authenticated account." : "";
      const shown = def.rows, whole = def.total;
      return c.reason === "max"
        ? ` This selection holds ${whole != null ? number(whole) : `more than ${number(shown)}`} rows: the newest ${number(shown)} are loaded, the most a table holds in the page. Narrow the period or filter on a server or a user to see the others.`
        : ` The first ${number(shown)} rows are loaded: the server lists at most that many in one go. Narrow the period or filter on a server or a user to see the others.`;
    }
    const resultNote = set => chips[set] && mode[set] === "client" ? ` (narrowed on the server: ${chips[set].label})`
      : cut[set] ? ` (newest ${number(meta.datasets[set].rows)}${meta.datasets[set].total != null ? ` of ${number(meta.datasets[set].total)}` : ""} rows of the selection loaded)` : "";
    function hash(p) {
      writeSelection(p, selection);
      if (openKey) p.set("open", openKey);
      // The server selection of the open tab: its filters, so that the address opens the same rows again.
      const c = tab && chips[tab.name] && mode[tab.name] === "client" ? chips[tab.name] : null;
      if (c) for (const [k, v] of Object.entries(c.query)) if (!p.has(k)) { if (k.startsWith("m.")) for (const x of v.split("|")) p.append(k, x); else p.set(k, v); }
      if (tab && anyCaseUsed === tab.name && remote(tab.name)) p.set("anyCase", "1");
    }
    return { start, controls, loadSets, fullRow, fullRowById, transcript, keptFields, tableReady, restoreOpen, caption, resultNote, hash, sameSelection,
      isCut: set => !!cut[set] || (LISTS.has(set) && whole[set] !== true), whole: set => whole[set] === true, remote, sortable, sortTitle, boxHelp, defaultSort, exportTitle, exportRemote,
      facetValues, facets, remotePass, visible, opened, userSessions, get selection() { return selection; } };
  }

  // ---- Progressive display --------------------------------------------------------------------------------
  // The overview needs servers and daily; a table opens once its own dataset is complete. The tab named in the
  // address, else the first one, opens by itself.
  const initialHash = parseHash(), wanted = tabs.find(t => t.name === initialHash.get("tab")) || tabs[0];
  const guardOverride = Number(initialHash.get("maxbytes"));
  restorePeriod(initialHash);
  let overviewDone = false, noticeSet = null;
  function datasetReady(set) {
    if (!overviewDone && (!meta.datasets.servers || ready.servers) && (!meta.datasets.daily || ready.daily)) renderOverview();
    if (overviewDone && meta.edge && (set === "smtpclients" || set === "smtpdestinations")) edgeTiles();
    if (overviewDone && (set === "users" || set === "authentication")) authTile();
    const t = tabs.find(x => x.name === set);
    if (served && t) queueMicrotask(() => portal.tableReady(set));
    if (!t) return;
    t.button.disabled = false; t.button.classList.remove("loading"); t.button.removeAttribute("title");
    // A tab asked for by an address change while its rows were still loading opens when it is complete.
    if (noticeSet === set) { noticeSet = null; openTab(t, null); }
    else if (pendingHash && pendingHash.t === t) { const { p } = pendingHash; pendingHash = null; openTab(t, p); }
    else if (t === wanted && !tab) openTab(t, initialHash.get("tab") === t.name ? initialHash : null);
  }

  // ---- Memory guard -----------------------------------------------------------------------------------
  // A table is not loaded on its own when the tables already loaded plus its estimated size exceed what this computer can
  // hold (a quarter of its memory, at most 2 GB; #maxbytes=<n> in the address sets the limit); its tab says so and offers to
  // load it anyway. The small tables come first, so the overview and the small tables are never the ones left out. rows: the rows of a table
  // that its description does not count yet (a list loaded whole once its days are counted).
  const HEAVY = new Set(["sessions", "issues", "messages"]);
  function estimate(set, rows) {
    const d = meta.datasets[set]; let per = 8;
    for (const c of d.columns) per += c.kind === "num" || c.kind === "time" ? 8 : c.kind === "text" ? 6 : c.kind === "list" ? 16 : 0;
    // Checked against the memory of the page for 1.5 million sessions, 340,000 failed requests and 936,000 messages: the figure is
    // 4 to 65 % above what each of these tables takes (the dictionaries depend on the data), plus the fixed cost of a table.
    return Math.round((rows ?? d.rows) * (per + (HEAVY.has(set) ? 40 : 0)) * 1.3) + 12 * 1048576;
  }
  const bytesText = n => n >= 1073741824 ? `${(n / 1073741824).toFixed(1)} GB` : `${Math.max(1, Math.round(n / 1048576))} MB`;
  const guardLimit = guardOverride > 0 ? guardOverride : Math.min(2 * 1073741824, 0.25 * (navigator.deviceMemory || 6) * 1073741824);
  let estimated = 0; const decided = {};
  function allowed(set) {
    if (PLAIN.has(set)) return true;
    if (!(set in decided)) { const need = estimate(set); decided[set] = estimated + need <= guardLimit; if (decided[set]) estimated += need; }
    return decided[set];
  }
  function skipSet(set) {
    skipped[set] = estimate(set);
    const t = tabs.find(x => x.name === set); if (!t) return;
    t.button.disabled = false; t.button.classList.remove("loading"); t.button.classList.add("skipped"); t.button.title = "Not loaded automatically (memory)";
    if (t === wanted && !tab) openTab(t, null);
  }
  function showSkipped(t) {
    const box = el("tab-notice"), d = meta.datasets[t.name], button = make("button", "primary-button", "Load anyway"); button.type = "button";
    button.addEventListener("click", () => loadAnyway(t.name));
    box.replaceChildren(make("span", null, `This table has ${number(d.total)} rows (about ${bytesText(skipped[t.name])}): it is not loaded automatically on this computer. The CSV file has every row.`), button);
    box.hidden = false; noticeSet = t.name; tab = null;
    for (const p of dataParts) p.hidden = true;
  }
  function loadAnyway(set) {
    const t = tabs.find(x => x.name === set);
    estimated += skipped[set]; decided[set] = true; delete skipped[set];
    t.button.classList.remove("skipped"); t.button.classList.add("loading"); t.button.disabled = true;
    el("tab-notice").textContent = `Loading ${t.title.toLowerCase()}...`;
    progress.hidden = false;
    loader = loader.then(loadAll);
  }

  // ---- Loading ----------------------------------------------------------------------------------------
  // The small tables in the order of the report description, then the table that opens (so that its preview comes first), then
  // the other large tables; the files are read in that order.
  const manifestOrder = Array.from(new Set(summaryFiles.map(f => f.set)));
  const setOrder = [...manifestOrder.filter(s => !HEAVY.has(s)), ...manifestOrder.filter(s => HEAVY.has(s) && wanted && s === wanted.name), ...manifestOrder.filter(s => HEAVY.has(s) && !(wanted && s === wanted.name))];
  const loadFiles = summaryFiles.map((f, i) => ({ f, i })).sort((a, b) => setOrder.indexOf(a.f.set) - setOrder.indexOf(b.f.set) || a.i - b.i).map(x => x.f);
  const loadedBySet = {}, verifyMode = initialHash.has("verify");
  const NO_STREAMS = "This browser cannot open the compressed data (a recent Edge, Chrome or Firefox is required). Use the CSV files of the same folder.";
  let ahead = null, loader = null, progressAt = 0;
  // The file after `f` is requested while `f` is being decoded, when its table will be loaded as well.
  function lookAhead(f) {
    const g = loadFiles[loadFiles.indexOf(f) + 1];
    if (g && !ready[g.set] && !skipped[g.set] && allowed(g.set)) { ahead = { f: g, p: getFile(g) }; ahead.p.catch(() => { }); }
  }
  async function loadSet(set) {
    const def = meta.datasets[set], plain = PLAIN.has(set), files = summaryFiles.filter(f => f.set === set);
    // A table interrupted by an error starts again: a half-filled column is not worth keeping.
    loaded -= loadedBySet[set] || 0; loadedBySet[set] = 0;
    endPreview(set);
    const table = data[set] = plain ? [] : new Table(def, def.rows);
    let slice = performance.now();
    for (const f of files) {
      const p = ahead && ahead.f === f ? ahead.p : getFile(f); ahead = null;
      lookAhead(f);
      const r = await p;
      if (verifyMode) check(f, r);
      const before = plain ? table.length : table.len, entries = r.entries;
      // The next block is decoded (native gunzip and JSON parse) while the rows of the current one are added to the table.
      const decodeAt = j => { const q = decode(entries[j].data); q.catch(() => { }); return q; };
      let next = entries.length ? decodeAt(0) : null;
      for (let j = 0; j < entries.length; j++) {
        let chunk; const waited = performance.now();
        try { chunk = await next; } catch { throw new ExlError(NO_STREAMS); }
        next = j + 1 < entries.length ? decodeAt(j + 1) : null;
        const appending = performance.now(); timing.decodeMs[set] = (timing.decodeMs[set] || 0) + appending - waited;
        if (chunk.set !== set) throw new ExlError(`The data file ${f.name} holds rows of ${chunk.set}, not of ${set}: the file is damaged.`);
        if (plain) for (const row of chunk.rows) table.push(row); else table.append(chunk.rows);
        timing.appendMs[set] = (timing.appendMs[set] || 0) + performance.now() - appending;
        loaded += chunk.rows.length; loadedBySet[set] += chunk.rows.length;
        // The loading line is redrawn at most every 100 ms, and after the last block of a file.
        if (j === entries.length - 1 || performance.now() - progressAt > 100) { progressAt = performance.now(); showProgress(set); }
        if (!plain && !tab && set === previewSet()) {
          if (!grid) showPreview(set);
          else if (grid.preview && grid.set === set && performance.now() - previewAt > 500) refreshPreview();
        }
        // Yield by time budget so that the page stays responsive while the remaining datasets are decoded.
        if (performance.now() - slice > 30) { await yieldNow(); slice = performance.now(); }
      }
      const got = (plain ? table.length : table.len) - before;
      if (got !== f.rows) throw new ExlError(`The data file ${f.name} holds ${number(got)} rows, the report description says ${number(f.rows)}: the file is damaged.`);
      // The blocks are released once the whole file is loaded: a file that failed is read again, whole, by "Try again".
      if (inlineLayout) { if (r.script) r.script.remove(); r.entries = []; inlineFiles.delete(f.name); consumed.add(f.name); }
      else for (const e of entries) e.data = null;
      filesDone++;
    }
    if (!plain) table.finish();
    ready[set] = true; timing.ready[set] = performance.now();
    datasetReady(set);
  }
  async function loadAll() {
    try {
      if (served) await portal.loadSets(setOrder);
      else for (const set of setOrder) {
        if (ready[set] || skipped[set]) continue;
        if (!allowed(set)) { skipSet(set); continue; }
        await loadSet(set);
      }
    } catch (error) { loadFailed(error); return; }
    allLoaded = true; progress.hidden = true; el("loading").hidden = true;
    for (const b of document.querySelectorAll(".retry")) b.remove();
    timing.complete = performance.now();
  }
  // The reason is shown where the person is looking (loading line, tabs), with a button to try again in a folder report (the
  // folder can be put back or extracted meanwhile; a single file cannot change between two attempts).
  function loadFailed(error) {
    // A portal load cancelled by a new selection or by Stop portal has nothing to say.
    if (served && error && error.name === "AbortError") return;
    const message = error instanceof ExlError || (served && error && error.portal) ? error.message : `The data could not be read (${error && error.message ? error.message : error}). The CSV files of the same folder have every row.`;
    endPreview(null);
    el("loading-text").textContent = message; progressText.textContent = message; progress.hidden = false; progressFill.style.width = "0";
    for (const b of document.querySelectorAll(".retry")) b.remove();
    if (!inlineLayout || served) for (const box of [el("loading").firstElementChild, progress]) {
      const b = make("button", "retry", "Try again"); b.type = "button";
      b.addEventListener("click", () => { for (const x of document.querySelectorAll(".retry")) x.remove(); loader = loader.then(loadAll); });
      box.append(b);
    }
    for (const t of tabs) if (!ready[t.name] && !skipped[t.name]) t.button.title = message;
    if (!tab) el("tab-caption").textContent = message;
  }
  if (!tabs.length) el("data").hidden = true;
  if (served) { portal.controls(); portal.restoreOpen(initialHash, wanted); }
  for (const name in ready) if (ready[name]) datasetReady(name);
  loader = loadAll();
  await loader;
})();

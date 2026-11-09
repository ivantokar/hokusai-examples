// Runtime Lab: bounded, user-triggered scenarios that exercise the real server integration.
// Every number here is measured. Browser-side observations (an aborted fetch, chunks arriving) are
// never presented as proof of what the server did: the server's own status is polled for that.

const $ = (id) => document.getElementById(id);
const el = (tag, props = {}, ...children) => { const n = Object.assign(document.createElement(tag), props); for (const c of children) n.append(c); return n; };
const wait = (ms) => new Promise((r) => setTimeout(r, ms));
const ms = (n) => `${Math.round(n)} ms`;
const kib = (n) => (n < 1048576 ? `${(n / 1024).toFixed(1)} KiB` : `${(n / 1048576).toFixed(2)} MiB`);

// A recipe that takes a noticeable fraction of a second: big enough to overlap, small enough to stay bounded.
const HEAVY = {
  version: 1,
  steps: [
    { op: "resize", params: { width: 5000, fit: "inside" } },
    { op: "blur", params: { sigma: 6 } },
    { op: "median", params: { size: 9 } },
  ],
  output: { format: "jpeg", options: { quality: 60 } },
};

let sample = null, uploadId = null, statusTimer = null;

async function sampleBytes() {
  sample ??= await fetch("/samples/scene.png").then((r) => r.blob());
  return sample;
}
async function ensureUpload() {
  if (uploadId) return uploadId;
  const res = await fetch("/api/uploads", { method: "POST", body: await sampleBytes() });
  uploadId = (await res.json()).uploadId;
  return uploadId;
}
async function heavyRender(signal) {
  const body = () => JSON.stringify({ uploadId, recipe: HEAVY });
  await ensureUpload();
  let res = await fetch("/api/render", { method: "POST", body: body(), signal });
  if (res.status === 404) { uploadId = null; await ensureUpload(); res = await fetch("/api/render", { method: "POST", body: body(), signal }); }
  return res;
}
const getStatus = () => fetch("/api/status", { cache: "no-store" }).then((r) => r.json());

function table(rows, head) {
  const t = el("table");
  if (head) t.append(el("thead", {}, el("tr", {}, ...head.map((h) => el("th", { scope: "col", textContent: h })))));
  const body = el("tbody");
  for (const r of rows) body.append(el("tr", {}, ...r.map((c, i) => (i === 0 && !head ? el("th", { scope: "row", textContent: c }) : el("td", { textContent: String(c) })))));
  t.append(body);
  return t;
}

function card(title, intro, ...rest) {
  const out = el("div", { className: "lab-out", role: "status", "aria-live": "polite" });
  const c = el("section", { className: "lab-card" }, el("h2", { textContent: title }), el("p", { className: "muted", textContent: intro }), ...rest, out);
  return { node: c, out };
}
function runner(label, fn, out) {
  const b = el("button", { type: "button", className: "btn", textContent: label });
  b.onclick = async () => {
    b.disabled = true; out.replaceChildren(el("p", { className: "muted", textContent: "Running…" }));
    try { await fn(); } catch (e) { out.replaceChildren(el("p", { className: "status error", textContent: e.message })); }
    b.disabled = false;
  };
  return b;
}

// ---- A. Streaming ----
function streamingCard() {
  const fmt = el("select", { "aria-label": "Format" }, ...["webp", "jpeg", "png", "tiff"].map((f) => el("option", { value: f, textContent: f.toUpperCase() })));
  const c = card("Streamed output", "The minimal route resizes the sample and streams the encoded image back. Time to the first byte against total time shows whether the server started sending before it finished encoding. Chunks arriving is not progressive decoding of the picture.");
  const once = async (format) => {
    const t0 = performance.now(); let first = null, chunks = 0, bytes = 0;
    const res = await fetch(`/api/minimal/resize?width=2400&format=${format}`, { method: "POST", body: await sampleBytes() });
    if (!res.ok) throw new Error(`${res.status}: ${(await res.json()).error?.message ?? ""}`);
    const reader = res.body.getReader();
    for (;;) { const { done, value } = await reader.read(); if (done) break; first ??= performance.now() - t0; chunks++; bytes += value.byteLength; }
    return { format, first, total: performance.now() - t0, chunks, bytes };
  };
  const show = (rs) => c.out.replaceChildren(
    table(rs.map((r) => [r.format.toUpperCase(), kib(r.bytes), r.chunks, ms(r.first), ms(r.total), `${Math.round((r.first / r.total) * 100)}%`]), ["Format", "Size", "Chunks received", "First byte", "Total", "First byte / total"]),
    el("p", { className: "muted", textContent: "First byte / total shows how much of the work was done before anything was sent. Hokusai encodes TIFF fully in memory before the first byte leaves, so for TIFF the server holds the whole file first (here the encode is fast, so the first byte still comes early); the other encoders can start sending while they work. The encoders differ in how they chunk their output (WebP arrived in one piece). Times include the network between this browser and the server." }));
  c.node.insertBefore(el("div", { className: "lab-actions" }, fmt, runner("Run", async () => show([await once(fmt.value)]), c.out),
    runner("Compare all formats", async () => { const rs = []; for (const f of ["webp", "jpeg", "png", "tiff"]) rs.push(await once(f)); show(rs); }, c.out)), c.out);
  return c.node;
}

// ---- B. Cancel ----
function cancelCard() {
  const c = card("Cancel a request", "Starts a heavy render, aborts the request in the browser, and polls the server's own status. The browser seeing the abort proves nothing about the server; the status shows whether it stopped evaluating.");
  const run = async () => {
    await ensureUpload();
    const t0 = performance.now();
    const full = await heavyRender(); await full.blob();
    const fullMs = performance.now() - t0;
    await waitForIdle(5000);
    const ctrl = new AbortController(); const started = performance.now();
    const pending = heavyRender(ctrl.signal).catch((e) => e);
    await wait(120); ctrl.abort(); const abortedAt = performance.now() - started; await pending;
    let seenActive = 0, lastActive = null, idleAfter = null;
    while (performance.now() - started < 8000) {
      const s = await getStatus();
      if (s.active > 0) { seenActive = performance.now() - started; lastActive = s.active; }
      if (s.active === 0 && s.queued === 0 && performance.now() - started > abortedAt + 60) { idleAfter = performance.now() - started; break; }
      await wait(60);
    }
    const server = idleAfter == null ? "still busy after 8 s" : ms(Math.max(0, idleAfter - abortedAt));
    const verdict = idleAfter == null ? "The server had not gone idle after 8 s." :
      idleAfter - abortedAt < fullMs * 0.35 ? "The server went idle well before a full render would have finished: evaluation was stopped." :
      "The server stayed busy for about as long as a full render needs: it kept evaluating after the client left.";
    c.out.replaceChildren(table([["Uncancelled render", ms(fullMs)], ["Aborted in the browser at", ms(abortedAt)], ["Server active after the abort for", server], ["Last active count seen", lastActive ?? "0"]]),
      el("p", { textContent: verdict }),
      el("p", { className: "muted", textContent: "Polling every 60 ms, so values are approximate. This measures this backend with this route; a cancelled upload or a different route can behave differently." }));
  };
  c.node.insertBefore(el("div", { className: "lab-actions" }, runner("Run", run, c.out)), c.out);
  return c.node;
}
async function waitForIdle(limit) { const t = performance.now(); while (performance.now() - t < limit) { const s = await getStatus(); if (s.active === 0 && s.queued === 0) return; await wait(60); } }

// ---- C. Batch ----
function batchCard() {
  const n = el("select", { "aria-label": "Requests" }, ...[4, 6, 10, 14].map((v) => el("option", { value: v, textContent: `${v} at once`, selected: v === 10 })));
  const c = card("Queue and limits", "Sends a small batch of heavy renders at once. The server runs a few, queues a few, and answers 503 beyond its configured queue. Everything is bounded: at most 14 requests, each a fraction of a second of work. A browser opens only about six connections to one server, so no more than six requests reach it at the same time however many you send.");
  const run = async () => {
    await ensureUpload(); await waitForIdle(5000);
    const count = Number(n.value); let peakActive = 0, peakQueued = 0, polling = true;
    const poll = (async () => { while (polling) { const s = await getStatus(); peakActive = Math.max(peakActive, s.active); peakQueued = Math.max(peakQueued, s.queued); await wait(40); } })();
    const t0 = performance.now();
    const results = await Promise.all(Array.from({ length: count }, async () => {
      const t = performance.now(); const res = await heavyRender(); const type = res.headers.get("content-type");
      const detail = type?.includes("json") ? (await res.json()).error?.message : (await res.blob(), "");
      return { status: res.status, ms: performance.now() - t, detail };
    }));
    polling = false; await poll;
    const s = await getStatus();
    const by = {}; for (const r of results) by[r.status] = (by[r.status] ?? 0) + 1;
    const rejected = results.find((r) => r.status === 503);
    c.out.replaceChildren(
      table([["Requests", count], ["Answered", Object.entries(by).map(([k, v]) => `${v} × ${k}`).join(", ")], ["Peak running / queued seen", `${peakActive} / ${peakQueued}`],
        ["Configured", `${s.maxConcurrent} concurrent, queue of ${s.limits.maxQueued ?? "unbounded"}`], ["Whole batch", ms(performance.now() - t0)]]),
      ...(rejected ? [el("p", { textContent: `A rejected request got: “${rejected.detail}”` })] : [el("p", { className: "muted", textContent: "Nothing was rejected: the queue was long enough for what reached the server at once. Restart the server with HOKUSAI_MAX_QUEUED set lower to see rejections." })]),
      el("p", { className: "muted", textContent: "A 503 with a clear message is the intended way to shed load; clients should retry later. Peaks come from polling every 40 ms." }));
  };
  c.node.insertBefore(el("div", { className: "lab-actions" }, n, runner("Send batch", run, c.out)), c.out);
  return c.node;
}

// ---- D. Failures ----
function failuresCard() {
  const c = card("Failure examples", "Each button sends something wrong on purpose and shows what the integration answers: the status a client can act on, and the message. Nothing here is a stress test.");
  const phone = () => fetch("/samples/phone.jpg").then((r) => r.blob());
  const cases = [
    ["Not an image", async () => fetch("/api/uploads", { method: "POST", body: "hello, this is text" })],
    ["Truncated JPEG", async () => {
      // Upload only reads the header, so a cut-off file is accepted; the damage shows when it is rendered.
      const up = await fetch("/api/uploads", { method: "POST", body: (await phone()).slice(0, 1800) });
      if (!up.ok) return up;
      const id = (await up.json()).uploadId;
      return fetch("/api/render", { method: "POST", body: JSON.stringify({ uploadId: id, recipe: { version: 1, steps: [{ op: "grayscale" }], output: { format: "png" } } }) });
    }],
    ["Too large for the minimal route (6 MiB, limit 5)", async () => fetch("/api/minimal/resize", { method: "POST", body: new Blob([await sampleBytes(), new Uint8Array(6 * 1048576)]) })],
    ["Upload id that does not exist", async () => fetch("/api/render", { method: "POST", body: JSON.stringify({ uploadId: "nope", recipe: { version: 1, steps: [], output: { format: "png" } } }) })],
    ["Unknown operation in a recipe", async () => { await ensureUpload(); return fetch("/api/render", { method: "POST", body: JSON.stringify({ uploadId, recipe: { version: 1, steps: [{ op: "sparkle" }], output: { format: "png" } } }) }); }],
    ["Crop outside the image", async () => { await ensureUpload(); return fetch("/api/render", { method: "POST", body: JSON.stringify({ uploadId, recipe: { version: 1, steps: [{ op: "crop", params: { x: 1500, width: 400 } }], output: { format: "png" } } }) }); }],
  ];
  const rows = el("div", { className: "lab-actions wrap" });
  for (const [label, fn] of cases) {
    const b = el("button", { type: "button", className: "btn", textContent: label });
    b.onclick = async () => {
      b.disabled = true;
      try {
        const res = await fn(); let message = "";
        try { const b = await res.clone().json(); message = b.error?.message ?? b.reason ?? b.message ?? res.statusText; } catch { message = res.ok ? "accepted" : res.statusText; }
        c.out.replaceChildren(el("p", {}, el("strong", { textContent: `${res.status} ` }), `${label}: ${message}`));
      } catch (e) { c.out.replaceChildren(el("p", { className: "status error", textContent: `${label}: ${e.message}` })); }
      b.disabled = false;
    };
    rows.append(b);
  }
  c.node.insertBefore(rows, c.out);
  return c.node;
}

// ---- E. Configuration ----
function configCard() {
  const c = card("Runtime configuration (read-only)", "Hokusai's runtime settings are per process and are frozen when the first image is evaluated, so there are no sliders here. To try another configuration restart the server with HOKUSAI_MAX_CONCURRENT and HOKUSAI_MAX_QUEUED (or launch a second, isolated worker).");
  c.out.id = "lab-config";
  return { node: c.node, refresh: async () => {
    const s = await getStatus(); const l = s.limits;
    c.out.replaceChildren(table([
      ["Evaluations running now / allowed", `${s.active} / ${s.maxConcurrent}`], ["Queued now / queue limit", `${s.queued} / ${l.maxQueued ?? "unbounded"}`],
      ["libvips threads per evaluation", l.vipsConcurrency], ["Largest output", l.maxOutputPixels == null ? "default" : `${l.maxOutputPixels.toLocaleString()} px`],
      ["Untrusted loaders blocked", l.blockUntrusted ? "yes" : "no"], ["Configuration frozen", s.frozen ? "yes (a first image was evaluated)" : "not yet"],
      ["Stored uploads", `${s.uploads} (${kib(s.uploadBytes)}) · limit ${l.uploadMaxEntries} items, ${kib(l.uploadTotalBytes)} total, ${kib(l.uploadLimitBytes)} each`],
      ["Upload lifetime", `${l.uploadLifetimeSeconds} s without use, then forgotten`],
    ]));
  } };
}

export function initLab(container) {
  const config = configCard();
  container.replaceChildren(
    el("div", { className: "inspect-head" }, el("h1", { textContent: "Runtime Lab" }),
      el("p", { className: "muted", textContent: "Bounded, user-triggered scenarios against the backend that served this page. Browser measurements are labelled as such; the server's own status is the evidence for what it did." })),
    el("div", { className: "lab-grid" }, streamingCard(), cancelCard(), batchCard(), failuresCard(), config.node));
  return {
    show() { config.refresh(); clearInterval(statusTimer); statusTimer = setInterval(config.refresh, 2000); },
    hide() { clearInterval(statusTimer); },
  };
}

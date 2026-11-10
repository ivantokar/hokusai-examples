// Inspect: raw pixels and pages. Values shown here come from real bytes the server produced or accepted;
// nothing is inferred from settings.
import { el, clone, fmtBytes, apiError } from "./ui.js";

const FORMATS = [
  ["gray8", 1, 1], ["grayAlpha8", 2, 1], ["rgb8", 3, 1], ["rgba8", 4, 1],
  ["gray16", 1, 2], ["grayAlpha16", 2, 2], ["rgb16", 3, 2], ["rgba16", 4, 2],
];
const info = (format) => { const f = FORMATS.find((x) => x[0] === format); return { channels: f[1], bytes: f[2], alpha: f[0].includes("Alpha") || f[0].startsWith("rgba"), gray: f[1] <= 2 }; };
const rows = (pairs) => el("table", {}, el("tbody", {}, ...pairs.map(([k, v]) => el("tr", {}, el("th", { scope: "row", textContent: k }), el("td", { textContent: String(v) })))));

// ------------------------------------------------------------------ raw pixels
export function initRaw(container, ctx) {
  const state = ctx.state;

  // ---- A. raw output
  const fmt = el("select", { "aria-label": "Raw pixel format" }, ...FORMATS.map(([f]) => el("option", { value: f, textContent: f, selected: f === "rgba8" })));
  const pre = el("input", { type: "checkbox", id: "raw-pre" });
  const edge = el("select", { "aria-label": "Largest side" }, ...[64, 128, 256, 512].map((v) => el("option", { value: v, textContent: `${v} px`, selected: v === 128 })));
  const outFacts = el("div", { className: "lab-out", role: "status", "aria-live": "polite" });
  const view = el("div", { className: "raw-view" });
  const probe = el("div", { className: "raw-probe", role: "status", "aria-live": "polite", textContent: "Move over the pixels to read their values." });
  let bytes = null, meta = null;

  const sample = (x, y) => {                       // the real values at one pixel, as stored
    const i = info(meta.format), o = y * meta.stride + x * i.channels * i.bytes, vals = [];
    for (let c = 0; c < i.channels; c++) vals.push(i.bytes === 1 ? bytes[o + c] : bytes[o + c * 2] | (bytes[o + c * 2 + 1] << 8));   // 16-bit is little-endian on this server
    return vals;
  };
  const to8 = (v, b) => (b === 1 ? v : Math.round(v / 257));
  const names = (f) => ({ gray8: ["gray"], grayAlpha8: ["gray", "alpha"], rgb8: ["R", "G", "B"], rgba8: ["R", "G", "B", "A"] })[f.replace("16", "8")];

  function draw() {
    const i = info(meta.format), { width: w, height: h } = meta;
    const make = (pick) => {
      const c = el("canvas", { width: w, height: h, className: "raw-canvas" }), g = c.getContext("2d"), img = g.createImageData(w, h);
      for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) { const v = sample(x, y), [r, gg, b, a] = pick(v), k = (y * w + x) * 4; img.data.set([r, gg, b, a], k); }
      g.putImageData(img, 0, 0); return c;
    };
    const full = (v) => {
      const e = (n) => to8(n, i.bytes);
      if (i.gray) return [e(v[0]), e(v[0]), e(v[0]), i.alpha ? e(v[1]) : 255];
      return [e(v[0]), e(v[1]), e(v[2]), i.alpha ? e(v[3]) : 255];
    };
    const main = make(full); main.setAttribute("aria-label", "The raw pixels as an image"); main.classList.add("raw-main");
    const chan = names(meta.format).map((n, c) => { const cv = make((v) => { const g = to8(v[c], i.bytes); return [g, g, g, 255]; }); cv.setAttribute("aria-label", `${n} channel`); return el("figure", {}, cv, el("figcaption", { textContent: n })); });
    main.onmousemove = (e) => {
      const r = main.getBoundingClientRect(), x = Math.min(w - 1, Math.floor(((e.clientX - r.left) / r.width) * w)), y = Math.min(h - 1, Math.floor(((e.clientY - r.top) / r.height) * h));
      const v = sample(x, y);
      probe.textContent = `(${x}, ${y})  ` + names(meta.format).map((n, c) => `${n} ${v[c]}${i.bytes === 2 ? ` (0x${v[c].toString(16).padStart(4, "0")})` : ""}`).join("  ·  ");
    };
    view.replaceChildren(main, probe, el("div", { className: "raw-chans" }, ...chan));
  }

  const run = el("button", { type: "button", className: "btn", textContent: "Read pixels" });
  run.onclick = async () => {
    if (!ctx.hasInput()) { outFacts.replaceChildren(el("p", { className: "muted", textContent: "Open an image in the Playground first. Raw pixels are read from the current pipeline." })); return; }
    run.disabled = true;
    try {
      const res = await fetch("/api/raw/output", { method: "POST", body: JSON.stringify({ uploadId: ctx.uploadId(), recipe: ctx.recipe(), format: fmt.value, premultiplied: pre.checked, maxEdge: Number(edge.value), page: state.page || null, assets: state.assets }) });
      if (!res.ok) throw await apiError(res);
      bytes = new Uint8Array(await res.arrayBuffer());
      const h = (n) => res.headers.get(n);
      meta = { width: +h("x-raw-width"), height: +h("x-raw-height"), format: h("x-raw-format"), channels: +h("x-raw-channels"), bits: +h("x-raw-bit-depth"), stride: +h("x-raw-row-stride"), premultiplied: h("x-raw-premultiplied") === "true", bytes: +h("x-raw-bytes") };
      outFacts.replaceChildren(rows([
        ["Size", `${meta.width} × ${meta.height}`], ["Format", `${meta.format}: ${meta.channels} channel${meta.channels > 1 ? "s" : ""} of ${meta.bits} bits`],
        ["Row stride", `${meta.stride} bytes (${meta.width} × ${meta.channels * meta.bits / 8})`], ["Total", fmtBytes(meta.bytes)],
        ["Alpha", info(meta.format).alpha ? (meta.premultiplied ? "present, premultiplied" : "present, straight (not premultiplied)") : "none: transparent areas were flattened onto white"],
        ["Byte order", meta.bits === 16 ? "16-bit values are little-endian here (the server's native order)" : "one byte per channel"],
      ]));
      probe.textContent = "Move over the pixels to read their values.";
      draw();
    } catch (e) { outFacts.replaceChildren(el("p", { className: "status error", textContent: e.message })); view.replaceChildren(); }
    run.disabled = false;
  };

  // ---- B. raw input
  const inFmt = el("select", { "aria-label": "Declared format" }, ...FORMATS.map(([f]) => el("option", { value: f, textContent: f, selected: f === "rgba8" })));
  const pad = el("input", { type: "checkbox", id: "raw-pad" });
  const inPre = el("input", { type: "checkbox", id: "raw-inpre" });
  const inOut = el("div", { className: "lab-out", role: "status", "aria-live": "polite" });
  const GRID = 16;

  /** A known colour grid in the chosen layout, so what comes back can be checked against what went in. */
  function makeGrid(format, padding) {
    const i = info(format), rowBytes = GRID * i.channels * i.bytes, stride = rowBytes + (padding ? 8 : 0), data = new Uint8Array(stride * GRID - (padding ? 8 : 0));
    const max = i.bytes === 1 ? 255 : 65535;
    for (let y = 0; y < GRID; y++) for (let x = 0; x < GRID; x++) {
      const px = [Math.round((x / (GRID - 1)) * max), Math.round((y / (GRID - 1)) * max), Math.round(max / 2), Math.round(max * (x >= GRID / 2 && y >= GRID / 2 ? 0.4 : 1))];
      const chans = i.gray ? [px[0]] : px.slice(0, 3);
      if (i.alpha) chans.push(px[3]);
      chans.forEach((v, c) => { const o = y * stride + (x * i.channels + c) * i.bytes; if (i.bytes === 1) data[o] = v; else { data[o] = v & 255; data[o + 1] = v >> 8; } });
    }
    return { data, stride, width: GRID, height: GRID };
  }
  async function send(label, { format, data, stride, width, height, explicitStride }) {
    const q = new URLSearchParams({ width, height, format });
    if (explicitStride) q.set("stride", stride);
    if (inPre.checked) q.set("premultiplied", "true");
    const res = await fetch(`/api/raw/input?${q}`, { method: "POST", body: data });
    if (!res.ok) { inOut.replaceChildren(el("p", { className: "status error" }, el("strong", { textContent: `${label}: ${res.status} ` }), (await apiError(res)).message), el("p", { className: "muted", textContent: "The library checks the declared layout against the number of bytes and refuses a mismatch instead of guessing." })); return; }
    const blob = await res.blob(), url = URL.createObjectURL(blob);
    const img = el("img", { className: "raw-input-img", src: url, alt: "The declared raw pixels, shown as a PNG" });
    inOut.replaceChildren(el("div", { className: "raw-compare" }, el("figure", {}, img, el("figcaption", { textContent: `${width} × ${height} as ${format}` }))),
      rows([["Sent", `${fmtBytes(data.length)} (${width} × ${height}, stride ${stride}${explicitStride ? " declared" : ", implied"})`], ["Alpha", info(format).alpha ? (inPre.checked ? "declared premultiplied" : "declared straight") : "none"],
        ["Read back in the same layout", res.headers.get("x-raw-roundtrip") === "exact" ? "exact: every pixel byte equals what was sent" : res.headers.get("x-raw-roundtrip")]]));
  }
  const ok = el("button", { type: "button", className: "btn", textContent: "Send the grid" });
  ok.onclick = async () => { const g = makeGrid(inFmt.value, pad.checked); await send("Grid", { format: inFmt.value, ...g, explicitStride: pad.checked }); };
  const short = el("button", { type: "button", className: "btn", textContent: "One byte short" });
  short.onclick = async () => { const g = makeGrid(inFmt.value, pad.checked); await send("One byte short", { format: inFmt.value, ...g, data: g.data.slice(0, g.data.length - 1), explicitStride: pad.checked }); };
  const wrong = el("button", { type: "button", className: "btn", textContent: "Wrong format declared" });
  wrong.onclick = async () => { const g = makeGrid("rgba8", false); await send("Wrong format", { format: "rgb8", ...g }); };

  container.replaceChildren(el("div", { className: "lab-grid" },
    el("section", { className: "lab-card" }, el("h2", { textContent: "Raw output" }),
      el("p", { className: "muted", textContent: "The current pipeline's pixels exactly as Hokusai hands them over, with the layout, bit depth, row stride and alpha convention it reports. The picture, the channel previews and the pixel values are all drawn from those bytes. Statistics such as histograms are not part of the library and are not shown." }),
      el("div", { className: "lab-actions wrap" }, fmt, edge, el("label", { htmlFor: "raw-pre" }, pre, " premultiplied"), run), outFacts, view),
    el("section", { className: "lab-card" }, el("h2", { textContent: "Raw input" }),
      el("p", { className: "muted", textContent: "Declares a small generated colour grid as raw pixels: you choose the layout, the browser builds the bytes, the server turns them into an image and reads them back in the same layout to prove nothing was reinterpreted. Wrong declarations are rejected with the library's own message." }),
      el("div", { className: "lab-actions wrap" }, inFmt, el("label", { htmlFor: "raw-pad" }, pad, " 8 bytes of row padding"), el("label", { htmlFor: "raw-inpre" }, inPre, " premultiplied")),
      el("div", { className: "lab-actions wrap" }, ok, short, wrong), inOut)));
  return { show() {} };
}

// ------------------------------------------------------------------ pages
export function initPages(container, ctx) {
  const state = ctx.state;
  const body = el("div", { className: "lab-out", role: "status", "aria-live": "polite" });
  container.replaceChildren(el("div", { className: "lab-grid" }, el("section", { className: "lab-card wide" }, el("h2", { textContent: "Pages and frames" }),
    el("p", { className: "muted", textContent: "Some inputs hold more than one image: PDF pages, animated GIF frames, multi-page TIFFs. Hokusai reads one at a time, chosen by a zero-based index. It does not edit a multi-frame image as a whole and does not encode animations. Open “Three-page PDF” or “Animated GIF” from the sample menu to try it." }),
    body)));
  let rev = 0;

  async function show() {
    if (!ctx.hasInput()) { body.replaceChildren(el("p", { className: "muted", textContent: "Open an image in the Playground first." })); return; }
    if (state.recipe.source) { body.replaceChildren(el("p", { className: "muted", textContent: "A generated image is one page: there is no file with pages or frames. Open an image or a PDF to see them." })); return; }
    const mine = ++rev;
    try {
      const res = await fetch("/api/inspect", { method: "POST", body: JSON.stringify({ uploadId: ctx.uploadId(), page: state.page || null, assets: state.assets }) });
      if (!res.ok) throw await apiError(res);
      const { source: f } = await res.json(); if (mine !== rev) return;
      const count = f.pages;
      const selector = el("div", { className: "seg", role: "group", "aria-label": "Page" });
      for (let i = 0; i < count && i < 24; i++) {
        const b = el("button", { type: "button", textContent: f.animated ? `Frame ${i + 1}` : `Page ${i + 1}`, className: i === (state.page || 0) ? "on" : "", title: `API index ${i}` });
        b.setAttribute("aria-pressed", i === (state.page || 0)); b.onclick = () => { ctx.setPage(i); show(); }; selector.append(b);
      }
      const delays = f.frameDelaysMs ? f.frameDelaysMs.map((d) => `${d} ms`).join(", ") : null;
      const facts = rows([
        ["Kind", count <= 1 ? "a single image" : f.animated ? `an animation of ${count} frames` : `a document of ${count} pages`],
        ["Selected", `${f.animated ? "frame" : "page"} ${(state.page || 0) + 1} of ${count}, API index ${state.page || 0} (zero-based)`],
        ["Size of this page", `${f.width} × ${f.height}`],
        ...(delays ? [["Frame delays", delays], ["Loop count", f.loopCount === 0 ? "forever" : String(f.loopCount)]] : []),
        ["Format", f.format ?? "unknown"],
      ]);
      const thumbs = el("div", { className: "page-thumbs" });
      body.replaceChildren(count > 1 ? selector : "", facts, el("p", { className: "muted", textContent: count > 1 ? "Selecting a page applies to the whole playground: its preview, inspection and export now use this page of the input. Page count and animation are different things: a PDF has pages, a GIF has frames with delays, and this API treats both as an index." : "This input has one image, so there is nothing to select." }), thumbs);
      // Small thumbnails, one at a time so the server's queue is never flooded.
      for (let i = 0; i < count && i < 12; i++) {
        const r = await fetch("/api/render", { method: "POST", body: JSON.stringify({ uploadId: ctx.uploadId(), page: i, recipe: { version: 1, steps: [{ op: "resize", params: { width: 140, fit: "inside" } }], output: { format: "png" } } }) });
        if (mine !== rev) return;
        if (r.ok) thumbs.append(el("figure", {}, el("img", { src: URL.createObjectURL(await r.blob()), alt: `${f.animated ? "Frame" : "Page"} ${i + 1}`, className: "raw-thumb" }), el("figcaption", { textContent: `${i + 1}` })));
      }
    } catch (e) { if (mine === rev) body.replaceChildren(el("p", { className: "status error", textContent: e.message })); }
  }
  return { show };
}

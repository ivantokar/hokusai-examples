// One UI for every backend. The server owns image processing; this file only edits a recipe,
// asks the server to render it, and shows the result. No framework, no build step.
import { initLab } from "./lab.js";
import { initExport } from "./export.js";
import { initRaw, initPages } from "./raw-pages.js";
import { el, clone, uid, fmtBytes, apiError, field, identityMatrix } from "./ui.js";

const $ = (id) => document.getElementById(id);

const PREVIEW_EDGE = 1280;
const DEBOUNCE_MS = 160;

const state = {
  catalog: null, backend: null,
  upload: null,            // { uploadId, width, height, orientedWidth, orientedHeight, bytes, format, name }
  originalBlob: null, originalUrl: null,
  recipe: { version: 1, name: null, steps: [], output: { format: "webp", options: {} } },
  selected: null,
  revision: 0,             // bumps on every recipe edit; only the newest revision may update the UI
  history: [], future: [],
  full: false,             // render the result at its real size instead of fitting the preview
  view: "result", lastGood: null, resultUrl: null,
  section: "playground", assets: {}, page: 0, itab: "metadata", target: "core", tab: "swift", codeText: "", facts: {},
};

const ops = () => new Map(state.catalog.operations.map((o) => [o.id, o]));

// ---------- status ----------
function setStatus(text, kind = "") {
  const s = $("status");
  s.className = "status" + (kind ? " " + kind : "");
  s.replaceChildren(...(kind === "error" ? [el("span", { className: "tag", textContent: "Error" }), text] : [text]));
}

// ---------- backend ----------
async function connect() {
  try {
    const [backend, catalog] = await Promise.all([fetch("/api/backend").then((r) => r.json()), fetch("/api/catalog").then((r) => r.json())]);
    state.backend = backend; state.catalog = catalog;
    document.querySelector("#backend .dot").dataset.state = "ok";
    $("backend-text").textContent = `${backend.backend} · Hokusai ${backend.hokusai}`;
    document.title = `Hokusai examples · ${backend.backend}`;
  } catch {
    document.querySelector("#backend .dot").dataset.state = "down";
    $("backend-text").textContent = "Backend not reachable";
    setStatus("The server did not answer. Start it with docker compose up vapor (or hummingbird) and reload.", "error");
    throw new Error("backend unreachable");
  }
}

// ---------- input ----------
async function openBlob(blob, name) {
  setStatus("Uploading…");
  try {
    const res = await fetch("/api/uploads", { method: "POST", body: blob });
    if (!res.ok) throw await apiError(res);
    state.upload = { ...(await res.json()), name }; state.page = 0;
    state.originalBlob = blob;
    if (state.originalUrl) URL.revokeObjectURL(state.originalUrl);
    state.originalUrl = URL.createObjectURL(blob);
    $("empty-state").hidden = true;
    for (const id of ["export", "accurate"]) $(id).disabled = false;
    $("reset").disabled = false;
    setStatus(`${name}: ${state.upload.orientedWidth} × ${state.upload.orientedHeight}, ${fmtBytes(state.upload.bytes)}`);
    changed(false);
  } catch (e) {
    setStatus(e.message || "Could not open that image.", "error");
  }
}


async function openSample(name) {
  const blob = await fetch(`/samples/${name}`).then((r) => r.blob());
  await openBlob(blob, name);
}

// ---------- recipe editing (undo / redo) ----------
function edit(mutator) {
  state.history.push(clone(state.recipe)); if (state.history.length > 100) state.history.shift();
  state.future = [];
  mutator(state.recipe);
  changed(true);
}
function undo() { if (!state.history.length) return; state.future.push(clone(state.recipe)); state.recipe = state.history.pop(); fixSelection(); changed(true); }
function redo() { if (!state.future.length) return; state.history.push(clone(state.recipe)); state.recipe = state.future.pop(); fixSelection(); changed(true); }
function fixSelection() { if (!state.recipe.steps.some((s) => s.id === state.selected)) state.selected = null; syncCropButton(); }

function changed(rerenderPanels) {
  state.revision++; fixSelection();
  $("undo").disabled = !state.history.length; $("redo").disabled = !state.future.length;
  if (rerenderPanels) { drawSteps(); drawSettings(); drawOutput(); }
  else { drawSteps(); drawOutput(); }
  scheduleRender(); scheduleCode(); scheduleCropBase(); scheduleInspect();
}

// ---------- pipeline list ----------
function drawSteps() {
  const list = $("steps"); const o = ops();
  $("steps-empty").hidden = state.recipe.steps.length > 0;
  list.replaceChildren(...state.recipe.steps.map((step, i) => {
    const spec = o.get(step.op);
    const li = el("li", { className: "step" + (step.enabled ? "" : " off"), draggable: true });
    li.dataset.id = step.id;
    if (step.id === state.selected) li.setAttribute("aria-current", "true");
    const name = el("button", { className: "name", type: "button", textContent: spec.title });
    name.setAttribute("aria-label", `Step ${i + 1}: ${spec.title}${step.enabled ? "" : " (disabled)"}`);
    name.onclick = () => select(step.id);
    name.onkeydown = (e) => {
      if (e.altKey && e.key === "ArrowUp") { e.preventDefault(); move(step.id, -1); }
      else if (e.altKey && e.key === "ArrowDown") { e.preventDefault(); move(step.id, +1); }
      else if (e.key === "Delete" || e.key === "Backspace") { e.preventDefault(); remove(step.id); }
    };
    const btn = (label, title, fn, disabled = false) => { const b = el("button", { type: "button", className: "mini", textContent: label, title, disabled }); b.setAttribute("aria-label", `${title}: ${spec.title}`); b.onclick = (e) => { e.stopPropagation(); fn(); }; return b; };
    li.append(el("span", { className: "num", textContent: String(i + 1) }), name,
      btn(step.enabled ? "●" : "○", step.enabled ? "Disable" : "Enable", () => edit((r) => { const s = r.steps.find((x) => x.id === step.id); s.enabled = !s.enabled; })),
      btn("↑", "Move up", () => move(step.id, -1), i === 0), btn("↓", "Move down", () => move(step.id, +1), i === state.recipe.steps.length - 1),
      btn("⧉", "Duplicate", () => duplicate(step.id)), btn("✕", "Remove", () => remove(step.id)));
    li.ondragstart = (e) => { e.dataTransfer.setData("text/plain", step.id); e.dataTransfer.effectAllowed = "move"; };
    li.ondragover = (e) => { e.preventDefault(); li.classList.add("over"); };
    li.ondragleave = () => li.classList.remove("over");
    li.ondrop = (e) => { e.preventDefault(); li.classList.remove("over"); const from = e.dataTransfer.getData("text/plain"); if (from && from !== step.id) moveTo(from, i); };
    return li;
  }));
}
function select(id) {
  state.selected = id; drawSteps(); drawSettings(); syncCropButton();
  if (selectedCrop()) { setView("crop"); ensureCropBase(); }
}
function move(id, delta) { const i = state.recipe.steps.findIndex((s) => s.id === id); const j = i + delta; if (j < 0 || j >= state.recipe.steps.length) return; moveTo(id, j); }
function moveTo(id, j) { edit((r) => { const i = r.steps.findIndex((s) => s.id === id); const [s] = r.steps.splice(i, 1); r.steps.splice(j, 0, s); }); focusStep(id); }
function duplicate(id) { const copy = uid(); edit((r) => { const i = r.steps.findIndex((s) => s.id === id); r.steps.splice(i + 1, 0, { ...clone(r.steps[i]), id: copy }); }); state.selected = copy; drawSteps(); drawSettings(); }
function remove(id) { edit((r) => { r.steps = r.steps.filter((s) => s.id !== id); }); fixSelection(); drawSteps(); drawSettings(); }
function focusStep(id) { document.querySelector(`.step[data-id="${CSS.escape(id)}"] .name`)?.focus(); }

// ---------- add menu ----------
function drawAddList(filter = "") {
  const list = $("add-list"); const q = filter.trim().toLowerCase();
  const groups = { geometry: "Geometry", effects: "Effects", color: "Colour", composition: "Composition" };
  const items = [];
  for (const [key, title] of Object.entries(groups)) {
    const matches = state.catalog.operations.filter((o) => o.group === key && (!q || (o.title + " " + o.api + " " + o.summary).toLowerCase().includes(q)));
    if (!matches.length) continue;
    items.push(el("li", { className: "group", textContent: title }));
    for (const spec of matches) {
      const b = el("button", { type: "button" }, spec.title, el("small", { textContent: spec.summary }));
      b.onclick = () => addStep(spec.id);
      items.push(el("li", {}, b));
    }
  }
  if (!items.length) items.push(el("li", { className: "group", textContent: "Nothing matches" }));
  list.replaceChildren(...items);
}
function addStep(opId) {
  const id = uid();
  if (opId === "crop") crop.fresh.add(id);
  edit((r) => { r.steps.push({ id, op: opId, enabled: true, params: {} }); });
  $("add-list").hidden = true; $("add-search").value = "";
  select(id);
}

// ---------- settings ----------
function drawSettings() {
  const box = $("settings"); const step = state.recipe.steps.find((s) => s.id === state.selected);
  if (!step) { $("settings-title").textContent = "Settings"; box.replaceChildren(el("p", { className: "empty", textContent: "Select a step to edit it." })); return; }
  const spec = ops().get(step.op);
  $("settings-title").textContent = spec.title;
  const common = spec.params.filter((p) => !p.advanced), adv = spec.params.filter((p) => p.advanced);
  const nodes = [el("p", { className: "api", textContent: spec.api })];
  if (spec.previewNote) nodes.push(el("p", { className: "note", textContent: spec.previewNote }));
  const context = { siblings: spec.params, setMany: (values) => { setParams(step.id, values); drawSettings(); } };
  const control = (p) => field(p, step.params, (v) => {
    // A kernel's grid follows its size: choosing another size starts a new identity grid of that size.
    const followers = spec.params.filter((q) => q.matrix?.columnsFrom === p.name);
    if (followers.length) { context.setMany({ [p.name]: v, ...Object.fromEntries(followers.map((q) => [q.name, identityMatrix(Number(v))])) }); return; }
    setParam(step.id, p, v);
    if (p.name === "asset") drawSettings();
  }, context);
  nodes.push(...common.map(control));
  if (adv.length) nodes.push(el("details", { className: "adv" }, el("summary", { textContent: "Advanced" }), ...adv.map(control)));
  if (step.op === "crop") nodes.push(cropControls(step));
  if ((step.op === "layer" || step.op === "mask") && (step.params.asset ?? "") === "second") nodes.push(secondImageControl());
  if (spec.params.length) { const r = el("button", { type: "button", className: "btn small", textContent: "Reset to defaults" }); r.onclick = () => { edit((rr) => { rr.steps.find((s) => s.id === step.id).params = {}; }); drawSettings(); }; nodes.push(r); }
  box.replaceChildren(...nodes);
}

let coalesce = null;
function setParam(stepId, p, value) {
  // Dragging a slider fires many events: they form one undo entry and are debounced for rendering.
  if (coalesce !== stepId + p.name) { state.history.push(clone(state.recipe)); state.future = []; coalesce = stepId + p.name; }
  clearTimeout(setParam.t); setParam.t = setTimeout(() => { coalesce = null; }, 600);
  const step = state.recipe.steps.find((s) => s.id === stepId);
  if (value === p.default) delete step.params[p.name]; else step.params[p.name] = value;
  changed(false);
}

// ---------- a second picture for layers and masks ----------
function secondImageControl() {
  const input = el("input", { type: "file", accept: "image/*", id: "second-file" });
  input.onchange = async () => {
    const file = input.files[0]; if (!file) return;
    try {
      const res = await fetch("/api/uploads", { method: "POST", body: file });
      if (!res.ok) throw await apiError(res);
      state.assets.second = (await res.json()).uploadId; state.secondName = file.name;
      drawSettings(); changed(false);
    } catch (e) { setStatus(e.message, "error"); }
  };
  return el("div", { className: "field" }, el("label", { htmlFor: "second-file" }, "Second image"),
    el("div", { className: "help", textContent: state.assets.second ? `Using ${state.secondName ?? "your second image"} (kept on the server for a few minutes).` : "Choose the picture to place. It is uploaded like the main image and forgotten after a while." }), input);
}

// ---------- output ----------
function setOutputParam(p, v) {
  if (coalesce !== "out" + p.name) { state.history.push(clone(state.recipe)); state.future = []; coalesce = "out" + p.name; }
  clearTimeout(setParam.t); setParam.t = setTimeout(() => { coalesce = null; }, 600);
  if (v === p.default) delete state.recipe.output.options[p.name]; else state.recipe.output.options[p.name] = v;
  changed(false);
}

function drawOutput() {
  const out = state.recipe.output; const spec = state.catalog.outputs.find((o) => o.format === out.format);
  const sel = el("select", { id: "fmt", "aria-label": "Format" }, ...state.catalog.outputs.map((o) => el("option", { value: o.format, textContent: o.title + (o.available ? "" : " (not in this runtime)"), disabled: !o.available, selected: o.format === out.format })));
  sel.onchange = () => edit((r) => { r.output = { format: sel.value, options: {} }; });
  const fields = spec.params.map((p) => field(p, out.options, (v) => setOutputParam(p, v)));
  const keep = document.activeElement?.closest?.("#output");
  if (keep && document.activeElement.tagName !== "SELECT") return;     // do not rebuild a control the user is dragging
  $("output").replaceChildren(el("div", { className: "field" }, sel), ...fields);
}

// ---------- rendering ----------
let renderTimer = null, inflight = null;
function scheduleRender() {
  clearTimeout(renderTimer);
  if (!state.upload) return;
  $("updating").hidden = false;
  renderTimer = setTimeout(render, DEBOUNCE_MS);
}

async function render(retry = true) {
  const rev = state.revision; inflight?.abort(); inflight = new AbortController();
  const started = performance.now();
  try {
    const body = { uploadId: state.upload.uploadId, recipe: recipeForServer(), previewMaxEdge: state.full ? null : PREVIEW_EDGE, viewable: true, page: state.page || null, assets: state.assets };
    const res = await fetch("/api/render", { method: "POST", body: JSON.stringify(body), signal: inflight.signal });
    if (!res.ok) throw await apiError(res);
    const blob = await res.blob();
    if (rev !== state.revision) return;                                   // a newer edit exists: drop this answer
    const url = URL.createObjectURL(blob);
    if (state.resultUrl) URL.revokeObjectURL(state.resultUrl);
    state.resultUrl = url;
    const h = (n) => res.headers.get(n);
    state.lastGood = { width: +h("x-hokusai-width"), height: +h("x-hokusai-height"), bytes: blob.size, mime: blob.type, server: parseFloat((h("server-timing") || "").split("dur=")[1]), request: performance.now() - started, backend: h("x-hokusai-backend"), full: state.full,
      // When the browser cannot show the encoded format the server sends a PNG decoded from the real bytes; the real file is what Export gives.
      proxyOf: h("x-hokusai-proxy-of"), realBytes: +h("x-hokusai-bytes"), pdfPages: h("x-hokusai-pdf-pages"), pdfSize: h("x-hokusai-pdf-width") ? `${(+h("x-hokusai-pdf-width")).toFixed(0)} × ${(+h("x-hokusai-pdf-height")).toFixed(0)} pt` : null };
    showImage(); $("updating").hidden = true;
    const f = state.lastGood;
    if (f.proxyOf) setStatus(`Viewable proxy (PNG decoded from the real ${f.proxyOf}${f.pdfPages ? `, page 1 of ${f.pdfPages}, ${f.pdfSize}` : ""}) · the real file is ${fmtBytes(f.realBytes)}${f.full ? "" : " at preview size"}`);
    else setStatus(`${f.full ? "Full size" : "Preview"} ${f.width} × ${f.height} · ${fmtBytes(f.bytes)}${f.full ? "" : " (preview, not the export size)"}`);
    drawFacts();
  } catch (e) {
    if (e.name === "AbortError" || rev !== state.revision) return;
    if (e.code === "expiredUpload" && retry && state.originalBlob) {      // re-bind the original, then try once more
      try { const r = await fetch("/api/uploads", { method: "POST", body: state.originalBlob }); state.upload = { ...state.upload, ...(await r.json()) }; return render(false); } catch { /* fall through */ }
    }
    $("updating").hidden = true;
    setStatus(`${e.message}${state.lastGood ? " The image shown is the last good result, not this edit." : ""}`, "error");
  }
}
// What goes to the server: every step as written, disabled ones included so the order survives round trips.
function recipeForServer() { return clone(state.recipe); }

function showImage() {
  const img = $("image"), wrap = $("imgwrap");
  const src = state.view === "original" ? state.originalUrl : state.view === "crop" ? crop.base?.url : state.resultUrl;
  if (!src) { wrap.hidden = true; return; }
  if (img.getAttribute("src") !== src) img.src = src;
  wrap.hidden = false;
  img.alt = state.view === "original" ? "Original image" : state.view === "crop" ? "The image entering the crop step" : "Result of the current pipeline";
  const natural = state.view === "result" && state.lastGood ? state.lastGood.width : state.view === "crop" && crop.base ? crop.base.w : null;
  img.style.width = state.zoom100 && natural ? natural + "px" : "";
  drawCrop();
}

// ---------- code ----------
let codeTimer = null, codeRev = 0;
function scheduleCode() { clearTimeout(codeTimer); codeTimer = setTimeout(loadCode, 200); }
async function loadCode() {
  const rev = ++codeRev;
  try {
    const res = await fetch("/api/code", { method: "POST", body: JSON.stringify({ recipe: state.recipe, target: state.target, uploadId: state.upload?.uploadId ?? null, page: state.page || null, assets: state.assets }) });
    if (!res.ok) throw await apiError(res);
    const { code } = await res.json(); if (rev !== codeRev) return;
    state.codeText = code; drawCode();
  } catch (e) { if (rev === codeRev) { state.codeText = `// ${e.message}`; drawCode(); } }
}
function curlText() {
  const origin = location.origin;
  return `# 1. Upload the original once; the server keeps it for a few minutes and returns an id.\ncurl -s --data-binary @input.jpg ${origin}/api/uploads\n\n# 2. Render the recipe against that id (the output below is exactly what Export downloads).\ncurl -s -X POST ${origin}/api/render \\\n  -d '${JSON.stringify({ uploadId: "<id from step 1>", recipe: state.recipe }).replaceAll("'", "'\\''")}' \\\n  -o result.${state.catalog.outputs.find((o) => o.format === state.recipe.output.format).fileExtension}\n\n# The minimal integration, without the demo API:\ncurl --data-binary @input.jpg '${origin}/api/minimal/resize?width=800' -o small.webp\n`;
}
function drawCode() {
  const showCode = state.tab === "swift" || state.tab === "curl";
  $("code").hidden = !showCode; $("facts").hidden = showCode; $("targets").hidden = state.tab !== "swift"; $("copy").hidden = !showCode;
  $("code").textContent = state.tab === "curl" ? curlText() : state.codeText;
}
function drawFacts() {
  const f = state.lastGood, u = state.upload; if (!f || !u) return;
  const rows = [
    ["Backend", `${state.backend.backend} (Hokusai ${state.backend.hokusai})`],
    ["Source", `${u.width} × ${u.height} stored · ${u.orientedWidth} × ${u.orientedHeight} upright · ${u.format ?? "?"} · ${fmtBytes(u.bytes)}`],
    [f.proxyOf ? "Proxy shown" : f.full ? "Result (full size)" : "Preview", `${f.width} × ${f.height} · ${fmtBytes(f.bytes)}${f.proxyOf ? ` (a PNG standing in for ${f.proxyOf})` : ""}`],
    ...(f.proxyOf ? [["Real encoded file", `${fmtBytes(f.realBytes)}${f.pdfPages ? ` · ${f.pdfPages} page(s), ${f.pdfSize}` : ""}`]] : []),
    ["Server work", isNaN(f.server) ? "n/a" : `${f.server.toFixed(0)} ms (evaluate + encode)`],
    ["Request total", `${f.request.toFixed(0)} ms (includes network and queueing)`],
    ["Output", `${f.mime} · ${f.full ? "this is the export size" : "Press Full size or Export for the real size and bytes"}`],
  ];
  $("facts").replaceChildren(...rows.flatMap(([k, v]) => [el("dt", { textContent: k }), el("dd", { textContent: v })]));
}

// ---------- export ----------
async function doExport() {
  setStatus("Rendering the export from the original…");
  try {
    const res = await fetch("/api/render", { method: "POST", body: JSON.stringify({ uploadId: state.upload.uploadId, recipe: state.recipe, page: state.page || null, assets: state.assets }) });
    if (!res.ok) throw await apiError(res);
    const blob = await res.blob(); const spec = state.catalog.outputs.find((o) => o.format === state.recipe.output.format);
    const base = (state.upload.name || "image").replace(/\.[^.]+$/, "");
    const a = el("a", { href: URL.createObjectURL(blob), download: `${base}-hokusai.${spec.fileExtension}` }); a.click(); setTimeout(() => URL.revokeObjectURL(a.href), 4000);
    setStatus(`Exported ${res.headers.get("x-hokusai-width")} × ${res.headers.get("x-hokusai-height")} · ${fmtBytes(blob.size)} ${spec.title}`);
  } catch (e) { setStatus(e.message, "error"); }
}

// ---------- helpers & wiring ----------

function loadPreset(id) {
  const p = state.catalog.presets.find((x) => x.id === id); if (!p) return;
  const apply = () => edit((r) => { const rec = clone(p.recipe); rec.steps = rec.steps.map((s) => ({ ...s, id: uid(), enabled: s.enabled ?? true, params: s.params ?? {} })); Object.assign(r, rec); });
  const go = () => { apply(); state.selected = state.recipe.steps[0]?.id ?? null; drawSteps(); drawSettings(); };
  if (!state.upload || state.upload.name !== p.sample && !state.upload.custom) openSample(p.sample).then(go); else go();
}

function wire() {
  $("file").onchange = (e) => { const f = e.target.files[0]; if (f) openBlob(f, f.name).then(() => { state.upload && (state.upload.custom = true); }); e.target.value = ""; };
  for (const s of state.catalog.samples) {
    $("sample").append(el("option", { value: s.name, textContent: s.title }));
    const b = el("button", { type: "button", className: "btn", textContent: s.title }); b.onclick = () => openSample(s.name); $("empty-samples").append(b);
  }
  $("sample").onchange = (e) => { if (e.target.value) openSample(e.target.value); e.target.value = ""; };
  for (const p of state.catalog.presets) $("preset").append(el("option", { value: p.id, textContent: p.title }));
  $("preset").onchange = (e) => { if (e.target.value) loadPreset(e.target.value); e.target.value = ""; };
  $("nav-recipes").onclick = () => $("preset").focus();
  $("undo").onclick = undo; $("redo").onclick = redo;
  $("reset").onclick = () => edit((r) => { r.steps = []; r.output = { format: "webp", options: {} }; });
  $("export").onclick = doExport;
  $("accurate").onclick = () => { state.full = !state.full; $("accurate").textContent = state.full ? "Fit preview" : "Full size"; changed(false); };
  $("show-result").onclick = () => setView("result"); $("show-original").onclick = () => setView("original"); $("show-crop").onclick = () => setView("crop");
  $("nav-play").onclick = () => setSection("playground");
  for (const b of document.querySelectorAll("#inspect-tabs button")) b.onclick = () => setInspectTab(b.dataset.itab); $("nav-inspect").onclick = () => setSection("inspect"); $("nav-lab").onclick = () => setSection("lab"); $("nav-export").onclick = () => setSection("export");
  $("image").addEventListener("load", drawCrop); window.addEventListener("resize", drawCrop);
  wireCrop();
  const zoom = (z) => { state.zoom100 = z; $("canvas").classList.toggle("actual", z); $("zoom-fit").classList.toggle("on", !z); $("zoom-100").classList.toggle("on", z); $("zoom-fit").setAttribute("aria-pressed", !z); $("zoom-100").setAttribute("aria-pressed", z); showImage(); };
  $("zoom-fit").onclick = () => zoom(false); $("zoom-100").onclick = () => zoom(true);
  const search = $("add-search");
  search.onfocus = () => { drawAddList(search.value); $("add-list").hidden = false; };
  search.oninput = () => { drawAddList(search.value); $("add-list").hidden = false; };
  search.onkeydown = (e) => { if (e.key === "Escape") { $("add-list").hidden = true; } if (e.key === "ArrowDown") { $("add-list").querySelector("button")?.focus(); e.preventDefault(); } };
  document.addEventListener("click", (e) => { if (!e.target.closest(".add")) $("add-list").hidden = true; });
  for (const t of document.querySelectorAll(".drawer-tabs [role=tab]")) t.onclick = () => { state.tab = t.dataset.tab; for (const x of document.querySelectorAll(".drawer-tabs [role=tab]")) x.setAttribute("aria-selected", x === t); drawCode(); };
  for (const target of state.catalog.targets) {
    const b = el("button", { type: "button", textContent: { core: "Core", vapor: "Vapor", hummingbird: "Hummingbird" }[target], className: target === state.target ? "on" : "" });
    b.onclick = () => { state.target = target; for (const x of $("targets").children) x.classList.toggle("on", x === b); loadCode(); };
    $("targets").append(b);
  }
  $("copy").onclick = async () => { try { await navigator.clipboard.writeText($("code").textContent); setStatus("Copied."); } catch { setStatus("Copy is not available here; select the code instead.", "error"); } };
  document.addEventListener("keydown", (e) => {
    if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "z" && !/INPUT|TEXTAREA/.test(document.activeElement.tagName)) { e.preventDefault(); e.shiftKey ? redo() : undo(); }
  });
  const canvas = $("canvas");
  canvas.ondragover = (e) => { e.preventDefault(); canvas.classList.add("drop"); };
  canvas.ondragleave = () => canvas.classList.remove("drop");
  canvas.ondrop = (e) => { e.preventDefault(); canvas.classList.remove("drop"); const f = e.dataTransfer.files[0]; if (f) openBlob(f, f.name); };
}

connect().then(() => { wire(); drawOutput(); drawSteps(); drawSettings(); loadCode(); drawCode(); }).catch(() => {});

// ---------- sections ----------
let lab = null, exportView = null, rawView = null, pagesView = null;
function setInspectTab(name) {
  state.itab = name;
  for (const b of document.querySelectorAll("#inspect-tabs button")) { const on = b.dataset.itab === name; b.classList.toggle("on", on); b.setAttribute("aria-pressed", on); }
  $("inspect-body").hidden = name !== "metadata"; $("raw-body").hidden = name !== "raw"; $("pages-body").hidden = name !== "pages";
  const ctx = { state, recipe: () => state.recipe, setPage: (p) => { state.page = p; changed(false); } };
  if (name === "metadata") loadInspect();
  if (name === "raw") { rawView ??= initRaw($("raw-body"), ctx); rawView.show(); }
  if (name === "pages") { pagesView ??= initPages($("pages-body"), ctx); pagesView.show(); }
}
function exportContext() {
  return {
    state,
    useFormat: (format) => edit((r) => { r.output = { format, options: {} }; }),
    setOutputParam,
    onUploadNeeded: () => state.upload,
    recipe: () => state.recipe,
  };
}
function setSection(name) {
  state.section = name;
  $("stage").hidden = name !== "playground"; $("inspect").hidden = name !== "inspect"; $("lab").hidden = name !== "lab"; $("export-view").hidden = name !== "export";
  if (name === "export") { exportView ??= initExport($("export-view"), exportContext()); exportView.show(); } else exportView?.hide();
  if (name === "lab") { lab ??= initLab($("lab")); lab.show(); } else lab?.hide();
  for (const [id, n] of [["nav-play", "playground"], ["nav-inspect", "inspect"], ["nav-lab", "lab"], ["nav-export", "export"]]) { $(id).classList.toggle("active", name === n); if (name === n) $(id).setAttribute("aria-current", "page"); else $(id).removeAttribute("aria-current"); }
  if (name === "inspect") setInspectTab(state.itab);
}

function setView(v) {
  state.view = v;
  for (const [id, n] of [["show-result", "result"], ["show-original", "original"], ["show-crop", "crop"]]) { $(id).classList.toggle("on", v === n); $(id).setAttribute("aria-pressed", v === n); }
  showImage();
  if (v === "crop") ensureCropBase();
}

// ---------- inspect ----------
let inspectTimer = null, inspectRev = 0;
function scheduleInspect() { if (state.section !== "inspect" || state.itab !== "metadata" || !state.upload) return; clearTimeout(inspectTimer); inspectTimer = setTimeout(loadInspect, 250); }
async function loadInspect() {
  if (!state.upload) { $("inspect-body").replaceChildren(el("p", { className: "empty", textContent: "Open an image to inspect it." })); return; }
  const rev = ++inspectRev;
  try {
    const res = await fetch("/api/inspect", { method: "POST", body: JSON.stringify({ uploadId: state.upload.uploadId, recipe: state.recipe, page: state.page || null, assets: state.assets }) });
    if (!res.ok) throw await apiError(res);
    const data = await res.json(); if (rev !== inspectRev) return;
    drawInspect(data);
  } catch (e) { if (rev === inspectRev) $("inspect-body").replaceChildren(el("p", { className: "status error", textContent: e.message })); }
}
function drawInspect({ source, output, outputFormat }) {
  const block = (name, src, out) => {
    const text = out == null ? (src ? `${src} B` : "absent") : (out ? `${out} B` : "absent");
    let pill = null;
    if (out != null) { if (src && !out) pill = ["removed", "removed"]; else if (src && out) pill = ["kept", "kept"]; else if (!src && out) pill = ["added", "added"]; }
    return [name, text, pill];
  };
  const rows = (f, other) => [
    ["Format", f.format ?? "unknown"],
    ["Stored size", `${f.width} × ${f.height}`],
    ["Upright size", `${f.orientedWidth} × ${f.orientedHeight}` + (f.orientedWidth !== f.width ? " (orientation swaps the sides)" : "")],
    ["Orientation tag", f.orientation == null ? "none" : String(f.orientation)],
    ["Colour", `${f.channels} channel${f.channels === 1 ? "" : "s"}${f.hasAlpha ? " including alpha" : ""}, ${f.interpretation}`],
    ["Samples", `${f.sampleFormat}${f.bitsPerSample ? `, ${f.bitsPerSample}-bit` : ""}${f.isPalette ? ", palette" : ""}`],
    ["Density", f.density ?? "none"],
    ["Pages", `${f.pages}${f.animated ? `, animated (${f.frames ?? "?"} frames)` : ""}`],
    ["File size", fmtBytes(f.bytes)],
    ...(f.progressive == null ? [] : [["Progressive", f.progressive ? "yes" : "no"]]),
    block("EXIF block", source.exifBytes, other ? f.exifBytes : null), block("ICC profile", source.iccBytes, other ? f.iccBytes : null),
    block("XMP", source.xmpBytes, other ? f.xmpBytes : null), block("IPTC", source.iptcBytes, other ? f.iptcBytes : null),
  ];
  const table = (title, f, other) => {
    const t = el("table", {}, el("caption", { textContent: title }));
    for (const [k, v, pill] of rows(f, other)) t.append(el("tr", {}, el("th", { scope: "row", textContent: k }), el("td", {}, v, ...(pill ? [el("span", { className: "pill " + pill[0], textContent: pill[1] })] : []))));
    return t;
  };
  $("inspect-body").replaceChildren(
    table(`Source: ${state.upload.name}`, source, false),
    table(`Exported output (${outputFormat}), encoded and read back`, output, true),
    el("p", { className: "note", textContent: "Orientation and density are stored inside an EXIF block, so a small EXIF block can remain while camera details are gone. An embedded ICC profile is not a colour conversion: the pixels are not changed by it. The right column is measured on the exported bytes, not inferred from the settings." }),
  );
}

// ---------- crop editor ----------
// The rectangle is edited on the image that ENTERS the crop step, rendered by the server with the steps before it,
// so its coordinates are exactly the ones the extract call receives, whatever rotate or resize came first.
const crop = { fresh: new Set(), base: null, rev: 0, ratioKey: "free", timer: null, drag: null, ctrl: null };
const RATIOS = { free: 0, "1:1": 1, "4:3": 4 / 3, "3:2": 3 / 2, "16:9": 16 / 9 };
const clamp = (v, lo, hi) => Math.min(Math.max(v, lo), hi);

function selectedCrop() { const s = state.recipe.steps.find((x) => x.id === state.selected); return s && s.op === "crop" ? s : null; }
function syncCropButton() { const c = selectedCrop(); $("show-crop").hidden = !c; if (!c && state.view === "crop") setView("result"); }
function cropRect(step) {
  const v = (n) => (n in step.params ? step.params[n] : ops().get("crop").params.find((p) => p.name === n).default);
  return { x: v("x"), y: v("y"), w: v("width"), h: v("height") };
}
function cropSignature(step) {
  const i = state.recipe.steps.findIndex((s) => s.id === step.id);
  return JSON.stringify([state.upload?.uploadId, step.id, state.recipe.steps.slice(0, i).filter((s) => s.enabled).map((s) => [s.op, s.params])]);
}
function scheduleCropBase() { if (!selectedCrop()) return; clearTimeout(crop.timer); crop.timer = setTimeout(ensureCropBase, 200); }
async function ensureCropBase() {
  const step = selectedCrop(); if (!step || !state.upload) return;
  const sig = cropSignature(step);
  if (crop.base?.sig === sig) { drawCrop(); return; }
  const rev = ++crop.rev; crop.ctrl?.abort(); crop.ctrl = new AbortController();
  try {
    const recipe = clone(state.recipe); recipe.output = { format: "webp", options: { quality: 90 } };
    const res = await fetch("/api/render", { method: "POST", signal: crop.ctrl.signal, body: JSON.stringify({ uploadId: state.upload.uploadId, recipe, stopBefore: step.id, page: state.page || null, assets: state.assets }) });
    if (!res.ok) throw await apiError(res);
    const blob = await res.blob(); if (rev !== crop.rev) return;
    if (crop.base?.url) URL.revokeObjectURL(crop.base.url);
    crop.base = { sig, url: URL.createObjectURL(blob), w: +res.headers.get("x-hokusai-width"), h: +res.headers.get("x-hokusai-height") };
    // A crop that was just added starts as the whole image entering it, so it is valid at once and the
    // handles have something to shrink. This only touches a step nobody has edited yet.
    if (crop.fresh.delete(step.id) && !Object.keys(step.params).length) {
      step.params = { width: crop.base.w, height: crop.base.h };
      changed(true);
    }
    showImage();
  } catch (e) { if (e.name !== "AbortError" && rev === crop.rev) { crop.base = null; setStatus(`Cannot show the image entering the crop: ${e.message}`, "error"); showImage(); } }
}

function drawCrop() {
  const box = $("crop"), step = selectedCrop(), img = $("image");
  if (state.view !== "crop" || !step || !crop.base || !img.clientWidth) { box.hidden = true; return; }
  const { x, y, w, h } = cropRect(step), W = crop.base.w, H = crop.base.h, k = img.clientWidth / W;
  const valid = x + w <= W && y + h <= H;
  const cx = clamp(x, 0, W), cy = clamp(y, 0, H), cw = clamp(w, 1, W - cx), ch = clamp(h, 1, H - cy);
  Object.assign(box.style, { left: cx * k + "px", top: cy * k + "px", width: cw * k + "px", height: ch * k + "px" });
  box.classList.toggle("invalid", !valid);
  box.hidden = false;
  if (!valid) setStatus(`The crop (${x}, ${y}, ${w} × ${h}) reaches outside the ${W} × ${H} image entering this step. It is not moved for you: edit the rectangle or an earlier step.`, "error");
  else setStatus(`Editing the crop on the ${W} × ${H} image entering this step: ${w} × ${h} at (${x}, ${y}).`);
}

function setParams(stepId, values) {
  const key = stepId + "/" + Object.keys(values).join(",");
  if (coalesce !== key) { state.history.push(clone(state.recipe)); state.future = []; coalesce = key; }
  clearTimeout(setParam.t); setParam.t = setTimeout(() => { coalesce = null; }, 600);
  const step = state.recipe.steps.find((s) => s.id === stepId), spec = ops().get(step.op);
  for (const [name, v] of Object.entries(values)) { const p = spec.params.find((q) => q.name === name); if (v === p.default) delete step.params[name]; else step.params[name] = v; }
  for (const input of document.querySelectorAll("#settings [data-param]")) if (input.dataset.param in values && document.activeElement !== input) input.value = values[input.dataset.param];
  changed(false);
}
function setCropRect(step, r) { setParams(step.id, { x: Math.round(r.x), y: Math.round(r.y), width: Math.max(1, Math.round(r.w)), height: Math.max(1, Math.round(r.h)) }); }

function ratioValue(step) {
  if (crop.ratioKey === "original" && crop.base) return crop.base.w / crop.base.h;
  return RATIOS[crop.ratioKey] ?? 0;
}

// Pure geometry, so it can be reasoned about: the new rectangle for a drag of `mode` by (dx, dy) image pixels.
function dragRect(mode, r0, dx, dy, W, H, ratio) {
  if (mode === "move") return { x: clamp(r0.x + dx, 0, Math.max(0, W - r0.w)), y: clamp(r0.y + dy, 0, Math.max(0, H - r0.h)), w: r0.w, h: r0.h };
  let l = r0.x, t = r0.y, r = r0.x + r0.w, b = r0.y + r0.h;
  if (mode.includes("w")) l = clamp(l + dx, 0, r - 1);
  if (mode.includes("e")) r = clamp(r + dx, l + 1, W);
  if (mode.includes("n")) t = clamp(t + dy, 0, b - 1);
  if (mode.includes("s")) b = clamp(b + dy, t + 1, H);
  if (!ratio) return { x: l, y: t, w: r - l, h: b - t };
  let w = r - l, h = b - t;
  const corner = mode.length === 2, vertical = mode === "n" || mode === "s";
  if (vertical || (corner && Math.abs(dy) > Math.abs(dx))) w = h * ratio; else h = w / ratio;
  const cx = r0.x + r0.w / 2, cy = r0.y + r0.h / 2;
  // room available on each axis, given which edge stays put
  const roomW = mode.includes("w") ? r0.x + r0.w : mode.includes("e") ? W - r0.x : 2 * Math.min(cx, W - cx);
  const roomH = mode.includes("n") ? r0.y + r0.h : mode.includes("s") ? H - r0.y : 2 * Math.min(cy, H - cy);
  const f = Math.min(1, roomW / w, roomH / h); w *= f; h *= f;
  const x = mode.includes("w") ? r0.x + r0.w - w : mode.includes("e") ? r0.x : cx - w / 2;
  const y = mode.includes("n") ? r0.y + r0.h - h : mode.includes("s") ? r0.y : cy - h / 2;
  return { x, y, w, h };
}

function wireCrop() {
  const box = $("crop");
  box.addEventListener("pointerdown", (e) => {
    const step = selectedCrop(); if (!step || !crop.base) return;
    box.setPointerCapture(e.pointerId);
    crop.drag = { mode: e.target.dataset.h || "move", sx: e.clientX, sy: e.clientY, r0: cropRect(step), step };
    e.preventDefault();
  });
  box.addEventListener("pointermove", (e) => {
    const d = crop.drag; if (!d || !crop.base) return;
    const k = $("image").clientWidth / crop.base.w;
    setCropRect(d.step, dragRect(d.mode, d.r0, (e.clientX - d.sx) / k, (e.clientY - d.sy) / k, crop.base.w, crop.base.h, ratioValue(d.step)));
  });
  const end = () => { crop.drag = null; };
  box.addEventListener("pointerup", end); box.addEventListener("pointercancel", end);
  box.addEventListener("keydown", (e) => {
    const step = selectedCrop(); if (!step || !crop.base) return;
    const n = e.shiftKey ? 10 : 1, r = cropRect(step);
    const d = { ArrowLeft: [-n, 0], ArrowRight: [n, 0], ArrowUp: [0, -n], ArrowDown: [0, n] }[e.key];
    if (!d) return;
    e.preventDefault();
    setCropRect(step, dragRect("move", r, d[0], d[1], crop.base.w, crop.base.h, 0));
  });
}

function cropControls(step) {
  const sel = el("select", { id: "crop-ratio" }, ...Object.keys(RATIOS).map((k) => el("option", { value: k, textContent: k === "free" ? "Free" : k, selected: k === crop.ratioKey })), el("option", { value: "original", textContent: "Original", selected: crop.ratioKey === "original" }));
  sel.onchange = () => {
    crop.ratioKey = sel.value; const ratio = ratioValue(step);
    if (ratio && crop.base) { const r = cropRect(step); setCropRect(step, dragRect("se", r, 0, 0, crop.base.w, crop.base.h, ratio)); }
  };
  const full = el("button", { type: "button", className: "btn small", textContent: "Whole image" });
  full.onclick = () => { if (crop.base) setCropRect(step, { x: 0, y: 0, w: crop.base.w, h: crop.base.h }); };
  return el("div", { className: "field" }, el("label", { htmlFor: "crop-ratio" }, "Aspect ratio"), el("div", { className: "row" }, sel, full),
    el("div", { className: "help", textContent: "Drag on the Crop view, or use the arrow keys on the rectangle, or type exact numbers above." }));
}

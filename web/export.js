// Export / PDF view: the encoder explorer, the raster PDF report and the HokusaiPDF vector document editor.
// Everything measured or generated comes from the server; this file only edits models and shows results.
import { el, clone, uid, fmtBytes, apiError, field } from "./ui.js";

const PAGE_PT = { a4: [595.276, 841.89], letter: [612, 792] };

export function initExport(container, ctx) {
  const state = ctx.state;
  const catalog = () => state.catalog;
  const cards = [];

  container.replaceChildren(
    el("div", { className: "inspect-head" }, el("h1", { textContent: "Export and PDF" }),
      el("p", { className: "muted", textContent: "Compare what each encoder produces for the current pipeline, make a PDF page from it, or build a multi-page PDF with real text from scratch. Sizes and facts are measured on real encoded bytes." })),
    el("div", { className: "lab-grid" }));
  const grid = container.querySelector(".lab-grid");

  // ---------------------------------------------------------------- A. encoders
  {
    const out = el("div", { className: "lab-out", role: "status", "aria-live": "polite" });
    const run = el("button", { type: "button", className: "btn", textContent: "Compare encoders" });
    run.onclick = async () => {
      if (!state.upload) { out.replaceChildren(el("p", { className: "muted", textContent: "Open an image in the Playground first." })); return; }
      run.disabled = true; out.replaceChildren(el("p", { className: "muted", textContent: "Encoding with every encoder…" }));
      try {
        const res = await fetch("/api/compare", { method: "POST", body: JSON.stringify({ uploadId: state.upload.uploadId, recipe: ctx.recipe(), page: state.page || null }) });
        if (!res.ok) throw await apiError(res);
        const { rows, scaledTo } = await res.json();
        const smallest = Math.min(...rows.filter((r) => r.ok).map((r) => r.bytes));
        const table = el("table", {}, el("thead", {}, el("tr", {}, ...["Format", "Size", "Relative", "Dimensions", "Server time", "In this browser", ""].map((h) => el("th", { scope: "col", textContent: h })))));
        const body = el("tbody");
        for (const o of catalog().outputs.filter((x) => x.format !== "pdf")) {
          const r = rows.find((x) => x.format === o.format);
          const use = el("button", { type: "button", className: "btn small", textContent: "Use", disabled: !r?.ok });
          use.onclick = () => ctx.useFormat(o.format);
          const viewer = o.browserViewable ? "shown directly" : "needs a proxy (the real file is still offered)";
          if (!o.available || !r?.ok) {
            const why = !o.available ? o.reason : r?.error ?? "failed";
            body.append(el("tr", {}, el("th", { scope: "row", textContent: o.title }), el("td", { colSpan: 5, textContent: `Not available: ${why}` }), el("td", { textContent: viewer }), el("td", {}, use)));
          } else {
            body.append(el("tr", {}, el("th", { scope: "row", textContent: o.title }), el("td", { textContent: fmtBytes(r.bytes) }),
              el("td", { textContent: r.bytes === smallest ? "smallest" : `${(r.bytes / smallest).toFixed(1)}×` }), el("td", { textContent: `${r.width} × ${r.height}` }),
              el("td", { textContent: `${Math.round(r.milliseconds)} ms` }), el("td", { textContent: viewer }), el("td", {}, use)));
          }
        }
        table.append(body);
        out.replaceChildren(table, el("p", { className: "muted", textContent: `Each encoder runs with its default options on the pipeline's result, reduced to at most ${scaledTo} px so the comparison stays quick. Use a format and tune it in the Playground; Export always encodes the full-size recipe. A format a runtime cannot encode is reported as such, which is different from a browser being unable to display a valid file.` }));
      } catch (e) { out.replaceChildren(el("p", { className: "status error", textContent: e.message })); }
      run.disabled = false;
    };
    grid.append(el("section", { className: "lab-card" }, el("h2", { textContent: "Encoders" }),
      el("p", { className: "muted", textContent: "The same pipeline through every encoder this server's libvips has, with default options." }),
      el("div", { className: "lab-actions" }, run), out));
  }

  // ---------------------------------------------------------------- B. raster PDF
  {
    const spec = () => catalog().outputs.find((o) => o.format === "pdf");
    const form = el("div", { className: "pdf-form" });
    const preview = el("img", { className: "pdf-page", alt: "Page 1 of the PDF, rendered from the PDF bytes", hidden: true });
    const facts = el("div", { className: "lab-out", role: "status", "aria-live": "polite" });
    let rev = 0, timer = null, url = null;
    const pdfRecipe = () => { const r = clone(ctx.recipe()); r.output = { format: "pdf", options: r.output.format === "pdf" ? r.output.options : {} }; return r; };
    async function refresh() {
      if (!state.upload) { facts.replaceChildren(el("p", { className: "muted", textContent: "Open an image in the Playground first. The PDF is made from the current pipeline." })); preview.hidden = true; return; }
      const mine = ++rev;
      try {
        const res = await fetch("/api/render", { method: "POST", body: JSON.stringify({ uploadId: state.upload.uploadId, recipe: pdfRecipe(), viewable: true }) });
        if (!res.ok) throw await apiError(res);
        const blob = await res.blob(); if (mine !== rev) return;
        if (url) URL.revokeObjectURL(url);
        url = URL.createObjectURL(blob); preview.src = url; preview.hidden = false;
        const h = (n) => res.headers.get(n);
        facts.replaceChildren(el("dl", { className: "facts-inline" },
          ...[["Pages", h("x-hokusai-pdf-pages")], ["Page size", `${(+h("x-hokusai-pdf-width")).toFixed(0)} × ${(+h("x-hokusai-pdf-height")).toFixed(0)} pt (${((+h("x-hokusai-pdf-width")) / 72 * 25.4).toFixed(0)} × ${((+h("x-hokusai-pdf-height")) / 72 * 25.4).toFixed(0)} mm)`],
            ["PDF file", fmtBytes(+h("x-hokusai-bytes"))], ["Preview", `a PNG of page 1 decoded from the real PDF (${blob.size ? fmtBytes(blob.size) : ""})`], ["Server time", h("server-timing")?.split("dur=")[1] + " ms"]]
            .flatMap(([k, v]) => [el("dt", { textContent: k }), el("dd", { textContent: v })])),
          el("p", { className: "muted", textContent: "This is a raster page: the pipeline's pixels are embedded as an image, so text drawn by a Text overlay step is pixels here and cannot be selected. Use the vector document below for real text." }));
      } catch (e) { if (mine === rev) facts.replaceChildren(el("p", { className: "status error", textContent: e.message })); }
    }
    const schedule = () => { clearTimeout(timer); timer = setTimeout(refresh, 300); };
    function drawForm() {
      const opts = ctx.recipe().output.format === "pdf" ? ctx.recipe().output.options : {};
      const common = spec().params.filter((p) => !p.advanced), adv = spec().params.filter((p) => p.advanced);
      const bind = (p) => field(p, opts, (v) => { if (ctx.recipe().output.format !== "pdf") ctx.useFormat("pdf"); ctx.setOutputParam(p, v); schedule(); });
      form.replaceChildren(...common.map(bind), el("details", { className: "adv" }, el("summary", { textContent: "Advanced" }), ...adv.map(bind)));
    }
    const download = el("button", { type: "button", className: "btn primary", textContent: "Download PDF" });
    download.onclick = async () => {
      if (!state.upload) return;
      const res = await fetch("/api/render", { method: "POST", body: JSON.stringify({ uploadId: state.upload.uploadId, recipe: pdfRecipe() }) });
      if (!res.ok) { facts.replaceChildren(el("p", { className: "status error", textContent: (await apiError(res)).message })); return; }
      const a = el("a", { href: URL.createObjectURL(await res.blob()), download: `${(state.upload.name || "image").replace(/\.[^.]+$/, "")}.pdf` }); a.click(); setTimeout(() => URL.revokeObjectURL(a.href), 4000);
    };
    cards.push({ refreshRaster() { drawForm(); refresh(); } });
    grid.append(el("section", { className: "lab-card" }, el("h2", { textContent: "Raster PDF report" }),
      el("p", { className: "muted", textContent: "Puts the current pipeline's result on a PDF page: page size, margins, position, background and document properties." }),
      form, el("div", { className: "lab-actions" }, download), preview, facts));
  }

  // ---------------------------------------------------------------- C. vector document
  {
    const items = () => catalog().vectorItems;
    const spec = (t) => items().find((i) => i.type === t);
    const doc = clone(catalog().vectorPresets[0].document);
    const sel = { page: 0, item: null };
    let rev = 0, timer = null, codeTimer = null, previewUrl = null, lastInfo = null;

    const pageBox = el("div", { className: "vec-pages" }), itemBox = el("div", { className: "vec-items" }), settings = el("div", { className: "vec-settings" });
    const img = el("img", { className: "pdf-page", alt: "Selected PDF page", hidden: true });
    const info = el("div", { className: "lab-out", role: "status", "aria-live": "polite" });
    const code = el("pre", { className: "code vec-code", tabIndex: 0 });
    const page = () => doc.pages[sel.page];
    const pageSize = (p) => (p.size === "custom" ? [p.width, p.height] : (p.orientation === "landscape" ? [...PAGE_PT[p.size]].reverse() : PAGE_PT[p.size]));

    const changed = () => { drawPages(); drawItems(); schedulePreview(); scheduleCode(); };
    function drawPages() {
      const bar = el("div", { className: "seg", role: "group", "aria-label": "Pages" });
      doc.pages.forEach((p, i) => { const b = el("button", { type: "button", textContent: `Page ${i + 1}`, className: i === sel.page ? "on" : "" }); b.setAttribute("aria-pressed", i === sel.page); b.onclick = () => { sel.page = i; sel.item = null; drawPages(); drawItems(); drawSettings(); schedulePreview(); }; bar.append(b); });
      const mini = (label, fn, disabled = false) => { const b = el("button", { type: "button", className: "btn small", textContent: label, disabled }); b.onclick = fn; return b; };
      const p = page();
      const size = el("select", { "aria-label": "Page size" }, ...[["a4", "A4"], ["letter", "US Letter"], ["custom", "Custom"]].map(([v, l]) => el("option", { value: v, textContent: l, selected: p.size === v })));
      size.onchange = () => { p.size = size.value; changed(); drawPages(); };
      const orient = el("select", { "aria-label": "Orientation", disabled: p.size === "custom" }, ...["portrait", "landscape"].map((v) => el("option", { value: v, textContent: v, selected: p.orientation === v })));
      orient.onchange = () => { p.orientation = orient.value; changed(); };
      const dims = p.size === "custom" ? [["width", "Width pt"], ["height", "Height pt"]].map(([k, l]) => { const i = el("input", { type: "number", value: p[k], min: 1, max: 14400, "aria-label": l }); i.oninput = () => { const n = Number(i.value); if (n >= 1 && n <= 14400) { p[k] = n; changed(); } }; return i; }) : [];
      pageBox.replaceChildren(bar, el("div", { className: "lab-actions wrap" },
        mini("Add page", () => { if (doc.pages.length < 12) { doc.pages.push({ id: uid(), size: p.size, orientation: p.orientation, width: p.width, height: p.height, items: [] }); sel.page = doc.pages.length - 1; sel.item = null; changed(); drawSettings(); } }, doc.pages.length >= 12),
        mini("Duplicate", () => { const c = clone(p); c.id = uid(); c.items.forEach((x) => { x.id = uid(); }); doc.pages.splice(sel.page + 1, 0, c); sel.page++; changed(); }, doc.pages.length >= 12),
        mini("Remove", () => { if (doc.pages.length > 1) { doc.pages.splice(sel.page, 1); sel.page = Math.max(0, sel.page - 1); sel.item = null; changed(); drawSettings(); } }, doc.pages.length <= 1)),
        el("div", { className: "lab-actions wrap" }, size, orient, ...dims));
    }

    function itemLabel(it) {
      const s = spec(it.type); const text = it.type === "text" ? ` “${String(it.props.content ?? "Hello, PDF").slice(0, 22)}”` : "";
      return s.title + text;
    }
    function drawItems() {
      const list = el("ol", { className: "steps", "aria-label": "Items on this page, drawn in order" });
      page().items.forEach((it, i) => {
        const li = el("li", { className: "step" });
        if (it.id === sel.item) li.setAttribute("aria-current", "true");
        const name = el("button", { type: "button", className: "name", textContent: itemLabel(it) });
        name.setAttribute("aria-label", `Item ${i + 1}: ${itemLabel(it)}`);
        name.onclick = () => { sel.item = it.id; drawItems(); drawSettings(); };
        const mini = (label, title, fn, disabled = false) => { const b = el("button", { type: "button", className: "mini", textContent: label, title, disabled }); b.setAttribute("aria-label", `${title}: ${itemLabel(it)}`); b.onclick = (e) => { e.stopPropagation(); fn(); }; return b; };
        const move = (d) => { const items = page().items; const j = i + d; if (j < 0 || j >= items.length) return; [items[i], items[j]] = [items[j], items[i]]; changed(); };
        li.append(el("span", { className: "num", textContent: String(i + 1) }), name, mini("↑", "Move up", () => move(-1), i === 0), mini("↓", "Move down", () => move(1), i === page().items.length - 1),
          mini("⧉", "Duplicate", () => { const c = clone(it); c.id = uid(); page().items.splice(i + 1, 0, c); sel.item = c.id; changed(); drawSettings(); }), mini("✕", "Remove", () => { page().items.splice(i, 1); if (sel.item === it.id) sel.item = null; changed(); drawSettings(); }));
        list.append(li);
      });
      const add = el("select", { "aria-label": "Add an item" }, el("option", { value: "", textContent: "Add item…" }), ...items().map((s) => el("option", { value: s.type, textContent: s.title })));
      add.onchange = () => { if (!add.value) return; if (page().items.length >= 60) return; const it = { id: uid(), type: add.value, props: {} }; page().items.push(it); sel.item = it.id; changed(); drawSettings(); };
      itemBox.replaceChildren(list, page().items.length ? "" : el("p", { className: "empty", textContent: "This page is empty." }), add);
    }
    function drawSettings() {
      const it = page().items.find((x) => x.id === sel.item);
      if (!it) { settings.replaceChildren(el("p", { className: "empty", textContent: "Select an item to edit it." })); return; }
      const s = spec(it.type);
      const bind = (p) => field(p, it.props, (v) => { if (v === p.default) delete it.props[p.name]; else it.props[p.name] = v; schedulePreview(); scheduleCode(); drawItems(); });
      settings.replaceChildren(el("h3", { textContent: s.title }), el("p", { className: "api", textContent: s.api }), el("p", { className: "muted", textContent: s.summary }),
        ...s.params.filter((p) => !p.advanced).map(bind),
        ...(s.params.some((p) => p.advanced) ? [el("details", { className: "adv" }, el("summary", { textContent: "Advanced" }), ...s.params.filter((p) => p.advanced).map(bind))] : []));
    }

    function body(extra = {}) { return JSON.stringify({ uploadId: state.upload?.uploadId ?? null, document: doc, ...extra }); }
    function schedulePreview() { clearTimeout(timer); timer = setTimeout(preview, 250); }
    async function preview() {
      const mine = ++rev;
      try {
        const res = await fetch("/api/pdf", { method: "POST", body: body({ previewPage: sel.page + 1 }) });
        if (!res.ok) throw await apiError(res);
        const blob = await res.blob(); if (mine !== rev) return;
        if (previewUrl) URL.revokeObjectURL(previewUrl);
        previewUrl = URL.createObjectURL(blob); img.src = previewUrl; img.hidden = false;
        const h = (n) => res.headers.get(n);
        const [w, hgt] = pageSize(page());
        lastInfo = { pages: h("x-hokusai-pdf-pages"), bytes: h("x-hokusai-bytes"), selectable: h("x-hokusai-selectable-text") === "true", time: h("server-timing")?.split("dur=")[1] };
        info.replaceChildren(el("dl", { className: "facts-inline" }, ...[
          ["Showing", `page ${sel.page + 1} of ${lastInfo.pages}, ${w.toFixed(0)} × ${hgt.toFixed(0)} pt (a PNG decoded from the real PDF at 72 dpi)`],
          ["PDF file", `${fmtBytes(+lastInfo.bytes)} · ${lastInfo.time} ms on the server`],
          ["Selectable text", lastInfo.selectable ? "yes: the PDF carries a text font with a character map (a heuristic; the unit tests confirm it with a PDF reader)" : "none: this document has no text items"],
        ].flatMap(([k, v]) => [el("dt", { textContent: k }), el("dd", { textContent: v })])));
      } catch (e) { if (mine === rev) info.replaceChildren(el("p", { className: "status error", textContent: `${e.message}${lastInfo ? " The page shown is the last good one, not this edit." : ""}` })); }
    }
    function scheduleCode() { clearTimeout(codeTimer); codeTimer = setTimeout(loadCode, 300); }
    async function loadCode() {
      try {
        const res = await fetch("/api/code", { method: "POST", body: JSON.stringify({ document: doc }) });
        code.textContent = res.ok ? (await res.json()).code : `// ${(await apiError(res)).message}`;
      } catch (e) { code.textContent = `// ${e.message}`; }
    }

    const presetSel = el("select", { "aria-label": "Document template" }, ...catalog().vectorPresets.map((p) => el("option", { value: p.id, textContent: p.title })));
    const reset = el("button", { type: "button", className: "btn small", textContent: "Load template" });
    reset.onclick = () => { const p = catalog().vectorPresets.find((x) => x.id === presetSel.value); Object.assign(doc, clone(p.document)); sel.page = 0; sel.item = null; titleIn.value = doc.title; authorIn.value = doc.author; changed(); drawSettings(); };
    const titleIn = el("input", { type: "text", value: doc.title, placeholder: "Document title", "aria-label": "Document title" }); titleIn.oninput = () => { doc.title = titleIn.value; schedulePreview(); scheduleCode(); };
    const authorIn = el("input", { type: "text", value: doc.author, placeholder: "Author", "aria-label": "Author" }); authorIn.oninput = () => { doc.author = authorIn.value; schedulePreview(); scheduleCode(); };
    const download = el("button", { type: "button", className: "btn primary", textContent: "Download PDF" });
    download.onclick = async () => {
      const res = await fetch("/api/pdf", { method: "POST", body: body() });
      if (!res.ok) { info.replaceChildren(el("p", { className: "status error", textContent: (await apiError(res)).message })); return; }
      const a = el("a", { href: URL.createObjectURL(await res.blob()), download: "document.pdf" }); a.click(); setTimeout(() => URL.revokeObjectURL(a.href), 4000);
    };
    const copy = el("button", { type: "button", className: "btn small", textContent: "Copy Swift" });
    copy.onclick = async () => { try { await navigator.clipboard.writeText(code.textContent); copy.textContent = "Copied"; setTimeout(() => { copy.textContent = "Copy Swift"; }, 1500); } catch { /* clipboard unavailable */ } };

    cards.push({ refreshVector() { changed(); drawSettings(); loadCode(); } });
    grid.append(el("section", { className: "lab-card wide" }, el("h2", { textContent: "Vector document (HokusaiPDF)" }),
      el("p", { className: "muted", textContent: "Pages of real text, shapes, gradients and pictures. Text stays selectable and shapes stay sharp at any zoom. This is a document builder, not an editor for existing PDFs: there are no tables or other layout beyond what HokusaiPDF draws. Coordinates are in points from the top-left of the page." }),
      el("div", { className: "lab-actions wrap" }, presetSel, reset, titleIn, authorIn, download),
      el("div", { className: "vec" }, el("div", {}, pageBox, itemBox), el("div", { className: "vec-preview" }, img, info), settings),
      el("div", { className: "lab-actions" }, el("strong", { textContent: "Swift" }), copy), code));
  }

  return {
    show() { for (const c of cards) { c.refreshRaster?.(); c.refreshVector?.(); } },
    hide() {},
  };
}

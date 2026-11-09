// Helpers shared by the playground, the labs and the export view.
export const el = (tag, props = {}, ...children) => {
  const node = Object.assign(document.createElement(tag), props);
  for (const c of children) node.append(c);
  return node;
};
export const clone = (v) => JSON.parse(JSON.stringify(v));
export const uid = () => (crypto.randomUUID ? crypto.randomUUID() : String(Math.random()).slice(2));
export function fmtBytes(n) { return n < 1024 ? `${n} B` : n < 1048576 ? `${(n / 1024).toFixed(1)} KiB` : `${(n / 1048576).toFixed(2)} MiB`; }

export async function apiError(res) {
  let message = `The server answered ${res.status}.`, code = "";
  try { const b = await res.json(); message = b.error.message; code = b.error.code; } catch { /* keep default */ }
  return Object.assign(new Error(message), { code, status: res.status });
}

/** One control, generated from the catalog's description of a parameter. `onChange` gets the new value. */
export function field(p, params, onChange) {
  const value = p.name in params ? params[p.name] : p.default;
  const id = "f-" + uid();
  const wrap = el("div", { className: "field" });
  const label = el("label", { htmlFor: id }, p.label, p.unit ? el("span", { className: "unit", textContent: p.unit }) : "");
  wrap.append(label);
  if (p.kind === "number" || p.kind === "integer") {
    const num = el("input", { type: "number", id, value, min: p.min ?? "", max: p.max ?? "", step: p.step ?? (p.kind === "integer" ? 1 : "any") });
    const range = (p.min != null && p.max != null && p.max - p.min <= 100000) ? el("input", { type: "range", min: p.min, max: p.max, step: p.step ?? 1, value, tabIndex: -1 }) : null;
    range?.setAttribute("aria-hidden", "true");
    num.dataset.param = p.name; if (range) range.dataset.param = p.name;
    const commit = (raw) => { const n = Number(raw); if (Number.isFinite(n) && raw !== "") onChange(n); };
    num.oninput = () => { if (range) range.value = num.value; commit(num.value); };
    if (range) range.oninput = () => { num.value = range.value; commit(range.value); };
    wrap.append(el("div", { className: "row" }, ...(range ? [range, num] : [num])));
  } else if (p.kind === "boolean") {
    const box = el("input", { type: "checkbox", id, checked: !!value }); box.onchange = () => onChange(box.checked);
    wrap.append(box);
  } else if (p.kind === "choice") {
    const sel = el("select", { id }, ...p.options.map((o) => el("option", { value: o.value, textContent: o.label, selected: o.value === value })));
    sel.onchange = () => onChange(sel.value); wrap.append(sel);
  } else if (p.kind === "color") {
    const hex = String(value); const rgb = hex.slice(0, 7); const a = hex.length === 9 ? parseInt(hex.slice(7), 16) : 255;
    const picker = el("input", { type: "color", id, value: rgb });
    const alpha = el("input", { type: "range", min: 0, max: 255, value: a }); alpha.setAttribute("aria-label", `${p.label} opacity`);
    const emit = () => onChange(picker.value + (Number(alpha.value) === 255 ? "" : Number(alpha.value).toString(16).padStart(2, "0")));
    picker.oninput = emit; alpha.oninput = emit;
    wrap.append(el("div", { className: "row" }, picker, alpha));
  } else {
    const input = el("input", { type: "text", id, value, maxLength: 2000 }); input.oninput = () => onChange(input.value); wrap.append(input);
  }
  if (p.help) wrap.append(el("div", { className: "help", textContent: p.help }));
  return wrap;
}


#!/usr/bin/env python3
"""Checks coverage/coverage.json against the catalog and regenerates coverage/COVERAGE.md.

  scripts/coverage.py          regenerate COVERAGE.md and fail if the matrix and the catalog disagree
  scripts/coverage.py --check  fail if COVERAGE.md is stale
"""
import json, pathlib, subprocess, sys

root = pathlib.Path(__file__).resolve().parent.parent
rows = json.loads((root / "coverage/coverage.json").read_text())
catalog = subprocess.run(["swift", "run", "--package-path", str(root / "recipes"), "-q", "recipes-tool", "coverage"],
                         capture_output=True, text=True, check=True).stdout.split("\n")
ops = {l.split()[1] for l in catalog if l.startswith("operation ")}
outs = {l.split()[1] for l in catalog if l.startswith("output ")}

errors = []
mapped_ops = {r["op"] for r in rows if "op" in r}
mapped_outs = {r["output"] for r in rows if "output" in r}
for r in rows:
    if r["status"] not in ("implemented", "partial", "planned"):
        errors.append(f'{r["item"]}: bad status {r["status"]}')
    if "op" in r and r["op"] not in ops:
        errors.append(f'{r["item"]}: operation "{r["op"]}" is not in the catalog')
    if "output" in r and r["output"] not in outs:
        errors.append(f'{r["item"]}: output "{r["output"]}" is not in the catalog')
    if r["status"] in ("implemented", "partial") and "op" not in r and "output" not in r and r["area"] in ("Geometry", "Effects", "Colour and alpha", "Encoders"):
        errors.append(f'{r["item"]}: implemented but not tied to a catalog entry')
for missing in sorted(ops - mapped_ops):
    errors.append(f'catalog operation "{missing}" is missing from the coverage matrix')
for missing in sorted(outs - mapped_outs):
    errors.append(f'catalog output "{missing}" is missing from the coverage matrix')
if errors:
    print("\n".join("coverage: " + e for e in errors)); sys.exit(1)

lines = ["# Capability coverage", "",
         "Generated from [`coverage.json`](coverage.json) by `scripts/coverage.py`; CI fails if it is stale or if the catalog and this matrix disagree.",
         "The baseline is Hokusai 2.2.2 (see `recipes/Package.swift`). Future operators tracked in ivantokar/hokusai#150 are not listed as promises.", "",
         "Status: **implemented** works in the demo today; **partial** works with the limits named; **planned** is demo work that is not built yet (it does not mean the library lacks it).", ""]
counts = {"implemented": 0, "partial": 0, "planned": 0}
for r in rows: counts[r["status"]] += 1
lines += [f'{counts["implemented"]} implemented, {counts["partial"]} partial, {counts["planned"]} planned, {len(rows)} in total.', ""]
area = None
for r in rows:
    if r["area"] != area:
        area = r["area"]; lines += ["", f"## {area}", "", "| Capability | Public API | Status | Where |", "| --- | --- | --- | --- |"]
    note = f' {r["note"]}' if r.get("note") else ""
    lines.append(f'| {r["item"]} | `{r["api"]}` | {r["status"]} | {r["where"]}.{note} |')
text = "\n".join(lines) + "\n"
target = root / "coverage/COVERAGE.md"
if "--check" in sys.argv:
    if not target.exists() or target.read_text() != text:
        print("coverage: COVERAGE.md is stale; run scripts/coverage.py"); sys.exit(1)
else:
    target.write_text(text)
print(f"coverage ok: {counts}")

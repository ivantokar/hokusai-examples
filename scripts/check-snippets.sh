#!/usr/bin/env bash
# Compiles and runs the Swift the playground generates for every preset, against the pinned Hokusai release.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
swift run --package-path "$here/recipes" recipes-tool snippets "$work/snippets" "$here/fixtures"
cd "$work/snippets"
swift build 2>&1 | tail -3
python3 - "$here" <<'PY'
import json, os, shutil, subprocess, sys, tempfile
here = sys.argv[1]
for item in json.load(open("manifest.json")):
    run = tempfile.mkdtemp()
    shutil.copy(os.path.join(here, "fixtures", item["sample"]), os.path.join(run, "input.jpg"))
    for name in os.listdir(os.path.join(here, "fixtures")):      # documents place these pictures by name
        shutil.copy(os.path.join(here, "fixtures", name), os.path.join(run, name))
    r = subprocess.run([os.path.abspath(".build/debug/" + item["target"])], cwd=run, capture_output=True, text=True)
    out = os.path.join(run, item["output"])
    if r.returncode != 0 or not os.path.exists(out) or os.path.getsize(out) < 100:
        print("FAIL", item["target"], r.stdout, r.stderr); sys.exit(1)
    print("ok  ", item["target"], "->", item["output"], os.path.getsize(out), "bytes;", r.stdout.strip())
PY

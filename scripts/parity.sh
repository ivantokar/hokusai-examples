#!/usr/bin/env bash
# Checks that two running backends answer the same questions the same way. They are built on the same shared
# DemoAPI, so any difference is a bug in an adapter (routing, body limits, headers, error mapping).
#   scripts/parity.sh http://127.0.0.1:8081 http://127.0.0.1:8082
set -euo pipefail
a="${1:?first backend url}"; b="${2:?second backend url}"
here="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$a" "$b" "$here/fixtures" <<'PY'
import json, sys, urllib.error, urllib.request

urls, fx = sys.argv[1:3], sys.argv[3]

def call(base, method, path, body=None, raw=False):
    data = None if body is None else (body if raw else json.dumps(body).encode())
    req = urllib.request.Request(base + path, data=data, method=method)
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            return r.status, dict((k.lower(), v) for k, v in r.headers.items()), r.read()
    except urllib.error.HTTPError as e:
        return e.code, dict((k.lower(), v) for k, v in e.headers.items()), e.read()

failures = []
def strip_ids(x):
    # Vector presets get fresh UUIDs on every request; they identify items inside one response only.
    if isinstance(x, dict): return {k: strip_ids(v) for k, v in x.items() if k != "id" or not isinstance(v, str) or len(v) != 36}
    if isinstance(x, list): return [strip_ids(v) for v in x]
    return x

def canonical(b):
    # Key order in a JSON object is not part of the contract; compare the data.
    try: return json.dumps(strip_ids(json.loads(b)), sort_keys=True).encode()
    except ValueError: return b

def same(label, results, headers=(), body=True):
    (s1, h1, b1), (s2, h2, b2) = results
    if h1.get("content-type", "").startswith("application/json"): b1, b2 = canonical(b1), canonical(b2)
    problems = []
    if s1 != s2: problems.append(f"status {s1} vs {s2}")
    for name in headers:
        if h1.get(name) != h2.get(name): problems.append(f"{name}: {h1.get(name)} vs {h2.get(name)}")
    if body and b1 != b2: problems.append(f"body differs ({len(b1)} vs {len(b2)} bytes)")
    print(("ok   " if not problems else "FAIL ") + label + ("" if not problems else " - " + "; ".join(problems)))
    if problems: failures.append(label)

def both(method, path, body=None, raw=False):
    return [call(u, method, path, body, raw) for u in urls]

names = [json.loads(call(u, "GET", "/api/backend")[2])["backend"] for u in urls]
assert names[0] != names[1], f"both URLs answered as {names[0]}; compare two different backends"
print(f"comparing {names[0]} with {names[1]}")

# Descriptions of what the runtime can do.
same("catalog", both("GET", "/api/catalog"))
same("capabilities", both("GET", "/api/capabilities"))

uploads = []
for name in ("phone.jpg", "scene.png", "metadata.jpg"):
    data = open(f"{fx}/{name}", "rb").read()
    r = both("POST", "/api/uploads", data, raw=True)
    same(f"upload {name}", r, body=False)
    uploads.append([json.loads(x[2])["uploadId"] for x in r])
phone, scene, meta = uploads

def with_id(ids, extra):
    return [dict(extra, uploadId=i) for i in ids]

def post_each(path, ids, extra):
    return [call(u, "POST", path, dict(extra, uploadId=i)) for u, i in zip(urls, ids)]

recipes = {
    "orient + resize + rotate": ([{"op": "autoOrient"}, {"op": "resize", "params": {"width": 400, "fit": "inside"}}, {"op": "rotate", "params": {"degrees": 90}}], "png"),
    "blur + sharpen": ([{"op": "blur", "params": {"sigma": 2}}, {"op": "sharpen", "params": {"sigma": 1}}], "png"),
    "text overlay": ([{"op": "text", "params": {"content": "Parity"}}], "png"),
    "convolution kernel": ([{"op": "convolve"}], "png"),
    "colour matrix": ([{"op": "recombine"}], "png"),
    "affine shear": ([{"op": "affine", "params": {"matrix": "1 0.4 0 1"}}], "png"),
    "emblem layer": ([{"op": "layer", "params": {"asset": "emblem.png", "width": 200}}], "png"),
    "webp export": ([{"op": "resize", "params": {"width": 300, "fit": "inside"}}], "webp"),
    "jpeg export": ([{"op": "resize", "params": {"width": 300, "fit": "inside"}}], "jpeg"),
}
for label, (steps, fmt) in recipes.items():
    recipe = {"version": 1, "steps": steps, "output": {"format": fmt}}
    r = post_each("/api/render", scene, {"recipe": recipe})
    same(f"render: {label}", r, headers=("content-type", "x-hokusai-width", "x-hokusai-height"))

recipe = {"version": 1, "steps": [{"op": "resize", "params": {"width": 400, "fit": "inside"}}], "output": {"format": "png"}}
same("render: preview", post_each("/api/render", scene, {"recipe": recipe, "previewMaxEdge": 100}), headers=("x-hokusai-width", "x-hokusai-height"))
for label, params in (("text source", {}), ("text source, wrapped and left aligned", {"wrapWidth": 400, "alignment": "left", "content": "one two three four five six seven"})):
    r = [call(u, "POST", "/api/render", {"recipe": {"version": 1, "source": {"kind": "text", "params": params}, "steps": [], "output": {"format": "png"}}}) for u in urls]
    same(f"render: {label}", r, headers=("content-type", "x-hokusai-width", "x-hokusai-height"))
same("code: text source for Vapor", [call(u, "POST", "/api/code", {"target": "vapor", "recipe": {"version": 1, "source": {"kind": "text"}, "steps": [], "output": {"format": "png"}}}) for u in urls])
same("code: core", post_each("/api/code", scene, {"recipe": recipe, "target": "core"}))
same("inspect: metadata", post_each("/api/inspect", meta, {"recipe": {"version": 1, "steps": [], "output": {"format": "jpeg", "options": {"keepXmp": True}}}}))
same("raw output", post_each("/api/raw/output", scene, {"recipe": recipe, "format": "rgba8", "maxEdge": 64}), headers=("x-raw-width", "x-raw-height", "x-raw-row-stride"))
same("minimal route", [call(u, "POST", "/api/minimal/resize?width=300&format=png", open(f"{fx}/scene.png", "rb").read(), raw=True) for u in urls])

# Errors: the same status and the same JSON error, whichever adapter produced them.
same("error: expired upload", both("POST", "/api/render", {"uploadId": "nope", "recipe": recipe}))
same("error: not an image", both("POST", "/api/uploads", b"not an image", raw=True), body=False)
bad_crop = {"version": 1, "steps": [{"op": "crop", "params": {"x": 900, "y": 0, "width": 400, "height": 400}}], "output": {"format": "png"}}
same("error: crop out of bounds", post_each("/api/render", scene, {"recipe": bad_crop}))
same("error: malformed JSON", [call(u, "POST", "/api/render", b"{", raw=True) for u in urls], body=False)
same("error: unknown route", both("GET", "/api/nope"), body=False)

if failures:
    sys.exit(f"{len(failures)} difference(s) between the backends: {', '.join(failures)}")
print("parity passed")
PY

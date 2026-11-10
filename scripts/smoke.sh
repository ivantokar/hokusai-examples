#!/usr/bin/env bash
# Smoke-tests one running backend through its public HTTP API: the same checks for Vapor and Hummingbird.
#   scripts/smoke.sh http://127.0.0.1:8081 vapor
set -euo pipefail
base="${1:?base url}"; expect_backend="${2:?expected backend name}"
here="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   $*"; }
json() { python3 -c "import sys,json; d=json.load(sys.stdin); print($1)"; }

[ "$(curl -fsS "$base/api/backend" | json 'd["backend"]')" = "$expect_backend" ] || fail "backend name"
ok "backend is $expect_backend"

curl -fsS "$base/api/catalog" | json 'len(d["operations"])' | grep -Eq '^[0-9]+$' || fail "catalog"
curl -fsS "$base/api/capabilities" | json '"jpeg" in d["output"] and d["text"]' | grep -q True || fail "capabilities (jpeg + text)"
ok "catalog and runtime capabilities"

curl -fsS "$base/" | grep -q "Hokusai" || fail "web UI is not served"
curl -fsS -o /dev/null "$base/samples/scene.png" || fail "sample"
ok "web UI and samples"

# Minimal route: upload -> resize -> response, with the EXIF orientation applied (1000x1600 stored, upright 1600x1000).
curl -fsS --data-binary @"$here/fixtures/phone.jpg" "$base/api/minimal/resize?width=300" -o "$tmp/min.webp"
python3 - "$tmp/min.webp" <<'PY' || fail "minimal route output"
import sys
b = open(sys.argv[1], "rb").read()
assert b[:4] == b"RIFF" and b[8:12] == b"WEBP", "not WebP"
PY
ok "minimal upload -> resize -> response"

id="$(curl -fsS --data-binary @"$here/fixtures/phone.jpg" "$base/api/uploads" | json 'd["uploadId"]')"
recipe='{"version":1,"steps":[{"op":"autoOrient"},{"op":"resize","params":{"width":400,"fit":"inside"}},{"op":"rotate","params":{"degrees":90}},{"op":"text","params":{"content":"Smoke"}}],"output":{"format":"png"}}'
headers="$(curl -fsS -D- -o "$tmp/r.png" -X POST "$base/api/render" -d "{\"uploadId\":\"$id\",\"recipe\":$recipe}")"
w="$(echo "$headers" | tr -d '\r' | awk -F': ' 'tolower($1)=="x-hokusai-width"{print $2}')"
h="$(echo "$headers" | tr -d '\r' | awk -F': ' 'tolower($1)=="x-hokusai-height"{print $2}')"
# 1600x1000 upright -> width 400 -> 400x250 -> rotated 250x400
[ "$w x $h" = "250 x 400" ] || fail "render size was $w x $h, expected 250 x 400"
echo "$headers" | tr -d '\r' | grep -qi "^x-hokusai-backend: $expect_backend" || fail "backend header"
echo "$headers" | tr -d '\r' | grep -qi "^server-timing: render;dur=" || fail "server timing"
[ "$(head -c 4 "$tmp/r.png" | tail -c 3)" = PNG ] || fail "render is not a PNG"
ok "render keeps step order (250 x 400), reports server time"

# Preview reduces the result, never the evaluated recipe.
pw="$(curl -fsS -D- -o /dev/null -X POST "$base/api/render" -d "{\"uploadId\":\"$id\",\"previewMaxEdge\":100,\"recipe\":$recipe}" | tr -d '\r' | awk -F': ' 'tolower($1)=="x-hokusai-height"{print $2}')"
[ "$pw" = "100" ] || fail "preview height $pw"
ok "preview fits the result"

# Errors are JSON with a status the client can act on.
code="$(curl -sS -o "$tmp/e.json" -w '%{http_code}' -X POST "$base/api/render" -d '{"uploadId":"nope","recipe":{"version":1,"steps":[],"output":{"format":"png"}}}')"
[ "$code" = "404" ] && grep -q expiredUpload "$tmp/e.json" || fail "expired upload: $code"
code="$(curl -sS -o /dev/null -w '%{http_code}' --data-binary 'not an image' "$base/api/uploads")"
[ "$code" = "422" ] || fail "non-image upload gave $code, expected 422"
code="$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$base/api/render" -d "{\"uploadId\":\"$id\",\"recipe\":{\"version\":1,\"steps\":[{\"op\":\"crop\",\"params\":{\"x\":900,\"y\":0,\"width\":400,\"height\":400}}],\"output\":{\"format\":\"png\"}}}")"
[ "$code" = "422" ] || fail "out-of-bounds crop gave $code, expected 422"
ok "errors: expired upload 404, non-image 422, invalid crop $code"

# The crop editor asks for the image that ENTERS a step: sizes must match the coordinates the crop uses.
crop='{"version":1,"steps":[{"id":"a","op":"autoOrient"},{"id":"b","op":"resize","params":{"width":400,"fit":"inside"}},{"id":"c","op":"rotate","params":{"degrees":90}},{"id":"d","op":"crop","params":{"x":10,"y":20,"width":100,"height":120}}],"output":{"format":"webp"}}'
eh="$(curl -fsS -D- -o /dev/null -X POST "$base/api/render" -d "{\"uploadId\":\"$id\",\"stopBefore\":\"d\",\"recipe\":$crop}" | tr -d '\r')"
echo "$eh" | grep -qi "^x-hokusai-width: 250" && echo "$eh" | grep -qi "^x-hokusai-height: 400" || fail "image entering the crop is not 250 x 400"
fh="$(curl -fsS -D- -o /dev/null -X POST "$base/api/render" -d "{\"uploadId\":\"$id\",\"recipe\":$crop}" | tr -d '\r')"
echo "$fh" | grep -qi "^x-hokusai-width: 100" && echo "$fh" | grep -qi "^x-hokusai-height: 120" || fail "export does not match the crop rectangle"
ok "crop coordinates agree with the image entering the step"

# Metadata retention is read back from the exported bytes, never assumed from the settings.
mid="$(curl -fsS --data-binary @"$here/fixtures/metadata.jpg" "$base/api/uploads" | json 'd["uploadId"]')"
inspect() { curl -fsS -X POST "$base/api/inspect" -d "{\"uploadId\":\"$mid\",\"recipe\":{\"version\":1,\"steps\":[],\"output\":{\"format\":\"jpeg\",\"options\":$1}}}"; }
inspect '{}' | json 'd["source"]["xmpBytes"] > 0 and d["source"]["iptcBytes"] > 0 and d["output"]["xmpBytes"] == 0 and d["output"]["iptcBytes"] == 0 and d["output"]["iccBytes"] > 0' | grep -q True || fail "default policy should keep ICC and drop XMP/IPTC"
inspect '{"keepXmp":true,"keepIptc":true,"keepIcc":false}' | json 'd["output"]["xmpBytes"] > 0 and d["output"]["iptcBytes"] > 0 and d["output"]["iccBytes"] == 0' | grep -q True || fail "granular policy was not honoured in the exported bytes"
ok "metadata policy verified on exported bytes"

# Runtime: formats other than WebP come through the minimal route (TIFF is the buffered one).
python3 - "$base" "$here/fixtures/scene.png" <<'PY' || fail "minimal route formats"
import sys, urllib.request
base, path = sys.argv[1], sys.argv[2]
body = open(path, "rb").read()
magic = {"webp": lambda b: b[:4] == b"RIFF", "jpeg": lambda b: b[:2] == b"\xff\xd8", "png": lambda b: b[1:4] == b"PNG", "tiff": lambda b: b[:4] in (b"II*\x00", b"MM\x00*")}
for fmt, check in magic.items():
    data = urllib.request.urlopen(urllib.request.Request(f"{base}/api/minimal/resize?width=300&format={fmt}", data=body)).read()
    assert check(data), fmt
PY
ok "minimal route streams webp, jpeg, png and tiff"

# Runtime: a burst larger than running + queued is shed with 503 and a message; everything accepted still finishes.
python3 - "$base" "$id" <<'PY' || fail "queue behaviour"
import concurrent.futures, json, sys, time, urllib.error, urllib.request
base, upload = sys.argv[1], sys.argv[2]
status0 = json.load(urllib.request.urlopen(base + "/api/status"))
limit = status0["maxConcurrent"] + (status0["limits"]["maxQueued"] or 0)
heavy = {"version": 1, "steps": [{"op": "resize", "params": {"width": 5000, "fit": "inside"}}, {"op": "blur", "params": {"sigma": 6}}, {"op": "median", "params": {"size": 9}}], "output": {"format": "jpeg", "options": {"quality": 60}}}
def one(_):
    req = urllib.request.Request(base + "/api/render", data=json.dumps({"uploadId": upload, "recipe": heavy}).encode())
    try:
        with urllib.request.urlopen(req, timeout=120) as r: r.read(); return r.status, ""
    except urllib.error.HTTPError as e: return e.code, e.read().decode()
n = limit + 8
with concurrent.futures.ThreadPoolExecutor(n) as pool: results = list(pool.map(one, range(n)))
codes = sorted(c for c, _ in results)
assert set(codes) <= {200, 503}, codes
assert codes.count(200) >= status0["maxConcurrent"], codes
assert codes.count(503) >= 1, f"nothing was shed with {n} requests and room for {limit}: {codes}"
assert any("queue" in m for c, m in results if c == 503), "503 without a queue message"
for _ in range(100):
    s = json.load(urllib.request.urlopen(base + "/api/status"))
    if s["active"] == 0 and s["queued"] == 0: break
    time.sleep(0.1)
else: raise AssertionError("the server never went idle")
print(f"{codes.count(200)} accepted, {codes.count(503)} shed, then idle")
PY
ok "burst is shed with 503 and the server returns to idle"

# PDF: a raster page, a vector document with real text, and honest previews of both.
python3 - "$base" "$id" <<'PY' || fail "pdf"
import json, sys, urllib.error, urllib.request
base, upload = sys.argv[1], sys.argv[2]
def post(path, body):
    return urllib.request.urlopen(urllib.request.Request(base + path, data=json.dumps(body).encode()))
catalog = json.load(urllib.request.urlopen(base + "/api/catalog"))
assert any(o["format"] == "pdf" and o["available"] for o in catalog["outputs"]), "pdf output missing"
raster = {"version": 1, "steps": [{"op": "text", "params": {"content": "Pixels only"}}], "output": {"format": "pdf", "options": {"pageSize": "letter", "orientation": "landscape", "title": "T"}}}
real = post("/api/render", {"uploadId": upload, "recipe": raster})
data = real.read()
assert data[:4] == b"%PDF" and float(real.headers["x-hokusai-pdf-width"]) == 792, real.headers["x-hokusai-pdf-width"]
assert b"/ToUnicode" not in data, "a raster page must not carry selectable text"
proxy = post("/api/render", {"uploadId": upload, "recipe": raster, "viewable": True})
png = proxy.read()
assert png[1:4] == b"PNG" and proxy.headers["x-hokusai-proxy-of"] == "application/pdf" and int(proxy.headers["x-hokusai-bytes"]) == len(data)
doc = catalog["vectorPresets"][0]["document"]
vec = post("/api/pdf", {"document": doc})
pdf = vec.read()
assert pdf[:4] == b"%PDF" and vec.headers["x-hokusai-pdf-pages"] == "2" and vec.headers["x-hokusai-selectable-text"] == "true" and b"/ToUnicode" in pdf
page = post("/api/pdf", {"document": doc, "previewPage": 2}).read()
assert page[1:4] == b"PNG"
cmp = json.load(post("/api/compare", {"uploadId": upload, "recipe": {"version": 1, "steps": [], "output": {"format": "png"}}}))
ok = {r["format"] for r in cmp["rows"] if r["ok"]}
assert {"jpeg", "png", "webp", "tiff"} <= ok, ok
bad = {"document": {"version": 1, "pages": [{"items": [{"type": "image", "props": {"asset": "upload"}}]}]}}
try: post("/api/pdf", bad); raise SystemExit("an image item with no upload should be rejected")
except urllib.error.HTTPError as e: assert e.code == 422, e.code
PY
ok "raster PDF (no selectable text), vector PDF (selectable text), page previews, encoder comparison"

# Raw pixels and pages: layouts are read from real bytes, a wrong declaration is refused, pages are real pages.
python3 - "$base" "$here/fixtures" "$id" <<'PY' || fail "raw and pages"
import json, sys, urllib.error, urllib.request
base, fx, upload = sys.argv[1], sys.argv[2], sys.argv[3]
def post(path, data, raw=False):
    return urllib.request.urlopen(urllib.request.Request(base + path, data=data if raw else json.dumps(data).encode()))
def upload_file(name): return json.load(post("/api/uploads", open(f"{fx}/{name}", "rb").read(), raw=True))["uploadId"]
recipe = {"version": 1, "steps": [], "output": {"format": "png"}}
r = post("/api/raw/output", {"uploadId": upload, "recipe": recipe, "format": "rgb16", "maxEdge": 64})
body = r.read(); h = r.headers
assert (h["x-raw-channels"], h["x-raw-bit-depth"], h["x-raw-premultiplied"]) == ("3", "16", "false"), dict(h)
assert int(h["x-raw-row-stride"]) == int(h["x-raw-width"]) * 6 and len(body) == int(h["x-raw-row-stride"]) * int(h["x-raw-height"])
data = bytes((i * 7 + 3) % 256 for i in range(8 * 8 * 4))
ok = post("/api/raw/input?width=8&height=8&format=rgba8", data, raw=True)
assert ok.headers["x-raw-roundtrip"] == "exact" and ok.read()[1:4] == b"PNG"
for query, body in (("width=8&height=8&format=rgba8", data[:-1]), ("width=8&height=8&format=rgb8", data), ("width=8&height=8&format=cmyk8", data)):
    try: post("/api/raw/input?" + query, body, raw=True); raise SystemExit("a wrong raw declaration was accepted: " + query)
    except urllib.error.HTTPError as e: assert e.code in (400, 422), (query, e.code)
gif = upload_file("anim.gif")
facts = json.load(post("/api/inspect", {"uploadId": gif}))["source"]
assert facts["pages"] == 3 and facts["animated"] and facts["frameDelaysMs"] == [200, 200, 200] and facts["loopCount"] == 0, facts
pdf = upload_file("pages.pdf")
p0 = post("/api/render", {"uploadId": pdf, "page": 0, "recipe": recipe}).read()
p2 = post("/api/render", {"uploadId": pdf, "page": 2, "recipe": recipe}).read()
assert p0[1:4] == b"PNG" and p0 != p2, "page selection returned the same image"
assert json.load(post("/api/inspect", {"uploadId": pdf, "page": 1}))["source"]["pages"] == 3
PY
ok "raw output layout, raw input round trip and refusal, page and frame selection"

# Layers and masks: pictures come from a fixed set or from named uploads, never from a path; masks match the image size.
python3 - "$base" "$here/fixtures" "$id" <<'PY' || fail "layers and masks"
import json, sys, urllib.error, urllib.request
base, fx, upload = sys.argv[1], sys.argv[2], sys.argv[3]
def post(path, body, raw=False):
    return urllib.request.urlopen(urllib.request.Request(base + path, data=body if raw else json.dumps(body).encode()))
def render(steps, extra=None, fmt="png"):
    body = {"uploadId": upload, "recipe": {"version": 1, "steps": steps, "output": {"format": fmt}}}
    body.update(extra or {})
    r = post("/api/render", body); return r.read(), r.headers
plain, _ = render([])
layered, h = render([{"op": "layer", "params": {"asset": "emblem.png", "width": 200}}])
assert layered != plain and h["x-hokusai-width"] == "1000", "the emblem layer changed nothing, or resized the picture"
second = json.load(post("/api/uploads", open(f"{fx}/emblem.png", "rb").read(), raw=True))["uploadId"]
with_second, _ = render([{"op": "layer", "params": {"asset": "second", "width": 200}}], {"assets": {"second": second}})
assert with_second != plain, "the second image changed nothing"
try: render([{"op": "layer", "params": {"asset": "second"}}]); raise SystemExit("a missing second image should be refused")
except urllib.error.HTTPError as e: assert e.code == 422, e.code
for evil in ("../../etc/passwd", "/etc/passwd", "scene.png/../mask.png"):
    try: render([{"op": "layer", "params": {"asset": evil}}]); raise SystemExit("a path was accepted as a picture: " + evil)
    except urllib.error.HTTPError as e: assert e.code == 422, (evil, e.code)
recipe = {"version": 1, "steps": [{"id": "r", "op": "resize", "params": {"width": 500, "fit": "inside"}}, {"id": "m", "op": "mask", "params": {"source": "picture"}}], "output": {"format": "png"}}
r = post("/api/render", {"uploadId": upload, "recipe": recipe})
assert r.headers["x-hokusai-width"] == "500", r.headers["x-hokusai-width"]
raw = post("/api/raw/output", {"uploadId": upload, "recipe": recipe, "format": "rgba8", "maxEdge": 100}).read()
alphas = raw[3::4]
assert min(alphas) < max(alphas), "a picture mask should produce partial transparency"
code = json.load(post("/api/code", {"recipe": recipe, "uploadId": upload}))["code"]
assert ".resize(width: 500, height: 800, fit: .fill)" in code, code
PY
ok "image layers, second image by upload, refused paths, picture mask sized to its step"

# Matrices: kernels, colour matrices and affine transforms are described by the catalog, and their grids are validated.
python3 - "$base" "$id" <<'PY' || fail "matrix operations"
import json, sys, urllib.error, urllib.request
base, upload = sys.argv[1], sys.argv[2]
def render(steps):
    body = {"uploadId": upload, "recipe": {"version": 1, "steps": steps, "output": {"format": "png"}}}
    r = urllib.request.urlopen(urllib.request.Request(base + "/api/render", data=json.dumps(body).encode()))
    return r.read(), r.headers
catalog = json.load(urllib.request.urlopen(base + "/api/catalog"))
ops = {o["id"]: o for o in catalog["operations"]}
for op, name in (("convolve", "kernel"), ("recombine", "matrix"), ("affine", "matrix")):
    spec = next(p for p in ops[op]["params"] if p["name"] == name)
    assert spec["kind"] == "matrix" and spec["matrix"]["presets"], op
plain, h0 = render([])
assert render([{"op": "convolve"}])[0] != plain, "the default kernel (sharpen) changed nothing"
assert render([{"op": "convolve", "params": {"kernel": "0 0 0 0 1 0 0 0 0"}}])[0] == plain, "the identity kernel changed the pixels"
assert render([{"op": "recombine", "params": {"matrix": "1 0 0 0 1 0 0 0 1"}}])[0] == plain, "the identity colour matrix changed the pixels"
assert render([{"op": "recombine"}])[0] != plain, "sepia changed nothing"
_, sheared = render([{"op": "affine", "params": {"matrix": "1 0.4 0 1"}}])
assert int(sheared["x-hokusai-width"]) > int(h0["x-hokusai-width"]), "a shear should widen the canvas"
for step in ({"op": "convolve", "params": {"kernel": "1 2 3"}}, {"op": "convolve", "params": {"scale": 0}},
             {"op": "recombine", "params": {"matrix": "1 0 0 1"}}, {"op": "affine", "params": {"matrix": "1 2 2 4"}}):
    try: render([step]); raise SystemExit(f"{step} should be refused")
    except urllib.error.HTTPError as e:
        assert e.code == 422, (step, e.code)
        assert json.load(e)["error"]["message"], step
code = json.load(urllib.request.urlopen(urllib.request.Request(base + "/api/code", data=json.dumps({"recipe": {"version": 1, "steps": [{"op": "recombine"}], "output": {"format": "png"}}}).encode())))["code"]
assert ".recombine(.sepia)" in code, code
PY
ok "convolution kernels, colour matrices and affine transforms: catalog, rendering, refusals, generated Swift"

# A text source: no upload at all, the recipe makes its own pixels.
python3 - "$base" <<'PY' || fail "text source"
import json, sys, urllib.error, urllib.request
base = sys.argv[1]
def post(path, body):
    return urllib.request.urlopen(urllib.request.Request(base + path, data=json.dumps(body).encode()))
def recipe(params=None, steps=None):
    return {"version": 1, "source": {"kind": "text", "params": params or {}}, "steps": steps or [], "output": {"format": "png"}}
catalog = json.load(urllib.request.urlopen(base + "/api/catalog"))
assert any(s["id"] == "text" for s in catalog["sources"]), "the catalog lists no text source"
r = post("/api/render", {"recipe": recipe({"padding": 0})})
data = r.read()
assert data[1:4] == b"PNG" and int(r.headers["x-hokusai-width"]) > 100, r.headers
padded = post("/api/render", {"recipe": recipe({"padding": 50})})
assert int(padded.headers["x-hokusai-width"]) == int(r.headers["x-hokusai-width"]) + 100, "padding is not added on both sides"
small = post("/api/render", {"recipe": recipe(steps=[{"op": "resize", "params": {"width": 300, "fit": "inside"}}])})
assert small.headers["x-hokusai-width"] == "300", "a step after the source did not run"
facts = json.load(post("/api/inspect", {"recipe": recipe()}))
assert facts["source"]["format"] == "png" and facts["output"] is not None, facts
code = json.load(post("/api/code", {"recipe": recipe(), "target": "vapor"}))["code"]
assert 'get("banner")' in code and "Hokusai.text(" in code and "hokusaiImage" not in code, code
for bad in ({"version": 1, "steps": [], "output": {"format": "png"}},                                         # neither source nor upload
            recipe({"content": ""}), {**recipe(), "source": {"kind": "nope"}}):
    try: post("/api/render", {"recipe": bad}); raise SystemExit("should be refused: " + json.dumps(bad)[:80])
    except urllib.error.HTTPError as e: assert e.code == 422, (bad, e.code)
PY
ok "text source: renders without an upload, steps follow it, inspect and code understand it, bad sources are refused"

curl -fsS -X POST "$base/api/code" -d "{\"recipe\":$recipe,\"target\":\"core\"}" | json 'd["code"]' | grep -q ".rotate(by: 90)" || fail "code"
ok "generated Swift"
echo "smoke passed for $expect_backend"

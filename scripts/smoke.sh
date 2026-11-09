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

curl -fsS -X POST "$base/api/code" -d "{\"recipe\":$recipe,\"target\":\"core\"}" | json 'd["code"]' | grep -q ".rotate(by: 90)" || fail "code"
ok "generated Swift"
echo "smoke passed for $expect_backend"

#!/usr/bin/env python3
"""Builds fixtures/metadata.jpg: a small JPEG carrying every kind of embedded block with synthetic values.

EXIF (make, model, artist, copyright, software), an ICC profile, XMP, IPTC and a pixel density, so the Inspect
view can show which blocks survive each output policy. All text is invented for this project. Needs the vips CLI
and macOS's sRGB profile; the result is committed, so this only matters when regenerating.
"""
import pathlib, struct, subprocess, sys, tempfile

root = pathlib.Path(__file__).resolve().parent.parent
icc = pathlib.Path("/System/Library/ColorSync/Profiles/sRGB Profile.icc").read_bytes()

with tempfile.TemporaryDirectory() as t:
    base = pathlib.Path(t) / "base.jpg"
    subprocess.run(["vips", "thumbnail", str(root / "fixtures/scene.png"), f"{base}[Q=85,strip]", "800", "--height", "500", "--size", "force"], check=True)
    jpeg = base.read_bytes()

def segment(marker: int, payload: bytes) -> bytes:
    return bytes([0xFF, marker]) + struct.pack(">H", len(payload) + 2) + payload

# --- EXIF (big-endian TIFF) ---
def ascii_(s): return s.encode() + b"\0"
entries = [(0x010F, "Hokusai Fixture Co."), (0x0110, "Synthetic Camera 1"), (0x0131, "hokusai-examples fixture script"),
           (0x013B, "Fixture Artist"), (0x8298, "Public domain, generated for tests")]
n = len(entries) + 1                                  # + orientation
ifd_size = 2 + n * 12 + 4
data_off = 8 + ifd_size
blobs, rows = b"", []
for tag, text in sorted(entries + [(0x0112, None)], key=lambda e: e[0]):
    if tag == 0x0112:
        rows.append(struct.pack(">HHIHH", tag, 3, 1, 1, 0))      # orientation 1 (upright)
    else:
        v = ascii_(text)
        rows.append(struct.pack(">HHII", tag, 2, len(v), data_off + len(blobs)))
        blobs += v + (b"\0" if len(v) % 2 else b"")
tiff = b"MM\0*" + struct.pack(">I", 8) + struct.pack(">H", n) + b"".join(rows) + struct.pack(">I", 0) + blobs
exif = segment(0xE1, b"Exif\0\0" + tiff)

# --- XMP ---
xmp_packet = ('<?xpacket begin="﻿" id="W5M0MpCehiHzreSzNTczkc9d"?><x:xmpmeta xmlns:x="adobe:ns:meta/">'
              '<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description rdf:about="" '
              'xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title><rdf:Alt><rdf:li xml:lang="x-default">Lighthouse at dusk (synthetic)'
              '</rdf:li></rdf:Alt></dc:title></rdf:Description></rdf:RDF></x:xmpmeta><?xpacket end="w"?>').encode()
xmp = segment(0xE1, b"http://ns.adobe.com/xap/1.0/\0" + xmp_packet)

# --- IPTC (Photoshop 3.0 / 8BIM 0x0404): caption 2:120, keywords 2:25 ---
def iptc(record, dataset, value): return b"\x1c" + bytes([record, dataset]) + struct.pack(">H", len(value)) + value
iptc_data = iptc(2, 120, b"A synthetic lighthouse, for tests") + iptc(2, 25, b"hokusai") + iptc(2, 25, b"fixture")
if len(iptc_data) % 2: iptc_data += b"\0"
bim = b"8BIM" + struct.pack(">H", 0x0404) + b"\0\0" + struct.pack(">I", len(iptc_data)) + iptc_data
iptc_seg = segment(0xED, b"Photoshop 3.0\0" + bim)

# --- ICC (one chunk) ---
icc_seg = segment(0xE2, b"ICC_PROFILE\0\x01\x01" + icc)

# --- JFIF with 300 dpi ---
jfif = segment(0xE0, b"JFIF\0\x01\x01" + bytes([1]) + struct.pack(">HH", 300, 300) + b"\0\0")

assert jpeg[:2] == b"\xff\xd8"
# drop any JFIF libvips wrote, then insert ours and the metadata right after SOI
i = 2
while jpeg[i] == 0xFF and jpeg[i + 1] in (0xE0, 0xE1, 0xE2, 0xED):
    i += 2 + struct.unpack(">H", jpeg[i + 2:i + 4])[0]
out = jpeg[:2] + jfif + exif + xmp + iptc_seg + icc_seg + jpeg[i:]
(root / "fixtures/metadata.jpg").write_bytes(out)
print("wrote fixtures/metadata.jpg", len(out), "bytes")

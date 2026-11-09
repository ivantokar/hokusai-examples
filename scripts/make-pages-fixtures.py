#!/usr/bin/env python3
"""Builds fixtures/anim.gif: a 3-frame animated GIF (a square moving across a 160x100 canvas, 200 ms per frame).

Pure Python, no imaging library: a tiny LZW encoder writes the frames. The multi-page PDF fixture (fixtures/pages.pdf)
is produced by `swift run --package-path recipes recipes-tool pages-pdf fixtures/pages.pdf`, so HokusaiPDF makes it.
"""
import pathlib, struct

W, H = 160, 100
palette = [(27, 58, 87), (241, 234, 216), (192, 86, 31), (47, 125, 140)]          # navy, beige, orange, teal
frames = []
for i in range(3):
    px = [[0] * W for _ in range(H)]
    for y in range(H):                      # teal ground line, beige sky
        for x in range(W):
            px[y][x] = 1 if y < 70 else 3
    x0 = 12 + i * 48
    for y in range(34, 70):                  # orange square standing on the line
        for x in range(x0, x0 + 36):
            px[y][x] = 2
    for x in range(W):                       # navy frame counter bars: i+1 bars
        pass
    for k in range(i + 1):
        for y in range(8, 20):
            for x in range(8 + k * 16, 20 + k * 16):
                px[y][x] = 0
    frames.append([c for row in px for c in row])

def lzw(indices, min_code=2):
    clear, eoi = 1 << min_code, (1 << min_code) + 1
    size, nxt = min_code + 1, eoi + 1
    table = {(i,): i for i in range(clear)}
    out, acc, nbits = bytearray(), 0, 0
    def emit(code):
        nonlocal acc, nbits
        acc |= code << nbits; nbits += size
        while nbits >= 8: out.append(acc & 255); acc >>= 8; nbits -= 8
    emit(clear)
    cur = ()
    for v in indices:
        nxt_seq = cur + (v,)
        if nxt_seq in table: cur = nxt_seq; continue
        emit(table[cur])
        if nxt < 4096:
            table[nxt_seq] = nxt; nxt += 1
            if nxt - 1 == (1 << size) and size < 12: size += 1
        else:
            emit(clear); table = {(i,): i for i in range(clear)}; size, nxt = min_code + 1, eoi + 1
        cur = (v,)
    emit(table[cur]); emit(eoi)
    if nbits: out.append(acc & 255)
    return bytes(out)

def blocks(data):
    return b"".join(bytes([len(data[i:i + 255])]) + data[i:i + 255] for i in range(0, len(data), 255)) + b"\0"

gif = b"GIF89a" + struct.pack("<HHBBB", W, H, 0xF1, 0, 0) + b"".join(bytes(c) for c in palette)
gif += b"\x21\xFF\x0BNETSCAPE2.0\x03\x01\x00\x00\x00"                         # loop forever
for frame in frames:
    gif += b"\x21\xF9\x04\x04" + struct.pack("<H", 20) + b"\x00\x00"           # 200 ms, no transparency, keep frame
    gif += b"\x2C" + struct.pack("<HHHHB", 0, 0, W, H, 0) + bytes([2]) + blocks(lzw(frame))
gif += b"\x3B"
out = pathlib.Path(__file__).resolve().parent.parent / "fixtures/anim.gif"
out.write_bytes(gif)
print("wrote", out, len(gif), "bytes")

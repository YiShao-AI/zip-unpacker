#!/usr/bin/env python3
"""Fixtures for FormatTests: one small payload in every format 7-Zip handles for us.
Needs: pip install py7zr zstandard. RAR samples come from libarchive's test suite (BSD-2-Clause),
see Fixtures/formats/RAR-SOURCE.txt. Password for the encrypted ones: test-pw (RAR: "password")."""
import bz2, gzip, io, lzma, os, random, sys, tarfile, zipfile
import py7zr, zstandard

out = sys.argv[1]
os.makedirs(out, exist_ok=True)
random.seed(42)
clip = bytes(random.getrandbits(8) for _ in range(32 * 1024))
payload = {'7月17日舞蹈/说明.txt': '你好，世界\n'.encode() * 20, '7月17日舞蹈/clip (1).mp4': clip, 'readme.txt': b'hello\n' * 100}
open(os.path.join(out, 'clip.bin'), 'wb').write(clip)

src = os.path.join(out, '_src')
for k, v in payload.items():
    p = os.path.join(src, k); os.makedirs(os.path.dirname(p), exist_ok=True); open(p, 'wb').write(v)
P = lambda n: os.path.join(out, n)

with py7zr.SevenZipFile(P('plain.7z'), 'w') as z: z.writeall(src, 'p')
with py7zr.SevenZipFile(P('enc.7z'), 'w', password='test-pw') as z: z.writeall(src, 'p')
with py7zr.SevenZipFile(P('enchdr.7z'), 'w', password='test-pw', header_encryption=True) as z: z.writeall(src, 'p')
enc = open(P('enc.7z'), 'rb').read()
open(P('split.7z.001'), 'wb').write(enc[:len(enc) // 2]); open(P('split.7z.002'), 'wb').write(enc[len(enc) // 2:])

for name, mode in [('a.tar', 'w'), ('a.tar.gz', 'w:gz'), ('a.tar.bz2', 'w:bz2'), ('a.tar.xz', 'w:xz')]:
    with tarfile.open(P(name), mode) as t: t.add(src, 'p')
open(P('a.tar.zst'), 'wb').write(zstandard.ZstdCompressor().compress(open(P('a.tar'), 'rb').read()))
open(P('one.mp4.gz'), 'wb').write(gzip.compress(clip))
open(P('one.mp4.bz2'), 'wb').write(bz2.compress(clip))
open(P('one.mp4.xz'), 'wb').write(lzma.compress(clip))
open(P('one.mp4.lzma'), 'wb').write(lzma.compress(clip, format=lzma.FORMAT_ALONE))
open(P('one.mp4.zst'), 'wb').write(zstandard.ZstdCompressor().compress(clip))
for name, m in [('bzip2.zip', zipfile.ZIP_BZIP2), ('lzma.zip', zipfile.ZIP_LZMA)]:
    with zipfile.ZipFile(P(name), 'w', m) as z:
        for k, v in payload.items(): z.writestr(k, v)
# Nested: a 7z inside a zip, and a split 7z inside a zip (Baidu style).
with zipfile.ZipFile(P('zip-with-7z.zip'), 'w', zipfile.ZIP_STORED) as z: z.write(P('enc.7z'), 'inner/dance.7z')
with zipfile.ZipFile(P('zip-with-split7z.zip'), 'w', zipfile.ZIP_STORED) as z:
    z.write(P('split.7z.001'), 'dance.7z.001'); z.write(P('split.7z.002'), 'dance.7z.002')

import shutil; shutil.rmtree(src)
print('ok')

# TT-tools PNGs: a file hidden in the low bits of the pixels. See TTImage.swift for the layout.
import hashlib, struct, zlib

def tt_png(name, blob, *, start=0.20, side=256, ctype=2, base=128):
    """Square PNG with `blob` stored from row int(side * start). Rows rotate through all five PNG filters."""
    stream = struct.pack('>I', len(blob)) + blob
    bits = [b >> (7 - i) & 1 for b in stream for i in range(8)]
    channels = {2: 3, 6: 4}[ctype]
    rnd = random.Random(7)
    rows = []
    n = 0
    first = int(side * start)
    assert (side - first) * side * 3 >= len(bits), name
    for y in range(side):
        line = bytearray()
        for x in range(side):
            px = [(base + rnd.randrange(40)) & 0xFF for _ in range(3)]
            for k in range(3):
                if y >= first and n < len(bits):        # other pixels keep random low bits, like a watermark
                    px[k] = px[k] & 0xFE | bits[n]; n += 1
            line += bytes(px + ([200] if channels == 4 else []))
        rows.append(line)
    raw = bytearray()
    prev = bytearray(len(rows[0]))
    for y, line in enumerate(rows):
        f = y % 5
        out = bytearray()
        for i, v in enumerate(line):
            a = line[i - channels] if i >= channels else 0
            b = prev[i]
            c = prev[i - channels] if i >= channels else 0
            if f == 4:
                p = a + b - c; pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pred = a if pa <= pb and pa <= pc else b if pb <= pc else c
            else:
                pred = (0, a, b, (a + b) // 2)[f]
            out.append((v - pred) & 0xFF)
        raw += bytes([f]) + out
        prev = line
    def chunk(t, d): return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d))
    comp = zlib.compress(bytes(raw))
    png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', side, side, 8, ctype, 0, 0, 0))
    png += b''.join(chunk(b'IDAT', comp[i:i + 4000]) for i in range(0, len(comp), 4000)) + chunk(b'IEND', b'')
    open(P(name), 'wb').write(png)

def tt_blob(data, ext, password=None):
    e = ext.encode()
    if password is None: return bytes([0, len(e)]) + e + struct.pack('>I', len(data)) + data
    salt = bytes(random.getrandbits(8) for _ in range(16))
    km = (password + salt.hex()).encode()
    ks = b''.join(hashlib.sha256(km + str(i).encode()).digest() for i in range(len(data) // 32 + 1))
    enc = bytes(a ^ b for a, b in zip(data, ks))
    return bytes([1]) + hashlib.sha256(km).digest() + salt + bytes([len(e)]) + e + struct.pack('>I', len(enc)) + enc

tt_clip = clip[:6000]
open(P('ttclip.bin'), 'wb').write(tt_clip)
tt_png('tt-new.png', tt_blob(tt_clip, 'mp4'))                                  # newest layout: 20 %, RGB
tt_png('tt-old-rgba.png', tt_blob(tt_clip, 'mp4'), start=0.05, ctype=6)        # older layout: 5 %, alpha present
tt_png('tt-pw.png', tt_blob(tt_clip, 'mp4', 'test-pw'))                        # password
tt_png('tt-noflag.png', bytes([3]) + b'mp4' + struct.pack('>I', len(tt_clip)) + tt_clip, start=0.05)   # "TT img enc"
with zipfile.ZipFile(P('_tt.zip'), 'w', zipfile.ZIP_STORED) as z: z.writestr('clip (1).mp4', tt_clip)
zipped = open(P('_tt.zip'), 'rb').read(); os.remove(P('_tt.zip'))
tt_png('tt-rawzip.png', zipped, start=0.0)                                     # before v1.0.5: the bytes of a zip
tt_png('tt-zip.png', tt_blob(zipped, 'zip'))                                   # a zip inside, opened as a next layer
tt_png('ordinary.png', b'', start=0.0)                                          # just a picture

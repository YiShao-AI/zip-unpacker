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

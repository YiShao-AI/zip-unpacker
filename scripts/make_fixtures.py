#!/usr/bin/env python3
"""Generate the test fixtures in Core/Tests/UnpackCoreTests/Fixtures.

Needs: pip install pyzipper
The fixtures imitate the Baidu files: a .pdf-named AES-256 zip that holds a
second .pdf-named AES-256 zip, with GBK (not UTF-8) filenames. They use the
test password "test-pw" and contain only generated data.
"""
import hashlib, io, json, os, random, struct, sys, zipfile, zlib
import pyzipper

OUT = os.path.join(os.path.dirname(__file__), "..", "Core", "Tests", "UnpackCoreTests", "Fixtures")
PW = b"test-pw"
expected = {}


def placeholder(real: bytes, tag: str) -> bytes:
    ph = ("PH" + tag).encode()
    assert len(ph) <= len(real)
    return ph + b"_" * (len(real) - len(ph))


def patch(buf: bytes, mapping: dict) -> bytes:
    for ph, real in mapping.items():
        assert len(ph) == len(real)
        assert buf.count(ph) == 2, (ph, buf.count(ph))  # local header + central dir
        buf = buf.replace(ph, real)
    return buf


def unicode_path_extra(raw_name: bytes, utf8_name: str) -> bytes:
    u = utf8_name.encode("utf-8")
    return struct.pack("<HHBI", 0x7075, 5 + len(u), 1, zlib.crc32(raw_name)) + u


rng = random.Random(1717)
random_bin = bytes(rng.getrandbits(8) for _ in range(50_000))
text = "".join(f"line {i}: 舞蹈 dance {i * i}\n" for i in range(8000)).encode("utf-8")
notes = "这是说明文件 / readme\n".encode("utf-8")

# ---- inner layer: AES-256, GBK names, mixed stored/deflate ----
inner_names = {
    "内层/": None,
    "内层/说明.txt": (notes, zipfile.ZIP_STORED, True),     # also carries 0x7075 Unicode path
    "内层/数据.txt": (text, zipfile.ZIP_DEFLATED, False),
    "内层/random.bin": (random_bin, zipfile.ZIP_STORED, False),
}
mapping = {}
buf = io.BytesIO()
with pyzipper.AESZipFile(buf, "w", encryption=pyzipper.WZ_AES) as z:
    z.setpassword(PW)
    z.setencryption(pyzipper.WZ_AES, nbits=256)
    for i, (name, spec) in enumerate(inner_names.items()):
        gbk = name.encode("gbk")
        ph = placeholder(gbk, f"i{i}")
        mapping[ph] = gbk
        zi = z.zipinfo_cls(ph.decode(), date_time=(2025, 7, 17, 12, 0, 0))
        if spec is None:
            zi.external_attr = 0o40755 << 16 | 0x10
            z.writestr(zi, b"")
            continue
        data, method, add_unicode = spec
        zi.compress_type = method
        if add_unicode:
            zi.extra = unicode_path_extra(gbk, name)
        z.writestr(zi, data)
inner = patch(buf.getvalue(), mapping)

# ---- outer layer: AES-256 store of the inner zip, GBK names ----
outer_names = {"外层文件夹/": None, "外层文件夹/内层.pdf": inner}
mapping = {}
buf = io.BytesIO()
with pyzipper.AESZipFile(buf, "w", compression=zipfile.ZIP_STORED, encryption=pyzipper.WZ_AES) as z:
    z.setpassword(PW)
    for i, (name, data) in enumerate(outer_names.items()):
        gbk = name.encode("gbk")
        ph = placeholder(gbk, f"o{i}")
        mapping[ph] = gbk
        zi = z.zipinfo_cls(ph.decode(), date_time=(2025, 7, 17, 12, 0, 0))
        zi.compress_type = zipfile.ZIP_STORED
        if data is None:
            zi.external_attr = 0o40755 << 16 | 0x10
            data = b""
        z.writestr(zi, data)
outer = patch(buf.getvalue(), mapping)
open(os.path.join(OUT, "nested.pdf"), "wb").write(outer)
sha = lambda b: hashlib.sha256(b).hexdigest()
expected["nested"] = {"说明.txt": sha(notes), "数据.txt": sha(text), "random.bin": sha(random_bin)}

# ---- AES-128 deflate, UTF-8 names (flag set) ----
with pyzipper.AESZipFile(os.path.join(OUT, "aes128.zip"), "w", compression=zipfile.ZIP_DEFLATED,
                         encryption=pyzipper.WZ_AES) as z:
    z.setpassword(PW)
    z.setencryption(pyzipper.WZ_AES, nbits=128)
    z.writestr("视频/clip.txt", text)
expected["aes128"] = {"clip.txt": sha(text)}

# ---- ZipCrypto (legacy) deflate, written by hand ----
CRC_TABLE = []
for n in range(256):
    c = n
    for _ in range(8):
        c = (c >> 1) ^ 0xEDB88320 if c & 1 else c >> 1
    CRC_TABLE.append(c)


class Keys:
    def __init__(self, pw):
        self.k = [0x12345678, 0x23456789, 0x34567890]
        for b in pw:
            self.update(b)

    def update(self, b):
        k0, k1, k2 = self.k
        k0 = CRC_TABLE[(k0 ^ b) & 0xFF] ^ (k0 >> 8)
        k1 = ((k1 + (k0 & 0xFF)) * 134775813 + 1) & 0xFFFFFFFF
        k2 = CRC_TABLE[(k2 ^ (k1 >> 24)) & 0xFF] ^ (k2 >> 8)
        self.k = [k0, k1, k2]

    def encrypt(self, data):
        out = bytearray()
        for p in data:
            t = (self.k[2] | 2) & 0xFFFF
            out.append(p ^ (((t * (t ^ 1)) >> 8) & 0xFF))
            self.update(p)
        return bytes(out)


def zipcrypto_zip(entries, pw):
    out, cd = bytearray(), bytearray()
    for name, data in entries:
        co = zlib.compressobj(9, zlib.DEFLATED, -15)
        comp = co.compress(data) + co.flush()
        crc = zlib.crc32(data)
        header = bytes(range(1, 12)) + bytes([crc >> 24])
        enc = Keys(pw).encrypt(header + comp)
        nb = name.encode("utf-8")
        off = len(out)
        out += struct.pack("<IHHHHHIIIHH", 0x04034B50, 20, 0x801, 8, 0, 0x5AF1, crc, len(enc), len(data), len(nb), 0) + nb + enc
        cd += struct.pack("<IHHHHHHIIIHHHHHII", 0x02014B50, 20, 20, 0x801, 8, 0, 0x5AF1, crc, len(enc), len(data),
                          len(nb), 0, 0, 0, 0, 0, off) + nb
    n = len(entries)
    return bytes(out + cd + struct.pack("<IHHHHIIH", 0x06054B50, 0, 0, n, n, len(cd), len(out), 0))


zc = zipcrypto_zip([("legacy/old.txt", text)], PW)
with zipfile.ZipFile(io.BytesIO(zc)) as z:  # sanity check with Python's own reader
    assert z.read("legacy/old.txt", pwd=PW) == text
open(os.path.join(OUT, "zipcrypto.zip"), "wb").write(zc)
expected["zipcrypto"] = {"old.txt": sha(text)}

# ---- unencrypted: a nested plain zip, a .docx (must NOT be opened), and a zip-slip name ----
docx = io.BytesIO()
with zipfile.ZipFile(docx, "w") as z:
    z.writestr("word/document.xml", "<w/>")
nested_plain = io.BytesIO()
with zipfile.ZipFile(nested_plain, "w", zipfile.ZIP_DEFLATED) as z:
    z.writestr("deep.txt", notes)
with zipfile.ZipFile(os.path.join(OUT, "plain.zip"), "w", zipfile.ZIP_DEFLATED) as z:
    z.writestr("report.docx", docx.getvalue())
    z.writestr("inner.zip", nested_plain.getvalue())
    z.writestr("../evil.txt", notes)
    z.writestr("__MACOSX/._junk", b"junk")
    # raw name says "uni.txt" but the Info-ZIP Unicode Path field says "统一码.txt"; the reader must prefer the latter
    zi = zipfile.ZipInfo("uni.txt", date_time=(2025, 7, 17, 12, 0, 0))
    zi.extra = unicode_path_extra(b"uni.txt", "统一码.txt")
    z.writestr(zi, notes)
expected["plain"] = {"report.docx": sha(docx.getvalue()), "inner/deep.txt": sha(notes), "evil.txt": sha(notes),
                     "统一码.txt": sha(notes)}

# ---- not supported: 7z signature ----
open(os.path.join(OUT, "fake7z.pdf"), "wb").write(b"7z\xbc\xaf\x27\x1c" + b"\0" * 64)

json.dump(expected, open(os.path.join(OUT, "expected.json"), "w"), ensure_ascii=False, indent=1)
print("fixtures written:", sorted(os.listdir(OUT)))

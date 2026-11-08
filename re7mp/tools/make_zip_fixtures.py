#!/usr/bin/env python3
"""Writes the small zip files tests/core_tests.cpp unpacks (stored, fixed-Huffman, dynamic-Huffman, nested and unsafe
entries, a fake REFramework package and a fake release). The contents are re-created in the test from the same
formulas, so the expected bytes are not stored. Run from the project folder: python3 tools/make_zip_fixtures.py"""
import os, struct, zipfile, zlib

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tests", "data")
os.makedirs(OUT, exist_ok=True)

def random_bytes(n, seed):            # mirrors random_bytes() in tests/core_tests.cpp
    x = (seed * 2654435761 + 1) & 0xFFFFFFFF
    out = bytearray()
    for _ in range(n):
        x = (x * 1664525 + 1013904223) & 0xFFFFFFFF
        out.append(x >> 24)
    return bytes(out)

def text_block(n):                     # mirrors text_block() in the test
    return "".join("The quick brown fox jumps over %d lazy dogs\n" % i for i in range(n)).encode()

def fake_exe(n, seed):                 # looks like a Windows program to the updater's check
    return b"MZ" + random_bytes(n - 2, seed)

def add(z, name, data, method=zipfile.ZIP_DEFLATED, level=6):
    zi = zipfile.ZipInfo(name, date_time=(2026, 11, 7, 12, 0, 0))
    zi.compress_type = method
    zi.external_attr = 0o644 << 16
    z.writestr(zi, data, compress_type=method, compresslevel=level if method == zipfile.ZIP_DEFLATED else None)

with zipfile.ZipFile(os.path.join(OUT, "sample.zip"), "w") as z:
    add(z, "hello.txt", b"Hello, zip!\n")                                     # fixed Huffman
    add(z, "big_text.txt", text_block(3000), level=9)                        # dynamic Huffman
    add(z, "random.bin", random_bytes(40000, 5), level=9)                    # incompressible: stored blocks
    add(z, "stored.txt", b"stored, not deflated\n" * 50, method=zipfile.ZIP_STORED)
    add(z, "empty.txt", b"")
    add(z, "dir/", b"", method=zipfile.ZIP_STORED)
    add(z, "dir/nested.txt", b"nested\n" * 100)
    add(z, "fast.bin", text_block(500) + random_bytes(3000, 8), level=1)     # a different mix
    add(z, "../escape.txt", b"must never be written outside\n")
    add(z, "back\\slash.txt", b"backslash path\n")
    add(z, "C:/drive.txt", b"drive letter\n")

# damaged copy: one byte flipped inside big_text.txt's compressed data
raw = bytearray(open(os.path.join(OUT, "sample.zip"), "rb").read())
with zipfile.ZipFile(os.path.join(OUT, "sample.zip")) as z:
    info = z.getinfo("random.bin")
off = info.header_offset + 30 + len(info.filename.encode()) + 0
raw[off + 200] ^= 0xFF
open(os.path.join(OUT, "damaged.zip"), "wb").write(bytes(raw))

# a pretend REFramework RE7.zip: the loader, VR files, and a reframework folder
with zipfile.ZipFile(os.path.join(OUT, "refw.zip"), "w") as z:
    add(z, "dinput8.dll", fake_exe(80000, 21))
    add(z, "openvr_api.dll", fake_exe(70000, 22))
    add(z, "reframework/", b"", method=zipfile.ZIP_STORED)
    add(z, "reframework/autorun/example.lua", b"-- shipped example\n")
    add(z, "reframework/data/readme.txt", b"data folder\n")
    add(z, "../../outside.dll", fake_exe(70000, 23))

# a REFramework zip with no loader, and one with a corrupt loader
with zipfile.ZipFile(os.path.join(OUT, "refw_noloader.zip"), "w") as z:
    add(z, "openvr_api.dll", fake_exe(70000, 22))

# a release asset: re7mp.exe inside a folder, next to source files
with zipfile.ZipFile(os.path.join(OUT, "release.zip"), "w") as z:
    add(z, "re7mp/README.md", b"readme\n")
    add(z, "re7mp/re7mp.exe", fake_exe(90000, 31))
    add(z, "re7mp/lua/re7mp.lua", b"-- lua\n")

with zipfile.ZipFile(os.path.join(OUT, "release_noexe.zip"), "w") as z:
    add(z, "re7mp/README.md", b"readme\n")
    add(z, "re7mp/lua/re7mp.lua", b"-- lua\n")

print("wrote", sorted(os.listdir(OUT)))

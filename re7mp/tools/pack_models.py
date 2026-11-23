#!/usr/bin/env python3
"""(10.13) Packs modpack/third-person-full-models/ into modpack/third-person-full-models.zip, the file src/app.rc embeds in the exe (resource 103),
so the exe installs AfroJackX's full character models itself (Nexus RE7 mod 86; see CREDITS.txt).

The zip has the same layout as the author's own download (natives/stm/... plus modinfo.ini), with CREDITS.txt added, so the same installer code reads it
(install_model_pack). Deterministic: sorted names, fixed timestamps, so the same pack always gives the same bytes.

  python3 tools/pack_models.py            # (re)build the zip
  python3 tools/pack_models.py --check    # exit 1 if the zip is missing or out of date
"""
import os
import sys
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "modpack", "third-person-full-models")
OUT = os.path.join(ROOT, "modpack", "third-person-full-models.zip")
STAMP = (2022, 1, 28, 0, 0, 0)  # the models' own date


def files():
    out = []
    for base, _dirs, names in os.walk(SRC):
        for n in names:
            full = os.path.join(base, n)
            out.append((os.path.relpath(full, SRC).replace(os.sep, "/"), full))
    out.sort()
    return out


def build(path):
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for rel, full in files():
            zi = zipfile.ZipInfo(rel, STAMP)
            zi.compress_type = zipfile.ZIP_DEFLATED
            zi.external_attr = 0o644 << 16
            with open(full, "rb") as f:
                z.writestr(zi, f.read(), compresslevel=9)


def same(path):
    if not os.path.exists(path):
        return False
    with zipfile.ZipFile(path) as z:
        have = {i.filename: i.CRC for i in z.infolist()}
    import binascii
    want = {}
    for rel, full in files():
        with open(full, "rb") as f:
            want[rel] = binascii.crc32(f.read()) & 0xFFFFFFFF
    return have == want


if __name__ == "__main__":
    if not os.path.isdir(os.path.join(SRC, "natives")):
        sys.exit("no natives folder in " + SRC)
    if "--check" in sys.argv:
        sys.exit(0 if same(OUT) else 1)
    if same(OUT):
        print("up to date:", OUT)
    else:
        build(OUT)
        print("wrote", OUT, os.path.getsize(OUT), "bytes,", len(files()), "files")

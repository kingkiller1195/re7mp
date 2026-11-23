#!/usr/bin/env python3
"""Checks tools/pack_alpha.py's guards with made-up exes (no real build needed, standard library only).

    python tools/test_pack_alpha.py

(10.25) The packer must only pack an alpha from an exe that was built from THIS script AND with the alpha link. The link is the text
"re7mp-alpha-link=owner/name" that src/alpha_channel.hpp puts into the exe; the repository's name alone proves nothing, because the normal updater's own web
addresses contain it (an exe built before the link has the name too: case A below is exactly that exe, and it must be refused).
(10.26) An alpha is named by NUMBER, "v0.11 alpha 3": the script's ALPHA label says it, a normal release has ALPHA = "0" and is refused, and the exe has to carry
the same number (it reads which alpha it is from its own copy of the script). The cases run on a COPY of the real source tree whose script is set to alpha 3
(the real tree is a normal release, so it is checked as it is, too: case J).
Every case runs the real packer in a child process and looks at its exit code and what it says. Nothing is written outside a temporary folder.
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
failed = 0
total = 0


def check(name, ok, detail=""):
    global failed, total
    total += 1
    if not ok:
        failed += 1
    print(("  ok    " if ok else "  FAIL  ") + name + ("" if ok else "   <- " + detail))


def label(text, name):
    m = re.search(r'\b' + name + r'\s*=\s*"([^"]+)"', text[:16384])
    return m.group(1) if m else ""


DEFAULT_RELEASE = "0.11"  # set in main() from the real script


def fake_exe(path, build, alpha, marker=None, release=None):
    """MZ + padding + what a real exe has that the packer looks at: the script's BUILD and ALPHA labels, the normal updater's web addresses (they contain
    the repository's name), and, when `marker` is not None, the link text (NUL-terminated, like a C string). alpha None = an exe from before 10.26."""
    data = b"MZ" + b"\0" * 70000
    data += b'BUILD = "%s"\0' % build.encode()
    data += b'    RELEASE = "%s",\0' % (release or DEFAULT_RELEASE).encode()
    if alpha is not None:
        data += b'    ALPHA = "%s",\0BODY_ALPHA = 215\0' % alpha.encode()
    data += b"https://api.github.com/repos/kingkiller1195/re7mp/releases/latest\0https://github.com/kingkiller1195/re7mp/releases\0"
    if marker is not None:
        data += b"re7mp-alpha-link=" + marker.encode() + b"\0"
    open(path, "wb").write(data)


def run(packer, exe, out, *extra):
    p = subprocess.run([sys.executable, "-I", packer, "--exe", exe, "--out", out] + list(extra), capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr


def copy_tree(dst, alpha, release=None, header_release=None):
    """A copy of the real source the packer reads (script with ALPHA = alpha, defaults, the alpha header, updater.hpp, the changelog) and the packer itself."""
    for d in ("tools", "lua", os.path.join("data", "re7mp"), "src"):
        os.makedirs(os.path.join(dst, d))
    shutil.copy(os.path.join(HERE, "pack_alpha.py"), os.path.join(dst, "tools", "pack_alpha.py"))
    lua = open(os.path.join(ROOT, "lua", "re7mp.lua"), encoding="utf-8", errors="replace").read()
    new, n = re.subn(r'(\n\s*ALPHA\s*=\s*)"[^"]*"', lambda m: m.group(1) + '"%s"' % alpha, lua, count=1)
    assert n == 1, "the script has no ALPHA label"
    if release:
        new, n = re.subn(r'(\n\s*RELEASE\s*=\s*)"[^"]*"', lambda m: m.group(1) + '"%s"' % release, new, count=1)
        assert n == 1, "the script has no RELEASE label"
    open(os.path.join(dst, "lua", "re7mp.lua"), "w", encoding="utf-8").write(new)
    vh = open(os.path.join(ROOT, "src", "version.hpp"), encoding="utf-8").read()
    vh = re.sub(r'(kReleaseVersion\s*=\s*)"[^"]*"', lambda m: m.group(1) + '"%s"' % (header_release or release or DEFAULT_RELEASE), vh, count=1)
    open(os.path.join(dst, "src", "version.hpp"), "w", encoding="utf-8").write(vh)
    for rel in (os.path.join("data", "re7mp", "defaults.json"), os.path.join("src", "alpha_channel.hpp"), os.path.join("src", "updater.hpp"), "CHANGELOG.md"):
        if os.path.exists(os.path.join(ROOT, rel)):
            shutil.copy(os.path.join(ROOT, rel), os.path.join(dst, rel))
    return os.path.join(dst, "tools", "pack_alpha.py")


def main():
    lua = open(os.path.join(ROOT, "lua", "re7mp.lua"), encoding="utf-8", errors="replace").read()
    global DEFAULT_RELEASE
    build, release, real_alpha = label(lua, "BUILD"), label(lua, "RELEASE"), label(lua, "ALPHA")
    DEFAULT_RELEASE = release
    header = open(os.path.join(ROOT, "src", "alpha_channel.hpp"), encoding="utf-8").read()
    m = re.search(r'#define\s+RE7MP_ALPHA_REPO\s+"([^"]*)"', header)
    repo = m.group(1) if m else ""
    print("script build %s, release %s, alpha %s, source link '%s'" % (build, release, real_alpha, repo))
    check("the source links the alpha to the SAME repository as the normal releases (updater.hpp)", repo != "" and
          ('repos/%s/releases/latest' % repo) in open(os.path.join(ROOT, "src", "updater.hpp"), encoding="utf-8").read(), "repo=%r" % repo)
    check("the script has an ALPHA label (a whole number; 0 = a normal release)", re.fullmatch(r'\d{1,4}', real_alpha or "") is not None, "alpha=%r" % real_alpha)

    tmp = tempfile.mkdtemp(prefix="re7mp_packtest_")
    try:
        # ---- the real source tree, as it is: a normal release ----------------------------------------
        print("real tree:")
        real = os.path.join(HERE, "pack_alpha.py")
        exe_j = os.path.join(tmp, "J.exe"); fake_exe(exe_j, build, real_alpha, repo)
        code, text = run(real, exe_j, os.path.join(tmp, "oJ"))
        if real_alpha == "0":
            check("J: a normal release (ALPHA = \"0\") is refused: it is not an alpha", code != 0 and "NORMAL release" in text and not os.path.exists(os.path.join(tmp, "oJ")), text[-300:])
        else:
            check("J: the real tree is set to alpha %s: it packs" % real_alpha, code == 0, text[-300:])

        # ---- a copy of it set to alpha 3 -------------------------------------------------------------
        print("copy of the real tree, ALPHA = 3:")
        pk = copy_tree(os.path.join(tmp, "copy"), "3")
        exe_a = os.path.join(tmp, "A_built_before_the_link.exe");  fake_exe(exe_a, build, "3", None)
        exe_b = os.path.join(tmp, "B_linked.exe");                 fake_exe(exe_b, build, "3", repo)
        exe_c = os.path.join(tmp, "C_empty_link.exe");             fake_exe(exe_c, build, "3", "")
        exe_d = os.path.join(tmp, "D_other_link.exe");             fake_exe(exe_d, build, "3", "someone/else")
        exe_f = os.path.join(tmp, "F_other_build.exe");            fake_exe(exe_f, "1.2", "3", repo)
        exe_k = os.path.join(tmp, "K_other_alpha.exe");            fake_exe(exe_k, build, "2", repo)
        exe_l = os.path.join(tmp, "L_before_alpha_numbers.exe");   fake_exe(exe_l, build, None, repo)
        code, text = run(pk, exe_a, os.path.join(tmp, "oA"))
        check("A: an exe from before the link (it has the repository's name, but no link text) is refused", code != 0 and "no alpha link in it" in text and not os.path.exists(os.path.join(tmp, "oA")), text[-300:])
        code, text = run(pk, exe_b, os.path.join(tmp, "oB"))
        zpath = os.path.join(tmp, "oB", "re7mp-alpha-%s-3.zip" % release)
        ok = code == 0 and os.path.exists(zpath)
        if ok:
            with zipfile.ZipFile(zpath) as z:
                ok = sorted(z.namelist()) == ["data/re7mp/defaults.json", "lua/re7mp.lua", "re7mp.exe"]
                ok = ok and 'ALPHA = "3"' in z.read("lua/re7mp.lua").decode("utf-8", "replace")
        check("B: an exe with the right link and alpha number is packed as re7mp-alpha-<release>-3.zip (exactly the three files, the script says alpha 3)", ok, text[-300:])
        rel = os.path.join(tmp, "oB", "alpha-%s-3-release.txt" % release)
        rtext = open(rel, encoding="utf-8").read() if os.path.exists(rel) else ""
        title, tag = "v%s alpha 3" % release, "v%s-alpha-3" % release
        check("B: the release text names the repository, the title \"%s\" and the tag \"%s\", and says to tick pre-release but not latest" % (title, tag),
              ("github.com/" + repo) in rtext and title in rtext and tag in rtext and 'TICK "Set as a pre-release"' in rtext and "UNTICKED" in rtext, rtext[:300])
        check("B: ...and explains the order (an alpha is in between: the normal v0.13 is newer than v0.12 alpha 10)", "in-between" in rtext and "v0.13" in rtext and "ALPHA back to" in rtext, rtext[-900:])
        code, text = run(pk, exe_c, os.path.join(tmp, "oC"))
        check("C: an exe built with an EMPTY link is refused", code != 0 and "links the alpha to nothing" in text, text[-300:])
        code, text = run(pk, exe_d, os.path.join(tmp, "oD"))
        check("D: an exe linked to another repository is refused", code != 0 and "someone/else" in text, text[-300:])
        code, text = run(pk, exe_f, os.path.join(tmp, "oF"))
        check("F: an exe built from another script (other BUILD) is still refused first", code != 0 and "NOT built from this script" in text, text[-300:])
        code, text = run(pk, exe_k, os.path.join(tmp, "oK"))
        check("K: an exe built as another alpha (ALPHA 2, the script says 3) is refused and says which it carries", code != 0 and 'alpha "2"' in text and not os.path.exists(os.path.join(tmp, "oK")), text[-300:])
        code, text = run(pk, exe_l, os.path.join(tmp, "oL"))
        check("L: an exe from before the alpha numbers (no ALPHA label in it at all) is refused", code != 0 and "no alpha label I can find" in text, text[-300:])
        # (10.26 part 3) the release number: the first alpha after v0.11 is public is "v0.12 alpha 1", so script RELEASE, src/version.hpp and the exe's
        # own copy of the script all have to say it
        exe_m = os.path.join(tmp, "M_other_release.exe");          fake_exe(exe_m, build, "3", repo, release="0.9")
        code, text = run(pk, exe_m, os.path.join(tmp, "oM"))
        check("M: an exe whose script says another RELEASE (0.9) is refused and says which it carries", code != 0 and "NOT built with RELEASE" in text and 'release "0.9"' in text and not os.path.exists(os.path.join(tmp, "oM")), text[-300:])
        pn = copy_tree(os.path.join(tmp, "copy_n"), "3", release=None, header_release="0.7")
        code, text = run(pn, exe_b, os.path.join(tmp, "oN"))
        check("N: src/version.hpp saying another release than the script's RELEASE is refused (the exe would offer itself the same update forever)", code != 0 and "src/version.hpp says release 0.7" in text and not os.path.exists(os.path.join(tmp, "oN")), text[-300:])
        nxt = "0.12"
        po = copy_tree(os.path.join(tmp, "copy_o"), "1", release=nxt)
        exe_o = os.path.join(tmp, "O_next_release.exe");           fake_exe(exe_o, build, "1", repo, release=nxt)
        code, text = run(po, exe_o, os.path.join(tmp, "oO"))
        relo = os.path.join(tmp, "oO", "alpha-%s-1-release.txt" % nxt)
        rto = open(relo, encoding="utf-8").read() if os.path.exists(relo) else ""
        check("O: the alpha of the NEXT release (script, version.hpp and exe all say 0.12) packs as v0.12 alpha 1 / v0.12-alpha-1 / re7mp-alpha-0.12-1.zip",
              code == 0 and os.path.exists(os.path.join(tmp, "oO", "re7mp-alpha-%s-1.zip" % nxt)) and "v0.12 alpha 1" in rto and "v0.12-alpha-1" in rto, text[-300:])
        code, text = run(pk, exe_a, os.path.join(tmp, "oE"), "--allow-unlinked")
        check("E: --allow-unlinked packs the old exe for a trial and says so loudly", code == 0 and "WARNING (--allow-unlinked)" in text and os.path.exists(os.path.join(tmp, "oE", "re7mp-alpha-%s-3.zip" % release)), text[-300:])

        # ---- alpha numbers that are not alpha numbers ---------------------------------------------------
        print("bad ALPHA labels:")
        for bad, why in (("0", "NORMAL release"), ("", "NORMAL release"), ("x", "whole number"), ("3.1", "whole number"), ("10000", "whole number"), ("03", "whole number")):
            tb = copy_tree(os.path.join(tmp, "bad_" + (bad or "empty")), bad)
            fake_exe(os.path.join(tmp, "bad.exe"), build, bad, repo)
            code, text = run(tb, os.path.join(tmp, "bad.exe"), os.path.join(tmp, "oBad_" + (bad or "empty")))
            check("ALPHA = \"%s\" is refused (%s)" % (bad, why), code != 0 and why in text, text[-250:])

        # ---- a made-up tree whose header has no link ------------------------------------------------
        print("made-up tree, source not linked:")
        t = os.path.join(tmp, "tree")
        for d in ("tools", "lua", os.path.join("data", "re7mp"), "src"):
            os.makedirs(os.path.join(t, d))
        shutil.copy(real, os.path.join(t, "tools", "pack_alpha.py"))
        open(os.path.join(t, "lua", "re7mp.lua"), "w").write('BUILD = "9.9",\nRELEASE = "0.1"\nALPHA = "2",\n')
        open(os.path.join(t, "data", "re7mp", "defaults.json"), "w").write('{"build":"9.9"}')
        open(os.path.join(t, "src", "alpha_channel.hpp"), "w").write('#ifndef RE7MP_ALPHA_REPO\n#define RE7MP_ALPHA_REPO ""\n#endif\n')
        open(os.path.join(t, "src", "version.hpp"), "w").write('constexpr const char* kReleaseVersion = "0.1";\n')
        exe_g = os.path.join(tmp, "G.exe");  fake_exe(exe_g, "9.9", "2", "", release="0.1")
        exe_h = os.path.join(tmp, "H.exe");  fake_exe(exe_h, "9.9", "2", "kingkiller1195/re7mp", release="0.1")
        pm = os.path.join(t, "tools", "pack_alpha.py")
        code, text = run(pm, exe_g, os.path.join(tmp, "oG"))
        check("G: a source with no link is refused, even for an exe that matches it", code != 0 and "RE7MP_ALPHA_REPO is empty" in text, text[-300:])
        code, text = run(pm, exe_h, os.path.join(tmp, "oH"))
        check("H: a source with no link is refused for a linked exe too (they must agree)", code != 0 and "RE7MP_ALPHA_REPO is empty" in text, text[-300:])
        code, text = run(pm, exe_g, os.path.join(tmp, "oI"), "--allow-unlinked")
        check("I: --allow-unlinked packs it for a trial (release 0.1, alpha 2)", code == 0 and os.path.exists(os.path.join(tmp, "oI", "re7mp-alpha-0.1-2.zip")), text[-300:])
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print("%d of %d checks passed" % (total - failed, total))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Packs an ALPHA release of re7mp for GitHub (written for build 10.24, link check from 10.25, alpha NUMBERS from 10.26).

An alpha release is named "v<release> alpha <n>" ("v0.11 alpha 3"), is flagged pre-release on GitHub, and counts as an in-between version: alpha n of
release X sits between the release before X and X itself (older than the normal X, newer than the earlier alphas of it), so the normal v0.13 is newer than "v0.12 alpha 10". The number n is the script's
ALPHA label (lua/re7mp.lua: ALPHA = "3"); a normal release has ALPHA = "0" and this packer refuses it.

The release number is the one the alpha is heading to: the first alpha after v0.11 is public is "v0.12 alpha 1", so RELEASE (lua/re7mp.lua) and kReleaseVersion
(src/version.hpp) both say 0.12 for it, and the packer refuses an exe or a source tree where they disagree.

What it does, in the order it does it (it stops at the first thing that is wrong and says what):
  1. reads the build, the release number and the alpha number from lua/re7mp.lua (BUILD = "10.26", RELEASE = "0.11", ALPHA = "3");
  2. checks data/re7mp/defaults.json is the same build (it is built together with the script) and that src/version.hpp (kReleaseVersion) says the same
     release number as the script's RELEASE;
  3. checks the re7mp.exe you give it WAS BUILT FROM THIS SCRIPT: the exe carries a copy of the script inside it, so its bytes contain `BUILD = "10.26"`,
     `RELEASE = "0.11"` AND `ALPHA = "3"`. An exe that carries another build or another alpha number is refused: a tester would get an exe that says one thing and a
     script that says another (and the exe reads its own alpha number from that copy, to know what to offer);
  3b. checks the alpha is LINKED: src/alpha_channel.hpp says which repository (RE7MP_ALPHA_REPO) and the exe carries the same link text
      ("re7mp-alpha-link=owner/name"). An exe built before the link was set, or built with another one, would send every tester back to the normal
      releases at its first start, so it is refused (--allow-unlinked packs it anyway, for a trial);
  4. writes dist/re7mp-alpha-0.11-3.zip with exactly what re7mp.exe's updater reads: re7mp.exe, lua/re7mp.lua, data/re7mp/defaults.json;
  5. writes dist/alpha-0.11-3-release.txt: the title, the tag and the notes to paste into GitHub's "new release" page, and what to tick.

    python tools/pack_alpha.py --exe C:\\path\\to\\re7mp.exe            (run it from the folder that holds lua\\, data\\ and tools\\)

Standard library only. It never touches GitHub: you create the release there yourself (the release-text file says how).
"""
import argparse
import json
import os
import re
import sys
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LABEL_RE = re.compile(r'(?i)(?<![a-z0-9])alpha(?![a-z])[ \-_.:#]*(?:build|b|v)?[ \-_.:#]*(\d+)(?!\.?\d)')  # the same rule as alpha_number_in() in src/updater.cpp (a whole number)
NOTES_WINDOW = 700  # the join window and the update window show this many characters of the notes


def fail(msg):
    print("\nSTOPPED: " + msg)
    sys.exit(1)


def label_of(text, name):
    m = re.search(r'\b' + name + r'\s*=\s*"([^"]+)"', text[:16384])
    return m.group(1) if m else ""


def changelog_notes(build):
    """The bold lead of every numbered item under "What changed" for this build: a short list a tester can read in a window."""
    path = os.path.join(ROOT, "CHANGELOG.md")
    if not os.path.exists(path):
        return []
    text = open(path, encoding="utf-8").read()
    m = re.search(r'^## What changed in v' + re.escape(build) + r'\b.*?$(.*?)(?=^## |\Z)', text, re.S | re.M)
    if not m:
        return []
    items = re.findall(r'^- \*\*(\d+\.\s.*?)\*\*', m.group(1), re.M)
    return [re.sub(r'\s+', ' ', i).strip() for i in items]


def main():
    ap = argparse.ArgumentParser(description="Pack an alpha release of re7mp for GitHub.")
    ap.add_argument("--exe", required=True, help="the re7mp.exe you built from THIS source")
    ap.add_argument("--out", default=os.path.join(ROOT, "dist"), help="where the zip and the release text go (default: dist)")
    ap.add_argument("--allow-unlinked", action="store_true", help="pack even though no alpha repository is linked in the source (only for a trial: see the message)")
    args = ap.parse_args()

    lua_path = os.path.join(ROOT, "lua", "re7mp.lua")
    defaults_path = os.path.join(ROOT, "data", "re7mp", "defaults.json")
    version_path = os.path.join(ROOT, "src", "version.hpp")
    for p in (lua_path, defaults_path, version_path, args.exe):
        if not os.path.isfile(p):
            fail("not found: " + p)

    lua = open(lua_path, encoding="utf-8", errors="replace").read()
    build, release, alpha = label_of(lua, "BUILD"), label_of(lua, "RELEASE"), label_of(lua, "ALPHA")
    if not re.fullmatch(r'\d+(\.\d+)+', build or ""):
        fail('lua/re7mp.lua has no BUILD = "10.26" style label (found "%s")' % build)
    if not re.fullmatch(r'\d+(\.\d+)*', release or ""):
        fail('lua/re7mp.lua has no RELEASE = "0.11" style label (found "%s")' % release)
    if alpha in ("", "0"):
        fail('lua/re7mp.lua says ALPHA = "%s": that is a NORMAL release, not an alpha. For an alpha set ALPHA = "<n>" (1, 2, 3 ... for "v%s alpha <n>"), '
             'rebuild re7mp.exe (it embeds the script) and run this again. Put it back to "0" for the normal release.' % (alpha, release))
    if not re.fullmatch(r'[1-9]\d{0,3}', alpha):
        fail('lua/re7mp.lua has ALPHA = "%s": it has to be a whole number from 1 to 9999 (the alpha number of v%s)' % (alpha, release))

    # (10.26 part 3) the release number the alpha is NAMED for must be the number the exe knows itself by. The exe compares itself with GitHub's releases as
    # (kReleaseVersion, its alpha number): an alpha built for v0.12 with src/version.hpp still saying 0.11 would call itself "v0.11 alpha 1", see "v0.12 alpha 1"
    # as newer, and offer itself the same update every time it checks.
    mv = re.search(r'kReleaseVersion\s*=\s*"([^"]*)"', open(version_path, encoding="utf-8", errors="replace").read())
    if not mv or mv.group(1) != release:
        fail('src/version.hpp says release %s but lua/re7mp.lua says RELEASE = "%s". An alpha of v%s needs BOTH to say %s (change kReleaseVersion and RELEASE together, '
             'then rebuild re7mp.exe): an exe that disagrees would call itself "v%s alpha %s" and offer itself the same update forever.'
             % (mv.group(1) if mv else "no release", release, release, release, mv.group(1) if mv else "?", alpha))

    defaults = json.load(open(defaults_path, encoding="utf-8"))
    if str(defaults.get("build", "")) != build:
        fail("data/re7mp/defaults.json says build %s but the script says %s: rebuild it with tools/build_defaults.py --build %s" % (defaults.get("build"), build, build))

    exe = open(args.exe, "rb").read()
    if len(exe) < 64 * 1024 or exe[:2] != b"MZ":
        fail(args.exe + " does not look like a Windows program")
    if not re.search(rb'BUILD\s*=\s*"' + re.escape(build.encode()) + rb'"', exe):
        carried = re.search(rb'BUILD\s*=\s*"([0-9.]+)"', exe)
        fail("this re7mp.exe was NOT built from this script. The script is build %s; the exe carries %s.\n"
             "Rebuild re7mp.exe from this source (it embeds lua\\re7mp.lua), then run this again."
             % (build, carried.group(1).decode() if carried else "no build label I can find"))
    # (10.26 part 3) the release number: the exe's copy of the script has to say it too (an exe built before RELEASE was bumped does not)
    if not re.search(rb'(?<![A-Za-z0-9_.])RELEASE\s*=\s*"' + re.escape(release.encode()) + rb'"', exe):
        carried = re.search(rb'(?<![A-Za-z0-9_.])RELEASE\s*=\s*"([0-9.]+)"', exe)
        fail("this re7mp.exe was NOT built with RELEASE = \"%s\" in the script: it carries %s.\n"
             "Rebuild re7mp.exe from this source (it embeds lua\\re7mp.lua), then run this again."
             % (release, ('release "%s"' % carried.group(1).decode()) if carried else "no release label I can find"))
    # (10.26) the alpha number: the exe reads which alpha it IS from its own copy of the script, so the copy must say the number this release is called
    if not re.search(rb'(?<![A-Za-z0-9_.])ALPHA\s*=\s*"' + re.escape(alpha.encode()) + rb'"', exe):
        carried = re.search(rb'(?<![A-Za-z0-9_.])ALPHA\s*=\s*"([0-9]*)"', exe)
        fail("this re7mp.exe was NOT built with ALPHA = \"%s\" in the script: it carries %s.\n"
             "Rebuild re7mp.exe from this source (it embeds lua\\re7mp.lua), then run this again."
             % (alpha, ('alpha "%s"' % carried.group(1).decode()) if carried else "no alpha label I can find (an exe from before 10.26)"))

    # (10.25) THE LINK. An alpha exe that has no repository linked sends the tester back to the normal releases at its first start (re7mp.ini says
    # channel=alpha, but this exe has nowhere to look). The source says which repository (#define RE7MP_ALPHA_REPO in src/alpha_channel.hpp, the SAME one the
    # normal releases are in) and an exe built with that link carries the text "re7mp-alpha-link=owner/name" (kAlphaLinkMark). The repository's name alone
    # proves nothing: the normal updater's web addresses already contain it, so an exe built before the link has it too.
    header = open(os.path.join(ROOT, "src", "alpha_channel.hpp"), encoding="utf-8").read()
    m = re.search(r'#define\s+RE7MP_ALPHA_REPO\s+"([^"]*)"', header)
    repo = m.group(1) if m else ""
    marks = set(x.decode() for x in re.findall(rb're7mp-alpha-link=([A-Za-z0-9._/-]*)\x00', exe))
    problem = ""
    if not repo:
        problem = 'src/alpha_channel.hpp has no alpha repository linked (RE7MP_ALPHA_REPO is empty).'
    elif not marks:
        problem = ("this re7mp.exe has no alpha link in it: it was built before the link was set (10.25). Rebuild it from this source.")
    elif marks != {repo}:
        problem = ("this re7mp.exe links the alpha to %s, but the source links it to %s. Rebuild it from this source."
                   % (", ".join(sorted(x or "nothing" for x in marks)), repo))
    if problem:
        if not args.allow_unlinked:
            fail(problem + "\nAn alpha exe like that would send every tester back to the normal releases the first time it starts. (--allow-unlinked packs it anyway, "
                 "for a trial on your own machine.)")
        print("WARNING (--allow-unlinked): " + problem)

    title, tag = "v%s alpha %s" % (release, alpha), "v%s-alpha-%s" % (release, alpha)
    zip_name = "re7mp-alpha-%s-%s.zip" % (release, alpha)
    for what, text in (("title", title), ("tag", tag)):
        mm = LABEL_RE.search(text)
        if not (mm and mm.group(1) == alpha and re.match(r'v?' + re.escape(release) + r'(?![0-9.])', text)):
            fail("internal check: the %s I would use (%s) does not read as alpha %s of release %s" % (what, text, alpha, release))
    low = zip_name.lower()
    if "src" in low or "source" in low:
        fail("internal check: a zip with 'src' or 'source' in its name is skipped by the updater")

    os.makedirs(args.out, exist_ok=True)
    zip_path = os.path.join(args.out, zip_name)
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as z:
        z.writestr("re7mp.exe", exe)
        z.write(lua_path, "lua/re7mp.lua")
        z.write(defaults_path, "data/re7mp/defaults.json")
    with zipfile.ZipFile(zip_path) as z:  # read it back the way the updater does
        names = sorted(z.namelist())
        if names != ["data/re7mp/defaults.json", "lua/re7mp.lua", "re7mp.exe"] or z.testzip() is not None:
            fail("the zip I wrote does not read back correctly: " + ", ".join(names))
        if z.read("lua/re7mp.lua").decode("utf-8", "replace") != lua:
            fail("the script inside the zip is not the one on disk")

    items = changelog_notes(build)
    body = "\n".join("- " + i for i in items) if items else "(write what changed in this build here: it is shown to the tester in the join and update windows)"
    note_len = len(body)
    text = """GITHUB RELEASE FOR %(title)s   (script build %(build)s)
==============================================================

On github.com/%(repo_page)s > Releases > "Draft a new release"   (the SAME repository as the normal releases: an alpha is a pre-release there)

  Title          %(title)s          <- must say "alpha %(alpha)s" and the release number: that is how re7mp.exe finds it, tells it from a normal release and puts it in order
  Tag            %(tag)s            (create it on publish)
  Pre-release    TICK "Set as a pre-release"   (this is what marks it as the alpha on the page; the normal updater would skip it even without the tick)
  Latest         leave "Set as the latest release" UNTICKED (GitHub does not allow both). The NORMAL release is the one that is not a pre-release.
  Attach         %(zip)s            (ONE file, from the dist folder)
  Description    paste the notes below, then edit them: they are what a tester sees in the "Join the alpha?" window and when an update is offered

--- notes (from CHANGELOG.md, the bold start of each numbered item; %(n)d characters, the windows show the first %(win)d) ---
%(body)s
--- end of notes ---

How it is ordered: an alpha is an in-between version. %(title)s is newer than the earlier alphas of it and than the release before v%(release)s, and older than the normal
v%(release)s itself (so a tester on it is offered v%(release)s when it comes out, and a normal v0.13 is newer than "v0.12 alpha 10"). A player on the alpha channel is offered the newest of ALL the releases, alpha or
normal; a player on the normal releases is never offered an alpha.
What the exe does with it: re7mp.exe's "Join the alpha..." / "Check now" asks GitHub for the releases of the alpha repository and offers the newest one when it is
newer than what the running exe is (v%(release)s alpha %(alpha)s here). Installing it replaces re7mp.exe and puts lua\\re7mp.lua and data\\re7mp\\defaults.json into the
game folder. It refuses a release whose script says another release number or another alpha number than the title does.
After this: put ALPHA back to "0" in lua\\re7mp.lua before you build the next NORMAL release (and set "n+1" for the next alpha).
""" % dict(build=build, release=release, alpha=alpha, title=title, tag=tag, zip=zip_name, body=body, n=note_len,
           win=NOTES_WINDOW, repo_page=repo or "<the alpha repository>")
    text_path = os.path.join(args.out, "alpha-%s-%s-release.txt" % (release, alpha))
    open(text_path, "w", encoding="utf-8").write(text)

    print("Packed %s (script build %s), linked to %s." % (title, build, repo or "NOTHING (trial only)"))
    print("  zip:   %s  (%.1f MB)" % (zip_path, os.path.getsize(zip_path) / 1048576.0))
    print("  text:  %s" % text_path)
    if note_len > NOTES_WINDOW:
        print("  note:  the notes are %d characters; the windows show the first %d, so put the important lines first." % (note_len, NOTES_WINDOW))
    if not items:
        print("  note:  CHANGELOG.md has no numbered 'What changed' items for %s: write the notes yourself." % build)


if __name__ == "__main__":
    main()

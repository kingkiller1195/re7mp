#!/usr/bin/env python3
"""
Builds re7mp/defaults.json: the one file that ships with a release and holds
  * the built-in animation clips (so a new install animates the other player's body instead of leaving it in a T pose)
  * the default settings (a copy of your own re7mp/settings.json, with the RELEASE_OVERRIDES below applied)

Usage (run it from anywhere):
    python build_defaults.py --data "<...>/reframework/data" --out "<release folder>/reframework/data/re7mp/defaults.json"

Where clips are read from (the first one found for a label wins):
    1. <data>/re7mp/clips/<label>.json     (recordings made by build 9.30 and later)
    2. <data>/re7mp_clip_<label>.json      (recordings made by older builds)
Cutscene recordings (labels starting with "cs_") are never bundled.

Every clip is checked with the same rules as CFG.clip.valid in re7mp.lua, so a damaged recording is reported here, not in a player's game.
Nothing in <data> is changed.
"""
import argparse
import hashlib
import json
import os
import sys

# Settings that must not ship switched on, whatever the developer's own file says.
# (cutscene_probe records every cutscene and writes files: a developer tool, not a default for players.)
RELEASE_OVERRIDES = {
    # (9.44) Item sync stays ON, but it shares only consumables and weapons (item_safe_only, whose code default is True and which is never shipped off):
    # a key item (the fuse, the bolt cutters) stays in each game. The developer's own settings file must not turn the filter off for players.
    "item_sync": True,
    "item_safe_only": True,
    "cutscene_probe": False,
    # (9.38) the probe is NOT linked to cutscenes: a recording starts only when the tester presses "Record now".
    "cutscene_link": False,
    # (9.33) "make the loopback bot face me" is a testing tool; the developer's own file has it on.
    "face_me": False,
    # (9.30) the real body is the default, so the green man is only a debug model: it is drawn anywhere it is switched on, and the two
    # "hide it behind walls / while a menu is open" mechanics are off. A real body is hidden by the game's own depth test.
    "occlude": False,
    "menu_hide": False,
    # (9.35) Loading models from their FILES is ON in the shipped defaults: Mia's playable body (Pl2000) "works better" than the corrupted Mia,
    # and Clancy and the enemy models are made this way. Ethan is NEVER made from files (the script refuses): he is copied from the scene,
    # because a body made from his files "spawned with no textures". (9.33 shipped this off after two engine crashes in sessions that had
    # loaded resources this way; the script still switches it off at the next start after a session that ended inside a load, see loadstate.json.)
    "load_by_path": True,
    # (9.35) The item journal (hooks on three item calls) and its object scan are not wanted for an average player: their calls could lag the game.
    # With the journal off the hooks are not even installed. (The in-game box still turns it on for a tester.)
    "item_journal": False,
    "item_scan": False,
    # (9.35) Giving the LAST one of a kind (a whole inventory entry) is on: the crafting-way removal (reduceItem, third argument false) worked in the
    # real game, and the way that crashed it 4 times is gone. An unreadable inventory is still refused.
    "give_last": True,
    # (9.35) "These are the right Mia settings" (the 9.34 screenshots): the layers of the corrupted Mia's head switched by name, her own skin on,
    # the corrupted skin and the blend between them off, the eyes, the hair and the tear layers on; her playable body gets that head and chain hair.
    # Her own pl2050 head is the game's shadow-only head (it drew black), so it stays off. The side-lock hair meshes (GpuCloth) are hidden: without
    # the cloth they draw as flat white shards. The hair physics is a new experiment (a copied via.motion.Chain): it ships UNticked until seen working.
    "mia_layers_on": True,
    "mia_own_head": False,
    "mia_head_parts": True,
    "mia_layers": {
        "Eye_Shadow": True,
        "em2050_Eye_Blend": True,
        "em2050_Hair": True,
        "em2050_Skin_Blend": False,
        "em2050_Skin_Evil": False,
        "em2050_Skin_Mia": True,
        "eye_Tear": True,
    },
    "body_hidden": ["Em2000LeftHair", "Em2000RightHair"],
    "real_body_hair": False,
    "real_body_model": "Pl0000_Chapter1",
    "hair_physics": False,
}

# (9.33) Settings that are one player's own choices or testing leftovers: they are never shipped, so the code's own default applies.
#   who_choice, who_follow   the "Play as" choice belongs to re7mp.exe (a new player starts on "auto")
#   story_callout, story_watch   the story message callouts and the watch-only list are per player; the story SWITCHES are never saved at all
# (9.35) the Mia keys are shipped now (RELEASE_OVERRIDES); tape_on / tape_hide went with the tape watcher (removed in 9.35).
NEVER_SHIP = ["who_choice", "who_follow", "story_callout", "story_watch", "tape_on", "tape_hide"]

# A learned gun signal that is a PrevWeaponActionID is the PREVIOUS weapon's action: it was 2 during a block with empty hands (the 9.7
# recording), so a new install would show the gun pose for every unarmed block. It is left out of the shipped settings (the script then
# uses PlayerGun.actionID, and lets the pose go 12 s after the last aim or shot). The aim signal is kept.
def drop_unsafe_gun_signal(settings):
    gs = settings.get("gun_signals")
    if isinstance(gs, dict) and isinstance(gs.get("gun"), dict) and "PrevWeaponActionID" in json.dumps(gs["gun"]):
        del gs["gun"]
        print("dropped the learned gun signal (a PrevWeaponActionID); the aim signal is kept")
        if not gs:
            del settings["gun_signals"]

# Labels the script knows (CFG.clip.LABELS minus "auto"); anything else is reported and skipped.
KNOWN_LABELS = {
    "idle", "walk", "run", "crouch", "crouch_walk", "guard", "heal", "inventory", "aim", "shoot", "reload", "melee", "other",
    "gun_idle", "gun_walk", "gun_run", "gun_crouch", "gun_aim", "gun_shoot", "gun_reload",
}
REQUIRED = ["idle"]  # the real body needs at least an idle clip, otherwise it stays in its T pose


def valid(d):
    """Same checks as CFG.clip.valid in re7mp.lua."""
    if not isinstance(d, dict) or not isinstance(d.get("body"), dict):
        return "no body block"
    rate, dur = d.get("rate"), d.get("dur")
    if not isinstance(rate, (int, float)) or isinstance(rate, bool) or rate <= 0:
        return "bad rate"
    if not isinstance(dur, (int, float)) or isinstance(dur, bool) or dur <= 0.2:
        return "bad duration"
    b = d["body"]
    names, frames, na = b.get("names"), b.get("frames"), b.get("na")
    if not isinstance(names, list) or not isinstance(frames, list) or not isinstance(na, int) or na != 3 * len(names) or len(frames) < 4:
        return "bad names/frames/na"
    want = na + (3 if b.get("hip") else 0)
    for i in (0, len(frames) - 1):
        f = frames[i]
        if not isinstance(f, list) or len(f) != want:
            return "frame %d has %s values, expected %d" % (i, len(f) if isinstance(f, list) else "?", want)
        if any(isinstance(v, bool) or not isinstance(v, (int, float)) for v in f):
            return "frame %d has a non-number" % i
    return None


def load_json(path):
    with open(path, "r", encoding="utf-8") as fh:
        return json.load(fh)


def collect_clips(data_dir):
    found = {}  # label -> (path, clip)
    legacy_prefix = "re7mp_clip_"
    sources = []
    new_dir = os.path.join(data_dir, "re7mp", "clips")
    if os.path.isdir(new_dir):
        for fn in sorted(os.listdir(new_dir)):
            if fn.endswith(".json"):
                sources.append((fn[:-5], os.path.join(new_dir, fn)))
    for fn in sorted(os.listdir(data_dir)):
        if fn.startswith(legacy_prefix) and fn.endswith(".json"):
            sources.append((fn[len(legacy_prefix):-5], os.path.join(data_dir, fn)))
    problems = []
    for label, path in sources:
        if label.startswith("cs_"):
            continue
        if label in found:
            continue  # an earlier (newer-location) file already has this label
        if label not in KNOWN_LABELS:
            problems.append("skipped %s: not a label the script knows" % os.path.basename(path))
            continue
        try:
            clip = load_json(path)
        except Exception as exc:  # noqa: BLE001 - report any read/parse failure
            problems.append("skipped %s: %s" % (os.path.basename(path), exc))
            continue
        why = valid(clip)
        if why:
            problems.append("skipped %s: %s" % (os.path.basename(path), why))
            continue
        found[label] = (path, clip)
    return found, problems


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--data", required=True, help="the reframework/data folder with your recordings and settings")
    ap.add_argument("--out", required=True, help="where to write defaults.json")
    ap.add_argument("--settings", help="settings file to use (default: <data>/re7mp/settings.json, or the older <data>/re7mp_settings.json)")
    ap.add_argument("--build", default="", help="script build label to record in the file, e.g. 9.30")
    ap.add_argument("--clips-from", help="an earlier defaults.json: its clips are used for every label the data folder has no recording of "
                                         "(so the bundle can be rebuilt without the recordings folder)")
    ap.add_argument("--settings-from", help="an earlier defaults.json: its settings are used when there is no settings file (so the bundle can be "
                                            "rebuilt, with new overrides, without the developer's own settings file)")
    args = ap.parse_args()

    clips, problems = collect_clips(args.data)
    if args.clips_from:
        old = load_json(args.clips_from).get("clips", {})
        for label, clip in sorted(old.items()):
            if label in clips or label.startswith("cs_") or label not in KNOWN_LABELS:
                continue
            why = valid(clip)
            if why:
                problems.append("skipped %s from %s: %s" % (label, args.clips_from, why))
                continue
            clips[label] = (args.clips_from + "#" + label, clip)
    settings_path = args.settings
    if not settings_path:  # 9.30 builds keep it in the re7mp folder; older ones next to the other files
        settings_path = os.path.join(args.data, "re7mp", "settings.json")
        if not os.path.isfile(settings_path):
            settings_path = os.path.join(args.data, "re7mp_settings.json")
    settings = {}
    if os.path.isfile(settings_path):
        settings = load_json(settings_path)
        if not isinstance(settings, dict):
            print("settings file is not a JSON object: %s" % settings_path)
            return 1
    elif args.settings_from:
        settings = load_json(args.settings_from).get("settings", {})
        if not isinstance(settings, dict):
            print("no settings in %s" % args.settings_from)
            return 1
        problems.append("no settings file at %s: the settings of %s are used" % (settings_path, args.settings_from))
    else:
        problems.append("no settings file at %s: the bundle will carry no default settings" % settings_path)
    for k in NEVER_SHIP:
        if k in settings:
            print("not shipped: %s (%r)" % (k, settings[k]))
            del settings[k]
    drop_unsafe_gun_signal(settings)
    for k, v in RELEASE_OVERRIDES.items():
        if settings.get(k) != v:
            print("override: %s %r -> %r" % (k, settings.get(k), v))
        settings[k] = v

    missing = [r for r in REQUIRED if r not in clips]
    if missing:
        print("ERROR: required clip(s) missing: %s (the other player's body would stay in a T pose)" % ", ".join(missing))
        return 1

    bundle = {
        "format": 1,
        "about": "re7mp built-in defaults: animation clips and default settings. Shipped with the release; the script never writes it. "
                 "A player's own recordings and settings file always win.",
        "build": args.build,
        "settings": dict(sorted(settings.items())),
        "clips": {label: clip for label, (_, clip) in sorted(clips.items())},
    }
    text = json.dumps(bundle, separators=(",", ":"), ensure_ascii=False)
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(text)

    digest = hashlib.sha256(text.encode("utf-8")).hexdigest()
    print("wrote %s: %d bytes, sha256 %s" % (args.out, len(text.encode("utf-8")), digest[:16]))
    for label, (path, clip) in sorted(clips.items()):
        print("  clip %-12s %5.1f s  %3d frames  %d joints%s   <- %s" % (
            label, clip["dur"], len(clip["body"]["frames"]), len(clip["body"]["names"]),
            " + hands" if clip.get("hands") else "", os.path.relpath(path, args.data)))
    absent = sorted(KNOWN_LABELS - set(clips))
    if absent:
        print("  no clip for: %s (the script falls back as in CFG.clip.FALLBACK)" % ", ".join(absent))
    print("  settings: %d keys" % len(settings))
    for p in problems:
        print("  note: " + p)
    return 0


if __name__ == "__main__":
    sys.exit(main())

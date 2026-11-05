#!/usr/bin/env python3
"""Stand-in for the Lua script, so you can test the sidecar without launching RE7.

Writes a moving position to <data-dir>/re7mp_out.json (what the Lua script does) and
prints whatever the sidecar publishes to <data-dir>/re7mp_in.json.

  python fake_game.py --data-dir .\\a --start 0 0 0 --seconds 5
"""
import argparse, json, math, os, time


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data-dir", required=True)
    ap.add_argument("--start", nargs=3, type=float, default=[0, 0, 0])
    ap.add_argument("--seconds", type=float, default=5)
    ap.add_argument("--hz", type=float, default=20)
    args = ap.parse_args()

    os.makedirs(args.data_dir, exist_ok=True)
    out_path = os.path.join(args.data_dir, "re7mp_out.json")
    in_path = os.path.join(args.data_dir, "re7mp_in.json")
    x0, y0, z0 = args.start
    t_end = time.time() + args.seconds
    seq = 0
    last_in = None
    while time.time() < t_end:
        seq += 1
        t = seq / args.hz
        pos = {"seq": seq, "x": x0 + math.cos(t) * 5, "y": y0, "z": z0 + math.sin(t) * 5}
        with open(out_path, "w") as f:
            json.dump(pos, f)
        try:
            with open(in_path) as f:
                inbound = json.load(f)
            if inbound != last_in:
                last_in = inbound
        except (OSError, ValueError):
            pass
        time.sleep(1.0 / args.hz)
    print("last position received from peer:", last_in)


if __name__ == "__main__":
    main()

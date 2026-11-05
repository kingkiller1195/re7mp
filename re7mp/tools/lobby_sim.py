"""Transliteration of the Lua ready-check logic (local_flags, start_ready, cancel_ready,
on_local_new_game, update_lobby) plus a lossy, laggy two-player network, to look for deadlocks,
double starts and early starts. Not the Lua itself, but the same state machine."""
import math, random

FLAG_READY, FLAG_SEES, FLAG_GO = 1, 8, 16
STALE_AFTER, READY_TIMEOUT, GO_LATCH, COUNTDOWN = 2.0, 120, 5, 3

def has(f, bit): return math.floor(f / bit) % 2 == 1
def flags_diff(f): return math.floor(f / 2) % 4

class Peer:
    def __init__(self, name, rng):
        self.name = name; self.rng = rng
        self.remote_flags = 0; self.remote_changed_at = -1e9
        self.phase = "idle"; self.difficulty = 1; self.hold_kind = None; self.need_clear = False
        self.join_diff = None; self.started_at = 0; self.go_at = 0; self.latch_until = 0
        self.mismatch_diff = None; self.suppress_until = 0
        self.auto_join = False; self.auto_start = True; self.freeze_instead = False
        self.can_block = True
        self.starts = []       # times start_new_game was called
        self.released = []     # times freeze released
        self.messages = []
        self.seq = 0

    def rf_now(self, now):
        return 0 if now - self.remote_changed_at > STALE_AFTER else self.remote_flags

    def local_flags(self, now):
        f = 0
        active = self.phase in ("waiting", "go") or (self.phase == "done" and now < self.latch_until)
        if active: f += FLAG_READY + self.difficulty * 2
        if has(self.rf_now(now), FLAG_READY): f += FLAG_SEES
        if self.phase == "go" or (self.phase == "done" and now < self.latch_until): f += FLAG_GO
        return f

    def start_ready(self, now, difficulty, from_hook):
        if self.phase != "idle": return
        self.phase = "waiting"; self.difficulty = difficulty; self.started_at = now
        self.mismatch_diff = None; self.hold_kind = None
        if from_hook:
            self.hold_kind = "freeze" if (self.freeze_instead or not self.can_block) else "block"

    def cancel_ready(self, now, text=None):
        if self.hold_kind == "freeze": self.released.append(now)
        self.hold_kind = None; self.phase = "idle"; self.latch_until = 0
        self.mismatch_diff = None; self.need_clear = True

    def on_local_new_game(self, now, difficulty):
        """returns True if the original request is blocked"""
        if now < self.suppress_until: return False
        if self.phase == "idle" and now - self.remote_changed_at > STALE_AFTER: return False
        self.start_ready(now, difficulty, True)
        if self.phase == "waiting" and self.hold_kind is None and self.can_block and not self.freeze_instead:
            self.hold_kind = "block"
        return self.hold_kind == "block"

    def update(self, now):
        rf = self.rf_now(now)
        if self.phase == "idle":
            if self.need_clear:
                if not has(rf, FLAG_READY): self.need_clear = False
                self.join_diff = None; return
            if has(rf, FLAG_READY):
                self.join_diff = flags_diff(rf)
                if self.auto_join: self.start_ready(now, self.join_diff, False)
            else: self.join_diff = None
        elif self.phase == "waiting":
            if now - self.started_at > READY_TIMEOUT:
                self.cancel_ready(now); self.messages.append((now, "timeout")); return
            if has(rf, FLAG_READY):
                theirs = flags_diff(rf)
                if theirs != self.difficulty: self.mismatch_diff = theirs
                else:
                    self.mismatch_diff = None
                    if has(rf, FLAG_SEES) or has(rf, FLAG_GO):
                        self.phase = "go"; self.go_at = now; self.latch_until = now + GO_LATCH
            else: self.mismatch_diff = None
        elif self.phase == "go":
            if COUNTDOWN - (now - self.go_at) <= 0:
                kind = self.hold_kind; self.hold_kind = None
                self.phase = "done"; self.need_clear = True; self.suppress_until = now + 20
                if kind == "freeze": self.released.append(now)
                else: self.starts.append((now, self.difficulty, kind or "manual"))
        elif self.phase == "done":
            if now >= self.latch_until: self.phase = "idle"; self.need_clear = True

def run(events, duration, loss, seed, auto_join_b=False):
    rng = random.Random(seed)
    a, b = Peer("A", rng), Peer("B", rng); b.auto_join = auto_join_b
    peers = {"A": a, "B": b}
    inflight = []  # (deliver_at, to, flags, seq)
    last_sent = {"A": -1, "B": -1}
    t = 0.0; dt = 1/60
    pending = sorted(events)
    blocked_requests = []
    while t < duration:
        while pending and pending[0][0] <= t:
            _, who, action, arg = pending.pop(0)
            p = peers[who]
            if action == "newgame":
                blocked = p.on_local_new_game(t, arg)
                if not blocked and not (p.phase in ("waiting", "go")): p.starts.append((t, arg, "unblocked"))
            elif action == "ready": p.start_ready(t, arg, False)
            elif action == "cancel": p.cancel_ready(t)
            elif action == "use_theirs": p.difficulty = p.mismatch_diff
        for name, p in peers.items():
            if t - last_sent[name] >= 0.04:
                last_sent[name] = t; p.seq += 1
                if rng.random() >= loss:
                    other = "B" if name == "A" else "A"
                    inflight.append((t + rng.uniform(0.03, 0.15), other, p.local_flags(t), p.seq))
        for pkt in [x for x in inflight if x[0] <= t]:
            inflight.remove(pkt)
            _, to, fl, seq = pkt
            q = peers[to]
            if seq > getattr(q, "_last_seq", 0):  # engine keeps only the newest packet
                q._last_seq = seq; q.remote_flags = fl; q.remote_changed_at = t
        a.update(t); b.update(t)
        t += dt
    return a, b

def check(name, cond, detail=""):
    print(("PASS " if cond else "FAIL ") + name + ("  " + detail if detail and not cond else ""))
    return cond

ok = True
for loss in (0.0, 0.1, 0.3):
    for seed in range(40):
        tag = f"loss={loss} seed={seed}"
        # A: both press New Game (blocked) at random times
        t1, t2 = random.Random(seed).uniform(1, 10), random.Random(seed + 99).uniform(1, 10)
        a, b = run([(t1, "A", "newgame", 2), (t2, "B", "newgame", 2)], 40, loss, seed)
        ok &= check(f"both press, once each [{tag}]", len(a.starts) == 1 and len(b.starts) == 1, f"{a.starts} {b.starts}")
        if a.starts and b.starts:
            ok &= check(f"both press, starts within 0.6 s and after both pressed [{tag}]",
                        abs(a.starts[0][0] - b.starts[0][0]) < 0.6 and min(a.starts[0][0], b.starts[0][0]) >= max(t1, t2) + COUNTDOWN - 0.01,
                        f"{a.starts[0][0]:.2f} {b.starts[0][0]:.2f} pressed {t1:.2f}/{t2:.2f}")
        # B: A presses New Game, B joins from the panel (manual)
        a, b = run([(2, "A", "newgame", 1), (6, "B", "ready", 1)], 40, loss, seed)
        ok &= check(f"press + join [{tag}]", len(a.starts) == 1 and len(b.starts) == 1 and abs(a.starts[0][0]-b.starts[0][0]) < 0.6, f"{a.starts} {b.starts}")
        # C: only A presses: nobody starts, A times out
        a, b = run([(2, "A", "newgame", 1)], 140, loss, seed)
        ok &= check(f"lonely press never starts [{tag}]", not a.starts and not b.starts and a.phase == "idle", f"{a.starts} {b.starts} {a.phase}")
        # D: mismatch then B uses their difficulty
        a, b = run([(2, "A", "newgame", 2), (3, "B", "ready", 0), (8, "B", "use_theirs", 0)], 40, loss, seed)
        ok &= check(f"mismatch resolves [{tag}]", len(a.starts) == 1 and len(b.starts) == 1 and a.starts[0][1] == 2 and b.starts[0][1] == 2, f"{a.starts} {b.starts}")
        a, b = run([(2, "A", "newgame", 2), (3, "B", "ready", 0)], 30, loss, seed)
        ok &= check(f"mismatch alone never starts [{tag}]", not a.starts and not b.starts, f"{a.starts} {b.starts}")
        # E: A presses then cancels; B presses later: A must not be dragged back in
        a, b = run([(2, "A", "newgame", 1), (3, "B", "ready", 1), (3.2, "A", "cancel", 0), (12, "B", "cancel", 0)], 40, loss, seed)
        ok &= check(f"cancel respected [{tag}]", len(a.starts) <= 1, f"{a.starts} {b.starts}")
        # F: auto-join on B
        a, b = run([(2, "A", "newgame", 1)], 40, loss, seed, auto_join_b=True)
        ok &= check(f"auto-join [{tag}]", len(a.starts) == 1 and len(b.starts) == 1, f"{a.starts} {b.starts}")
        # G: nothing restarts after completion (long run)
        a, b = run([(2, "A", "newgame", 1), (4, "B", "newgame", 1)], 90, loss, seed, auto_join_b=True)
        ok &= check(f"no second start [{tag}]", len(a.starts) == 1 and len(b.starts) == 1, f"{a.starts} {b.starts}")
print("ALL PASSED" if ok else "SOME FAILED")

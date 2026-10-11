#!/usr/bin/env python3
"""Summarise one Klepton session from a device log (Documents/klepton-boot.log).

    tools/session_summary.py klepton-boot.log

Reads the lines the runtime and the compositor already print:

  [hb] HH:MM:SS  phase=...  foot=NM avail=NM     heartbeat, every ~2 s: wall
                                                 clock and memory footprint
  [openvr] guest X fps, frame work Y ms ...      OpenVR guests (Alyx): frames
                                                 submitted over each ~5 s window
  <date> ... [cp] alive: N iters, P with a picture, B black, ...
                                                 compositor liveness, every 0.5 s
  <date> ... [cp] cadence M ms mean / X max ...  compositor present cadence
  [session] ...                                  the in-app session summary
                                                 (KleptonSessionStats.swift),
                                                 when the build has it

and prints the guest frame rate (average over play windows, min, max and the
low percentiles of the 5-second windows), the display rate, session duration
and peak memory. Windows under LOADING_FPS are counted as loading, not play:
a game that stops submitting during a load (SuspendRendering) reports ~0 there.
"""
import re
import sys

LOADING_FPS = 2.0     # a 5 s window under this is a load, not gameplay

HB = re.compile(r"\[hb\] (\d\d):(\d\d):(\d\d)\s+phase=(.*?)\s+foot=(-?\d+)M avail=(-?\d+)M")
GUEST = re.compile(r"\[openvr\] guest ([\d.]+) fps, frame work ([\d.]+) ms.*?display (\d+) Hz")
STAMP = re.compile(r"^(\d{4}-\d\d-\d\d) (\d\d):(\d\d):(\d\d(?:\.\d+)?) ")
ALIVE = re.compile(r"\[cp\] alive: (\d+) iters, (\d+) with a picture, (\d+) black")
CADENCE = re.compile(r"\[cp\] cadence ([\d.]+) ms mean")
SESSION = re.compile(r"\[session\] (.*)")


def pct(sorted_vals, p):
    """Nearest-rank percentile of an ascending list (p in 0..100)."""
    if not sorted_vals:
        return None
    k = max(0, min(len(sorted_vals) - 1, int(round(p / 100.0 * (len(sorted_vals) - 1)))))
    return sorted_vals[k]


def main(path):
    hb_times, hb_secs_prev, day = [], None, 0
    peak_foot, peak_phase, last_avail_min = -1, "", None
    guest, work, disp_hz = [], [], None
    alive = []            # (seconds, iters, with_picture)
    cadence = []
    sessions = []
    with open(path, errors="replace") as f:
        for line in f:
            m = HB.search(line)
            if m:
                s = int(m[1]) * 3600 + int(m[2]) * 60 + int(m[3])
                if hb_secs_prev is not None and s < hb_secs_prev - 43200:
                    day += 86400                      # past midnight
                hb_secs_prev = s
                hb_times.append(s + day)
                foot, avail = int(m[5]), int(m[6])
                if foot > peak_foot:
                    peak_foot, peak_phase = foot, m[4]
                if avail >= 0 and (last_avail_min is None or avail < last_avail_min):
                    last_avail_min = avail
                continue
            m = GUEST.search(line)
            if m:
                guest.append(float(m[1]))
                work.append(float(m[2]))
                disp_hz = int(m[3])
                continue
            m = ALIVE.search(line)
            if m:
                t = STAMP.match(line)
                if t:
                    secs = int(t[2]) * 3600 + int(t[3]) * 60 + float(t[4])
                    alive.append((secs, int(m[1]), int(m[2])))
                continue
            m = CADENCE.search(line)
            if m:
                cadence.append(float(m[1]))
                continue
            m = SESSION.search(line)
            if m:
                sessions.append(m[1].strip())

    print(f"log: {path}")
    if hb_times:
        dur = hb_times[-1] - hb_times[0]
        print(f"duration      : {dur // 60} min {dur % 60:02d} s (first to last [hb], {len(hb_times)} heartbeats)")
    else:
        print("duration      : n/a (no [hb] lines)")
    if peak_foot >= 0:
        print(f"peak memory   : {peak_foot} MB footprint (at phase '{peak_phase}')"
              + (f"; lowest available {last_avail_min} MB" if last_avail_min is not None else ""))

    if guest:
        play = [g for g in guest if g >= LOADING_FPS]
        loading = len(guest) - len(play)
        s = sorted(play)
        print(f"guest fps     : {len(guest)} windows of ~5 s ({len(play)} play, {loading} loading <{LOADING_FPS:g} fps)")
        if play:
            # Each window is the same ~5 s, so the plain mean of the windows is
            # the time-weighted average frame rate over play.
            mean = sum(play) / len(play)
            print(f"  average     : {mean:.1f} fps")
            print(f"  min / max   : {s[0]:.1f} / {s[-1]:.1f} fps (5 s windows)")
            print(f"  1% / 5% low : {pct(s, 1):.1f} / {pct(s, 5):.1f} fps (percentile of the 5 s windows)")
            print(f"  p25/p50/p75 : {pct(s, 25):.1f} / {pct(s, 50):.1f} / {pct(s, 75):.1f} fps")
            pw = sorted(w for g, w in zip(guest, work) if g >= LOADING_FPS)
            print(f"  frame work  : {sum(pw) / len(pw):.1f} ms mean, p95 {pct(pw, 95):.1f} ms (WaitGetPoses -> Submit)")
            # A coarse 5 s timeline: one char per window, so a slump is visible.
            marks = " .:-=+*#%@"
            top = max(s[-1], 1.0)
            line = "".join(marks[min(len(marks) - 1, int(g / top * (len(marks) - 1)))] for g in guest)
            print(f"  timeline    : [{line}] (each char 5 s, '@' = {top:.0f} fps)")
    else:
        print("guest fps     : n/a (no [openvr] guest ... fps lines; not an OpenVR guest?)")

    if disp_hz:
        print(f"display       : {disp_hz} Hz (as the runtime reports it)")
    if len(alive) >= 2:
        t0, i0, p0 = alive[0]
        t1, i1, p1 = alive[-1]
        if t1 < t0:
            t1 += 86400
        span = t1 - t0
        if span > 0:
            print(f"compositor    : {(i1 - i0) / span:.1f} iterations/s over {span:.0f} s of [cp] alive lines, "
                  f"{p1} of {i1} with a guest picture")
    if cadence:
        cs = sorted(cadence)
        print(f"  cadence     : {sum(cadence) / len(cadence):.2f} ms mean present interval "
              f"(worst 0.5 s report {cs[-1]:.2f} ms)")
    if sessions:
        print(f"in-app [session] lines: {len(sessions)}; last:")
        print(f"  {sessions[-1]}")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__.strip().splitlines()[2], file=sys.stderr)
        sys.exit(2)
    main(sys.argv[1])

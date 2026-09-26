#!/usr/bin/env bash
# Follow-ups 24 (copied from experiments/runs/2026-09-25-walkthrough/drivers/sleep-events.sh, unchanged below this line; that header read: Follow-ups 23): host power events over this record's windows, kinds and stamps only, in the shape of
# experiments/runs/2026-09-25-followups-22/sleep-events.csv. Reads `pmset -g log` and keeps a line only when its
# event-kind column (field 4) is Sleep, Wake, DarkWake or Maintenance; a "Wake Requests" line (field 5 Requests) is
# pmset listing what asked for the next wake, not a wake, and is not kept. No line's text is kept: the output is the
# kind and the stamp, converted to UTC with the offset pmset prints beside it, for the lines inside a window, and the
# count of each kind per window. Nothing else in the log is read, counted or recorded (CLAUDE.md: host-sleep records
# carry Sleep, Wake, DarkWake and Maintenance lines and counts only).
# $1 = output csv, $2 = windows file (label,start_utc,end_utc). Read-only. This script starts no keep-awake and
# changes no power setting.
set -uo pipefail
OUT="$1"; WINDOWS="$2"
pmset -g log | python3 -c '
import sys, datetime as dt
KEPT = ("Sleep", "Wake", "DarkWake", "Maintenance")
wins = []
for w in open(sys.argv[1]):
    w = w.strip()
    if not w or w.startswith("#"): continue
    label, a, b = w.split(",")
    f = lambda x: dt.datetime.strptime(x, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc)
    wins.append((label, f(a), f(b)))
rows = []
for line in sys.stdin:
    p = line.split()
    if len(p) < 4 or p[3] not in KEPT: continue
    if p[3] == "Wake" and len(p) > 4 and p[4] == "Requests": continue
    try: t = dt.datetime.strptime(" ".join(p[:3]), "%Y-%m-%d %H:%M:%S %z").astimezone(dt.timezone.utc)
    except ValueError: continue
    for label, a, b in wins:
        if a <= t <= b: rows.append((label, p[3], t.strftime("%Y-%m-%dT%H:%M:%SZ")))
now = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
print(f"# kind,utc,window -- host power events of the four kinds inside this record'"'"'s windows, from pmset -g log, read {now}.")
print("# The stamp is pmset'"'"'s own local stamp converted with the offset pmset printed beside it. No line'"'"'s text is kept.")
for label, a, b in wins:
    c = {k: sum(1 for r in rows if r[0] == label and r[1] == k) for k in KEPT}
    print(f"# window {label}: {a:%Y-%m-%dT%H:%M:%SZ} .. {b:%Y-%m-%dT%H:%M:%SZ}: " + " ".join(f"{k}={v}" for k, v in c.items()))
print("kind,utc,window")
for label, k, u in rows: print(f"{k},{u},{label}")
' "$WINDOWS" > "$OUT"
echo "wrote $OUT"

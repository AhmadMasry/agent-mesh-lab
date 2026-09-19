#!/usr/bin/env bash
# Follow-ups 18, task 2: did the host sleep inside a window this task counts?
#
# A REDUCED form of experiments/runs/2026-09-19-failed-model-call/rebuild-2/host-sleep.sh. It keeps that
# script's selection -- lines are chosen by pmset's own event-kind column, field $4, never by a match anywhere
# in the line -- and its per-window count. It drops that script's third section entirely: no `Assertions`
# line is listed here, in whole or in part, and no process list is read. Those lines are where pmset prints
# the names of the host's peripherals (the `product:` value on WindowServer UserIsActive lines, and the
# owners of kernel assertions), and the history rewrite of 2026-09-19 cut exactly those from four earlier
# records. The question this record answers needs none of them: a sleep in a window is a Sleep line in it.
#
# Kept kinds: Sleep, Wake, DarkWake, Maintenance. A "Wake Requests" line ($4=="Wake", $5=="Requests") is pmset
# listing what asked for the next wake, not a wake; it is counted apart. Assertions lines are counted per
# window as a number and never printed. As a second guard, any kept line that matches `product:`, `USB` or
# `Assertions` anywhere has everything after its kind replaced by <cut>, and the number of such cuts is printed.
#
# No keep-awake of any form is started by this script, by the drivers beside it, or by the task that ran them.
#
# $1 = output file. $2 = windows file, one line per counted window: label,start_utc,end_utc (ISO 8601, Z).
# Read-only: `pmset -g log` only reads.
set -uo pipefail
OUT="$1"
WINDOWS="$2"
LOGF="$(mktemp)"
trap 'rm -f "$LOGF"' EXIT
pmset -g log > "$LOGF"

{
echo "# Host sleep during the follow-ups 18 rebuild and readings. Written $(date -u +%Y-%m-%dT%H:%M:%SZ)."
echo "#"
echo "# The selection, by pmset's event-kind column (field \$4), over the whole of \`pmset -g log\`:"
echo "#   \$4==\"Sleep\" || \$4==\"Wake\" || \$4==\"DarkWake\" || \$4==\"Maintenance\""
echo "# pmset stamps in the host local zone (shown per line); the windows are given in UTC and compared after"
echo "# converting each stamp with its own offset. No Assertions line is listed anywhere in this file."
echo "#"
echo "# EVERY COUNTED WINDOW, and the lines of each kept kind whose stamp falls inside it:"
echo
python3 - "$LOGF" "$WINDOWS" <<'PY'
import sys, datetime as dt, re
logf, winf = sys.argv[1], sys.argv[2]
KEPT = ("Sleep", "Wake", "DarkWake", "Maintenance")
GUARD = re.compile(r"product:|USB|Assertions")
rows, cuts = [], 0
for line in open(logf, errors="replace"):
    f = line.split()
    if len(f) < 4 or f[3] not in KEPT + ("Assertions",):
        continue
    try:
        t = dt.datetime.strptime(" ".join(f[:3]), "%Y-%m-%d %H:%M:%S %z")
    except ValueError:
        continue
    kind = f[3]
    if kind == "Wake" and len(f) > 4 and f[4] == "Requests":
        kind = "Wake Requests"
    text = None
    if f[3] in KEPT:
        text = line.rstrip("\n")
        if GUARD.search(text):
            text = " ".join(f[:4]) + " <cut>"
            cuts += 1
    rows.append((t, kind, text))
first = min((r[0] for r in rows), default=None)
for w in open(winf):
    w = w.strip()
    if not w or w.startswith("#"):
        continue
    label, a, b = w.split(",")
    ta = dt.datetime.strptime(a, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc)
    tb = dt.datetime.strptime(b, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc)
    inside = [r for r in rows if ta <= r[0] <= tb]
    counts = {k: sum(1 for r in inside if r[1] == k)
              for k in ("Sleep", "Wake", "DarkWake", "Maintenance", "Wake Requests", "Assertions")}
    print(f"   window {label}: {a} .. {b}")
    print("     " + "  ".join(f"{k}={v}" for k, v in counts.items()) + "   (Assertions: counted, never listed)")
    for r in inside:
        if r[2] is not None:
            print("       " + r[2])
    print()
print(f"# kept lines whose tail was cut by the guard: {cuts}")
if first is not None:
    print(f"# the earliest stamped line pmset holds: {first.isoformat()} (the log covers the windows only if this is before them)")
last_sleep = [r for r in rows if r[1] == "Sleep"]
last_wake = [r for r in rows if r[1] == "Wake"]
print(f"# Sleep lines pmset holds in all: {len(last_sleep)}; the last one stamped {last_sleep[-1][0].isoformat() if last_sleep else 'none'}")
print(f"# Wake lines pmset holds in all:  {len(last_wake)}; the last one stamped {last_wake[-1][0].isoformat() if last_wake else 'none'}")
PY
} > "$OUT" 2>&1
echo "wrote $OUT ($(grep -c '' "$OUT") lines)"

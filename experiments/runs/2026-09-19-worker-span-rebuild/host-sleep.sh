#!/usr/bin/env bash
# Follow-ups 19, task 3c: did the host sleep inside a window this task counts, and what do pmset's assertion
# lines in those windows say about keep-awake?
#
# experiments/runs/2026-09-19-currency-rebuild/host-sleep.sh, changed in four places and nowhere else: this
# header down to the line of dashes; the first line the script prints; the keep-awake sentence, reworded as that
# record's review ruled it; and the three sections added at the end (the assertion COUNTS per window, by
# host-sleep-assertion-counts.py beside this file; the keep-awake processes read by `ps`, arguments and the
# parent's command name only; and this directory's own lines that run one). The selection and the counting
# of the first section are untouched.
# That script descends from experiments/runs/2026-09-19-failed-model-call/rebuild-2/host-sleep.sh. It keeps that
# script's selection -- lines are chosen by pmset's own event-kind column, field $4, never by a match anywhere
# in the line -- and its per-window count. No `Assertions` line is listed here, in whole or in part: those lines
# are where pmset prints the names of the host's peripherals (the `product:` value on WindowServer UserIsActive
# lines, and the owners of kernel assertions), and the history rewrite of 2026-09-19 cut exactly those from four
# earlier records.
#
# Kept kinds: Sleep, Wake, DarkWake, Maintenance. A "Wake Requests" line ($4=="Wake", $5=="Requests") is pmset
# listing what asked for the next wake, not a wake; it is counted apart. Assertions lines are counted per
# window as a number and never printed. As a second guard, any kept line that matches `product:`, `USB` or
# `Assertions` anywhere has everything after its kind replaced by <cut>, and the number of such cuts is printed.
#
# Keep-awake: this script starts none and changes no power setting, and neither do the drivers beside it nor the
# commands of the task that ran them. Keep-awake is NOT claimed absent on the host: the agent harness holds its
# own rolling `caffeinate` per session, which this task neither starts nor stops.
#
# $1 = output file. $2 = windows file, one line per counted window: label,start_utc,end_utc (ISO 8601, Z).
# Read-only: `pmset -g log` and `ps` only read.
# ---------------------------------------------------------------------------------------------------------------
set -uo pipefail
OUT="$1"
WINDOWS="$2"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGF="$(mktemp)"
trap 'rm -f "$LOGF"' EXIT
pmset -g log > "$LOGF"

{
echo "# Host sleep during the follow-ups 19 task 3c rebuild (REBUILD-2) and readings. Written $(date -u +%Y-%m-%dT%H:%M:%SZ)."
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
echo
echo "# ASSERTION COUNTS PER WINDOW. Counts only: no Assertions line is listed here. How counted:"
echo "#   pmset -g log | python3 host-sleep-assertion-counts.py windows.csv   (the same read of the log as above)"
echo "# The method is in that program's header: field \$4 == \"Assertions\"; stamps compared in UTC, both ends inclusive;"
echo "# the substring \"caffeinate\"; the type substring; the action word after the process token, printed only if it is"
echo "# one of pmset's own action words. It prints numbers and those words, never a line, a pid or a name other than"
echo "# that process name."
python3 "$HERE/host-sleep-assertion-counts.py" "$WINDOWS" < "$LOGF"
echo
echo "# KEEP-AWAKE PROCESSES, read by \`ps\` at $(date -u +%Y-%m-%dT%H:%M:%SZ), after the windows: the process's arguments and its"
echo "# PARENT's command name only (no pid, no user, no terminal):"
ps -axo pid=,ppid=,args= | awk '$3 ~ /(^|\/)caffeinate$/ { $1=""; print }' | while read -r ppid args; do
	pc=$(ps -o comm= -p "$ppid" 2>/dev/null | awk '{n=split($1, a, "/"); print a[n]}')
	echo "$args   <- parent command name: ${pc:-(gone)}"
done | sort | uniq -c | sed 's/^/#   /'
echo "# (no line above means no such process at that moment)"
echo
echo "# THIS DIRECTORY'S OWN LINES that run caffeinate or a pmset setter: non-comment lines of the .sh and .py files"
echo "# beside this script that match \`caffeinate\` or \`pmset\`, counted; the counting program's match strings and"
echo "# this script's own reads are what is expected to match:"
for f in "$HERE"/*.sh "$HERE"/*.py; do
	n=$(grep -v '^[[:space:]]*#' "$f" | grep -cE 'caffeinate|pmset' || true)
	s=$(grep -v '^[[:space:]]*#' "$f" | grep -cE 'pmset +(-[abcu] |sleepnow|displaysleepnow|schedule|repeat|noidle|touch|lock)|(^|[^"`(.[:alnum:]_-])caffeinate +-' || true)
	echo "#   $(basename "$f"): lines naming either = $n; of them lines that would START a keep-awake or SET a power value = $s"
done
} > "$OUT" 2>&1
echo "wrote $OUT ($(grep -c '' "$OUT") lines)"

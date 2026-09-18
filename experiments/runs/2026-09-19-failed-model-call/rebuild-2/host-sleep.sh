#!/usr/bin/env bash
# Follow-ups 15, review round (rebuild 2): the host's sleep and keep-awake record for every window this task counts.
# Copied from ../rebuild/host-sleep.sh; section 3 now reads the caffeinate parents by ps when it runs, instead of
# stating one (review finding M2).
#
# The form of experiments/runs/2026-09-16-genai-spans/rebuild/host-sleep.sh (follow-ups 14): lines are selected
# by pmset's own event-kind column, never by a match anywhere in the line. In a `pmset -g log` line the fields
# are $1 the local date, $2 the local time, $3 the zone offset and $4 the event kind, so the predicate is $4
# throughout this file:
#   pmset -g log | awk -v d=<day> '$1==d && ($4=="Sleep" || $4=="Wake" || $4=="DarkWake" || $4=="Maintenance")'
#   pmset -g log | awk -v d=<day> '$1==d && $4=="Assertions"'
# A "Wake Requests" line ($4=="Wake", $5=="Requests") is pmset listing what asked for the next wake, not a wake;
# it is shown with the rest but not counted as one.
#
# What this adds to that form: each counted window is named, and the lines whose stamp falls inside it are
# counted by kind, so "no sleep in the window" is a count read from the log rather than a reading of the list.
#
# $1 = output file. $2 = windows file, one line per counted window: label,start_utc,end_utc (ISO 8601, Z).
# DAYS = space-separated local dates whose Sleep/Wake/DarkWake/Maintenance lines are listed (default: today, local).
# ASSERT_DAYS = the local dates whose Assertions lines are listed in full (default: the last of DAYS); for any other
# day only the count is printed, because a day can hold thousands of them. Read-only: pmset -g log only reads.
set -uo pipefail
OUT="$1"
WINDOWS="$2"
DAYS="${DAYS:-$(date +%Y-%m-%d)}"
ASSERT_DAYS="${ASSERT_DAYS:-${DAYS##* }}"
LOGF="$(mktemp)"
trap 'rm -f "$LOGF"' EXIT
pmset -g log > "$LOGF"

kinds() { awk -v d="$1" '$1==d && ($4=="Sleep" || $4=="Wake" || $4=="DarkWake" || $4=="Maintenance")' "$LOGF"; }
assertions() { awk -v d="$1" '$1==d && $4=="Assertions"' "$LOGF"; }

{
echo "# Host sleep and keep-awake during the follow-ups 15 rebuild and readings. Written $(date -u +%Y-%m-%dT%H:%M:%SZ)."
echo "#"
echo "# The selection, verbatim, per local day listed (the event kind is field \$4):"
echo "#   pmset -g log | awk -v d=<day> '\$1==d && (\$4==\"Sleep\" || \$4==\"Wake\" || \$4==\"DarkWake\" || \$4==\"Maintenance\")'"
echo "#   pmset -g log | awk -v d=<day> '\$1==d && \$4==\"Assertions\"'"
echo "# pmset stamps in the host local zone (shown per line); the windows are given in UTC and compared after"
echo "# converting each stamp with its own offset."
echo "#"
echo "# 1. EVERY COUNTED WINDOW, and the lines of each kind whose stamp falls inside it:"
echo
python3 - "$LOGF" "$WINDOWS" <<'PY'
import sys, datetime as dt
logf, winf = sys.argv[1], sys.argv[2]
rows = []
for line in open(logf, errors="replace"):
    f = line.split()
    if len(f) < 4 or f[3] not in ("Sleep", "Wake", "DarkWake", "Maintenance", "Assertions"):
        continue
    try:
        t = dt.datetime.strptime(" ".join(f[:3]), "%Y-%m-%d %H:%M:%S %z")
    except ValueError:
        continue
    kind = f[3]
    if kind == "Wake" and len(f) > 4 and f[4] == "Requests":
        kind = "Wake Requests"
    rows.append((t, kind, line.rstrip("\n")))
for w in open(winf):
    w = w.strip()
    if not w or w.startswith("#"):
        continue
    label, a, b = w.split(",")
    ta = dt.datetime.strptime(a, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc)
    tb = dt.datetime.strptime(b, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc)
    inside = [r for r in rows if ta <= r[0] <= tb]
    counts = {k: sum(1 for r in inside if r[1] == k) for k in ("Sleep", "Wake", "DarkWake", "Maintenance", "Assertions", "Wake Requests")}
    print(f"   window {label}: {a} .. {b}")
    print("     " + "  ".join(f"{k}={v}" for k, v in counts.items()))
    for r in inside:
        if r[1] != "Assertions":
            print("       " + r[2])
    print()
PY
for d in $DAYS; do
echo "# 2. SLEEP, WAKE, DARKWAKE AND MAINTENANCE, every line pmset holds for $d:"
echo
kinds "$d" | sed 's/^/   /'
echo
printf '#    last Sleep: %s\n' "$(kinds "$d" | awk '$4=="Sleep"' | tail -1)"
printf '#    last Wake:  %s\n' "$(kinds "$d" | awk '$4=="Wake" && $5!="Requests"' | tail -1)"
echo "#    Sleep lines: $(kinds "$d" | awk '$4=="Sleep"' | grep -c ''); Wake: $(kinds "$d" | awk '$4=="Wake" && $5!="Requests"' | grep -c ''); DarkWake: $(kinds "$d" | awk '$4=="DarkWake"' | grep -c '')"
echo
done
echo "# The last Sleep and the last Wake pmset holds on any day, by the same column:"
printf '#    last Sleep: %s\n' "$(awk '$4=="Sleep"' "$LOGF" | tail -1)"
printf '#    last Wake:  %s\n' "$(awk '$4=="Wake" && $5!="Requests"' "$LOGF" | tail -1)"
printf '#    first line pmset holds: %s\n' "$(head -1 "$LOGF" | cut -c1-80)"
echo
echo "# 3. KEEP-AWAKE. No driver, script or command of this task starts a keep-awake. What pmset shows held is"
echo "#    below in full. Every caffeinate process running as this record is written, with its parent, read by ps"
echo "#    now, since pmset records pids and not parents:"
ps -axo pid,ppid,lstart,command | grep -E "[c]affeinate -i" | sed 's/^/#      /'
for pp in $(ps -axo ppid,command | grep -E "[c]affeinate -i" | awk '{print $1}' | sort -u); do
	ps -o pid,ppid,lstart,command -p "$pp" | tail -1 | cut -c1-140 | sed 's/^/#      parent: /'
done
echo "#    A keep-awake prevents an idle sleep; whether one mattered in a counted window is answered by section 1,"
echo "#    not by this list."
echo
for d in $DAYS; do
echo "#    Assertions lines for $d: $(assertions "$d" | grep -c '')"
done
echo
for d in $ASSERT_DAYS; do
echo "#    Assertions lines for $d, in full:"
assertions "$d" | sed 's/^/   /'
echo
done
} > "$OUT" 2>&1
echo "wrote $OUT ($(grep -c '' "$OUT") lines)"

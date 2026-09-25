#!/usr/bin/env bash
# Experiment B, step B-4: the host's sleep and wake EVENTS, kind and stamp only, so that counts.py can mark each
# repetition of the row sleep-affected or clean from that repetition's own window.
#
# It keeps the four kinds the lab's host-sleep records keep -- Sleep, Wake, DarkWake, Maintenance -- chosen by
# pmset's own event-kind column ($4), never by a match anywhere in the line, and a "Wake Requests" line ($4=="Wake",
# $5=="Requests") is counted apart as pmset listing what asked for the next wake, not a wake. NOTHING of a line's
# text is kept: each row is the kind and the stamp converted to UTC from the offset pmset itself prints, so no
# peripheral name, product string or assertion owner can enter the record (CLAUDE.md). host-sleep.txt beside this
# file is the last record's host-sleep.sh, unedited, over windows.csv; this file is the same log read for one more
# purpose, and the two agree on the counts.
# THE WINDOW. pmset holds far more than a task: its log here goes back a week. A record of this lab's runs carries
# this task's own window and not the host's history, so the two optional arguments bound what is written -- the first
# phase stamp of this task and its closing reading -- and the committed file holds only that. Run without them it
# writes the whole log, which is what the unedited output kept in a scratch directory is.
# Read-only: pmset -g log only reads.
#   bash sleep-events.sh <output csv> [<from utc> <to utc>]
set -uo pipefail
OUT="${1:?the output csv is required}"
FROM="${2:-}"
TO="${3:-}"
{
	echo "# kind,utc -- host power events of the four kinds, from pmset -g log, read $(date -u +%FT%TZ)."
	echo "# The stamp is pmset's own local stamp converted with the offset pmset printed beside it. No line's text is kept."
	if [ -n "$FROM" ]; then
		echo "# Bounded to this task's own window, $FROM .. $TO: its first phase stamp to its closing reading."
	else
		echo "# The whole of the log pmset holds, unbounded."
	fi
	echo "kind,utc"
	pmset -g log | awk '
		$4 == "Wake" && $5 == "Requests" { next }
		$4 == "Sleep" || $4 == "Wake" || $4 == "DarkWake" || $4 == "Maintenance" { print $4, $1, $2, $3 }
	' | while read -r kind d t off; do
		u=$(TZ=UTC date -u -j -f '%Y-%m-%d %H:%M:%S %z' "$d $t $off" +%FT%TZ 2>/dev/null) || continue
		if [ -n "$FROM" ]; then
			if [ "$u" \< "$FROM" ] || [ "$u" \> "$TO" ]; then continue; fi
		fi
		printf '%s,%s\n' "$kind" "$u"
	done
} > "$OUT"

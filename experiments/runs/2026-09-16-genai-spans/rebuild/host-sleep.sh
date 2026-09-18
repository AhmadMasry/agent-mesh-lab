#!/usr/bin/env bash
# Follow-ups 14: the host's sleep and keep-awake record for the rebuild and its readings.
#
# Written as a script, and the script committed, because the first attempt at this record was
# selected by hand with a grep that matched "Sleep" anywhere in the line: it caught
# com.apple.sleepservices.sessionStarted/Terminated and missed every real `Sleep` line, then named a
# sessionTerminated line as "the last Sleep". The selection is now by pmset's own column -- the
# second whitespace-delimited field after the timestamp, which is the event kind -- so a Sleep line
# is a Sleep line and nothing else is.
#
# $1 = output file. Read-only: pmset -g log only reads.
set -uo pipefail
OUT="$1"
DAY="${DAY:-$(date +%Y-%m-%d)}"

# The exact selection, recorded here and used below, so a reader can re-run it:
#   pmset -g log | awk -v d=<day> '$1==d && ($3=="Sleep" || $3=="Wake" || $3=="DarkWake" || $3=="Maintenance")'
#   pmset -g log | awk -v d=<day> '$1==d && $3=="Assertions"'
# ($1 is the date, $2 the time, $3 the zone offset... so the kind is $4; the awk below uses $4 and
#  prints the whole line.)
# 2026-09-19 correction (follow-ups 15): the predicate is $4 throughout; the $3 in the two selection lines above is a slip of this comment, and nothing else in this file was touched.
kinds() { pmset -g log | awk -v d="$DAY" '$1==d && ($4=="Sleep" || $4=="Wake" || $4=="DarkWake" || $4=="Maintenance")'; }
assertions() { pmset -g log | awk -v d="$DAY" '$1==d && $4=="Assertions"'; }

{
echo "# Host sleep and keep-awake during the follow-ups 14 rebuild and its readings."
echo "#"
echo "# The selection, verbatim, so it can be re-run and so it cannot quietly match the wrong lines:"
echo "#   pmset -g log | awk -v d=$DAY '\$1==d && (\$4==\"Sleep\" || \$4==\"Wake\" || \$4==\"DarkWake\" || \$4==\"Maintenance\")'"
echo "#   pmset -g log | awk -v d=$DAY '\$1==d && \$4==\"Assertions\"'"
echo "# pmset stamps in the host's local zone, +0300. The rebuild and the readings ran in the UTC window"
echo "# recorded in build.txt and logs/, which is three hours behind these stamps."
echo "#"
echo "# 1. SLEEP, WAKE, DARKWAKE AND MAINTENANCE, every line pmset holds for $DAY:"
echo
kinds | sed 's/^/   /'
echo
echo "#    The last Sleep and the last Wake of the day, by the same selection:"
printf '#      last Sleep: %s\n' "$(kinds | awk '$4=="Sleep"' | tail -1)"
printf '#      last Wake:  %s\n' "$(kinds | awk '$4=="Wake" && $5!="Requests"' | tail -1)"
echo "#      Sleep lines: $(kinds | awk '$4=="Sleep"' | grep -c ''); Wake: $(kinds | awk '$4=="Wake" && $5!="Requests"' | grep -c ''); DarkWake: $(kinds | awk '$4=="DarkWake"' | grep -c '')"
echo "#      (a \"Wake Requests\" line is pmset listing what asked for the next wake, not a wake; it is shown"
echo "#       above with the rest but is not counted as one.)"
echo
echo "# 2. KEEP-AWAKE. No driver, script or command of this task holds the host awake and none was started"
echo "#    for it, so nothing here is this lab's. What was held anyway, by processes that are not this"
echo "#    task's, is below in full; \"no keep-awake\" would be false and is not claimed."
echo "#      PID (Do Not Sleep)   the author's Parallels Toolbox tool, PreventUserIdleSystemSleep and"
echo "#                           PreventUserIdleDisplaySleep. Theirs, not this task's."
echo "#      PID 363 (powerd)     the system's own \"Prevent sleep while display is on\"."
echo "#      PID (caffeinate)     the Claude Code harness's \`caffeinate -i -t 300\`, a new one about every"
echo "#                           four minutes, each with a Claude Code process as its parent."
echo "#    A keep-awake prevents an idle sleep. Whether one mattered is answered by section 1, not by this"
echo "#    list."
echo
assertions | sed 's/^/   /'
} > "$OUT" 2>&1
echo "wrote $OUT ($(grep -c '' "$OUT") lines)"

#!/usr/bin/env bash
# Follow-ups 15, commit 3: one counted run between two readings of every hop counter, each step stamped.
#
#   quiet wait QUIET s  -> read-hops.sh <name>-before -> the stimulus (a committed script, unedited, given as
#   the remaining arguments) -> wait AFTER_WAIT s -> read-hops.sh <name>-after
#
# The scrape interval is 15 s for every job (Prometheus's live configuration, prometheus-config.txt). QUIET is at
# least two intervals, so every target's last sample before the "before" reading postdates whatever ran before it;
# AFTER_WAIT is at least two intervals, as the brief requires, so every target is scraped at least twice after the
# stimulus's last request. Nothing else runs between the two readings. Writes its log to $LOG.
#
# $1 = name; the rest = the stimulus command. QUIET (default 35), AFTER_WAIT (default 45), LOG (required).
set -uo pipefail
NAME="$1"; shift
QUIET="${QUIET:-35}"; AFTER_WAIT="${AFTER_WAIT:-45}"
: "${LOG:?LOG required}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
now() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }
step() { local label="$1"; shift; local s e rc; s=$(now); echo "## $label  started $(ts)  epoch $s" >> "$LOG"; "$@" >> "$LOG" 2>&1; rc=$?; e=$(now); echo "## $label  finished $(ts)  epoch $e  exit=$rc  wall=$(perl -e "printf '%.3f', $e - $s")s" >> "$LOG"; echo >> "$LOG"; echo "$(ts) $label exit=$rc"; return $rc; }
wait_s() { local n="$1" i; for i in $(seq 1 "$n"); do sleep 1; done; }
echo "# counted run '$NAME', started $(ts); HEAD $(git rev-parse HEAD); stimulus: $*" >> "$LOG"
step "quiet ${QUIET} s" wait_s "$QUIET"
step "read ${NAME}-before" "$DIR/read-hops.sh" "${NAME}-before" || exit 1
step "stimulus" "$@"
step "wait ${AFTER_WAIT} s (at least two scrape intervals)" wait_s "$AFTER_WAIT"
step "read ${NAME}-after" "$DIR/read-hops.sh" "${NAME}-after" || exit 1
echo "# counted run '$NAME' finished $(ts)" >> "$LOG"

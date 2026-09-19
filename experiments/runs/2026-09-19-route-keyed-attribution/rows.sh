#!/usr/bin/env bash
# rows.sh <sub-directory> <run id> <row>... -- runs matrix rows one after another at
# REPS=1, DRY_RUN=off, each into its own run directory. A row is RUN:RECEIVER[:SUB].
# No retry: a row that fails stops the sequence and is not run again.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"   # the copy that ran named the checkout by its absolute path; this line is the only change
BASE="$(date +%F)-route-keyed-attribution/$1"; RUN_ID="$2"; shift 2
LOG="experiments/runs/${BASE}/rows.log"
mkdir -p "experiments/runs/${BASE}"
for row in "$@"; do
	IFS=: read -r run receiver sub <<<"$row"
	name="$(printf '%s-%s%s' "$run" "$receiver" "${sub:+-$sub}" | tr '[:upper:]' '[:lower:]')"
	printf '== %s | row %s -> %s ==\n' "$(date -u +%FT%TZ)" "$row" "${BASE}/${name}" | tee -a "$LOG"
	rc=0
	RUN="$run" RECEIVER="$receiver" SUB="$sub" REPS=1 DRY_RUN=off RUN_ID="$RUN_ID" RUN_ITEM="${BASE}/${name}" \
		experiments/gate3-matrix.sh >>"$LOG" 2>&1 || rc=$?
	printf '== %s | row %s exit status %s ==\n\n' "$(date -u +%FT%TZ)" "$row" "$rc" | tee -a "$LOG"
	[ "$rc" = "0" ] || { echo "stopping: row ${row} exited ${rc}" | tee -a "$LOG"; exit "$rc"; }
done
echo "== $(date -u +%FT%TZ) | all rows done ==" | tee -a "$LOG"

#!/usr/bin/env bash
# Follow-ups 24: one read taken beside the walk, right after its D-3b step (63) ended and before D-4's header phase
# rolled the agents: D-3b's own committed batch-by-hash.sh, which finds the batch probes' receiver lines by the body hash
# the client recorded (the D-3b entry's method; its counts.py reads them from ingress-by-body-hash.txt), run as a
# reader's copy whose one changed line names this run's d3b directory (the copy rule of the currency pass, ruled again
# for this task), then D-3b's counts.py again over the directory that now holds those lines. Reads only: kubectl logs of
# the two agents and files of this run. Logged in walk.sh's format as 63b and 63c; started by a waiter that watched the
# walk's own log for step 63's exit line, so that it ran inside the window before D-4's headers.sh replaced the pods.
# The inventory of Step 1 missed this reader (it listed d3b.sh and rows.sh only); recorded as a deviation.
set -u
cd "$(git rev-parse --show-toplevel)" || exit 1
: "${WALK_SCRATCH:?}" "${D:?}"
L="$WALK_SCRATCH/logs"; TIM="$WALK_SCRATCH/timings.csv"
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
now() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }
run() {
	local f="$1" label="$2" ok="$3" cmd="$4" s e rc st
	cmd="${cmd//@D@/$D}"
	st=$(ts); s=$(now)
	printf '$ %s\n' "$cmd" > "$L/$f.txt"
	echo "# istioctl on PATH at this step's start: $(istioctl version --remote=false 2>/dev/null)" >> "$L/$f.txt"
	bash -c "$cmd" >> "$L/$f.txt" 2>&1
	rc=$?
	e=$(now)
	local w; w=$(perl -e "printf '%.3f', $e - $s")
	echo "wall ${w}s exit $rc" >> "$L/$f.txt"
	[ "$label" = "-" ] || echo "$label,$st,$(ts),$w,$rc" >> "$TIM"
	echo "$(ts) $f exit=$rc wall=${w}s"
	case " $ok " in *" $rc "*) ;; *) echo "step-63b driver: $f exited $rc (allowed: $ok); stopping"; exit "$rc" ;; esac
}
step() { local cmd; cmd=$(cat); run "$1" "$2" "$3" "$cmd"; }
echo "$(ts) step-63b driver start (agent pods: $(kubectl -n lab get pods -l 'app in (worker,orchestrator)' -o jsonpath='{range .items[*]}{.metadata.name}={.metadata.creationTimestamp} {end}'))"
step 63b-d3b-batch-by-hash - "0 1" <<'EOF2'
sed -e 's#^D=experiments/runs/2026-09-25-d3b-extauthz-shapes$#D=experiments/runs/@D@/d3b#' \
  experiments/runs/2026-09-25-d3b-extauthz-shapes/batch-by-hash.sh > experiments/runs/@D@/drivers/d3b-batch-by-hash.sh
diff experiments/runs/2026-09-25-d3b-extauthz-shapes/batch-by-hash.sh experiments/runs/@D@/drivers/d3b-batch-by-hash.sh
bash experiments/runs/@D@/drivers/d3b-batch-by-hash.sh | tee experiments/runs/@D@/d3b/batch-by-hash.txt
EOF2
step 63c-d3b-counts-again - 0 <<'EOF2'
python3 experiments/runs/@D@/d3b/counts.py | tee experiments/runs/@D@/d3b/counts.txt
EOF2
echo "$(ts) step-63b driver exit=0"

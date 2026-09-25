#!/usr/bin/env bash
# The currency pass of 2026-09-25: C-5 re-counted. Replays the call sequence of
# experiments/runs/2026-09-23-c5-istio-policy-agw-central/phases.txt with that record's c5.sh, UNEDITED, run with
# RUNREL=2026-09-25-currency-rebuild/c5 (its output path is a setting), RUN_ID cur5:
#   read before; pod-up; p0 (no policy): go/py x SendMessage/SubscribeToTask, header yes, 1 each; apply; read applied;
#   p1 (the policy in force): per receiver, 3 rounds of SendMessage hdr=yes, SubscribeToTask hdr=yes, SendMessage hdr=no;
#   read p1-after; remove; read removed; pod-down.
# overlay-c5 and counts.sh in this directory are byte copies of that record's (cmp: identical); counts.sh reads and
# writes relative to its own directory, so it counts this run's files. agw-central-access.txt is agw-central's log from
# this replay's start, the same reading the original record kept under that name.
# No retry: c5.sh sends one curl --retry 0 per probe. Keep-awake: this script starts none and changes no power setting.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1
PATH="${TMPDIR%/}/cur/tools/istioctl-1.31.1:$PATH"; export PATH
export RUNREL=2026-09-25-currency-rebuild/c5 RUN_ID=cur5
N=experiments/runs/$RUNREL
C5=experiments/runs/2026-09-23-c5-istio-policy-agw-central/c5.sh
PH="$N/phases.txt"
ts() { date -u +%FT%TZ; }
S=$(ts)
echo "$S C-5 replay start; HEAD $(git rev-parse HEAD); c5.sh sha256 $(shasum -a 256 $C5 | cut -d' ' -f1); istioctl $(istioctl version --remote=false)" | tee -a "$PH"
run() { echo "$(ts) c5.sh $*" >> "$PH"; bash "$C5" "$@" 2>&1 | tee -a "$PH"; }
run read before "$S"
run pod-up
for r in go py; do run probe p0 $r SendMessage yes 1; run probe p0 $r SubscribeToTask yes 1; done
A=$(ts); run apply
run read applied "$A"
for r in go py; do for n in 1 2 3; do
	run probe p1 $r SendMessage yes $n; run probe p1 $r SubscribeToTask yes $n; run probe p1 $r SendMessage no $n
done; done
run read p1-after "$A"
B=$(ts); run remove
run read removed "$B"
run pod-down
kubectl -n agentgateway-waypoint logs deploy/agw-central --since-time="$S" > "$N/agw-central-access.txt" 2>&1
bash "$N/counts.sh" > "$N/counts-driver.txt" 2>&1; echo "$(ts) counts exit=$?" | tee -a "$PH"
echo "$(ts) C-5 replay end" | tee -a "$PH"

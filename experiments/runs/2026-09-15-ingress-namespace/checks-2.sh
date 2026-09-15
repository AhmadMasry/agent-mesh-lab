#!/usr/bin/env bash
# Follow-ups 12: the readings after the host slept, resumed on the controller's word of 2026-09-15 without a rebuild.
# checks.sh ran the rejections before, the readback, the card read and the clean check, and was stopped by hand at
# about 22:16Z while its trace was interrupted (rebuild/host-sleep.txt, trace/attempt-1/INTERRUPTED.txt). This driver
# re-takes the trace from the start with a fresh RUN_ID and runs the remaining readings in the brief's order, each step
# stamped. No keep-awake of any kind is used (the author's decision, relayed by the controller on 2026-09-15): a first
# run of this driver under `caffeinate -i` was stopped by hand when that ruling arrived (trace/attempt-2/STOPPED.txt),
# and a sleep that interrupts a step is recorded and that step re-taken with a fresh RUN_ID. Committed scripts and this
# run's tools only; the probes and the trace create and remove their own client pods. $1 = log file (outside the
# repository, copied in afterwards).
set -uo pipefail
cd $(git rev-parse --show-toplevel)
RUNREL=2026-09-15-ingress-namespace
D=experiments/runs/$RUNREL
LOG="$1"
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
step() { # label, command...
	local label="$1"; shift; local s; s=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
	echo "## $label  started $(ts)" >> "$LOG"
	"$@" >> "$LOG" 2>&1; local rc=$?
	local e; e=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
	echo "## $label  finished $(ts)  exit=$rc  wall=$(perl -e "printf '%.3f', $e - $s")s" >> "$LOG"; echo >> "$LOG"
	echo "$(ts) $label exit=$rc"
}
echo "# Follow-ups 12 readings, resumed $(ts). HEAD $(git rev-parse HEAD); tracked changes: $(git status --short --untracked-files=no | tr '\n' ' ')" > "$LOG"
step "cluster state on resumption (pods, restarts, releases, nodes)" bash -c "kubectl get nodes; helm list -A; kubectl get pods -A -o json | jq -r '.items[] | select(.metadata.namespace | test(\"^(lab|agentgateway-|istio-system|telemetry)\")) | \"\(.metadata.namespace)/\(.metadata.name) phase=\(.status.phase) restarts=\([.status.containerStatuses[]?.restartCount] | add)\"'"
step "trace per work item REPS=2 (fresh RUN_ID)" env REPS=2 RUN_ITEM=$RUNREL/trace RUN_ID=$(date -u +%H%M%S) experiments/gate3-trace-per-work-item.sh
step "dangling parents" bash -c "python3 $D/trace/dangling.py $D/trace > $D/trace/dangling.csv && cat $D/trace/dangling.csv"
step "plaintext probe from telemetry (followups-10 probe.sh, unedited)" env OUT=../$RUNREL/mtls experiments/runs/2026-09-12-current-versions/probe.sh after
step "probe cleanup (telemetry)" env OUT=../$RUNREL/mtls experiments/runs/2026-09-12-current-versions/probe.sh cleanup
step "plaintext probe from agentgateway-system" "$D/probe-cp.sh" after
step "probe cleanup (agentgateway-system)" "$D/probe-cp.sh" cleanup
step "ztunnel rejections after" "$D/rebuild/rejections.sh" "$D/rebuild/ztunnel-rejections-after.txt" "after the card read, the clean check, the three trace attempts and both probes"
step "prometheus targets" bash -c "{ echo '# Prometheus scrape targets on the rebuilt cluster, $(ts).'; echo '# experiments/runs/2026-09-12-mtls-enforced/promq.sh targets, then the up series with the labels each job relabels in (namespace, gateway_name)'; echo; experiments/runs/2026-09-12-mtls-enforced/promq.sh targets; echo; experiments/runs/2026-09-12-mtls-enforced/promq.sh query up | jq -r '.data.result[] | \"\(.metric.job) up=\(.value[1]) instance=\(.metric.instance) namespace=\(.metric.namespace // \"-\") gateway_name=\(.metric.gateway_name // \"-\")\"' | sort; } > $D/rebuild/prometheus-targets.txt 2>&1; cat $D/rebuild/prometheus-targets.txt"
step "tcp connection security raw" bash -c "{ echo '# istio_tcp_connections_opened_total, every series, $(ts): experiments/runs/2026-09-12-mtls-enforced/promq.sh security'; experiments/runs/2026-09-12-mtls-enforced/promq.sh security; } > $D/rebuild/tcp-connection-security-raw.txt 2>&1; wc -l $D/rebuild/tcp-connection-security-raw.txt"
step "hops table" python3 "$D/hops.py"
step "versions and images readback" "$D/rebuild/versions-readback.sh" "$D/rebuild"
step "guard demonstration on the rebuilt cluster" "$D/guard/guard.sh" d28dea6 "$D/guard/make-n-without-helm-rebuilt-cluster.txt"
echo "# readings finished $(ts)" >> "$LOG"
echo "$(ts) checks-2 done"

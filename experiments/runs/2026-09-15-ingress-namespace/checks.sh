#!/usr/bin/env bash
# Follow-ups 12: the readings on the rebuilt cluster, in order, each step stamped. Committed scripts and this run's
# tools only; nothing is edited, restarted or deleted by hand (the probes and the card read create and remove their
# own client pods, as the clean check and the trace do). Runs from the repository root after the rebuild; the log is
# written to $1 (outside the repository) and copied in afterwards.
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
echo "# Follow-ups 12 readings, started $(ts). HEAD $(git rev-parse HEAD); git status --short over the deployed paths -> $(git status --short -- deploy Makefile agents fixtures experiments/lib 'experiments/*.sh' | tr '\n' ' ')" > "$LOG"
step "ztunnel rejections before" "$D/rebuild/rejections.sh" "$D/rebuild/ztunnel-rejections-before.txt" "before the readings, the card read, the clean check, the trace and the probes"
step "readback (helm, istio, certificates, mesh shape, attachment, egress first stream)" "$D/rebuild/readback.sh" "$D/rebuild"
step "agent card read" "$D/rebuild/card.sh" "$D/rebuild/agent-card.txt"
step "clean check" env RUN_ITEM=$RUNREL/clean-check experiments/gate2-single-clean.sh
step "trace per work item REPS=2" env REPS=2 RUN_ITEM=$RUNREL/trace experiments/gate3-trace-per-work-item.sh
step "dangling parents" bash -c "python3 $D/trace/dangling.py $D/trace > $D/trace/dangling.csv && cat $D/trace/dangling.csv"
step "plaintext probe from telemetry (followups-10 probe.sh, unedited)" env OUT=../$RUNREL/mtls experiments/runs/2026-09-12-current-versions/probe.sh after
step "probe cleanup (telemetry)" env OUT=../$RUNREL/mtls experiments/runs/2026-09-12-current-versions/probe.sh cleanup
step "plaintext probe from agentgateway-system" "$D/probe-cp.sh" after
step "probe cleanup (agentgateway-system)" "$D/probe-cp.sh" cleanup
step "ztunnel rejections after" "$D/rebuild/rejections.sh" "$D/rebuild/ztunnel-rejections-after.txt" "after the card read, the clean check, the trace and both probes"
step "prometheus targets" bash -c "{ echo '# Prometheus scrape targets on the rebuilt cluster, $(ts).'; echo '# experiments/runs/2026-09-12-mtls-enforced/promq.sh targets, then the up series with the labels each job relabels in (namespace, gateway_name)'; echo; experiments/runs/2026-09-12-mtls-enforced/promq.sh targets; echo; experiments/runs/2026-09-12-mtls-enforced/promq.sh query up | jq -r '.data.result[] | \"\(.metric.job) up=\(.value[1]) instance=\(.metric.instance) namespace=\(.metric.namespace // \"-\") gateway_name=\(.metric.gateway_name // \"-\")\"' | sort; } > $D/rebuild/prometheus-targets.txt 2>&1; cat $D/rebuild/prometheus-targets.txt"
step "tcp connection security raw" bash -c "{ echo '# istio_tcp_connections_opened_total, every series, $(ts): experiments/runs/2026-09-12-mtls-enforced/promq.sh security'; experiments/runs/2026-09-12-mtls-enforced/promq.sh security; } > $D/rebuild/tcp-connection-security-raw.txt 2>&1; wc -l $D/rebuild/tcp-connection-security-raw.txt"
step "hops table" python3 "$D/hops.py"
step "versions and images readback" "$D/rebuild/versions-readback.sh" "$D/rebuild"
echo "# readings finished $(ts)" >> "$LOG"
echo "$(ts) checks done"

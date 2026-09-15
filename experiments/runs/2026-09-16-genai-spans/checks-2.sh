#!/usr/bin/env bash
# Follow-ups 14, part 2: the three re-run rows, the probes and the closing readings, each step stamped.
# Committed scripts and this run's tools only; nothing is edited, restarted or deleted by hand. The A.3 row
# rolls the orchestrator Deployment's environment, which is what gate3-matrix.sh does for that row and what it
# restores afterwards -- that is the script's own step, not a manual one. Runs from the repository root; the log
# is written to $1 (outside the repository) and copied in afterwards. Adapted from
# experiments/runs/2026-09-15-ingress-namespace/checks.sh (followups-12): the run directory, and the three
# matrix rows this task re-runs.
set -uo pipefail
cd $(git rev-parse --show-toplevel)
RUNREL=2026-09-16-genai-spans
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
echo "# Follow-ups 14 readings part 2, started $(ts). HEAD $(git rev-parse HEAD)" > "$LOG"
step "A.2 go http, REPS=5" env CLIENT=go LAYER=http REPS=5 RUN_ITEM=$RUNREL/a2-go-http experiments/gate2-a2.sh
step "A.2 py http retries, REPS=5" env CLIENT=py LAYER=http PY_HTTP_KNOB=retries REPS=5 RUN_ITEM=$RUNREL/a2-py-http-retries experiments/gate2-a2.sh
step "A.3 R3 py, REPS=5" env RUN=R3 RECEIVER=py REPS=5 RUN_ITEM=$RUNREL/a3-r3-py experiments/gate3-matrix.sh
step "the comparison against the committed rows" python3 "$D/compare.py"
step "GenAI spans in the A.3 R3 py row" bash -c "mkdir -p $D/a3-r3-py/genai && python3 $D/genai-spans.py $D/a3-r3-py $D/a3-r3-py/genai > $D/a3-r3-py/genai/summary.csv && cat $D/a3-r3-py/genai/summary.csv && for f in per-operation chat-spans invoke-agent; do echo; echo \"## \$f.csv\"; cat $D/a3-r3-py/genai/\$f.csv; done"
step "plaintext probe from telemetry (followups-10 probe.sh, unedited)" env OUT=../$RUNREL/mtls experiments/runs/2026-09-12-current-versions/probe.sh after
step "probe cleanup (telemetry)" env OUT=../$RUNREL/mtls experiments/runs/2026-09-12-current-versions/probe.sh cleanup
step "plaintext probe from agentgateway-system" "$D/probe-cp.sh" after
step "probe cleanup (agentgateway-system)" "$D/probe-cp.sh" cleanup
step "ztunnel rejections after" "$D/rebuild/rejections.sh" "$D/rebuild/ztunnel-rejections-after.txt" "after the card read, the clean check, the trace, the A.2 and A.3 rows and both probes (one run each)"
step "prometheus targets" bash -c "{ echo '# Prometheus scrape targets on the rebuilt cluster, $(ts).'; echo '# experiments/runs/2026-09-12-mtls-enforced/promq.sh targets, then the up series with the labels each job relabels in (namespace, gateway_name)'; echo; experiments/runs/2026-09-12-mtls-enforced/promq.sh targets; echo; experiments/runs/2026-09-12-mtls-enforced/promq.sh query up | jq -r '.data.result[] | \"\(.metric.job) up=\(.value[1]) instance=\(.metric.instance) namespace=\(.metric.namespace // \"-\") gateway_name=\(.metric.gateway_name // \"-\")\"' | sort; } > $D/rebuild/prometheus-targets.txt 2>&1; cat $D/rebuild/prometheus-targets.txt"
step "tcp connection security raw" bash -c "{ echo '# istio_tcp_connections_opened_total, every series, $(ts): experiments/runs/2026-09-12-mtls-enforced/promq.sh security'; experiments/runs/2026-09-12-mtls-enforced/promq.sh security; } > $D/rebuild/tcp-connection-security-raw.txt 2>&1; wc -l $D/rebuild/tcp-connection-security-raw.txt"
step "hops table" python3 "$D/hops.py"
step "versions and images readback" "$D/rebuild/versions-readback.sh" "$D/rebuild"
step "image scan" env SCAN_OUT=$D/scan make scan-images
echo "# readings part 2 finished $(ts)" >> "$LOG"
echo "$(ts) checks-2 done"

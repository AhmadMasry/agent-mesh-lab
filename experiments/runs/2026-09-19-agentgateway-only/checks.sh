#!/usr/bin/env bash
# Follow-ups 18, task 2: the standard proof's readings on the rebuilt cluster, in order, each step stamped.
# Committed scripts are run unedited; nothing on the cluster is edited, restarted or deleted by hand (the clean
# check and the trace create and remove their own client pods and Jobs; the plaintext probe creates and removes
# its own pod; the retry-knob readings are `make retry-on` / `make retry-off`, last, and end at zero stanzas).
# Runs from the repository root AFTER the rebuild; the log is written to $1 (outside the repository) and copied
# in afterwards. Adapted from experiments/runs/2026-09-19-failed-model-call/rebuild-2/checks.sh: the output
# paths and nonces, and the readings this topology adds (the STRICT legs, the two proxies' config dumps, the
# cluster facts, the retry knobs). No retry anywhere: every curl is --retry 0 and every send is one send.
set -uo pipefail
cd $(git rev-parse --show-toplevel)
RUNREL=2026-09-19-agentgateway-only
D=experiments/runs/$RUNREL
F14=experiments/runs/2026-09-16-genai-spans
F17=experiments/runs/2026-09-19-waypoint-policy-recheck
MTLS=experiments/runs/2026-09-12-mtls-enforced
LOG="$1"
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
step() { # label, command...
	local label="$1"; shift; local s; s=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
	echo "## $label  started $(ts)  epoch $s" >> "$LOG"
	"$@" >> "$LOG" 2>&1; local rc=$?
	local e; e=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
	echo "## $label  finished $(ts)  epoch $e  exit=$rc  wall=$(perl -e "printf '%.3f', $e - $s")s" >> "$LOG"; echo >> "$LOG"
	echo "$(ts) $label exit=$rc"
}
mkdir -p "$D/strict" "$D/proxies/raw" "$D/cluster" "$D/retry-knobs"
echo "# Follow-ups 18 proof readings, started $(ts). HEAD $(git rev-parse HEAD) ($(git log --format=%s -1 | cut -c1-60)...); git status --short over the deployed paths -> $(git status --short -- deploy Makefile agents fixtures internal experiments/lib 'experiments/*.sh' .ko.yaml go.mod go.sum kind-config.yaml | tr '\n' ' ')" > "$LOG"

# --- 1-5: the standard proof, as every rebuild since follow-ups 12 has taken it -------------------------------
step "clean check" env RUN_ID=fu18c RUN_ITEM=$RUNREL/clean-check experiments/gate2-single-clean.sh
step "trace per work item REPS=2" env REPS=2 RUN_ID=fu18t RUN_ITEM=$RUNREL/trace experiments/gate3-trace-per-work-item.sh
step "dangling parents (follow-ups 14 dangling.py, unedited)" bash -c "python3 $F14/trace/dangling.py $D/trace > $D/trace/dangling.csv && cat $D/trace/dangling.csv"
step "GenAI spans per operation (follow-ups 14 genai-spans.py, unedited)" bash -c "mkdir -p $D/trace/genai && python3 $F14/genai-spans.py $D/trace $D/trace/genai > $D/trace/genai/summary.csv && cat $D/trace/genai/summary.csv"
step "prometheus targets" bash -c "{ echo '# Prometheus scrape targets on the rebuilt cluster, $(ts).'; echo '# $MTLS/promq.sh targets'; echo; $MTLS/promq.sh targets; } > $D/prometheus-targets.txt 2>&1; cat $D/prometheus-targets.txt"

# --- 6: STRICT. Posture, the plaintext probe against both receivers, then every ztunnel series ----------------
posture() {
	echo "== $(ts) PeerAuthentication, every namespace =="
	kubectl get peerauthentication -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,MODE:.spec.mtls.mode,SELECTOR:.spec.selector.matchLabels,PORTS:.spec.portLevelMtls
	echo "== $(ts) namespaces and their dataplane-mode label =="
	kubectl get ns -o custom-columns=NS:.metadata.name,DATAPLANE_MODE:'.metadata.labels.istio\.io/dataplane-mode'
	echo "== $(ts) istioctl ztunnel-config workloads (PROTOCOL HBONE = captured, TCP = not) =="
	istioctl ztunnel-config workloads
}
step "STRICT posture" bash -c "$(declare -f posture ts); posture > $D/strict/posture.txt 2>&1; cat $D/strict/posture.txt"

probe() { # the walkthrough's probe ('Plaintext is refused'), against both receivers, one request each
	local pod=mtls-probe img=curlimages/curl:8.22.0 tp
	kubectl -n default delete pod "$pod" --ignore-not-found --wait=true >/dev/null 2>&1
	kubectl -n default run "$pod" --image="$img" --restart=Never --command -- sleep 600 >/dev/null
	kubectl -n default wait --for=condition=Ready "pod/$pod" --timeout=90s >/dev/null
	tp=$(ts)
	echo "# The plaintext probe, $(ts): a pod in namespace default (not enrolled: $(kubectl get ns default -o jsonpath='{.metadata.labels.istio\.io/dataplane-mode}' | sed 's/^$/no dataplane-mode label/')) asks each receiver for its agent card, once, curl --retry 0." > "$D/strict/plaintext-probe.txt"
	echo "target,http_code,curl_exit" > "$D/strict/plaintext-probe.csv"
	for r in worker orchestrator; do
		local url="http://$r.lab.svc.cluster.local:8080/.well-known/agent-card.json" res rc=0
		res=$(kubectl -n default exec "$pod" -- curl -sS -o /dev/null -w 'http=%{http_code} exit=%{exitcode}' --retry 0 --connect-timeout 5 --max-time 10 "$url" 2>>"$D/strict/plaintext-probe.txt") || rc=$?
		echo "$url -> $res (kubectl exec status $rc)" >> "$D/strict/plaintext-probe.txt"
		echo "$url,$(printf '%s' "$res" | sed -n 's/.*http=\([0-9]*\).*/\1/p'),$(printf '%s' "$res" | sed -n 's/.*exit=\([0-9]*\).*/\1/p')" >> "$D/strict/plaintext-probe.csv"
	done
	sleep 3
	echo "# ztunnel lines holding 'policy rejection' since the probe started ($tp), every ztunnel pod:" > "$D/strict/plaintext-probe-ztunnel.txt"
	for zt in $(kubectl -n istio-system get pods -l app=ztunnel -o jsonpath='{.items[*].metadata.name}'); do
		kubectl -n istio-system logs "$zt" --since-time="$tp" 2>/dev/null | grep 'policy rejection' || true
	done >> "$D/strict/plaintext-probe-ztunnel.txt"
	cat "$D/strict/plaintext-probe.txt" "$D/strict/plaintext-probe.csv"
	echo "ztunnel 'policy rejection' lines: $(grep -c 'policy rejection' "$D/strict/plaintext-probe-ztunnel.txt")"
	echo "  of them naming istio-system/istio_converted_static_strict: $(grep -c 'istio-system/istio_converted_static_strict' "$D/strict/plaintext-probe-ztunnel.txt")"
}
step "plaintext probe, both receivers" bash -c "D=$D; $(declare -f probe ts); probe"

security() {
	echo "-- waiting 35 s so Prometheus has scraped ztunnel (every 15 s) after the last connection above --"
	sleep 35
	{ echo "# istio_tcp_connections_opened_total, every series, $(ts): $MTLS/promq.sh security"; "$MTLS/promq.sh" security 2>&1; } > "$D/strict/tcp-connection-security-raw.txt"
	python3 "$D/hops.py" "$D/strict/tcp-connection-security-raw.txt" "$D/strict/hops-security.csv" "$D/strict/legs.csv"
	echo "--- named legs:"; cat "$D/strict/legs.csv"
	echo "--- ztunnel error/denied/reject lines since the build, other than the probe's own:"
	for zt in $(kubectl -n istio-system get pods -l app=ztunnel -o jsonpath='{.items[*].metadata.name}'); do
		kubectl -n istio-system logs "$zt" --tail=-1 2>/dev/null | grep -E 'error|denied|reject' | grep -v 'src.workload="mtls-probe"' || true
	done > "$D/strict/ztunnel-other-error-lines.txt"
	echo "count: $(grep -c '' "$D/strict/ztunnel-other-error-lines.txt")"
}
step "ztunnel connection security, every series" bash -c "D=$D; MTLS=$MTLS; $(declare -f security ts); security"
kubectl -n default delete pod mtls-probe --ignore-not-found --wait=false >/dev/null 2>&1

# --- 7: each proxy's own /config_dump: its policies and the control plane it is a client of -------------------
dumps() {
	for pair in "agentgateway-waypoint agw-central" "agentgateway-ingress agentgateway-ingress"; do
		set -- $pair
		echo "== $(ts) $1/$2 =="
		"$F17/config-dump.sh" "$1" "$2" "$D/proxies/raw/$2.config-dump.json" >/dev/null
		python3 "$F17/extract-config-dump.py" "$D/proxies/raw/$2.config-dump.json" "$D/proxies/$2.extract.json"
	done
}
step "config dumps (follow-ups 17 config-dump.sh and extract-config-dump.py, unedited)" bash -c "D=$D; F17=$F17; $(declare -f dumps ts); dumps 2>&1 | tee $D/proxies/extracts.txt"

# --- 8: the cluster facts the brief names ----------------------------------------------------------------------
facts() {
	echo "== $(ts) kubectl get gateway -A, with class =="
	kubectl get gateway -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,CLASS:.spec.gatewayClassName,PROGRAMMED:'.status.conditions[?(@.type=="Programmed")].status',ADDRESS:'.status.addresses[0].value'
	echo "Gateways of a class whose name starts with istio: $(kubectl get gateway -A -o jsonpath='{range .items[*]}{.spec.gatewayClassName}{"\n"}{end}' | grep -c '^istio' || true)"
	echo "== $(ts) kubectl get gatewayclass =="
	kubectl get gatewayclass -o custom-columns=NAME:.metadata.name,CONTROLLER:.spec.controllerName,ACCEPTED:'.status.conditions[?(@.type=="Accepted")].status'
	echo "== $(ts) kubectl get httproute -A, with parent and status =="
	kubectl get httproute -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,HOSTNAMES:.spec.hostnames,PARENT:'.spec.parentRefs[0].name',SECTION:'.spec.parentRefs[0].sectionName',ACCEPTED:'.status.parents[0].conditions[?(@.type=="Accepted")].status',RESOLVED:'.status.parents[0].conditions[?(@.type=="ResolvedRefs")].status',CONTROLLER:'.status.parents[0].controllerName'
	echo "== $(ts) kubectl get telemetry -A =="
	kubectl get telemetries.telemetry.istio.io -A 2>&1
	echo "== $(ts) kubectl get agentgatewaypolicy -A, with status =="
	kubectl get agentgatewaypolicy -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,TARGET:'.spec.targetRefs[0].name',ACCEPTED:'.status.ancestors[0].conditions[?(@.type=="Accepted")].status',ATTACHED:'.status.ancestors[0].conditions[?(@.type=="Attached")].status'
	echo "== $(ts) the waypoint binding Istio wrote on each bound object (istio.io/WaypointBound) =="
	for o in "service/worker" "service/orchestrator" "serviceentry/model-external"; do
		printf '%s: ' "$o"; kubectl -n lab get "$o" -o jsonpath='{range .status.conditions[?(@.type=="istio.io/WaypointBound")]}{.status}{" -- "}{.message}{end}'; echo
	done
	echo "== $(ts) istiod's container env =="
	kubectl -n istio-system get deploy istiod -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}={.value}{"\n"}{end}'
	echo "lines naming PILOT_ENABLE_AGENTGATEWAY: $(kubectl -n istio-system get deploy istiod -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}{"\n"}{end}' | grep -c PILOT_ENABLE_AGENTGATEWAY || true)"
	echo "== $(ts) the istio ConfigMap's mesh config =="
	kubectl -n istio-system get cm istio -o jsonpath='{.data.mesh}'; echo
	echo "== $(ts) the central proxy: its pod's labels, its image, and its namespace's labels =="
	kubectl -n agentgateway-waypoint get pods -o custom-columns=POD:.metadata.name,DATAPLANE_MODE:'.metadata.labels.istio\.io/dataplane-mode',GATEWAY:'.metadata.labels.gateway\.networking\.k8s\.io/gateway-name',REDIRECTION:'.metadata.annotations.ambient\.istio\.io/redirection',IMAGE:'.spec.containers[0].image',SA:.spec.serviceAccountName
	echo "namespace agentgateway-waypoint labels: $(kubectl get ns agentgateway-waypoint -o jsonpath='{.metadata.labels}')"
	echo "== $(ts) the ingress proxy, the same way =="
	kubectl -n agentgateway-ingress get pods -o custom-columns=POD:.metadata.name,DATAPLANE_MODE:'.metadata.labels.istio\.io/dataplane-mode',GATEWAY:'.metadata.labels.gateway\.networking\.k8s\.io/gateway-name',REDIRECTION:'.metadata.annotations.ambient\.istio\.io/redirection',IMAGE:'.spec.containers[0].image',SA:.spec.serviceAccountName
	echo "namespace agentgateway-ingress labels: $(kubectl get ns agentgateway-ingress -o jsonpath='{.metadata.labels}')"
	echo "== $(ts) namespaces that exist =="
	kubectl get ns -o name | tr '\n' ' '; echo
	echo "== $(ts) helm list -A =="
	helm list -A -o json | python3 -c 'import json,sys; [print("%-20s %-20s %-10s %s" % (r["name"], r["namespace"], r["status"], r["chart"])) for r in json.load(sys.stdin)]'
	echo "== $(ts) ztunnel's certificates, each node =="
	for n in agent-mesh-lab-worker agent-mesh-lab-control-plane; do echo "-- node $n"; istioctl ztunnel-config certificates --node "$n"; done
}
step "cluster facts" bash -c "$(declare -f facts ts); facts > $D/cluster/facts.txt 2>&1; cat $D/cluster/facts.txt"

# --- 9: the retry knobs, last: each route set on, read, off; and everything off at the end ---------------------
stanzas() { # per route: namespace/name and how many retry stanzas it carries
	kubectl get httproute -A -o json | python3 -c 'import json,sys
for r in json.load(sys.stdin)["items"]:
    n = sum(1 for rule in r["spec"].get("rules", []) if "retry" in rule)
    print("  %s/%s retry_stanzas=%d%s" % (r["metadata"]["namespace"], r["metadata"]["name"], n, "" if not n else " " + json.dumps([rule["retry"] for rule in r["spec"]["rules"] if "retry" in rule])))'
}
knobs() {
	echo "== $(ts) before anything: every route, stanza count =="; stanzas
	for route in waypoint ingress egress; do
		echo "== $(ts) make retry-on ROUTE=$route =="; make --no-print-directory retry-on ROUTE=$route; stanzas
		echo "== $(ts) make retry-off ROUTE=$route =="; make --no-print-directory retry-off ROUTE=$route; stanzas
	done
	echo "== $(ts) make retry-off (every route set), the state every run starts and ends in =="; make --no-print-directory retry-off; stanzas
}
step "retry knobs on the new route names" bash -c "D=$D; $(declare -f knobs stanzas ts); knobs > $D/retry-knobs/readings.txt 2>&1; cat $D/retry-knobs/readings.txt"

echo "# readings finished $(ts)" >> "$LOG"
echo "$(ts) checks done"

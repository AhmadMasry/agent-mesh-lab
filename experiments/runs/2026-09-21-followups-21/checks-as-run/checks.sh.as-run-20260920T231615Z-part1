#!/usr/bin/env bash
# Follow-ups 19, task 3c: the readings on the cluster REBUILD-2 built, in order, each step stamped. Written whole
# before its first invocation and meant to run ONCE, straight through (`all`); at every invocation it logs its own
# sha256 and keeps a byte copy of itself under checks-as-run/, so that what ran can be checked against what is
# committed.
# Part one is the standard proof, every reading task 3's part one took, in its order (clean check; trace REPS=2 with
# dangling parents and the GenAI summary; Prometheus targets; STRICT posture, the plaintext probe against both
# receivers, every ztunnel series -> the hops table; both proxies' config dumps; the cluster facts).
# Part two is ONLY what the one commit between the two rebuilt trees can touch -- `fix(worker): mark the server span
# of an injected close-after-read`, agents/worker/ingress.go and its test:
#   (c) the running images, every container's image and imageID and the Helm releases, beside task 3's read-back.
#       Taken FIRST in part two, as task 3 took its read-back, so that the pod list holds what task 3's held: the
#       built pods and part one's six finished Job pods;
#   (b) experiments/gate1-wire-version.sh, unedited: ingress.go is on the path of the A2A-Version capture (rule 7);
#   (a) the worker's server span under its own close-after-read, LIVE, by the committed row task 3 used for its
#       reading (h): gate3-matrix.sh RUN=R1 SUB=http RECEIVER=go REPS=1 DRY_RUN=off, unedited; read with task 3's
#       reading tool, unedited, and set beside task 3's reading field for field;
#   (d) the ingress ledger's line shape on the cluster, for the clean work items and for the closed delivery, beside
#       task 3's lines for the same rows (rule 5), with the worker pod's own raw log lines beside the collected ones;
#   then one clean work item per receiver, which is what shows the receiver disarmed (it writes no control line).
# The retry knobs come LAST, as in every proof, and end at zero stanzas. The state the cluster is left in and the
# host's sleep record are read after this script, by cluster-after.sh and host-sleep.sh.
# NOT re-taken here, because that commit cannot touch them: the pins read back against pins.csv, rule 4 on the
# orchestrator, Jaeger's API, the mock's span on its two modes, the exporter's columns, the image scan.
# Committed scripts are run unedited; nothing on the cluster is edited, restarted or deleted by hand. What the
# committed scripts themselves do to the cluster: the clean check, the trace, the wire-version script and the matrix
# row create and remove their own client pods and Jobs; the plaintext probe creates and removes its own pod; the
# retry-knob readings are `make retry-on` / `make retry-off`. The R1 row switches on the load client's own knob for
# its one Job (CLIENT_RETRIES=1, CLIENT_RETRY_ON=transport+503), which is what that row measures; it patches no
# route and rolls no Deployment on the Go receiver. No retry anywhere in what this task wrote: every curl here is
# --retry 0 and every send is one send.
# Runs from the repository root AFTER the rebuild; the log is written to $1 (outside the repository) and copied in
# afterwards. $2 = the run directory's name under experiments/runs/. $3 = all (default) | part1 | part2 | knobs.
# Adapted from experiments/runs/2026-09-19-currency-rebuild/checks.sh: part one is that file's part one with the
# output paths and nonces changed (nonces of the same length as task 3's, so that a body's length is comparable);
# part two is new; hops.py, dangling.py, genai-spans.py, promq.sh, config-dump.sh, extract-config-dump.py,
# containers.py and worker-span-reading.py are run from the records that hold them, unedited.
# Keep-awake: this script starts none and changes no power setting.
set -uo pipefail
cd $(git rev-parse --show-toplevel)
LOG="$1"
RUNREL="$2"
ONLY="${3:-all}"
D=experiments/runs/$RUNREL
T3=experiments/runs/2026-09-19-currency-rebuild
F14=experiments/runs/2026-09-16-genai-spans
F17=experiments/runs/2026-09-19-waypoint-policy-recheck
F18=experiments/runs/2026-09-19-agentgateway-only
MTLS=experiments/runs/2026-09-12-mtls-enforced
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
step() { # label, command...
	local label="$1"; shift; local s; s=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
	echo "## $label  started $(ts)  epoch $s" >> "$LOG"
	"$@" >> "$LOG" 2>&1; local rc=$?
	local e; e=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
	echo "## $label  finished $(ts)  epoch $e  exit=$rc  wall=$(perl -e "printf '%.3f', $e - $s")s" >> "$LOG"; echo >> "$LOG"
	echo "$(ts) $label exit=$rc"
}
mkdir -p "$D/strict" "$D/proxies/raw" "$D/cluster" "$D/retry-knobs" "$D/images/raw" "$D/worker-span" "$D/ingress-shape" "$D/checks-as-run"
DEPLOYED=(deploy Makefile agents fixtures internal experiments/lib ':(glob)experiments/*.sh' .ko.yaml go.mod go.sum kind-config.yaml)
SELF_SHA=$(shasum -a 256 "$0" | awk '{print $1}')
ASRUN="$D/checks-as-run/checks.sh.as-run-$(date -u +%Y%m%dT%H%M%SZ)-$ONLY"
cp "$0" "$ASRUN"; chmod 644 "$ASRUN"
echo "# Follow-ups 19 task 3c readings ($ONLY), started $(ts). HEAD $(git rev-parse HEAD) ($(git log --format=%s -1 | cut -c1-60)...); git status --short over the deployed paths -> $(git status --short -- "${DEPLOYED[@]}" | tr '\n' ' ')" >> "$LOG"
echo "# this driver as it runs: sha256 $SELF_SHA; byte copy kept as $ASRUN" >> "$LOG"

if [ "$ONLY" = all ] || [ "$ONLY" = part1 ]; then
# --- 1-5: the standard proof, as every rebuild since follow-ups 12 has taken it -------------------------------
step "clean check" env RUN_ID=fu3cc RUN_ITEM=$RUNREL/clean-check experiments/gate2-single-clean.sh
step "trace per work item REPS=2" env REPS=2 RUN_ID=fu3ct RUN_ITEM=$RUNREL/trace experiments/gate3-trace-per-work-item.sh
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
	local pod=mtls-probe img=curlimages/curl:8.22.0 tp label
	kubectl -n default delete pod "$pod" --ignore-not-found --wait=true >/dev/null 2>&1
	kubectl -n default run "$pod" --image="$img" --restart=Never --command -- sleep 600 >/dev/null
	kubectl -n default wait --for=condition=Ready "pod/$pod" --timeout=90s >/dev/null
	tp=$(ts)
	label=$(kubectl get ns default -o jsonpath='{.metadata.labels.istio\.io/dataplane-mode}')
	echo "# The plaintext probe, $(ts): a pod in namespace default (not enrolled: ${label:-no dataplane-mode label}) asks each receiver for its agent card, once, curl --retry 0." > "$D/strict/plaintext-probe.txt"
	echo "target,http_code,curl_exit" > "$D/strict/plaintext-probe.csv"
	for r in worker orchestrator; do
		local url="http://$r.lab.svc.cluster.local:8080/.well-known/agent-card.json" res rc=0
		res=$(kubectl -n default exec "$pod" -- curl -sS -o /dev/null -w 'http=%{http_code} exit=%{exitcode}' --retry 0 --connect-timeout 5 --max-time 10 "$url" 2>>"$D/strict/plaintext-probe.txt") || rc=$?
		echo "$url -> $res (kubectl exec status $rc)" >> "$D/strict/plaintext-probe.txt"
		echo "$url,$(printf '%s' "$res" | sed -n 's/.*http=\([0-9]*\).*/\1/p'),$(printf '%s' "$res" | sed -n 's/.*exit=\([0-9]*\).*/\1/p')" >> "$D/strict/plaintext-probe.csv"
	done
	sleep 3
	echo "# ztunnel refusal lines since the probe started ($tp), every ztunnel pod:" > "$D/strict/plaintext-probe-ztunnel.txt"
	for zt in $(kubectl -n istio-system get pods -l app=ztunnel -o jsonpath='{.items[*].metadata.name}'); do
		kubectl -n istio-system logs "$zt" --since-time="$tp" 2>/dev/null | grep 'policy rejection' || true
	done >> "$D/strict/plaintext-probe-ztunnel.txt"
	cat "$D/strict/plaintext-probe.txt" "$D/strict/plaintext-probe.csv"
	echo "ztunnel 'policy rejection' lines (the file's own header line does not hold those words): $(grep -c 'policy rejection' "$D/strict/plaintext-probe-ztunnel.txt")"
	echo "  of them naming istio-system/istio_converted_static_strict: $(grep -c 'istio-system/istio_converted_static_strict' "$D/strict/plaintext-probe-ztunnel.txt")"
}
step "plaintext probe, both receivers" bash -c "D=$D; $(declare -f probe ts); probe"

security() {
	echo "-- waiting 35 s so Prometheus has scraped ztunnel (every 15 s) after the last connection above --"
	sleep 35
	{ echo "# istio_tcp_connections_opened_total, every series, $(ts): $MTLS/promq.sh security"; "$MTLS/promq.sh" security 2>&1; } > "$D/strict/tcp-connection-security-raw.txt"
	python3 "$F18/hops.py" "$D/strict/tcp-connection-security-raw.txt" "$D/strict/hops-security.csv" "$D/strict/legs.csv"
	echo "--- named legs:"; cat "$D/strict/legs.csv"
	echo "--- ztunnel error/denied/reject lines since the build, other than the probe's own (by source workload; a probe"
	echo "--- line ztunnel could not attribute carries no src.workload and stays in this file -- the last proofs' note):"
	for zt in $(kubectl -n istio-system get pods -l app=ztunnel -o jsonpath='{.items[*].metadata.name}'); do
		kubectl -n istio-system logs "$zt" --tail=-1 2>/dev/null | grep -E 'error|denied|reject' | grep -v 'src.workload="mtls-probe"' || true
	done > "$D/strict/ztunnel-other-error-lines.txt"
	echo "count: $(grep -c '' "$D/strict/ztunnel-other-error-lines.txt")"
}
step "ztunnel connection security, every series (follow-ups 18 hops.py, unedited)" bash -c "D=$D; MTLS=$MTLS; F18=$F18; $(declare -f security ts); security"
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

# --- 8: the cluster facts ------------------------------------------------------------------------------------
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
fi

if [ "$ONLY" = all ] || [ "$ONLY" = part2 ]; then
# ================= part two: only what the worker change can touch ==============================================
# --- (c) the running images, beside task 3's read-back -----------------------------------------------------------
images() {
	echo "== $(ts) every container of every pod: image as the spec names it, imageID as the node resolved it, ready, restarts (task 3's containers.py, unedited) =="
	kubectl get pods -A -o json > "$D/images/raw/pods.json"
	python3 "$T3/pins/containers.py" "$D/images/raw/pods.json" "$D/images/containers.csv"
	cat "$D/images/containers.csv"
	echo "== $(ts) helm list -A: release, namespace, status, chart, app version =="
	helm list -A -o json > "$D/images/helm-list.json"
	python3 -c 'import json,sys; [print("%-22s %-22s %-10s %-36s app_version=%s" % (r["name"], r["namespace"], r["status"], r["chart"], r["app_version"])) for r in json.load(open(sys.argv[1]))]' "$D/images/helm-list.json"
	echo "== $(ts) the server, the nodes, the Gateway API bundle =="
	kubectl version -o json | python3 -c 'import json,sys; v=json.load(sys.stdin); print("kubectl client %s  server %s" % (v["clientVersion"]["gitVersion"], v["serverVersion"]["gitVersion"]))'
	kubectl get nodes -o custom-columns=NODE:.metadata.name,KUBELET:.status.nodeInfo.kubeletVersion,RUNTIME:.status.nodeInfo.containerRuntimeVersion,OS:.status.nodeInfo.osImage
	docker inspect -f '{{.Name}} image={{.Config.Image}}' agent-mesh-lab-control-plane agent-mesh-lab-worker 2>&1
	for crd in gateways httproutes; do
		printf '%s.gateway.networking.k8s.io: ' "$crd"
		kubectl get crd "$crd.gateway.networking.k8s.io" -o jsonpath='bundle-version={.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version} channel={.metadata.annotations.gateway\.networking\.k8s\.io/channel}{"\n"}'
	done
	istioctl version 2>&1
	echo "== $(ts) the running agents: the SDK each one runs, for the entry's Versions line =="
	kubectl -n lab exec deploy/orchestrator -- python -c 'import importlib.metadata as m; print(" ".join("%s=%s" % (p, m.version(p)) for p in ("a2a-sdk", "openai")))' 2>&1
	echo "(a2a-go's version is the module the worker binary was linked with: go.mod at the built tree -> $(awk '$1 ~ /a2aproject\/a2a-go/ {print $1 "@" $2}' go.mod | tr '\n' ' '))"
	echo "== $(ts) beside task 3's read-back ($T3/pins/containers.csv, helm-list.json): images-vs-task-3.py =="
	python3 "$D/images/images-vs-task-3.py" "$T3/pins/containers.csv" "$D/images/containers.csv" "$T3/pins/helm-list.json" "$D/images/helm-list.json" "$D/images/images-vs-task-3.csv"
}
step "(c) the running images beside task 3's read-back" bash -c "D=$D; T3=$T3; $(declare -f images ts); images 2>&1 | tee $D/images/readback.txt"

# --- (b) the A2A-Version header per SDK, committed script unedited ----------------------------------------------
step "(b) gate1-wire-version.sh, unedited" env RUN_ID=fu3cw RUN_ITEM=$RUNREL/wire-version experiments/gate1-wire-version.sh

# --- (a) the worker's own close-after-read, live, by the committed row task 3 used ------------------------------
step "(a) the worker's own close-after-read: gate3-matrix.sh RUN=R1 SUB=http RECEIVER=go REPS=1 DRY_RUN=off (committed row, unedited)" env RUN=R1 SUB=http RECEIVER=go REPS=1 DRY_RUN=off RUN_ID=fu3ch RUN_ITEM=$RUNREL/worker-span/close-after-read experiments/gate3-matrix.sh
afterrow() {
	echo "== $(ts) retry stanzas across every HTTPRoute after that row: $(kubectl get httproute -A -o yaml | grep -c 'retry:' || true)"
	echo "== $(ts) the worker Deployment's env, names starting MODEL_ or CLIENT_ (deploy/ sets MODEL_BASE_URL, MODEL_NAME, MODEL_API_KEY and no other) =="
	kubectl -n lab get deploy/worker -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}={.value}{"\n"}{end}' | grep -E '^(MODEL_|CLIENT_)' || echo "  (none)"
	kubectl -n lab get deploy worker orchestrator mockllm -o custom-columns=DEPLOY:.metadata.name,GENERATION:.metadata.generation,READY:.status.readyReplicas
	kubectl -n lab get pods -o custom-columns=POD:.metadata.name,STARTED:.status.startTime --no-headers | grep -v '^loadgen-'
	echo "== $(ts) the mock's control lines: the last one =="
	kubectl -n lab logs deploy/mockllm --tail=-1 | grep '"ledger":"control"' | tail -1
	echo "== $(ts) the worker's process log (not a ledger) prints a line only for a close-after-read that could NOT take its connection or could not close it (agents/worker/ingress.go); such lines: =="
	kubectl -n lab logs deploy/worker --tail=-1 | grep -v '^{' | grep -i 'close-after-read' || echo "  (none)"
}
step "(a) stanzas, the worker's env and the mock's last control line after that row" bash -c "D=$D; $(declare -f afterrow ts); afterrow 2>&1 | tee $D/worker-span/after-the-row.txt"
reading() {
	local wi="$D/worker-span/close-after-read/a3m-r1-go-http-fu3ch-01" out="$D/worker-span/after-live-close-after-read.txt"
	{
	echo "# The worker's own close-after-read at the tree of the commit that marks it (the live AFTER): $(ts). python3 $T3/worker-span/worker-span-reading.py (task 3's reading tool, unedited) on the work item gate3-matrix.sh RUN=R1 SUB=http RECEIVER=go REPS=1 DRY_RUN=off sent on this cluster. Task 3's reading (h), $T3/worker-span/before-live-close-after-read.txt, is the live BEFORE."
	python3 "$T3/worker-span/worker-span-reading.py" "$wi"
	echo
	echo "## the row's own attribution:"
	cat "$wi/attribution.txt"
	} > "$out" 2>&1
	cat "$out"
	echo "== $(ts) BEFORE beside AFTER, field for field: before-vs-after.py =="
	python3 "$D/worker-span/before-vs-after.py" "$T3/worker-span/before-live-close-after-read.txt" "$out" > "$D/worker-span/before-vs-after.txt" 2>&1
	tail -1 "$D/worker-span/before-vs-after.txt"
	grep -E '^    (DIFFERS)' "$D/worker-span/before-vs-after.txt" || echo "  (no row reads DIFFERS)"
}
step "(a) the span read with task 3's tool, and set beside task 3's reading (h)" bash -c "D=$D; T3=$T3; $(declare -f reading ts); reading"

# --- (d) the ingress ledger's line shape on the cluster, beside task 3's ----------------------------------------
shape() {
	local closed="a3m-r1-go-http-fu3ch-01" lwi
	for lwi in g2c-fu3cc-worker g2c-fu3cc-orchestrator "$closed"; do
		kubectl -n lab logs deploy/worker --tail=-1 | grep '"ledger":"ingress"' | grep "\"logical_work_item_id\":\"$lwi\"" > "$D/ingress-shape/worker-log-raw-lines-$lwi.jsonl" || true
		echo "raw ingress lines in the worker pod's own log for $lwi: $(grep -c '' "$D/ingress-shape/worker-log-raw-lines-$lwi.jsonl")"
	done
	python3 "$D/ingress-shape/ingress-shape.py" \
		"clean work item, sent to the worker (gate2-single-clean.sh)" "$T3/clean-check/g2c-fu19c-worker/ingress.jsonl" "$D/clean-check/g2c-fu3cc-worker/ingress.jsonl" "$D/ingress-shape/worker-log-raw-lines-g2c-fu3cc-worker.jsonl" -- \
		"clean work item, sent to the orchestrator, which forwards to the worker (gate2-single-clean.sh)" "$T3/clean-check/g2c-fu19c-orchestrator/ingress.jsonl" "$D/clean-check/g2c-fu3cc-orchestrator/ingress.jsonl" "$D/ingress-shape/worker-log-raw-lines-g2c-fu3cc-orchestrator.jsonl" -- \
		"the closed delivery and the one served after it (gate3-matrix.sh R1 http go)" "$T3/worker-span/close-after-read/a3m-r1-go-http-fu19h-01/ingress.jsonl" "$D/worker-span/close-after-read/$closed/ingress.jsonl" "$D/ingress-shape/worker-log-raw-lines-$closed.jsonl"
}
step "(d) the ingress ledger's line shape beside task 3's (ingress-shape.py)" bash -c "D=$D; T3=$T3; $(declare -f shape ts); shape 2>&1 | tee $D/ingress-shape/ingress-shape.txt"

# --- one clean work item per receiver after the row: the receiver writes no control line, so this is what shows it disarmed
step "one clean work item per receiver after the row" env RUN_ID=fu3cy RUN_ITEM=$RUNREL/worker-span/clean-after experiments/gate2-single-clean.sh
fi

if [ "$ONLY" = all ] || [ "$ONLY" = knobs ]; then
# --- last: the retry knobs: each route set on, read, off; and everything off at the end -------------------------
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
KNOBS_OUT=$D/retry-knobs/readings.txt
if [ -e "$KNOBS_OUT" ]; then KNOBS_OUT="$D/retry-knobs/readings-take-$(date -u +%Y%m%dT%H%M%SZ).txt"; fi
step "retry knobs -> $KNOBS_OUT" bash -c "D=$D; $(declare -f knobs stanzas ts); knobs > $KNOBS_OUT 2>&1; cat $KNOBS_OUT"
fi

echo "# readings ($ONLY) finished $(ts)" >> "$LOG"
echo "$(ts) checks done ($ONLY)"

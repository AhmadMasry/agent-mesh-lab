#!/usr/bin/env bash
# Gate 3 / both receivers / trace per work item.
#
# One clean SendMessage per receiver, repeated, with the trace for each work item
# exported next to that work item's three ledgers. Nothing is injected and no retry
# knob is set: this counts what the instrumentation sees when everything works, so
# that a later row's missing span is a property of the row rather than of the
# pipeline.
#
# The two paths are the ones the Gate 2 script established:
#
#   worker:       loadgen -> worker Service. The loadgen pod is ztunnel-captured, so
#                 the request reaches the worker through the waypoint the worker
#                 Service names, `agw-central`. The worker's model call leaves
#                 through the same proxy, in its egress role.
#   orchestrator: loadgen -> orchestrator Service for the card; the card advertises the
#                 agentgateway ingress, so the SendMessage POST enters through the
#                 ingress, and the orchestrator forwards to the worker through
#                 `agw-central`.
#
# Since 2026-09-19 (the author's decision of that day in docs/proposal-notes.md) one
# agentgateway-managed proxy, `agw-central`, is the waypoint for both agents and the
# egress for the model host. Until then the worker path crossed an istiod-driven waypoint
# and a separate egress proxy, and the orchestrator path a second istiod-driven waypoint;
# run directories dated before that day name those proxies in their summaries.
#
# One Job per work item, backoffLimit 0, one send. No retry logic anywhere.
#
#   REPS=<n>       repetitions per receiver (default 5)
#   RECEIVERS=<s>  which receivers to send to (default "worker orchestrator"). One
#                  receiver's repetitions can be re-run on their own after a change that
#                  affects only that receiver; the summary is rebuilt from every work
#                  item the run directory holds, so the other receiver's rows survive.
#   RUN_ID=<s>     nonce in the work-item ids (default the wall clock)
#   RUN_ITEM=<s>   the run directory under experiments/runs (default today's a3 item)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

NAMESPACE="lab"
CLUSTER_NAME="agent-mesh-lab"
REPS="${REPS:-5}"
RECEIVERS="${RECEIVERS:-worker orchestrator}"
# Pod logs outlive runs, so a repeated work-item id would collect an earlier run's
# lines as if they were this run's.
RUN_ID="${RUN_ID:-$(date +%H%M%S)}"
RUN_ITEM="${RUN_ITEM:-$(date +%F)-a3-trace-per-work-item}"
RUN_DIR="experiments/runs/${RUN_ITEM}"
CURL_POD="a3t-curl"
CURL_IMAGE="curlimages/curl:8.22.0"
MOCK_URL="http://mockllm.lab.svc.cluster.local:8080"
WORKER_URL="http://worker.lab.svc.cluster.local:8080"
ORCH_URL="http://orchestrator.lab.svc.cluster.local:8080"

# The hops each path crosses, named by the Kubernetes object that carries them. A hop
# is counted as having produced a span when a span's service.name is this string; the
# summary also prints every service that did appear, so a hop that named itself
# something else shows up there rather than being silently counted as missing.
#
# `agw-central` is listed once per path although it serves more than one leg of each (it
# holds the worker's route, the orchestrator's and the model host's): one proxy has one
# service.name, so this list can say whether that proxy produced a span, not which of its
# legs did. How many spans it produced per work item is in spans_by_service. Telling its
# legs apart needs something other than the service name: the span's `route`, a column
# of spans.csv since 2026-09-19, which is what experiments/lib/derive-layer.sh keys on
# (MODEL_ROUTE for the model leg, and the route read from the trace for an agent leg).
# This script still counts hops by service name and reads no route.
# Until 2026-09-19 the lists named five and eight hops: `agentgateway-waypoint` and
# `agw-egress` on the worker path, and those two plus `agentgateway-waypoint-orch` on the
# orchestrator path.
HOPS_WORKER="loadgen agw-central worker mockllm"
HOPS_ORCH="loadgen agw-central agentgateway-ingress orchestrator worker mockllm"

mkdir -p "$RUN_DIR"

cleanup() {
	kubectl -n "$NAMESPACE" delete pod "$CURL_POD" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

# The two run-level records append rather than overwrite, each invocation under a dated
# header naming the receivers it sent to. A run directory can be filled by more than one
# invocation — one receiver's repetitions re-run after a change that affects only it — and
# overwriting would leave only the last invocation's certificate check in the record.
STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
HEADER="== ${STAMP} | RUN_ID=${RUN_ID} | REPS=${REPS} | RECEIVERS=${RECEIVERS} =="

echo "== certificate check =="
CERTS="$(istioctl ztunnel-config certificates --node "${CLUSTER_NAME}-worker")"
printf '%s\n' "$HEADER" "$CERTS" "" >>"${RUN_DIR}/certificates.txt"
printf '%s\n' "$CERTS"
if ! printf '%s\n' "$CERTS" | awk '$1 ~ /ns\/lab\/sa\/default$/ && $2 == "Leaf" { print $4 }' | grep -qx true; then
	echo "certificate check: VALID CERT is not true for spiffe://cluster.local/ns/lab/sa/default; restart ds/ztunnel and record it" >&2
	exit 1
fi

{
	printf '%s\n' "$HEADER"
	kubectl version
	istioctl version --remote=false
	kubectl -n "$NAMESPACE" get deploy -o wide
	# The Python agent's image keeps one tag, so the tag says nothing about which build
	# ran; the digest the kubelet resolved it to does.
	echo "orchestrator image digests, by pod:"
	kubectl -n "$NAMESPACE" get pods -l app=orchestrator \
		-o 'custom-columns=POD:.metadata.name,PHASE:.status.phase,IMAGE:.spec.containers[0].image,IMAGEID:.status.containerStatuses[0].imageID'
	kubectl get gateway -A
	echo
} >>"${RUN_DIR}/cluster-versions.txt" 2>&1

echo "== starting the control pod =="
kubectl -n "$NAMESPACE" delete pod "$CURL_POD" --ignore-not-found --wait=true >/dev/null 2>&1 || true
kubectl -n "$NAMESPACE" run "$CURL_POD" --image="$CURL_IMAGE" --restart=Never --command -- sleep 3600 >/dev/null
kubectl -n "$NAMESPACE" wait --for=condition=Ready "pod/${CURL_POD}" --timeout=60s >/dev/null

post() { kubectl -n "$NAMESPACE" exec "$CURL_POD" -- curl -s -o /dev/null -w "%{http_code}" -X POST "$1"; }

reset_all() {
	for url in "${MOCK_URL}/control/reset" "${WORKER_URL}/control/reset" "${ORCH_URL}/control/reset"; do
		code=$(post "$url")
		case "$code" in 2??) ;; *) echo "reset ${url} returned ${code}" >&2; exit 1 ;; esac
	done
}

run_one() { # $1 = receiver, $2 = target URL, $3 = work item
	local receiver="$1" target="$2" lwi="$3"
	echo "== ${receiver}: one clean request, logical_work_item_id=${lwi} =="
	reset_all
	kubectl -n "$NAMESPACE" delete job "loadgen-${lwi}" --ignore-not-found --wait=true >/dev/null 2>&1 || true
	sed -e "s/\${LWI}/${lwi}/g" -e "s#\${TARGET_URL}#${target}#g" deploy/base/loadgen-job.yaml \
		| KO_DOCKER_REPO=kind.local KIND_CLUSTER_NAME="$CLUSTER_NAME" ko apply --platform="linux/$(go env GOARCH)" -f - >/dev/null
	# A Job that fails is a recorded outcome, so wait for either condition.
	kubectl -n "$NAMESPACE" wait --for=condition=complete "job/loadgen-${lwi}" --timeout=180s >/dev/null 2>&1 \
		|| kubectl -n "$NAMESPACE" wait --for=condition=failed "job/loadgen-${lwi}" --timeout=10s >/dev/null 2>&1 \
		|| echo "warning: job loadgen-${lwi} reached neither complete nor failed within the timeout"
	mkdir -p "${RUN_DIR}/${lwi}"
	make --no-print-directory ledgers "LWI=${lwi}" "OUT=${RUN_DIR}/${lwi}" >/dev/null
	# The batch span processors flush on a timer and the trace backend stores in
	# memory, so the trace is exported here, in the run, rather than afterwards.
	sleep 8
	make --no-print-directory export-trace "LWI=${lwi}" "OUT=${RUN_DIR}/${lwi}" || true
}

for rep in $(seq 1 "$REPS"); do
	for receiver in $RECEIVERS; do
		lwi="a3t-${RUN_ID}-r${rep}-${receiver}"
		case "$receiver" in
			worker) run_one worker "$WORKER_URL" "$lwi" ;;
			orchestrator) run_one orchestrator "$ORCH_URL" "$lwi" ;;
			*) echo "unknown receiver ${receiver}" >&2; exit 1 ;;
		esac
	done
done

# The summary is computed with python's csv reader rather than by cutting on commas:
# the exporter quotes any field that contains one, and a span operation is free to.
{
	echo "receiver,work_item,trace_ids,spans,spans_by_service,hops_without_span,lab_work_item_on_all"
	# Every work item the run directory holds, not only the ones this invocation sent,
	# so a re-run of one receiver leaves the other receiver's rows in place.
	for dir in "${RUN_DIR}"/*/; do
		lwi="$(basename "$dir")"
		case "$lwi" in
			*-worker) receiver="worker" ;;
			*-orchestrator) receiver="orchestrator" ;;
			*) continue ;;
		esac
		case "$receiver" in
			worker) hops="$HOPS_WORKER" ;;
			*) hops="$HOPS_ORCH" ;;
		esac
		RECEIVER="$receiver" LWI="$lwi" HOPS="$hops" SPANS_CSV="${RUN_DIR}/${lwi}/spans.csv" python3 - <<'PY'
import collections, csv, os, pathlib

receiver, lwi, hops = os.environ["RECEIVER"], os.environ["LWI"], os.environ["HOPS"].split()
path = pathlib.Path(os.environ["SPANS_CSV"])
rows = list(csv.DictReader(path.open())) if path.exists() else []

by_service = collections.Counter(row["service"] for row in rows)
trace_ids = len({row["trace_id"] for row in rows})
carrying = sum(1 for row in rows if row["lab_work_item"] == lwi)
missing = [hop for hop in hops if hop not in by_service]

print(",".join([
    receiver,
    lwi,
    str(trace_ids),
    str(len(rows)),
    "|".join(f"{name}={count}" for name, count in sorted(by_service.items())) or "none",
    "|".join(missing) or "none",
    "yes" if rows and carrying == len(rows) else f"no:{carrying}/{len(rows)}",
]))
PY
	done
} >"${RUN_DIR}/summary.csv"

echo "== summary =="
cat "${RUN_DIR}/summary.csv"

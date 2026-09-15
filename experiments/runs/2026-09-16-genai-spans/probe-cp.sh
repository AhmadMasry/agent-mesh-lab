#!/usr/bin/env bash
# Follow-ups 14 / the second plaintext probe: the same probe, sent from the control plane's namespace.
#
# Copied from experiments/runs/2026-09-15-ingress-namespace/probe-cp.sh (followups-12) with ONE line changed,
# RUN_DIR, which that copy had fixed to its own run directory. It was copied here without that line being
# updated, so the first attempt of this task's probe wrote its two files into the follow-ups 12 run directory,
# appending to its CSV. Those two committed files were restored from git, unchanged, and the attempt's output
# is kept uncounted in mtls/attempt-1-wrong-path/ (its CSV holds followups-12's two rows and this run's two).
# The counted probe is the re-run with the line below corrected. findings.md says so.
#
# Copied from experiments/runs/2026-09-12-current-versions/probe.sh (followups-10), which is copied from
# ../2026-09-12-mtls-enforced/probe.sh (followups-7). Changed, and nothing else: this header; NS is
# `agentgateway-system`, which since follow-ups 12 carries no istio.io/dataplane-mode label, where the original's is
# `telemetry`; POD is `mtls-probe-cp`; RUN_DIR is fixed to this task's run directory and the two files are named
# plaintext-probe-cp-<phase>.txt and plaintext-probe-cp.csv; and the ztunnel workload listing prints the rows of NS
# and of lab. The question is the original's, asked from a namespace that was enrolled until this task: does a pod
# there, now outside the mesh, get an answer from a mesh workload? Under mesh-wide STRICT the documented answer is no.
#
# The original header follows.
#
# Follow-ups 7 / the plaintext probe that mTLS enforcement is measured with.
#
# One question: does a pod that is NOT in the mesh get an answer from a mesh workload?
# Before the STRICT PeerAuthentication the documented answer is yes, and after it no:
#
#   "The default policy for ambient mode is PERMISSIVE, which allows pods to accept
#    both mTLS-encrypted traffic (from within the mesh) and plain text traffic (from
#    without). Enabling STRICT mode means that pods will only accept mTLS-encrypted
#    traffic."                  https://istio.io/latest/docs/ambient/usage/l4-policy/
#
#   "Having HBONE configured on your workload doesn't mean your workload will reject
#    any plaintext traffic. If you want your workload to reject plaintext traffic,
#    create a PeerAuthentication policy with mTLS mode set to STRICT for your
#    workload."        https://istio.io/latest/docs/ambient/usage/verify-mtls-enabled/
#
# The prober sits in `telemetry`, which deploy/step-3-stress/namespace.yaml creates
# deliberately without `istio.io/dataplane-mode=ambient`, so its packets arrive at the
# receiving pod as plaintext on the in-pod ztunnel port 15006 rather than as HBONE on
# 15008 -- the two paths the redirection rules distinguish
# (https://istio.io/latest/docs/ambient/architecture/traffic-redirection/). The target
# is each agent's A2A Agent Card, a plain unauthenticated GET, so a refusal is the
# transport refusing and not the application.
#
# No retry anywhere: curl is given `--retry 0` explicitly and each URL is requested
# once per phase. The exit code is recorded as well as the status, because a refused
# connection has no status to record.
#
# The attempt's subdirectory is OUT (default attempt-2): the first attempt's files stay
# in attempt-1/ exactly as they were taken.
#
#   OUT=attempt-2 ./probe.sh before     # run before `kubectl apply -f` of the policy
#   OUT=attempt-2 ./probe.sh after      # run after it
#   OUT=attempt-2 ./probe.sh reverted   # run after `kubectl delete -f`, if it is reverted
#                 ./probe.sh cleanup    # remove the prober pod
set -euo pipefail

PHASE="${1:?usage: probe.sh before|after|reverted|cleanup}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$REPO_ROOT"

RUN_DIR="experiments/runs/2026-09-16-genai-spans/mtls"
mkdir -p "$RUN_DIR"
NS="agentgateway-system"             # not ambient-enrolled since follow-ups 12: the point of this probe
POD="mtls-probe-cp"
IMAGE="curlimages/curl:8.22.0"       # the image every other script in this repo uses (follow-ups 10: copied from ../2026-09-12-mtls-enforced/probe.sh with only this line and the overrides image changed)
CURL_OPTS=(-sS -o /dev/null -w '%{http_code}' --retry 0 --connect-timeout 5 --max-time 10)
CARD_PATH="/.well-known/agent-card.json"

# The non-root securityContext deploy/base/worker.yaml uses, carried onto the prober so
# it is admitted under the same terms as the lab's own pods.
OVERRIDES='{
  "spec": {
    "securityContext": {
      "runAsNonRoot": true, "runAsUser": 65532, "runAsGroup": 65532, "fsGroup": 65532,
      "seccompProfile": {"type": "RuntimeDefault"}
    },
    "containers": [{
      "name": "mtls-probe-cp",
      "image": "curlimages/curl:8.22.0",
      "command": ["sleep", "900"],
      "securityContext": {
        "allowPrivilegeEscalation": false, "readOnlyRootFilesystem": true,
        "runAsNonRoot": true, "runAsUser": 65532, "runAsGroup": 65532,
        "capabilities": {"drop": ["ALL"]},
        "seccompProfile": {"type": "RuntimeDefault"}
      }
    }]
  }
}'

if [ "$PHASE" = "cleanup" ]; then
	kubectl -n "$NS" delete pod "$POD" --ignore-not-found --wait=true
	echo "prober removed"
	exit 0
fi

case "$PHASE" in before|after|reverted) ;; *) echo "phase must be before, after, reverted or cleanup" >&2; exit 2 ;; esac

LOG="${RUN_DIR}/plaintext-probe-cp-${PHASE}.txt"
CSV="${RUN_DIR}/plaintext-probe-cp.csv"
STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

{
	echo "== ${STAMP} | phase=${PHASE} =="
	echo "-- the prober's namespace is not ambient-enrolled:"
	kubectl get ns "$NS" --show-labels
	echo "-- the policy, as the cluster has it at this moment:"
	kubectl get peerauthentication -A -o yaml 2>&1 | sed -n '1,40p'
} >>"$LOG" 2>&1

if ! kubectl -n "$NS" get pod "$POD" >/dev/null 2>&1; then
	kubectl -n "$NS" run "$POD" --image="$IMAGE" --restart=Never \
		--overrides="$OVERRIDES" --command -- sleep 900 >/dev/null
fi
kubectl -n "$NS" wait --for=condition=Ready "pod/${POD}" --timeout=90s >/dev/null

{
	echo "-- the prober is not in the mesh, as ztunnel sees it (no row for ${NS}/${POD} is the expected reading):"
	istioctl ztunnel-config workloads 2>&1 | awk -v ns="$NS" 'NR==1 || $1 == ns || $1 == "lab"'
} >>"$LOG" 2>&1

[ -f "$CSV" ] || echo "phase,receiver,url,curl_exit,http_code,curl_stderr" >"$CSV"

for receiver in worker orchestrator; do
	url="http://${receiver}.lab.svc.cluster.local:8080${CARD_PATH}"
	echo "== ${PHASE} ${receiver}: ${url} =="
	err_file="$(mktemp)"
	set +e
	code="$(kubectl -n "$NS" exec "$POD" -- curl "${CURL_OPTS[@]}" "$url" 2>"$err_file")"
	rc=$?
	set -e
	err="$(tr '\n' ' ' <"$err_file" | sed -e 's/"/'"'"'/g' -e 's/  */ /g' -e 's/ *$//')"
	rm -f "$err_file"
	printf '%s\n' "curl exit=${rc} http_code=${code:-none} stderr=${err}"
	{
		echo "-- ${receiver} ${url}"
		echo "   curl exit=${rc} http_code=${code:-none}"
		echo "   stderr: ${err}"
	} >>"$LOG"
	printf '%s,%s,%s,%s,%s,"%s"\n' "$PHASE" "$receiver" "$url" "$rc" "${code:-none}" "$err" >>"$CSV"
done

printf '\n' >>"$LOG"
echo "== ${PHASE} phase recorded in ${LOG} and ${CSV} =="

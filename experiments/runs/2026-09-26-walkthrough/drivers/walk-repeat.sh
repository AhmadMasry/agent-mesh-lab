#!/usr/bin/env bash
# Follow-ups 24: ONE step appended to the walk after the two trials and their clean check, by the controller's ruling of
# 2026-09-26 ("C-8 batch cells: append a repeat with the by-hash read"): C-8's Deny overlay applied as C-8 applied it, the
# two batch probes sent by c8.sh unedited, one per receiver, then the by-body-hash read the C-8 entry made by hand
# (its ingress-by-body-hash.txt header: the receiver's log grepped for the sha256 of the body the client recorded),
# taken on both receivers right after the probes and before anything rolls the agents, the overlay removed, and the
# clean check; then, ruled the same way when D-3's comparison showed the same class (its allow-window batch probes were
# read by hand there too), D-3's overlay applied, its setting put to allow, its two batch probes sent by d3.sh unedited,
# the same read on both receivers, the setting put back to deny, the overlay removed, and the clean check. It runs once
# the walk's own driver (walk.sh) has exited, because a running script is not edited; its
# steps log to the same scratch directory in the same format, numbered after the walk's last step, and it appends its
# own window to windows.csv. Then the closing state and size reads of the walk are taken again (91, 92) so that the
# record's closing reads describe the cluster after everything. The run() and step() functions are walk.sh's, copied.
# No retry: each command runs once. Keep-awake: this driver starts none and changes no power setting.
# $WALK_SCRATCH and $D as for walk.sh.
set -u
cd "$(git rev-parse --show-toplevel)" || exit 1
: "${WALK_SCRATCH:?}" "${D:?}"
L="$WALK_SCRATCH/logs"; TIM="$WALK_SCRATCH/timings.csv"; WIN="$WALK_SCRATCH/windows.csv"
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
	case " $ok " in *" $rc "*) ;; *) echo "repeat driver: $f exited $rc (allowed: $ok); stopping"; echo "repeat,$T0UTC,$(ts)" >> "$WIN"; exit "$rc" ;; esac
}
step() { local cmd; cmd=$(cat); run "$1" "$2" "$3" "$cmd"; }
T0UTC=$(ts)
echo "$T0UTC repeat driver start; HEAD $(git rev-parse HEAD); tree $(git rev-parse 'HEAD^{tree}')"

step 90-c8-batch-repeat c8-batch-repeat 0 <<'EOF2'
mkdir -p experiments/runs/@D@/c8-repeat
cp -R experiments/runs/2026-09-23-c8-body-rule/overlay-c8-deny experiments/runs/2026-09-23-c8-body-rule/counts.py experiments/runs/@D@/c8-repeat/
export RUNREL=@D@/c8-repeat RUN_ID=wtc8r
SENDS="bash experiments/runs/2026-09-23-c6-httproute/sends.sh"; C8="bash experiments/runs/2026-09-23-c8-body-rule/c8.sh"
export IMAGE=$($SENDS image | sed -n 's/.* image=\([^ ]*\) .*/\1/p'); echo "IMAGE=$IMAGE"
S=$(date -u +%FT%TZ)
$C8 read before "$S"
$SENDS pod-up
T=$(date -u +%FT%TZ); $C8 apply overlay-c8-deny; sleep 10; $C8 read deny-applied "$T"
for r in go py; do $C8 probe c8d batch $r 1; done
echo "== the by-body-hash read, as the C-8 entry's ingress-by-body-hash.txt header gives it: the receiver's log since the apply, grepped for the sha256 of the body the client recorded =="
for pair in go:worker py:orchestrator; do
  recv=${pair%%:*}; app=${pair##*:}
  P=experiments/runs/@D@/c8-repeat/c8d/c8d-$recv-batch-wtc8r-1
  H=$(shasum -a 256 $P/request.json | cut -d' ' -f1)
  { echo "# $(date -u +%FT%TZ) kubectl -n lab logs deploy/$app --since-time=$T | grep $H  (make ledgers found no line by the work-item id: the body does not parse as an object, so the ledger line carries no identity; joined here on the body hash the client recorded)"
    kubectl -n lab logs deploy/$app --since-time=$T | grep "$H"; } > $P/ingress-by-body-hash.txt
  cat $P/ingress-by-body-hash.txt
done
U=$(date -u +%FT%TZ); $C8 read deny-end "$T"; $C8 remove overlay-c8-deny; sleep 10; $C8 read deny-removed "$U"
$SENDS pod-down
RUN_ID=c8rafter RUN_ITEM=@D@/c8-repeat/after experiments/gate2-single-clean.sh
python3 experiments/runs/@D@/c8-repeat/counts.py | tee experiments/runs/@D@/c8-repeat/counts.txt
EOF2

step 90b-d3-batch-repeat d3-batch-repeat 0 <<'EOF2'
mkdir -p experiments/runs/@D@/d3-repeat
cp -R experiments/runs/2026-09-24-d3-extauthz/overlay-d3-extauthz experiments/runs/2026-09-24-d3-extauthz/counts.py experiments/runs/@D@/d3-repeat/
export RUNREL=@D@/d3-repeat RUN_ID=d3ar
X="bash experiments/runs/2026-09-24-d3-extauthz/d3.sh"
export IMAGE=$($X image | sed -n 's/.* image=\([^ ]*\) .*/\1/p'); echo "IMAGE=$IMAGE"
$X pod-up
$X read allow-before; $X apply; sleep 8; $X setting allow; $X read allow-applied
for r in go py; do $X send allow jsonrpc batch $r 1; done
echo "== the by-body-hash read, D-3's method (its ingress-by-body-hash.txt, which D-3b's batch-by-hash.sh writes the same way): each receiver's ingress-ledger lines whose body_sha256 is the one the client recorded, with the field source set as make ledgers sets it =="
for pair in go:worker py:orchestrator; do
  recv=${pair%%:*}; app=${pair##*:}
  P=experiments/runs/@D@/d3-repeat/allow/allow-jsonrpc-$recv-batch-d3ar-1
  H=$(jq -r '.body_sha256' $P/client.jsonl)
  kubectl -n lab logs deploy/$app --tail=-1 | grep '"ledger":"ingress"' | { grep -F "\"body_sha256\":\"$H\"" || true; } | jq -c --arg s "$app" '. + {source: $s}' > $P/ingress-by-body-hash.txt
  echo "$(basename $P) $app sha256=$H lines=$(grep -c . $P/ingress-by-body-hash.txt)"; cat $P/ingress-by-body-hash.txt
done
$X read allow-end
$X setting deny; $X read deny-restored
$X remove; sleep 8; $X read removed
$X pod-down
RUN_ID=d3rafter RUN_ITEM=@D@/d3-repeat/after experiments/gate2-single-clean.sh
python3 experiments/runs/@D@/d3-repeat/counts.py | tee experiments/runs/@D@/d3-repeat/counts.txt
EOF2

step 91-closing-state-after-repeat - 0 <<'EOF2'
echo "## retry stanzas across every HTTPRoute"; kubectl get httproute -A -o yaml | grep -c "retry:"
echo "## AuthorizationPolicies, AgentgatewayPolicies, AgentgatewayBackends, the agent Services' appProtocol, the agents' settings"
kubectl get authorizationpolicy -A --no-headers 2>/dev/null | wc -l | tr -d ' ' | sed 's/^/AuthorizationPolicy: /'
kubectl get agentgatewaypolicy -A --no-headers | wc -l | tr -d ' ' | sed 's/^/AgentgatewayPolicy: /'
kubectl get agentgatewaybackend -A --no-headers | wc -l | tr -d ' ' | sed 's/^/AgentgatewayBackend: /'
kubectl -n lab get svc worker orchestrator -o jsonpath='{range .items[*]}{.metadata.name} appProtocol=[{.spec.ports[0].appProtocol}]{"\n"}{end}'
kubectl -n lab get deploy -o json | jq -r '.items[] | .metadata.name as $n | ((.spec.template.spec.containers[0].env // [])[] | select(.name | test("^(CLIENT_|MODEL_RETRIES|MODEL_MAX_RETRIES|REFUSE_OPERATION|LEDGER_HEADERS|FORWARD_RESUBSCRIBE|DOWNSTREAM_A2A_URL|EXTAUTHZ_UNDECIDABLE)")) | "\($n): \(.name)=[\(.value)]")'
kubectl -n lab get deploy extauthz -o jsonpath='extauthz replicas={.spec.replicas} ready={.status.readyReplicas}{"\n"}'
echo "## namespaces and probe pods left"; kubectl get ns c3r repro 2>&1 | tail -2; kubectl -n lab get pods --no-headers | grep -v -E '^(worker|orchestrator|mockllm|extauthz|loadgen|replay)-' | wc -l | tr -d ' ' | sed 's/^/other pods in lab: /'
echo "## Jobs and finished pods left in lab"; kubectl -n lab get jobs --no-headers | wc -l | tr -d " " | sed "s/^/jobs: /"; kubectl -n lab get pods --no-headers | awk '{print $3}' | sort | uniq -c
echo "## the Deployments standing in lab"; kubectl -n lab get deploy
EOF2
run 92-my-walkthrough-size-after-repeat - 0 'du -sh experiments/runs/@D@ | cut -f1'
echo "repeat,$T0UTC,$(ts)" >> "$WIN"
echo "$(ts) repeat driver exit=0"

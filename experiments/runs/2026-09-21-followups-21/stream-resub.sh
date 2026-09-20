#!/usr/bin/env bash
# Follow-ups 21, readings 2 and 3: does `make ledgers` collect a resubscription's three ledgers together, and does
# its output for an existing UNARY work item stay byte-identical?
#
# Reading 2 -- the resubscription. One streamed work item against the Go receiver and one resubscription onto the
# task it created, both sent from a curl pod of this script's own, one send per request, every curl --retry 0:
#   1. the mock is armed for this work item with the committed delay-then-close mode at 8000 ms, so the Task is
#      still running when the resubscription arrives (this is B-3's shape: a second stream onto a live task, not a
#      refusal). The worker's MODEL_TIMEOUT_S is left at its default 60 s, so the model call is not cut short by
#      the receiver; the mock closes at 8 s and the Task fails after that, which is a recorded outcome, not a retry;
#   2. SendStreamingMessage is sent in the background, its SSE body captured whole;
#   3. the taskId is read from the execution ledger (the `received` line of that work item), not guessed; the
#      pod log is read line by line as raw text, because it also carries lines that are not JSON;
#   4. SubscribeToTask is sent for that taskId, with the X-Logical-Work-Item-Id header the load client sets on every
#      request -- the header the ingress ledger falls back to, and the only place the work item appears, since the
#      A2A request carries no Message and so no metadata;
#   5. the mock is reset, so this script leaves nothing armed;
#   6. `make ledgers` for the work item is taken twice, with the PARENT commit's Makefile (verbatim from its blob,
#      written to a scratch path taken from the environment) and with the branch's, and the two are counted and
#      diffed.
# Reading 3 -- the unary comparison. The same two collections for one unary work item of EACH receiver, the clean
# work items reading 1 already sent, compared byte for byte.
# Keep-awake: this script starts none and changes no power setting. No retry logic anywhere.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1
NS=lab
RUNREL=2026-09-21-followups-21
D=experiments/runs/$RUNREL
SCR="${TMPDIR%/}/fu21/proof"
POD=fu21-curl
CURL_IMAGE=curlimages/curl:8.22.0
WORKER_URL=http://worker.lab.svc.cluster.local:8080
MOCK_URL=http://mockllm.lab.svc.cluster.local:8080
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
mkdir -p "$D/stream" "$SCR"

PARENT=$(git rev-parse HEAD^)
git show "$PARENT:Makefile" > "$SCR/Makefile.parent"
echo "# follow-ups 21, readings 2 and 3. start $(ts)"
echo "# HEAD $(git rev-parse HEAD); parent $PARENT"
echo "# branch Makefile blob $(git rev-parse HEAD:Makefile)"
echo "# parent Makefile blob $(git rev-parse "$PARENT:Makefile"), written to the scratch copy this script collects with"
echo "# scratch copy sha256 $(shasum -a 256 "$SCR/Makefile.parent" | cut -d' ' -f1)"

kubectl -n "$NS" delete pod "$POD" --ignore-not-found --wait=true >/dev/null 2>&1 || true
kubectl -n "$NS" run "$POD" --image="$CURL_IMAGE" --restart=Never --command -- sleep 3600 >/dev/null
kubectl -n "$NS" wait --for=condition=Ready "pod/$POD" --timeout=60s >/dev/null
echo "# curl pod $POD ready $(ts)"

control() { # $1 = path, $2 = body
	kubectl -n "$NS" exec "$POD" -- curl -sS --retry 0 -o /dev/null -w '%{http_code}' \
		-X POST -H 'Content-Type: application/json' -d "${2:-}" "${MOCK_URL}$1"
}

LWI="fu21-stream-go-$(date +%H%M%S)"
MSGID="01a06f19-cf55-7daf-af2b-a251c81a0375"
echo "# work item: $LWI"

ARM=$(printf '{"mode":"delay-then-close","lwi":"%s","delay_ms":8000}' "$LWI")
echo "# arm the mock: $(control /control/inject "$ARM")  $(ts)"

STREAM_BODY=$(printf '{"jsonrpc":"2.0","method":"SendStreamingMessage","params":{"message":{"messageId":"%s","metadata":{"logical_work_item_id":"%s"},"parts":[{"text":"lwi:%s hello"}],"role":"ROLE_USER"}},"id":"rpc-stream-1"}' "$MSGID" "$LWI" "$LWI")
echo "# SendStreamingMessage body (whole): $STREAM_BODY"
kubectl -n "$NS" exec "$POD" -- curl -sS --retry 0 -N -D - \
	-H 'Content-Type: application/json' -H 'A2A-Version: 1.0' -H "X-Logical-Work-Item-Id: $LWI" \
	-X POST -d "$STREAM_BODY" "$WORKER_URL/" > "$D/stream/send-streaming.txt" 2>&1 &
STREAM_PID=$!
echo "# SendStreamingMessage sent in the background, pid $STREAM_PID  $(ts)"

TASKID=""
for _ in $(seq 1 40); do
	TASKID=$(kubectl -n "$NS" logs deploy/worker --tail=-1 2>/dev/null \
		| jq -R -r --arg lwi "$LWI" 'fromjson? | select(.ledger == "execution" and .logical_work_item_id == $lwi and (.taskId // "") != "") | .taskId' \
		| head -1)
	[ -n "$TASKID" ] && break
	sleep 0.25
done
echo "# taskId read from the execution ledger: ${TASKID:-(none)}  $(ts)"
if [ -z "$TASKID" ]; then echo "STOP: no taskId for $LWI; the resubscription is not sent"; control /control/reset; exit 1; fi

SUB_BODY=$(printf '{"jsonrpc":"2.0","method":"SubscribeToTask","params":{"id":"%s"},"id":"rpc-sub-1"}' "$TASKID")
echo "# SubscribeToTask body (whole): $SUB_BODY"
kubectl -n "$NS" exec "$POD" -- curl -sS --retry 0 -N -m 30 -D - \
	-H 'Content-Type: application/json' -H 'A2A-Version: 1.0' -H "X-Logical-Work-Item-Id: $LWI" \
	-X POST -d "$SUB_BODY" "$WORKER_URL/" > "$D/stream/subscribe-to-task.txt" 2>&1
echo "# SubscribeToTask returned, exit=$?  $(ts)"
wait "$STREAM_PID"
echo "# SendStreamingMessage finished, exit=$?  $(ts)"

echo "# reset the mock: $(control /control/reset)  $(ts)"
kubectl -n "$NS" delete pod "$POD" --ignore-not-found --wait=false >/dev/null 2>&1 || true

echo "===== reading 2: make ledgers for $LWI, parent Makefile then branch Makefile ====="
make -f "$SCR/Makefile.parent" --no-print-directory ledgers "LWI=$LWI" "OUT=$D/stream/parent" > "$D/stream/parent-stdout.txt" 2>"$D/stream/parent-stderr.txt"
echo "# parent collection exit=$?"
make --no-print-directory ledgers "LWI=$LWI" "OUT=$D/stream/new" > "$D/stream/new-stdout.txt" 2>"$D/stream/new-stderr.txt"
echo "# branch collection exit=$?"
for s in parent new; do
	echo "# $s: ingress $(wc -l < "$D/stream/$s/ingress.jsonl" | tr -d ' ')  execution $(wc -l < "$D/stream/$s/execution.jsonl" | tr -d ' ')  invocation $(wc -l < "$D/stream/$s/invocation.jsonl" | tr -d ' ')  client $(wc -l < "$D/stream/$s/client.jsonl" | tr -d ' ')"
	echo "#   of those, SubscribeToTask: ingress $(grep -c SubscribeToTask "$D/stream/$s/ingress.jsonl")  execution $(grep -c SubscribeToTask "$D/stream/$s/execution.jsonl")"
done
echo "# lines the branch collects that the parent does not:"
diff "$D/stream/parent-stdout.txt" "$D/stream/new-stdout.txt"
echo "# (diff exit=$?)"
echo "# the branch's execution lines for the resubscription, whole:"
grep SubscribeToTask "$D/stream/new/execution.jsonl"
echo "# the branch's ingress lines for the resubscription, whole:"
grep SubscribeToTask "$D/stream/new/ingress.jsonl"

echo "===== reading 3: the unary comparison, one work item per receiver ====="
for lwi in "$@"; do
	mkdir -p "$D/stream/unary-$lwi"
	make -f "$SCR/Makefile.parent" --no-print-directory ledgers "LWI=$lwi" > "$D/stream/unary-$lwi/parent-stdout.txt" 2>"$D/stream/unary-$lwi/parent-stderr.txt"
	pe=$?
	make --no-print-directory ledgers "LWI=$lwi" > "$D/stream/unary-$lwi/new-stdout.txt" 2>"$D/stream/unary-$lwi/new-stderr.txt"
	ne=$?
	echo "# $lwi: parent exit=$pe  branch exit=$ne  lines $(wc -l < "$D/stream/unary-$lwi/new-stdout.txt" | tr -d ' ')"
	if cmp -s "$D/stream/unary-$lwi/parent-stdout.txt" "$D/stream/unary-$lwi/new-stdout.txt"; then
		echo "#   stdout byte-identical; sha256 $(shasum -a 256 "$D/stream/unary-$lwi/new-stdout.txt" | cut -d' ' -f1)"
	else
		echo "#   stdout DIFFERS:"; diff -u "$D/stream/unary-$lwi/parent-stdout.txt" "$D/stream/unary-$lwi/new-stdout.txt"
	fi
	if cmp -s "$D/stream/unary-$lwi/parent-stderr.txt" "$D/stream/unary-$lwi/new-stderr.txt"; then
		echo "#   stderr byte-identical"
	else
		echo "#   stderr DIFFERS:"; diff -u "$D/stream/unary-$lwi/parent-stderr.txt" "$D/stream/unary-$lwi/new-stderr.txt"
	fi
done
echo "# readings 2 and 3 done $(ts)"

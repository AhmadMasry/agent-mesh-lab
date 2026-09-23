#!/usr/bin/env bash
# Experiment C, step C-8: the driver, kept in the run directory. Rows 1 and 2's sends are C-6's sends.sh, run from
# C-6's run directory with RUNREL set to this one (as C-7 did); this script applies and removes the overlays, reads
# every layer, sends rows 3 and 4's curl probes, and records host power events over the task's own window.
#
#   c8.sh apply <overlay> | remove <overlay>     kubectl apply -k / delete -k overlay-c8-deny or overlay-c8-require
#   c8.sh read <label> <since>                   readings, each through rec, into readings-<label>.txt
#   c8.sh probe <phase> <kind> <recv> <n>        ONE curl POST from sends.sh's curl pod (c6-curl) to the ingress Service,
#                                                with Host worker.lab.internal for go (route lab/worker-ingress) and the
#                                                ingress's own host for py (route lab/orchestrator-ingress), the same
#                                                target and headers as sends.sh's cst:
#       pad    a SubscribeToTask whose object carries one more top-level member, x_pad, a run of the letter a, so that
#              the body is PAD_LEN bytes, past maxBufferSize (2097152 by default; the lab sets none)
#       padt   the same SubscribeToTask with the pad in params.tenant instead, the one field besides id that the
#              specification gives SubscribeToTaskRequest (a2a.proto at 3303592, l.748-754: "Optional. Opaque routing
#              identifier."), so that the body is PAD_LEN bytes (added after the controller's ruling of 2026-09-23)
#       batch  a JSON-RPC batch: an array holding one SubscribeToTask request
#       dup    one object with the method key written twice, SendMessage first and SubscribeToTask second, and the
#              params a SubscribeToTask takes
#   c8.sh sleep <from> <to>                      host power events of four kinds in the window, counts and stamps only
# Every request carries A2A-Version: 1.0, X-Logical-Work-Item-Id and a traceparent whose trace id is recorded. One
# curl per call, --retry 0, --max-time 30, never re-sent; the ledgers are collected at once by make ledgers.
# No retry logic anywhere. Keep-awake: this script starts none and changes no power setting.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1
PATH="${TMPDIR%/}/c5/tools/istioctl-1.31.0:$PATH"
export PATH
RUNREL="${RUNREL:?RUNREL, the run directory name, is required}"
D="experiments/runs/$RUNREL"
NS=lab
POD=c6-curl
INGRESS=http://agentgateway-ingress.agentgateway-ingress.svc.cluster.local
PAD_LEN=2200000
ts() { date -u +%FT%TZ; }
tsn() { perl -MTime::HiRes=time -MPOSIX=strftime -e '$t=time; printf "%s.%06dZ\n", strftime("%Y-%m-%dT%H:%M:%S", gmtime($t)), ($t-int($t))*1e6'; }
rec() {
	local f="$1"; shift
	{ printf '\n# read %s\n$ %s\n' "$(ts)" "$*"; bash -c "$*" 2>&1; printf '# exit %s\n' "$?"; } >> "$f"
}
dump() { # dump <ns> <deploy> <out> <port>
	kubectl -n "$1" port-forward "deploy/$2" "$4:15000" >/dev/null 2>&1 &
	local pf=$!
	for _ in $(seq 1 40); do nc -z 127.0.0.1 "$4" 2>/dev/null && break; perl -e 'select(undef,undef,undef,0.25)'; done
	curl -sS --retry 0 --max-time 10 "http://127.0.0.1:$4/config_dump" -o "$3"
	kill "$pf" 2>/dev/null || true
}

cmd="${1:-}"; shift || true
case "$cmd" in
apply | remove)
	ov="${1:?overlay}"
	case "$ov" in overlay-c8-deny | overlay-c8-require | overlay-c8-require-scoped) ;; *) echo "overlay $ov" >&2; exit 1 ;; esac
	verb=apply; [ "$cmd" = remove ] && verb=delete
	echo "$(ts) $verb -k $ov" | tee -a "$D/phases.txt"
	rec "$D/$cmd-$ov.txt" "kubectl $verb -k $D/$ov"
	echo "$(ts) $verb done" | tee -a "$D/phases.txt"
	;;
read)
	label="${1:?label}"; since="${2:?since}"
	f="$D/readings-$label.txt"
	rec "$f" "kubectl get agentgatewaypolicy -A -o yaml"
	rec "$f" "kubectl get agentgatewaypolicy -A -o json | jq -r '.items[] | \"\\(.metadata.namespace)/\\(.metadata.name) authorization=\\(.spec.traffic.authorization != null) ancestors=\\([.status.ancestors[]? | .conditions[]? | \"\\(.type)=\\(.status)/\\(.reason)\"] | join(\",\"))\"'"
	rec "$f" "kubectl get authorizationpolicy -A --no-headers | wc -l"
	rec "$f" "kubectl get httproute -A -o json | jq '[.items[].spec.rules[]? | select(.retry != null)] | length'"
	rec "$f" "kubectl -n agentgateway-system logs deploy/agentgateway --since-time=$since"
	rec "$f" "kubectl -n agentgateway-ingress logs deploy/agentgateway-ingress --since-time=$since | grep -v 'request gateway='"
	rec "$f" "kubectl -n agentgateway-waypoint logs deploy/agw-central --since-time=$since | grep -v 'request gateway='"
	dump agentgateway-ingress agentgateway-ingress "$D/config-dump-ingress-$label.json" 15997
	dump agentgateway-waypoint agw-central "$D/config-dump-agw-central-$label.json" 15996
	for p in ingress agw-central; do
		rec "$f" "jq -r '(.policies // []) | length as \$n | \"$p policies: \\(\$n)\", (.[] | \"  key=\\(.key) name=\\(.name|tostring) target=\\(.target|tostring|.[0:200]) kinds=\\(.policy|tostring|.[0:240])\")' $D/config-dump-$p-$label.json"
		rec "$f" "jq -r '[.. | objects | select(has(\"maxBufferSize\")) | .maxBufferSize] | \"$p maxBufferSize values in the dump: \\(length) \\(.)\"' $D/config-dump-$p-$label.json"
		rec "$f" "wc -c < $D/config-dump-$p-$label.json; shasum -a 256 $D/config-dump-$p-$label.json"
	done
	echo "$(ts) read $label -> $f" | tee -a "$D/phases.txt"
	;;
probe)
	PHASE="${1:?phase}" KIND="${2:?kind}" RECV="${3:?recv}" N="${4:?n}"
	case "$KIND" in pad | padt | batch | dup) ;; *) echo "kind $KIND" >&2; exit 1 ;; esac
	case "$RECV" in go) HOSTH=(-H 'Host: worker.lab.internal') ;; py) HOSTH=() ;; *) echo "recv $RECV" >&2; exit 1 ;; esac
	LWI="${PHASE}-${RECV}-${KIND}-${RUN_ID:?RUN_ID}-${N}"
	W="$D/$PHASE/$LWI"
	mkdir -p "$W"
	since=$(tsn)
	echo "$since send $LWI phase=$PHASE kind=$KIND recv=$RECV" > "$W/steps.txt"
	TASK="no-such-task-$LWI"
	TRACE_ID=$(openssl rand -hex 16); SPAN=$(openssl rand -hex 8); RPC_ID=$(uuidgen | tr 'A-Z' 'a-z')
	B="${TMPDIR%/}/c8/body-$LWI.json"
	case "$KIND" in
	pad)
		head=$(printf '{"jsonrpc":"2.0","method":"SubscribeToTask","params":{"id":"%s"},"id":"%s","x_pad":"' "$TASK" "$RPC_ID")
		fill=$((PAD_LEN - ${#head} - 2))
		{ printf '%s' "$head"; head -c "$fill" /dev/zero | tr '\0' 'a'; printf '"}'; } > "$B"
		;;
	padt)
		head=$(printf '{"jsonrpc":"2.0","method":"SubscribeToTask","id":"%s","params":{"id":"%s","tenant":"' "$RPC_ID" "$TASK")
		fill=$((PAD_LEN - ${#head} - 3))
		{ printf '%s' "$head"; head -c "$fill" /dev/zero | tr '\0' 'a'; printf '"}}'; } > "$B"
		;;
	batch)
		printf '[{"jsonrpc":"2.0","method":"SubscribeToTask","params":{"id":"%s"},"id":"%s"}]' "$TASK" "$RPC_ID" > "$B"
		;;
	dup)
		printf '{"jsonrpc":"2.0","method":"SendMessage","method":"SubscribeToTask","params":{"id":"%s"},"id":"%s"}' "$TASK" "$RPC_ID" > "$B"
		;;
	esac
	blen=$(wc -c < "$B" | tr -d ' '); bsha=$(shasum -a 256 "$B" | cut -d' ' -f1)
	if [ "$KIND" = pad ] || [ "$KIND" = padt ]; then
		# The padded body is not kept (2.2 MB): its first 200 bytes, its last 40, its length and hash are.
		head -c 200 "$B" > "$W/request-head.txt"; tail -c 40 "$B" > "$W/request-tail.txt"
	else
		cp "$B" "$W/request.json"
	fi
	s=$(tsn)
	out=$(kubectl -n "$NS" exec -i "$POD" -- curl -sS -i -v --retry 0 --max-time 30 -X POST ${HOSTH[@]+"${HOSTH[@]}"} \
		-H 'Content-Type: application/json' -H 'A2A-Version: 1.0' -H "X-Logical-Work-Item-Id: $LWI" \
		-H "traceparent: 00-${TRACE_ID}-${SPAN}-01" -w '\n__STATUS__%{http_code}' --data-binary @- "$INGRESS/" < "$B" 2> "$W/curl-stderr.txt")
	rc=$?
	e=$(tsn)
	rm -f "$B"
	code=$(printf '%s\n' "$out" | sed -n 's/^__STATUS__//p' | tail -1)
	printf '%s\n' "$out" | sed '/^__STATUS__/d' > "$W/response.txt"
	grep '^> ' "$W/curl-stderr.txt" > "$W/request-headers-as-sent.txt" || true
	jq -cn --arg ts "$s" --arg te "$e" --arg lwi "$LWI" --arg phase "$PHASE" --arg recv "$RECV" --arg kind "$KIND" --arg url "$INGRESS/" \
		--arg code "$code" --argjson rc "$rc" --arg trace "$TRACE_ID" --arg id "$RPC_ID" --arg task "$TASK" \
		--argjson blen "$blen" --arg bsha "$bsha" --arg head "$(head -c 300 "$W/response.txt" | tr '\r\n' '  ')" \
		'{ledger:"client",client:"curl",ts:$ts,ts_end:$te,logical_work_item_id:$lwi,phase:$phase,receiver:$recv,kind:$kind,
		  url:$url,attempt:1,http_status:$code,exit_code:$rc,trace_id:$trace,id:$id,taskId_asked:$task,body_len:$blen,
		  body_sha256:$bsha,response_head:$head}' > "$W/client.jsonl"
	echo "$(tsn) curl http=$code exit=$rc body_len=$blen" >> "$W/steps.txt"
	sleep 2
	kubectl -n agentgateway-ingress logs deploy/agentgateway-ingress --since-time="$since" 2>/dev/null > "$W/ingress-log-window.txt" || true
	grep 'request gateway=' "$W/ingress-log-window.txt" > "$W/ingress-access.txt" || true
	kubectl -n agentgateway-waypoint logs deploy/agw-central --since-time="$since" 2>/dev/null | grep 'request gateway=' > "$W/agw-central-access.txt" || true
	lr=0
	make --no-print-directory ledgers "LWI=$LWI" "OUT=$W" > /dev/null 2> "$W/ledgers-stderr.txt" || lr=$?
	echo "$(tsn) make ledgers exit=$lr" >> "$W/steps.txt"
	st_ing=$(awk -F'http.status=' 'NF>1{split($2,a," "); printf "%s ", a[1]}' "$W/ingress-access.txt")
	cnt() { if [ -f "$1" ]; then wc -l < "$1" | tr -d ' '; else echo 0; fi; }
	echo "$(ts) $PHASE $RECV $KIND $LWI http=$code exit=$rc body_len=$blen ledgers-exit=$lr ingress-ledger=$(cnt "$W/ingress.jsonl") execution=$(cnt "$W/execution.jsonl") invocation=$(cnt "$W/invocation.jsonl") ingress-proxy-status=[${st_ing% }]" | tee -a "$D/phases.txt"
	;;
sleep)
	from="${1:?from}"; to="${2:?to}"
	out="$D/sleep-events.csv"
	{
		printf '# kind,utc -- host power events of the four kinds, from pmset -g log, read %s.\n' "$(ts)"
		printf '# The stamp is pmset own local stamp converted with the offset pmset printed beside it. No line text is kept.\n'
		printf '# Bounded to this task own window, %s .. %s.\n' "$from" "$to"
		printf 'kind,utc\n'
		pmset -g log | FROM="$from" TO="$to" perl -ne '
			next unless /^(\d{4})-(\d\d)-(\d\d) (\d\d):(\d\d):(\d\d) ([+-])(\d\d)(\d\d) (Sleep|Wake|DarkWake|Maintenance) +\t/;
			use Time::Local; my $t = timegm($6,$5,$4,$3,$2-1,$1) - ($7 eq "+" ? 1 : -1) * ($8*3600 + $9*60);
			my @g = gmtime($t); my $u = sprintf("%04d-%02d-%02dT%02d:%02d:%02dZ", $g[5]+1900,$g[4]+1,$g[3],$g[2],$g[1],$g[0]);
			print "$10,$u\n" if $u ge $ENV{FROM} && $u le $ENV{TO};'
	} > "$out"
	echo "$(ts) sleep events $from..$to: $(($(wc -l < "$out") - 4))" | tee -a "$D/phases.txt"
	;;
*)
	echo "usage: c8.sh apply|remove <overlay> | read <label> <since> | probe <phase> <kind> <recv> <n> | sleep <from> <to>" >&2; exit 1 ;;
esac

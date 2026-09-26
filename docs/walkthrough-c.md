# Walkthrough C — Experiment C, every row

Experiment C asks what each layer on this topology can **see** and **enforce** of an A2A operation: ztunnel with
istiod's L4 policy, the Gateway API routes on the two agentgateway proxies, agentgateway's own CEL policy on headers,
identity and the request body, an external authorizer, and the application itself, each put to the same rule, one
operation refused (`SubscribeToTask`) and another allowed (`SendMessage`) on one endpoint, on JSON-RPC and then on REST
and gRPC. It was measured in the order the author's notes of 2026-09-20, 2026-09-23, 2026-09-24 and 2026-09-25 set, and
this document re-takes every row on the cluster [`walkthrough-b.md`](walkthrough-b.md) leaves standing, each with its
committed driver, at **two repetitions per probe** where the entries ran three to ten (one where the entry ran one),
reading each against the entry that recorded it, by heading. The two rows whose configuration is not standing, C-9's
A2A marking and D-5's A2A backend type, come last and are applied from a run directory, counted, removed, and followed
by the clean check, as the D-5 entries did. Nothing here adds a finding.

Everything printed here was taken from the run of 2026-09-26 at the tree of the commit `docs(proposal-notes): the
walkthrough extended to every row of Experiments B and C for the author's end-to-end test, decided by the author`; this
part ran from 15:13:38Z to 17:05:15Z, **1 h 51 min 37 s**, then one step appended at 17:06:01Z to 17:10:15Z and one
more at 17:24:12Z to 17:25:00Z, both said where they belong below. The record is
`experiments/runs/2026-09-26-walkthrough/` (the C steps are `logs/50-*` to `logs/95-*`); the main walkthrough's rules
apply unchanged, and the comparison with the entries is its `rows-vs-entries.txt` (one CSV line per send or probe) and
`readings-vs-entries.txt` (the rows whose committed tool prints text).

**How the output blocks are cut.** Each block quotes the counting tool's cells for what the entry rests on and names
the log or file it comes from; the per-send lines, the readings each driver takes of the routes, policies and dumps, and
the timing figures are left to the record. A block that quotes lines whole says nothing more; a block that condenses
them starts with a line `# condensed:` naming what it does, which is one or more of: several cells joined on one line
with ` ; ` or ` -> `, a line cut at ` ... ` where the rest of it says nothing the entry rests on, cells or rows left out
and named, and a pod address or a task id that differs between repetitions written `<pod>` or `<task id>`. Every value
in a condensed line is the tool's; the unabridged output is in the file the block names.

## Before you start (C)

**Tools.** Beside the B drivers' tools, the C drivers use `yq` (v4, the Go one), `nc`, `lsof`, `bc`, `iconv`,
`openssl`, `uuidgen`, `docker` (C-3R2 removes its pulled image from the kind node with `docker exec ... crictl rmi`),
and, in C-3R and C-3R2 only, `gdate`, GNU date under the name Homebrew gives it on macOS. On Linux `date` is GNU date
already; give it that name in the tools directory the main walkthrough set up, `ln -s "$(command -v date)"
"${TMPDIR:-/tmp}/agent-mesh-lab-tools/gdate"`, and nothing else changes. `TMPDIR` must be set, as for B.

**The scratch directories the drivers write into without creating them, and the copies.** Five committed drivers name
their own dated run directory in one line; the reader runs a copy with that line changed, as the currency pass did by
ruling on 2026-09-25, and the `diff` after each copy shows the one line. C-3R's server object names the worker image of
the day it was written, which no rebuilt cluster holds, so its copy takes today's from the Deployment. The block is
this run's `logs/50-c-prerequisites.txt`:

```
mkdir -p "${TMPDIR:-/tmp}"/c5/ko-build-my-walkthrough "${TMPDIR:-/tmp}"/d2/ko-build-my-walkthrough "${TMPDIR:-/tmp}"/d3 "${TMPDIR:-/tmp}"/d3b "${TMPDIR:-/tmp}"/c8 "${TMPDIR:-/tmp}"/c9
mkdir -p experiments/runs/my-walkthrough/drivers experiments/runs/my-walkthrough/c3c4 experiments/runs/my-walkthrough/c3r experiments/runs/my-walkthrough/c3r2
for f in send-one.sh counts.sh proxy-spans.sh; do
  sed -e 's#^R="experiments/runs/2026-09-21-c3-c4-ztunnel"$#R="experiments/runs/my-walkthrough/c3c4"#' \
    experiments/runs/2026-09-21-c3-c4-ztunnel/$f > experiments/runs/my-walkthrough/drivers/c3c4-$f
done
sed -e 's#^R="experiments/runs/2026-09-21-c3r-open-connections"$#R="experiments/runs/my-walkthrough/c3r"#' \
  experiments/runs/2026-09-21-c3r-open-connections/rep.sh > experiments/runs/my-walkthrough/drivers/c3r-rep.sh
sed -e 's#^R="experiments/runs/2026-09-21-c3r2-public-server"$#R="experiments/runs/my-walkthrough/c3r2"#' \
  experiments/runs/2026-09-21-c3r2-public-server/rep.sh > experiments/runs/my-walkthrough/drivers/c3r2-rep.sh
for f in send-one.sh counts.sh proxy-spans.sh; do diff experiments/runs/2026-09-21-c3-c4-ztunnel/$f experiments/runs/my-walkthrough/drivers/c3c4-$f; done
diff experiments/runs/2026-09-21-c3r-open-connections/rep.sh experiments/runs/my-walkthrough/drivers/c3r-rep.sh
diff experiments/runs/2026-09-21-c3r2-public-server/rep.sh experiments/runs/my-walkthrough/drivers/c3r2-rep.sh
cp -R experiments/runs/2026-09-21-c3-c4-ztunnel/overlay-c3 experiments/runs/2026-09-21-c3-c4-ztunnel/overlay-c4 experiments/runs/2026-09-21-c3-c4-ztunnel/rec.sh experiments/runs/my-walkthrough/c3c4/
cp -R experiments/runs/2026-09-21-c3r-open-connections/objects experiments/runs/2026-09-21-c3r-open-connections/rec.sh experiments/runs/2026-09-21-c3r-open-connections/responses.py experiments/runs/2026-09-21-c3r-open-connections/counts.py experiments/runs/my-walkthrough/c3r/
WORKER_IMAGE=$(kubectl -n lab get deploy worker -o jsonpath='{.spec.template.spec.containers[0].image}')
sed -e "s#^\(          image: \).*#\1$WORKER_IMAGE#" experiments/runs/2026-09-21-c3r-open-connections/objects/server.yaml > experiments/runs/my-walkthrough/c3r/objects/server.yaml
diff experiments/runs/2026-09-21-c3r-open-connections/objects/server.yaml experiments/runs/my-walkthrough/c3r/objects/server.yaml
cp -R experiments/runs/2026-09-21-c3r2-public-server/objects experiments/runs/2026-09-21-c3r2-public-server/rec.sh experiments/runs/2026-09-21-c3r2-public-server/responses.py experiments/runs/2026-09-21-c3r2-public-server/counts.py experiments/runs/my-walkthrough/c3r2/
```

```
# condensed: the last diff's image digest written as a placeholder (this run's is in logs/50-c-prerequisites.txt)
20c20
< R="experiments/runs/2026-09-21-c3-c4-ztunnel"
---
> R="experiments/runs/my-walkthrough/c3c4"
13c13
< R="experiments/runs/2026-09-21-c3-c4-ztunnel"
---
> R="experiments/runs/my-walkthrough/c3c4"
6c6
< R="experiments/runs/2026-09-21-c3-c4-ztunnel"
---
> R="experiments/runs/my-walkthrough/c3c4"
41c41
< R="experiments/runs/2026-09-21-c3r-open-connections"
---
> R="experiments/runs/my-walkthrough/c3r"
50c50
< R="experiments/runs/2026-09-21-c3r2-public-server"
---
> R="experiments/runs/my-walkthrough/c3r2"
40c40
<           image: kind.local/worker-918a018b7a581926ead34dec2ba0fb83:64e86fdffd5ef6c996132d6b64a7005fb1afcafb685ff75861b34313ff9851b4
---
>           image: kind.local/worker-918a018b7a581926ead34dec2ba0fb83:<the digest your step 1 built>
```

Every other C driver takes `RUNREL` (and, where it sends through the load client, an `IMAGE` its own `image`
sub-command builds once) and runs unedited from its record. Two more copies are made where they are needed below: D-3b's
`batch-by-hash.sh`, and D-3's `counts.py` for the one step appended at the end.

## C-1 — the observation: what each layer recorded of one clean `SendMessage`

```
S=$(date -u +%FT%TZ)
RUN_ID=wtc1 RUN_ITEM=my-walkthrough/c1 experiments/gate2-single-clean.sh
for w in worker orchestrator; do make export-trace LWI=g2c-wtc1-$w OUT=experiments/runs/my-walkthrough/c1/g2c-wtc1-$w; done
echo "$S" > experiments/runs/my-walkthrough/c1/window-start.txt
```

**47.9 s.** One clean `SendMessage` per receiver by the committed clean check, then each work item's trace exported.
The entry read every layer afterwards, read-only; its readings had no driver, so the block below is those reads as
commands (`logs/51b-c1-layers.txt`; the block is long and is the reader's own copy of that log's first line):

```
# condensed: this block stands for the 41-line read block of logs/51b-c1-layers.txt, whose first line is the reader's copy
C=experiments/runs/my-walkthrough/c1; S=$(cat $C/window-start.txt)
# the routes, the Services' appProtocol, both proxies' /config_dump and the strings a2a, authorization, jwt, extAuth,
# rateLimit in each, every policy object, both proxies' request lines of the window, every attribute on every proxy
# SERVER span of the two traces, ztunnel's lines of the window, its connection lines to the agents, the
# connection-security series, and the three ledgers: the full block is logs/51b-c1-layers.txt in the record.
```

What it read, against `## Experiment C / both receivers / observation`:

```
# condensed: the five route JSON lines summarised in angle brackets; the policy lines cut to their kind; span lines grouped with a count
## the routes, as they stand
<5 HTTPRoutes: agentgateway-waypoint/model-via-agw, lab/orchestrator, lab/orchestrator-ingress, lab/worker, lab/worker-ingress, each one PathPrefix / rule, no filters, no retry>
worker: name=http port=8080 appProtocol=<none>; name=grpc port=8081 appProtocol=kubernetes.io/h2c
orchestrator: name=http port=8080 appProtocol=<none>; name=grpc port=8081 appProtocol=kubernetes.io/h2c
mockllm: name=http port=8080 appProtocol=<none>
## every policy each proxy holds, and the strings a2a, authorization, jwt, extAuth, rateLimit in its config_dump
policies: 2   (agw-central: access-logs, tracing)
agw-central "a2a"=0 agw-central "authorization"=0 agw-central "jwt"=0 agw-central "extAuth"=0 agw-central "rateLimit"=0
policies: 2   (agentgateway-ingress: access-logs, tracing)
agentgateway-ingress "a2a"=0 agentgateway-ingress "authorization"=0 agentgateway-ingress "jwt"=0 agentgateway-ingress "extAuth"=0 agentgateway-ingress "rateLimit"=0
AgentgatewayPolicy objects: 4
AuthorizationPolicy objects: 0
## both proxies' request lines of the window
agw-central request lines: 13, carrying src.identity: 13; distinct path/method pairs on route=lab/worker: 3
ingress request lines: 1, carrying src.identity: 0
## every attribute on every proxy SERVER span of the two work items
worker agw-central POST /* attrs=17 src.identity=1 a2a_keys=0 protocol=http          (3 agw-central spans on the worker item: two POSTs and a GET)
orchestrator agentgateway-ingress POST /* attrs=16 src.identity=0 a2a_keys=0 protocol=http
orchestrator agw-central GET /* attrs=17 src.identity=1 a2a_keys=0 protocol=http    (4 agw-central spans on the orchestrator item)
## ztunnel, the node that runs every lab pod: what its lines carry
lines in the window: 54
lines naming messageId    0
lines naming taskId       0
lines naming SendMessage  0
lines naming http.method  0
lines naming http.path    0
lines naming agent-card   0
lines naming the work item g2c-wtc1: 18; of them outside a src.workload= or dst.workload= token: 12
## the ledgers: what the application recorded before the SDK
worker method=SendMessage a2a_version=1.0 remote=<agw-central's pod>:<port> messageId=... taskId=[] body_sha256=... keys=a2a_version,body_len,body_sha256,content_type,id,ledger,logical_work_item_id,messageId,method,phase,remote,source,taskId,ts_arrival
worker method=SendMessage a2a_version=1.0 remote=<agw-central's pod>:<port> ...
orchestrator method=SendMessage a2a_version=1.0 remote=<the ingress's pod>:<port> ...
worker execute taskId=...   worker execute taskId=...   orchestrator execute taskId=...
invocation caller=worker lwi=g2c-wtc1-worker ...   invocation caller=worker lwi=g2c-wtc1-orchestrator ...
```

Cell by cell against the entry's `layer-counts.csv`: the route layer, 5 HTTPRoutes with one PathPrefix `/` rule each,
0 header, query or method matches, 0 filters, 0 retry stanzas, as there; the policy layer, 2 policies per proxy
(access logs and tracing), 0 authorization fields, 0 `AuthorizationPolicy` objects, 0 occurrences of `a2a` in either
dump, as there; the telemetry layer, `src.identity` on 13 of 13 `agw-central` request lines and on 7 of 7 of its SERVER
spans (17 attributes each), none on the ingress's 1 line and 1 span (16 attributes, the same set without
`src.identity`), 0 `a2a.` attribute keys, `protocol=http` on 8 of 8, 3 distinct path/method pairs on `route=lab/worker`,
as there; the application layer, 3 arrivals on the path (1 at the worker item, 2 on the orchestrator item's forward),
each with `method=SendMessage`, `a2a_version=1.0`, a `messageId` and an empty `taskId`, a `remote` that is the
delivering proxy's pod, no identity or caller field among the fourteen keys, 3 executes minting 3 tasks, 2 model
invocations each naming its work item, `messageId` and `taskId`, as there; ztunnel, 0 lines carrying a `messageId`, a
`taskId`, `SendMessage`, `http.method`, `http.path` or `agent-card` among the window's 54, as there. One cell changed
since the entry for a recorded reason: the agent Services now carry a second port, `grpc` 8081 with
`appProtocol: kubernetes.io/h2c`, the D-2 bindings of 2026-09-24, while the `http` port carries none, as there.

Two of the block's reads were written wrong in this run and are corrected here over the saved files, which the record
keeps as `logs/51c-c1-reads-over-the-saved-files.txt`: the connection-security series lines end in ` => <value>` after
their JSON object, so the block's `jq` stopped after one line; and the count of ztunnel lines naming the work item
outside a workload token stripped the two `*.workload=` tokens but not the pod-lifecycle tokens `name=` and `wl=`, so it
read 12 where the entry's cell counts lines outside a workload **or pod** token. Over the saved files:

```
C=experiments/runs/my-walkthrough/c1
sed 's/ => .*//' $C/ztunnel-series.txt | grep -E '"destination_workload": "(worker|orchestrator)"' | jq -r '[.reporter, .connection_security_policy, .source_workload, .source_principal, .destination_workload] | @tsv' | sort | uniq -c
echo "lines naming g2c-wtc1: $(grep -c 'g2c-wtc1' $C/ztunnel-window.txt); outside src.workload=, dst.workload=, name= and wl= tokens: $(grep 'g2c-wtc1' $C/ztunnel-window.txt | sed 's/src.workload="[^"]*"//; s/dst.workload="[^"]*"//; s/name="[^"]*"//; s/wl=[^ }]*//' | grep -c 'g2c-wtc1')"
grep 'connection complete' $C/ztunnel-window.txt | grep -o 'direction="[a-z]*"\|dst.workload="[^"]*"' | paste - - | sed 's/-[0-9a-f]*-[0-9a-z]*"/"/' | sort | uniq -c
```

```
# condensed: the four proxy-to-agent series lines whole, the other series summarised in one parenthesis
   1 destination	mutual_tls	agentgateway-ingress	spiffe://cluster.local/ns/agentgateway-ingress/sa/agentgateway-ingress	orchestrator
   1 destination	mutual_tls	agentgateway-ingress	spiffe://cluster.local/ns/agentgateway-ingress/sa/agentgateway-ingress	worker
   1 destination	mutual_tls	agw-central	spiffe://cluster.local/ns/agentgateway-waypoint/sa/agw-central	orchestrator
   1 destination	mutual_tls	agw-central	spiffe://cluster.local/ns/agentgateway-waypoint/sa/agw-central	worker
   (the load clients' and the control pod's own legs to the orchestrator follow, mutual_tls, and the step-2 plaintext probe's two legs, unknown)
lines naming g2c-wtc1: 18; outside src.workload=, dst.workload=, name= and wl= tokens: 0
   4 dst.workload="agentgateway-ingress"	direction="inbound"
   1 dst.workload="agentgateway-ingress"	direction="outbound"
   8 dst.workload="agw-central"	direction="outbound"
   3 dst.workload="mockllm"	direction="outbound"
   2 dst.workload="otel-collector"	direction="outbound"
```

So every proxy-to-agent leg reads `mutual_tls` by the destination's ztunnel with the proxy's own identity as source, 4
of 4 here (the entry had 3 of 3; the fourth, the ingress to the worker, exists since B's rows reached the Go receiver
through the ingress), and 0 of 18 lines name the work item outside a workload or pod token, as the entry's cell. One
cell cannot be re-read on a cluster that has run B: the entry counted the proxy-to-agent legs from ztunnel's own
`connection complete` lines in its window, and here no such inbound line to either agent falls in the window, because
the proxies' HBONE connections to the agents were opened by B's rows and stay pooled; the series carry the reading
instead.

## C-3 and C-4 — ztunnel's ALLOW on the worker, and the same policy given an HTTP rule

```
C=experiments/runs/my-walkthrough/c3c4; REC=$C/rec.sh; SO=experiments/runs/my-walkthrough/drivers/c3c4-send-one.sh
node=agent-mesh-lab-worker
bash $REC $C/start-state.txt "kubectl get authorizationpolicy -A; kubectl get peerauthentication -A; kubectl get httproute -A -o json | jq '[.items[].spec.rules[]? | select(.retry != null)] | length'"
bash $SO p0-nopolicy direct c34-p0-direct
bash $SO p0-nopolicy ingress c34-p0-ingress
A=$(date -u +%FT%TZ)
bash $REC $C/c3-policy.txt "kubectl apply -k $C/overlay-c3"
for i in $(seq 1 60); do n=$(istioctl ztunnel-config policy --node $node -o json 2>/dev/null | jq '[.[] | select(.name=="require-agw-central")] | length'); [ "${n:-0}" -ge 1 ] && { echo "ztunnel holds the policy after ${i}s"; break; }; sleep 1; done
bash $REC $C/c3-policy.txt "kubectl get authorizationpolicy -A"
bash $REC $C/c3-policy.txt "istioctl ztunnel-config policy --node $node -o json"
bash $REC $C/c3-policy.txt "kubectl -n lab get authorizationpolicy require-agw-central -o yaml"
RUN_ID=c3 RUN_ITEM=my-walkthrough/c3c4 experiments/gate2-single-clean.sh
bash $SO c3-l4 direct c34-c3-direct || echo "send-one exit=$? (a refused send leaves no ledger line, and make ledgers exits 1)"
bash $SO c3-l4 ingress c34-c3-ingress || echo "send-one exit=$?"
bash $REC $C/c3-istiod.txt "kubectl -n istio-system logs deploy/istiod --since-time=$A"
bash $REC $C/c3-ztunnel.txt "kubectl -n istio-system get pods -l app=ztunnel -o wide"
ZT=$(kubectl -n istio-system get pod -l app=ztunnel --field-selector spec.nodeName=$node -o jsonpath='{.items[0].metadata.name}')
bash $REC $C/c3-ztunnel.txt "kubectl -n istio-system logs $ZT --since-time=$A"
bash $REC $C/c3-ztunnel-connections.txt "istioctl ztunnel-config connections --node $node -o json"
bash $REC $C/c3-proxies.txt "kubectl -n agentgateway-waypoint logs deploy/agw-central --since-time=$A | grep 'route=lab/worker'"
bash $REC $C/c3-proxies.txt "kubectl -n agentgateway-ingress logs deploy/agentgateway-ingress --since-time=$A | grep 'route=lab/worker-ingress'"
WIP=$(kubectl -n lab get pod -l app=worker -o jsonpath='{.items[0].status.podIP}')
closed=""
for i in $(seq 1 300); do
  l=$(kubectl -n istio-system logs "$ZT" --since-time=$A | grep 'connection complete' | grep 'src.workload="agentgateway-ingress-' | grep "$WIP:8080" | head -1)
  [ -n "$l" ] && { closed=$i; echo "closed after ${i}s: $l"; break; }
  sleep 1
done
[ -n "$closed" ] || echo "the held connection's close line was NOT observed within 300 s; sending anyway"
bash $SO c3-l4 ingress c34-c3-ingress-2 || echo "send-one exit=$?"
B=$(date -u +%FT%TZ)
bash $REC $C/c4-policy.txt "kubectl apply -k $C/overlay-c4"
for i in $(seq 1 60); do g=$(kubectl -n lab get authorizationpolicy require-agw-central -o jsonpath='{.status.conditions[0].observedGeneration}' 2>/dev/null); [ "$g" = 2 ] && { echo "observedGeneration=2 after ${i}s"; break; }; sleep 1; done
bash $REC $C/c4-policy.txt "kubectl -n lab get authorizationpolicy require-agw-central -o yaml"
bash $REC $C/c4-policy.txt "istioctl ztunnel-config policy --node $node -o json | jq '.[] | select(.name==\"require-agw-central\")'"
bash $SO c4-l7rule service c34-c4-service || echo "send-one exit=$?"
bash $SO c4-l7rule direct c34-c4-direct || echo "send-one exit=$?"
bash $SO c4-l7rule ingress c34-c4-ingress || echo "send-one exit=$?"
bash $REC $C/c4-istiod.txt "kubectl -n istio-system logs deploy/istiod --since-time=$B"
bash $REC $C/c4-ztunnel.txt "kubectl -n istio-system logs $ZT --since-time=$B"
bash $REC $C/c4-proxies.txt "kubectl -n agentgateway-waypoint logs deploy/agw-central --since-time=$B | grep 'route=lab/worker'"
bash $REC $C/c4-proxies.txt "kubectl -n agentgateway-ingress logs deploy/agentgateway-ingress --since-time=$B | grep 'route=lab/worker-ingress'"
bash $REC $C/removal.txt "kubectl delete -k $C/overlay-c4"
for i in $(seq 1 60); do n=$(istioctl ztunnel-config policy --node $node -o json 2>/dev/null | jq '[.[] | select(.name=="require-agw-central")] | length'); [ "${n:-0}" = 0 ] && { echo "ztunnel dropped the policy after ${i}s"; break; }; sleep 1; done
bash $REC $C/removal.txt "kubectl get authorizationpolicy -A"
bash $REC $C/removal.txt "istioctl ztunnel-config policy --node $node -o json | jq -c '.[] | {name,namespace,action}'"
bash $REC $C/removal.txt "kubectl get peerauthentication -A"
bash $REC $C/removal.txt "kubectl get httproute -A -o json | jq '[.items[].spec.rules[]? | select(.retry != null)] | length'"
bash $SO after-removal direct c34-after-direct
bash $SO after-removal ingress c34-after-ingress
RUN_ID=c34after RUN_ITEM=my-walkthrough/c3c4/after experiments/gate2-single-clean.sh
bash experiments/runs/my-walkthrough/drivers/c3c4-counts.sh > $C/counts.csv && cat $C/counts.csv
bash experiments/runs/my-walkthrough/drivers/c3c4-proxy-spans.sh | tee $C/proxy-spans.txt
```

**311.2 s.** The block is the entry's own sequence: two controls with no policy; the waypoint page's ALLOW on the worker
(only `agw-central`'s identity may connect), read at the API server, at istiod and in ztunnel, then one send by each of
three paths (direct to the worker's pod, through the ingress, through `agw-central` by the clean check); a second
ingress send after ztunnel has closed the held ingress-to-worker connection, which the entry waited for on ztunnel's own
close line (about 12 min there) and this block waits for the same way, bounded at 300 s; then the same policy given
`to.operation.methods: GET` (C-4); then the removal and two controls. The counts (`c3c4/counts.csv`):

```
# condensed: the remote_of_send addresses written as the pod they are, in angle brackets; the rows in the entry's order
work_item,phase,via,get,post,send_arrivals,received,executes,tasks,invocations,remote_of_send
c34-p0-direct,p0-nopolicy,direct,200/exit0,200/exit0,1,1,1,1,1,<the curl pod>
c34-p0-ingress,p0-nopolicy,ingress,200/exit0,200/exit0,1,1,1,1,1,<the ingress pod>
g2c-c3-worker,c3-l4,service-loadgen,loadgen,task/TASK_STATE_COMPLETED,1,1,1,1,1,<agw-central's pod>
c34-c3-direct,c3-l4,direct,000/exit56,000/exit56,0,0,0,0,0,none
c34-c3-ingress,c3-l4,ingress,200/exit0,200/exit0,1,1,1,1,1,<the ingress pod>
c34-c3-ingress-2,c3-l4,ingress,503/exit0,503/exit0,0,0,0,0,0,none
c34-c4-service,c4-l7rule,service,503/exit0,503/exit0,0,0,0,0,0,none
c34-c4-direct,c4-l7rule,direct,000/exit56,000/exit56,0,0,0,0,0,none
c34-c4-ingress,c4-l7rule,ingress,503/exit0,503/exit0,0,0,0,0,0,none
c34-after-direct,after-removal,direct,200/exit0,200/exit0,1,1,1,1,1,<the curl pod>
c34-after-ingress,after-removal,ingress,200/exit0,200/exit0,1,1,1,1,1,<the ingress pod>
g2c-c34after-worker,after-removal,service-loadgen,loadgen,task/TASK_STATE_COMPLETED,1,1,1,1,1,<agw-central's pod>
```

Read against `## Experiment C / go receiver / C-3, ztunnel L4` and `## Experiment C / go receiver / C-4, ztunnel given an
HTTP rule`, 120 of 120 cells the same. Under C-3, the direct send is refused at the connection (curl exit 56, no ledger
line), the send through `agw-central` completes 1/1/1/1/1, and the first ingress send **passes** on the connection the
ingress already held open to the worker, opened before the policy; once ztunnel has closed that connection (here after
113 s, inside the bound) the next ingress send is refused, 503, because the ingress's identity is not the one allowed.
Under C-4, istiod accepts the object with reason `UnsupportedValue` ("ztunnel does not support HTTP attributes"),
ztunnel holds it as `Allow` with an empty rule list, and every caller is refused, the GET the rule names as well as the
POST, 3 of 3 paths. After the removal, both controls and the clean check complete. The proxy spans
(`c3c4/proxy-spans.txt`) read as the entry's: 0 spans for the refused direct send, the two ingress SERVER spans of the
refused second send reading `http.status=503` with status error, and full traces for the delivered ones.

## C-3R and C-3R2 — does ztunnel close a connection opened before an ALLOW that denies it?

```
C=experiments/runs/my-walkthrough/c3r; REC=$C/rec.sh
for c in "kubectl get authorizationpolicy -A" "kubectl -n istio-system get pods -l app=ztunnel -o wide" "kubectl -n lab get pods -o wide"; do bash $REC $C/start-state.txt "$c"; done
bash $REC $C/objects-created.txt "kubectl apply -f $C/objects/namespace.yaml"
bash $REC $C/objects-created.txt "kubectl apply -f $C/objects/server.yaml -f $C/objects/client.yaml"
bash $REC $C/objects-created.txt "kubectl -n c3r wait --for=condition=Available deploy/c3r-server --timeout=120s && kubectl -n c3r wait --for=condition=Ready pod/c3r-client --timeout=120s"
bash $REC $C/objects-created.txt "kubectl -n c3r get pods -o wide"
W=$(date -u +%FT%TZ)
for r in none-1 selector-1 namespace-1 selector-2 namespace-2; do
  sleep 5
  bash experiments/runs/my-walkthrough/drivers/c3r-rep.sh "${r%-*}" "${r##*-}"
done
ZT=$(kubectl -n istio-system get pod -l app=ztunnel --field-selector spec.nodeName=agent-mesh-lab-worker -o jsonpath='{.items[0].metadata.name}')
bash $REC $C/window.txt "kubectl -n c3r logs deploy/c3r-server"
bash $REC $C/window.txt "kubectl -n istio-system logs $ZT --since-time=$W | grep -E 'no longer allowed|policy change|skipping unknown policy|handling RBAC'"
bash $REC $C/window.txt "kubectl -n istio-system logs $ZT --since-time=$W | awk -F'\t' '\$2 == \"warn\"' | wc -l"
bash $REC $C/window.txt "kubectl -n istio-system logs deploy/istiod --since-time=$W | grep -E 'PUSH for node:$ZT' | grep -E 'WDS|WADS'"
bash $REC $C/objects-deleted.txt "kubectl delete -f $C/objects/client.yaml -f $C/objects/server.yaml --wait=true"
bash $REC $C/objects-deleted.txt "kubectl delete -f $C/objects/namespace.yaml --wait=true --timeout=180s"
bash $REC $C/objects-deleted.txt "kubectl get authorizationpolicy -A; istioctl ztunnel-config workloads --node agent-mesh-lab-worker -o json | jq '[.[] | select(.namespace == \"c3r\")] | length'"
RUN_ID=c3rafter RUN_ITEM=my-walkthrough/c3r/after experiments/gate2-single-clean.sh
python3 $C/counts.py
```

**158.3 s.** C-3R2 is the same measurement with a server anyone can pull, an nginx image pinned by digest in
`objects/setup.yaml` (one manifest for the namespace `repro`, the server and the client), read inside the server pod
before the repetitions, its log read with stamps, and the image removed from the kind node after; **175.4 s**
(`logs/54-c3r2.txt`):

```
C=experiments/runs/my-walkthrough/c3r2; REC=$C/rec.sh
for c in "kubectl get authorizationpolicy -A" "kubectl -n istio-system get pods -l app=ztunnel -o wide"; do bash $REC $C/start-state.txt "$c"; done
bash $REC $C/objects-created.txt "kubectl apply -f $C/objects/setup.yaml"
bash $REC $C/objects-created.txt "kubectl -n repro wait --for=condition=Available deploy/server --timeout=180s && kubectl -n repro wait --for=condition=Ready pod/client --timeout=180s"
bash $REC $C/objects-created.txt "kubectl -n repro get pods -o jsonpath='{range .items[*]}{.metadata.name}{\" \"}{.spec.serviceAccountName}{\" \"}{.status.containerStatuses[0].imageID}{\"\\n\"}{end}'"
bash $REC $C/server-and-client.txt "kubectl -n repro exec deploy/server -- sh -c 'nginx -v 2>&1; id; nginx -T 2>&1 | grep -n -E \"listen|keepalive\"'"
W=$(date -u +%FT%TZ)
for r in none-1 selector-1 namespace-1 selector-2 namespace-2; do
  sleep 5
  bash experiments/runs/my-walkthrough/drivers/c3r2-rep.sh "${r%-*}" "${r##*-}"
done
ZT=$(kubectl -n istio-system get pod -l app=ztunnel --field-selector spec.nodeName=agent-mesh-lab-worker -o jsonpath='{.items[0].metadata.name}')
bash $REC $C/window.txt "kubectl -n repro logs deploy/server --timestamps --since-time=$W"
bash $REC $C/window.txt "kubectl -n istio-system logs $ZT --since-time=$W | grep -E 'no longer allowed|policy change|skipping unknown policy|handling RBAC'"
bash $REC $C/window.txt "kubectl -n istio-system logs deploy/istiod --since-time=$W | grep -E 'PUSH for node:$ZT' | grep -E 'WDS|WADS'"
bash $REC $C/objects-deleted.txt "kubectl delete -f $C/objects/setup.yaml --wait=true --timeout=180s"
bash $REC $C/objects-deleted.txt "kubectl get authorizationpolicy -A; kubectl get ns repro"
bash $REC $C/objects-deleted.txt "docker exec agent-mesh-lab-worker crictl rmi docker.io/nginxinc/nginx-unprivileged@sha256:0918d093d6088225655ddf602fdf00679c1c0c9a89c01c6dcdce5ee5e6c2f3f3"
RUN_ID=c3r2after RUN_ITEM=my-walkthrough/c3r2/after experiments/gate2-single-clean.sh
python3 $C/counts.py
```

A throwaway namespace, a server and a client pod; in each repetition the client opens one
connection through its ztunnel, sends one request on it, a policy that denies the client's identity is applied, scoped
to the server's workload (`selector`) or to the namespace, a second request is sent on the **same** held connection,
then a new connection, and the policy is removed. The entry ran three of each scope and one control; this block runs
one control and two of each. The counts (`c3r/counts.csv`, the cells that carry the finding, in their column order with the identifiers, push and
list columns left out; `c3r2/counts.csv` reads the same on every one of them, its refused new connection reading
`curl exit 56: curl: (56) Recv failure: Connection reset by peer`):

```
# condensed: eleven of the CSV's columns, in its order; the identifier, push and list columns left out; the new_conn cell cut after the ztunnel status
scope,n,zt_scope,watcher_lines,sock_before_r2,r2_on_held,server_arrivals_held,held_responses,held_outbound_close,r2_after_rbac_ms,new_conn
none,1,,0,ESTABLISHED,delivered,2,2 200 200,no error,,curl exit 0; ztunnel outbound: no error
selector,1,WorkloadSelector,0,ESTABLISHED,delivered,2,2 200 200,no error,455,curl exit 56; ztunnel outbound: http status: 401 Unauthorized
selector,2,WorkloadSelector,0,ESTABLISHED,delivered,2,2 200 200,no error,453,curl exit 56; ztunnel outbound: http status: 401 Unauthorized
namespace,1,Namespace,1,CLOSE_WAIT,not delivered,1,1 200,while closing connection: send: io error: broken pipe,392,curl exit 56; ztunnel outbound: http status: 401 Unauthorized
namespace,2,Namespace,1,CLOSE_WAIT,not delivered,1,1 200,while closing connection: send: io error: broken pipe,387,curl exit 56; ztunnel outbound: http status: 401 Unauthorized
```

Read against `## Experiment C / ztunnel / open connections` and `## Experiment C / ztunnel / open connections, public
server`: **the policy's scope decides it**. A selector-scoped ALLOW leaves the held connection open and the second request
on it is delivered (2 of 2 here, 3 of 3 there), while the new connection is refused; a namespace-scoped ALLOW closes the
held connection (ztunnel's watcher line, the socket in `CLOSE_WAIT`, the second request not delivered, 2 of 2 here and 3
of 3 there), and the new connection is refused. C-3R2 reads the same with the public server. Set beside the entries, 60
of 66 and 62 of 69 cells the same, 2 and 3 timing, and 4 and 4 differing: the `push_apply` and `push_remove` cells read
`none` here, because the byte-copied `counts.py` names the ztunnel pod of the day it was written for istiod's push sizes;
today's pushes are in `window.txt` beside them, exactly as the currency pass recorded the same limit: for C-3R `WDS`
236 B and 217 B with `WADS` 67 B, 68 B and 0 B against the entry's 238 B, 219 B, 67 B, 68 B and 0 B; for C-3R2 426 B and
380 B with 73 B, 74 B and 0 B, the entry's sizes. Both namespaces are deleted and the clean check after each reads
1/1/1/1/1 on both receivers.

## C-5 — Istio's `AuthorizationPolicy` with `targetRefs` naming `agw-central`

```
mkdir -p experiments/runs/my-walkthrough/c5
cp -R experiments/runs/2026-09-23-c5-istio-policy-agw-central/overlay-c5 experiments/runs/2026-09-23-c5-istio-policy-agw-central/counts.sh experiments/runs/my-walkthrough/c5/
export RUNREL=my-walkthrough/c5 RUN_ID=wtc5
C5="bash experiments/runs/2026-09-23-c5-istio-policy-agw-central/c5.sh"
S=$(date -u +%FT%TZ)
$C5 read before "$S"
$C5 pod-up
for r in go py; do $C5 probe p0 $r SendMessage yes 1; $C5 probe p0 $r SubscribeToTask yes 1; done
A=$(date -u +%FT%TZ); $C5 apply
$C5 read applied "$A"
for r in go py; do for n in 1 2; do
  $C5 probe p1 $r SendMessage yes $n; $C5 probe p1 $r SubscribeToTask yes $n; $C5 probe p1 $r SendMessage no $n
done; done
$C5 read p1-after "$A"
B=$(date -u +%FT%TZ); $C5 remove
$C5 read removed "$B"
$C5 pod-down
kubectl -n agentgateway-waypoint logs deploy/agw-central --since-time="$S" > experiments/runs/my-walkthrough/c5/agw-central-access.txt
(cd experiments/runs/my-walkthrough/c5 && bash counts.sh) | tee experiments/runs/my-walkthrough/c5/counts.txt
```

**47.0 s.** An `AuthorizationPolicy` that denies a probe header, aimed at `agw-central` by `targetRefs`; the probes carry
the header (`yes`) or not (`no`). The tally (`c5/counts.txt`):

```
p0 go SendMessage yes -> probes=1 http200=1 arrived=1 refused403=0 executes=1 invocations=1
p0 go SubscribeToTask yes -> probes=1 http200=1 arrived=1 refused403=0 executes=0 invocations=0
p0 py SendMessage yes -> probes=1 http200=1 arrived=1 refused403=0 executes=2 invocations=1
p0 py SubscribeToTask yes -> probes=1 http200=1 arrived=1 refused403=0 executes=0 invocations=0
p1 go SendMessage no -> probes=2 http200=2 arrived=2 refused403=0 executes=2 invocations=2
p1 go SendMessage yes -> probes=2 http200=2 arrived=2 refused403=0 executes=2 invocations=2
p1 go SubscribeToTask yes -> probes=2 http200=2 arrived=2 refused403=0 executes=0 invocations=0
p1 py SendMessage no -> probes=2 http200=2 arrived=2 refused403=0 executes=4 invocations=2
p1 py SendMessage yes -> probes=2 http200=2 arrived=2 refused403=0 executes=4 invocations=2
p1 py SubscribeToTask yes -> probes=2 http200=2 arrived=2 refused403=0 executes=0 invocations=0
all probes: 16 http200: 16 refused403 lines: 0
```

Read against `## Experiment C / agw-central / C-5, Istio's AuthorizationPolicy with targetRefs naming agw-central`: istiod
accepts the object (`WaypointAccepted=True`, "bound to agentgateway-waypoint/agw-central") and pushes it, and **nothing
changes**: every probe with the header is delivered, 200, 1 arrival at the receiver asked, 16 of 16 here and 20 of 20
there, 0 lines refused, and the proxy's dump holds no authorization before, during or after. An Istio policy aimed at an
agentgateway-managed proxy is accepted by istiod and reaches nothing that enforces it. 110 of 110 cells the same.

## C-6 — what a Gateway API `HTTPRoute` can separate

```
mkdir -p experiments/runs/my-walkthrough/c6
cp -R experiments/runs/2026-09-23-c6-httproute/overlay-c6 experiments/runs/2026-09-23-c6-httproute/counts.py experiments/runs/my-walkthrough/c6/
export RUNREL=my-walkthrough/c6 RUN_ID=wtc6
SENDS="bash experiments/runs/2026-09-23-c6-httproute/sends.sh"; C6="bash experiments/runs/2026-09-23-c6-httproute/c6.sh"
export IMAGE=$($SENDS image | sed -n 's/.* image=\([^ ]*\) .*/\1/p'); echo "IMAGE=$IMAGE"
S=$(date -u +%FT%TZ)
$C6 read before "$S"
$SENDS pod-up
for n in 1 2; do for r in go py; do $SENDS c6pa sm $r $n; $SENDS c6pa st $r $n; done; done
A=$(date -u +%FT%TZ); $C6 apply
$C6 read applied "$A"
for n in 1 2; do for r in go py; do for k in sm st ss cst; do $SENDS c6pb $k $r $n; done; done; done
B=$(date -u +%FT%TZ); $C6 remove
$C6 read removed "$B"
$SENDS pod-down
RUN_ID=c6after RUN_ITEM=my-walkthrough/c6/after experiments/gate2-single-clean.sh
python3 experiments/runs/my-walkthrough/c6/counts.py | tee experiments/runs/my-walkthrough/c6/counts.txt
```

**233.8 s.** Phase A sends `SendMessage` (`sm`) and `SubscribeToTask` (`st`) with nothing applied; phase B adds one
route per receiver that matches `Accept: text/event-stream` and has no backend, then sends `sm`, `st`,
`SendStreamingMessage` (`ss`) and a curl `SubscribeToTask` without that header (`cst`). The tally (`c6/counts.txt`):

```
c6pa go sm -> sends=2 post_status=200 route=lab/worker-ingress method_path=POST / arrivals=2 executes=2 invocations=2 client=ok:TASK_STATE_COMPLETED
c6pa go st -> sends=2 post_status=200 route=lab/worker-ingress method_path=POST / arrivals=2 executes=0 invocations=0 client=200
c6pa py sm -> sends=2 post_status=200 route=lab/orchestrator-ingress method_path=POST / arrivals=2 executes=4 invocations=2 client=ok:TASK_STATE_COMPLETED
c6pa py st -> sends=2 post_status=200 route=lab/orchestrator-ingress method_path=POST / arrivals=2 executes=0 invocations=0 client=200
c6pb go cst -> sends=2 post_status=200 route=lab/worker-ingress method_path=POST / arrivals=2 executes=0 invocations=0 client=200
c6pb go sm -> sends=2 post_status=200 route=lab/worker-ingress method_path=POST / arrivals=2 executes=2 invocations=2 client=ok:TASK_STATE_COMPLETED
c6pb go ss -> sends=2 post_status=500 route=lab/c6-refuse-event-stream-worker method_path=POST / arrivals=0 executes=0 invocations=0 client=500
c6pb go st -> sends=2 post_status=500 route=lab/c6-refuse-event-stream-worker method_path=POST / arrivals=0 executes=0 invocations=0 client=500
c6pb py cst -> sends=2 post_status=200 route=lab/orchestrator-ingress method_path=POST / arrivals=2 executes=0 invocations=0 client=200
c6pb py sm -> sends=2 post_status=200 route=lab/orchestrator-ingress method_path=POST / arrivals=2 executes=4 invocations=2 client=ok:TASK_STATE_COMPLETED
c6pb py ss -> sends=2 post_status=500 route=lab/c6-refuse-event-stream-orchestrator method_path=POST / arrivals=0 executes=0 invocations=0 client=500
c6pb py st -> sends=2 post_status=500 route=lab/c6-refuse-event-stream-orchestrator method_path=POST / arrivals=0 executes=0 invocations=0 client=500
sends: 24 refused by the route (500): 8 of them with an arrival: 0
```

Read against `## Experiment C / both receivers / C-6, what a Gateway API HTTPRoute can separate`: every POST reads
`POST /` at the route layer whatever its operation, so a route cannot tell `SubscribeToTask` from `SendMessage` by path
or method; the one thing it can match is the `Accept: text/event-stream` header the SDK client sends on its streaming
methods, and the added route refuses those with `500`, `no valid backends`, **0 arrivals**, while `SendMessage` goes
through and a curl `SubscribeToTask` without the header goes through too, 8 refused and 16 delivered here, 12 and 24
there. 168 of 168 cells the same.

## C-7 — agentgateway's authorization on a header, and what each proxy sees as the caller's identity

```
mkdir -p experiments/runs/my-walkthrough/c7
cp -R experiments/runs/2026-09-23-c7-agw-authorization/overlay-c7-header experiments/runs/2026-09-23-c7-agw-authorization/overlay-c7-identity experiments/runs/2026-09-23-c7-agw-authorization/counts.py experiments/runs/my-walkthrough/c7/
export RUNREL=my-walkthrough/c7 RUN_ID=wtc7
SENDS="bash experiments/runs/2026-09-23-c6-httproute/sends.sh"; C7="bash experiments/runs/2026-09-23-c7-agw-authorization/c7.sh"
export IMAGE=$($SENDS image | sed -n 's/.* image=\([^ ]*\) .*/\1/p'); echo "IMAGE=$IMAGE"
S=$(date -u +%FT%TZ)
$C7 read before "$S"
A=$(date -u +%FT%TZ); $C7 apply overlay-c7-header
$C7 read header-applied "$A"
$SENDS pod-up
for n in 1 2; do for r in go py; do for k in sm st ss cst; do $SENDS c7h $k $r $n; done; done; done
$SENDS pod-down
B=$(date -u +%FT%TZ); $C7 remove overlay-c7-header
$C7 read header-removed "$B"
I=$(date -u +%FT%TZ); $C7 apply overlay-c7-identity
$C7 read identity-applied "$I"
RUN_ID=c7id RUN_ITEM=my-walkthrough/c7/identity-in-force-clean experiments/gate2-single-clean.sh
$C7 pod-up
for n in 1 2; do for p in ingress-go ingress-py agw-go agw-py pf-go; do $C7 probe $p $n; done; done
$C7 pod-down
J=$(date -u +%FT%TZ); $C7 remove overlay-c7-identity
$C7 read identity-removed "$J"
RUN_ID=c7after RUN_ITEM=my-walkthrough/c7/after experiments/gate2-single-clean.sh
python3 experiments/runs/my-walkthrough/c7/counts.py | tee experiments/runs/my-walkthrough/c7/counts.txt
```

**291.3 s.** Part 1 is C-6's header rule as an `AgentgatewayPolicy` `deny` on the ingress routes; part 2 applies
`AgentgatewayPolicy` objects whose rule reads `source.identity` on both proxies, takes the clean check with them in force,
and probes five paths. The tally (`c7/counts.txt`):

```
c7h go cst -> sends=2 post_status=200 route=lab/worker-ingress method_path=POST / arrivals=2 executes=0 invocations=0 client=200
c7h go sm -> sends=2 post_status=200 route=lab/worker-ingress method_path=POST / arrivals=2 executes=2 invocations=2 client=ok:TASK_STATE_COMPLETED
c7h go ss -> sends=2 post_status=403 route=lab/worker-ingress method_path=POST / arrivals=0 executes=0 invocations=0 client=403
c7h go st -> sends=2 post_status=403 route=lab/worker-ingress method_path=POST / arrivals=0 executes=0 invocations=0 client=403
c7h py cst -> sends=2 post_status=200 route=lab/orchestrator-ingress method_path=POST / arrivals=2 executes=0 invocations=0 client=200
c7h py sm -> sends=2 post_status=200 route=lab/orchestrator-ingress method_path=POST / arrivals=2 executes=4 invocations=2 client=ok:TASK_STATE_COMPLETED
c7h py ss -> sends=2 post_status=403 route=lab/orchestrator-ingress method_path=POST / arrivals=0 executes=0 invocations=0 client=403
c7h py st -> sends=2 post_status=403 route=lab/orchestrator-ingress method_path=POST / arrivals=0 executes=0 invocations=0 client=403
sends: 16 refused by the proxy (403): 8 of them with an arrival: 0
# part 2: path, proxy, route, the src.identity the proxy logged, status, reason -> lines
agw-go agw-central lab/worker spiffe://cluster.local/ns/lab/sa/default 403 Authorization -> 2
agw-py agw-central lab/orchestrator spiffe://cluster.local/ns/lab/sa/default 403 Authorization -> 2
ingress-go agw-central agentgateway-waypoint/model-via-agw spiffe://cluster.local/ns/lab/sa/worker 200  -> 2
ingress-go ingress lab/worker-ingress <absent> 200  -> 2
ingress-py agw-central agentgateway-waypoint/model-via-agw spiffe://cluster.local/ns/lab/sa/worker 200  -> 2
ingress-py agw-central lab/worker spiffe://cluster.local/ns/lab/sa/orchestrator 200  -> 2
ingress-py ingress lab/orchestrator-ingress <absent> 200  -> 2
pf-go agw-central agentgateway-waypoint/model-via-agw spiffe://cluster.local/ns/lab/sa/worker 200  -> 2
pf-go ingress lab/worker-ingress <absent> 200  -> 2
probe path agw-go: probes=2 client_status=403 with an arrival=0
probe path agw-py: probes=2 client_status=403 with an arrival=0
probe path ingress-go: probes=2 client_status=200 with an arrival=2
probe path ingress-py: probes=2 client_status=200 with an arrival=2
probe path pf-go: probes=2 client_status=200 with an arrival=2
```

Read against `## Experiment C / both receivers / C-7, agentgateway's authorization on headers and on identity`: the
header rule refuses the two streaming methods at the proxy, `403 authorization failed`, **0 arrivals**, and lets
`SendMessage` and the curl `SubscribeToTask` through, 8 refused and 8 delivered here, 12 and 12 there; the clean check
with the identity rule in force reads 1/1/1/1/1 on both receivers (`c7/identity-in-force-clean`); through the ingress
every probe is delivered and the ingress's own line carries **no `src.identity`**, in-cluster and by port-forward alike,
6 of 6 here and 9 of 9 there; through `agw-central` the probe pod, which runs as the `default` account, is refused
`403 Authorization` with `src.identity=spiffe://cluster.local/ns/lab/sa/default` on 4 of 4 here and 6 of 6 there. The
header rule's 112 cells read the same. Of the identity rule's cells, 37 read the same and **3 differ, and they now read
as a later entry recorded them**: on the three ingress paths the other `agw-central` lines of the probe's work item, the
orchestrator's forward and the worker's model call, carry `lab/sa/orchestrator` and `lab/sa/worker` where C-7 read
`lab/sa/default` for every lab workload. Those are the three ServiceAccounts D-4 made standing on 2026-09-25, and
`## Experiment C / both receivers / D-4, the identity re-reading` records exactly these values ("lab/sa/orchestrator on
the forward, lab/sa/worker on every model call"); C-7's single-identity values no longer apply on this topology.

## C-8 — agentgateway's authorization on the request body

```
mkdir -p experiments/runs/my-walkthrough/c8
cp -R experiments/runs/2026-09-23-c8-body-rule/overlay-c8-deny experiments/runs/2026-09-23-c8-body-rule/overlay-c8-require experiments/runs/2026-09-23-c8-body-rule/overlay-c8-require-scoped experiments/runs/2026-09-23-c8-body-rule/counts.py experiments/runs/my-walkthrough/c8/
export RUNREL=my-walkthrough/c8 RUN_ID=wtc8
SENDS="bash experiments/runs/2026-09-23-c6-httproute/sends.sh"; C8="bash experiments/runs/2026-09-23-c8-body-rule/c8.sh"
export IMAGE=$($SENDS image | sed -n 's/.* image=\([^ ]*\) .*/\1/p'); echo "IMAGE=$IMAGE"
rows() { for n in 1 2; do for r in go py; do for k in sm st ss cst; do $SENDS "$1" $k $r $n; done; done; done; }
S=$(date -u +%FT%TZ)
$C8 read before "$S"
$SENDS pod-up
T=$(date -u +%FT%TZ); $C8 apply overlay-c8-deny; sleep 10; $C8 read deny-applied "$T"
rows c8d
for r in go py; do $C8 probe c8d pad $r 1; done
for r in go py; do $C8 probe c8d batch $r 1; $C8 probe c8d dup $r 1; done
U=$(date -u +%FT%TZ); $C8 read deny-end "$T"; $C8 remove overlay-c8-deny; sleep 10; $C8 read deny-removed "$U"
T=$(date -u +%FT%TZ); $C8 apply overlay-c8-require; sleep 10; $C8 read require-applied "$T"
rows c8r
for r in go py; do $C8 probe c8r pad $r 1; done
U=$(date -u +%FT%TZ); $C8 read require-end "$T"; $C8 remove overlay-c8-require; sleep 10; $C8 read require-removed "$U"
$SENDS pod-down
RUN_ID=c8after RUN_ITEM=my-walkthrough/c8/after experiments/gate2-single-clean.sh
$C8 read after "$U"
$SENDS pod-up
T=$(date -u +%FT%TZ); $C8 apply overlay-c8-deny; sleep 10; $C8 read deny2-applied "$T"
$C8 probe c8p padt py 1
U=$(date -u +%FT%TZ); $C8 read deny2-end "$T"; $C8 remove overlay-c8-deny; sleep 10; $C8 read deny2-removed "$U"
T=$(date -u +%FT%TZ); $C8 apply overlay-c8-require-scoped; sleep 10; $C8 read scoped-applied "$T"
rows c8s
for r in go py; do $C8 probe c8s pad $r 1; done
U=$(date -u +%FT%TZ); $C8 read scoped-end "$T"; $C8 remove overlay-c8-require-scoped; sleep 10; $C8 read scoped-removed "$U"
$SENDS pod-down
RUN_ID=c8after2 RUN_ITEM=my-walkthrough/c8/after-2 experiments/gate2-single-clean.sh
$C8 read after-2 "$U"
python3 experiments/runs/my-walkthrough/c8/counts.py | tee experiments/runs/my-walkthrough/c8/counts.txt
```

**549.1 s.** The rule reads the JSON-RPC `method` out of the body: as a `deny` of `SubscribeToTask` (row 1), as a
`require` of anything but it (row 2), and as that `require` scoped to POSTs so the card GET passes (row 5); the probes
are the four kinds, a body padded past the proxy's 2 097 152-byte limit (`pad`, and `padt` with the pad inside
`params.tenant`), a JSON batch and a body with the key twice (`dup`). The entry's stage sequence, `run-c8.sh`, names its
own directory and nonce, so the block above is its stages as commands. The tally (`c8/counts.txt`, the summary lines and
the cells that carry each row):

```
# condensed: the summary lines whole; the per-cell lines cut to the fields the entry rests on, the rest of each line left out
Deny go st -> sends=2 post_status=403 post_error=authorization failed Authorization arrivals=0 executes=0 invocations=0 client=403/stream_end=error
Deny go sm -> sends=2 post_status=200 arrivals=2 arrival_methods=SendMessage executes=2 invocations=2 client=ok:TASK_STATE_COMPLETED
Deny go pad -> sends=1 post_status=200 arrivals=1 arrival_methods=SubscribeToTask sdk_received=1 executes=0 client=200 answer=sse:error -32001 ...
Deny go batch -> sends=1 post_status=200 arrivals=0 executes=0 client=200 answer=error -32602 invalid params: json: cannot unmarshal array ...
Deny go dup -> sends=1 post_status=403 post_error=authorization failed Authorization arrivals=0 client=403
Deny py pad -> sends=1 post_status=200 arrivals=1 arrival_methods=SubscribeToTask sdk_received=0 client=200 answer=error -32600 Invalid Request ...
Deny py batch -> sends=1 post_status=200 arrivals=0 client=200 answer=error -32600 Batch requests are not supported
Deny: sends=22 POST refused by the proxy (403)=10 of them with an arrival=0; card GET lines=6 of them 403=0
Require go sm -> sends=2 get=403 post_status=<no POST line> arrivals=0 client=err:resolve card: card request failed, status: 403 Forbidden
Require py sm -> sends=2 agw_card_get=200 post_status=200 arrivals=2 executes=4 invocations=2 client=ok:TASK_STATE_COMPLETED
Require: sends=18 POST refused by the proxy (403)=8 of them with an arrival=0; card GET lines=6 of them 403=6
Deny (re-applied) py padt -> sends=1 post_status=200 arrivals=1 arrival_methods=SubscribeToTask sdk_received=1 executes=0 client=200
Require (scoped) go sm -> sends=2 get=200 post_status=200 arrivals=2 executes=2 invocations=2 client=ok:TASK_STATE_COMPLETED
Require (scoped) go st -> sends=2 get=200 post_status=403 post_error=authorization failed Authorization arrivals=0 client=403/stream_end=error
Require (scoped): sends=18 POST refused by the proxy (403)=10 of them with an arrival=0; card GET lines=6 of them 403=0
```

Read against `## Experiment C / both receivers / C-8, agentgateway's authorization on the request body`: the body rule
does what the header and route rules could not, it refuses `SubscribeToTask` and allows `SendMessage` on one endpoint,
10 of 10 refused with 0 arrivals under Deny here (40 of 40 there); the plain Require also refuses the Go client's card
GET (its body has no `method`), 403 at the card 6 of 6, so the Go rows never send their POST, which the scoped Require
fixes (card GET 200, then the same refusals); and the rule does not hold where the body defeats it: the padded
`SubscribeToTask` past the proxy's body limit passes as 200 and arrives at both receivers (`pad`, `padt`), and the batch
passes as 200 (the receivers refuse batches themselves, -32602 at the Go receiver, -32600 at the Python one), while the
duplicate key is refused by the second key. 781 cells read the same, 4 within, and 20 differ in two kinds: 10 byte
lengths (`body_len` 140 and 159 there against 141 and 160 here on the batch and dup probes, `arrival_body_len` 278 and
287 against 280 and 289 on the Require and scoped Require SendMessage and SendStreamingMessage rows), because the bodies
carry the work-item id once or twice and this run's nonce is one character longer; and the two batch probes' 10 cells
(arrivals, responses, the arrival's length and A2A version, the response's status), which read 1 arrival and 1 response
there and 0 or empty here. That second kind is a read the driver does
not make: a batch body is a JSON array and carries no work-item id, so `make ledgers` finds no line for it on either
side; the entry read those two cells afterwards by the sha256 of the body the client recorded, kept as
`ingress-by-body-hash.txt`, which `counts.py` reads. This run took that read in **one step appended at its end** (the
next row, C-10, had replaced both agent pods one second after C-8's step ended, so the lines were gone from this
cluster). The step is the row's Deny stage again in its own directory with its own nonce, the two batch probes, the read
on both receivers right after them, the overlay removed and the clean check, as it ran (`logs/90-c8-batch-repeat.txt`);
a reader makes the read the same way right after their own two batch probes above, before any row that rolls the
agents, with `c8` and `wtc8` in place of `c8-repeat` and `wtc8r`:

```
mkdir -p experiments/runs/my-walkthrough/c8-repeat
cp -R experiments/runs/2026-09-23-c8-body-rule/overlay-c8-deny experiments/runs/2026-09-23-c8-body-rule/counts.py experiments/runs/my-walkthrough/c8-repeat/
export RUNREL=my-walkthrough/c8-repeat RUN_ID=wtc8r
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
  P=experiments/runs/my-walkthrough/c8-repeat/c8d/c8d-$recv-batch-wtc8r-1
  H=$(shasum -a 256 $P/request.json | cut -d' ' -f1)
  { echo "# $(date -u +%FT%TZ) kubectl -n lab logs deploy/$app --since-time=$T | grep $H  (make ledgers found no line by the work-item id: the body does not parse as an object, so the ledger line carries no identity; joined here on the body hash the client recorded)"
    kubectl -n lab logs deploy/$app --since-time=$T | grep "$H"; } > $P/ingress-by-body-hash.txt
  cat $P/ingress-by-body-hash.txt
done
U=$(date -u +%FT%TZ); $C8 read deny-end "$T"; $C8 remove overlay-c8-deny; sleep 10; $C8 read deny-removed "$U"
$SENDS pod-down
RUN_ID=c8rafter RUN_ITEM=my-walkthrough/c8-repeat/after experiments/gate2-single-clean.sh
python3 experiments/runs/my-walkthrough/c8-repeat/counts.py | tee experiments/runs/my-walkthrough/c8-repeat/counts.txt
```

**125.3 s.** The read found the arrival and the response line for each batch body:

```
# condensed: the two ledger lines cut at " ... " with their digest written <sha256>; the two CSV rows cut to the cells named
{"ledger":"ingress","phase":"arrival",...,"method":"","id":"","messageId":"","taskId":"","logical_work_item_id":"","a2a_version":"1.0","content_type":"application/json","body_sha256":"<sha256>","body_len":142}
{"ledger":"ingress","phase":"response",...,"body_sha256":"<sha256>","body_len":142,"status":200}
c8d,Deny,go,batch,...,arrivals=1,arrival_a2a_version=1.0,responses=1,response_status=200,...,answer=error -32602 invalid params: json: cannot unmarshal array ...
c8d,Deny,py,batch,...,arrivals=1,arrival_a2a_version=1.0,responses=1,response_status=200,...,answer=error -32600 Batch requests are not supported
```

which is the entry's reading, 1 arrival and 1 response at each receiver, the batch passing the body rule and refused by
the receiver itself (`c8-repeat/counts.csv`; 42 cells the same, the 4 byte lengths one and two characters longer for the
two-character-longer nonce).

## C-10 — the application refuses the operation

```
mkdir -p experiments/runs/my-walkthrough/c10
cp experiments/runs/2026-09-24-c10-application/counts.py experiments/runs/my-walkthrough/c10/
RUNREL=my-walkthrough/c10 N=2 bash experiments/runs/2026-09-24-c10-application/c10.sh
RUN_ID=c10after RUN_ITEM=my-walkthrough/c10/after experiments/gate2-single-clean.sh
python3 experiments/runs/my-walkthrough/c10/counts.py; cat experiments/runs/my-walkthrough/c10/counts.txt
```

**191.8 s**, the two rollouts of both agents included: `REFUSE_OPERATION=SubscribeToTask` is set on both Deployments
for the row and restored empty by the driver's exit trap. The tally (`c10/counts.txt`, per kind and receiver; the
Python receiver's `st` and `cst` read the same with `content_type=application/json` and `stream_end=eof`):

```
# condensed: per kind, the cells the entry rests on; some cells joined with " ; "; long client cells cut at " ... "
== c10r go sm (SendMessage): 2 sends
   client                 unary ok state=TASK_STATE_COMPLETED x2
   post_status            200 x2
   arrivals               1 x2
   executes               1 x2
   invocations            1 x2
== c10r go st (SubscribeToTask): 2 sends
   client                 http=200 content_type=text/event-stream wire_error=-32004 this operation is not supported: SubscribeToTask is refused by this agent (REFUSE_OPERATION) events=0 stream_end=error ... x2
   post_status            200 x2
   arrivals               1 x2
   arrival_methods        SubscribeToTask x2
   exec_own               received:SubscribeToTask result[error=this operation is not supported: SubscribeToTask is refused by this agent (REFUSE_OPERATION);stream_end=error] x2
   executes               0 x2
   invocations            0 x2
== c10r go ss (SendStreamingMessage): 2 sends
   client                 http=200 content_type=text/event-stream wire_error=0  events=4 stream_end=eof error= x2
   arrivals 1 x2 ; executes 1 x2 ; invocations 1 x2
== c10p go pad (SubscribeToTask padded, x_pad): 1 sends
   client                 curl http=200 content_type=text/event-stream answer=sse:error -32004 this operation is not supported: SubscribeToTask is refused by this agent (REFUSE_OPERATION) x1
   arrivals 1 x1 ; executes 0 x1 ; invocations 0 x1
== c10p py padt (SubscribeToTask padded, params.tenant): 1 sends
   client                 curl http=200 content_type=application/json answer=error -32004 this operation is not supported: SubscribeToTask is refused by this agent (REFUSE_OPERATION) x1
   arrivals 1 x1 ; executes 0 x1 ; invocations 0 x1
```

Read against `## Experiment C / both receivers / C-10, the application refuses the operation`: every request reaches the
receiver (the proxy's line and the arrival line read 200 and the operation), the refusal sits after the pre-dispatch
ledger's arrival line and the execution ledger's `received` line and before the SDK's handler, the answer is the
specification's `-32004 UnsupportedOperationError` on both SDKs, and **it holds where C-8's Deny did not**: the padded
bodies are refused 2 of 2 here (4 of 4 there), 0 executes. `SendMessage` and `SendStreamingMessage` complete with one
invocation each. 142 cells the same, 8 within (the entry's tenth repetition carries a two-digit number in its body
length), 0 differing.

## D-1 — which request headers reach each application

```
RUN_ID=wtd1h RUNREL=my-walkthrough/d1-headers bash experiments/runs/2026-09-24-d1-current-topology/headers.sh
H=experiments/runs/my-walkthrough/d1-headers/headers
for app in worker orchestrator; do
  echo "== $app"
  jq -r 'select(.phase=="arrival" and .headers != null) | "\(if (.method // "") == "" then "GET /.well-known/agent-card.json" else .method end) | lwi=\(.logical_work_item_id) | remote=\(.remote | sub(":[0-9]+$"; "")) | names=\(.headers.names | join(",")) | values=\([.headers.values | to_entries[] | "\(.key)=\(.value)"] | join(" ; ")) | authorization_present=\(.headers.authorization_present)"' $H/$app-ingress.jsonl
done | tee $H/readings.txt
echo "== names over every arrival carrying the reading"; cat $H/worker-ingress.jsonl $H/orchestrator-ingress.jsonl | jq -r 'select(.phase=="arrival" and .headers != null) | .headers.names[]' | sort | uniq -c | sort -rn
```

**48.9 s**, the two rollouts of both agents included (`LEDGER_HEADERS=on` for the row, restored empty). One unary, one
stream and one subscribe per receiver, on B-4's paths; the entry ran one of each too. The reading
(`logs/60-d1-headers.txt`), the worker's arrivals from the load client through the ingress and from the orchestrator's
forward through `agw-central`, and the names over all 15 arrivals:

```
# condensed: three of the worker's nine arrival lines, the remote written as the pod it is; the names tally whole
== worker
GET /.well-known/agent-card.json | lwi= | remote=<the ingress pod> | names=accept-encoding,host,traceparent,user-agent,x-caller,x-logical-work-item-id | values=host=worker.lab.internal ; user-agent=Go-http-client/1.1 ; x-caller=loadgen | authorization_present=false
SendMessage | lwi=d1-hdr-go-unary-wtd1h | remote=<the ingress pod> | names=a2a-version,accept-encoding,content-length,content-type,host,traceparent,user-agent,x-caller,x-logical-work-item-id | ...
SendMessage | lwi=d1-hdr-py-unary-wtd1h | remote=<agw-central's pod> | names=a2a-version,accept,accept-encoding,content-length,content-type,host,traceparent,user-agent,x-a2a-message-id,x-caller,x-logical-work-item-id | values=host=worker.lab.svc.cluster.local:8080 ; user-agent=python-httpx/0.28.1 ; x-caller=orchestrator | authorization_present=false
== names over every arrival carrying the reading
  15 x-caller
  15 user-agent
  15 traceparent
  15 host
  15 accept-encoding
  14 x-logical-work-item-id
   8 content-type
   8 content-length
   8 a2a-version
   7 accept
   2 x-a2a-message-id
```

Read against `## Experiment C / both receivers / D-1, the header reading`: 15 arrivals carry the reading, 9 at the
worker and 6 at the orchestrator, with the same eleven names in the same counts as there (host, user-agent,
accept-encoding, traceparent and x-caller 15 each, x-logical-work-item-id 14, a2a-version, content-type and
content-length 8, accept 7, x-a2a-message-id 2), `authorization_present` false on 15 of 15, no forwarding or
client-certificate header, and the `remote` the forwarding proxy's own pod on 15 of 15. No caller identity reaches
either application in a header; `x-caller` is what the client itself chose to send. The header-name sets per receiver
and arrival kind read 8 of 8 the same (`readings-vs-entries.txt`).

## D-2 — the REST and gRPC bindings: the route layer, the path rule, the body rule and the application

```
mkdir -p experiments/runs/my-walkthrough/d2
for o in overlay-l1-route overlay-l2-path overlay-l3-deny overlay-l3-require; do cp -R experiments/runs/2026-09-24-d2-bindings/$o experiments/runs/my-walkthrough/d2/; done
cp experiments/runs/2026-09-24-d2-bindings/counts.py experiments/runs/my-walkthrough/d2/
export RUNREL=my-walkthrough/d2 RUN_ID=wtd2
SENDS="bash experiments/runs/2026-09-24-d2-bindings/sends.sh"; W=experiments/runs/my-walkthrough/d2
export IMAGE=$($SENDS image | sed -n 's/.* image=\([^ ]*\) .*/\1/p'); echo "IMAGE=$IMAGE"
readings() { # <window> <label>: the routes, the policies, the agents' setting and pods, the controller's log, the ingress's config dump
  mkdir -p $W/$1
  { echo "# $(date -u +%FT%TZ) readings $1 $2"; kubectl -n lab get httproute,grpcroute,agentgatewaypolicy -o yaml
    for d in worker orchestrator; do echo "$d: $(kubectl -n lab get deploy $d -o jsonpath='{range .spec.template.spec.containers[0].env[?(@.name=="REFUSE_OPERATION")]}{.name}={.value}{end}')"; done
    kubectl -n lab get pods -l 'app in (worker,orchestrator)' -o wide --no-headers
    kubectl -n agentgateway-system logs deploy/agentgateway --since=2m 2>/dev/null | tail -40; } > $W/$1/readings-$2.txt 2>&1
  bash experiments/runs/2026-09-19-waypoint-policy-recheck/config-dump.sh agentgateway-ingress agentgateway-ingress $W/$1/config-dump-ingress-$2.json > /dev/null
}
sendset() { # <window> <rounds>
  for b in rest grpc; do for r in go py; do
    for n in $(seq 1 "$2"); do $SENDS "$1" $b sm $r $n; $SENDS "$1" $b st $r $n; done
    if [ "$b" = rest ]; then for n in $(seq 1 "$2"); do $SENDS "$1" rest cst $r $n; done; fi
  done; done
}
$SENDS pod-up
for b in rest grpc; do for r in go py; do $SENDS clean $b sm $r 1; done; done
readings p0 before; sendset p0 1; readings p0 removed
for win in l1-route l2-path l3-deny l3-require; do
  readings $win before
  kubectl apply -k $W/overlay-$win | tee $W/$win/apply.txt; sleep 8
  readings $win applied
  sendset $win 2
  readings $win end
  kubectl delete -k $W/overlay-$win | tee $W/$win/remove.txt; sleep 8
  readings $win removed
done
readings l4-app before
for d in worker orchestrator; do kubectl -n lab set env deploy/$d REFUSE_OPERATION=SubscribeToTask; done | tee $W/l4-app/apply.txt
for d in worker orchestrator; do kubectl -n lab rollout status deploy/$d --timeout=180s; done | tee -a $W/l4-app/apply.txt
readings l4-app applied
sendset l4-app 2
readings l4-app end
for d in worker orchestrator; do kubectl -n lab set env deploy/$d REFUSE_OPERATION=; done | tee $W/l4-app/remove.txt
for d in worker orchestrator; do kubectl -n lab rollout status deploy/$d --timeout=180s; done | tee -a $W/l4-app/remove.txt
readings l4-app removed
$SENDS pod-down
RUN_ID=d2after RUN_ITEM=my-walkthrough/d2/after experiments/gate2-single-clean.sh
python3 $W/counts.py | tee $W/counts.txt
```

**795.2 s.** D-2's own stage driver, `rows.sh`, runs five repetitions per send; the block above is its stages with the
reader's own loop at two (the clean send and the `p0` window at one, as the entries). The tally (`d2/counts.txt`, one
line per window, binding, receiver and kind; the columns are sends, the client's outcomes, the gRPC attempts, the
proxy's lines, arrivals and their binding, received, executes, invocations and the receiver's answers):

```
# condensed: twelve of the file's 64 lines, whole
p0 | rest | go | st | 1 | 1x http=200 error=task not found: no active execution | - | 1x lab/worker-ingress http=200 | 1 | rest | 1 | 0 | 0 | 1x status=200
p0 | grpc | go | st | 1 | 1x grpc=5 error=task not found: no active execution | 1x 1/0 | 1x lab/worker-grpc-ingress http=200 grpc=5 | 1 | grpc | 1 | 0 | 0 | 1x status=200 grpc_status=5
l1-route | rest | go | st | 2 | 2x http=500 error=server error | - | 2x lab/d2-refuse-subscribe-rest-worker http=500 reason=NoHealthyBackend | 0 | - | 0 | 0 | 0 | -
l1-route | grpc | go | st | 2 | 2x grpc=14 error=no valid backends | 2x 1/0 | 2x lab/d2-refuse-subscribe-grpc-worker http=200 reason=NoHealthyBackend | 0 | - | 0 | 0 | 0 | -
l1-route | rest | go | sm | 2 | 2x http=- state=TASK_STATE_COMPLETED | - | 2x lab/worker-ingress http=200 | 2 | rest | 2 | 2 | 2 | 2x status=200
l2-path | rest | go | st | 2 | 2x http=403 error=server error | - | 2x lab/worker-ingress http=403 reason=Authorization | 0 | - | 0 | 0 | 0 | -
l2-path | grpc | go | st | 2 | 2x grpc=7 error=authorization failed | 2x 1/0 | 2x lab/worker-grpc-ingress http=200 reason=Authorization | 0 | - | 0 | 0 | 0 | -
l3-deny | rest | go | st | 2 | 2x http=200 error=task not found: no active execution | - | 2x lab/worker-ingress http=200 | 2 | rest | 2 | 0 | 0 | 2x status=200
l3-deny | grpc | go | st | 2 | 2x grpc=5 error=task not found: no active execution | 2x 1/0 | 2x lab/worker-grpc-ingress http=200 grpc=5 | 2 | grpc | 2 | 0 | 0 | 2x status=200 grpc_status=5
l3-require | rest | go | sm | 2 | 2x http=- error=server error | - | 2x lab/worker-ingress http=403 reason=Authorization | 0 | - | 0 | 0 | 0 | -
l3-require | grpc | go | sm | 2 | 2x grpc=7 error=authorization failed | 2x 1/0 | 2x lab/worker-grpc-ingress http=200 reason=Authorization | 0 | - | 0 | 0 | 0 | -
l4-app | rest | go | st | 2 | 2x http=200 error=this operation is not supported: SubscribeToTask is refused  | - | 2x lab/worker-ingress http=200 | 2 | rest | 2 | 0 | 0 | 2x status=200
l4-app | grpc | go | st | 2 | 2x grpc=9 error=this operation is not supported: SubscribeToTask is refused  | 2x 1/0 | 2x lab/worker-grpc-ingress http=200 grpc=9 | 2 | grpc | 2 | 0 | 0 | 2x status=200
# gRPC sends with a transparent attempt (grpc_transparent_attempts > 0): 0 []
```

Read against the four D-2 entries, `## Experiment C / both receivers / D-2, the route layer on REST and gRPC`,
`... D-2, agentgateway's authorization on request.path`, `... D-2, C-8's body rule on REST and gRPC` and `... D-2, the
application refuses the operation on REST and gRPC`: on REST and gRPC the operation is in the **path**, so the route
layer refuses `SubscribeToTask` (500 `NoHealthyBackend` on REST, gRPC status 14 `no valid backends`) where on JSON-RPC
no route match could; agentgateway's CEL rule on `request.path` refuses it (403 on REST, gRPC status 7) where C-7's
header rule could not tell the operation; C-8's body rule, unchanged, reads nothing on either binding, since a REST
body carries no JSON-RPC `method` and a gRPC body is protobuf, so as `deny` it refuses nothing there and as `require` it
refuses everything, `SendMessage` included (403 on REST, gRPC status 7); and the
application's refusal is binding-agnostic (`-32004` as HTTP 200 on REST at the Go receiver and 400 at the Python one,
gRPC status 9). No gRPC send made a transparent attempt, 0 of 40. With every cell normalised to its row's sends (5 there,
2 here, 1 in the clean and `p0` windows on both), 576 of 576 cells read the same.

## D-3 — the lab's external authorizer on each binding

```
mkdir -p experiments/runs/my-walkthrough/d3
cp -R experiments/runs/2026-09-24-d3-extauthz/overlay-d3-extauthz experiments/runs/2026-09-24-d3-extauthz/counts.py experiments/runs/my-walkthrough/d3/
export RUNREL=my-walkthrough/d3 RUN_ID=d3a
X="bash experiments/runs/2026-09-24-d3-extauthz/d3.sh"; W=experiments/runs/my-walkthrough/d3
export IMAGE=$($X image | sed -n 's/.* image=\([^ ]*\) .*/\1/p'); echo "IMAGE=$IMAGE"
row34() { for r in go py; do for k in pad padt padsm batch dup; do $X send "$1" jsonrpc $k $r 1; done; done; }
$X pod-up
$X read p0-before
for r in go py; do $X send p0 jsonrpc csm $r 1; done
$X read deny-before; $X apply; sleep 8; $X read deny-applied
for r in go py; do for n in 1 2; do for k in sm st ss cst; do $X send deny jsonrpc $k $r $n; done; done; done
$X hop deny-row1
for b in rest grpc; do for r in go py; do for n in 1 2; do $X send deny $b sm $r $n; $X send deny $b st $r $n; done; done; done
row34 deny
$X read deny-end
$X setting allow; $X read allow-applied
row34 allow
$X read allow-end
$X setting deny; $X read deny-restored
$X scale 0; $X read unavail-scaled-0
for r in go py; do for n in 1 2; do $X send unavail jsonrpc sm $r $n; $X send unavail jsonrpc st $r $n; done; done
$X read unavail-end
$X scale 1; $X read unavail-restored
$X remove; sleep 8; $X read removed
$X pod-down
RUN_ID=d3after RUN_ITEM=my-walkthrough/d3/after experiments/gate2-single-clean.sh
$X pod-up
$X read shapes-before; $X apply; sleep 8; $X read shapes-applied
for n in 1 2; do for k in xp xa xg xr; do $X send shapes jsonrpc $k go $n; done; done
for n in 1 2; do for k in xg xr; do $X send shapes jsonrpc $k py $n; done; done
$X read shapes-end
$X remove; sleep 8; $X read shapes-removed
$X pod-down
RUN_ID=d3after2 RUN_ITEM=my-walkthrough/d3/after-2 experiments/gate2-single-clean.sh
python3 $W/counts.py | tee $W/counts.txt
```

**952.3 s.** Four `AgentgatewayPolicy` objects send every request on the ingress routes to the lab's authorization
fixture (`extauthz`, standing since D-3), whose one rule refuses `SubscribeToTask` and allows everything else; its
`EXTAUTHZ_UNDECIDABLE` setting says what to do with a request it cannot read (`deny` by default, `allow` for one
window), and one window scales the fixture to zero. D-3's own `rows.sh` runs ten repetitions of row 1 and five of the
others; the block is its stages with the reader's loops at two. The `RUN_ID` is the entry's own, `d3a`, because D-3's
`counts.py` keys the send directories on it. The tally (`d3/counts.txt`, one cell per window, binding, receiver and kind):

```
# condensed: cells joined with " ; " or " -> "; lines cut at " ... "; the unavail cell quoted whole
deny jsonrpc go sm: sends=2
 client task/TASK_STATE_COMPLETED x2
 proxy 200 200 x2
 extauthz allow:not-subscribe:deny:other:len=0:size=0 allow:operation:SendMessage:deny:jsonrpc:len=296:size=296 x2
 arrivals 1 x2 ; sdk_received 1 x2 ; executes 1 x2 ; invocations 1 x2
deny jsonrpc go st: sends=2
 client unexpected HTTP status: 403 Forbidden stream_end=error x2
 proxy 200 403/DirectResponse x2
 extauthz allow:not-subscribe:deny:other:len=0:size=0 deny:operation:SubscribeToTask:deny:jsonrpc:len=144:size=144 x2
 arrivals 0 x2 ; sdk_received 0 x2 ; executes 0 x2 ; invocations 0 x2
deny rest go st: sends=2  ->  client server error stream_end=error ; proxy 200 403/DirectResponse ; extauthz ... deny:operation:SubscribeToTask:deny:rest:len=0:size=0 ; arrivals 0
deny grpc go st: sends=2  ->  client unexpected HTTP status code received from server: 403 (Forbidden); malformed header: missing HTTP content-type ... grpc=7 attempts=1 transparent=0 ; proxy 200 403/DirectResponse ; extauthz ... deny:operation:SubscribeToTask:deny:grpc:len=41:size=41 ; arrivals 0
deny jsonrpc go pad: sends=1   ->  client http=403 ; proxy 403/DirectResponse ; extauthz deny:undecidable:partial-body:deny:jsonrpc:len=2097152:size=-1 ; arrivals 0
deny jsonrpc go batch: sends=1 ->  client http=403 ; proxy 403/DirectResponse ; extauthz deny:undecidable:batch:deny:jsonrpc:len=149:size=149 ; arrivals 0
deny jsonrpc go dup: sends=1   ->  client http=403 ; proxy 403/DirectResponse ; extauthz deny:undecidable:duplicate-key:deny:jsonrpc:len=168:size=168 ; arrivals 0
allow jsonrpc go pad: sends=1  ->  client http=200 ; proxy 200 ; extauthz allow:undecidable:partial-body:allow:jsonrpc:len=2097152:size=-1 ; arrivals 1 ; sdk_received 1
unavail jsonrpc go sm: sends=2
    client         resolve card: card request failed, status: 403 Forbidden x2
    proxy          403/external authorization failed/ExtAuth x2
    extauthz_lines 0 x2
    extauthz        x2
    arrivals       0 x2
    sdk_received   0 x2
    executes       0 x2
    task_last_state  x2
    invocations    0 x2
shapes jsonrpc go xp: sends=2  ->  client http=403 ; proxy 403/DirectResponse ; extauthz deny:operation:SubscribeToTask:deny:jsonrpc:len=146:size=146 ; arrivals 0
```

Read against `## Experiment C / both receivers / D-3, an external authorizer on each binding`, `... D-3, the body past
maxSize and the request the authorizer cannot read` and `... D-3, the authorizer unavailable`: the fixture reads the
operation from the JSON-RPC body, from the REST path and from the gRPC method path, and one rule refuses
`SubscribeToTask` on all three bindings (403 `DirectResponse`, **0 arrivals**, the gRPC client reading status 7 from a
plain HTTP 403) while `SendMessage` and `SendStreamingMessage` complete with one invocation each, 2 of 2 per cell here
against 10 and 5 there; every decision line joins its send on the work item it carries. Under `deny` the body past the
proxy's limit reaches the fixture cut (`body_len 2097152, size -1`) and is refused, as are the batch and the duplicate
key; under `allow` the same ten are forwarded and reach the receivers (C-8's fail-open, at the authorizer's layer). With
the fixture scaled to zero nothing passes, 0 arrivals and 0 decision lines, and the proxy answers 403 with
`external authorization failed`, reason `ExtAuth`. Both clean checks
read 1/1/1/1/1.

Two things read differently from D-3's entry, and both have a recorded cause. **The shapes window**: D-3 recorded that
its fixture allowed six shapes of `SubscribeToTask` it did not read (a POST to `/x` or `/a2a/v1` at the Go receiver, a
JSON-RPC body with a gRPC content type, the REST subscribe path with its colon percent-encoded: 30 of 30 allowed, each
dispatched by the SDK). Here every one of those 12 sends reads `http=403`, `403/DirectResponse`, the fixture's line
`deny:operation:SubscribeToTask`, 0 arrivals, 0 dispatches. That is D-3b's fixture, the one standing since the author's
note of 2026-09-25, and `## Experiment C / both receivers / D-3b, the authorization fixture over every shape the receivers
dispatch` counted exactly these shapes refused; D-3's values for that window no longer apply on this fixture, and the
30 cells that differ read as D-3b recorded them. **The two batch probes of the `allow` window** read 0 arrivals here
against 1 there for the same reason as C-8's: the read the entry made by hand by the body hash. This run re-took them in
the step appended at its end with that read (`logs/90b-d3-batch-repeat.txt`; the overlay applied, the setting put to
`allow`, the two probes, the read on both receivers, the setting back to `deny`, the overlay removed, the clean check):

```
# condensed: the go cell's first five lines; the py cell, equal to it, not repeated
allow jsonrpc go batch: sends=1
    client         http=200 x1
    proxy          200 x1
    extauthz       allow:undecidable:batch:allow:jsonrpc:len=151:size=151 x1
    arrivals       1 x1
    sdk_received   0 x1
```

which is the entry's reading: forwarded under `allow`, 1 arrival at each receiver, not dispatched because both SDKs
refuse batches. That step ran with its own nonce (`d3ar`), and D-3's `counts.py` keys on `d3a`, so it was counted by a
copy in the step's directory whose one changed line names `d3ar` (`logs/93-*`, the `diff` shown there); the fixture's line
reads `len=151` against the entry's 150 for the one-character-longer nonce. 440 cells of the D-3 row read the same, 8
within (the fixture's line lengths under the other nonce), 32 differ as said.

## D-3b — the fixture over every shape the receivers dispatch

```
mkdir -p experiments/runs/my-walkthrough/d3b
cp -R experiments/runs/2026-09-25-d3b-extauthz-shapes/overlay-d3-extauthz experiments/runs/2026-09-25-d3b-extauthz-shapes/counts.py experiments/runs/my-walkthrough/d3b/
export RUNREL=my-walkthrough/d3b RUN_ID=d3b
X="bash experiments/runs/2026-09-25-d3b-extauthz-shapes/d3b.sh"; W=experiments/runs/my-walkthrough/d3b
export IMAGE=$($X image | sed -n 's/.* image=\([^ ]*\) .*/\1/p'); echo "IMAGE=$IMAGE"
row34() { for r in go py; do for k in pad padt padsm batch dup; do $X send "$1" jsonrpc $k $r 1; done; done; }
GO_SHAPES="xp xa xg xr xn xt xm xc xh xl gp gs gq xu xq xi rg xk"
PY_SHAPES="xg xr xn xc xh xl xs xe xb x16 xq rg xk"
$X pod-up
$X read deny-before; $X apply; sleep 8; $X read deny-applied
for r in go py; do for n in 1 2; do for k in sm st ss cst; do $X send deny jsonrpc $k $r $n; done; done; done
$X hop deny-row1
for b in rest grpc; do for r in go py; do for n in 1 2; do $X send deny $b sm $r $n; $X send deny $b st $r $n; done; done; done
row34 deny
$X read deny-end
$X read shapes-before
for n in 1 2; do for k in $GO_SHAPES; do $X send shapes jsonrpc $k go $n; done; done
for n in 1 2; do for k in $PY_SHAPES; do $X send shapes jsonrpc $k py $n; done; done
$X read shapes-end
$X setting allow; $X read allow-applied
row34 allow
$X read allow-end
$X setting deny; $X read deny-restored
$X remove; sleep 8; $X read removed
$X pod-down
RUN_ID=d3bafter RUN_ITEM=my-walkthrough/d3b/after experiments/gate2-single-clean.sh
python3 $W/counts.py | tee $W/counts.txt
```

**574.1 s.** D-3's rows again under the standing fixture, then every shape either receiver dispatches (18 on the Go
receiver, 13 on the Python one), at two each. D-3b's record carries one reader D-3's does not: `batch-by-hash.sh`, which
takes the by-body-hash read for the batch probes and writes it where `counts.py` reads it. It names its own run
directory, so the reader runs a copy, **right after the row and before anything rolls the agents**, and counts again:

```
sed -e 's#^D=experiments/runs/2026-09-25-d3b-extauthz-shapes$#D=experiments/runs/my-walkthrough/d3b#' \
  experiments/runs/2026-09-25-d3b-extauthz-shapes/batch-by-hash.sh > experiments/runs/my-walkthrough/drivers/d3b-batch-by-hash.sh
diff experiments/runs/2026-09-25-d3b-extauthz-shapes/batch-by-hash.sh experiments/runs/my-walkthrough/drivers/d3b-batch-by-hash.sh
bash experiments/runs/my-walkthrough/drivers/d3b-batch-by-hash.sh | tee experiments/runs/my-walkthrough/d3b/batch-by-hash.txt
python3 experiments/runs/my-walkthrough/d3b/counts.py | tee experiments/runs/my-walkthrough/d3b/counts.txt
```

```
# condensed: the read's stamp and the four digests written as placeholders
10c10
< D=experiments/runs/2026-09-25-d3b-extauthz-shapes
---
> D=experiments/runs/my-walkthrough/d3b
# read <stamp>: worker 174 ingress lines, orchestrator 134
deny-jsonrpc-go-batch-d3b-1 worker sha256=<sha256> lines=0
deny-jsonrpc-py-batch-d3b-1 orchestrator sha256=<sha256> lines=0
allow-jsonrpc-go-batch-d3b-1 worker sha256=<sha256> lines=2
allow-jsonrpc-py-batch-d3b-1 orchestrator sha256=<sha256> lines=2
```

In this run that read was taken beside the D-3b step rather than inside it: the inventory this walk was built from had
missed the reader, and a waiter ran the copy the moment the step's log showed its exit, one second after, before D-4's
header phase replaced the agent pods (`logs/63b-*`, `logs/63c-*`). The shapes (`d3b/counts.txt`; every shape reads the
same four lines):

```
# condensed: one shape's four cells whole, two more shapes' extauthz and arrivals cells joined with " -> "
shapes jsonrpc go xp: sends=2
 client http=403 x2
 proxy 403/DirectResponse x2
 extauthz deny:operation:SubscribeToTask:deny:jsonrpc:len=146:size=146 x2
 arrivals 0 x2
shapes jsonrpc go rg: sends=2   ->  extauthz deny:operation:SubscribeToTask:deny:rest:len=0:size=0 ; arrivals 0
shapes jsonrpc go gp: sends=2   ->  extauthz deny:operation:SubscribeToTask:deny:grpc:len=46:size=46 ; arrivals 0
# decision lines not joined to their send's work item: 0
# decision lines with source_principal empty: 128 of 128
```

Read against `## Experiment C / both receivers / D-3b, the authorization fixture over every shape the receivers
dispatch`: D-3's rows do not move (the same cells as above), and **every shape is refused**, 62 of 62 here and 155 of
155 there, client 403, proxy 403 `DirectResponse`, 0 arrivals, 0 dispatches, the fixture's line carrying the decoded
path and the binding it read it as; the batch probes under `allow` read 1 arrival by the by-hash read, as there;
`source_principal` is empty on every decision line. 796 cells read the same, 8 within (the paths carry the repetition
number), 0 differing.

## D-4 — three ServiceAccounts: the identity rows

```
mkdir -p experiments/runs/my-walkthrough/d4
for o in overlay-d4-z overlay-d4-a overlay-d4-r2; do cp -R experiments/runs/2026-09-25-d4-serviceaccounts/$o experiments/runs/my-walkthrough/d4/; done
export RUNREL=my-walkthrough/d4
ROWS="bash experiments/runs/2026-09-25-d4-serviceaccounts/rows.sh"; W=experiments/runs/my-walkthrough/d4
RUN_ID=d4cc RUN_ITEM=my-walkthrough/d4/clean-check experiments/gate2-single-clean.sh
RUN_ID=z1 $ROWS z
RUN_ID=a1 $ROWS a
RUN_ID=r1 $ROWS r2
RUN_ID=x1 $ROWS xa
RUN_ID=d4h1 bash experiments/runs/2026-09-24-d1-current-topology/headers.sh
S=$(date -u +%FT%TZ)
RUN_ID=d4after RUN_ITEM=my-walkthrough/d4/after experiments/gate2-single-clean.sh
mkdir -p $W/after/hop-lines
for zt in $(kubectl -n istio-system get pods -l app=ztunnel -o jsonpath='{.items[*].metadata.name}'); do kubectl -n istio-system logs "$zt" --since-time="$S" | grep 'connection complete' | sed "s/^/$zt /"; done > $W/after/hop-lines/ztunnel-connections.txt
kubectl -n agentgateway-waypoint logs deploy/agw-central --since-time="$S" | grep 'request gateway=' > $W/after/hop-lines/agw-central-access.txt
kubectl -n agentgateway-ingress logs deploy/agentgateway-ingress --since-time="$S" | grep 'request gateway=' > $W/after/hop-lines/ingress-access.txt
python3 experiments/runs/2026-09-25-d4-serviceaccounts/counts.py $W | tee $W/counts.txt
```

**507.9 s.** D-4's `rows.sh` runs each phase at its own five probes, and short as they are it runs as committed here; its
`RUN_ID` values are the entry's because `counts.py` keys on them. The reading (`d4/counts.txt`):

```
# condensed: the JSON cells cut at " ..."; R2's two orchestrator-ingress probe rows and the header reading's values left out; the ingress's five access-line tallies summarised in one line
## Row Z: ztunnel ALLOW on principals at the worker (agw-central's and the orchestrator's identities)
  direct, as the orchestrator's account, policy in force: 5 work items
    5 x {"client": ["GetAgentCard=200/exit0", "SendMessage=200/exit0"], "invocations": 1, ...}
  direct, as the load client's account, policy in force: 5 work items
    5 x {"client": ["GetAgentCard=000/exit56", "SendMessage=000/exit56"], "none": true}
  the forward control (a load-client Job to the orchestrator's Service), policy in force: 5 work items
    5 x {"client": "task/TASK_STATE_COMPLETED", "invocations": 1, "orchestrator_arrivals": 1, ...}
  ztunnel connection lines in the window, inbound to the worker's pod on its port 8080, by source address:
    10 x ('d4-as-loadgen', 'spiffe://cluster.local/ns/lab/sa/loadgen', 'spiffe://cluster.local/ns/lab/sa/worker', 'policy-rejection')
    10 x ('d4-as-orchestrator', 'spiffe://cluster.local/ns/lab/sa/orchestrator', 'spiffe://cluster.local/ns/lab/sa/worker', 'ok')
## Row A: agentgateway Allow on source.identity (lab/orchestrator) on agw-central's route lab/worker
  the load client's account to the worker Service: 5 work items
    5 x {"client": "/ error=resolve card: card request failed, status: 403 Forbidden", "invocations": 0, ...}
  the load client's account to the orchestrator Service, forwarded by the orchestrator: 5 work items
    5 x {"client": "task/TASK_STATE_COMPLETED", "invocations": 1, "orchestrator_arrivals": 1, ...}
  agw-central's access lines in the window (route, src.identity, method, path, status, reason):
    5 x ('lab/worker', 'spiffe://cluster.local/ns/lab/sa/loadgen', 'GET', '/.well-known/agent-card.json', '403', 'Authorization')
    5 x ('lab/worker', 'spiffe://cluster.local/ns/lab/sa/orchestrator', 'POST', '/', '200', '')
## R2: the ingress's source.identity and source.unverifiedWorkload (NOT cryptographically authenticated)
  load client's account, x-d4-probe: verified, worker-ingress: 5 work items      5 x SendMessage=200/exit0
  load client's account, x-d4-probe: unverified, worker-ingress: 5 work items    5 x SendMessage=403/exit0
  orchestrator's account, x-d4-probe: unverified, worker-ingress: 5 work items   5 x SendMessage=200/exit0
  the ingress's access lines in the window: <no src.identity> on every one of 25
## the ingress's ext-authz source principal, D-3's overlay re-applied from its record
  decision lines: 15; (binding, http_method, decision, source_principal): {('other', 'GET', 'allow', '<empty>'): 5, ('jsonrpc', 'POST', 'allow', '<empty>'): 10}
## the header reading (D-1's headers.sh, unedited, from its record)
  worker: 9 arrivals carrying the reading; ... orchestrator: 6 arrivals carrying the reading; ...
```

Read against `## Experiment C / both receivers / D-4, the identity re-reading`, `## Experiment C / go receiver / D-4, Row
Z, ztunnel's ALLOW on principals` and `## Experiment C / go receiver / D-4, Row A, agentgateway's Allow on
source.identity`: with three accounts, ztunnel's ALLOW at the worker admits the orchestrator's identity and refuses the
load client's at the connection (10 `policy-rejection` lines naming `lab/sa/loadgen`, 10 `ok` for the orchestrator's) and
the forward still passes; agentgateway's Allow on `source.identity` at `agw-central`'s worker route refuses the load
client's card GET (403) and passes the orchestrator's forward, 5 of 5 each; the ingress still sees no identity on any
line and its `source.unverifiedWorkload` rule fires on the header the client itself sends; the authorizer's source
principal is empty on 15 of 15; the header reading is D-1's, 15 arrivals with the same names. The tool's text beside the
entry's (`readings-vs-entries.txt`): every row and both clean checks read the same, 99 of 101 lines, the differing lines
being the closing window's ztunnel connection tallies (this run's window holds more connections opening than the
entry's, which is what a window on a long-lived cluster holds) and the header's directory name. The header-name sets
read 8 of 8 the same.

## D-5 — the connection count, with the A2A marking applied and removed from a run directory

```
mkdir -p experiments/runs/my-walkthrough/d5
cp experiments/runs/2026-09-25-d5-a2a-backend/marking-add.json experiments/runs/2026-09-25-d5-a2a-backend/marking-remove.json experiments/runs/my-walkthrough/d5/
export RUNREL=my-walkthrough/d5 RUN_ID=s21
D5="bash experiments/runs/2026-09-25-d5-a2a-backend/d5.sh"
S=$(date -u +%FT%TZ)
$D5 conn unmarked
$D5 mark
$D5 conn marked
$D5 unmark
$D5 conn removed
mkdir -p experiments/runs/my-walkthrough/d5/conn-join
{ echo "# read $(date -u +%FT%TZ): every ztunnel's lines since $S, the start of the connection count"
  for z in $(kubectl -n istio-system get pod -l app=ztunnel -o jsonpath='{.items[*].metadata.name}'); do kubectl -n istio-system logs "$z" --since-time="$S" | sed "s/^/$z /"; done; } > experiments/runs/my-walkthrough/d5/conn-join/ztunnel-window.txt
```

**679.3 s**: each set is 100 s quiet, 8 curl requests, 100 s quiet, and the marking is a JSON patch on the two agent
Services, applied and removed between the sets and waited for in both proxies' dumps. Its `counts.py` runs after the
trial below (it counts both). The counter lines (`d5/counts.txt`; the absolute values are the cluster's since it came up,
the reading is each set's delta):

```
# condensed: the unmarked set's four counter lines whole; the marked and removed sets' lines summarised
### unmarked
  counter agw-central->worker mutual_tls (destination)         pre=31 post=32 idle=32  set delta=1, after 100 s quiet +0
  counter agw-central->orchestrator mutual_tls (destination)   pre=32 post=33 idle=33  set delta=1, after 100 s quiet +0
  counter agentgateway-ingress->worker mutual_tls (destination) pre=48 post=49 idle=49  set delta=1, after 100 s quiet +0
  counter agentgateway-ingress->orchestrator mutual_tls (destination) pre=47 post=48 idle=48  set delta=1, after 100 s quiet +0
### marked      (the same four lines, each set delta=1, after 100 s quiet +0)
### removed     (the same four lines, each set delta=1, after 100 s quiet +0)
```

Read against `## Experiment C / both receivers / D-5, the connection count`: one upstream connection per proxy and agent
per set, and none in the quiet after it, marked or not, 12 of 12 counters here as there; every request 200 in each
phase; under the marking the proxy's lines read `protocol=a2a` and `a2a.method=SendMessage` on the POSTs, unmarked
`protocol=http` and no method, as there. The text beside the entry's (`readings-vs-entries.txt`) differs in the absolute
counter values (this cluster had carried the walk's rows first), the durations and byte counts of the joined connection
lines, and two connection lines that were open before the first set began; every `set delta=1, after 100 s quiet +0`
reads the same.

## The two trials whose configuration is not standing

### C-9 — the A2A marking switched on, then off

```
RUNREL=my-walkthrough/c9 RUN_ID=b1 OUTROOT=experiments/runs/my-walkthrough/c9 bash experiments/runs/2026-09-24-c9-a2a-marking/c9.sh base 1
mkdir -p experiments/runs/my-walkthrough/c9-marking
cp experiments/runs/2026-09-25-d5-a2a-backend/marking-add.json experiments/runs/2026-09-25-d5-a2a-backend/marking-remove.json experiments/runs/my-walkthrough/c9-marking/
RUNREL=my-walkthrough/c9-marking RUN_ID=c9m bash experiments/runs/2026-09-25-d5-a2a-backend/d5.sh mark
kubectl -n lab get svc worker orchestrator -o jsonpath='{range .items[*]}{.metadata.name} appProtocol={.spec.ports[0].appProtocol}{"\n"}{end}'
kubectl -n lab rollout restart deploy/orchestrator
kubectl -n lab rollout status deploy/orchestrator --timeout=180s
RUNREL=my-walkthrough/c9 RUN_ID=a1 OUTROOT=experiments/runs/my-walkthrough/c9 bash experiments/runs/2026-09-24-c9-a2a-marking/c9.sh after 2
bash experiments/runs/2026-09-24-c9-a2a-marking/cards.sh experiments/runs/my-walkthrough/c9/cards-after
bash experiments/runs/2026-09-24-c9-a2a-marking/fwd.sh experiments/runs/my-walkthrough/c9/forward f1
RUN_ID=c9clean RUN_ITEM=my-walkthrough/c9/clean-marked experiments/gate2-single-clean.sh
RUNREL=my-walkthrough/c9-marking RUN_ID=c9m bash experiments/runs/2026-09-25-d5-a2a-backend/d5.sh unmark
kubectl -n lab get svc worker orchestrator -o jsonpath='{range .items[*]}{.metadata.name} appProtocol=[{.spec.ports[0].appProtocol}]{"\n"}{end}'
bash experiments/runs/2026-09-24-c9-revert/cards.sh experiments/runs/my-walkthrough/c9/cards-reverted
RUN_ID=c9after RUN_ITEM=my-walkthrough/c9/after experiments/gate2-single-clean.sh
kubectl -n lab rollout restart deploy/orchestrator
kubectl -n lab rollout status deploy/orchestrator --timeout=180s
kubectl -n lab get pod -l app=orchestrator -o jsonpath="{range .items[*]}{.metadata.name} created={.metadata.creationTimestamp}{\"\n\"}{end}"
RUN_ID=c9after2 RUN_ITEM=my-walkthrough/c9/after-2 experiments/gate2-single-clean.sh
python3 experiments/runs/2026-09-24-c9-a2a-marking/counts.py experiments/runs/my-walkthrough/c9/base experiments/runs/my-walkthrough/c9/after | tee experiments/runs/my-walkthrough/c9/counts.txt
cat experiments/runs/my-walkthrough/c9/cards-after/cards.txt experiments/runs/my-walkthrough/c9/cards-reverted/cards.txt
```

**About 16 min** (94.9, 5.4, 316.8, 36.8, 400.2, 7.1 and 73.0 s for the steps, then 2.5 and 47.9 s for the restart and the
check after it). C-9 marked the agent Services
`appProtocol: agentgateway.dev/a2a` by a deploy commit and rebuilt; this walk applies the same marking with D-5's JSON
patch, as D-5 did, and removes it the same way. Two things in the block are this walk's and not C-9's driver's, and both
concern the orchestrator's agent card of the worker. The first restart, after the marking, is by the controller's
ruling: C-9's orchestrator had been rebuilt under the marking and fetched the worker's card under it, so its forward
failed; D-5's connection count applied the marking around an orchestrator that had fetched the card before it, and its
forward passed. To read C-9's condition the orchestrator is restarted once the marking is on, so that its first forward
fetches the card under it. The second restart, after the unmark, is what this walk found it needs: **an orchestrator
restarted under the marking keeps the card it fetched then, removing the marking does not refresh it, and C-9's own
revert rebuilt the cluster, which this walk does not**. Without it every clean check at the orchestrator after the
unmark read `1/1/1/1/0 task/TASK_STATE_FAILED`, the orchestrator's executor recording `Network communication error:
[SSL: WRONG_VERSION_NUMBER]` on its forward, which is how this walk first took it: the block above is in this run's
order, the check `c9after` before the restart (FAILED at the orchestrator, `c9/after`), the restart, then `c9after2`
(1/1/1/1/1 on both, `c9/after-2`). A reader restarts the orchestrator right after the unmark and takes one check. The readings (`c9/counts.txt`
and the cards):

```
# condensed: the tally's lines cut to the entry's cells; the client lines cut at " ... "; the run directory is the reader's
==== phase base (experiments/runs/my-walkthrough/c9/base)
access lines: 22; on the lab/* routes (A2A Services): 18; model route: 4
    4  agentgateway-ingress | lab/orchestrator-ingress | POST | / | http | <absent> | <absent> | <absent> | <absent> | <absent> | <absent>
    4  agentgateway-ingress | lab/worker-ingress | POST | / | http | <absent> | <absent> | <absent> | <absent> | <absent> | <absent>
   A2A-Version on arrivals: {'1.0': 10}
==== phase after (experiments/runs/my-walkthrough/c9/after)
access lines: 26; on the lab/* routes (A2A Services): 22; model route: 4
    8  agentgateway-ingress | lab/worker-ingress | GET | /.well-known/agent-card.json | a2a | <absent> | <absent> | <absent> | <absent> | <absent> | <absent>
    2  agentgateway-ingress | lab/worker-ingress | POST | / | a2a | SendMessage | success | <absent> | task | TASK_STATE_COMPLETED | set
    2  agentgateway-ingress | lab/worker-ingress | POST | / | a2a | SendStreamingMessage | <absent> | <absent> | <absent> | <absent> | <absent>
    4  agentgateway-ingress | lab/worker-ingress | POST | / | a2a | SubscribeToTask | <absent> | <absent> | <absent> | <absent> | <absent>
    6  agw-central | lab/orchestrator | GET | /.well-known/agent-card.json | a2a | <absent> | <absent> | <absent> | <absent> | <absent> | <absent>
    2  go | sm | SendMessage | http://worker.lab.internal/ ... | TASK_STATE_COMPLETED |  |
    2  py | sm | SendMessage | https://orchestrator.lab.svc.cluster.local:8080/ ... | None |  |
    2  py | sr | SendStreamingMessage | https://orchestrator.lab.svc.cluster.local:8080/ ... |  | error | 0
   26  access line and its span carry the same seven keys and values
card go-central ... interfaces=["https://worker.lab.svc.cluster.local:8080/", ...]
card py-central ... interfaces=["https://orchestrator.lab.svc.cluster.local:8080/", ...]
card probe-go-central-xfp-http ... extra=[-H X-Forwarded-Proto: http] ... interfaces=["http://worker.lab.svc.cluster.local:8080/", ...]
(after the revert) card go-central ... interfaces=["http://worker.lab.svc.cluster.local:8080", ...]
orchestrator-<pod> created=2026-09-26T17:24:10Z
orchestrator-<pod> created=2026-09-26T16:48:01Z
```

Read against `## Experiment C / both receivers / C-9, the A2A marking switched on` and `## Experiment C / both receivers /
after C-9`: under the marking the proxies' lines and spans on the agent routes read `protocol=a2a`, `a2a.method` on the
POSTs (`SendMessage` with its outcome, result kind and task state; `SubscribeToTask` and `SendStreamingMessage` with the
method alone), each access line and its span carrying the same seven keys; the Go clients through the ingress complete;
**the agent-card rewrite moves every client that follows a card to a Service address to `https`**, so the Python clients
fail (`None`, `error 0`), the orchestrator's forward fails with `Network communication error: [SSL: WRONG_VERSION_NUMBER]`
(`c9/forward`, `task/TASK_STATE_FAILED`), and the lab's clean check reads 0/0/0/0/0 at both receivers, the script exiting
0 with it as the entry's did; a probe carrying `X-Forwarded-Proto: http` gets the card with `http`. After the revert the
cards read `http` again and the clean check reads 1/1/1/1/1 on both receivers once the orchestrator is restarted. Set
beside the entries: the base and after `requests`, `proxy-spans` and `arrivals` tables read 132, 143, 8 and 216 of 216
cells the same; the `clients` tables differ in one column, `advertised_urls`, which lists three interfaces per card here
(JSON-RPC, HTTP+JSON and gRPC, the D-2 bindings of 2026-09-24) where C-9 read one; the tallies scale from five
repetitions to two.

### D-5 — the A2A backend type as a trial

```
cp -R experiments/runs/2026-09-25-d5-a2a-backend/trial-overlay experiments/runs/my-walkthrough/d5/
RUNREL=my-walkthrough/d5 RUN_ID=t22 REPS=2 bash experiments/runs/2026-09-25-d5-a2a-backend/d5.sh trial
W=experiments/runs/my-walkthrough/d5/trial; mkdir -p $W/traces/by-id
grep -h -o 'trace.id=[0-9a-f]*' $W/agw-central-access-in-force-with-cards.txt $W/ingress-access-in-force-with-cards.txt | cut -d= -f2 | sort -u > $W/traces/trace-ids.txt
kubectl -n telemetry port-forward svc/jaeger 16686:16686 >/dev/null 2>&1 &
PF=$!
for i in $(seq 1 30); do curl -sS -o /dev/null --max-time 2 http://127.0.0.1:16686/api/v3/services >/dev/null 2>&1 && break; sleep 1; done
while read -r t; do curl -sS --retry 0 --max-time 20 "http://127.0.0.1:16686/api/traces/$t" -o "$W/traces/by-id/$t.json"; done < $W/traces/trace-ids.txt
kill "$PF" >/dev/null 2>&1 || true; wait "$PF" >/dev/null 2>&1 || true
echo "# $(date -u +%FT%TZ) traces read from Jaeger by the trace.id on every proxy request line of the trial window (port-forward to svc/jaeger, /api/traces/<id>)" > $W/traces/README.txt
echo "trace ids: $(wc -l < $W/traces/trace-ids.txt | tr -d ' '); files: $(ls $W/traces/by-id | wc -l | tr -d ' ')"
RUNREL=my-walkthrough/d5 RUN_ID=d5after bash experiments/runs/2026-09-25-d5-a2a-backend/d5.sh clean
(cd experiments/runs/my-walkthrough/d5 && python3 ../../2026-09-25-d5-a2a-backend/counts.py) | tee experiments/runs/my-walkthrough/d5/counts.txt
```

**114.2 s**, the trace read **1.3 s** and the clean check **47.8 s**. Two `AgentgatewayBackend` objects of type A2A
replace the four HTTP agent routes' backends, every client the lab runs is sent once per repetition, the routes are
restored from their own specs and the backends deleted; then every trace the trial's proxy lines name is read from the
trace backend by its id, as the entry did (`logs/71b-d5-trial-traces.txt`: `trace ids: 18; files: 18`). The reading
(`d5/counts.txt`, Step 2.2):

```
# condensed: case (a) whole; cases (b) to (g) summarised in two lines with the proxies' tallies
### (a) JSON-RPC, ingress by Host worker.lab.internal, CLIENT_DIAL=target: 2 repetitions
  client: 2 x resolve card: card request failed, status: 503 Service Unavailable
  ledgers: arrivals=0 execution lines=0 invocations=0
  agw-central line x2 route=lab/worker GET /.well-known/agent-card.json host=worker.lab.svc.cluster.local status=503 protocol=a2a src sa=agentgateway-ingress reason=UpstreamFailure error=upstream call failed: SendRequest: connection error: Connection reset by peer (os error 104)
  ingress line x2 route=lab/worker-ingress GET /.well-known/agent-card.json host=worker.lab.internal status=503 protocol=a2a src sa=<none> reason=Internal error=processing failed: agent card invalid JSON
### (b) to (g): the same, 2 repetitions each, every client 503 at the card
  agw-central x7 route=lab/worker status=503 protocol=a2a reason=UpstreamFailure src sa=agentgateway-ingress
  ingress x7 route=lab/worker-ingress status=503 protocol=a2a reason=Internal src sa=<none>
```

Read against `## Experiment C / both receivers / D-5, the A2A backend type as a trial`: **every row fails at the card
GET**, 14 of 14 here and 21 of 21 there, the ingress answering 503 `agent card invalid JSON` and `agw-central` 503
`UpstreamFailure` with the connection reset, so the type is not kept; the routes read as before after the removal. The
clean check after the trial read `1/1/1/1/1` at the worker and `1/1/1/1/0 task/TASK_STATE_FAILED` at the orchestrator
in this run, for the reason the C-9 section gives (it was taken before the orchestrator's second restart); the check
after that restart reads 1/1/1/1/1 on both.

## The closing state

```
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
```

This run took that read twice, at the walk's end (`logs/80-closing-state.txt`) and again after the appended step
(`logs/91-closing-state-after-repeat.txt`); the second, whole (the `AGE` column is what the cluster reported):

```
## retry stanzas across every HTTPRoute
0
## AuthorizationPolicies, AgentgatewayPolicies, AgentgatewayBackends, the agent Services' appProtocol, the agents' settings
AuthorizationPolicy: 0
AgentgatewayPolicy: 4
AgentgatewayBackend: 1
worker appProtocol=[]
orchestrator appProtocol=[]
extauthz: EXTAUTHZ_UNDECIDABLE=[deny]
orchestrator: MODEL_MAX_RETRIES=[0]
orchestrator: REFUSE_OPERATION=[null]
orchestrator: LEDGER_HEADERS=[null]
orchestrator: FORWARD_RESUBSCRIBE=[null]
orchestrator: DOWNSTREAM_A2A_URL=[http://worker.lab.svc.cluster.local:8080]
worker: REFUSE_OPERATION=[null]
worker: LEDGER_HEADERS=[null]
extauthz replicas=1 ready=1
## namespaces and probe pods left
Error from server (NotFound): namespaces "c3r" not found
Error from server (NotFound): namespaces "repro" not found
other pods in lab: 1
## Jobs and finished pods left in lab
jobs: 460
 279 Completed
 181 Error
   4 Running
   1 Terminating
## the Deployments standing in lab
NAME           READY   UP-TO-DATE   AVAILABLE   AGE
extauthz       1/1     1            1           179m
mockllm        1/1     1            1           3h5m
orchestrator   1/1     1            1           3h5m
worker         1/1     1            1           3h5m
```

The first read differed in the Jobs alone (456, 275 Completed); its one other pod was the D-5 clean check's control pod,
still terminating in the second that check ended (17:04:41Z, the stamp of both), and the second's the appended step's
curl pod, terminating the same way.

Zero retry stanzas, no `AuthorizationPolicy`, the four deployed `AgentgatewayPolicy` objects (access logs and tracing
on each Gateway), the one standing `AgentgatewayBackend` (the model host, `agentgateway-waypoint/mockllm`, from
step 2b), no `appProtocol` on the agent Services, every row's setting restored, the fixture at `deny` and 1 of 1, both
throwaway namespaces gone; the mock and both receivers reset by the main walkthrough's reset block (`204` each). The
Jobs and their pods stay, as the main walkthrough says: 460 Jobs here, of which 181 pods exited non-zero as their rows
recorded (a refused send is the client's own non-zero exit). The reader's directory held 50 MB at the end of this run
before the proxies' JSON dumps were set aside from the record (`config-dumps-sha256.txt` lists them).

## What this part took

| row | wall time |
| --- | ---: |
| C-1 observation, and its reads | 47.9 s |
| C-3 and C-4 (with the 300 s bound, reached at 113 s) | 311.2 s |
| C-3R, C-3R2 | 158.3 / 175.4 s |
| C-5, C-6, C-7, C-8, C-10 | 47.0 / 233.8 / 291.3 / 549.1 / 191.8 s |
| D-1 headers, D-2, D-3, D-3b, D-4, D-5 connection count | 48.9 / 795.2 / 952.3 / 574.1 / 507.9 / 679.3 s |
| C-9 base, marking and restart, after, cards and forward, clean check under the marking, unmark, clean check | 94.9 / 5.4 / 316.8 / 36.8 / 400.2 / 7.1 / 73.0 s |
| D-5 trial, its trace read, its clean check | 114.2 / 1.3 / 47.8 s |
| **first command to last, the reads between included** | **1 h 51 min 37 s** |
| appended: C-8's and D-3's batch probes with the by-hash read | 125.3 / 127.2 s |
| appended: the orchestrator's restart after the unmark, and the clean check | 2.5 / 47.9 s |

Every driver exited 0 on its first run and none was repeated; the two `diff` commands exit 1 by design. The per-step
stamps are in the record's `timings.csv`, and what the cluster reports about itself in `cluster-versions.txt`.

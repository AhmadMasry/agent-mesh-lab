# agent-mesh-lab

Can you retry an agent? A reproducible lab for A2A failure semantics on Kubernetes.

## What this is

An experiment lab that produces counted, traced findings about how A2A agent traffic behaves under retries, transport failure, and network-layer policy on Kubernetes, with Istio Ambient and agentgateway on the path. The findings feed a KubeCon + CloudNativeCon Europe 2027 submission. This is experiment apparatus, not a system intended for any other use.

## Read in this order

1. `docs/PROPOSAL.md` — the experiment design, v6, frozen. It is not edited; anything that would change it goes to `docs/proposal-notes.md` for a human decision.
2. `docs/experiment-a-checklist.md` — the working checklist for Experiment A, gate by gate. Every box ends with something recorded, not something built.
3. `findings.md` — one entry per gate, receiver, and mode or run. Numbers first, interpretation second. No entry without a run.
4. `versions.yaml` — every pin with the URL it was verified from. No value without a source.

Progress is read from the checklist and `findings.md`, not from this file.

## Method in one paragraph

One logical work item can become one or more A2A messages; each message can be delivered over one or more network attempts; each delivery can cause downstream side effects. Three ledgers count what happened at three boundaries: every inbound HTTP/JSON-RPC request before the A2A SDK sees it, every message the SDK dispatched and every Task created, and every model invocation attributed to the work item and task that caused it. OpenTelemetry traces explain which layer produced each delivery and why. Ledgers are ground truth; traces are the explanation. The proposal defines the experiments (A, B, C), the pins, and the language standard.

## Layout

Directories appear when their gate needs them.

```
agents/orchestrator/   Python, a2a-python; same behaviour as the worker, Agent A by default
agents/worker/         Go, a2a-go; hosts the pre-dispatch ingress and execution ledgers
fixtures/mockllm/      Go; OpenAI-compatible model endpoint; failure injection; invocation ledger
fixtures/replay/       Go; controlled duplicate-delivery harness (modes M1–M3)
fixtures/loadgen/      Go; a2a-go client
deploy/                Kustomize: base, step-1-nomesh, step-2-ambient-agw, step-2b-agw-ingress-egress, step-2c-gate2, step-3-stress
experiments/           one runnable script per checklist item; cited run outputs under experiments/runs/,
                       shared helpers under experiments/lib/, test inputs under experiments/fixtures/
docs/upstream/         draft issue texts for behaviour that looks like a project gap; filed by a human
```

## Prerequisites and running Experiment A

Tools needed on the machine running these targets, with the versions observed
on the machine used for Gate 1 (each checked with its own version command;
`versions.yaml` remains the source of truth for the pins the findings cite):

| Tool | Command | Observed |
| --- | --- | --- |
| ko | `ko version` | `0.19.1` |
| pack | `pack version` | `0.40.9+git-8210eb1.build-6996` |
| kind | `kind version` | `kind v0.33.0 go1.27.0 darwin/arm64` |
| istioctl | `istioctl version --remote=false` | `client version: 1.31.0` |
| kubectl | `kubectl version --client` | `Client Version: v1.37.0` |
| jq | `jq --version` | `jq-1.8.2` |
| docker | `docker --version` | `Docker version 29.7.2, build a7dcaa6` |
| uv | `uv --version` | `uv 0.12.10 (Homebrew 2026-09-04 aarch64-apple-darwin)` |
| go | `go version` | `go version go1.27.1 darwin/arm64` |

`ko apply`/`ko build` are called with `--platform=linux/$(go env GOARCH)`
throughout the Makefile and `experiments/*.sh`, so the built images match
whatever architecture this machine's Go toolchain reports — no per-host edit
needed.

The worker and mock Deployments do not rebuild themselves: a change under
`agents/worker/`, `fixtures/mockllm/`, or `internal/` reaches them only
through a step target's `ko apply` (`step-1`, `step-2`, `step-2b`, `step-2c`,
`step-3` — not `cluster-kind`, which only creates the kind cluster), which
re-resolves every `ko://` reference from the current checkout and rolls the
affected Deployments; `kubectl set env` restarts a pod onto whatever image
the Deployment already names, and rebuilds nothing. This was measured the
hard way in Gate 3 Task 6: `MODEL_RETRIES` was added to
`agents/worker/main.go` without a following `make step-3`, so
`kubectl set env deployment/worker MODEL_RETRIES=1` set the variable on a
binary with no code path that read it, and a twenty-repetition run measured
nothing before the gap was found. Every one of those five step targets now
also stamps both Deployments with a metadata annotation,
`lab.agent-mesh/go-sources=<hash>` (`GO_SOURCES_HASH` in the Makefile: a
content hash of the tracked Go sources under those paths plus `go.mod` and
`go.sum`, test files excluded since `ko` does not compile them and a
test-only commit must not force a rebuild), and
`experiments/gate3-matrix.sh`'s `image_fresh_or_die()` checks this before
every row: it recomputes the same hash from the checkout with the same
command and refuses unless a Deployment's own annotation matches it exactly
— never by rebuilding anything or by comparing a freshly built image's own
tag, which this repository has separately measured is not stable across time
even on an unchanged checkout. This is metadata, not a binding to the image
itself, so it has one accepted gap: `kubectl rollout undo`, `kubectl set
image`, or a hand-run `ko apply` all change the running binary without
touching the annotation, and the guard would then pass a Deployment whose
sources have not changed but whose image has. That trade is deliberate:
ReplicaSet pruning (the flaw the previous version of this guard had) was
automatic and silent, where each of these is a deliberate operator action,
and only a step target ever changes either Deployment's image in this lab.
**`fixtures/loadgen/` and `fixtures/replay/` are different**: the loadgen Job
is piped through `ko apply` by the experiment scripts themselves
(`experiments/gate3-matrix.sh`'s `send_loadgen_job`) on every repetition, and
`make replay-waypoint` does the same for the replay Job on every invocation,
so both are rebuilt fresh every time they run and cannot go stale — which is
why the guard above does not cover them and does not need to.
`make replay-ingress` is different again: it runs no Job and no `ko apply` at
all, only a host `go build` of the replay fixture driven against a
port-forward, which is if anything a stronger freshness guarantee than a
rebuild-on-apply Job. **The Python agent is not built by `ko`** at all: it is
built by Cloud Native Buildpacks under the fixed tag `orchestrator:dev` and
loaded into kind, so changing anything under `agents/orchestrator/` needs
`make orchestrator-image` followed by
`kubectl -n lab rollout restart deployment/orchestrator`. A `kubectl set env`
on that Deployment restarts the pod onto the image already loaded under that
tag, which is the old one; a run that only sets an environment variable will
measure the code that was there before. This was measured the hard way in
Gate 2 A.2.

To bring up Gate 1's step-1 (no mesh) baseline and step-2 (Istio Ambient with
the agentgateway waypoint) baseline:

```
make cluster-kind step-1 verify-baseline
make step-2 && STEP=2 REPS=5 RUNS="1 2 3 4" experiments/gate1-baseline.sh
```

(step 2 repeats only run types 1-4, the ones whose path crosses the worker's
Service and therefore the waypoint; run types 5-7 exercise the orchestrator's
own model client or a keep-alive connection to the model, neither of which is
behind it, and were counted once in the step-1 entry.)

Step 2b adds two more agentgateway proxies under agentgateway's own control
plane, an ingress in front of Agent A and an egress waypoint between Agent B and
the model, and counts the same four run types through them (`RUN4_URL` sends run
4 in through the ingress; the other three enter at the worker):

```
make step-2b && STEP=2b REPS=5 RUNS="1 2 3 4" \
  RUN4_URL=http://agentgateway-ingress.agentgateway-system.svc.cluster.local \
  experiments/gate1-baseline.sh
```

Step 2c adds the Gate 2 stimulus paths. It gives the orchestrator Service a
second istiod-driven waypoint of its own, so an in-cluster stimulus to either
receiver traverses a waypoint, and gives the worker its own hostname on the
step-2b ingress, so an out-of-cluster stimulus can reach either receiver. It
applies on top of step 2b:

```
make step-2c
```

Gate 2 asks what each receiver does when the same A2A message arrives twice. The
duplicate-delivery harness in `fixtures/replay/` builds one `SendMessage` body
and sends it twice over a client with no retries, in one of three modes: `M1`
byte-identical, `M2` a new JSON-RPC id with the same `messageId`, `M3` a new
JSON-RPC id and a new `messageId`. `RECEIVER` names the SDK (`go` is the worker,
`py` the orchestrator) and `VIA` names the path:

```
make replay MODE=M1 RECEIVER=go VIA=waypoint LWI=<id>
make replay MODE=M1 RECEIVER=go VIA=ingress  LWI=<id> OUT=<dir>
make ledgers LWI=<id> OUT=<dir>
```

`VIA=waypoint` runs the harness as an in-cluster Job, whose pod is
ztunnel-captured, so the request traverses the receiver's own istiod-driven
waypoint; `make ledgers` reads its two client lines from the pod log. `VIA=ingress`
runs the harness on this host through a `kubectl port-forward` to the ingress
Service, and with `OUT` writes the two client lines to `<OUT>/client.jsonl`,
which `make ledgers OUT=<dir>` then keeps rather than overwriting. The name is
`VIA` and not `PATH` because a command-line `PATH=` assignment is exported into
every recipe's shell.

Each receiver Service has a waypoint of its own rather than the two sharing one,
and the out-of-cluster path carries no waypoint at all because the agentgateway
ingress dials the backend pod rather than the Service VIP. Both facts were
measured; they are recorded in `deploy/step-2c-gate2/kustomization.yaml`, in a
dated note in `docs/proposal-notes.md`, and as a draft issue in
`docs/upstream/`.

`experiments/gate2-a1.sh` runs one A.1 box end to end: for one mode and one
receiver it sends the duplicate `REPS` times over each path and writes one row
per repetition.

```
MODE=M1 RECEIVER=go REPS=20 experiments/gate2-a1.sh
MODE=M1 RECEIVER=go REPS=20 VIAS=waypoint experiments/gate2-a1.sh   # one path at a time
```

Rows land in `experiments/runs/<date>-a1-<mode>-<receiver>/summary.csv`, each
carrying the deliveries, executor entries, distinct `messageId`s, Tasks created
and model invocations counted for that work item, the shape of both responses,
and whether the second response named the first Task. The receiver's injector is
disarmed before the run and the mock is reset before every repetition, so a
repetition measures a duplicate and nothing else; `RECEIVER=py` additionally
puts the orchestrator into model mode for the run and restores its
`DOWNSTREAM_A2A_URL` on exit, so the receiver under test answers the request
itself. A repetition whose harness run failed is recorded in the row's `notes`
column and is never re-run: a re-run would be a third delivery. One run
directory holds one run: rows carrying a nonce other than this run's stop the
script before anything is sent, so chunking by `VIAS` works while a second run
into a directory a `findings.md` entry already cites does not. `REPS` must be a
positive integer, and an empty value is an error rather than the default,
because a silent default here spends deliveries that cannot be taken back.

`experiments/gate2-a2.sh` runs one A.2 row end to end: it makes one real client
retry one request and counts what the worker's pre-dispatch ledger recorded for
each attempt.

```
CLIENT=go LAYER=http REPS=20 experiments/gate2-a2.sh
CLIENT=go LAYER=http RETRY_ON=transport+503 REPS=20 experiments/gate2-a2.sh
CLIENT=py LAYER=http PY_HTTP_KNOB=resend REPS=20 experiments/gate2-a2.sh
```

Neither SDK offers a retry, so the retry is the lab's own and it is opt-in.
`CLIENT_RETRIES`, `CLIENT_TRANSPORT_RESEND` and `CLIENT_SDK_RESEND` all default
to off, each has a unit test that fails if that default changes, and this script
is the only thing that switches one on — through the Job template
`deploy/base/loadgen-a2-job.yaml` for the Go client, and through
`kubectl set env` on the orchestrator, with the pre-run values recorded and
restored on exit, for the Python one. The failure the client is asked to retry is
one `close-after-read` armed at the worker for the repetition's work item, which
counts the arrival and then takes the connection away.

`CLIENT_RETRY_ON` says what the HTTP-layer resend acts on, and it matters here
because of what the waypoint does: `transport`, the default, is a transport error
only, and a receiver-side connection close never reaches the client as one,
because the worker's waypoint answers 503 for it (measured on both hops in
`experiments/runs/2026-09-09-a2-go-http/waypoint-503-probe.txt`). `transport+503`
also re-sends once on a 503, and on no other status. Both modes are run and both
are recorded. The mode is not a switch: with no HTTP-layer resend on there is
nothing to widen, and the script refuses the mode on rows that have none.

Rows land in
`experiments/runs/<date>-a2-<client>-<layer>[-<knob>]/summary.csv`, each carrying
the arrivals at the worker and, when there were two, whether they shared the A2A
`messageId`, the JSON-RPC `id` and the body hash.

`experiments/runs/` holds the CSV/JSONL outputs each `findings.md` entry
cites; nothing in that directory is regenerated by reading this README, only
by running the scripts above.

### Step 3: telemetry

Step 3 adds the pipeline the Gate 3 traces travel through. It applies on top of
step 2c and adds only new objects: a `telemetry` namespace holding an
OpenTelemetry Collector, a Jaeger v2 trace backend and Prometheus, plus one
`Instrumentation` resource in `lab` for the OpenTelemetry Operator to read later.
The Operator itself is installed from its Helm chart by the target, the way
step 2b installs agentgateway's control plane, with the chart version pinned in
the Makefile as `OTEL_OPERATOR_CHART_VERSION`.

```
make step-3
```

Like the earlier steps this is a setup target and rotates the `lab` pods, so do
not run it against a measurement in progress. Measured on 2026-09-09: `ko`
rebuilt the Go binaries from unchanged sources to new image digests, so the
worker and the mock rolled, and the apply also returned the orchestrator
Deployment to its declared environment.

What it leaves running:

| Component | Service | Ports |
| --- | --- | --- |
| Collector | `otel-collector.telemetry` | 4317 OTLP gRPC, 4318 OTLP HTTP, 8889 its Prometheus endpoint |
| Trace backend | `jaeger.telemetry` | 4317 and 4318 in, 16686 its own query UI and API |
| Prometheus | `prometheus.telemetry` | 9090 |

Prometheus scrapes four jobs: `istiod` on `:15014/metrics`, `ztunnel` on
`:15020/metrics`, `agentgateway-proxies` on `:15020/metrics` (the two
istiod-driven waypoints, the ingress and the egress, selected by the
`gateway.networking.k8s.io/gateway-name` label the controllers put on them), and
the collector's own endpoint. Read them with
`curl http://prometheus.telemetry.svc.cluster.local:9090/api/v1/targets` from
inside the cluster, or through a port-forward.

The collector lifts one work item's identity onto one set of names. The Python
auto-instrumentation records the four identity headers as
`http.request.header.x_logical_work_item_id` and its siblings, each holding a
list; the Go instrumentation sets `lab.work_item`, `lab.message_id`,
`lab.task_id` and `lab.caller` directly. A `transform` processor copies the first
form onto the second, so every query reads one spelling.

What is instrumented, and what a work item's trace is made of. The three Go
binaries use `internal/otel`: one `Setup` per process, which installs a tracer
provider only when `OTEL_EXPORTER_OTLP_ENDPOINT` is set, an `otelhttp` handler
wrapper on each server, and an `otelhttp` transport wrapper on each outbound
client. The Python agent has no OpenTelemetry code either: it carries the
OpenTelemetry distro as a dependency and starts under `opentelemetry-instrument`,
named in its Procfile, configured only by the environment the step-3 overlay
sets. The OpenTelemetry Operator is installed and its `Instrumentation` resource
exists, but nothing is annotated for injection; that route was measured in four
states and not kept, and `findings.md` carries the counts. The ingress and the
egress proxies export because one `AgentgatewayPolicy` each says so; the
istiod-driven waypoints export nothing, and appear in a trace only as a parent
span id that no exported span carries. Because an A2A request keeps the work item
inside `Message.metadata`, where no HTTP instrumentation can see it, every lab
client also sends it as a header, and the Go handler wrappers and the Python
header capture put it on the span, so a work item is queryable. Reading one
work item gives two traces, not one: the client fetches the agent card and
sends the message as two separate roots.

Traces come out of the backend one work item at a time:

```
make export-trace LWI=<logical_work_item_id> OUT=<dir>
```

It opens a short-lived port-forward, queries the backend's `/api/v3/traces`
binding for spans carrying `lab.work_item=<id>`, and writes the raw response as
`<dir>/trace.json` and one row per span as `<dir>/spans.csv`, with the columns
`trace_id,span_id,parent_span_id,service,operation,start_us,duration_us,lab_work_item,lab_message_id,http_status`.
`LOOKBACK` sets how many seconds back the search window opens (default 3600).
The recipe exits 2 when no span matched, so a run script can tell that from a
failed query; GNU make reports any recipe failure as its own exit 2, so read the
message or the row count rather than make's status. The `jq` program that builds
the CSV lives in `experiments/lib/jaeger-spans.jq` and `make test` runs it against
a response captured from the running backend, `experiments/fixtures/jaeger-trace-sample.json`.

To read a trace by eye, port-forward the backend's own query UI. Nothing else is
installed to look at it with:

```
kubectl -n telemetry port-forward svc/jaeger 16686:16686
# then open http://127.0.0.1:16686
```

Storage is in-memory, so a restart of that pod loses every trace it holds. The
traces a `findings.md` entry cites are the exported copies under
`experiments/runs/`, not the ones in the backend.

### Gateway retries

Every route in this lab carries no `retry` stanza in its baseline state. The
experimental Gateway API `HTTPRouteRule.retry` field goes on for one measured run
and comes off again:

```
make retry-on ROUTE=<waypoint|ingress|egress> [OUT=<dir>]
make retry-off [ROUTE=<waypoint|ingress|egress>] [OUT=<dir>]
```

`waypoint` is the `worker` route the istiod-driven agentgateway waypoint serves,
`ingress` is both routes on the agentgateway ingress, and `egress` is the route
to the model endpoint on the egress waypoint. The stanza is `attempts: 1`,
`backoff: 100ms`, and `codes: [503]`, except on the egress route, where it is
`[500, 503]` because the failure injected on that hop is the model endpoint's
500. Both targets are `kubectl apply` of route objects and nothing else: the
manifests under `deploy/step-3-stress/retry/<route>/{off,on}` read the step-2,
2b and 2c route files rather than copying them, and the rendered stream is cut
down to its `HTTPRoute` documents by `experiments/lib/httproute-only.awk`. No
image is built and no Deployment is rolled. Both print how many `retry:` lines
exist across every HTTPRoute in the cluster, and with `OUT` they write the route
objects read back from the API server into `<dir>/routes.txt`. `retry-off` with
no `ROUTE` puts all three route sets back, which is the state every run that is
not measuring a gateway retry has to start and end in.

What each route's retry does to a request is counted by:

```
ROUTE=<waypoint|ingress|egress> REPS=5 experiments/gate3-gateway-retry-mechanics.sh
ROUTE=<waypoint|ingress|egress> DUMP_ONLY=on experiments/gate3-gateway-retry-mechanics.sh
```

It switches the stanza on, injects one failure per repetition on the hop that
route serves, and counts what the receiver's pre-dispatch ledger or the model
endpoint's invocation ledger recorded, then switches the stanza off again and
disarms every injector. `DUMP_ONLY=on` reads the proxy's own `/config_dump`,
which says whether the proxy holds the policy, and sends nothing: that is a
different question from whether the proxy fired it, and re-asking it must not
spend repetitions. The worker's own model client has one retry knob for the
matrix rows, `MODEL_RETRIES`, which defaults to 0 and has a unit test that fails
if that default changes.

### The A.3 retry-location matrix

One row of the matrix per invocation:

```
make matrix RUN=<baseline|R1|R2|R3|R4|egress> RECEIVER=<go|py> [SUB=<http|sdk|waypoint|ingress|ingress-incluster>] [REPS=20]
RUN=<row> RECEIVER=<go|py> [SUB=<sub>] [REPS=20] [DRY_RUN=on|off] [RUN_ID=<nonce>] [RUN_ITEM=<name>] experiments/gate3-matrix.sh
```

`RUN` names the row and `SUB` its sub-row, which `R1` (`http`, `sdk`) and `R2`
(`waypoint`, `ingress`, `ingress-incluster`) have and the others do not.
`RECEIVER` names the SDK under test: `go` is the worker, `py` the orchestrator,
which is put into model mode for its rows by unsetting `DOWNSTREAM_A2A_URL` for
the run and is put back afterwards.

Which gateway a row means is not the same object for the two receivers, because
the two are not behind the same proxy: the worker sits behind its own
istiod-driven waypoint, and the orchestrator behind the agentgateway ingress its
agent card advertises. So `R2`'s gateway sub-row is `waypoint` for the Go
receiver and `ingress-incluster` for the Python one, and `R4` composes with the
waypoint route at the Go receiver and the ingress route at the Python one. Rows
that would switch a retry on for a route the stimulus never crosses are refused
before anything is sent, each with its reason: any row naming the waypoint route
for the Python receiver, because no `HTTPRoute` names the orchestrator Service
as a parent; and `ingress-incluster` on the Go receiver, because an in-cluster
Job to the worker Service crosses the worker's waypoint rather than the ingress.
The per-route stanza assertion cannot catch either case on its own, since the
stanza does land on a live route, just not one that receiver's stimulus
crosses. Each row switches on exactly the knobs it names — the client's
through the Job template, the receiver's model client through `kubectl set env`,
the gateway's through `make retry-on` — arms one injection per repetition keyed
by that repetition's work item, sends one stimulus, and then collects the three
ledgers, the client lines and the exported trace into
`experiments/runs/<date>-a3-<run>-<receiver>[-<sub>]/<work item>/`. `summary.csv`
holds one row per repetition and `knobs.txt` holds every knob's value and every
route's stanza count, per route and cluster-wide, before the run and again after
it whatever way it ended. Everything the run changed is put back from a trap on
`EXIT`, `INT` and `TERM`; a `SIGKILL` is the one path no trap covers, and
`knobs.txt` names the exact `kubectl set env` that puts the change back. A
restore that fails says so and leaves the script non-zero.

Which layer made a second delivery is decided by `experiments/lib/derive-layer.sh`
from one repetition's ledgers and trace, and from nothing else: no knob value
reaches it, so a row cannot be labelled by what it was expected to do. The
ledgers say whether there was a second delivery and whether it was
byte-identical; a new JSON-RPC id under the same `messageId` is the SDK resend.
Byte-identical deliveries are separated by parent span ids rather than by
service names, because at step 3 a proxy always sits between the client and the
receiver: two receiver server spans under one parent span id, or under two
parents that are themselves one proxy span, is the gateway, and anything else is
the client's HTTP layer. A second model call is the receiver's if two calls
entered the egress waypoint and the proxy's if one call entered it and was sent
upstream twice. `make test` runs the derivation against committed fixtures in
`experiments/fixtures/derive-layer/`, three of them real gateway retries from
the Task 2 probes.

The `baseline` row asserts rather than assumes: zero `retry:` stanzas across
every HTTPRoute, no `CLIENT_*` on any Deployment, the receiver's model-retry knob
read back off the live object, and the Job rendered with all three client knobs
off. Its injection is one `close` at the model endpoint, as Gate 1's baseline
used, so the failure is raw and any second delivery would be somebody's retry.
Every invocation runs its own one-repetition dry run first, under a scratch work
item whose directory is deleted, and every work-item id carries the run's
wall-clock nonce, because the trace backend and the pod logs both outlive a run.

**A cluster that has been up for a day on a laptop.** ztunnel's workload certificates live 24 hours and, at Istio
1.31.0, are renewed on a timer that does not advance while the Docker Desktop VM is paused by host sleep. Observed
on 2026-09-08: after a day of sleep/wake cycles every mesh hop failed with "certificate expired" while the
agentgateway proxies had renewed their own. Before any mesh run on a cluster older than about a day since `make step-2`,
check `istioctl ztunnel-config certificates --node agent-mesh-lab-worker` and, if `VALID CERT` is false, run
`kubectl -n istio-system rollout restart ds/ztunnel`.

## Working rules

The rules for anyone, or any agent, working in this repository are in `CLAUDE.md`: done means a recorded count; pins come from documents fetched in the session; fixtures never retry; ledgers before agent logic; scope is fixed; the A2A target is v1.0; kind first; one checklist box per task.

## License

Apache License 2.0. See `LICENSE`.

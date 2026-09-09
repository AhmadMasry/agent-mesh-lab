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

The Go binaries are rebuilt by `ko` on every apply, so a change to them reaches
the cluster on the next `make` target or experiment run. **The Python agent is
not**: it is built by Cloud Native Buildpacks under the fixed tag
`orchestrator:dev` and loaded into kind, so changing anything under
`agents/orchestrator/` needs `make orchestrator-image` followed by
`kubectl -n lab rollout restart deployment/orchestrator`. A `kubectl set env` on
that Deployment restarts the pod onto the image already loaded under that tag,
which is the old one; a run that only sets an environment variable will measure
the code that was there before. This was measured the hard way in Gate 2 A.2.

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

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
experiments/           one runnable script per checklist item; cited run outputs under experiments/runs/
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

`experiments/runs/` holds the CSV/JSONL outputs each `findings.md` entry
cites; nothing in that directory is regenerated by reading this README, only
by running the scripts above.

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

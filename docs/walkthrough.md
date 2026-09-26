# Walkthrough — from a deleted cluster to Experiment A

This lab counts what happens to A2A agent traffic when a message is delivered more than once: two agents built on the
two official A2A SDKs, a controllable model endpoint, three ledgers that count every arrival, dispatch and model call,
and Istio Ambient with agentgateway on the path. This walkthrough builds the whole of it from a deleted cluster and
then runs six of Experiment A's rows on it, so that by the end you have counted duplicate deliveries yourself rather
than read about them; the topology it ends at is the figure below.

The build and the six Experiment A rows below were taken from one run on 2026-09-25, 21:49:38Z to 22:13:18Z, **23 min
40 s** end to end, on the author's machine, at the tree of the commit `fix(experiments): the make test guard refuses a
later change to GO_SOURCES_PATHS and a git command kept only in a comment, two committed mutants; gate3-matrix.sh's
stamp comment names the three binaries`, whose record is `experiments/runs/2026-09-25-walkthrough/`. On 2026-09-26 the
same commands were walked again from a deleted cluster, at the tree of the commit `docs(proposal-notes): the walkthrough
extended to every row of Experiments B and C for the author's end-to-end test, decided by the author`, and then every
row of Experiments B and C was run on the cluster they leave standing: that run's record is
`experiments/runs/2026-09-26-walkthrough/` (14:03:08Z to 17:05:15Z, with two steps appended after it), the six A rows
read 74 of 74 cells as their entries again, and the B and C rows are [`walkthrough-b.md`](walkthrough-b.md) and
[`walkthrough-c.md`](walkthrough-c.md), which start where this document ends. This text replaces the walkthrough of
2026-09-20, which lives in git history. Timings are what the 2026-09-25 run observed; yours will differ with your
machine and your network. The 2026-09-25 record holds:

```
logs/                   the unabridged stdout+stderr of every command below, one file per step, in order
timings.csv             each target's and script's start, finish, wall time and exit status
tool-versions.txt       the host's tool versions
cluster-versions.txt    what the finished cluster reports about itself
sleep-events.csv        the host's Sleep, Wake, DarkWake and Maintenance events in the run's window, kinds and
                        stamps only, written by drivers/sleep-events.sh over the windows in windows.csv
reading-notes.txt       where a file of this record reads other than a reader would take it
drivers/                the driver that ran the commands below, the tools block it sourced, and the readers
                        and comparison program named in the record
step-1/ step-2/ step-2b/ step-2c/ step-3/   the readings each step's section quotes
a1-m1-go/ a2-go-http-503/ a3-baseline-go/ a3-r1-go-http/ a3-egress-go/ a3-r2-py-service/
                        one directory per Experiment A row: summary.csv, the row's own control and knob readings,
                        and per work item the three ledgers, the client lines, the scripts' own per-item logs as
                        .txt and (on the A.3 rows) the exported trace and its attribution
rows-vs-entries.txt     the six rows beside the entry that re-measured each at twenty repetitions
cleanup/                the state the run left behind
proof/                  the standard proof taken on the same cluster after the walk
make-test.txt, guard-before-after.txt
                        make test at the built tree, and the Go-sources guard of the commit this run built from,
                        before and after that commit, over its mutants
```

The findings this lab has recorded are in `findings.md`, and each demonstration below is read against the entry that
committed it, by heading. Nothing here adds a finding: this document re-takes counts that are already recorded.

Output blocks are this run's, and this is everything that is done to them. Wall-clock columns that say nothing about
the reading (`AGE`, `UPDATED`, `SERIAL NUMBER`) and a few very wide `-o wide` columns are removed for width; where
rows are left out the block says which rows it keeps or marks the gap `…`; long JSON lines are wrapped. Every quoted
`agw-central` or `ztunnel` log line loses its leading ISO timestamp, as the `ko` block in step 1 says of its own, and
three of them lose fields that are per-run or say nothing about the reading: the `ztunnel` access line in step 2
drops `src.cluster`, `dst.cluster`, `bytes_sent` and `bytes_recv`; the `ztunnel` policy-rejection line in step 2
drops `dst.cluster`, `bytes_sent`, `bytes_recv` and `duration`; and the model-leg line in step 2b drops
`http.version` and `protocol`. Two blocks lose one thing more: the `make ledgers` block in step 1 drops each line's
`ts` field, as its own sentence says, and the step-3 certificate block drops the `NOT BEFORE` column. Nothing else is
cut. The unabridged reading is always in `logs/`, under the step that produced it.

## The topology this walkthrough ends at

```mermaid
flowchart LR
  host["this host<br/>kubectl port-forward"]

  subgraph NSIN["namespace agentgateway-ingress — ambient, ztunnel-captured"]
    ingress["agentgateway-ingress<br/>Gateway proxy"]
  end

  subgraph NSLAB["namespace lab — ambient, ztunnel-captured"]
    job["loadgen / replay Job<br/>sa/loadgen (loadgen)"]
    orch["orchestrator<br/>Python, a2a-python<br/>sa/orchestrator"]
    worker["worker<br/>Go, a2a-go<br/>sa/worker"]
    extauthz["extauthz<br/>authorization fixture,<br/>called by no route here"]
    mock["mockllm<br/>dataplane-mode: none — opted out"]
  end

  subgraph NSWP["namespace agentgateway-waypoint — outside the mesh"]
    central["agw-central<br/>waypoint for both agent Services,<br/>egress for the model host"]
  end

  subgraph NSCP["namespace agentgateway-system — outside the mesh"]
    cp["agentgateway controller<br/>XDS 9978, metrics 9092"]
  end

  subgraph NSTEL["namespace telemetry — outside the mesh"]
    col["otel-collector"]
    jae["jaeger"]
    prom["prometheus"]
  end

  host -->|"out-of-cluster stimulus"| ingress
  ingress -->|"orchestrator-ingress: any host"| orch
  ingress -->|"worker-ingress: Host worker.lab.internal"| worker
  ingress -.->|"GRPCRoutes on 8081:<br/>worker-grpc / orchestrator-grpc .lab.internal"| worker
  ingress -.-> orch
  job -->|"in-cluster stimulus"| central
  orch -->|"forward"| central
  worker -->|"model call"| central
  orch -->|"model call"| central
  central -->|"lab/worker"| worker
  central -->|"lab/orchestrator"| orch
  central -->|"model-via-agw"| mock

  cp -. XDS .-> ingress
  cp -. XDS .-> central
  worker -. spans .-> col
  orch -. spans .-> col
  central -. spans .-> col
  ingress -. spans .-> col
  mock -. spans .-> col
  col --> jae
  prom -. scrapes .-> cp
  prom -. scrapes .-> ingress
  prom -. scrapes .-> central
```

Every agentic L7 hop — the A2A hops and the model calls — is carried by a proxy under agentgateway's own control
plane, and Istio does L4 only: ztunnel capture, identity and mesh-wide STRICT mTLS. That is the author's decision of
2026-09-19 in `docs/proposal-notes.md`. There are two such proxies. The **ingress** takes the out-of-cluster stimulus
and dials the receiver **pod**, on its HTTP routes — `orchestrator-ingress`, which sets no hostname and so matches
everything, and `worker-ingress`, which step 2c adds for `Host: worker.lab.internal` — and, since the REST and gRPC
bindings arrived, on two `GRPCRoute`s to each agent's gRPC port 8081 on hostnames of their own. **`agw-central`** is
everything else: the waypoint for both agent Services, each on a hostname route of its own (`lab/worker`,
`lab/orchestrator`), and the egress for the external-looking host `model.lab.internal` on a third
(`agentgateway-waypoint/model-via-agw`). One internal listener on 8080 receives all three, and the hostname is what
tells them apart.

So an in-cluster message crosses `agw-central` on the receiving Service's route, and both agents' model calls leave
through the same proxy on the model route. The mock behind that route is deliberately outside ambient, because it
stands in for an external provider. `ztunnel` captures the pods of `lab` and `agentgateway-ingress` and nothing else
— the two subgraphs the figure marks — with the mock the one pod inside them that opts out, by the
`istio.io/dataplane-mode: none` on its own template. `agw-central`'s own namespace is not enrolled either: the proxy
terminates HBONE on 15008 itself, under its own SPIFFE identity, which is what agentgateway's Istio ambient egress
page asks for.

The load client, the worker and the orchestrator each run under a ServiceAccount of their own, so each carries its own
mesh identity (`spiffe://cluster.local/ns/lab/sa/loadgen`, `…/sa/worker`, `…/sa/orchestrator`); the mock, the
authorization fixture and the replay harness keep `lab`'s default account. And `lab` holds one Deployment the
experiments below never call: `extauthz`, the lab's external-authorization fixture, which an ingress route consults
only while a run applies a policy that names it. Both are in step 1 and step 2b below.

## Before you start

**Tools.** The README's "Prerequisites and running Experiment A" table lists every tool with the version command that
reads it; `versions.yaml` remains the source of truth for the pins the findings cite. On the host that produced this
document, five rows read other than that table, and none of them is a pin the lab counts against except `istioctl`,
which the block below provides: `kubectl` v1.37.1 against v1.37.0 (the cluster itself runs v1.37.0), `docker` 29.8.0
against 29.7.2, `docker buildx` v0.37.1 against v0.36.1-desktop.1, `uv` 0.12.19 against 0.12.12, and `istioctl` 1.31.1
against 1.31.0. Everything this document counts held on those. The whole reading is
[`experiments/runs/2026-09-25-walkthrough/tool-versions.txt`](../experiments/runs/2026-09-25-walkthrough/tool-versions.txt).

**istioctl and Helm, scoped to this shell.** `make step-2` reads `istioctl version --remote=false` and refuses anything
that is not `1.31.1`, and Istio, the agentgateway control plane and the three telemetry components install by Helm and
by no other route. Both are set up for the shell you run this walkthrough in, and nothing else on your machine changes:
the block fetches istioctl 1.31.1 and the checksum file the release publishes beside it, extracts the binary only if
the two agree, puts it first on this shell's `PATH`, and gives Helm an empty repository scope of its own — an empty
repository list, an empty repository cache and an empty cache directory — so no repository or cached index of your
own Helm setup takes part, and the charts come from the `--repo` URLs and the OCI references the Makefile names. It
scopes those three settings only: `HELM_CONFIG_HOME`, `HELM_DATA_HOME` and `HELM_REGISTRY_CONFIG` are not set, so
your own Helm plugins and registry configuration still apply, the latter to the two OCI charts. Run it from the
repository root, in the shell you will keep using:

```
LAB_TOOLS="${TMPDIR:-/tmp}/agent-mesh-lab-tools"
ISTIOCTL_ASSET=istioctl-1.31.1-osx-arm64.tar.gz
mkdir -p "$LAB_TOOLS/helm/config" "$LAB_TOOLS/helm/cache/repository"
curl -fsSL -o "$LAB_TOOLS/$ISTIOCTL_ASSET" "https://github.com/istio/istio/releases/download/1.31.1/$ISTIOCTL_ASSET"
curl -fsSL -o "$LAB_TOOLS/$ISTIOCTL_ASSET.sha256" "https://github.com/istio/istio/releases/download/1.31.1/$ISTIOCTL_ASSET.sha256"
want=$(cut -d' ' -f1 "$LAB_TOOLS/$ISTIOCTL_ASSET.sha256")
got=$(shasum -a 256 "$LAB_TOOLS/$ISTIOCTL_ASSET" | cut -d' ' -f1)
[ -n "$want" ] && [ "$want" = "$got" ] && echo "checksum ok: $got" && tar -xzf "$LAB_TOOLS/$ISTIOCTL_ASSET" -C "$LAB_TOOLS"
export PATH="$LAB_TOOLS:$PATH"
: > "$LAB_TOOLS/helm/config/repositories.yaml"
export HELM_REPOSITORY_CONFIG="$LAB_TOOLS/helm/config/repositories.yaml"
export HELM_REPOSITORY_CACHE="$LAB_TOOLS/helm/cache/repository"
export HELM_CACHE_HOME="$LAB_TOOLS/helm/cache"
istioctl version --remote=false
```

```
checksum ok: 3f37edda91e51a5948d688681c9db64971ee3abb38cda65d797dec51f46fecd1
client version: 1.31.1
```

`osx-arm64` is this host's asset. The 1.31.1 release lists `istioctl-1.31.1-osx-amd64.tar.gz`,
`istioctl-1.31.1-linux-amd64.tar.gz`, `istioctl-1.31.1-linux-arm64.tar.gz` and `istioctl-1.31.1-linux-armv7.tar.gz`
beside it, each with its own `.sha256`; set `ISTIOCTL_ASSET` to yours. The block needs `shasum`; on a host without
it the comparison fails, no `checksum ok` line prints, and nothing is extracted. If no `checksum ok` line prints, for
that or any other reason, do not go on. The block uses no `helm repo add` and no `helm repo update`, and it leaves your own Helm
configuration and cache as they were. `helm` itself must be on `PATH` before `make step-2`: without it a `make`
command line naming `step-2` or `step-3` — the two goals whose recipes call helm — stops while make reads the
Makefile, so no goal on that line runs. Docker Desktop must be running before `make cluster-kind`, or kind's API server
refuses connections.

**kind first.** Every step here runs on a two-node kind cluster. EKS enters only on one of the four triggers in
`docs/PROPOSAL.md` §5, and no overlay in `deploy/` names a cluster type.

**Your machine has to stay awake.** The longer steps run for a minute or two each and the whole walkthrough for about
twenty-five minutes, and a Docker Desktop VM paused by host sleep stops `ztunnel`'s certificate-renewal timer along
with everything else — a timer that, once it is late, stays late until ztunnel restarts. Nothing in this repository
starts a keep-awake or changes a power setting, and this run's scripts and commands started none: keep the machine
awake yourself. What the host's own power log holds for this run's window is counted rather than asserted, in
[`sleep-events.csv`](../experiments/runs/2026-09-25-walkthrough/sleep-events.csv): Sleep 0, Wake 0, DarkWake 0 and
Maintenance 0 in the window 21:49:38Z..22:13:18Z. That record carries those four kinds of event and their counts and
nothing else from the log. This run started no keep-awake and changed no power setting; keep-awake is not claimed
absent.

**One thing `ko` will tell you, which is not an error.** Every step target that builds images prints

```
git is in a dirty state
Please check in your pipeline what can be changing the following files:
?? experiments/runs/2026-09-25-walkthrough/
```

as soon as the tree holds any untracked or modified file — including the run outputs the scripts you are about to run
write into it, which is what the `??` line is: this run printed the name of its own run directory, and yours will
print `experiments/runs/my-walkthrough/`. It is `ko`'s VCS stamping, and it did not change any count here. It does
change the digest of what `ko` builds: Go stamps whether the tree was modified into the binary, so the worker and the
mock built at step 1, from a clean tree, and rebuilt at step 2b carry different digests from the same sources — the
Makefile's `GO_SOURCES_HASH` comment says why the lab's freshness check hashes the sources rather than the image. It
is not the same check as `check-go-sources-clean`, which is a prerequisite of every step target and looks only at the
Go paths the image stamp hashes (`agents/worker`, `fixtures/mockllm`, `fixtures/extauthz`, `internal`, `go.mod`,
`go.sum`, test files excluded); that one refuses to run at all while those paths carry uncommitted changes.

**Where the outputs go.** The experiment scripts take `RUN_ITEM`, which names a directory under `experiments/runs/`.
Every command below passes `RUN_ITEM=my-walkthrough/…`, a name **no committed record uses**: what you run is
yours, it lands in `experiments/runs/my-walkthrough/`, and it is untracked, so `git status` will show that one new
directory and — until you restore them — the two files the determinism check in step 1 overwrites, and nothing
else. The readings quoted in this document came from the same commands run under
`experiments/runs/2026-09-25-walkthrough/`, which is committed and which nothing here writes to. Do not point
`RUN_ITEM` at a dated directory under `experiments/runs/`: those hold the outputs a `findings.md` entry cites,
and a run into one overwrites the record it cites. The Cleanup section says what to do with your directory
afterwards.

The commands also take `RUN_ID`, a nonce that every work-item id carries, because pod logs outlive a run and a
repeated id would collect an earlier run's lines as if they were this run's. The nonces below are this run's, so
the work-item ids in the outputs are reproducible; change them if you run a step twice.

Run everything from the repository root, in the shell the tools block above set up, and when a step below writes a
file outside the repository it takes the directory from the environment — `"${TMPDIR:-/tmp}"` — rather than naming
one.

## Step 0 — delete the cluster, then create it

```
make teardown
make cluster-kind
kubectl wait --for=condition=Ready nodes --all --timeout=180s
kubectl get nodes
```

`make teardown` took **1.6 s** and `make cluster-kind` **19.9 s**. Two nodes on `kindest/node:v1.37.0`, pinned by
digest in `kind-config.yaml`, both Ready within about eleven seconds of creation:

```
NAME                           STATUS   ROLES           AGE   VERSION
agent-mesh-lab-control-plane   Ready    control-plane   26s   v1.37.0
agent-mesh-lab-worker          Ready    <none>          12s   v1.37.0
```

`make cluster-kind` creates the cluster and nothing else: no lab image is loaded and no namespace of this lab's exists
yet.

## Step 1 — three images, no mesh

```
make step-1
```

**58.6 s** on this run. It does three things in order. `check-go-sources-clean` refuses to go on while the hashed Go
paths carry uncommitted changes. `orchestrator-image` builds the Python agent with
`docker build --pull --no-cache --platform linux/$(go env GOARCH) -t orchestrator:dev -f
agents/orchestrator/Dockerfile agents/orchestrator` — the platform follows this host's Go toolchain, which read
`arm64` here — and loads it into kind: three stages on Amazon Linux 2023, a `FROM scratch` final image with no
shell, running as uid 65532, with the OpenTelemetry launcher as its `CMD`. Then
`kubectl kustomize deploy/step-1-nomesh | … ko apply` builds **two** Go binaries on
`gcr.io/distroless/static-debian13:nonroot` — the worker and the mock, the two the step-1 overlay carries a
`ko://` reference for — loads them, rolls the three Deployments, and stamps the two Go Deployments with the source
hash the later freshness guard reads. The other three Go binaries this lab builds are not built here: the
authorization fixture from step 2b on, and the load client and the replay harness each time an experiment script
pipes its Job through `ko apply`, so the first of those appears in the clean check below.

What `ko` printed, whole — the base digest it resolved for each of the two, and the digest it built and loaded for
each (timestamps removed; `ko` builds the two concurrently, so the order of these lines is not fixed):

```
Using base gcr.io/distroless/static-debian13:nonroot@sha256:e2e927ec666bae08560abb3c55d0659eceabb657f56b6782ab500a9fc7f555e3 for github.com/AhmadMasry/agent-mesh-lab/agents/worker
Using base gcr.io/distroless/static-debian13:nonroot@sha256:e2e927ec666bae08560abb3c55d0659eceabb657f56b6782ab500a9fc7f555e3 for github.com/AhmadMasry/agent-mesh-lab/fixtures/mockllm
Building github.com/AhmadMasry/agent-mesh-lab/agents/worker for linux/arm64/v8
Building github.com/AhmadMasry/agent-mesh-lab/fixtures/mockllm for linux/arm64/v8
Loading kind.local/mockllm-d7e8f9e58ff4838298fc2d1892c03051:d8ff352b51aa5ff5a2ecf195601c9c04c869110d024d97d67baa87a7df1ff58d
Loading kind.local/worker-918a018b7a581926ead34dec2ba0fb83:6b5d10a2ec1edf227f4785f798ec256219ab6e60841edf0f8b9bb549b87bec16
```

```
kubectl -n lab get deploy,svc,pods -o wide
kubectl -n lab get serviceaccounts
```

Abridged to the columns that matter here — the images `ko` and `docker` just built, the ports, where each pod
landed, and the accounts:

```
NAME                           READY   UP-TO-DATE   AVAILABLE   CONTAINERS     IMAGES
deployment.apps/mockllm        1/1     1            1           mockllm        kind.local/mockllm-d7e8f9e5…
deployment.apps/orchestrator   1/1     1            1           orchestrator   orchestrator:dev
deployment.apps/worker         1/1     1            1           worker         kind.local/worker-918a018b…

NAME                   TYPE        CLUSTER-IP      PORT(S)
service/mockllm        ClusterIP   10.96.179.73    8080/TCP
service/orchestrator   ClusterIP   10.96.98.1      8080/TCP,8081/TCP
service/worker         ClusterIP   10.96.249.127   8080/TCP,8081/TCP

NAME                                READY   STATUS        IP           NODE
pod/mockllm-955d9d655-cx8xq         1/1     Running       10.244.1.2   agent-mesh-lab-worker
pod/orchestrator-6f86bb6dd-g6m8w    1/1     Running       10.244.1.5   agent-mesh-lab-worker
pod/orchestrator-78fdcfd784-d6694   1/1     Terminating   10.244.1.3   agent-mesh-lab-worker
pod/worker-8564464f7-vpnxd          1/1     Running       10.244.1.4   agent-mesh-lab-worker

NAME           AGE
default        4s
loadgen        4s
orchestrator   4s
worker         4s
```

Three Deployments, three Services, no mesh, no gateway. The fourth pod is the orchestrator's first, terminating: the
overlay creates the Deployment and `orchestrator-image` then rolls it onto the image it has just loaded, so a read
taken this soon catches the old one on its way out. Full reading:
[`step-1/after-step-1.txt`](../experiments/runs/2026-09-25-walkthrough/step-1/after-step-1.txt).

Two things in that read are newer than the lab's first walkthrough. Both agent Services carry a second port, **8081**:
each agent serves the REST binding on its JSON-RPC port 8080 and the gRPC binding on 8081, beside JSON-RPC, and
advertises all three on its card (`## Experiment C / both receivers / D-2, the REST and gRPC bindings rebuilt`). Every
experiment in this walkthrough sends JSON-RPC. And `lab` holds three **ServiceAccounts** besides `default` — one for
the load client, one for the worker, one for the orchestrator, each with token automount off. They are in the base
overlay, rendered from step 1, because the load client's Job templates are rendered at every step and a pod that names
an absent account is not created. Under ambient they give the three workloads three mesh identities, where every lab
workload had `lab/sa/default` until then; step 2 shows them
(`## Experiment C / both receivers / D-4, the rebuild with three ServiceAccounts`).

### Is the model endpoint deterministic?

Every count later in this document rests on the model endpoint answering the same way twice and failing exactly when
it is told to, so that is the first thing to check.

```
experiments/gate1-mockllm-deterministic.sh
```

**16.9 s.** It sends twenty identical requests and hashes each answer, then arms a `close` at invocation count 5 and
sends six, then arms a `close` keyed to the work item `det-003` and sends two of those and two of `det-004`:

```
identical_hashes,latency_min_ms,latency_max_ms,count_injection_fired_at,lwi_injection_hits_det003,lwi_injection_hits_det004
20,200.101,203.698,5,2,0
```

Twenty identical answers; the count-keyed injection fired at request 5 and nowhere else; the work-item-keyed one fired
on both `det-003` requests and on neither `det-004` request. Read against
`## Gate 1 / mockllm / deterministic`, the four counts — `20`, `5`, `2`, `0` — are the committed ones exactly. The two
latency cells are wall-clock measurements of the mock's fixed 200 ms, not counts; the committed pair is 200.264 and
209.447 ms and both runs sit inside 200–210 ms. This run's `summary.csv` and `invocation.jsonl` are copied to
[`step-1/mockllm-deterministic/`](../experiments/runs/2026-09-25-walkthrough/step-1/mockllm-deterministic/).

Two things about that script the reader meets here and nowhere else in the document.

It **writes into a committed run directory.** Its `RUN_DIR` is fixed to
`experiments/runs/2026-09-05-mockllm-deterministic/`, the directory the Gate 1 entry cites, so running it overwrites
that entry's two committed files and `git status` will say so. Put them back when you are done:

```
git checkout -- experiments/runs/2026-09-05-mockllm-deterministic/
```

And it **leaves an injection armed at the mock.** A work-item-keyed injection fires on every call for that id rather
than once — which is what `lwi_injection_hits_det003 = 2` above is measuring — so when the script returns, the mock is
still armed to close the connection on any call attributed to `det-003`. Nothing this walkthrough sends afterwards
carries that id, and every script below resets the mock before it sends anything, so it costs nothing here; the
cleanup section at the end resets it explicitly all the same.

### The first message, and the ledgers

```
RUN_ID=wt1 RUN_ITEM=my-walkthrough/step-1/clean experiments/gate2-single-clean.sh
```

**45.3 s.** One clean `SendMessage` per receiver, with both receivers' injectors and the mock reset before each and
again after the run, so this measures the instruments rather than a failure:

```
receiver,work_item,deliveries,received,executes,tasks_created,invocations,client_result
worker,g2c-wt1-worker,1,1,1,1,1,task/TASK_STATE_COMPLETED
orchestrator,g2c-wt1-orchestrator,1,1,1,1,1,task/TASK_STATE_COMPLETED
```

`1/1/1/1/1` and `TASK_STATE_COMPLETED` on both receivers, which is what
`## Gate 2 / instruments / single clean request` records and what every rebuild since has re-counted.

Now read the ledgers for one of those work items. This is the shape everything later is counted in:

```
make ledgers LWI=g2c-wt1-worker
```

Ten lines, in the five sections `make ledgers` prints: the lab's three instruments, the client's own lines, and the
authorization fixture's decision ledger, empty here. Trimmed to the fields that matter, and with the section headers
`make ledgers` writes to stderr kept for orientation:

```
## ingress
{"ledger":"ingress","phase":"arrival","ts_arrival":"2026-09-25T21:51:51.620505669Z","remote":"10.244.1.8:47480",
 "method":"SendMessage","id":"6b554285-1f33-4fce-b7d5-a8b71952c8a1",
 "messageId":"01a0da8d-a744-757c-8415-7b1bc519f91d","taskId":"","logical_work_item_id":"g2c-wt1-worker",
 "a2a_version":"1.0","content_type":"application/json",
 "body_sha256":"5e4ade8f04a8d8c92852ea987d725348149ab2eb5d21aeb185a23d3ff60fc002",
 "body_len":276,"source":"worker"}
{"ledger":"ingress","phase":"response", … ,"status":200,"source":"worker"}

## execution
{"ledger":"execution","event":"received","method":"SendMessage","messageId":"01a0da8d-a744-757c-8415-7b1bc519f91d",
 "taskId":"","logical_work_item_id":"g2c-wt1-worker","source":"worker"}
{"ledger":"execution","event":"execute","messageId":"01a0da8d-a744-757c-8415-7b1bc519f91d",
 "taskId":"01a0da8d-a744-7990-a099-bd7025ba5e9b","contextId":"01a0da8d-a744-7a06-972a-bab4a2672ae4", … }
{"ledger":"execution","event":"state", … ,"state":"TASK_STATE_SUBMITTED", … }
{"ledger":"execution","event":"state", … ,"state":"TASK_STATE_WORKING", … }
{"ledger":"execution","event":"state", … ,"state":"TASK_STATE_COMPLETED", … }
{"ledger":"execution","event":"result","method":"SendMessage", … ,"result_kind":"task",
 "state":"TASK_STATE_COMPLETED", … }

## invocation
{"ledger":"invocation","logical_work_item_id":"g2c-wt1-worker",
 "messageId":"01a0da8d-a744-757c-8415-7b1bc519f91d","taskId":"01a0da8d-a744-7990-a099-bd7025ba5e9b",
 "caller":"worker","body_sha256":"e973f4af…","stream":false,"injection":"none","outcome":"ok",
 "latency_ms":200.114,"source":"mockllm"}

## client
{"ledger":"client","attempt":1,"logical_work_item_id":"g2c-wt1-worker",
 "messageId":"01a0da8d-a744-757c-8415-7b1bc519f91d","taskId":"01a0da8d-a744-7990-a099-bd7025ba5e9b",
 "result_kind":"task","state":"TASK_STATE_COMPLETED","a2a_version":"1.0",
 "card_protocol_versions":["1.0","1.0","1.0"],
 "advertised_urls":["http://worker.lab.svc.cluster.local:8080","http://worker.lab.svc.cluster.local:8080",
                    "worker.lab.svc.cluster.local:8081"],
 "dialled_url":"http://worker.lab.svc.cluster.local:8080","source":"loadgen"}

## extauthz
```

What each one is for:

- **ingress** — the pre-dispatch ledger. It sits at the HTTP/JSON-RPC boundary *before* the A2A SDK sees the request,
  as middleware, so an arrival is counted even when the request is refused before dispatch. It carries the JSON-RPC
  `id`, the A2A `messageId`, the body's SHA-256 and length, the arrival time and the `A2A-Version` the caller sent —
  `1.0` here, which is the target. Two lines per request: the arrival, and the response with its status.
- **execution** — what the SDK actually did. `received` is the SDK's entry, `execute` the executor's own entry (a
  *dispatch* means the executor ran, not that the SDK accepted a request), then one `state` line per Task state and a
  `result`. The `taskId` appears first on the `execute` line, because the Task is created there.
- **invocation** — the model endpoint's own ledger, one line per call, carrying the work item and the `taskId` that
  caused it, the injection that was armed, the outcome and the latency. Here the `taskId` is exactly the one the
  `execute` line minted, so the model call is attributable to its own Task.
- **client** — not one of the three instruments: it is what the caller itself recorded, written by the load client,
  one line per attempt. `make ledgers` collects it from the Job's pod log so that a work item can be read from both
  ends at once. A caller that writes no such line — `curl`, in step 2b below — simply has no client section.
- **extauthz** — the authorization fixture's decision ledger, one line per check it answers, written before it
  answers. The fixture's Deployment does not exist until step 2b, and no route in this walkthrough consults it, so
  this section is empty on every work item here.

Two fields on that client line are worth separating. `card_protocol_versions` is what the agent card advertised, one
entry per interface — the card lists three, JSON-RPC first — and `a2a_version` is the value the load client's SDK put
on the wire. The header the receivers' ingress ledgers record is that value: `1.0` on all 45 arrivals and 45
responses this run's ingress ledgers hold (33 at the worker, 12 at the orchestrator), which is what
`## Gate 3 / both receivers / the pins of 2026-09-25` read from real requests at a2a-go v2.6.0 and a2a-python 1.1.5.
The last two fields are the load client's own addressing: `advertised_urls` is what the card offered and
`dialled_url` is where the POST actually went. The POST goes to the first, the JSON-RPC interface, on every row of
this walkthrough but the A.3 row that sets `CLIENT_DIAL=target`.

The `logical_work_item_id` is minted by the client and joins all of them: it travels in `Message.metadata`, as an
`lwi:<id>` token in the message text, and as the `X-Logical-Work-Item-Id` header on the model call. One logical work
item can become several A2A messages and several deliveries; the whole method is counting how many of each it became.

These files are committed per work item under
[`step-1/clean/g2c-wt1-worker/`](../experiments/runs/2026-09-25-walkthrough/step-1/clean/g2c-wt1-worker/).

## Step 2 — Istio Ambient by Helm, STRICT, and the one central proxy

```
make step-2
```

**113.8 s.** Gateway API CRDs v1.6.2 from the **experimental** channel (that is where `HTTPRoute.retry` lives), then
the four Istio charts at 1.31.1 in the order the ambient Helm page installs them — `base`, `istiod` with
`istio-values.yaml`, `cni` with `profile=ambient`, `ztunnel` with `ztunnel-values.yaml` — then the two agentgateway
OCI charts at `v1.5.0` from `oci://cr.agentgateway.dev/charts`, which install that project's own control plane into
`agentgateway-system`, and then the overlay: the `lab` namespace labelled ambient, a mesh-wide STRICT
`PeerAuthentication` in `istio-system`, the Gateway `agw-central` in its own unenrolled namespace
`agentgateway-waypoint`, the worker Service bound to it, and the `worker` HTTPRoute. The three agents are restarted
last, because `ztunnel` captures a pod when it starts and these predate the label.

```
helm list -A
```

```
NAME             	NAMESPACE          	REVISION	STATUS  	CHART                   	APP VERSION
agentgateway     	agentgateway-system	1       	deployed	agentgateway-v1.5.0     	v1.5.0
agentgateway-crds	agentgateway-system	1       	deployed	agentgateway-crds-v1.5.0	v1.5.0
istio-base       	istio-system       	1       	deployed	base-1.31.1             	1.31.1
istio-cni        	istio-system       	1       	deployed	cni-1.31.1              	1.31.1
istiod           	istio-system       	1       	deployed	istiod-1.31.1           	1.31.1
ztunnel          	istio-system       	1       	deployed	ztunnel-1.31.1          	1.31.1
```

### What ztunnel sees

```
istioctl ztunnel-config workloads
```

The rows of the three namespaces this step creates or enrols:

```
NAMESPACE             POD NAME                         ADDRESS     NODE                    WAYPOINT PROTOCOL
agentgateway-system   agentgateway-864d45549-hlbgv     10.244.1.13 agent-mesh-lab-worker   None     TCP
agentgateway-waypoint agw-central-5cb98f5c87-rr8fk     10.244.1.19 agent-mesh-lab-worker   None     TCP
lab                   mockllm-66d7d7d8df-nlx5g         10.244.1.17 agent-mesh-lab-worker   None     TCP
lab                   orchestrator-58cbd485d5-n9sd9    10.244.1.16 agent-mesh-lab-worker   None     HBONE
lab                   worker-7979d94d88-f9nz7          10.244.1.18 agent-mesh-lab-worker   None     HBONE
```

Both agents read `HBONE`: they are captured. The mock reads `TCP` because it carries
`istio.io/dataplane-mode: none` — it stands in for an external provider, so the model route's call to it is this
lab's external plaintext leg. `agw-central` reads `TCP` because its namespace is not enrolled at all: an
agentgateway proxy terminates HBONE under its own identity, and agentgateway's ambient egress page says to leave
that namespace unlabelled for exactly that reason. The controller reads `TCP` for the same reason as its own
namespace: it is infrastructure, not a traffic path.

The binding is on the **Service**, not the pod, and it takes two labels because the proxy is in another namespace:

```
kubectl -n lab get svc worker -o jsonpath='{.metadata.labels}'
```

```
{"app":"worker","istio.io/use-waypoint":"agw-central","istio.io/use-waypoint-namespace":"agentgateway-waypoint"}
```

### The certificates

```
istioctl ztunnel-config certificates --node agent-mesh-lab-worker
```

```
CERTIFICATE NAME                                  TYPE     STATUS        VALID CERT     NOT AFTER                NOT BEFORE
spiffe://cluster.local/ns/lab/sa/orchestrator     Leaf     Available     true           2026-10-02T21:54:04Z     2026-09-25T21:52:04Z
spiffe://cluster.local/ns/lab/sa/orchestrator     Root     Available     true           2036-09-22T21:53:10Z     2026-09-25T21:53:10Z
spiffe://cluster.local/ns/lab/sa/worker           Leaf     Available     true           2026-10-02T21:54:04Z     2026-09-25T21:52:04Z
spiffe://cluster.local/ns/lab/sa/worker           Root     Available     true           2036-09-22T21:53:10Z     2026-09-25T21:53:10Z
```

One leaf per ServiceAccount of a captured pod on the node: the worker's and the orchestrator's, each its own identity.
ztunnel holds a certificate only for an account one of its pods runs as, so the load client's account has none until
a load Job's pod is running, and the mock, opted out, has none at all. Seven days on each leaf, by the author's
decision of 2026-09-12, which takes two settings rather than one: `pilot.env.DEFAULT_WORKLOAD_CERT_TTL` in
`istio-values.yaml` and, the operative one for a ztunnel leaf, `env.SECRET_TTL` in `ztunnel-values.yaml`. This is the
check to run before any mesh run on a cluster that has been standing: ztunnel computes each renewal deadline on a clock
that does not advance while the host sleeps, so on a laptop this reads `false` sooner than the lifetime suggests, and
the remedy is `kubectl -n istio-system rollout restart ds/ztunnel`, recorded. `make step-3` and every experiment script
run it first, and require both the worker's and the orchestrator's leaf to read `true`.

### The same message, and who carried it

```
RUN_ID=wt2 RUN_ITEM=my-walkthrough/step-2/clean experiments/gate2-single-clean.sh
```

**45.2 s**, and the identical counts — `1,1,1,1,1` and `TASK_STATE_COMPLETED` on both receivers. The ledgers do not
change when a mesh appears under them; what changes is who carried the bytes:

```
kubectl -n agentgateway-waypoint logs deploy/agw-central | grep 'http.path=/ ' | head -1
kubectl -n istio-system logs -l app=ztunnel --tail=-1 | grep 'loadgen-g2c-wt2-worker' | grep access
```

```
info request gateway=agentgateway-waypoint/agw-central listener=inner-http route=lab/worker
  endpoint=10.244.1.18:8080 src.addr=10.244.1.21:48716 src.identity=spiffe://cluster.local/ns/lab/sa/loadgen
  http.method=POST http.host=worker.lab.svc.cluster.local http.path=/ http.version=HTTP/1.1 http.status=200
  trace.id=34de63d42fbac0b25fe535a1593b373f span.id=abc35cd4b8e29f9c protocol=http duration=208ms

info access connection complete src.addr=10.244.1.21:46468 src.workload="loadgen-g2c-wt2-worker-nq6cw"
  src.namespace="lab" src.identity="spiffe://cluster.local/ns/lab/sa/loadgen"
  dst.addr=10.244.1.19:15008 dst.hbone_addr=10.96.249.127:8080 dst.service="worker.lab.svc.cluster.local"
  dst.workload="agw-central-5cb98f5c87-rr8fk" dst.namespace="agentgateway-waypoint"
  dst.identity="spiffe://cluster.local/ns/agentgateway-waypoint/sa/agw-central" direction="outbound"
  duration="257ms"
```

Read the two together: `ztunnel` tunnelled the load Job's connection to **`agw-central`** on port 15008, both ends
named by SPIFFE identity — the load client's own, `lab/sa/loadgen`, and the proxy's own rather than a namespace
default — and the proxy then made the L7 hop to the worker pod on route `lab/worker`, naming the same caller in its
`src.identity`. Which layer can see which of the three identities, and act on it, is what
`## Experiment C / both receivers / D-4, the identity re-reading` records. Both lines are in
[`step-2/access-logs.txt`](../experiments/runs/2026-09-25-walkthrough/step-2/access-logs.txt).

### Plaintext is refused

mTLS is enforced here, not merely available, and the test is a pod outside the mesh asking a mesh workload for its
agent card — a plain unauthenticated GET, so a refusal is the transport refusing rather than the application.

```
kubectl -n default run mtls-probe --image=curlimages/curl:8.22.0 --restart=Never --command -- sleep 300
kubectl -n default wait --for=condition=Ready pod/mtls-probe --timeout=90s
kubectl -n default exec mtls-probe -- curl -sS -o /dev/null -w 'http=%{http_code} exit=%{exitcode}\n' --retry 0 \
  --connect-timeout 5 --max-time 10 http://worker.lab.svc.cluster.local:8080/.well-known/agent-card.json
```

```
curl: (56) Recv failure: Connection reset by peer
http=000 exit=56
command terminated with exit code 56
```

The same for `orchestrator.lab.svc.cluster.local`. `ztunnel` names the policy that refused it:

```
kubectl -n istio-system logs -l app=ztunnel --tail=-1 | grep 'policy rejection' | tail -2
```

It prints two, one per receiver. The worker's, from this run:

```
error access connection complete src.addr=10.244.1.23:33266 dst.addr=10.244.1.18:8080
  dst.service="worker.lab.svc.cluster.local" dst.workload="worker-7979d94d88-f9nz7" dst.namespace="lab"
  direction="inbound"
  error="connection closed due to policy rejection: explicitly denied by: istio-system/istio_converted_static_strict"
```

`curl` exit 56 with no status is what `## Gate 3 / both receivers / mTLS enforced` records for this probe, and what
every rebuild since has re-counted. What the line will carry and what it may not: the destination workload, the
`direction="inbound"` and the policy name are the reading, and they are always there; the **source** fields are
not. `src.workload`, `src.namespace` and `src.cluster` are ztunnel's own attribution of a pod it has to have
learned about, and on a prober created a second earlier it has not — this run printed both lines with `src.addr=`
alone and no source workload at all. Nothing the probe measures depends on them. Remove the prober when you are done:

```
kubectl -n default delete pod mtls-probe
```

## Step 2b — the ingress, the model host on `agw-central`, and the authorization fixture

```
make step-2b
```

**57.5 s.** The overlay adds the ingress Gateway in its own ambient namespace `agentgateway-ingress`, its
catch-all route to the orchestrator, a `ServiceEntry`, an `AgentgatewayBackend` and an HTTPRoute for
`model.lab.internal` on `agw-central`, both agents' `MODEL_BASE_URL` pointed at that host, the orchestrator's card
pointed at the ingress for its JSON-RPC and REST interfaces and for its gRPC one, a port-level PERMISSIVE exception for
the ingress pod's metrics port 15020 (Prometheus runs outside the mesh and its scrape is plaintext into a captured
pod), and the authorization fixture.

```
kubectl get gateway -A
kubectl get ns -L istio.io/dataplane-mode
```

```
NAMESPACE               NAME                   CLASS          ADDRESS        PROGRAMMED
agentgateway-ingress    agentgateway-ingress   agentgateway   10.96.58.152   True
agentgateway-waypoint   agw-central            agentgateway   10.96.18.93    True

NAME                    STATUS   DATAPLANE-MODE
agentgateway-ingress    Active   ambient
agentgateway-system     Active
agentgateway-waypoint   Active
lab                     Active   ambient
…                                (default, istio-system, kube-*, local-path-storage: no label)
```

Two Gateways, one class, and only two of these namespaces are enrolled. Read that table with the diagram:
`agentgateway-system` holds the **controller** only and is not enrolled — it is infrastructure rather than the traffic
path, and two of its three clients speak plaintext to it from outside the mesh. `agentgateway-waypoint` holds
`agw-central`, and is unlabelled because agentgateway's egress page says a proxy that terminates HBONE itself must
not also be captured. The ingress **proxy** has a namespace of its own and **is** enrolled, which is what the
agentgateway ambient-ingress page asks for. Getting this last one wrong is how a from-scratch rebuild failed on
2026-09-12: with the controller captured, `ztunnel` refused Prometheus's scrape of it under STRICT and the other
proxy's XDS dial was reset, and the running cluster had hidden it because that stream predated the policy.

The step also moves both agents' model endpoint:

```
kubectl -n lab get deploy orchestrator worker -o json | jq -r '.items[] | .metadata.name + ": " +
  ([.spec.template.spec.containers[0].env[]? | select(.name=="MODEL_BASE_URL" or .name=="PUBLIC_URL") |
  "\(.name)=\(.value)"] | join(" "))'
```

```
orchestrator: MODEL_BASE_URL=http://model.lab.internal:8080/v1 PUBLIC_URL=http://agentgateway-ingress.agentgateway-ingress.svc.cluster.local
worker: MODEL_BASE_URL=http://model.lab.internal:8080/v1 PUBLIC_URL=http://worker.lab.svc.cluster.local:8080
```

### The authorization fixture

```
kubectl -n lab get deploy,svc extauthz -o wide
```

```
NAME                       READY   UP-TO-DATE   AVAILABLE   CONTAINERS   IMAGES
deployment.apps/extauthz   1/1     1            1           extauthz     kind.local/extauthz-a6fd0adf…

NAME               TYPE        CLUSTER-IP      PORT(S)
service/extauthz   ClusterIP   10.96.105.167   9000/TCP
```

`extauthz` is an external-authorization server written in this repository, under `fixtures/extauthz/`, speaking the
gRPC protocol agentgateway calls for an external authorization check. It holds one rule — refuse `SubscribeToTask`,
allow every other operation — read from what the proxy sends it on each of the three bindings, and it writes a
decision line before every answer, which is the fifth section `make ledgers` prints. It stands from this step on, in
`lab`, enrolled like the agents, its port marked for HTTP/2 in plaintext; the ingress pod's dial to it therefore leaves
through ztunnel under STRICT like any other. It is **called by no route** in this walkthrough: a run that measures it
applies an `AgentgatewayPolicy` naming it from that run's own directory and removes it afterwards, and none of the
commands here does. It is a fixture of Experiment C, recorded in
`## Experiment C / both receivers / D-3, an external authorizer on each binding` and
`## Experiment C / both receivers / D-3b, the authorization fixture over every shape the receivers dispatch`; it is
shown here because you will meet it in every listing from now on. Its Deployment is stamped with the same Go-source
hash as the worker's and the mock's.

### The model leg

```
RUN_ID=wt2b RUN_ITEM=my-walkthrough/step-2b/clean experiments/gate2-single-clean.sh
kubectl -n agentgateway-waypoint logs deploy/agw-central | grep chat/completions | tail -2
```

**46.1 s**, counts unchanged at `1,1,1,1,1` `TASK_STATE_COMPLETED` on both receivers, and the model call now leaves
through `agw-central` on the model route. The `grep` prints two lines, **one per work item the clean check sent, not
one per agent**: both are the worker's, from the same `src.addr` and under the worker's own identity, because the
orchestrator is deployed in forward mode and the worker is the one that calls the model — which is what the
out-of-cluster ledgers below show line by line. The first is the worker's own work item:

```
info request gateway=agentgateway-waypoint/agw-central listener=inner-http
  route=agentgateway-waypoint/model-via-agw endpoint=mockllm.lab.svc.cluster.local:8080
  src.addr=10.244.1.26:43482 src.identity=spiffe://cluster.local/ns/lab/sa/worker http.method=POST
  http.host=model.lab.internal http.path=/v1/chat/completions http.status=200 duration=203ms
```

The `route=` is the whole point of the topology: one proxy, one listener, and the route name is what says this was
the model leg and not an agent leg. The route carries no `retry` stanza; every route in this lab is retry-free in
its baseline state, and that is asserted rather than assumed before every measured row. The mock's own invocation
lines for the same two work items both name `caller: worker` and the `taskId` the worker's executor minted
([`step-2b/model-leg.txt`](../experiments/runs/2026-09-25-walkthrough/step-2b/model-leg.txt)).

### The out-of-cluster path, and the card lesson

Open a tunnel to the ingress and read the orchestrator's agent card from this host. `port-forward` runs in the
foreground until it is interrupted, so give it a terminal of its own — or append `&` and keep the job id to kill
afterwards — and run everything that follows in the first terminal:

```
kubectl -n agentgateway-ingress port-forward svc/agentgateway-ingress 18080:80
```

```
curl -s http://127.0.0.1:18080/.well-known/agent-card.json | jq -c '{name, supportedInterfaces}'
```

```
{"name":"orchestrator","supportedInterfaces":[
 {"url":"http://agentgateway-ingress.agentgateway-ingress.svc.cluster.local","protocolBinding":"JSONRPC","protocolVersion":"1.0"},
 {"url":"http://agentgateway-ingress.agentgateway-ingress.svc.cluster.local","protocolBinding":"HTTP+JSON","protocolVersion":"1.0"},
 {"url":"agentgateway-ingress.agentgateway-ingress.svc.cluster.local:80","protocolBinding":"GRPC","protocolVersion":"1.0"}]}
```

Three interfaces, JSON-RPC first, then REST (`HTTP+JSON`) and gRPC, all at the ingress. **This is the thing to know
before you try to send from your laptop.** The a2a-go client resolves the card and then, unless `CLIENT_DIAL=target`
tells it otherwise, sends to the address the card advertises — and on every binding that address is an in-cluster DNS
name, which your machine cannot resolve:

```
curl -sS -o /dev/null --max-time 5 http://agentgateway-ingress.agentgateway-ingress.svc.cluster.local/
```

```
curl: (28) Resolving timed out after 5003 milliseconds
```

So the out-of-cluster send is made by hand, with `curl` and a `Host` header, which is also how the committed
out-of-cluster rows send. At this step the ingress carries one HTTP route, `orchestrator-ingress`, which sets no
hostname and so matches every host — step 2c adds `worker-ingress`, which matches `Host: worker.lab.internal` and is
how the same send reaches the other receiver. The `Host` below is therefore free; it is the value the committed rows
use. The answer is written to a scratch directory taken from the environment rather than to a named one:

```
LWI=wt2b-ingress
OUT="${TMPDIR:-/tmp}/ingress-resp.json"
curl -s -o "$OUT" -w 'http=%{http_code}\n' -X POST http://127.0.0.1:18080/ \
  -H 'Host: orchestrator.lab.internal' -H 'Content-Type: application/json' -H 'A2A-Version: 1.0' \
  -H "X-Logical-Work-Item-Id: $LWI" \
  -d "{\"jsonrpc\":\"2.0\",\"id\":\"$(uuidgen)\",\"method\":\"SendMessage\",\"params\":{\"message\":{\"messageId\":\"$(uuidgen)\",\"role\":\"ROLE_USER\",\"parts\":[{\"text\":\"lwi:$LWI hello\"}],\"metadata\":{\"logical_work_item_id\":\"$LWI\"}}}}"
```

```
http=200
```

```
jq -c '{taskId: .result.task.id, contextId: .result.task.contextId, state: .result.task.status.state}' "$OUT"
```

```
{"taskId":"bb9c0ef4-f19e-4c30-a1f0-45acc191eb69","contextId":"9a0e5f6b-df69-4511-a310-cad0d9d99d53","state":"TASK_STATE_COMPLETED"}
```

```
make ledgers LWI=wt2b-ingress OUT=experiments/runs/my-walkthrough/step-2b/ingress
```

Seventeen lines, and this is the shape a forwarded work item has. Two ingress-ledger arrivals, one at the
orchestrator carrying the `messageId` you sent and one at the worker carrying a **new** one; two execution ledgers,
each creating a Task of its own; and **one** invocation line at the mock, `caller: worker`:

| ledger | source | what it counted |
| --- | --- | --- |
| ingress | orchestrator | 1 arrival, `messageId` `EFD0244B…`, then status 200 |
| ingress | worker | 1 arrival, `messageId` `a689a7fe…`, then status 200 |
| execution | orchestrator | `received`, `execute` → task `bb9c0ef4…`, SUBMITTED/WORKING/COMPLETED, `result` |
| execution | worker | `received`, `execute` → task `01a0da92…`, SUBMITTED/WORKING/COMPLETED, `result` |
| invocation | mockllm | 1 call, `caller: worker`, task `01a0da92…` |
| client | — | none: `curl` writes no client ledger |
| extauthz | — | none: no route consults the fixture |

One work item, **two** A2A messages, **two** Tasks, **one** model call, by design — the orchestrator forwards and the
worker is the one that calls the model. The absent client ledger is not a gap, and `make ledgers` says so on stderr
rather than silently: the lab's own clients write those lines, and `curl` is not one of them. Files:
[`step-2b/ingress/`](../experiments/runs/2026-09-25-walkthrough/step-2b/ingress/). Close the port-forward when you
are done.

## Step 2c — the second Service's route, the worker's hostname on the ingress, and the gRPC routes

```
make step-2c
```

**21.8 s.** It gives the orchestrator Service its own hostname route on `agw-central` and binds the Service to it,
gives the worker its own hostname on the ingress, so an in-cluster stimulus to either receiver crosses the waypoint and
an out-of-cluster one can reach either receiver, and adds the two gRPC routes.

```
kubectl get httproute -A
kubectl get grpcroute -A
kubectl -n lab get svc -o json | jq -r '.items[] |
  "\(.metadata.name)  istio.io/use-waypoint=\(.metadata.labels["istio.io/use-waypoint"] // "-")"'
```

```
NAMESPACE               NAME                   HOSTNAMES
agentgateway-waypoint   model-via-agw          ["model.lab.internal"]
lab                     orchestrator           ["orchestrator.lab.svc.cluster.local"]
lab                     orchestrator-ingress
lab                     worker                 ["worker.lab.svc.cluster.local"]
lab                     worker-ingress         ["worker.lab.internal"]

NAMESPACE   NAME                        HOSTNAMES
lab         orchestrator-grpc-ingress   ["orchestrator-grpc.lab.internal"]
lab         worker-grpc-ingress         ["worker-grpc.lab.internal"]

extauthz  istio.io/use-waypoint=-
mockllm  istio.io/use-waypoint=-
orchestrator  istio.io/use-waypoint=agw-central
worker  istio.io/use-waypoint=agw-central
```

Five HTTPRoutes, two GRPCRoutes and two Gateways, and that is the whole L7 configuration of this lab. Three of the
HTTPRoutes are on `agw-central` — the two agent Services and the model host — and two on the ingress. The two
`GRPCRoute`s are on the ingress only, one per receiver, each to that agent's port 8081, on hostnames of their own
(`worker-grpc.lab.internal`, `orchestrator-grpc.lab.internal`) that intersect no HTTPRoute's, because Gateway API
accepts only one of an HTTPRoute and a GRPCRoute whose hostnames intersect on one listener; a gRPC client names that
hostname as its call's authority. Nothing gRPC is routed on `agw-central`: its waypoint listener serves the HTTP port
only. They are recorded in `## Experiment C / both receivers / D-2, the REST and gRPC bindings rebuilt`, and no command
in this walkthrough sends gRPC. The authorization fixture's Service names no waypoint, so nothing sends its traffic
through `agw-central`.

`retry-off` puts all four HTTPRoute **sets** back (`waypoint` is `lab/worker`, `waypoint-orchestrator` is
`lab/orchestrator`, `ingress` is both ingress HTTPRoutes, `egress` is `model-via-agw`), which is the state every run
that is not measuring a gateway retry starts and ends in. Until 2026-09-19 each agent Service had an istiod-driven
waypoint of its own; the reasons that class is retired here are in `deploy/step-2c-gate2/kustomization.yaml` and the
dated notes in `docs/proposal-notes.md`.

## Step 3 — telemetry, and one trace per work item

```
make step-3
```

**87.0 s.** It runs the certificate check first, then applies step 3's configuration through `ko` and installs the
three telemetry components from their charts into an unenrolled `telemetry` namespace. The namespace stays out of the
mesh deliberately: an in-mesh collector would enforce mTLS on inbound OTLP and refuse the spans of every emitter that
is not ztunnel-captured — the mock and `agw-central` — which is exactly the set of hops this step exists to light up.

Step 3's own configuration is two `AgentgatewayPolicy` pairs, one per Gateway: `frontend.tracing` and
`frontend.accessLog.otlp`, both pointing at the collector. Istio contributes no `Telemetry` resource at all; its
tracing configuration is the extension provider in `meshConfig`, which step 2 installed with the istiod chart.

**Never apply this overlay with a plain `kubectl apply -k deploy/step-3-stress`.** It carries the Go Deployments,
whose images are `ko://` references that only `kubectl kustomize … | ko apply` resolves; a plain `apply -k` writes the
literal `ko://` string into the Go Deployments and each gains an `InvalidImageName` pod beside its running one. Apply
a telemetry-only change by file, or run this target.

The certificate check, which is the first thing it prints:

```
== certificate check ==
CERTIFICATE NAME                                                           TYPE     STATUS        VALID CERT     NOT AFTER
spiffe://cluster.local/ns/agentgateway-ingress/sa/agentgateway-ingress     Leaf     Available     true           2026-10-02T21:56:23Z
spiffe://cluster.local/ns/lab/sa/default                                   Leaf     Available     true           2026-10-02T21:54:12Z
spiffe://cluster.local/ns/lab/sa/orchestrator                              Leaf     Available     true           2026-10-02T21:54:04Z
spiffe://cluster.local/ns/lab/sa/worker                                    Leaf     Available     true           2026-10-02T21:54:04Z
…                                                                          Root     (each identity's Root row)
certificate check: VALID CERT true for spiffe://cluster.local/ns/lab/sa/worker and spiffe://cluster.local/ns/lab/sa/orchestrator; ztunnel not restarted
```

Four leaves now: the ingress proxy's, the worker's, the orchestrator's, and `lab/sa/default`, the account of the
captured `lab` pods that keep the default — the authorization fixture, and the short-lived control pods the scripts
start. That leaf was first issued at 21:54:12Z, during step 2's clean check and before the fixture existed, which is
why step 2's read did not show it and this one does. `agw-central` has a SPIFFE
identity of its own but it is not a ztunnel workload, so ztunnel holds no certificate for it.

### Send one clean message first

```
RUN_ID=wt3 RUN_ITEM=my-walkthrough/step-3/clean experiments/gate2-single-clean.sh
```

**44.5 s**, `1,1,1,1,1` `TASK_STATE_COMPLETED` on both receivers again.

Run this **before** the trace, and the reason is measured rather than stylistic. `make step-3` rolls the lab pods,
and the orchestrator's **first** forward after a restart fetches the worker's agent card, which the trace then
carries. That was taken deliberately on this run, as its own reading, after the trace below:

```
kubectl -n lab rollout restart deploy/orchestrator
kubectl -n lab rollout status deploy/orchestrator --timeout=180s
REPS=1 RECEIVERS=orchestrator RUN_ID=wt3f RUN_ITEM=my-walkthrough/step-3/trace-first-forward \
  experiments/gate3-trace-per-work-item.sh
```

```
receiver,work_item,trace_ids,spans,spans_by_service,hops_without_span,lab_work_item_on_all
orchestrator,a3t-wt3f-r1-orchestrator,2,85,agentgateway-ingress=2|agw-central=8|loadgen=3|mockllm=1|orchestrator=67|worker=4,none,no:8/85
```

**85** spans against the **81** the next section reads — `+2 agw-central`, `+1 worker`, `+1 orchestrator`, and those
four are that card fetch crossing the waypoint
([`step-3/trace-first-forward/`](../experiments/runs/2026-09-25-walkthrough/step-3/trace-first-forward/)). Every
committed count for this path was taken after a clean check on the same process, so take yours the same way.

### The trace

```
REPS=2 RUN_ID=wt3 RUN_ITEM=my-walkthrough/step-3/trace experiments/gate3-trace-per-work-item.sh
```

**120.8 s.** Four work items, two per receiver, each with its three ledgers and its exported trace:

```
receiver,work_item,trace_ids,spans,spans_by_service,hops_without_span,lab_work_item_on_all
orchestrator,a3t-wt3-r1-orchestrator,2,81,agentgateway-ingress=2|agw-central=6|loadgen=3|mockllm=1|orchestrator=66|worker=3,none,no:8/81
worker,a3t-wt3-r1-worker,2,14,agw-central=6|loadgen=3|mockllm=1|worker=4,none,no:5/14
orchestrator,a3t-wt3-r2-orchestrator,2,81,agentgateway-ingress=2|agw-central=6|loadgen=3|mockllm=1|orchestrator=66|worker=3,none,no:8/81
worker,a3t-wt3-r2-worker,2,14,agw-central=6|loadgen=3|mockllm=1|worker=4,none,no:5/14
```

```
python3 experiments/runs/2026-09-16-genai-spans/trace/dangling.py \
  experiments/runs/my-walkthrough/step-3/trace
```

```
work_item,spans,trace_ids,roots,dangling_parents
a3t-wt3-r1-orchestrator,81,2,2,0
a3t-wt3-r1-worker,14,2,2,0
a3t-wt3-r2-orchestrator,81,2,2,0
a3t-wt3-r2-worker,14,2,2,0
```

Worker **14**, orchestrator **81**, `trace_ids` 2, **2 roots**, **0 dangling parents** and `hops_without_span: none`
on all four — column for column the figures `## Experiment A / both receivers / re-run on the topology of 2026-09-19`
records for this instrument, and the ones `## Gate 3 / both receivers / the pins of 2026-09-25` re-counted at
a2a-python 1.1.5 and a2a-go v2.6.0. Two traces per work item rather than one, because the client fetches the agent
card and sends the message as two separate roots. How the orchestrator's total came to 81 — the GenAI spans, then
twelve `EventQueueSource._deliver_to_sink` spans from a2a-python 1.1.4 — is in
`## Gate 3 / both receivers / GenAI and agent spans` and the re-run entry; no ledger count moved at any of those steps.

The whole of a worker work item, read out of that work item's `spans.csv`:

```
python3 - <<'PY'
import csv
rows = list(csv.DictReader(open(
    "experiments/runs/my-walkthrough/step-3/trace/a3t-wt3-r1-worker/spans.csv")))
for r in sorted(rows, key=lambda r: (r["trace_id"], int(r["start_us"]))):
    print("%-24s %-44s %s" % (r["service"], r["operation"], r["http_status"]))
PY
```

```
loadgen                  HTTP GET                                     200
agw-central              GET /*                                       200
agw-central              GET worker.lab.svc.cluster.local:8080        200
worker                   GET /.well-known/agent-card.json             200
loadgen                  invoke_agent worker
loadgen                  HTTP POST                                    200
agw-central              POST /*                                      200
agw-central              POST worker.lab.svc.cluster.local:8080       200
worker                   POST /                                       200
worker                   chat mock
worker                   HTTP POST                                    200
agw-central              POST /*                                      200
agw-central              POST mockllm.lab.svc.cluster.local:8080      200
mockllm                  POST /v1/chat/completions                    200
```

The two blocks of that listing are the work item's two traces, and **which of them comes first is not fixed**:
the sort is by `trace_id`, which is a random identifier, so the four `GET` rows — the card fetch — may come
below the ten `POST` rows instead of above them. Order within a trace is start time and is fixed. This run's
listing is committed as
[`step-3/trace/worker-spans.txt`](../experiments/runs/2026-09-25-walkthrough/step-3/trace/worker-spans.txt).

Every `agw-central` row above carries a status: the trace exporter reads agentgateway's own `http.status`
attribute. The exporter also writes two columns that tell one proxy's hops apart, now that there is one proxy:

```
head -1 experiments/runs/my-walkthrough/step-3/trace/a3t-wt3-r1-worker/spans.csv
```

```
trace_id,span_id,parent_span_id,service,operation,start_us,duration_us,lab_work_item,lab_message_id,http_status,route,retry_attempt
```

```
python3 - <<'PY'
import csv
rows = list(csv.DictReader(open(
    "experiments/runs/my-walkthrough/step-3/trace/a3t-wt3-r1-worker/spans.csv")))
for r in sorted(rows, key=lambda r: (r["trace_id"], int(r["start_us"]))):
    if r["service"] == "agw-central" and r["route"]:
        print("%-10s %-38s %s" % (r["operation"], r["route"], r["retry_attempt"] or "-"))
PY
```

```
GET /*     lab/worker                             -
POST /*    lab/worker                             -
POST /*    agentgateway-waypoint/model-via-agw    -
```

Three `route` values on one service: the card fetch, the POST to the worker, and the model call. `route` is on the
proxy's SERVER span — the one per request it received — and `retry_attempt` is agentgateway's `retry.attempt`,
empty here because no route carries a stanza. The layer-attribution tool keys on `route` for exactly this reason
([`step-3/trace/agw-central-routes.txt`](../experiments/runs/2026-09-25-walkthrough/step-3/trace/agw-central-routes.txt)).

Every hop a work item crosses in the diagram has a span. Two of those spans are named after operations rather than
HTTP verbs, and they are the lab's agentic work as the OpenTelemetry GenAI semantic conventions name it:
`invoke_agent worker` around the A2A send, `chat mock` around the model call. Counted per operation:

```
mkdir -p experiments/runs/my-walkthrough/step-3/trace/genai
python3 experiments/runs/2026-09-16-genai-spans/genai-spans.py \
  experiments/runs/my-walkthrough/step-3/trace \
  experiments/runs/my-walkthrough/step-3/trace/genai
```

```
work_item,spans,…,chat_spans,invoke_agent_spans,…,spans_missing_required,spans_missing_expected,spans_with_agent_id
a3t-wt3-r1-orchestrator,81,…,1,2,…,0,0,0
a3t-wt3-r1-worker,14,…,1,1,…,0,0,0
…                        (the two r2 rows read identically to their r1 counterparts)
```

| receiver | service | operation | kind | spans |
| --- | --- | --- | --- | --- |
| worker | loadgen | `invoke_agent worker` | CLIENT | 1 |
| worker | worker | `chat mock` | CLIENT | 1 |
| orchestrator | loadgen | `invoke_agent orchestrator` | CLIENT | 1 |
| orchestrator | orchestrator | `invoke_agent worker` | CLIENT | 1 |
| orchestrator | worker | `chat mock` | CLIENT | 1 |

`spans_missing_required=0`, `spans_missing_expected=0`, `spans_with_agent_id=0` on all four work items, the same
roll-up the GenAI entry records.

**A GenAI span count is not a delivery count, and the difference is deliberate.** The conventions say a span "SHOULD
cover the duration of the logical operation with all retries", so one `chat` span can wrap two model calls when a
client library retries under it. The A.3 R3 row counted exactly that, in
`## Gate 3 / both receivers / GenAI and agent spans` and not re-taken here: `invocations=2` in the ledger,
`mockllm=2` spans, and **one** `chat mock` span with two children. The ledgers count deliveries; the GenAI spans count
logical operations. When the two disagree, the ledger is the ground truth and the span is the explanation.

### Prometheus and the trace backend

```
experiments/runs/2026-09-12-mtls-enforced/promq.sh targets
```

```
agentgateway-controlplane  up  http://10.244.1.13:9092/metrics
agentgateway-proxies       up  http://10.244.1.19:15020/metrics
agentgateway-proxies       up  http://10.244.1.27:15020/metrics
istiod                     up  http://10.244.1.10:15014/metrics
otel-collector             up  http://otel-collector.telemetry.svc.cluster.local:8889/metrics
ztunnel                    up  http://10.244.0.6:15020/metrics
ztunnel                    up  http://10.244.1.12:15020/metrics
-- 7/7 targets up
```

**7/7**: the two agentgateway proxies, two `ztunnel`, `istiod`, the control plane and the collector — the roster
`## Gate 3 / both receivers / topology` records and every entry since has re-counted. The authorization fixture
exports no metrics and no spans, so it adds no target here and no service below.

To read a trace by eye, port-forward the backend's own UI. Nothing else is installed to look at it with. This one
also holds its terminal, so give it its own as the ingress tunnel above needed:

```
kubectl -n telemetry port-forward svc/jaeger 16686:16686
# then open http://127.0.0.1:16686
```

The services the backend holds spans for, read from its stable `/api/v3` query API (Jaeger 2.21.0, chart 4.14.0; the
legacy `/api/services` path was removed in 2.21.0):

```
curl -s http://127.0.0.1:16686/api/v3/services | jq -r '.services[]' | sort
```

```
agentgateway-ingress
agw-central
jaeger
loadgen
mockllm
orchestrator
worker
```

Seven: the two proxies, the load client, the two agents, the mock, and the backend's own.

Storage is in memory, so a restart of that pod loses every trace it holds; the traces a findings entry cites are the
exported copies under `experiments/runs/`, not the ones in the backend. To export one work item at a time:

```
make export-trace LWI=<logical_work_item_id> OUT=<dir>
```

## Experiment A, six rows

The cluster is now what the diagram draws, and the rest is Experiment A. Each row below runs at **reduced
repetitions** — the committed entries were taken at twenty per row and these at two, or one on the egress row — so
what is being demonstrated is that the counts reproduce, not that they reproduce with the committed statistical
weight. Every row resets both receivers' injectors and the mock before each repetition, arms exactly one failure,
sends exactly one stimulus, and puts back everything it changed on every exit path.

The full matrix takes hours; the six here take about ten minutes together and cover the four things the
experiment is for: what a receiver does with a duplicate, what a client retry puts back on the wire, where a
second delivery is made, and what changes when the client addresses a Service instead of the URL its card
advertises.

Every count below is read against `## Experiment A / both receivers / re-run on the topology of 2026-09-19`, the
entry that re-measured all of Experiment A on this topology at twenty repetitions per row, and against the older
entry each row was first recorded in where that adds something. That entry counted at a2a-go v2.5.0, a2a-python 1.1.4
and Istio 1.31.0; this run is at a2a-go v2.6.0, a2a-python 1.1.5 and Istio 1.31.1. Set beside it column by column,
each column as the set of values its repetitions took, identifiers masked only, the six rows read **74 of 74 cells the
same** ([`rows-vs-entries.txt`](../experiments/runs/2026-09-25-walkthrough/rows-vs-entries.txt)).

### A.1 M1 — the identical request, twice

```
MODE=M1 RECEIVER=go REPS=2 RUN_ID=wta1 RUN_ITEM=my-walkthrough/a1-m1-go experiments/gate2-a1.sh
```

**58.1 s.** Two repetitions over each of the two stimulus paths. Each repetition is one `make replay` in mode M1: one
`SendMessage` body delivered twice over a client with no retries, the second byte-identical to the first — same
JSON-RPC `id`, same A2A `messageId`, same bytes.

```
mode,receiver,path,work_item,deliveries,executes,distinct_message_ids,tasks_created,invocations,resp1,resp2,same_task,notes
M1,go,waypoint,a1-m1-go-waypoint-wta1-01,2,2,1,2,2,task/TASK_STATE_COMPLETED,task/TASK_STATE_COMPLETED,no,
M1,go,waypoint,a1-m1-go-waypoint-wta1-02,2,2,1,2,2,task/TASK_STATE_COMPLETED,task/TASK_STATE_COMPLETED,no,
M1,go,ingress,a1-m1-go-ingress-wta1-01,2,2,1,2,2,task/TASK_STATE_COMPLETED,task/TASK_STATE_COMPLETED,no,
M1,go,ingress,a1-m1-go-ingress-wta1-02,2,2,1,2,2,task/TASK_STATE_COMPLETED,task/TASK_STATE_COMPLETED,no,
```

Read against `## Gate 2 / go receiver / A.1 M1 exact transport replay` and against the re-run entry, every cell is
the committed one: two deliveries, two executor entries, **one** distinct `messageId`, **two** Tasks, **two** model
invocations, both responses `task`/`TASK_STATE_COMPLETED`, and `same_task: no` — the second answer names a different
Task from the first. Those entries counted 20 of 20 on each path and this run counted 2 of 2 on each; the values are
identical and the weight is not.

So under this configuration the Go receiver, at a2a-go v2.6.0 as at v2.5.0 in the entries, does not deduplicate an
exact transport replay: it accepts the second delivery, dispatches it, creates a second Task and calls the model
again, on both paths. The specification permits that — §3.3.1 says Send Message operations **MAY** be idempotent. The
useful part for the rows below is the negative result: neither the waypoint route nor the ingress collapsed, dropped
or altered the duplicate, so a second delivery counted at the worker later can be attributed to whatever produced it
rather than to the path it took.

### A.2 — what a client retry puts back on the wire

```
CLIENT=go LAYER=http RETRY_ON=transport+503 REPS=2 RUN_ID=wta2 \
  RUN_ITEM=my-walkthrough/a2-go-http-503 experiments/gate2-a2.sh
```

**48.8 s.** Neither SDK offers a retry, so the retry here is the lab's own and opt-in: `CLIENT_RETRIES=1` with
`CLIENT_RETRY_ON=transport+503`, switched on by this script alone, for this row alone. The failure it is asked to
retry is one `close-after-read` armed at the worker for the repetition's work item — the middleware writes the
arrival line and then takes the connection away.

```
client,layer,work_item,arrivals,messageId_reused,id_reused,body_identical,injection_fired,executes,invocations,client_result,notes
go,http,a2-go-http-503-wta2-01,2,yes,yes,yes,1,1,1,task/TASK_STATE_COMPLETED,knob=CLIENT_RETRIES=1 CLIENT_RETRY_ON=transport+503;client_lines=1;
go,http,a2-go-http-503-wta2-02,2,yes,yes,yes,1,1,1,task/TASK_STATE_COMPLETED,knob=CLIENT_RETRIES=1 CLIENT_RETRY_ON=transport+503;client_lines=1;
```

Read against `## Gate 2 / a2a-go client / A.2 retry identity`, the `transport+503` sub-row there reads
`2 yes yes yes 1 1 1 COMPLETED` in 20 of 20, and this run reads it in 2 of 2. Two arrivals at the worker's
pre-dispatch ledger with one `messageId`, one JSON-RPC `id` and one body hash between them: the second delivery is
the first one's bytes, unchanged. The mode matters, and which mode fires on this path was measured rather than assumed
— by that same entry, and not re-taken here: the default `transport` mode re-sends on a transport error only and
so never fires at all on this path, because the proxy in front of the worker turns the connection the receiver took
away into a synthesised **503** before the client can see it as a transport error. And
`client_lines=1`: an HTTP-layer retry is invisible above the transport, so the caller never learns there were two
deliveries. One arrival was refused before dispatch, which is why the row ends at one Task and one model call rather
than the two A.1 just counted for a duplicate that reaches dispatch.

### A.3 baseline — what raw failure looks like

```
RUN=baseline RECEIVER=go REPS=2 RUN_ID=wta3b RUN_ITEM=my-walkthrough/a3-baseline-go \
  experiments/gate3-matrix.sh
```

**104.9 s**, including the one-repetition dry run every matrix invocation runs first under a scratch nonce whose
directory is deleted. This row asserts its zero rather than assuming it: zero `retry:` stanzas across every
`HTTPRoute` read back from the API server, no `CLIENT_*` on any Deployment, the receiver's model-retry knob read off
the live object, and the Job rendered with all four `CLIENT_*` variables at their off values. Before any of that it
checks that the running worker and mock Deployments were built from the Go sources of this checkout, by the source
hash every step target stamps on them. Its injection is one `close` at the **model endpoint**,
so the failure is raw and any second delivery would be somebody's retry.

```
receiver,run,sub,work_item,deliveries,dispatched,distinct_messageIds,tasks,invocations,client_result,trace_spans,spans_by_service,second_delivery_layer,notes
go,baseline,none,a3m-baseline-go-wta3b-01,1,1,1,1,1,task/TASK_STATE_FAILED,14,agw-central=6|loadgen=3|mockllm=1|worker=4,none,client_lines=1;
go,baseline,none,a3m-baseline-go-wta3b-02,1,1,1,1,1,task/TASK_STATE_FAILED,14,agw-central=6|loadgen=3|mockllm=1|worker=4,none,client_lines=1;
```

Read against `## Gate 3 / both receivers / A.3 baseline` for the ledger counts and against the re-run entry for the
trace: `1 1 1 1 1` with `task/TASK_STATE_FAILED` and `second_delivery_layer: none`, **14** spans and
`agw-central=6|loadgen=3|mockllm=1|worker=4` — the committed values, here in 2 of 2 against those entries' 20 of 20.
One delivery, one dispatch, one Task, one model call, no second delivery anywhere: the baseline is retry-free by the
ledgers on a path that crosses one proxy twice. `second_delivery_layer: none` means there was no second delivery to
attribute, not that one could not be attributed. How the span total came to 14 from the 8 of the 2026-09-09 entry is
named in the entries themselves: the GenAI layer added one `loadgen invoke_agent worker` and one `worker chat mock`,
and the topology of 2026-09-19 regrouped the proxy spans without changing how many there are.

### A.3 R1 — a client retry, and where the trace says it came from

```
RUN=R1 RECEIVER=go SUB=http REPS=2 RUN_ID=wta3r1 RUN_ITEM=my-walkthrough/a3-r1-go-http \
  experiments/gate3-matrix.sh
```

**133.3 s.** The same client knob A.2 measured, now with the trace collected and the layer derived from the ledgers
and the trace alone — no knob value reaches the derivation, so a row cannot be labelled by what it was expected to do.

Its `summary.csv`, with the fourteenth column, `notes`, lifted out below because it is a paragraph of its own:

```
receiver,run,sub,work_item,deliveries,dispatched,distinct_messageIds,tasks,invocations,client_result,trace_spans,spans_by_service,second_delivery_layer,…
go,R1,http,a3m-r1-go-http-wta3r1-01,2,1,1,1,1,task/TASK_STATE_COMPLETED,17,agw-central=8|loadgen=3|mockllm=1|worker=5,client-http,…
go,R1,http,a3m-r1-go-http-wta3r1-02,2,1,1,1,1,task/TASK_STATE_COMPLETED,17,agw-central=8|loadgen=3|mockllm=1|worker=5,client-http,…
```

Read against `## Gate 3 / both receivers / A.3 R1` and the re-run entry: `2 1 1 1 1 COMPLETED client-http` with
**17** spans, the committed values, 2 of 2 here against 20 of 20 there. The derivation's own reason, the
`layer_reason=` part of that `notes` column, opens:

```
the two worker server spans have distinct parent span ids ba1c7025b94c1ab7 and dbcbc35267cf5dc0 that do not
converge on one proxy span / so each attempt crossed the proxy separately / client lines 1 which does not separate
the two layers because the lab's HTTP retry loops below the line the client prints / a proxy that exports nothing
leaves both parents dangling and is caught by the shared-parent rule instead because Task 2 measured the
istiod-driven waypoint (retired 2026-09-19) issuing one span id for both of its own attempts;
```

The last clause of that reason is the tool citing the measurement its rule rests on, and saying that the proxy it was
measured on is gone; the rule and the label are unchanged, which is what the re-run entry records for this cell.

Two deliveries, one dispatch, one Task, one model call — and the entry classifies that as **potentially dangerous**
rather than safe, because the one Task is an artefact of *where* this row's injection fires. R1 refuses the first
delivery before dispatch, so the retry always fires into a receiver that never started work. Had the first delivery
reached dispatch, A.1 above already counted what happens: a second Task and a second model call for one logical work
item, with the client seeing only the final answer.

One more reading on this row, and it comes from the row's **exported trace** rather than from `summary.csv`, which
carries no span attribute. The first of the two deliveries is the one the worker closed by its own injection, and
the worker marks its own server span for it, as the mock marks its own:

```
python3 experiments/runs/2026-09-19-currency-rebuild/worker-span/worker-span-reading.py \
  experiments/runs/my-walkthrough/a3-r1-go-http/a3m-r1-go-http-wta3r1-01
```

The tool prints the worker's three server spans in start order — the card fetch, the closed delivery, the one that
was answered. The second of them, whole:

```
  service=worker scope=go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp
    name=POST /
    kind=server
    status.code=Error
    status.description="injected: close-after-read"
    lab.injection=close-after-read
    http.request.method=POST
    http.response.status_code=200
    url.path=/
    lab.work_item=a3m-r1-go-http-wta3r1-01
    duration_ms=0.1 events=0 span_id=e4ed4d73f02e2360 parent=ba1c7025b94c1ab7
```

That `parent=ba1c7025b94c1ab7` is the first of the two span ids the `layer_reason` above names, so this is the
attempt the attribution tool counted as its own crossing. The **200** beside the `Error` is not a contradiction and
is left standing deliberately: the worker hijacks the connection away from `net/http` before anything is written,
and otelhttp v0.71.0 stamps its wrapper's default status on a hijack it cannot see, so the span carries a response
code for a delivery that got no response — the ledgers, not the span, are what say the delivery was refused. Read
against `## Gate 3 / go receiver / the worker's server span on its own injected close-after-read`, those four fields
are the committed ones. The third span, the delivery that was answered, reads `status.code=Unset`, an empty
description and no `lab.injection`. The whole reading, with the proxy's entry spans and the client's
beside it, is
[`a3-r1-go-http/worker-span.txt`](../experiments/runs/2026-09-25-walkthrough/a3-r1-go-http/worker-span.txt).

### A.3 egress — a gateway retry on the model leg

```
RUN=egress RECEIVER=go REPS=1 RUN_ID=wta3e RUN_ITEM=my-walkthrough/a3-egress-go \
  experiments/gate3-matrix.sh
```

**99.4 s**, one counted repetition after its dry run. This row switches the retry stanza on for the **model** route
alone, arms the model endpoint `http500` for the work item, and switches the stanza off again afterwards.

```
receiver,run,sub,work_item,deliveries,dispatched,distinct_messageIds,tasks,invocations,client_result,trace_spans,spans_by_service,second_delivery_layer,notes
go,egress,none,a3m-egress-go-wta3e-01,1,1,1,1,2,task/TASK_STATE_FAILED,16,agw-central=7|loadgen=3|mockllm=2|worker=4,gateway,client_lines=1;layer_reason=one call entered route agentgateway-waypoint/model-via-agw and the proxy made 2 upstream attempts under it / so the proxy re-sent it;
```

```
== restoring the egress route: removing the retry stanza ==
restored: retry stanzas across every HTTPRoute: 0
```

Read against `## Gate 3 / both receivers / egress-route retry` and the re-run entry: `1 1 1 1 2 FAILED gateway` with
**16** spans, the committed values, 1 of 1 here against 20 of 20 there. **One** delivery and **one** Task at the
receiver, but **two** model invocations: the duplicate was made below the A2A layer entirely, by the proxy on the
model route, and the receiver's ledgers cannot see it. That is the whole point of having three ledgers rather than
one — the mock counted a call the agent never made, and `agw-central=7` against the baseline's `6` is the proxy's
own extra span saying so. The Task still failed, because the second attempt met the same injection.

Read the reason beside the baseline's: it names `route agentgateway-waypoint/model-via-agw`. One proxy serves the
agent routes and the model route under one service name, so the attribution tool keys a proxy span's hop on its
`route` rather than on the service it came from.

### A.3 R2, Python receiver, addressed to its own Service

```
RUN=R2 RECEIVER=py SUB=service REPS=2 RUN_ID=wta3s RUN_ITEM=my-walkthrough/a3-r2-py-service \
  experiments/gate3-matrix.sh
```

**139.4 s.** This is the sub-row the author's note of 2026-09-19 added, and it is the one place in this walkthrough
where `CLIENT_DIAL` is not empty. The load client still resolves the orchestrator's agent card, which advertises the
ingress, and then sends its `SendMessage` POST to the **Service** it resolved the card at instead. So the POST
crosses `lab/orchestrator` on `agw-central`, and the retry stanza goes on that route alone — the
`waypoint-orchestrator` route set — where the Python receiver's other gateway rows put it on the ingress routes.

```
receiver,run,sub,work_item,deliveries,dispatched,distinct_messageIds,tasks,invocations,client_result,trace_spans,spans_by_service,second_delivery_layer,…
py,R2,service,a3m-r2-py-service-wta3s-01,2,1,1,1,1,task/TASK_STATE_COMPLETED,75,agw-central=7|loadgen=3|mockllm=1|orchestrator=64,gateway,…
py,R2,service,a3m-r2-py-service-wta3s-02,2,1,1,1,1,task/TASK_STATE_COMPLETED,75,agw-central=7|loadgen=3|mockllm=1|orchestrator=64,gateway,…
```

```
layer_reason=route lab/orchestrator on the agw-central in front of orchestrator shows one inbound span with
2 upstream attempts / so the proxy re-sent the delivery it received;
```

Read against the re-run entry's table of the three Service-addressed rows: `2 1 1 1 1 COMPLETED gateway`, **75**
spans and `agw-central=7|loadgen=3|mockllm=1|orchestrator=64` — every cell the committed one, 2 of 2 here against
20 of 20 there. **Zero** `agentgateway-ingress` spans, which is the whole difference from the same row sent through
the ingress: that one reads 75 spans too, but as `agentgateway-ingress=3|agw-central=4|loadgen=3|mockllm=1|orchestrator=64`.
The ledgers count the same thing either way — two deliveries carrying one JSON-RPC id, one `messageId` and one body
hash, one dispatch, one Task, one model call — and what moved is which proxy and which route carried the POST. The
client line says so too: `dialled_url` is `http://orchestrator.lab.svc.cluster.local:8080`, while every
`advertised_urls` entry names the ingress.

### The six rows, together

| row | this run | the re-run entry, 20 of 20 | ledger counts |
| --- | ---: | ---: | --- |
| A.1 M1 go, both paths | 2 of 2 each | 20 of 20 each | `2 2 1 2 2` COMPLETED/COMPLETED `no` |
| A.2 go http 503 | 2 of 2 | 20 of 20 | `2 yes yes yes 1 1 1` COMPLETED |
| A.3 baseline go | 2 of 2, 14 spans | 20 of 20, 14 spans | `1 1 1 1 1` FAILED `none` |
| A.3 R1 go/http | 2 of 2, 17 spans | 20 of 20, 17 spans | `2 1 1 1 1` COMPLETED `client-http` |
| A.3 egress go | 1 of 1, 16 spans | 20 of 20, 16 spans | `1 1 1 1 2` FAILED `gateway` |
| A.3 R2 py/service | 2 of 2, 75 spans | 20 of 20, 75 spans | `2 1 1 1 1` COMPLETED `gateway` |

Every ledger count, every layer label and every span total in the six rows equals the one the entry that committed it
records: 74 of 74 cells, none differs. The three span totals that moved on the way to this topology — baseline 12 →
14, R1 15 → 17, egress 14 → 16, and before that 8, 9 and 10 in the original 2026-09-09 entries — are accounted for in
the entries named beside each row, and this run reads the current figure in every case.

## Cleanup

Close any port-forward you opened. Then check that the cluster is in the state every run that is not measuring a
retry has to start and end in:

```
kubectl get httproute -A -o yaml | grep -c 'retry:'
```

```
0
```

```
kubectl -n lab get deploy -o json | jq -r '.items[] | .metadata.name as $n |
  ((.spec.template.spec.containers[0].env // [])[] |
  select(.name | startswith("CLIENT_") or . == "MODEL_RETRIES" or . == "MODEL_MAX_RETRIES") |
  "\($n): \(.name)=\(.value)")'
```

```
orchestrator: MODEL_MAX_RETRIES=0
```

No `CLIENT_*` on any Deployment; `MODEL_MAX_RETRIES=0` is the orchestrator's declared default and `MODEL_RETRIES` is
unset on the worker. The orchestrator's `DOWNSTREAM_A2A_URL` reads
`http://worker.lab.svc.cluster.local:8080`, which the matrix rows unset for a Python row and restore on exit — the
row above did exactly that, and this is the read that says it was put back.

Then reset the control state of the mock and both receivers. The determinism check in step 1 left a work-item-keyed
injection armed at the mock, and this is what takes it off:

```
kubectl -n lab run wt-cleanup --image=curlimages/curl:8.22.0 --restart=Never --command -- sleep 60
kubectl -n lab wait --for=condition=Ready pod/wt-cleanup --timeout=60s
for u in mockllm worker orchestrator; do
  kubectl -n lab exec wt-cleanup -- curl -s -o /dev/null -w "$u/control/reset -> %{http_code}\n" \
    -X POST http://$u.lab.svc.cluster.local:8080/control/reset
done
kubectl -n lab delete pod wt-cleanup
```

```
mockllm/control/reset -> 204
worker/control/reset -> 204
orchestrator/control/reset -> 204
```

`204` is the documented answer. The authorization fixture has no control state to reset: its settings are in its
Deployment, and no run here changed them. And if you ran the determinism check, put its two committed files back:

```
git checkout -- experiments/runs/2026-09-05-mockllm-deterministic/
```

### What the walkthrough leaves behind

The cluster stays standing at step 3 with the topology the figure draws: two Gateways, five HTTPRoutes and two
GRPCRoutes with no retry stanza on any, and four Deployments in `lab` — the worker, the orchestrator, the mock and the
authorization fixture — besides the telemetry namespace and the two control planes. Three other things are left, none
of them removed by any command above, and none of them harmful:

- **`experiments/runs/my-walkthrough/`**, your run's own outputs — 1.3 MB on this run. It is untracked, so after the
  `git checkout --` above `git status` shows this one directory and nothing else. Keep it to read your own
  ledgers and traces, or `rm -rf experiments/runs/my-walkthrough` — nothing in this repository cites it.
- **`ingress-resp.json`** and **`agent-mesh-lab-tools/`** in whatever directory `"${TMPDIR:-/tmp}"` named: the answer
  the out-of-cluster send in step 2b was written to, and the istioctl and empty Helm scope the tools block set up.
  `rm` them when you are done with them; a new shell no longer has either on its `PATH` or in its environment.
- **The Completed `loadgen-*` and `replay-*` Jobs in `lab`, and their pods** — one per work item sent from inside
  the cluster, so by the end of the walkthrough there are a good many: this run left **24** Jobs and 24 Completed
  pods beside the four running Deployments' pods, and one Terminating pod; the orchestrator's Deployment had rolled
  three seconds before that read, when the last row put its downstream URL back. Nothing removes them while the cluster stands, and that is
  deliberate: `make ledgers` reads the client ledger out of those pod logs, so deleting a Job costs you the client
  lines of every work item it sent. `kubectl -n lab get jobs` lists yours; the teardown below removes them with the
  cluster.

To delete the cluster:

```
make teardown
```

Do not run `make teardown` against a cluster you still want counts from; every other run in this repository leaves it
standing.

## What this run took

| target or script | wall time |
| --- | ---: |
| `make teardown` | 1.6 s |
| `make cluster-kind` | 19.9 s |
| `make step-1` | 58.6 s |
| `make step-2` | 113.8 s |
| `make step-2b` | 57.5 s |
| `make step-2c` | 21.8 s |
| `make step-3` | 87.0 s |
| **the seven targets together** | **360.2 s** |
| `gate1-mockllm-deterministic.sh` | 16.9 s |
| `gate2-single-clean.sh`, each of four | 45.3 / 45.2 / 46.1 / 44.5 s |
| `gate3-trace-per-work-item.sh`, `REPS=2` | 120.8 s |
| `gate3-trace-per-work-item.sh`, `REPS=1`, the first forward after a restart | 62.3 s |
| `gate2-a1.sh` M1 go, `REPS=2` | 58.1 s |
| `gate2-a2.sh` go/http 503, `REPS=2` | 48.8 s |
| `gate3-matrix.sh` baseline go, `REPS=2` | 104.9 s |
| `gate3-matrix.sh` R1 go/http, `REPS=2` | 133.3 s |
| `gate3-matrix.sh` egress go, `REPS=1` | 99.4 s |
| `gate3-matrix.sh` R2 py/service, `REPS=2` | 139.4 s |
| **first line to last, including the tools block and the reads between** | **23 min 40 s** |

Every target and every script exited 0 on its first run, and none was repeated. The per-step stamps are in
[`timings.csv`](../experiments/runs/2026-09-25-walkthrough/timings.csv), and what the cluster reports about itself —
`kubectl version`, `istioctl version`, the node image digest, the agentgateway image on each of the two proxies and
on the controller, the lab Deployments' images and accounts, and the nine Helm releases at their pins — is in
[`cluster-versions.txt`](../experiments/runs/2026-09-25-walkthrough/cluster-versions.txt).

## Where to go next

The cluster this walkthrough leaves standing at step 3 is where the two companion documents begin:
[`walkthrough-b.md`](walkthrough-b.md) re-takes every row of Experiment B (what happens to a streamed task when the
proxy under it is removed or replaced, and what one resubscription gets) and [`walkthrough-c.md`](walkthrough-c.md)
every row of Experiment C (what each layer can see and enforce of an A2A operation, on JSON-RPC, REST and gRPC, with
the identities step 2 showed), the D-series rows filed under them included, each at two repetitions with its committed
driver and read against its entry by heading; their record is `experiments/runs/2026-09-26-walkthrough/`.
`findings.md` holds one entry per gate, receiver and mode or run — the numbers first and the interpretation second,
and no entry without a run. Experiment A, whose rows this walkthrough re-took, is one part of it; B, C and the D series
are recorded there too, each read from the run directories under `experiments/runs/`.
`docs/proposal-notes.md` holds the author's dated decisions since the proposal froze, and every one of them is in
force: the topology this walkthrough builds is the note of 2026-09-19, the ServiceAccounts, the REST and gRPC bindings
and the authorization fixture are the notes of 2026-09-24 and 2026-09-25, and the pins are the currency pass of
2026-09-25. `docs/experiment-a-checklist.md` is the checklist that ran Experiment A gate by gate, closed on 2026-09-19
with every box ticked, and is history rather than a work list. The rules for anyone working in this repository are in
`CLAUDE.md`, and the experiment design is `docs/PROPOSAL.md`, which is frozen.

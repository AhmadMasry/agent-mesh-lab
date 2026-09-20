# agent-mesh-lab

Can you retry an agent? A reproducible lab for A2A failure semantics on Kubernetes.

## What this is

An experiment lab that produces counted, traced findings about how A2A agent traffic behaves under retries, transport failure, and network-layer policy on Kubernetes, with Istio Ambient and agentgateway on the path. The findings feed a KubeCon + CloudNativeCon Europe 2027 submission. This is experiment apparatus, not a system intended for any other use.

## Read in this order

1. `docs/PROPOSAL.md` — the experiment design, v6, frozen. It is not edited; anything that would change it goes to `docs/proposal-notes.md` for a human decision.
2. `docs/experiment-a-checklist.md` — Experiment A's checklist, gate by gate, closed on 2026-09-19 with every box ticked. It is history; the Experiment A work done since is in `findings.md`.
3. `findings.md` — one entry per gate, receiver, and mode or run. Numbers first, interpretation second. No entry without a run.
4. `versions.yaml` — every pin with the URL it was verified from. No value without a source.
5. `docs/walkthrough.md` — the step-by-step lab: from a deleted cluster to six Experiment A rows, every command runnable as written and every output taken from one run.

Progress is read from `findings.md` and the dated notes in `docs/proposal-notes.md`, not from this file.

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
| kind | `kind version` | `kind v0.33.0 go1.27.0 darwin/arm64` |
| istioctl | `istioctl version --remote=false` | `client version: 1.31.0` |
| kubectl | `kubectl version --client` | `Client Version: v1.37.0` |
| jq | `jq --version` | `jq-1.8.2` |
| docker | `docker --version` | `Docker version 29.7.2, build a7dcaa6` |
| docker buildx | `docker buildx version` | `github.com/docker/buildx v0.36.1-desktop.1 83d819cf8237b52ef45a2a9857eeb83a7b10977f` |
| uv | `uv --version` | `uv 0.12.12 (Homebrew 2026-09-09 aarch64-apple-darwin)` |
| kubescape | `kubescape version` | `4.0.14` |
| helm | `helm version` | `v4.3.0` (GitCommit `bec5b06ed841fe5269972d864d5177944fd5970f`, Go `go1.27.1`) |
| go | `go version` | `go version go1.27.1 darwin/arm64` |

`ko apply`/`ko build` are called with `--platform=linux/$(go env GOARCH)`
throughout the Makefile and `experiments/*.sh`, so the built images match
whatever architecture this machine's Go toolchain reports — no per-host edit
needed.

Helm's repository cache can be empty while its repository list
(`~/Library/Preferences/helm/repositories.yaml` on macOS) is not, and then an install
with `--repo <URL>` can fail on a missing index file; `helm repo update` repopulates
the cache. This was observed on the author's machine on 2026-09-15, after a macOS
upgrade, with the error fragment `no cached repo found … cilium-index.yaml`; it was not
reproduced for this README, since that would mean emptying the cache, and no record of
it is committed.

### Istio and agentgateway through Helm; istioctl for debugging

Istio, the agentgateway control plane and the three telemetry components are
installed by Helm and by no other route. Helm is a requirement: without `helm` on
PATH, a `make` command line that names `step-2` or `step-3` — the two goals whose
recipes call helm — stops while make reads the Makefile, with a message naming
those goals, so no goal on that line runs: `make step-1 step-2` runs neither, and
`make -n` stops the same way. `step-2b` left that list on 2026-09-19, when its two
Helm installs moved to step 2 and its recipe stopped calling helm; it parses and
runs without helm on PATH, and it still needs a host that has helm, because it
applies on top of step 2. The demonstration of the check, before and after it
moved to parse time, is `experiments/runs/2026-09-15-ingress-namespace/guard/`,
taken on 2026-09-15 when the list also held `step-2b`, which is why its last two
readings show that goal stopping too; and `make -n step-2 step-2b step-3` with
helm on PATH, as the targets were that day, is committed as
`experiments/runs/2026-09-15-ingress-namespace/make-n.txt`.

| Component | Route |
| --- | --- |
| Gateway API CRDs | `kubectl apply --server-side -f <release>/experimental-install.yaml` — the project publishes no chart |
| Istio (base, istiod, cni, ztunnel) | four charts at `1.31.0` from `https://blob.istio.io/istio-release/charts`; istiod takes `deploy/step-2-ambient-agw/istio-values.yaml`, ztunnel `ztunnel-values.yaml`, cni `--set profile=ambient` |
| agentgateway control plane | two OCI charts at `v1.5.0` from `oci://cr.agentgateway.dev/charts`, with `deploy/step-2-ambient-agw/agentgateway-values.yaml` — the project documents no other install |
| Collector | chart `opentelemetry-collector` `0.173.1` with `deploy/step-3-stress/otel-collector-values.yaml` |
| Trace backend | chart `jaeger` `4.13.1` with `deploy/step-3-stress/jaeger-values.yaml` |
| Prometheus | chart `prometheus` `29.31.1` with `deploy/step-3-stress/prometheus-values.yaml` |

istioctl remains a prerequisite, as this lab's debugging client and not its
installer: the certificate check in `make step-3` and in the experiment scripts reads
`istioctl ztunnel-config certificates`, the mTLS probe and the rebuild readings read
`istioctl ztunnel-config workloads`, and run records name the client and mesh
versions with `istioctl version`. Those reads were recorded with the client at the
pinned `1.31.0`, so it must match the pin, and `make step-2` refuses any other.

Until 2026-09-15 a host without helm installed Istio with `istioctl install` and an
IstioOperator file, and the telemetry components from manifests in
`deploy/step-3-stress-nohelm`; both routes were retired that day on the author's
direction, because Istio recommends Helm and agentgateway has no route but Helm, so
a rebuild without helm was never reproducible end to end (`findings.md`, "Gate 3 /
both receivers / Helm-first installation"), and the records that the Helm values
and charts carry every setting and object those routes carried are in
`experiments/runs/2026-09-15-helm-only/`.

Every chart version and every values key used is recorded in `versions.yaml`
with the URL it was read from. A chart's optional sub-components are disabled and
each disable is stated in the values file: the Prometheus chart's four subcharts
(`alertmanager`, `kube-state-metrics`, `prometheus-node-exporter`,
`prometheus-pushgateway`) and its `configmap-reload` sidecar; the collector
chart's nine presets, its cluster role and its `PodMonitor`/`ServiceMonitor`; the
Jaeger chart's OAuth2 sidecar, its Ingress and HTTPRoute, its NetworkPolicy
(`networkPolicy.enabled: false`), the three Elasticsearch maintenance jobs
(`esIndexCleaner`, `esRollover`, `esLookback`) and the Spark job. The scope rule this serves is
CLAUDE.md's rule 6: the component list is fixed, and a chart default is not a
reason to widen it.

Workload certificates are issued for **seven days**, by the author's decision of
2026-09-12, and it takes two settings rather than one. istiod's
`DEFAULT_WORKLOAD_CERT_TTL` is "Applied when the client sets a non-positive TTL in the
CSR" — and ztunnel *does* set a positive TTL in its CSR, so that variable never governs
a ztunnel leaf. What lengthens the leaves is ztunnel's own `SECRET_TTL`, which defaults
to 24 hours in ztunnel's source; `MAX_WORKLOAD_CERT_TTL` already permits seven days at
its 2160h default and is left alone. Both are set —
`pilot.env.DEFAULT_WORKLOAD_CERT_TTL` in `istio-values.yaml` and `env.SECRET_TTL` in
`ztunnel-values.yaml` — and the rendering was checked to put the variables in their
containers, not only in the values ConfigMap.
`versions.yaml` key `istio-workload-cert-ttl` carries the quotes. The separate
non-renewal quirk this lab has recorded is not addressed by this.

The agentgateway **controller** is outside the mesh because its namespace is.
`agentgateway-system` holds the control plane only and is not labelled ambient; the
ingress Gateway and its proxy run in a namespace of their own, `agentgateway-ingress`,
which the step-2b overlay creates with the ambient label. Three clients reach the
controller. Two are outside the mesh and speak plaintext to it: `agw-central`'s XDS
on 9978, and Prometheus's scrape of 9092. The third is the ingress proxy, which since
this change dials XDS from inside the mesh, across the namespace boundary.
Until follow-ups 12 (2026-09-15) the ingress ran in `agentgateway-system`, as in the
example on agentgateway's ambient-ingress page, and `make step-2b` labelled that whole
namespace for the ingress *proxy*'s sake, which captured the controller too. On the
from-scratch rebuild of 2026-09-12 ztunnel refused the scrape under mesh-wide STRICT,
naming the policy, and the then-separate egress proxy's XDS dial was reset, so it never
became ready; the older cluster had masked it because that XDS stream predated the policy and
ztunnel enforces per connection. The remedy then was a per-pod opt-out,
`istio.io/dataplane-mode: none` through the chart's `podLabels`; the namespace of its
own replaced it, and the controller pod carries no label of this lab's. The page's
requirement — "both the namespace that runs the agentgateway ingress
proxy and the namespace that runs the backend must be ambient-enabled" — still holds.
`versions.yaml` keys `agentgateway-controlplane-ambient-optout` (superseded) and
`agentgateway-ingress-namespace`.

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
sources have not changed but whose image has. A second gap of the same
family: the stamp hashes the index (`git ls-files -s`) while `ko` builds the
working tree, so the five step targets refuse to run while the hashed Go
paths carry uncommitted changes (`check-go-sources-clean`), the same refusal
the harness applies before a row. That trade is deliberate:
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
built from `agents/orchestrator/Dockerfile` under the fixed tag
`orchestrator:dev` and loaded into kind, so changing anything under
`agents/orchestrator/` needs `make orchestrator-image` followed by
`kubectl -n lab rollout restart deployment/orchestrator`. A `kubectl set env`
on that Deployment restarts the pod onto the image already loaded under that
tag, which is the old one; a run that only sets an environment variable will
measure the code that was there before. This was measured the hard way in
Gate 2 A.2. That image is also where the agent's telemetry comes from: it
carries the OpenTelemetry distro as a dependency and its `CMD` starts the
process under `opentelemetry-instrument`, so nothing has to be injected into
the pod and `make step-3` installs no Operator to inject it.

That Dockerfile replaced Cloud Native Buildpacks on 2026-09-10 by the author's
decision, and was itself replaced the same day, by the same decision, with the
one described here. It is three stages. A **builder** on
`public.ecr.aws/amazonlinux/amazonlinux:2023` installs `python3.14`, copies the
uv binary in from `ghcr.io/astral-sh/uv:latest`, and resolves `/app/.venv` from
the lockfile per uv's own Docker guide (`UV_COMPILE_BYTECODE`, `UV_LINK_MODE=copy`,
`UV_PYTHON_DOWNLOADS=0`, a `--no-install-project` dependency layer over
bind-mounted `uv.lock` and `pyproject.toml`, then `--no-dev --no-editable`), with
`UV_PYTHON=/usr/bin/python3.14` so the environment is built against the same
interpreter file the image will run. A **rootfs** stage on the same base assembles
the runtime root under `/rootfs` with `dnf --installroot`, which is the route the
AL2023 user guide documents for this — "Using the `--installroot` option to `dnf`
in this manner is how we create the other AL2023 images" — including the
`--releasever=$(rpm -q system-release --qf '%{VERSION}')` idiom that pins the new
root to the release of the base building it. The **final stage is `FROM scratch`**
and holds that root, the virtual environment and the agent package, and nothing
else. `--no-dev` keeps the dev dependency group — pytest and pytest-asyncio — out
of it, which is what `project.toml`'s `UV_NO_DEFAULT_GROUPS=1` used to do.

**That image has no shell.** Three packages are asked for by name — `python3.14`,
`system-release`, `ca-certificates` — `bash` and `coreutils` are removed from the
assembled root with `rpm -e` afterwards, and `dnf`, `rpm` and `microdnf` are never
installed into it at all; 45 packages and one `gpg-pubkey` entry remain, and
`/usr/bin` holds 25 files. The practical consequence for anyone working on this
lab: **`kubectl -n lab exec deploy/orchestrator` can only run `python`**, so every
in-container proof in `experiments/runs/` is a `python -c …`, and on the host the
same checks are `docker run --rm --read-only --user 65532:65532 orchestrator:dev
python -c …`. `rpm -e` rather than `rm` is deliberate: deleting the files would
leave the RPM database claiming a shell and a coreutils that are not there, and a
scanner would go on matching those versions against advisories. For the same
reason the RPM database and `system-release` **stay** — they are how a scanner
identifies the distribution and enumerates what is installed, and without them an
assembled root scans as an unidentifiable pile of files. The same stage prunes the
documentation, man and message-catalogue trees but **keeps glibc's locale archive**
at `/usr/lib/locale`, on the author's decision of 2026-09-11 taken after the cost
was measured. In this root the archive holds one locale, `C.utf8`, 12 files and
351817 bytes of content; keeping it costs **364032 bytes** on the exported root
filesystem, 186213888 → 186577920, an increase of 0.20%; and what it buys is that
`locale.setlocale(LC_ALL, "C.UTF-8")` returns `C.UTF-8` rather than raising
`unsupported locale setting`, which is what it did while the tree was removed.
`en_US.UTF-8` raises either way, the root carrying `glibc-minimal-langpack` and no
language pack, and `/usr/share/locale` — the message catalogues — is still removed.
Nothing counted here reads a locale in the first place: no `.py` file under `/app`,
the agent's or a dependency's, so much as mentions `setlocale`. Both sides are
measured in `experiments/runs/2026-09-10-orchestrator-al2023/locale-and-ownership.txt`
— the removed side in that run's `pre-locale/` — which also records which packages
still claim the trees that stage removes by path.

**Every base image of ours is referenced by tag, not by digest** —
`public.ecr.aws/amazonlinux/amazonlinux:2023` in both Amazon Linux stages,
`ghcr.io/astral-sh/uv:latest` for the installer, and
`gcr.io/distroless/static-debian13:nonroot` in `.ko.yaml` for the four Go
binaries (that base's config reads `User=65532`, the uid every Pod template
declares). That is the author's decision of 2026-09-10, taken against uv's own
advice to pin a digest: the lab wants the latest patched base and the latest uv at
every build, and AWS documents `:2023` as exactly that tag — "To get the latest
version of the AL2023 container image, use the `:2023` tag". What replaces the pin
is a record rather than nothing. `make orchestrator-image` passes
`docker build --pull --no-cache`. `--pull` re-resolves both tags at every build,
and a moved uv tag reaches the image on that alone: the resolved digest is part
of the `COPY --from` step's cache key, so a new digest is a cache miss on that
step. `--no-cache` (the author's decision of 2026-09-11) is for the two `dnf`
RUNs, whose cache key is their parent layer and command text and holds no
repository state: over a warm cache, a package update published between
base-image digests reached the image only on a cache miss
(`experiments/runs/2026-09-11-orchestrator-nocache/cache-measurement.txt`).
Building without the layer cache costs time: the first such
`make orchestrator-image` took **37 s** on this host, 35 s of `docker build` and
2 s of `kind load` onto both nodes, where the cached build that
`experiments/runs/2026-09-10-orchestrator-al2023/build.txt` records took 2.4 s
by Docker's build history (record `bagnfgltz9w7b7zz0o86vc7tn`). The builder stage
runs `uv --version`, the rootfs stage prints the release it pinned itself to and
the whole `rpm -qa` list into the build log (`--progress=plain` keeps it, and no
package-list file is written into the image), ko prints the base digest it
resolved, and each run record under `experiments/runs/` keeps the digests and
versions that build produced. `versions.yaml` records the tags as the pins with
that decision dated, beside the values observed. The rootfs stage also runs
`dnf … upgrade` in the same `RUN` as the install, so a base image lagging a
security update does not reach the cluster, and without the layer cache that
`RUN` executes at every build; on 2026-09-10 it applied nothing, "Nothing to do.",
the `:2023` tag already being at release 2023.12.20260909, and on 2026-09-11, at
the first build without the layer cache, it printed "Nothing to do." again, the
base still at that release.

The image runs as uid:gid 65532:65532, the uid of the distroless base `.ko.yaml`
uses for the Go images, so every workload of ours in the cluster runs as one uid,
and it needs no writable root filesystem. Its application files are owned by
**root** and only readable by that uid, so the process cannot rewrite its own code
or its own dependencies. Counted in
`experiments/runs/2026-09-10-orchestrator-al2023/`, the assembled root as it now
ships against the `python:3.14-slim` image it replaced: exported root filesystem
**220009472 → 186577920 bytes** (209.8 → 177.9 MiB, 84.8% of the former),
`docker image inspect` `.Size` **67132499 → 52750200 bytes** (64.0 → 50.3 MiB, that
field being the sum of the gzipped layers rather than the same quantity), layers
9 → 5, architecture arm64 in both, interpreter **CPython 3.14.7** in both. The
first count of the assembled root, taken on 2026-09-10 before the locale archive
was kept, is that run's `pre-locale/` directory: 186213888 and 52685920 bytes.
The earlier move off Cloud Native Buildpacks is the record before that, in
`experiments/runs/2026-09-10-images-rebuilt/`: it took the root filesystem from
294316 KiB to 239488 KiB and the architecture from emulated amd64 to arm64, the
pack builder having published no arm64 image at any tag (`versions.yaml` key
`pack-builder`; the candidates surveyed are in
`experiments/runs/2026-09-10-pack-multiarch/builder-survey.txt`), and it counted
every package in the lockfile as installing on 3.14 from a wheel, none from
source.

`make scan-images` runs the Kubescape CLI over the five images this lab builds —
the Python agent and the four Go binaries — and writes, under
`experiments/runs/<date>-image-scan/` by default (`SCAN_OUT=` to put it
elsewhere), one JSON and one text report per image, one `<image>-findings.csv`
per image derived from that JSON by `experiments/lib/kubescape-findings.jq`
(`id,severity,package,version,fixed_in,type`, where an empty `fixed_in` means no
fix is available), a `summary.csv` of counts by severity, and a
`scan-context.txt` naming the scanner version, its vulnerability-database date,
the command, and the digest of every image scanned against the image each lab
pod is running. The 2026-09-10 scan the findings entry cites was written beside
the run whose images it scanned, in
`experiments/runs/2026-09-10-images-rebuilt/scan/`. It is a **host-side CLI
only**: nothing is installed in the cluster — no Operator, no node agent — so the
cluster's component list is unchanged. It exits 0 whatever it finds, and **nothing
in this repository is fixed in response to a scan**: counting what is there on a
given date is the job, and a fix is the author's decision. The scanner was added
on 2026-09-10 by that decision, recorded in `docs/proposal-notes.md`.

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

Step 2b adds the agentgateway ingress in front of Agent A and gives `agw-central`
the model host as well, so both agents' model calls leave through the same proxy,
and counts the same four run types through them (`RUN4_URL` sends run
4 in through the ingress; the other three enter at the worker):

```
make step-2b && STEP=2b REPS=5 RUNS="1 2 3 4" \
  RUN4_URL=http://agentgateway-ingress.agentgateway-ingress.svc.cluster.local \
  experiments/gate1-baseline.sh
```

Step 2c adds the Gate 2 stimulus paths. It gives the orchestrator Service its own
hostname route on `agw-central` and binds that Service to it, so an in-cluster
stimulus to either receiver crosses the waypoint, and gives the worker its own
hostname on the step-2b ingress, so an out-of-cluster stimulus can reach either
receiver. It applies on top of step 2b:

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
ztunnel-captured, so the request traverses `agw-central` on the receiving
Service's own route; `make ledgers` reads its two client lines from the pod log. `VIA=ingress`
runs the harness on this host through a `kubectl port-forward` to the ingress
Service, and with `OUT` writes the two client lines to `<OUT>/client.jsonl`,
which `make ledgers OUT=<dir>` then keeps rather than overwriting. The name is
`VIA` and not `PATH` because a command-line `PATH=` assignment is exported into
every recipe's shell.

Both receiver Services are bound to the one proxy `agw-central`, each with a
hostname-matched route of its own, and the out-of-cluster path carries no waypoint
at all because the agentgateway ingress dials the backend pod rather than the
Service VIP. Until 2026-09-19 the two receivers had one istiod-driven waypoint
each, because a single shared istiod-driven waypoint was measured to misroute;
that class of waypoint is retired here by the author's decision of that day, and
the measurement, the draft issue in `docs/upstream/` and what supersedes them are
recorded in `deploy/step-2c-gate2/kustomization.yaml` and in the dated notes in
`docs/proposal-notes.md`.

mTLS is enforced, not merely available. `deploy/step-2-ambient-agw/peer-authentication.yaml`
is a mesh-wide STRICT `PeerAuthentication` in the root namespace, with the
document sentence behind each of its fields, and from step 2 on a plaintext
request from a pod outside the mesh is refused: measured at HTTP 200 before the
policy and `Recv failure: Connection reset by peer` under it, for both agents.

Three other choices make that hold for the lab's own traffic, and all three are
deliberate rather than incidental. The mock model **opts out of ambient**
(`istio.io/dataplane-mode: none` in `deploy/base/mockllm.yaml`): it stands in for
an external provider, so `agw-central`'s call to it on the model route is this
lab's external plaintext leg, and a captured mock refused that call when STRICT
was first applied. The agentgateway ingress pod's metrics port gets one port-level
exception (`deploy/step-2b-agw-ingress-egress/peer-authentication-ingress-metrics.yaml`,
`portLevelMtls: {15020: PERMISSIVE}`, in the ingress's namespace), because Prometheus
runs outside the mesh and its scrape is plaintext into a captured pod; without it that
scrape target went down. Whether ztunnel honours a port-level mode is not stated by any
current Istio page — it is measured here, and the file says so. And the agentgateway
**control plane is outside the mesh**, by its namespace: the ingress proxy runs in
`agentgateway-ingress`, which is enrolled, and `agentgateway-system`, which holds only
the controller, is not. The controller is infrastructure, not the traffic path — it
serves XDS over its own TLS and carries no agentgateway traffic. Two of its three clients
speak plaintext to it from outside the mesh: `agw-central`, whose own namespace is
unenrolled by agentgateway's documented egress shape, and Prometheus. The third is the
ingress proxy, which dials it from inside the mesh, across the namespace boundary.

This was found late, on a from-scratch rebuild on 2026-09-12, when the ingress
still shared the controller's namespace and that namespace was enrolled: ztunnel
refused Prometheus's scrape of the controller under STRICT, naming the policy,
and the then-separate egress proxy's XDS dial was reset, so it never became ready. The
earlier cluster had hidden it, because that proxy's XDS stream there had been
opened before the policy — on 2026-09-12 itself, after the controller's last
restart — and ztunnel enforces per connection; so a rebuild from a deleted
cluster is the test for any change to who is captured. The fix then was a
per-pod opt-out on the controller; on 2026-09-15 (follow-ups 12) the ingress
moved to its own namespace and the opt-out went.

The `telemetry` namespace stays **out** of the mesh on purpose. An in-mesh
collector would enforce mTLS on inbound OTLP and so refuse the spans of every
emitter that is not ztunnel-captured — the mock and `agw-central` — and the trace
would lose exactly the hops step 3 works to light up.

The counts, both attempts, and the per-hop connection security from ztunnel's
`istio_tcp_connections_opened_total` are the findings entry
`## Gate 3 / both receivers / mTLS enforced`, with outputs under
`experiments/runs/2026-09-12-mtls-enforced/`: every ztunnel-captured hop of both
flows reads `mutual_tls`, the two agentgateway-terminated legs have no ztunnel
series at all because each proxy terminates HBONE under its own identity, and
under the shipped shape the model leg has no receiving ztunnel to report. Traces
were unchanged at 66 and 12 spans with no dangling parent and no dark hop, the
figures of that date, so enforcement cost no observability. The same shape was counted again on the
topology of 2026-09-19 in `## Gate 3 / both receivers / topology`: every mesh leg
reads `mutual_tls` there too, and plaintext is still refused.

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

Neither SDK offers a retry, so the retry is the lab's own and it is opt-in. The
three retry knobs are `CLIENT_RETRIES` and `CLIENT_SDK_RESEND`, which both
clients have, and `CLIENT_TRANSPORT_RESEND`, which is the orchestrator's alone;
they all default to off, each has a unit test that fails if that default changes,
and this script is the only thing that switches one on — through the Job template
`deploy/base/loadgen-a2-job.yaml` for the Go client, and through
`kubectl set env` on the orchestrator, with the pre-run values recorded and
restored on exit, for the Python one. The failure the client is asked to retry is
one `close-after-read` armed at the worker for the repetition's work item, which
counts the arrival and then takes the connection away.

`CLIENT_RETRY_ON` says what the HTTP-layer resend acts on, and it matters here
because of what the proxy in front of the receiver does: `transport`, the default,
is a transport error only, and a receiver-side connection close never reaches the
client as one, because that proxy answers 503 for it (measured on both hops in
`experiments/runs/2026-09-09-a2-go-http/waypoint-503-probe.txt`). `transport+503`
also re-sends once on a 503, and on no other status. Both modes are run and both
are recorded. The mode is not a switch: with no HTTP-layer resend on there is
nothing to widen, and the script refuses the mode on rows that have none.

The load client reads four `CLIENT_*` variables — `CLIENT_RETRIES`,
`CLIENT_SDK_RESEND` and `CLIENT_RETRY_ON` above, and `CLIENT_DIAL`. The fourth is
**not** a retry knob and re-sends nothing. It says where the client sends after
it has resolved the agent card: unset or empty — its value on every row but the matrix's
`SUB=service` ones — the client sends to the URL the card advertises, which is
what it has always done; `target` makes it send to the address it resolved the
card at instead. It takes those two values and no others, and an unknown value
stops the Job with exit 2 before anything is sent, where an unknown retry-knob
value would not. The Job template renders all four of these variables at every
row, so no row can leave one on by forgetting it.

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
OpenTelemetry Collector, a Jaeger v2 trace backend and Prometheus.

The three components are installed from their charts. `deploy/step-3-stress`
carries step 3's *configuration* — the namespace, the two `AgentgatewayPolicy`
pairs and the three Deployment patches — and `make step-3` applies it before the
three `helm upgrade -i` calls.
No OpenTelemetry Operator is installed: the Python agent starts under the
OpenTelemetry distro's `opentelemetry-instrument` launcher, installed in its own
image (see below), and the Operator's injection route was measured in four states
at Gate 3 Task 1 and removed on 2026-09-10 by the author's decision. The counts
that route produced stay in `findings.md`, and the `opentelemetry-operator` and
`otel-python-autoinstrumentation` keys stay in `versions.yaml` marked as not used,
as the record those entries cite.

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

Prometheus scrapes five jobs: `istiod` on `:15014/metrics`, `ztunnel` on
`:15020/metrics`, `agentgateway-proxies` on `:15020/metrics` (`agw-central` and
the ingress, selected by the `gateway.networking.k8s.io/gateway-name` label the
controller puts on them), `agentgateway-controlplane` on `:9092/metrics`, and
the collector's own endpoint. Read them with
`curl http://prometheus.telemetry.svc.cluster.local:9090/api/v1/targets` from
inside the cluster, or through a port-forward.

One warning about applying this overlay, measured the hard way on 2026-09-12.
**A plain `kubectl apply -k deploy/step-3-stress` is not a safe way to push a
telemetry change.** The overlay carries the Go Deployments, whose images are
`ko://` references that only `kubectl kustomize … | ko apply` resolves, so a
plain `apply -k` writes the literal `ko://` string into `deployment/worker` and
`deployment/mockllm` and each gains an `InvalidImageName` pod beside its running
one. It happened here while applying a telemetry-only change and was undone with
`kubectl -n lab rollout undo deploy/worker deploy/mockllm`: the Deployments
returned to their `kind.local` images, the `lab.agent-mesh/go-sources` guard
annotation was intact, and the serving pods never changed. Apply a telemetry-only
change by file — `kubectl apply -f` the manifests it touches — or run `make
step-3`, which pipes through `ko`.

The agentgateway-driven proxies report on three channels, and only two of
them are OTLP at v1.5.0. Traces and access logs go to the collector: each of
the ingress and `agw-central` carries an `AgentgatewayPolicy` with
`frontend.tracing` and one with `frontend.accessLog.otlp`, and the collector
grew a `logs` pipeline whose only exporter is `debug`, so records are counted
rather than stored. Turning OTLP access logs on takes nothing away, because the
project's page says export "happens in addition to the standard stdout output";
the stdout access logs earlier runs read are unchanged. Metrics are the third
channel and stay a scrape: v1.5.0 documents no OTLP metrics exporter for the
proxy, and `frontend.metrics` carries only label additions. Prometheus now also
scrapes the agentgateway control plane on port 9092, which the
`agentgateway-proxies` job never reached because that job keeps only pods
carrying `gateway.networking.k8s.io/gateway-name` and the controller pod carries
none. The control plane documents no tracing of its own, so it contributes
metrics and nothing else.

Istio's own tracing configuration is entirely in the `meshConfig` block of
`deploy/step-2-ambient-agw/istio-values.yaml`, which `make step-2` installs with
the istiod chart: one OpenTelemetry extension provider named `otel-tracing`
pointing at the collector's OTLP gRPC port, in the shape the Istio OpenTelemetry
task gives for it, named under `defaultProviders.tracing` at 100% sampling.
What it covers is narrower than it looks. ztunnel emits no spans, by design: it
is the L4 layer, and since 2026-09-19 every L7 hop belongs to a proxy under
agentgateway's own control plane, which istiod does not configure. So no Istio
`Telemetry` resource ships here at all; the step-3 overlay carries none, and the
provider stays as the documented default.

Until 2026-09-19 step 3 also carried two `Telemetry` resources and a
`config.tracing` document delivered through each istiod-driven waypoint's
`parametersRef`, because the Telemetry API was measured on 2026-09-12 not to
reach those waypoints — the counts did not move and `/config_dump` still read
`"tracing": null` on both — while that document did, taking the worker path from
8 spans to 12 and the orchestrator path from 62 to 66 and closing every dangling
parent. That class of waypoint is retired, so both files went with it; the counts
they produced stay in `findings.md`. What makes the proxies emit now is the one
`AgentgatewayPolicy` per Gateway described just above.

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
named in its image's `CMD`, configured only by the environment the step-3
overlay sets. `make step-3` installs no Operator and the step-3 overlay holds no
`Instrumentation` resource; that route was measured in four states, not kept,
and removed from step 3 on 2026-09-10 and from the cluster the same day, and
`findings.md` carries the counts. The ingress and `agw-central` export because
one `AgentgatewayPolicy` each says so. Because an A2A request keeps the work item
inside `Message.metadata`, where no HTTP instrumentation can see it, every lab
client also sends it as a header, and the Go handler wrappers and the Python
header capture put it on the span, so a work item is queryable. Reading one
work item gives two traces, not one: the client fetches the agent card and
sends the message as two separate roots.

Two of those spans are named after operations rather than after HTTP verbs, and
they are the lab's own agentic work: every model call is a `chat <model>` span
and every A2A call is an `invoke_agent <name>` span, as the OpenTelemetry GenAI
semantic conventions describe them. Those conventions live in their own
repository, publish no release, and read **Status: Development**; the commit this
lab read, the pages, and every rule taken from them are recorded in
`versions.yaml` under `genai-semantic-conventions`. The two sides get there
differently, and the asymmetry is the point. Python installs a package:
`opentelemetry-instrumentation-openai-v2`, added to the agent's dependencies and
loaded by the same launcher that loads the Starlette and httpx instrumentations,
so the orchestrator's model call becomes a `chat` span with no code in this
project. Go has no package to install — `opentelemetry-go-contrib` carries no
GenAI, LLM or agent instrumentation, and `a2a-go` has no OpenTelemetry dependency
at all — so `internal/otel` gains two small helpers, `ModelCall` and
`InvokeAgent`, which the worker's model client and the load client call around
the calls they already made. The agent side is by hand in both languages: no
instrumentation knows that an A2A send is an agent invocation, so the load client
says so through `InvokeAgent` and the orchestrator's forward says so through the
one explicit span in `agents/orchestrator/orchestrator/forward.py`. What the
spans carry is what the conventions ask for — the operation, the provider name
(a recorded choice, `versions.yaml` under `genai-provider-name`), the model or
the agent's name, version and description from its card, the endpoint's address
and port, the response id, model, finish reasons and token counts the endpoint
reported, the A2A `contextId` as the conversation, and on a failure the status
the server answered with as `error.type` — plus, on the spans this lab writes,
the four `lab.*` identity attributes, because a span that is not an HTTP span
carries none of the headers the collector's transform reads. What is left unset
is recorded too: `gen_ai.agent.id`, because an A2A v1.0 agent card carries no
agent identifier. The
package's `chat` span carries the `gen_ai.*` attributes and no `lab.*` ones;
`findings.md` counts both sides.

No emitter samples, and since 2026-09-12 every one of them says so in its own
file rather than inheriting a default: the three Go binaries set
`sdktrace.AlwaysSample()` in `internal/otel/otel.go`, the Python agent sets
`OTEL_TRACES_SAMPLER=always_on` in
`deploy/step-3-stress/orchestrator-instrumentation.yaml` (replacing the SDK
default `parentbased_always_on`, which was the one inherited setting), the
agentgateway ingress and `agw-central` set `randomSampling: "true"` and
`clientSampling: "true"` in `deploy/step-3-stress/agentgateway-tracing.yaml`, one
policy each, and Istio's `meshConfig` sets `defaultConfig.tracing.sampling: 100`
in `deploy/step-2-ambient-agw/istio-values.yaml` — with the collector's traces
pipeline carrying no `probabilistic_sampler` or `tail_sampling`, only the
`filter` that drops health-probe spans by design.

Traces come out of the backend one work item at a time:

```
make export-trace LWI=<logical_work_item_id> OUT=<dir>
```

It opens a short-lived port-forward, queries the backend's `/api/v3/traces`
binding for spans carrying `lab.work_item=<id>`, and writes the raw response as
`<dir>/trace.json` and one row per span as `<dir>/spans.csv`, with the columns
`trace_id,span_id,parent_span_id,service,operation,start_us,duration_us,lab_work_item,lab_message_id,http_status,route,retry_attempt`.
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
make retry-on ROUTE=<waypoint|ingress|egress|waypoint-orchestrator> [OUT=<dir>]
make retry-off [ROUTE=<waypoint|ingress|egress|waypoint-orchestrator>] [OUT=<dir>]
```

All four name routes on the two agentgateway proxies. `waypoint` is `lab/worker`,
the worker Service's hostname route on `agw-central`; `waypoint-orchestrator` is
`lab/orchestrator`, the orchestrator Service's route on the same proxy, which a
stimulus crosses only when the client addresses that Service rather than the
ingress URL the card advertises; `ingress` is both routes on the agentgateway
ingress; and `egress` is the model route on `agw-central`. The stanza is
`attempts: 1`, `backoff: 100ms`, and `codes: [503]`, except on the model route,
where it is `[500, 503]` because the failure injected on that hop is the model
endpoint's 500. Both targets are `kubectl apply` of route objects and nothing
else: the manifests under `deploy/step-3-stress/retry/<route>/{off,on}` read the step-2,
2b and 2c route files rather than copying them, and the rendered stream is cut
down to its `HTTPRoute` documents by `experiments/lib/httproute-only.awk`. No
image is built and no Deployment is rolled. Both print how many `retry:` lines
exist across every HTTPRoute in the cluster, and with `OUT` they write the route
objects read back from the API server into `<dir>/routes.txt`. `retry-off` with
no `ROUTE` puts all four route sets back, which is the state every run that is
not measuring a gateway retry has to start and end in.

What each route's retry does to a request is counted by:

```
ROUTE=<waypoint|ingress|egress> REPS=5 experiments/gate3-gateway-retry-mechanics.sh
ROUTE=<waypoint|ingress|egress> DUMP_ONLY=on experiments/gate3-gateway-retry-mechanics.sh
```

That script takes three of the four sets and not `waypoint-orchestrator`, which
it refuses; the matrix is where that route set is counted. It switches the
stanza on, injects one failure per repetition on the hop that
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
make matrix RUN=<baseline|R1|R2|R3|R4|egress> RECEIVER=<go|py> [SUB=<http|sdk|waypoint|ingress|ingress-incluster|service>] [REPS=20]
RUN=<row> RECEIVER=<go|py> [SUB=<sub>] [REPS=20] [DRY_RUN=on|off] [RUN_ID=<nonce>] [RUN_ITEM=<name>] experiments/gate3-matrix.sh
```

`RUN` names the row and `SUB` its sub-row: `R1` has `http` and `sdk`, `R2` has
`waypoint`, `ingress`, `ingress-incluster` and `service`, `baseline` and `R4`
have the one sub-row `service`, and `R3` and `egress` have none.
`RECEIVER` names the SDK under test: `go` is the worker, `py` the orchestrator,
which is put into model mode for its rows by unsetting `DOWNSTREAM_A2A_URL` for
the run and is put back afterwards. `SUB=service` is the author's addition of
2026-09-19: it sets `CLIENT_DIAL=target` in the Job, so the load client still
resolves the agent card at the orchestrator Service and then sends its POST
there instead of to the ingress URL the card advertises.

Which gateway a row means is not the same route for the two receivers, although
both are behind `agw-central`: a stimulus for the worker enters on `lab/worker`,
while the Python receiver's `SendMessage` POST enters through the agentgateway
ingress on `lab/orchestrator-ingress`, because its agent card advertises the
ingress — and enters on its own Service's route `lab/orchestrator` only when the
row addresses that Service. So `R2`'s gateway sub-row is `waypoint` for the Go
receiver and, for the Python one, `ingress-incluster` in-cluster, `ingress` from
outside, or `service` for the route on its own Service; and `R4` composes with
the worker route at the Go receiver and the ingress or Service route at the
Python one. Rows that would switch a retry on for a route the stimulus never
crosses are refused before anything is sent, each with its reason: any row naming
the `waypoint` route set for the Python receiver, because that set is `lab/worker`
alone, with the refusal pointing at `SUB=service` or at the ingress sets;
`waypoint-orchestrator` for any row that does not address the orchestrator
Service; `ingress-incluster` on the Go receiver, because an in-cluster Job to the
worker Service crosses `lab/worker` rather than the ingress; and `SUB=service` on
the Go receiver, because the worker's card advertises the worker Service itself,
so every Go-receiver row the load client sends already addresses that Service.
The per-route stanza assertion cannot catch these cases on its own, since the
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
entered the model route and the proxy's if one call entered it and was sent
upstream twice; since 2026-09-19 the proxy span's hop is keyed on its `route`
rather than on its service name, because one proxy now serves the agent routes
and the model route. `make test` runs the derivation against the twenty committed
fixtures in `experiments/fixtures/derive-layer/` — eighteen taken from real rows,
two synthetic and saying so — comparing both the label and the reason, whole and
unmasked.

The `baseline` row asserts rather than assumes: zero `retry:` stanzas across
every HTTPRoute, no `CLIENT_*` on any Deployment, the receiver's model-retry knob
read back off the live object, and the Job rendered with all four `CLIENT_*`
variables at their off values — the three retry knobs off and `CLIENT_DIAL`
empty. Its injection is one `close` at the model endpoint, as Gate 1's baseline
used, so the failure is raw and any second delivery would be somebody's retry.
Every invocation runs its own one-repetition dry run first, under a scratch work
item whose directory is deleted, and every work-item id carries the run's
wall-clock nonce, because the trace backend and the pod logs both outlive a run.

**A cluster that has been up for a while on a laptop.** ztunnel renews a workload certificate on a deadline it
computes once, from a monotonic clock that does not advance while the Docker Desktop VM is paused by host sleep, so
every renewal after the first is late by all the sleep accumulated since ztunnel started, and stays late until
ztunnel restarts. Observed on 2026-09-08 with the then 24-hour leaves — after a day of sleep/wake cycles every mesh
hop failed with "certificate expired" while the agentgateway proxies had renewed their own — and reproduced with its
cause on 2026-09-19 (`## Gate 3 / both receivers / ztunnel certificate renewal across host sleep`). At the seven-day
leaves this lab now issues the margin is 84 h 01 min of accumulated sleep. Before any mesh run on a cluster that has
been standing, check `istioctl ztunnel-config certificates --node agent-mesh-lab-worker` and, if `VALID CERT` is
false, run `kubectl -n istio-system rollout restart ds/ztunnel` and record it.

## Working rules

The rules for anyone, or any agent, working in this repository are in `CLAUDE.md`: done means a recorded count; pins come from documents fetched in the session; fixtures never retry; ledgers before agent logic; scope is fixed; the A2A target is v1.0; kind first; one checklist box per task.

## License

Apache License 2.0. See `LICENSE`.

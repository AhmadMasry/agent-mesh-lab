# Currency pass of 2026-09-25, Phase 1: every pin against its latest stable release, the moves, the local proof, the impact list

The author's note of 2026-09-25 (docs/proposal-notes.md, the last note): a full dependency upgrade, triggered by a2a-go
v2.6.0, then a rebuild from a deleted cluster, the standard proof, and a re-count of every row a moved dependency could
change. This directory is Phase 1: no cluster was touched (no kubectl, helm install, kind or make step target, and not
make orchestrator-image or make scan-images, which load into and read the standing cluster). The cluster-side proof,
the read-back of every moved pin and the approved rows are Phase 2's, in experiments/runs/2026-09-25-currency-rebuild/,
after the controller's ruling on impact.md. No findings entry ships with this directory.

Every value in pins.csv was read from a document fetched in the session of 2026-09-25 (16:19Z to 16:42Z); sources.tsv
holds the URL, fetch stamp, HTTP status, size and sha256 of each of the 236 documents, all HTTP 200. Nothing is from
memory. No alpha, beta, release candidate, dev or nightly build was a candidate.

## Counts

pins.csv: **97 rows: 25 moved, 53 already current, 4 held, 15 with no stable line** (12 of the 15 moved or added, 3
unmoved). 37 values changed in the tree: 25 + 12, two of the 12 being packages the lock added.

| Moved (25) | from | to |
| --- | --- | --- |
| a2a-go | v2.5.0 | v2.6.0 (its own commit, with the test it needed) |
| a2a-sdk (a2a-python) | 1.1.4 | 1.1.5 |
| openai (openai-python) | 3.16.2 | 3.19.2 |
| uvicorn | 0.53.0 | 0.54.0 |
| OpenTelemetry Python OTLP/HTTP exporter | 1.44.0 | 1.45.0 |
| Istio | 1.31.0 | 1.31.1 |
| Istio charts base, istiod, cni, ztunnel (4 rows) | 1.31.0 | 1.31.1 |
| istioctl, the lab-scoped debugging client | 1.31.0 | 1.31.1 (checksum verified, local/istioctl.txt) |
| Prometheus image | v3.14.0 | v3.15.0 |
| Prometheus chart | 29.31.1 | 29.33.1 |
| Jaeger chart | 4.13.1 | 4.14.0 (image unchanged, 2.21.0, now the chart appVersion) |
| uv.lock google-api-core | 2.38.0 | 2.39.0 |
| uv.lock google-auth | 2.58.0 | 2.58.1 |
| uv.lock googleapis-common-protos | 1.75.3 | 1.75.4 |
| uv.lock httpcore2, httpx2 (2 rows) | 2.13.0 | 2.13.1 |
| uv.lock opentelemetry-api, -exporter-otlp-proto-common, -proto, -sdk (4 rows) | 1.44.0 | 1.45.0 |
| uv.lock protobuf | 6.33.6 | 7.36.2 (the hold of 2026-09-19 lifted) |
| uv.lock starlette | 1.6.0 | 1.7.0 |

No stable line, moved or added (12): the OpenTelemetry Python distro, instrumentation-starlette, instrumentation-httpx,
instrumentation, instrumentation-asgi, semantic-conventions, util-http (0.65b0 to 0.66b0); opentelemetry-exporter-http-
transport and opentelemetry-exporter-otlp-common (added at 0.66b0, new requirements of the exporter 1.45.0); the GenAI
semantic conventions (c88d504a to main head e57c543b); go.mod genproto googleapis/api and /rpc (to the proxy's @latest).
Unmoved with no stable line (3): Gateway API's experimental channel, opentelemetry-instrumentation-openai-v2 2.4b0,
cncf/xds/go.

**Held (4), each with the documents and what lifts it:**
- The kind node image at v1.37.0. Kubernetes v1.37.1 exists (release list; stable.txt), but kind v0.33.0 is still the
  newest kind and defaults to v1.37.0, and the kindest/node tag list has no v1.37.1. Lifts with a v1.37.1 node image.
- google.golang.org/grpc at v1.83.2, below v1.84.0. GHSA-2v4p-qf9q-27wj (updated 2026-09-08) and GO-2026-6443
  (modified 2026-09-15) read as on 2026-09-19, their range containing v1.84.0; no v1.84.1. Measured again: a worker
  image built at v1.84.0 in a scratch copy reads 1 High (GHSA-2v4p-qf9q-27wj) with the vulnerability DB of 2026-09-25,
  the lab's images at v1.83.2 read 0 (local/grpc-hold/, local/scan/). a2a-go v2.6.0's own go.mod requires v1.83.2.
- pydantic-core at 2.46.5: pydantic 2.13.5, PyPI's latest, requires pydantic-core==2.46.5.
- opentelemetry-util-genai at 1.1b0, below its line's 1.2b0 (2026-09-24): 1.2b0 renames the module
  opentelemetry.util.genai.instruments, which opentelemetry-instrumentation-openai-v2 2.4b0 (its newest release)
  imports; openai-v2 declares util-genai>=0.4b0.dev, so the resolver takes 1.2b0 and the orchestrator's test
  collection fails with ModuleNotFoundError (local/util-genai-hold.txt), and the launcher would load no chat span. The
  hold lives in uv.lock (uv lock --upgrade-package opentelemetry-util-genai==1.1b0); the test suite fails at collection
  if a later lock upgrade loses it. Lifts with an openai-v2 release for the new module layout.

**Holds of 2026-09-19 that lifted:** protobuf (a2a-sdk 1.1.5 drops protobuf<7) and the Prometheus advisory note
(v3.15.0 has golang.org/x/crypto v0.56.0, at or above GO-2026-6303's fix).

**Floats and host tools, recorded as observed:** Amazon Linux 2023 at the same digest 06da5a33..., release
2023.12.20260918, python3.14-3.14.7; uv inside the image build 0.12.19 (was 0.12.17), the host's uv 0.12.18;
distroless at the same digest e2e927ec...; kubectl on the host v1.37.1; Docker Desktop 4.92.0 (engine 29.8.0).

**agentgateway** is still v1.5.0: v1.6.0 exists only as alpha.1 and alpha.2, and both OCI charts answer not found for
v1.5.1, v1.5.2 and v1.6.0. Its support table still lists Istio 1.23 - 1.30 for 1.5.x (and Kubernetes 1.32 - 1.37); the
lab runs Istio 1.31.1, one minor above it, as it ran 1.31.0. agentgateway#3369 (sub-second access-line timestamps) is
closed by 98ada8a4, 70 commits after v1.5.0 and reached only by v1.6.0-alpha.2: v1.5.0 still has the defect, so no
figure is taken from an access-line timestamp.

## The commits

1. build(a2a-go): v2.6.0, with the in-process terminal-task subscription test following its answer, -32004. go.mod and
   go.sum (a2a-go alone), fixtures/loadgen/stream_test.go, the a2a-go key of versions.yaml. Test first: the test as it
   was fails at v2.6.0; the changed test fails at v2.5.0 on both its assertions and passes at v2.6.0, each run in a git
   archive copy (local/test-first.txt). No lab code changed.
2. build(pins): the rest of this table, this directory, versions.yaml (every moved key: value, previous, read stamp,
   a dated moved or re-read field, sources; three aggregate keys), go.mod and go.sum (genproto), pyproject.toml and
   uv.lock, the Makefile's chart versions and istioctl check, the Prometheus values tag, and comments that stated the
   running version (the Makefile chart paragraph, the Jaeger and Prometheus values headers, central-gateway.yaml, and
   the GenAI conventions commit in internal/otel/otel.go and agents/orchestrator/orchestrator/forward.py).

## Verified locally, with counts (at the tree of commit 2)

| Check | Result | Record |
| --- | --- | --- |
| go build, go vet, gofmt -l, go mod verify | exit 0, exit 0, no file, all modules verified | local/go-build-and-test.txt |
| go test ./... -count=1 | 9 packages ok, 0 failed | same |
| make test | exit 0: 9 Go packages ok and 21 tool lines ok, 0 FAIL | local/make-test.txt |
| uv lock --check, uv sync --locked, uv run pytest -q | 69 resolved; 254 passed | local/python-tests.txt |
| the lock against PyPI | 68 registry packages: 56 at the latest stable release, 11 with no stable line (10 at their line's latest, util-genai held), 1 held (pydantic-core); 24 moved, 2 added | local/uv-lock-upgrade.txt, local/uv-lock-vs-pypi.tsv |
| the Go module graph | 98 modules to 95: a2a-go and genproto moved, spf13/cobra, spf13/pflag and inconshreveable/mousetrap gone with a2a-go v2.5.0's CLI; 41 modules have a newer version, of which only google.golang.org/grpc provides an imported package (the hold) | local/go-modules.txt |
| ko build of the five Go images into ko.local (make scan-images' own command) | exit 0; base distroless static-debian13:nonroot @sha256:e2e927ec... for all five | local/ko-build.txt |
| the orchestrator image, make orchestrator-image's docker build under the scratch tag orchestrator:cur-2026-09-25 (its kind load line not run) | exit 0; AL2023 @sha256:06da5a33..., release 2023.12.20260918, python3.14-3.14.7-1.amzn2023.0.1, uv 0.12.19 | local/orchestrator-image-build.txt |
| inside that image, read-only, uid 65532, no network | Python 3.14.7; a2a-sdk 1.1.5, openai 3.19.2, protobuf 7.36.2, util-genai 1.1b0; ModelClient max_retries 0 over transport retries 0; httpx2 transport default 0; A2A-Version / 1.0; the openai-v2 instrumentation imports | local/image-retry-settings.txt |
| rule 4 for the Go fixtures | a2a-go v2.6.0's diff adds or removes 0 lines naming retry, backoff, resend or reconnect; the same 9 source files name them at both versions; the fixtures' client packages pass; grpc v1.83.2 | local/rule4-go.txt |
| Kubescape 4.0.14 on the six new images (scan-images.sh's per-image command and jq program; the script itself reads the cluster and scans the tag the cluster runs, so it is Phase 2's) | 0 findings in each of worker, mockllm, loadgen, replay, extauthz, orchestrator; vulnerability DB built 2026-09-25 | local/scan/ |
| kubectl kustomize of deploy/base and the five overlays against b72f2246 | 10, 10, 15, 25, 29, 34 objects; every rendering byte-identical to b72f2246's | local/kustomize-renders.txt |
| helm template of every moved chart, old against new, the lab's values | base, cni, ztunnel: the version string alone; istiod: that and 38 lines of injection-template quoting, all 13 hunks in ConfigMap istio-sidecar-injector; Jaeger: labels alone; Prometheus: labels alone, and the image line from the values file's tag (v3.14.0 to v3.15.0) | local/renders.txt |
| helm pull of the six moved charts | every archive's sha256 equals its index digest | local/charts.txt |
| Prometheus v3.15.0 started read-only with the rendered configuration; promtool check config | "Server is ready to receive web requests", 0 restarts (four Kubernetes service-discovery errors, from running outside a cluster); config valid | local/prometheus-v3.15.0-start.txt |
| make -n step-1 step-2 step-2b step-2c step-3 | exit 0; --version 1.31.1 x4, v1.5.0 x2, 0.173.1, 4.14.0, 29.33.1; the istioctl check greps 1.31.1; Gateway API v1.6.2 experimental | local/make-n.txt |
| the image and chart registries asked by name | agentgateway charts v1.5.1, v1.5.2, v1.6.0 not found; the digests of every image the rebuild will pull | local/registry-reads.txt |

So the only rendered changes are version strings, image references and pinned values, plus istiod's injection-template
quoting, which renders pods this lab does not have.

## The impact analysis

impact.md: for each moved pin on a traffic or telemetry path, what its diff changes that the lab can reach; the rows
proposed for re-count, in three groups (2a: a2a-go#442 changes the answer, B-3's D3 row and D-1's Python-client row;
2b: the rows run through changed lines with the reading predicting the same count, A.3 R3/R4 on the Python receiver,
ztunnel's authorization rows C-3, C-4, C-3R, C-3R2 and D-4 Row Z, C-5, and D-5's connection count; 2c: the
telemetry-path rows the standard proof covers); and the rows not affected, grouped with their reasons. Its evidence:
local/a2a-go-diff.txt, local/python-package-diffs.txt (with local/astdiff.py, the reader it used), local/impact-evidence.txt.

## Code comments that cite a2a-go v2.5.0

Besides the loadgen test line commit 1 moved, 24 lines in agents/, fixtures/ and internal/ (comments and test log
texts) name a2a-go v2.5.0. Those that cite a file and line were compared at v2.5.0 and v2.6.0: a2asrv/rest.go
l.51-60, a2apb/v1/a2av1_grpc.pb.go l.25-35, a2asrv/handler.go l.341 and l.362 are the same. Those that cite a file or
a behaviour: a2asrv/jsonrpc.go, a2asrv/agentcard.go, internal/jsonrpc and a2aclient/jsonrpc.go are byte-identical;
a2asrv/intercepted_handler.go changes interceptAfter's loop form alone (refuse.go's Before is untouched); v2.6.0's
go.mod still has no OpenTelemetry dependency (internal/otel/otel.go); the tests that log or pin a v2.5.0 reading pass at
v2.6.0 (local/a2a-go-diff.txt, local/go-build-and-test.txt). They are left as written: statements of what was read at
v2.5.0 that still hold at v2.6.0.

## What could not be verified here

- Anything on a cluster: the installs at the new pins, the A2A-Version header from a real request at a2a-go v2.6.0
  and a2a-sdk 1.1.5, the spans through the moved exporter, ztunnel 1.31.1's counters, make scan-images itself. Phase 2.
- Kubernetes v1.37.1's own changes were not read: the node image does not move.
- The istiod render difference was read as template text; no pod in this lab is injected, so it was not rendered
  further.

## Host state left by this phase

The images this phase built stay on the host: the five ko.local tags from make scan-images' own ko command (the tags
that command always moves), orchestrator:cur-2026-09-25 (scratch; orchestrator:dev, the tag the cluster was loaded
from, is untouched), ko.local/cur-grpc184/worker (the scratch grpc v1.84.0 build) and prom/prometheus:v3.15.0 (pulled
for the start check). The lab-scoped istioctl 1.31.1 is under the task's own TMPDIR tools directory. No container of
this phase is left. Keep-awake: this phase started none and changed no power setting.

## Note of 2026-09-25, after the controller's ruling on Phase 1

The opentelemetry-util-genai hold described above as living in uv.lock alone was made a constraint in
agents/orchestrator/pyproject.toml ([tool.uv] constraint-dependencies, opentelemetry-util-genai<1.2b0) by the
controller's ruling, in its own commit after this directory's. Under it, uv lock --upgrade keeps 1.1b0; the check is
recorded in experiments/runs/2026-09-25-currency-rebuild/local/util-genai-constraint.txt. The text above is not edited.

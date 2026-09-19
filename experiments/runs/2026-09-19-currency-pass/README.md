# Currency pass of 2026-09-19 (follow-ups 19, task 1): every pin against its latest stable release

The author's direction of 2026-09-19: "take a round on making sure we still use the latest versions of
everything, and update what is needed to be updated to latest version", and "by latest version I always
mean stable release versions". Every value in `pins.csv` was read from a document fetched in the session
of 2026-09-19 (15:07Z to 15:42Z, 196 documents; fix round 1 added 8 at 16:21Z to 16:22Z); `sources.tsv` holds
the URL, fetch stamp, HTTP status, size and sha256 of each of the 204 documents. Nothing is from memory. No alpha, beta, release candidate, dev or nightly
build was a candidate.

**What this directory is not.** No cluster was touched by this task: no `kubectl`, `helm install` or
`kind` call, no `make` step target, and not `make orchestrator-image` either, whose second line loads the
image into the standing cluster. Everything here is a document read or a local build, render or test. So
this is the audit and the local verification of the bumps, and **the cluster-side proof is pending**: the
rebuild from a deleted cluster with the standard proof is follow-ups 19 task 3, and Experiment A's re-run
at these versions is task 4. No findings entry ships with this directory; task 3's entry cites it.

## Counts

`pins.csv`: **84 rows — 11 moved, 57 already current, 3 held, 13 with no stable line** (3 of those 13
moved, each to the latest of the only line it has: the GenAI conventions commit and the two genproto modules;
the other 10 are unmoved). So 14 pins changed value in the tree: 11 + 3. Before fix round 1 this table read
80 rows, 13 / 57 / 3 / 7; no value changed in between, two rows were reclassified and four split out (below).

Three `current` rows carry an OBSERVED value that moved while the pin did not, because the pin floats or
is a host tool: the Amazon Linux 2023 tag (digest 155687eb… → 06da5a33…, release 2023.12.20260914 →
2023.12.20260918), uv's `latest` tag (0.12.15 → 0.12.17) and Docker Desktop (4.90.0 → 4.91.0). Task 3's build
record will therefore read differently from the last entry's on those three without any pin having moved.

| Moved (11) | from | to |
| --- | --- | --- |
| a2a-sdk (a2a-python) | 1.1.2 | 1.1.4 |
| openai (openai-python) | 3.13.0 | 3.16.2 |
| uvicorn | 0.52.4 | 0.53.0 |
| uv.lock google-api-core | 2.36.0 | 2.38.0 |
| uv.lock httpcore2 | 2.12.0 | 2.13.0 |
| uv.lock httpx2 | 2.12.0 | 2.13.0 |
| uv.lock idna | 3.19 | 3.20 |
| uv.lock urllib3 | 2.7.0 | 2.8.0 |
| OpenTelemetry Collector contrib image | 0.160.0 | 0.161.0 |
| Jaeger image | 2.20.0 | 2.21.0 |
| Prometheus chart | 29.28.1 | 29.31.1 |

Plus, under "no stable line", three that moved: the GenAI semantic conventions commit, 0c875949 → c88d504a, and
go.mod's genproto googleapis/api and googleapis/rpc, v0.0.0-20260911204522-f61a6ca850bd →
v0.0.0-20260918162117-cecb64721679 (moved by name).

**Held (3), each with what lifts it:**

- `google.golang.org/grpc` at v1.83.2, below the module proxy's v1.84.0. GHSA-2v4p-qf9q-27wj and
  GO-2026-6443 both still list the affected range 1.84.0-dev to 1.85.0-dev.0.20260825072537-93e31b48545e,
  which contains v1.84.0, while the v1.84.x release branch carries "cherry-pick #9365 to v1.84.x (#9370)",
  the fix, and that cherry-pick (d5a41119) is an ancestor of the v1.84.0 tag (compare: ahead 3, behind 0), so
  the fix is in the release. The hold rests on the two documents and on what the scanner counts, measured on the
  host the same day with the lab's own command (Kubescape 4.0.14, vulnerability DB built 2026-09-19;
  `grpc-scan/`): at v1.83.2, 0 findings in the four Go images; at v1.84.0, built from a scratch copy outside
  the repository, 1 High (GHSA-2v4p-qf9q-27wj, fixed_in 1.85.0-dev.0.20260825072537-93e31b48545e) in each of
  worker, mockllm and loadgen, and 0 in replay, whose binary links no grpc package. The scan reads the
  advisory's range literally; it does not settle whether v1.84.0 carries the fix — the commit list does. Lifts
  when either advisory's range is corrected or the advisories name a fixed release. All three readings:
  `local/grpc-hold.txt`. To keep it, this pass ran no `go get -u ./...`: the two genproto modules were
  moved by name, and `go list -m all` still selects grpc v1.83.2 (`local/go-modules.txt`).
- `protobuf` (uv.lock) at 6.33.6 against PyPI's 7.36.2: a2a-sdk 1.1.4 still requires `protobuf>=5.29.5,<7`,
  and 6.33.6 is the newest 6.x. Lifts when a2a-sdk admits protobuf 7.
- `pydantic-core` (uv.lock) at 2.46.5 against PyPI's 2.49.0: pydantic 2.13.5, PyPI's latest, requires
  `pydantic-core==2.46.5`. Lifts with a pydantic release that names a newer core.

**The hold of 2026-09-12 that lifted:** a2a-sdk. 1.1.3 and 1.1.4 were uploaded to PyPI on 2026-09-18 and
upstream issue a2aproject/a2a-python#1199 is closed as completed (`local/a2a-python-pypi-backfill.txt`).

**No stable line (13: 10 unmoved, 3 moved), each with the document that shows it:**

- Nine packages of the Python lock, every one of the lock's 65 that has never published a final release on
  PyPI (`local/otel-python-no-stable-line.txt`, computed over all 65): opentelemetry-distro,
  opentelemetry-instrumentation-starlette, opentelemetry-instrumentation-httpx (0.65b0; 63, 72, 57 releases),
  opentelemetry-instrumentation-openai-v2 (2.4b0; 5), opentelemetry-util-genai (1.1b0; 6), and the four the
  lock resolves under them, opentelemetry-instrumentation, -instrumentation-asgi, -semantic-conventions and
  -util-http (0.65b0; 73, 70, 61, 63). Unmoved; each is still its package's latest. The lock's 65 packages are
  54 at PyPI's latest stable release + these 9 + the 2 held; "63 of 65 at PyPI's latest" is 54 + 9.
- go.mod's genproto googleapis/api and googleapis/rpc: the module proxy's `@v/list` is empty for both (0
  tagged versions), so pseudo-versions are their only line. MOVED to the proxy's `@latest`.
- Gateway API: v1.6.2 is the newest stable release, but the experimental CHANNEL is the only line that
  carries HTTPRoute retry (still `<gateway:experimental>` at v1.6.2; 2 property lines in the experimental
  CRD, 0 in the standard one). Unmoved.
- OpenTelemetry GenAI semantic conventions: 0 releases, 0 tags, both pages "Status: Development". MOVED to
  main's head (2 commits on). `gen-ai-agent-spans.md` and the attribute registry are byte-identical at
  the two commits; `gen-ai-spans.md` differs in 40 lines, all inside "Execute tool span", a span this lab
  does not emit; its Inference section is identical (388 lines of the file, one sha256). The attribute checker's
  required, expected and never sets therefore read the same (`local/genai-conventions-head.txt`). The
  SHA changed in two code comments (internal/otel/otel.go, agents/orchestrator/orchestrator/forward.py);
  no code changed. Findings entries dated before 2026-09-19 keep the commit they were read at.

**Component ahead of its chart (2).** The collector image (0.161.0) and the Jaeger image (2.21.0) are
each one release ahead of the appVersion of the newest chart that exists: opentelemetry-collector 0.173.1
still declares appVersion 0.160.0 and jaeger 4.13.1 declares 2.20.0, and each is the newest entry of its
repository index as fetched (`local/charts.txt`). Both charts stay at their latest; the image is set
through each chart's own image tag value, which the values files already used. If either pairing fails
on the cluster in task 3, the fallback is the same on both sides: hold that image at its chart's appVersion
(collector 0.160.0, Jaeger 2.20.0) until a chart names the newer release, and that entry says so. For Jaeger
the walkthrough's `/api/v3/services` line would stay, since it answers the same on 2.20.0 and 2.21.0.

**A `current` pin with an advisory named (Prometheus).** v3.14.0 is the latest stable release (v3.15.0 is
rc.0). v3.13.3, on the older line, is a SECURITY patch published 2026-09-07, after v3.14.0: it moves
golang.org/x/crypto to v0.55.0 for GO-2026-6303 and klauspost/compress to v1.18.7 for GO-2026-5841. go.mod at
v3.14.0 has compress v1.19.1 (at or above the fix) and **x/crypto v0.54.0, inside GO-2026-6303's range**
(fixed 0.55.0). The pin stays at v3.14.0 by the controller's ruling: the author's rule is the latest stable
release, and `make scan-images` reads the lab's five images only, so no count of the lab's is touched. The
note lifts with a v3.14.1 or a stable v3.15.0 (`local/prometheus-security-patch-note.txt`).

**A recorded document, not a pin:** agentgateway's support table still gives 1.5.x the Istio range
1.23 - 1.30; the lab runs Istio 1.31.0, one minor above it. Neither agentgateway (v1.5.0; v1.6.0 exists
only as alpha.1) nor Istio (1.31.0) moved, so the pairing every count ran on is unchanged. That no 1.5.x
patch exists was also asked of the chart registry by name: both OCI charts serve v1.5.0 and answer not found
for v1.5.1, v1.5.2 and v1.6.0 (`local/agentgateway-oci-next-versions.txt`).

## Moved pins that experiment traffic crosses — what their release notes say that bears on Experiment A

Task 4 re-measures Experiment A on these. Experiment traffic crosses a2a-sdk, openai with httpx2/httpcore2, and
uvicorn (`TRAFFIC` in `pins.csv`); the collector and Jaeger are on the telemetry path, which the spans cross and
the requests do not (`TELEMETRY PATH`), and are listed because Experiment A's layer labels are derived from spans. Istio, agentgateway, Gateway API, a2a-go, the OpenTelemetry Go
modules and the OpenTelemetry Python instrumentations did NOT move.

**a2a-sdk 1.1.2 → 1.1.4** (the Python receiver and the Python client). The A2A wire constants are
byte-identical (`A2A-Version`, `1.0`). From the release notes, verbatim:

- 1.1.3: "use threading.RLock for in-memory server singletons" (#1162)
- 1.1.4: "prevent first-owner write loss in in-memory stores" (#1194)
- 1.1.4: "owner-scope cancel/subscribe and write terminal state on cancel" (#1159, #1170, #1172)
- 1.1.4: "**server:** surface producer errors after failed tasks" (#1229)
- 1.1.4: "make event queue sink removal idempotent" (#1134)
- 1.1.4: "**server:** let subscriber taps evict on full instead of wedging dispatch" (#1137)
- 1.1.4: "omit artifacts from list tasks responses" (#1212)
- 1.1.4: "**server:** validate push-notification URLs before dispatch (SSRF hardening)" (#1164) and
  "at config creation" (#1173); "**server:** warn when queue_manager is ignored in DefaultRequestHandlerV2"
  (#1153)

The lab's receiver uses the in-memory task store and fails a Task when the model call fails, so the first
three 1.1.4 items sit on the path the duplicate-delivery and failed-model-call rows measure: Task counts
per work item, the terminal state recorded, and what a client reads back after a failed Task.

**openai 3.13.0 → 3.16.2** (the Python agent's model client). `_constants.py` is byte-identical
(`DEFAULT_MAX_RETRIES = 2`, timeout 600 s, connect 5 s); the loop is still
`for retries_taken in range(max_retries + 1)`. From 3.14.1, "**client:** validate retry limits and preserve
application errors", read in `_base_client.py` at the tag:

- a new `_validate_max_retries`: None, a non-integer or a negative value is rejected; its message reads
  "Use 0 to disable retries". The lab's `max_retries=0` is valid; the control run's 2 is valid.
- the branch that wraps a failed send as `APIConnectionError` (and retries it while retries remain) changed
  from `except Exception as err` to `except request_exceptions() as err`. An exception that is not a request
  exception now propagates as raised, unwrapped and unretried. This is the path of the mock's `close` and
  `delay-then-close` injections, so the model-client rows (R3 and R4 for the Python receiver, and Gate 1's
  `MODEL_MAX_RETRIES=2` control) and the chat span's `error.type` are to be read on the cluster, not assumed.
- 3.14.0: "**streaming:** normalize errors raised while reading streams"; "normalize API error codes to
  strings"; 3.15.0: "preserve chat stream moderation results". Streaming is Experiment B's, not A's.

With it the lock moved **httpx2 and httpcore2 2.12.0 → 2.13.0**, the client's HTTP package:
`retries: int = 0` is still the default on both transports at tag v2.13.0; its changelog for 2.13.0 lists a
brotli requirement, the `--no-verify` CLI flag, and "Avoid nested async generator finalization errors when
streamed responses are abandoned early".

**uvicorn 0.52.4 → 0.53.0** (the Python agent's HTTP server): "Honor `Connection: close` token lists"
(#3103: comma-separated tokens parsed case-insensitively), "Trust IPv6 loopback proxies by default" (#3119),
"Keep upgraded WebSockets alive" (#3107), and opt-in HTTP/2 through `zttp`, which is not installed here.

**OpenTelemetry Collector 0.160.0 → 0.161.0** (every span, and the collector is where the work-item
attribute is copied from the captured header). "`pkg/ottl`: Promote the `ottl.set.allowNil` feature gate to
beta, enabling it by default. (#49741) When enabled, the `set` function passes `nil` values directly to the
target instead of treating them as a no-op." The lab's four `set` statements each test the list they index
for `!= nil` in their own `where` clause (4 of 4, `local/telemetry-images.txt`). Traces are the explanation
and the ledgers the ground truth, so this can move a layer label's evidence and cannot move a count. That is
one of the release's three `pkg/ottl` breaking items. The other two: "Remove the deprecated `Base64Decode`
converter" (#50875) — 0 uses in the rendered configuration and in the values file, which call `set` ×4 and
`IsMatch` ×1 and no other OTTL function; and "Promote the `ottl.PanicDuplicateName` feature gate to stable"
(#50873) — about two OTTL functions registered under one name in a collector build, not a configuration
matter. The list's other 11 breaking items name components this pipeline does not use, and core 0.161.0's
seven remove deprecated Go API; `validate` at 0.161.0 accepts the rendered configuration
(`local/telemetry-breaking-items.txt`).

**Jaeger 2.20.0 → 2.21.0** (where exported traces are read from). Its release notes list four breaking
changes. (1) "Feat(query)!: remove v1 http endpoints the ui no longer calls" (#9260): the next section. The
other three are configuration matters, and this lab passes Jaeger no configuration: chart 4.13.1 with the
lab's values renders a ServiceAccount, a Service and a Deployment whose container has 0 args, no command, 0
env entries, 0 volume mounts and no ConfigMap, so the image runs on its built-in all-in-one configuration
with in-memory storage. (2) "Replace ai.enable_mcp with an optional ai.mcp config block" (#9194): `mcp`
occurs 0 times in the rendering, the lab's values and the chart's files. (3) "Fix(es): reject five
unsupported elasticsearch config keys at startup" (#9076): the backend is memory, the rendering names
Elasticsearch 0 times, and the chart's Elasticsearch maintenance jobs are disabled in the lab's values.
(4) "Feat(clickhouse): promote clickhouse storage feature gate to stable" (#9058): no ClickHouse storage is
configured; 0 mentions. (`local/telemetry-breaking-items.txt`.) Also in the release, in the in-memory backend
this lab runs: "Fix(memory): return copies of stored traces, not references" (#9261) and "Fix(memory): match
unset-status spans in error=false trace search" (#9096).

Also moved, outside experiment traffic: the Prometheus chart (same Prometheus v3.14.0; the six rendered
objects differ in the chart label and one added pod annotation), google-api-core, idna, urllib3, and the two
genproto modules.

## Jaeger 2.21.0 removed four legacy query endpoints; the tree's one use is replaced

jaegertracing/jaeger#9260, from the 2.21.0 release notes' breaking changes: `GET /api/services`,
`GET /api/operations`, `GET /api/services/{service}/operations` and the `GET /api/traces` search are
removed; replacements are under `/api/v3`. The author's word of 2026-09-19: "make sure to have the Jaeger
moves 2.20.0 → 2.21.0 and remove any usage of any removed endpoint as soon as possible".

- The lab's tools read `/api/v3/traces` only: Makefile `export-trace` and `experiments/lib/jaeger-spans.jq`
  (`jaeger-endpoints/removed-endpoint-grep.txt`, section 1: 3 lines, 0 of them a legacy path).
- The one use of a removed endpoint was `docs/walkthrough.md` l.898,
  `curl -s http://127.0.0.1:16686/api/services | jq -r '.data[]' | sort`. It is replaced by
  `curl -s http://127.0.0.1:16686/api/v3/services | jq -r '.services[]' | sort`, after a local check of both
  images (`jaeger-endpoints/check.sh`, `jaeger-services-endpoint-check.txt`): on 2.21.0 `/api/services`
  answers **404** and `/api/v3/services` **200** `{"services":["worker","orchestrator"]}`; on 2.20.0 both
  answer 200, the legacy one as `{"data":[…],"total":2,…}` and the v3 one in the same shape as on 2.21.0. So
  the new line prints the same sorted list on both sides of the move. Both containers were stopped and removed.
- After the change, uses of a removed endpoint left in tracked files outside dated records: **0**. Left as
  written, being dated records of what was run: `experiments/runs/2026-09-16-walkthrough/step-3/jaeger-services.txt`
  (the walkthrough step as captured on 2026-09-16 against 2.20.0, where the path answered).
- The walkthrough's printed service list below that command is the 2026-09-16 capture and is not re-taken
  here; the walkthrough is re-taken whole in follow-ups 20.

## Verified locally, with counts (all at the final tree of this task)

| Check | Result | Record |
| --- | --- | --- |
| `go build ./...`, `go vet ./...`, `gofmt -l .` | exit 0, exit 0, no file listed | `local/go-build-and-test.txt` |
| `go test ./... -count=1` | 7 packages ok, 0 failed | same |
| `make test` | exit 0: 7 Go packages ok + 17 tool lines ok (1 jaeger-spans.jq, 16 derive-layer), 0 FAIL | `local/make-test.txt` |
| `uv lock --upgrade`, `uv lock --check`, `uv sync --locked` | 66 packages resolved, 8 moved; of the 65 locked packages, 54 at PyPI's latest stable release + 9 with no stable line (at the latest of their only line) + 2 held | `local/uv-lock-upgrade.txt`, `uv-lock-vs-pypi.tsv`, `python-tests.txt` |
| `uv run pytest -q` | 62 passed, among them zero-retry (one call on a 500), the control (three calls) and transport retries 0 | `local/python-tests.txt` |
| installed package read | a2a-sdk 1.1.4, openai 3.16.2, `A2A-Version` / `1.0`, httpx2 transport retries default 0 | `local/python-env-read.txt` |
| orchestrator image, `docker build --pull --no-cache` under tag `orchestrator:fu19-currency` (removed from the host in fix round 1) | exit 0. Observed: Amazon Linux 2023 @sha256:06da5a33…, release 2023.12.20260918, python3.14-3.14.7-1.amzn2023.0.1, uv 0.12.17 @sha256:10787c68…, `dnf upgrade`: Nothing to do. | `local/orchestrator-image-build.txt` |
| inside that image | Python 3.14.7; ModelClient max_retries 0 over transport retries 0; `A2A-Version` / `1.0` | `local/image-retry-settings.txt` |
| `ko build` of worker, mockllm, loadgen, replay into `ko.local` | exit 0; base distroless static-debian13:nonroot @sha256:e2e927ec… for all four | `local/ko-build.txt` |
| `helm show chart` / `helm pull` / `helm template` of the three telemetry charts | digests equal the index's; Prometheus 6 objects and 5 scrape jobs at both chart versions; collector 4 objects and Jaeger 3, each differing from the committed rendering in the image line alone | `local/charts.txt` |
| `otelcol-contrib validate` on the rendered configuration | exit 0 at 0.160.0 and at 0.161.0 | `local/telemetry-images.txt` |
| read-only root filesystem start | collector 0.161.0 and Jaeger 2.21.0 both reach "Everything is ready", 0 restarts | same |
| `kubectl kustomize` of `deploy/base` and the five overlays | exit 0 each: 7, 7, 12, 20, 22, 27 objects; no file under them changed except three Helm values files | `local/kustomize-renders.txt` |
| Kubescape scan of the four Go images at grpc v1.83.2 and v1.84.0 (fix round 1) | 0 findings ×4 at v1.83.2; 1 High ×3 and 0 in replay at v1.84.0; DB built 2026-09-19 | `grpc-scan/grpc-scan.txt`, `summary.csv` |
| `make -n step-1 step-2 step-2b step-2c step-3` | exit 0; carries `--version` 1.31.0 ×4, v1.5.0 ×2, 0.173.1, 4.13.1, 29.31.1 and Gateway API v1.6.2 | `local/make-n.txt` |

No experiment script carries a pin that moved (the curl image is unchanged in its ten scripts), so no
`experiments/*.sh` was due a run here, and every one of them needs the cluster.

## The keys of versions.yaml, accounted for

75 keys before this pass, 82 after. Of the 75: **33 are version pins in use** and were each re-read (the
`versions_yaml_key` column names 35 old keys: these 33, plus `go-module-moves-2026-09-12`, one of the three
aggregates, and `agentgateway-managed-central-waypoint`, one of the 27, which holds the support table);
**27 are configuration-surface records** — sentences and field names quoted from documents for the versions
in use. 26 of them quote Istio, agentgateway and Gateway API documents, none of which moved, and were not
re-read here. 1, `genai-provider-name`, quotes the GenAI conventions, whose pin this commit moved: it was
re-read — its five quoted sentences and its 16 well-known values stand on the registry page, byte-identical
at the two commits — and carries a `reread:` note; **5 are marked `retired:`** and stay as they are; **1 is `superseded:`**;
**5 record routes or tools the lab no longer uses** (`opentelemetry-operator`,
`otel-python-autoinstrumentation`, `pack-builder`, `pack`, `python-base`) and are kept as the record of what
older entries ran on, not bumped; **3 are the 2026-09-12 audit's aggregates**; **1 is a measurement**
(`chart-readonly-rootfs-check`). The 7 added: `uvicorn`, `pytest`, `pytest-asyncio` and `ko` (pins the audit
found without a key), and `pin-audit-2026-09-19`, `python-lock-moves-2026-09-19`,
`go-module-moves-2026-09-19`.

## What could not be verified here

- Anything on a cluster: the install of the moved charts and images, the `A2A-Version` header captured from
  a real request at a2a-sdk 1.1.4, the invocation counts at openai 3.16.2, spans through collector 0.161.0,
  a trace export from Jaeger 2.21.0. Task 3 and task 4.
- agentgateway's OCI registry refuses an anonymous tag listing (HTTP 401), so there is no tag LIST behind "no
  1.5.x patch exists"; it rests on the GitHub release list, the unchanged chart and image digests, and the
  registry answering not found for v1.5.1, v1.5.2 and v1.6.0 of both charts when asked by name.
- `make orchestrator-image` and `make scan-images` were not run: the first loads into the standing cluster;
  the second is a measurement whose counts belong to a findings entry, and task 3's rebuild runs it. The
  grpc scan of fix round 1 used that target's command on the four Go images only, as evidence for a hold, and
  scanned neither the orchestrator image nor anything for an entry.
- Whether a Prometheus server reaches golang.org/x/crypto/ssh, the package GO-2026-6303 is about, was not
  examined.
- 40 modules of the Go graph have a newer version and provide no package that `./...` builds; they are left
  where minimal version selection puts them, as on 2026-09-12 (`local/go-modules.txt`).
- One oddity recorded and not acted on: opentelemetry-collector-contrib's
  `cmd/otelcontribcol/builder-config.yaml` at tag v0.161.0 names three Prometheus exporter modules at
  v0.159.0, while the published image's own `components` output lists prometheusexporter v0.161.0
  (`local/collector-0.161.0-components.txt`).

## Host state left by this task

`local/host-images.txt`: the verification image `orchestrator:fu19-currency` is removed; `orchestrator:dev`
(the tag the cluster's image was loaded from) was created at 11:35:41Z, before this task began, and was not
rebuilt; the grpc-scan scratch images (`ko.local/fu19-grpc184/…`, 8 tags) and the scratch copy are removed.
The lab's four `ko.local/…:latest` tags WERE moved by this task's own `ko build` — the command
`make scan-images` runs — and point at the build of the committed tree; the scratch build did not move them
(same image ids before and after). No container of this task is left.

## Fix round 1 (2026-09-19, after an independent review: 0 Important, 8 Minor — wording and classification)

No pin value and no code changed. What did:

- `grpc-scan/` added, with its statement in the grpc hold above, in the `grpc-go` key and in the grpc row; the
  expectation "the lab's image scan reads the first two" is replaced by the measurement; the cherry-pick's
  ancestry of the v1.84.0 tag is verified and stated. `local/grpc-hold.txt` has a dated appended block; its
  first text is not edited.
- `pins.csv` reclassified evenly: genproto api and rpc from `moved` to `no-stable-line` (moved); four lock
  packages with no final release split out of the aggregate lock row; totals restated here, in the table's
  header, in `pin-audit-2026-09-19` and in the commit message. `local/otel-python-no-stable-line.txt` now
  covers all nine.
- `genai-provider-name` re-read and marked; the keys paragraph says 26 + 1 and names the column's 35 old keys.
- The fallback (hold the image at the chart's appVersion until a chart names the newer release) is stated for
  Jaeger as for the collector: `trace-backend`, `trace-backend-chart`, `opentelemetry-collector-chart`, both
  values files' headers and the Makefile comment.
- The host image removed and the host state recorded (previous section).
- Prometheus v3.13.3 read as what it is, a security patch published after v3.14.0, with the advisory named.
- All four Jaeger 2.21.0 breaking items and all three `pkg/ottl` items of collector 0.161.0 named, each with
  why it cannot reach the lab (`local/telemetry-breaking-items.txt`).
- Wording: the session window to 15:42Z; the Inference section as 388 lines of the file; the three observed
  floats that moved named in Counts. `local/genai-conventions-head.txt` has a dated appended block.
- The chart registry's not-found answers for the next agentgateway versions recorded.

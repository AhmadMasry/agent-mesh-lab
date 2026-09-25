# The currency pass of 2026-09-25: which existing rows a moved dependency could change

Phase 1's impact analysis, for the controller's ruling before any cluster action. For every moved pin that experiment
traffic or the telemetry path crosses, its release notes and its code diff between the old and the new version were
read (the documents are in sources.tsv; the readings in local/). Each existing row whose outcome a diff could
change is listed with the diff lines and the committed driver that re-counts it; the rows no diff touches follow, in
groups, each with its reason. Nothing here was run on a cluster; every "expected" below is a reading of code, not a
count, and the re-count is what decides it.

## 1. The moved pins on a traffic or telemetry path, and what their diffs change

| Pin | Moved | On the path of | What the diff changes that the lab can reach |
| --- | --- | --- | --- |
| a2a-go | v2.5.0 -> v2.6.0 | the worker (server), the load client (client), the replay harness (types), the extauthz fixture (decode mirror) | (a) a2asrv/handler.go l.373-382: a SubscribeToTask whose Resubscribe fails now reads the task store; a terminal task is answered ErrUnsupportedOperation, "task in a terminal state", JSON-RPC -32004 (internal/jsonrpc/jsonrpc.go l.78), REST 400 FAILED_PRECONDITION (internal/rest/rest.go l.201); a stored non-terminal task with no execution is answered with the stored Task and the stream ends; a task the store does not hold is still ErrTaskNotFound, the text unchanged. At v2.5.0 all three were ErrTaskNotFound, -32001, "task not found: no active execution". (b) a2asrv/agentexec.go l.228: a message naming a terminal task is ErrUnsupportedOperation, was ErrInvalidParams (-32602). (c) a2a/agent.go l.23, l.26: capabilities.pushNotifications and capabilities.streaming lose omitempty, so every card carries both. (d) a2aevent/diff.go compares status timestamps by value; its only exported entry, a2aevent.Recover, has no caller in a2a-go v2.6.0 outside tests and none in the lab. The client side (resolver, factory, REST query names), the JSON-RPC server (a2asrv/jsonrpc.go) and internal/jsonrpc are byte-identical or change nothing the lab calls (local/a2a-go-diff.txt). |
| a2a-sdk (Python) | 1.1.4 -> 1.1.5 | the orchestrator (server and client) | proto_utils: required-field validation and REST query parsing go through a helper that reads is_repeated on protobuf >= 6.31 and label below it, the same semantics; the OpenAPI schema helper; the database task store (unused). Its protobuf cap goes. The request handlers, the JSON-RPC dispatcher and constants.py (A2A-Version, 1.0) are unchanged (local/python-package-diffs.txt). |
| protobuf (Python) | 6.33.6 -> 7.36.2 | every A2A message the orchestrator parses or serialises, and its gRPC binding | the Python breaking items of v34.0 (python 7.34): FieldDescriptor.label removed (the SDK no longer reaches it at >= 6.31), bool assigned to an int or enum field raises, float_precision removed from json_format, float_format and double_format removed from text_format, a non-datetime given to Timestamp.FromDatetime raises TypeError (the SDK's task_updater passes datetimes only); v35 and v36 add recursion and depth guards and fix memory issues. The SDK's generated a2a_pb2 declares gencode 5.29.3 and loads on the 7.36.2 upb runtime with no warning. |
| openai | 3.16.2 -> 3.19.2 | the orchestrator's model call | _base_client.py (v3.19.2): each retry branch of the async loop also requires request_body_replay.rewind() (l.1780 timeout, l.1797 connection error, l.1821 retryable status); _RequestBodyReplay returns True for a body that is not a stream, and the chat call's body is JSON. Headers merge case-insensitively (_merge_headers); the lab's four X- headers share no name with a default header. _constants.py unchanged (DEFAULT_MAX_RETRIES 2). These lines run only when retries remain, that is with MODEL_MAX_RETRIES > 0. |
| httpx2, httpcore2 | 2.13.0 -> 2.13.1 | the model call's transport | Content-Length for a file passed as content, the sync WebSocket keepalive, httpcore2's connect (proxy and socks paths). No retry change; transport retries default 0. |
| starlette | 1.6.0 -> 1.7.0 | the orchestrator's server (the SDK's app is Starlette) | Router.app sets scope route (read by the asgi instrumentation for its duration-metric target only; the lab exports no Python metrics); Host.matches and compile_path parse IPv6 hosts; BaseHTTPMiddleware runs background tasks after the response (neither the lab nor the SDK uses it); CORS, sessions, static files, test client. |
| uvicorn | 0.53.0 -> 0.54.0 | the orchestrator's server | the zttp HTTP/2 implementation only (not installed). No change on the HTTP/1.1 path. |
| OpenTelemetry Python | 1.44.0/0.65b0 -> 1.45.0/0.66b0 | the orchestrator's spans (TELEMETRY PATH) | the starlette and asgi instrumentations: no behaviour change (syntax tree, annotations removed); httpx: retyped, one response branch reordered. The OTLP/HTTP exporter is rebuilt on two new packages and its default HTTP backend is urllib3; a 64 MiB request cap. SDK: BatchProcessor._export and emit (processor metrics), SimpleSpanProcessor after shutdown, resource detectors (host.id only when OTEL_EXPERIMENTAL_RESOURCE_DETECTORS names the host detector, which the lab does not set). Semantic conventions v1.44.0. |
| Istio | 1.31.0 -> 1.31.1 (istiod, ztunnel, CNI) | every mesh hop; STRICT; ztunnel's authorization | istiod: a8ef5737 "Reduce AuthorizationPolicy scanning by indexing on namespace" (ambientindex.go +14 -1, workloads.go +32 -36): the workload builders now receive a per-namespace index of WorkloadAuthorizations that admits only policies with a label selector, where they received the whole collection; 9d5808d5 the same for PeerAuthentication (workloads.go +38 -35). ztunnel: its own source adds test fixtures and rejects a legacy tunnel protocol the lab does not use; its crates move: h2 0.4.14 -> 0.4.15 (pinned), pingora-pool 0.8.0 -> 0.9.0 (the HBONE connection pool), hyper 1.10.0 -> 1.11.1, tokio 1.52.3 -> 1.53.1, rustls 0.23.40 -> 0.23.44, prometheus-client 0.24.1 -> 0.25.1 (the /metrics exposition). CNI: the iptables backend no longer flips across agent restarts. |
| Prometheus | v3.14.0 -> v3.15.0 (chart 29.31.1 -> 29.33.1) | the rows counted through Prometheus queries; the proof's target list | scrape and PromQL fixes (stale markers for a series still exposed, histogram and info() fixes, OM2.0 and UDS scraping opt-in); --log.level deprecated (the chart passes none). |
| Jaeger chart | 4.13.1 -> 4.14.0 | the trace store | the image stays 2.21.0; the rendering differs in labels alone. No row can change. |
| genproto (Go) | cecb64721679 -> b14227669459 | the worker's gRPC status details | the rpc module tree is identical; api differs in go.mod and go.sum. No row can change. |
| google-api-core, google-auth, googleapis-common-protos | minor moves | the SDK's imports | api-core adds a resumable-transfer package; common-protos regenerates longrunning and gapic metadata; auth: credentials code the lab never calls. No row can change. |

Held, so not moved: grpc-go v1.83.2, the kind node image v1.37.0, pydantic-core 2.46.5, opentelemetry-util-genai 1.1b0.
Unmoved on the path: agentgateway v1.5.0 (both proxies), Gateway API v1.6.2, the collector 0.161.0, Jaeger 2.21.0,
OpenTelemetry Go v1.46.0 and otelhttp v0.71.0, the Go toolchain, the curl image.

## 2. Rows whose outcome a diff could change: PROPOSED FOR RE-COUNT

### 2a. The diff changes the answer the row counted (a2a-go#442): expected to read differently

**B-3 / D3, SubscribeToTask on a terminal task, both receivers** (entry "Experiment B / both receivers / D3,
SubscribeToTask on a terminal task", 20 per receiver).
- Go cell: 20 of 20 read HTTP 200, text/event-stream, JSON-RPC -32001 "task not found: no active execution". At
  v2.6.0, handler.go l.373-379 reads the stored task, finds TASK_STATE_COMPLETED, and answers -32004 "task in a
  terminal state ...: this operation is not supported". The in-process reading of this exact shape moved the same way
  (local/test-first.txt).
- Python cell: -32602 "Task <id> is in terminal state: 3", from a2a-sdk; 1.1.5 changes none of the handler code, but
  the message is built over protobuf 7 and the row counts both receivers in one invocation.
- Driver: experiments/runs/2026-09-21-b3-streaming-client/rows.sh subscribe-terminal 20 "go py", counted by that
  directory's counts.py.

**D-1 / the Python client as the reconnecting client, go receiver** (entry "Experiment B / go receiver / D-1, the
Python client as the reconnecting client", 20 repetitions).
- The one SubscribeToTask reached the worker 5.2-13.2 ms after its Task had FAILED, 20 of 20, and was answered
  -32001 "task not found: no active execution"; the orchestrator's Task read "downstream SubscribeToTask ended without
  a terminal event (error: task not found: no active execution)" and the client raised TaskNotFoundError. At v2.6.0
  the same arrival is answered -32004 (handler.go l.379), which a2a-sdk maps to UnsupportedOperationError; the
  orchestrator's failure text and the client's exception class change with it.
- Same run: the entry's unexplained reading, the span processor's shutdown timing out in every repetition, sits on the
  OTLP/HTTP exporter that moved (urllib3 backend).
- Driver: experiments/runs/2026-09-24-d1-current-topology/pyclient.sh 20 (RUN_ID, RUNREL).

These two are the rows a2a-go#442 changes. B-6's table and D-6's B table carry the cells as quoted from these entries;
a new entry would say beside their headings which cells read differently. The draft
docs/upstream/a2a-go-subscribe-to-terminal-task-not-found.md (D-5c: superseded by v2.6.0) gains its dated note from
the B-3 re-count, confirming or refuting in counts.

### 2b. The rows run through changed lines; the reading predicts the same count (confirmation re-counts)

**A.3 R3 py, R4 py through the ingress, R4 py SUB=service** (entry "Experiment A / both receivers / re-run on the
topology of 2026-09-19", 20 each). MODEL_MAX_RETRIES=1, so the model call's retry runs openai v3.19.2 _base_client.py
l.1797 (the mock's close is a connection error), whose new condition is request_body_replay.rewind(). For the JSON
chat body rewind() returns True, so the reading predicts the second attempt still happens (invocations 2 in R4, the
recovered call in R3). The rows also cross a2a-sdk 1.1.5, protobuf 7 and starlette 1.7.0 on the receiver. Drivers:
experiments/gate3-matrix.sh RUN=R3 RECEIVER=py REPS=20, RUN=R4 RECEIVER=py REPS=20, RUN=R4 RECEIVER=py
SUB=service REPS=20 (via make matrix, with the script's own one-repetition dry run first, as that entry ran them).

**ztunnel's authorization rows**: C-3 (Istio's "allow only the waypoint's identity" on the worker), C-4 (ztunnel given
an HTTP rule), C-3R (open connections), C-3R2 (the public server), D-4 Row Z (ALLOW on principals). Each is a
selector-scoped AuthorizationPolicy on a workload, and istiod 1.31.1's a8ef5737 replaces the code that decides which
policies a workload's entry names (workloads.go: authorizationPolicies collection -> authPoliciesByNs index, which
admits only policies with a label selector, keyed by the policy's namespace). For a same-namespace selector policy the
reading predicts the same set; C-3R's own draft (ztunnel-policy-watcher-selector-scoped-policy.md) is about exactly
this kind of policy. ztunnel's crates (h2, hyper, tokio, rustls) carry the HBONE connections these rows open and
refuse. Drivers: experiments/runs/2026-09-21-c3-c4-ztunnel/ (send-one.sh, rec.sh, counts.sh; C-3 and C-4 applied
their policies by the steps that entry records), experiments/runs/2026-09-21-c3r-open-connections/rep.sh,
experiments/runs/2026-09-21-c3r2-public-server/rep.sh, experiments/runs/2026-09-25-d4-serviceaccounts/rows.sh
(phase z).

**C-5, Istio's AuthorizationPolicy with targetRefs naming agw-central.** A targetRefs policy carries no label
selector, which is exactly what the new index leaves out (ambientindex.go selectingWorkloadAuthzByNs returns nothing
when GetLabelSelector() is nil). What istiod does with it, and whether anything reaches the proxy, is C-5's question.
Driver: experiments/runs/2026-09-23-c5-istio-policy-agw-central/c5.sh.

**D-5, the connection count** (entry "Experiment C / both receivers / D-5, the connection count": agw-central's
upstream connections to an agent, one per agent per burst, the A2A marking on or off). Counted from each ztunnel's
metrics, whose connection pool (pingora-pool 0.9.0), HTTP/2 stack (h2 0.4.15, hyper 1.11.1) and exposition crate
(prometheus-client 0.25.1) all moved. Driver: experiments/runs/2026-09-25-d5-a2a-backend/d5.sh conn|mark|unmark
(the marking set once and removed, as D-5n did).

### 2c. Rows on the telemetry path: covered by the standard proof, re-counted only if it moves

The orchestrator's spans now leave through the moved exporter (urllib3 backend) and the moved SDK processor; by the
syntax-tree reading no instrumentation creates a different span. The standard proof counts spans per work item by
service, dangling parents and the GenAI summary on both receivers. If those counts equal D-4's, the trace-derived
cells of these rows stand as recorded: Experiment A's trace_spans and spans_by_service cells, the Gate 3 GenAI spans
entry, the layer-attribution entry, C-1's observation, B-6's trace table. If they differ, the rows whose cells rest on
them are listed for a ruling before anything is re-run.

## 3. Rows NOT affected, grouped, each with its reason

- **Every row that sends SubscribeToTask naming no task**: C-6, C-8, C-10, D-2 (route, CEL path rule, body rule,
  application), D-3 (the three entries) and D-3b send TASK_ID "no-such-task-<lwi>" or a task id naming no task
  (their drivers, lines cited in local/impact-evidence.txt). At v2.6.0 such a request takes the new branch's first
  arm, taskStore.Get fails, and the answer is ErrTaskNotFound with the text v2.5.0 gave (handler.go l.373-376). The
  refusals by the route layer, CEL and the authorizer happen before either SDK. C-7 sends no SubscribeToTask.
- **Every SubscribeToTask that reached a running Task**: B-3 subscribe-running, B-4, B-5b (both proxies), D-1's
  rollout variant. Each entry records the Task running at every arrival (40 of 40 or 20 of 20), where Resubscribe
  succeeds and v2.6.0's new code is not entered.
- **The rows that send no message to a terminal task**: the replay harness builds bodies with no taskId
  (fixtures/replay/body.go buildBody), and A.1's M1-M3 and A.2's resends carry none, so agentexec.go l.228 is not
  reached. A.1, A.2 and A.3's go rows, baseline, R1, R2 and egress on both receivers.
- **The rows on the model call with retries off**: MODEL_MAX_RETRIES 0 (the default and every A row but R3 and R4 on
  the Python receiver) never evaluates openai's changed condition (remaining_retries > 0 is false first).
- **The card's new fields**: no row counts the card's bytes or reads capabilities.pushNotifications; the lab's
  cards already declared streaming. a2a-python reads the added field as the value it already defaulted to.
- **agentgateway's own rows**: C-6, C-7, C-8, C-9 and its revert, D-2's route and CEL rows, D-3's authorizer rows,
  D-4 Row A, D-5's backend-type trial: agentgateway v1.5.0 did not move, and what they count happens at the proxy
  before either SDK (or, for C-9 and the trial, is no longer in the deployed configuration). #3369's defect is still
  in v1.5.0, so no figure is taken from an access-line timestamp.
- **D-1's header reading, D-4's identity re-reading**: headers reaching the applications and SPIFFE identities per
  hop. No moved dependency adds or strips a request header on the path (openai's header merge changes no name the
  lab sets; the SDKs' client headers are unchanged in the diffs), and identities come from istiod's CA, not the
  policy index. The standard proof's STRICT table re-reads the identities on every leg.
- **Gate 3 / metrics per hop** (2026-09-19): taken on the topology before the agentgateway-only note and at a2a-python
  1.1.2 and openai 3.13.0; D-5 is the current-topology row that counts ztunnel connections, and it is in 2b.
- **B-5a, the removal measured** (Go receiver, streams ended by removing a proxy): the stream is the load client's
  (a2a-go client side unchanged but for the card resolver's optional verifier, unused) through agentgateway v1.5.0; the
  removal timing is agentgateway's and Kubernetes'.
- **Python receiver rows with odd JSON bodies** (D-3's four other shapes, D-3m's probes at allow): the moved
  protobuf items are assignment and formatting APIs the SDK's JSON-RPC parse does not call; the parse of those shapes
  is JSON decoding before protobuf. The Python cell of D3 above exercises the parse at 7.36.2.

## 4. What this list does not settle

- It is a reading. A row in section 3 is left out because no diff reaches the code it exercises, not because it was
  measured unchanged; the standard proof's counts are the check on that reading for the clean path.
- The drivers of 2a and 2b that prepend a lab-scoped istioctl path name istioctl-1.31.0 under a task's own
  scratch directory. Run as they are, that directory is absent, so the next PATH entry answers; the rebuild's driver
  puts the checksum-verified 1.31.1 copy (local/istioctl.txt) first on PATH for them, so the version on PATH is the pin.
- C-3 and C-4 applied their policies by steps recorded in their entry rather than by one script; their re-count follows
  those steps with the same objects, and says so.

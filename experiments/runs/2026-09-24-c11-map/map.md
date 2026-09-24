# Experiment C, C-11 — the map: what each layer on this topology could see and enforce of a JSON-RPC-bound A2A operation

Written 2026-09-24. This step ran nothing: no cluster, no stimulus, no code. Every cell below is taken from a dated
findings.md entry, cited by the short key in the list that follows, and carries the qualifier its entry carries. A
cell that no entry supports is EMPTY and says so. Nothing here is a new reading.

## The entries the cells come from

| Key | findings.md heading (code quoting dropped; abridged after the dash only where marked) | Run directory |
|---|---|---|
| C-1 | Experiment C / both receivers / observation — what did each layer record of one clean SendMessage, and what could it tell apart? | 2026-09-20-c1-observation (its observation-map.md, which the entry cites) |
| C-3 | Experiment C / go receiver / C-3, ztunnel L4 — with Istio's own "allow only the waypoint's identity" policy on the worker, what does each caller path get? | 2026-09-21-c3-c4-ztunnel |
| C-4 | Experiment C / go receiver / C-4, ztunnel given an HTTP rule — what do istiod and ztunnel do with to.operation.methods, and what does every caller count? | 2026-09-21-c3-c4-ztunnel |
| C-3R | Experiment C / ztunnel / open connections — does ztunnel close a connection opened before an ALLOW policy that denies its caller, and does the policy's scope decide it? | 2026-09-21-c3r-open-connections |
| C-3R2 | Experiment C / ztunnel / open connections, public server — does the C-3R result hold with a server anyone can pull, run as the draft words it? | 2026-09-21-c3r2-public-server |
| B-6 | Experiment B / both receivers / B-6, the table — what B found, and what each trace shows of it | 2026-09-23-b6-traces-and-table |
| C-5 | Experiment C / agw-central / C-5, Istio's AuthorizationPolicy with targetRefs naming agw-central — (abridged) | 2026-09-23-c5-istio-policy-agw-central |
| C-6 | Experiment C / both receivers / C-6, what a Gateway API HTTPRoute can separate — (abridged) | 2026-09-23-c6-httproute |
| C-7 | Experiment C / both receivers / C-7, agentgateway's authorization on headers and on identity — (abridged) | 2026-09-23-c7-agw-authorization |
| C-8 | Experiment C / both receivers / C-8, agentgateway's authorization on the request body — (abridged) | 2026-09-23-c8-body-rule |
| C-10 | Experiment C / both receivers / C-10, the application refuses the operation — (abridged) | 2026-09-24-c10-application |
| C-9 | Experiment C / both receivers / C-9, the A2A marking switched on — (abridged) | 2026-09-24-c9-a2a-marking |
| after C-9 | Experiment C / both receivers / after C-9 — with the A2A marking reverted, is the lab back on its measured topology? | 2026-09-24-c9-revert |

## The configuration every cell holds for

kind; k8s v1.37.0, Istio 1.31.0, agentgateway v1.5.0, Gateway API v1.6.2 experimental, a2a-spec 3303592, a2a-go
v2.5.0, a2a-python 1.1.4. The topology of 2026-09-19: agentgateway-ingress (ztunnel-captured) and agw-central (not
enrolled, terminating HBONE itself), ztunnel at L4 under istiod, mesh-wide STRICT. The JSON-RPC binding only, served
at /. Every workload in lab runs as the one default ServiceAccount, spiffe://cluster.local/ns/lab/sa/default, by the
author's decision of 2026-09-23. The agent Services are NOT marked A2A — the deployed configuration before C-9 and
again after it (after C-9) — in every row except the one row that says otherwise.

**The C-9 row holds only with the A2A marking on** (Service port appProtocol agentgateway.dev/a2a on the worker and
the orchestrator). The author reverted that marking on 2026-09-24 after it broke every client that follows an agent
card to a Service address; the lab as it stands does not have it (after C-9). No cell of that row describes the lab
as it stands.

## 1. The observation map — what each layer could tell apart when SendMessage and a second operation arrive at one JSON-RPC endpoint

Tags: **M** measured (a count or reading in the cited entry); **D** documented or read from source, as the cited
entry labels it, and not measured — either a documented limit or a documented mechanism not exercised, each cell
saying which; **E** empty (no entry supports a cell); **N/A** not applicable, with the entry that says so. A cell with a measured reading and a
documented sentence beside it is counted M. "Inferred" and "read from source" are kept where the entry uses them.

### 1.1 The grid

| Layer (control plane) | Caller identity | Target Service | Path and headers | JSON-RPC method | messageId | taskId |
|---|---|---|---|---|---|---|
| R1 ztunnel, L4 (istiod) | M: the delivering proxy's identity, not the caller's | M: yes | M: none | M: none | M: none | M: none |
| R2 HTTPRoute on the agentgateway proxies (agentgateway's controller) | D: no match field names a source | M: yes, by route and hostname | M: path, method, query and headers; only a header differed, and it was the client's | M: not separable | D: in the body, not matchable | D: in the body, not matchable |
| R3 agentgateway authorization, AgentgatewayPolicy CEL (agentgateway's controller) | M: agw-central one value for every caller; ingress none | M: as attachment scope | M: yes | M: yes, by the body, within the buffer limit | D: documented mechanism, not exercised | D: documented mechanism, not exercised |
| R4 agentgateway telemetry, marking off (the deployed configuration) | M: agw-central one value; ingress none | M: yes | M: method, path, host; no header | M: none | M: none | M: none |
| R5 agentgateway A2A handling, marking ON (C-9 only, reverted) | E | M: yes, and the card rewrite moved it | M: card GET classified | M: yes, 20 of 20 | M: none | M: none (state only) |
| R6 application, Go worker (a2a-go) | M: none; remote is the proxy | N/A: the receiver is the target (C-1's map) | M: A2A-Version, content type, body hash | M: yes, before the SDK | M: yes | M: yes |
| R7 application, Python orchestrator (a2a-python) | M: none; remote is the proxy | N/A: the receiver is the target (C-1's map) | M: A2A-Version, content type, body hash | M: yes, before the SDK; also in span names | M: yes | M: yes |

Cell counts, 42 cells: **M 34, D 5, E 1, N/A 2.** The one E cell: R5 caller identity (C-9 reported no src.identity
under the marking, and R4's reading is not carried across a configuration change). The two N/A cells: R6 and R7
target Service, where C-1's map writes "it is the target" — the column's question does not apply at the receiver.
Of the 5 D cells, 3 are documented limits (R2 caller identity, messageId, taskId) and 2 are a documented mechanism
not exercised (R3 messageId, taskId).

### 1.2 The cells, in full

**R1 ztunnel, L4 (istiod; AuthorizationPolicy, PeerAuthentication)**

- Caller identity — M. Behind a proxy the receiver's ztunnel names the delivering proxy, not the caller: on the 3
  proxy-to-receiver legs of C-1 the source is spiffe://cluster.local/ns/agentgateway-waypoint/sa/agw-central or
  spiffe://cluster.local/ns/agentgateway-ingress/sa/agentgateway-ingress, 3 of 3 mutual_tls (C-1). Callers carry
  ns/lab/sa/default on their own legs (C-1; the loadgen-to-ingress leg in C-5's standard proof, as C-7 cites it). A
  refusal line names the identity the caller arrived with — lab/sa/default dialling direct, the ingress's identity
  through the ingress (C-3), agw-central's (C-4) — and names no policy. Configuration-specific: with one
  ServiceAccount for every lab workload, the policy "separated paths, not callers" (C-3).
- Target Service — M. dst.service on every access line and destination_service on every series; 99 of 99
  istio_tcp_connections_opened_total series carry the same 30 label names (C-1).
- Path and headers — M, none. 0 of the 165 ztunnel lines in C-1's window carry http.method or http.path (C-1). Given
  an HTTP method rule, istiod wrote ZtunnelAccepted=True, reason UnsupportedValue, and handed ztunnel the ALLOW policy
  with rules: [] (C-4). Documented beside it: "The ztunnel cannot enforce L7 policies" (Istio's L4 page l.66, as C-4
  cites it).
- JSON-RPC method — M, none. 0 of 165 lines carry SendMessage; the body is not parsed at this layer (C-1).
- messageId — M, none. 0 of 165 lines. The work-item string occurs 18 times, each inside a pod or workload token, 0
  as a property of a request (C-1).
- taskId — M, none. 0 of 165 lines (C-1).

**R2 HTTPRoute on the agentgateway proxies (agentgateway's controller; Gateway API v1.6.2 experimental)**

- Caller identity — D. HTTPRouteMatch has four fields, Path, Headers, QueryParams and Method, and none names a source
  (httproute_types.go at v1.6.2 l.761-798, as C-1 and C-6 cite it). No step matched on a source.
- Target Service — M. route named on 8 of 8 proxy SERVER spans and 14 of 14 access-log request lines, each route's
  backendRefs naming one Service (C-1). On one ingress the two receivers were told apart by hostname, lab/worker-ingress
  (worker.lab.internal) and lab/orchestrator-ingress, 12 of 12 sends on the route for their host (C-6, phase A).
- Path and headers — M. On the wire, 9 of 9 runs of the a2a-go load client: every POST is POST / with no query;
  SubscribeToTask 3 of 3 and SendStreamingMessage 3 of 3 carry Accept: text/event-stream, SendMessage 3 of 3 no Accept;
  A2a-Version: 1.0 on all (C-6). A header match on Accept separated this client's streaming operations from its unary
  one — 12 refused, 12 delivered — and a curl SubscribeToTask with Accept: */* passed 6 of 6 (C-6). C-6's words: a
  property of the client, not of the operation.
- JSON-RPC method — M, not separable. SendMessage and SubscribeToTask read POST, / and no query alike on the wire and
  on the ingress's own line, 12 of 12 in phase A (C-6); HTTPRouteMatch has no body field (documented, C-6). One route
  rule carried SendMessage, an agent-card GET and a control POST together (C-1).
- messageId — D. In the body, so not matchable on this binding (C-1's map, a documented limit); C-1 read that the live
  route objects hold no field that could name it. No step exercised it.
- taskId — D. The same (C-1's map). No step exercised it.

**R3 agentgateway authorization (AgentgatewayPolicy spec.traffic.authorization, CEL; agentgateway's controller)**

- Caller identity — M. source.identity, read by a Deny keyed on a probe header and source.identity.serviceAccount ==
  'default': on agw-central it fired 6 of 6, each line src.identity=spiffe://cluster.local/ns/lab/sa/default; on the
  ztunnel-captured ingress it fired 0 of 9 across three paths, and 9 of 9 lines carry no src.identity (C-7).
  Configuration-specific: on agw-central the value is the same for every lab caller; on the ingress it is absent on
  every path read (C-7). Allow and Require on identity were not run; what C-7 writes of them is what the documents
  imply, not measured.
- Target Service — M, as attachment scope. Rules were attached to named routes and held only there: under C-8's
  Require the Python card GET, which crosses agw-central's lab/orchestrator where no rule was attached, read 200 15 of
  15, while the Go card GET on the ruled lab/worker-ingress read 403 15 of 15 (C-8). The CEL variables request.host and
  backend.name are documented (C-1's map) and no rule used them.
- Path and headers — M. request.headers['accept'] as a Deny: 12 refused with the proxy's 403, 12 delivered, the same
  split as the route's (C-7). request.method == "GET" inside C-8's scoped Require passed the card GET 15 of 15 (C-8).
- JSON-RPC method — M, by the generic body parse and within the buffer limit. json(request.body).method as a Deny
  refused SubscribeToTask 40 of 40 and passed SendMessage 20 of 20 and SendStreamingMessage 20 of 20 (C-8). Past
  maxBufferSize (2,097,152 bytes, the default; probes of 2,200,000 bytes) the variable fails to evaluate: the Deny passed
  2 of 2 with 200, the Require refused 2 of 2 (C-8). A JSON-RPC batch passed the Deny 2 of 2; an object with the method
  key twice was refused 2 of 2, which C-8 says shows only that the rule read the second key (C-8). There is no A2A CEL
  object at this tag (documented, C-1's map), and the A2A block runs after both authorization points (read from
  source, C-9).
- messageId — D, a documented mechanism, not exercised. Reachable through the same generic body parse (C-1's map:
  documented, and "TO MEASURE" there); C-8 wrote no rule on it.
- taskId — D, a documented mechanism, not exercised. The same (C-1's map); C-8 wrote no rule on it. A request carries a
  taskId in its body only for the operations that name one: it was empty on 3 of 3 SendMessage arrivals (C-1).

**R4 agentgateway telemetry, marking off — the deployed configuration (C-1 and B-6 before C-9; after C-9)**

- Caller identity — M. src.identity on 7 of 7 agw-central SERVER spans and 13 of 13 of its access lines, every one
  spiffe://cluster.local/ns/lab/sa/default; 0 of 1 span and 0 of 1 line on agentgateway-ingress, on a leg ztunnel
  reports mutual_tls (C-1); 9 of 9 ingress lines without it (C-7).
- Target Service — M. route, endpoint, http.host, gateway and listener on 8 of 8 proxy SERVER spans (C-1).
- Path and headers — M. http.method, http.path, http.host and http.status on the spans, and no request header (C-1);
  SendMessage and SubscribeToTask lines both read http.method=POST http.path=/ (C-6).
- JSON-RPC method — M, none. 0 attribute keys beginning a2a. on any proxy span, protocol=http on 8 of 8 (C-1); 0 keys
  matching a2a.* or rpc.* across the 423 spans of twelve traces, and the 72 proxy spans name no operation (B-6's trace-readings.txt l.102);
  protocol=http on 4 of 4 card lines once the marking was reverted (after C-9). This is the cell in force today; R5 is
  what C-9 read in its place with the marking on.
- messageId — M, none. 0 on any proxy span (C-1, B-6).
- taskId — M, none. 0 on any proxy span (C-1); no A2A hop carries a task id in any form (B-6).

**R5 agentgateway A2A handling, marking ON — C-9 only; reverted by the author's decision of 2026-09-24**

Measured on the Go receiver's ingress path: 15 work items, 20 arrivals. Under the marking no request reached the
Python receiver through agw-central, and its streams through the ingress were not measured (C-9's own not-covered
list).

- Caller identity — E. C-9 counted protocol and the a2a.* keys on the marked lines and did not report src.identity on
  them. No entry supports a cell.
- Target Service — M, marked only. Routes as unmarked: 20 of 20 Go arrivals on lab/worker-ingress from the ingress pod,
  0 from agw-central (C-9). The card rewrite wrote into supportedInterfaces the host the GET named, with http at the
  ingress and https at agw-central, and every client that followed a card to a Service address failed at agw-central
  before its A2A request was sent: the Python load client 15 of 15, the clean check's two work items, the
  orchestrator's forward 1 of 1 (C-9). Why agw-central writes https is read from source, the last step inferred and not
  traced (C-9).
- Path and headers — M, marked only. Card GETs read protocol=a2a on 20 of 20 lines with no a2a.method; one card GET
  carrying X-Forwarded-Proto: http turned agw-central's https into http (1 probe) (C-9).
- JSON-RPC method — M, marked only. a2a.method names the operation on 20 of 20 A2A POST lines, and per work item its
  multiset equals the pre-dispatch ingress ledger's arrivals, 15 of 15; each of the 65 access lines has a SERVER span
  of the same trace and route with the same keys, 65 of 65 (C-9). C-9 wrote that this changes C-1's cell and B-6's
  reading "on the path that still works"; after the revert this cell is "not carried forward" (after C-9), and R4's
  cell is the one in force.
- messageId — M, marked only, none. 0 keys naming a messageId on every line and span (C-9).
- taskId — M, marked only, none. 0 keys naming a taskId on every line and span (C-9). What it did record of the task:
  a2a.task.state, a2a.result.kind and a2a.context.id on 5 of 5 SendMessage JSON answers, each agreeing with the
  execution ledger; all five response keys absent on 15 of 15 event-stream answers, including 5 -32001 errors (C-9).

**R6 application, Go worker (a2a-go v2.5.0; no control plane)**

- Caller identity — M, none. The ingress ledger's remote is the delivering proxy's address and 0 arrival lines carry
  an identity key: 3 of 3 arrivals across both receivers (C-1), 82 of 82 across both receivers, remote the ingress pod
  (C-10). Read from source, not measured: a2a-go builds its call context with User{Authenticated: false} and the
  request headers as ServiceParams (C-10). Whether either proxy forwards an identity header: not established (C-10).
- Target Service — N/A. C-1's map writes "it is the target": the column's question does not apply at the receiver.
- Path and headers — M. a2a_version=1.0, content_type, body length and body hash on every arrival, 3 of 3 across both
  receivers (C-1); the ledger keeps A2A-Version and Content-Type and no other header (C-1's map).
- JSON-RPC method — M. "method" on every arrival before the SDK: SendMessage 3 of 3 across both receivers (C-1); with
  REFUSE_OPERATION=SubscribeToTask the call interceptor refused 21 of 21 SubscribeToTask sends, one a 2,200,000-byte
  pad, and served SendMessage and SendStreamingMessage 20 of 20 (C-10). The Go receiver's spans name no operation, 0
  of 9 Go work items (B-6).
- messageId — M. On every arrival and in all three ledgers (C-1).
- taskId — M. Empty at the ingress ledger for a SendMessage, minted by the execution ledger per dispatch, carried by
  the invocation ledger (C-1). No A2A-hop span carries it; lab.task_id is set only on the model leg (B-6).

**R7 application, Python orchestrator (a2a-python 1.1.4; no control plane)**

- Caller identity — M, none. The same ledger readings as R6 (C-1, C-10). Read from source, not measured: a2a-python's
  default builder uses UnauthenticatedUser unless Starlette set a user, and keeps the request headers (C-10).
- Target Service — N/A. As R6.
- Path and headers — M. As R6 (C-1).
- JSON-RPC method — M. "method" on every arrival before the SDK (C-1); the request handler's check refused 21 of 21
  SubscribeToTask sends, one padded in params.tenant, and served 20 of 20 (C-10). The zero-code instrumentation names
  the handler method in span names — on_subscribe_to_task, on_message_send_stream — in 3 of 3 Python work items; span
  names, not attributes (B-6).
- messageId — M. As R6 (C-1).
- taskId — M. As R6 (C-1); no A2A-hop span carries it (B-6).

## 2. The enforcement table — "refuse SubscribeToTask, allow SendMessage" on one endpoint, tried at each layer that documents a mechanism

Counts are the entry's own. "Arrivals" is the pre-dispatch ingress ledger.

| # | Mechanism (entry) | Could it express the rule? | Refused / let through, counted | The refusing layer's own record | What failed open or broke |
|---|---|---|---|---|---|
| 1 | ztunnel L4, ALLOW only agw-central's principal on the worker (C-3; go receiver) | No. It admits by the identity a connection arrives with; it separates paths, not operations, and no SubscribeToTask was sent (C-3) | Through agw-central: 2 work items 1/1/1/1/1. Direct: GET and POST refused, curl exit 56, 0 ledger lines. Through the ingress on a fresh connection: GET 503 and POST 503, 0 ledger lines. Through the ingress on a connection opened 18 s before the policy: delivered, 1/1/1/1/1 (C-3) | Status ZtunnelAccepted=True, reason Accepted. ztunnel inbound "connection closed due to policy rejection: allow policies exist, but none allowed", naming the caller's identity and no policy; the direct caller got a reset, the ingress's caller a 503 "Connection reset by peer" (C-3) | The ingress dials the worker pod, so the recipe closed the out-of-cluster path to the worker too (C-3). A connection opened before a selector-scoped ALLOW was not closed and carried a request 59 s later (C-3); reproduced: selector-scoped 3 of 3 not closed, namespace-scoped 3 of 3 closed (C-3R), and again with a public server, 3 of 3 each (C-3R2); ztunnel logs nothing for the held connection |
| 2 | ztunnel given an HTTP rule, to.operation.methods GET on C-3's policy (C-4; go receiver) | No, not even for two requests that differ by HTTP method (C-4) | 6 of 6 requests refused, GET and POST on all three paths, the agw-central path included; 0 delivered; 0 ledger lines for 3 of 3 work items (C-4) | Status ZtunnelAccepted "True", reason UnsupportedValue, "... Within an ALLOW policy, rules matching HTTP attributes are omitted. This will be more restrictive than requested."; ztunnel's copy rules: []; istiod 0 lines at warn or error; ztunnel 6 policy-rejection lines naming no policy; agw-central's access line 503 "401 Unauthorized" (C-4) | Closed the worker to every caller, including the path C-3 admitted — the documented fail-safe (C-4) |
| 3 | Istio AuthorizationPolicy, targetRefs the Gateway agw-central, DENY on a probe header (C-5) | No: the API reads no body (authorization_policy.proto at 1.31.0, as C-5 cites it); the header probe asked only whether the mechanism reaches the proxy (C-5) | 0 refused. With the policy in force the 12 probes carrying the header were delivered, 12 of 12, 6 per receiver; 18 of 18 probes in all (C-5) | None at the proxy: the policies in its config dump hashed the same in all four dumps, and 0 of the 43 access lines in the window read 403. istiod wrote WaypointAccepted=True, reason Accepted, "bound to agentgateway-waypoint/agw-central", and pushed ztunnel resources:0 removed:1 (C-5) | The status says bound while nothing reached the proxy; istio/istio#60024 lists that status gap as out of scope (C-5) |
| 4 | HTTPRoute: a rule matching Accept: text/event-stream with no backendRefs, beside each ingress route (C-6) | No. It splits the a2a-go client's streaming operations from its unary one by a header the client chose (C-6) | Phase B: 12 refused (6 SubscribeToTask, 6 SendStreamingMessage, load client), 0 arrivals; 12 delivered (6 SendMessage, 6 curl SubscribeToTask with Accept: */*), 0 of them refused (C-6) | 500, error="no valid backends" reason=NoHealthyBackend on the access line; the client sees a plain 500, not a JSON-RPC error (C-6) | curl's SubscribeToTask passed 6 of 6; SendStreamingMessage was refused with SubscribeToTask; the refusal reads as a backend health failure (C-6) |
| 5 | agentgateway authorization, Deny on request.headers['accept'] (C-7, part 1) | No; the same split as row 4 (C-7) | 12 refused, 0 arrivals; 12 delivered, 6 of them curl SubscribeToTask (C-7) | http.status=403 error="authorization failed" reason=Authorization; the client 403 (C-7) | curl's SubscribeToTask passed 6 of 6 (C-7) |
| 6 | agentgateway authorization on source.identity, a Deny keyed on a probe header and serviceAccount == 'default' — a reading, by the author's decision (C-7, part 2) | Not for an operation. For a caller: one value for every lab caller on agw-central, none on the ingress, at this configuration (C-7) | agw-central: 6 of 6 probes refused, 0 arrivals. Ingress: 0 of 9 fired, 9 of 9 delivered (C-7) | agw-central 403 reason=Authorization, src.identity on the line; ingress: nothing, and no src.identity on its line (C-7) | On the ingress a Deny keyed on an identity never fired and nothing said so (C-7) |
| 7 | agentgateway authorization, Deny on json(request.body).method == "SubscribeToTask" (C-8) | Yes, within the buffer limit (C-8) | Under the limit: SubscribeToTask 40 of 40 refused (20 load client, 20 curl), 0 arrivals; SendMessage 20 of 20 and SendStreamingMessage 20 of 20 delivered; the Go card GETs 30 of 30. Past it (2,200,000 bytes): 2 of 2 passed with 200 — the Go receiver dispatched its x_pad SubscribeToTask; the Python receiver refused its x_pad form on its own validation before dispatch; a Python pad in params.tenant passed and was dispatched, 1 of 1. A batch passed 2 of 2 and neither SDK dispatched it; the duplicate key was refused 2 of 2 (C-8) | 403 reason=Authorization for each refusal; a request whose rule failed to evaluate reads 200 with no error and no reason; 0 non-access log lines at the default log level in every window (C-8) | Fails open past maxBufferSize, a size the client chooses, and is silent; the batch result rests on the receivers (C-8) |
| 8 | the same as Require, json(request.body).method != "SubscribeToTask" (C-8) | Not as written: it also refuses every bodyless request on the route (C-8) | Go path: the card GET refused 15 of 15, so no POST was sent, SendMessage included; curl SubscribeToTask 5 of 5 refused. Python path (card GET on agw-central): SendMessage 5 of 5 and SendStreamingMessage 5 of 5 delivered, SubscribeToTask 10 of 10 refused. Pad: 2 of 2 refused, 0 ledger lines (C-8) | 403 reason=Authorization (C-8) | Broke discovery on the Go path; fails closed past the limit (C-8) |
| 9 | the scoped Require, request.method == "GET" \|\| json(request.body).method != "SubscribeToTask" (C-8) | Yes; C-8's words: "held by one layer at this configuration" | Card GET 15 of 15 on the Go path, where the rule's GET clause was exercised (the Python card GET crosses agw-central's lab/orchestrator, where no rule was attached), SendMessage 10 of 10, SendStreamingMessage 10 of 10 delivered; SubscribeToTask 20 of 20 refused, 0 arrivals; pad 2 of 2 refused, 0 ledger lines (C-8) | 403 reason=Authorization (C-8) | Nothing counted. Untested: the batch and duplicate key under it, other paddings, a set maxBufferSize (C-8's not-covered list). Read from the rule's text, not a reading: it passes any GET whatever it carries |
| 10 | the application, REFUSE_OPERATION=SubscribeToTask: a2a-go call interceptor, a2a-python request-handler check (C-10) | Yes (C-10) | 42 of 42 SubscribeToTask refused, 21 per receiver, one 2,200,000-byte pad each; 0 executes, 0 invocations. 40 of 40 SendMessage and SendStreamingMessage served, 1 invocation each (C-10) | A JSON-RPC -32004 inside HTTP 200. Ingress ledger: an arrival with its method, 42 of 42. Execution ledger: received, then result carrying the refusal, 42 of 42. The proxy wrote 200 on 42 of 42, so the application's record is the only record (C-10) | The a2a-go client read the Python receiver's application/json refusal as an empty stream, no event and no error, 10 of 10, while its wire observer read -32004 (C-10) |

Not a row: agentgateway's A2A handling (R5). C-9 did not re-run authorization under the marking: it read from source
that the A2A block runs after route and backend authorization and that the marking adds no rule surface — read from
source, not measured (C-9).

## 3. Contradictions between entries

None found. Five places checked, each consistent once its configuration is named:

- C-9 wrote that its reading "changes B-6's 'no attribute names the operation' and C-1's map cell"; after C-9 wrote
  that C-9's readings "are not carried forward". Both hold: the first is the marked configuration (R5), the second the
  deployed one (R4).
- C-1's ingress-ledger remote for the ingress (10.244.1.26, in C-1's map) and C-10's (10.244.1.16) are pod addresses
  on different builds of the same topology; both are the ingress pod.
- C-6 and C-7 refused SendStreamingMessage and C-8's Deny passed it: different rules, each counted as written.
- "Both SDKs dispatched" past C-8's buffer limit holds by shape: a2a-go with a top-level x_pad; a2a-python only with
  the pad in params.tenant, its x_pad form refused on its own validation (C-8), as C-10 also states.
- B-6 calls the missing operation on the proxy spans "this lab's routes, not a limit of agentgateway", since the
  module keys on the Service marking (B-6's trace-readings.txt); C-9 switched the marking on and counted what it
  named and what it cost. The same shape as the first check: unmarked R4, marked R5.

# Experiment C after the D series, D-6: the map, on JSON-RPC, REST and gRPC, with distinct identities

Written 2026-09-25. This step ran nothing: no cluster, no stimulus, no code, no pin read or changed. It carries C-11's
map (experiments/runs/2026-09-24-c11-map/map.md, a dated record, not edited) forward with every cell the D series
counted. Every cell below is taken from a dated findings.md entry, cited by the short key in the list that follows,
and carries the qualifier its entry carries. A cell that no entry supports is EMPTY and says so. Nothing here is a
new reading, and no cell is filled from a neighbouring cell or from a document no entry cites.

## The entries the cells come from

C-11's own sources keep C-11's keys; a cell carried from C-11 cites "C-11" and the entry C-11 took it from. Dates are
the run directory's date.

| Key | findings.md heading (abridged after the dash) | Date, run directory |
|---|---|---|
| C-11 | Experiment C / both receivers / C-11, the map — what can each layer on this topology see and enforce of a JSON-RPC-bound A2A operation? | 2026-09-24, 2026-09-24-c11-map |
| C-1 | Experiment C / both receivers / observation — what did each layer record of one clean SendMessage, and what could it tell apart? | 2026-09-20, 2026-09-20-c1-observation |
| C-3 | Experiment C / go receiver / C-3, ztunnel L4 — (abridged) | 2026-09-21, 2026-09-21-c3-c4-ztunnel |
| C-4 | Experiment C / go receiver / C-4, ztunnel given an HTTP rule — (abridged) | 2026-09-21, 2026-09-21-c3-c4-ztunnel |
| C-3R | Experiment C / ztunnel / open connections — (abridged) | 2026-09-21, 2026-09-21-c3r-open-connections |
| C-3R2 | Experiment C / ztunnel / open connections, public server — (abridged) | 2026-09-21, 2026-09-21-c3r2-public-server |
| B-6 | Experiment B / both receivers / B-6, the table — what B found, and what each trace shows of it | 2026-09-23, 2026-09-23-b6-traces-and-table |
| C-5 | Experiment C / agw-central / C-5, Istio's AuthorizationPolicy with targetRefs naming agw-central — (abridged) | 2026-09-23, 2026-09-23-c5-istio-policy-agw-central |
| C-6 | Experiment C / both receivers / C-6, what a Gateway API HTTPRoute can separate — (abridged) | 2026-09-23, 2026-09-23-c6-httproute |
| C-7 | Experiment C / both receivers / C-7, agentgateway's authorization on headers and on identity — (abridged) | 2026-09-23, 2026-09-23-c7-agw-authorization |
| C-8 | Experiment C / both receivers / C-8, agentgateway's authorization on the request body — (abridged) | 2026-09-23, 2026-09-23-c8-body-rule |
| C-10 | Experiment C / both receivers / C-10, the application refuses the operation — (abridged) | 2026-09-24, 2026-09-24-c10-application |
| C-9 | Experiment C / both receivers / C-9, the A2A marking switched on — (abridged) | 2026-09-24, 2026-09-24-c9-a2a-marking |
| after C-9 | Experiment C / both receivers / after C-9 — with the A2A marking reverted, is the lab back on its measured topology? | 2026-09-24, 2026-09-24-c9-revert |
| D-1h | Experiment C / both receivers / D-1, the header reading — which request headers reach each application on B-4's paths and on the orchestrator's forward, and does any caller identity arrive in one? | 2026-09-24, 2026-09-24-d1-current-topology |
| D-2b | Experiment C / both receivers / D-2, the REST and gRPC bindings rebuilt — (abridged) | 2026-09-24, 2026-09-24-d2-bindings |
| D-2r | Experiment C / both receivers / D-2, the route layer on REST and gRPC — (abridged) | 2026-09-24, 2026-09-24-d2-bindings |
| D-2p | Experiment C / both receivers / D-2, agentgateway's authorization on request.path — (abridged) | 2026-09-24, 2026-09-24-d2-bindings |
| D-2y | Experiment C / both receivers / D-2, C-8's body rule on REST and gRPC — (abridged) | 2026-09-24, 2026-09-24-d2-bindings |
| D-2a | Experiment C / both receivers / D-2, the application refuses the operation on REST and gRPC — (abridged) | 2026-09-24, 2026-09-24-d2-bindings |
| D-3a | Experiment C / both receivers / D-3, an external authorizer on each binding — (abridged) | 2026-09-24, 2026-09-24-d3-extauthz |
| D-3m | Experiment C / both receivers / D-3, the body past maxSize and the request the authorizer cannot read — (abridged) | 2026-09-24, 2026-09-24-d3-extauthz |
| D-3u | Experiment C / both receivers / D-3, the authorizer unavailable — (abridged) | 2026-09-24, 2026-09-24-d3-extauthz |
| D-3b | Experiment C / both receivers / D-3b, the authorization fixture over every shape the receivers dispatch — (abridged) | 2026-09-25, 2026-09-25-d3b-extauthz-shapes |
| D-4b | Experiment C / both receivers / D-4, the rebuild with three ServiceAccounts — (abridged) | 2026-09-25, 2026-09-25-d4-serviceaccounts |
| D-4i | Experiment C / both receivers / D-4, the identity re-reading — (abridged) | 2026-09-25, 2026-09-25-d4-serviceaccounts |
| D-4z | Experiment C / go receiver / D-4, Row Z, ztunnel's ALLOW on principals — (abridged) | 2026-09-25, 2026-09-25-d4-serviceaccounts |
| D-4a | Experiment C / go receiver / D-4, Row A, agentgateway's Allow on source.identity — (abridged) | 2026-09-25, 2026-09-25-d4-serviceaccounts |
| D-5n | Experiment C / both receivers / D-5, the connection count — (abridged) | 2026-09-25, 2026-09-25-d5-a2a-backend |
| D-5t | Experiment C / both receivers / D-5, the A2A backend type as a trial — (abridged) | 2026-09-25, 2026-09-25-d5-a2a-backend |

## The configuration each cell holds for

kind; k8s v1.37.0, Istio 1.31.0, agentgateway v1.5.0, Gateway API v1.6.2 experimental, a2a-spec 3303592, a2a-go
v2.5.0, a2a-python 1.1.4; from D-2 on also grpcio 1.84.0 and grpc-go v1.83.2, and from D-3 on go-control-plane envoy
v1.39.0. The topology of 2026-09-19: agentgateway-ingress (ztunnel-captured) and agw-central (not enrolled,
terminating HBONE itself), ztunnel at L4 under istiod, mesh-wide STRICT. The agent Services unmarked.

What changed between C-11 and now, and whether it stands:

- **Bindings (standing from D-2's rebuild).** Both agents serve JSON-RPC and REST on 8080 and gRPC on 8081; two
  GRPCRoutes on the ingress on their own hostnames; nothing gRPC on agw-central, whose waypoint listener serves only
  8080 (D-2b). Every JSON-RPC row still uses JSON-RPC.
- **The extauthz fixture (in lab, default ServiceAccount).** Its objects stand from D-3's deploy commit, and its
  decision code is D-3b's, standing from D-3b's rebuild at D-3b's third commit (vcs.revision 217b2da9, D-3b); row 16
  counts D-3's decision code and row 19 D-3b's. The policies that
  call it are NOT standing: each was applied from a run directory and removed (D-3a, D-3b, D-4i). Row R8 and the
  enforcement rows 16 to 19 hold only while such a policy is in force.
- **Three ServiceAccounts (standing from D-4's rebuild, the commit "feat(deploy): the load client, the worker and
  the orchestrator each on their own ServiceAccount, from base, token automount off").** The load client, the worker
  and the orchestrator run as lab/sa/loadgen, lab/sa/worker and lab/sa/orchestrator; the mock, the extauthz fixture,
  the replay harness and the probe pods keep the default account (D-4b). Every cell in the column "caller identity,
  one account" is a record of the single-identity setup, which D-4b says the entries before it remain.
- **Not standing, and named in every cell that uses them:** the A2A marking (C-9, reverted after C-9; applied again
  for one set of sends from a run directory in D-5n); the A2A backend type (D-5t, a trial, not kept); LEDGER_HEADERS
  (D-1h, D-4i, one window each, restored empty); every route, AgentgatewayPolicy, AuthorizationPolicy and
  REFUSE_OPERATION setting of the enforcement rows (each applied from a run directory or set for one window).

## 1. The observation map

Columns: caller identity under one account (C-11's column, the single-identity setup); caller identity under three
accounts (D-4, standing); target Service; path and headers; the operation on each binding; messageId; taskId.
Rows: C-11's seven, and R8, the external authorizer, which D-3 added as a layer that receives the request.

Tags: **M** measured (a count or reading in the cited entry); **D** documented or read from source, as the cited
entry labels it, and not measured; **E** empty (no entry supports a cell); **N/A** not applicable, with the entry
that says so. A cell with a measured reading and a documented or read-from-source sentence beside it is counted M, as
C-11 counted.

### 1.1 The grid

| Layer | Caller identity, one account | Caller identity, three accounts | Target Service | Path and headers | Operation, JSON-RPC | Operation, REST | Operation, gRPC | messageId | taskId |
|---|---|---|---|---|---|---|---|---|---|
| R1 ztunnel, L4 (istiod) | M: the delivering proxy's, not the caller's | M: the caller's own on the hop it captures; behind a proxy, the proxy's | M: yes | M: none | M: none | E | E | M: none | M: none |
| R2 route layer: HTTPRoute, and GRPCRoute from D-2 | D: no match field names a source | E | M: yes, by route and hostname; gRPC on its own hostnames | M: path, method, query, headers | M: not separable | M: yes, by the path | M: yes, by the gRPC method | D: in the body, not matchable | D: in the body, not matchable |
| R3 agentgateway authorization, CEL | M: agw-central one value; ingress none | M: agw-central each caller's own; ingress none verified | M: as attachment scope; GRPCRoutes too | M: yes; request.path too | M: yes, by the body, within the buffer limit | M: yes, by request.path; the body rule separates nothing | M: yes, by request.path; the body rule separates nothing | D: mechanism not exercised | D: mechanism not exercised |
| R4 agentgateway telemetry, marking off (deployed) | M: agw-central one value; ingress none | M: agw-central each caller's own; ingress none | M: yes; gRPC routes too | M: method, path, host; no header | M: none | M: in the path on the line | M: in the path on the line, with grpc.status | M: none (JSON-RPC) | M: none on JSON-RPC; REST subscribe path as sent |
| R5 agentgateway A2A handling, marking ON (not standing) | E | M: agw-central's src on every marked agent line | M: yes; card rewritten, gRPC interface too | M: card GET classified | M: yes, at the ingress and at agw-central | E | E | M: none | M: none |
| R6 application, Go worker | M: none; remote the proxy; no identity header | M: none; remote the proxy; no identity header | N/A | M: A2A-Version, content type, body hash; all names in a window | M: yes, before the SDK, in the shapes counted | M: yes, before the SDK | M: yes, before the SDK | M: yes | M: yes |
| R7 application, Python orchestrator | M: none; remote the proxy; no identity header | M: none; remote the proxy; no identity header | N/A | M: as R6 | M: yes, before the SDK, in the shapes counted | M: yes, before the SDK | M: yes, before the SDK | M: yes | M: yes |
| R8 external authorizer, the lab's fixture over extAuth (policy not standing) | M: empty source principal | M: empty source principal | M: :authority among the names received | M: every header by name, and the path as the backend gets it | M: yes, by the body; undecidable past maxSize | M: yes, by the path | M: yes, by the path | E | M: REST, in the decoded path |

Cell counts, 8 rows by 9 columns, 72 cells: **M 58, D 5, E 7, N/A 2.**

- The 5 D cells: R2 caller identity, messageId and taskId (documented limits, C-11 from C-1 and C-6); R3 messageId and
  taskId (a documented mechanism not exercised, C-11 from C-1 and C-8). None was re-read by a D entry.
- The 7 E cells: R1 operation on REST and on gRPC; R2 caller identity under three accounts; R5 caller identity under
  one account, and R5 operation on REST and on gRPC; R8 messageId. Each says why below.
- The 2 N/A cells: R6 and R7 target Service, where C-1's map writes "it is the target" (C-11).
- C-11's 42 cells are all here, in the columns "caller identity, one account", "target Service", "path and headers",
  "operation, JSON-RPC", "messageId" and "taskId" of R1 to R7. D entries changed or extended 15 of them, each named in
  its cell below with the entry and the configuration: R2 target Service and path and headers; R3 target Service and
  path and headers; R4 target Service, path and headers and taskId; R5 target Service and operation; R6 and R7 caller
  identity and path and headers; R6 and R7 operation on JSON-RPC.
- Measured cells that are new: R1, R3, R4, R5, R6, R7 and R8 under three accounts; R2, R3, R4, R6, R7 and R8 on REST and on
  gRPC; R8 in every column but messageId.

### 1.2 The cells, in full

**R1 ztunnel, L4 (istiod; AuthorizationPolicy, PeerAuthentication)**

- Caller identity, one account — M, C-11's cell (C-1, C-3): behind a proxy the receiver's ztunnel names the delivering
  proxy, not the caller, 3 of 3 legs of C-1; callers carried ns/lab/sa/default on their own legs; a refusal line names
  the identity the caller arrived with and no policy.
- Caller identity, three accounts — M (D-4i, D-4b, D-4z; accounts standing). ztunnel records each caller's own identity
  on the hop it captures: src lab/sa/loadgen from every load-client pod, to agw-central on outbound lines only (agw-central
  is not enrolled; 0 inbound lines to it) and to the ingress on outbound and inbound lines; the worker and the
  orchestrator as themselves on their legs to agw-central (the series). Behind a proxy it records the proxy: the agents'
  inbound series name agw-central's or the ingress's account (D-4i). Against D-3b's proof, 12 of 24 legs differ only in a
  principal (D-4b). Row Z's refusals name src lab/sa/loadgen and dst lab/sa/worker, 10 of 10 lines (D-4z). This changes
  the setup C-11's cell describes, not C-11's reading of it.
- Target Service — M, C-11's cell (C-1): dst.service on every access line; 99 of 99 series carry the same 30 labels.
- Path and headers — M, none, C-11's cell (C-1, C-4): 0 of 165 lines carry http.method or http.path; given an HTTP
  rule, istiod handed ztunnel the ALLOW policy with rules: [].
- Operation, JSON-RPC — M, none, C-11's cell (C-1): 0 of 165 lines carry SendMessage.
- Operation, REST — E. No D entry read ztunnel's lines for a REST request. C-1's reading was taken on JSON-RPC traffic
  and is not carried across bindings.
- Operation, gRPC — E. The same: no D entry read ztunnel's lines for a gRPC request.
- messageId — M, none, C-11's cell (C-1): 0 of 165 lines.
- taskId — M, none, C-11's cell (C-1): 0 of 165 lines.

**R2 route layer (agentgateway's controller; Gateway API v1.6.2 experimental): HTTPRoute, and GRPCRoute from D-2**

- Caller identity, one account — D, C-11's cell (C-1, C-6): HTTPRouteMatch has four fields and none names a source
  (httproute_types.go at v1.6.2, l.761-798, as C-1 and C-6 cite it).
- Caller identity, three accounts — E. No D entry re-read the route layer for identity. C-11's documented limit is a
  statement about the match fields and is not re-read here under three accounts.
- Target Service — M, C-11's cell (C-1, C-6), extended by D-2 (bindings standing): two GRPCRoutes on the ingress on the
  hostnames worker-grpc.lab.internal and orchestrator-grpc.lab.internal; a gRPC SendMessage was carried on
  lab/worker-grpc-ingress and lab/orchestrator-grpc-ingress; every route read Accepted and ResolvedRefs (D-2b).
- Path and headers — M, C-11's cell (C-6: every JSON-RPC POST is POST / with no query; only Accept differed, set by the
  a2a-go client), extended by D-2: a REST SendMessage is POST /message:send, HTTP/1.1; a REST SubscribeToTask is POST
  /tasks/<id>:subscribe; a gRPC SendMessage is POST /lf.a2a.v1.A2AService/SendMessage, HTTP/2.0 (D-2b, D-2r).
- Operation, JSON-RPC — M, not separable, C-11's cell (C-6): SendMessage and SubscribeToTask read POST, / and no query
  alike, 12 of 12.
- Operation, REST — M, yes (D-2r; the added routes applied from a run directory, not standing): an HTTPRoute with a
  RegularExpression path match ^/tasks/[^/]+:subscribe$ and no backendRefs refused SubscribeToTask 20 of 20 (5 load
  client and 5 curl per receiver), 0 arrivals, while SendMessage passed on the deployed route 10 of 10.
- Operation, gRPC — M, yes (D-2r; not standing): a GRPCRoute with an Exact method match lf.a2a.v1.A2AService /
  SubscribeToTask refused 10 of 10, 0 arrivals; SendMessage 10 of 10 delivered.
- messageId — D, C-11's cell (C-1's map): in the body on JSON-RPC, not matchable. No D entry matched on it on any
  binding.
- taskId — D, C-11's cell (C-1's map): in the body on JSON-RPC, not matchable. On REST the SubscribeToTask path carries
  the id the request names (D-2r); D-2's expression matched any id in that position and no D entry matched on a given
  task id.

**R3 agentgateway authorization (AgentgatewayPolicy spec.traffic.authorization, CEL; agentgateway's controller)**

- Caller identity, one account — M, C-11's cell (C-7): on agw-central one value for every lab caller, ns/lab/sa/default,
  a probe Deny fired 6 of 6; on the ingress 0 of 9 fired, 9 of 9 lines without src.identity.
- Caller identity, three accounts — M (D-4a, D-4i; accounts standing, policies from run directories). At agw-central an
  Allow on "source.identity.namespace == 'lab' && source.identity.serviceAccount == 'orchestrator'" refused the load
  client 5 of 5 and passed the orchestrator's forward 5 of 5 (D-4a). At the ingress a probe Deny on source.identity fired
  0 of 10: no verified caller identity (D-4i). At the ingress source.unverifiedWorkload.serviceAccount, which cel.md at
  v1.5.0 l.122-125 calls resolved from the source IP and not cryptographically authenticated (as D-4i cites it), fired
  10 of 10 for the load client's account and 0 of 5 for the orchestrator's, the ingress's src.addr being the probe pod's
  own address on 25 of 25 lines; D-4i used it only to read its value, kept it out of the enforcement rows by the
  controller's ruling, and concludes nothing about it for authorization.
- Target Service — M, as attachment scope, C-11's cell (C-8), extended by D-2: a traffic policy may target a GRPCRoute
  (agentgateway_policy_types.go at v1.5.0 l.67, as D-2p reads it), and four policies on the two HTTPRoutes and two
  GRPCRoutes read Accepted and Attached, the ingress's dump holding their 4 expressions while in force (D-2p).
- Path and headers — M, C-11's cell (C-7, C-8), extended by D-2: request.path read on REST and gRPC (D-2p).
- Operation, JSON-RPC — M, C-11's cell (C-8): json(request.body).method as a Deny refused SubscribeToTask 40 of 40 and
  passed SendMessage 20 of 20 and SendStreamingMessage 20 of 20; past maxBufferSize the variable fails to evaluate.
- Operation, REST — M (D-2p, D-2y; policies from run directories). request.path.endsWith(":subscribe") as a Deny refused
  SubscribeToTask 20 of 20, curl included, and passed SendMessage 10 of 10 (D-2p). C-8's body rule, unchanged, separated
  nothing: a REST SendMessage body has no method field and a REST SubscribeToTask has no body (D-2y).
- Operation, gRPC — M (D-2p, D-2y). request.path == "/lf.a2a.v1.A2AService/SubscribeToTask" refused 10 of 10 and passed
  SendMessage 10 of 10 (D-2p). The body rule separated nothing: a gRPC body is a length-prefixed protobuf frame, which
  json() cannot parse (D-2y, with the source lines it reads).
- messageId — D, C-11's cell: a documented mechanism, not exercised. D-2y lists a CEL rule on the REST body's message
  fields as not covered.
- taskId — D, C-11's cell: a documented mechanism, not exercised. No D entry wrote a rule on a task id.

**R4 agentgateway telemetry, marking off — the deployed configuration**

- Caller identity, one account — M, C-11's cell (C-1, C-7): agw-central src.identity ns/lab/sa/default on 7 of 7 spans and
  13 of 13 lines; the ingress none.
- Caller identity, three accounts — M (D-4i; accounts standing). agw-central writes the caller's own identity on every
  line: lab/sa/loadgen on the load client's card GETs and POSTs, lab/sa/orchestrator on the forward, lab/sa/worker on
  every model call, lab/sa/default on the control pod's resets; every lab/worker and lab/orchestrator line in the four
  row windows and the closing check carries a src.identity. The ingress: 0 of 25 lines carry src.identity (D-4i).
  Row A's refusal lines carry src lab/sa/loadgen (D-4a).
- Target Service — M, C-11's cell (C-1), extended by D-2: the gRPC lines name lab/worker-grpc-ingress and
  lab/orchestrator-grpc-ingress (D-2b).
- Path and headers — M, C-11's cell (C-1, C-6), extended by D-2 and D-3: REST lines read POST /message:send, HTTP/1.1,
  200; gRPC lines POST /lf.a2a.v1.A2AService/SendMessage, HTTP/2.0 (D-2b); the ingress's line keeps the path as sent,
  undecoded, e.g. /tasks/<id>%3Asubscribe (D-3a, D-3b).
- Operation, JSON-RPC — M, none, C-11's cell (C-1, B-6, after C-9): 0 a2a.* or rpc.* keys on 423 spans; protocol=http.
  This is the cell in force.
- Operation, REST — M (D-2b, D-2r, D-3a). The operation is in the path, and the line records the path: POST
  /message:send for SendMessage (D-2b); the REST subscribe path as sent (D-3a). The line names no operation of its own.
- Operation, gRPC — M (D-2b, D-2r, D-2p, D-2a). The line records the method path, POST /lf.a2a.v1.A2AService/SendMessage,
  with http.status 200 and grpc.status 0 (D-2b). A refusal's HTTP status reads 200 on this binding for the route layer
  (reason=NoHealthyBackend, D-2r) and for the CEL path rule (reason=Authorization, D-2p); the application's refusal reads
  grpc.status 9 (D-2a).
- messageId — M, none, C-11's cell (C-1, B-6), on JSON-RPC. No D entry read the REST or gRPC lines for it.
- taskId — M, C-11's cell (C-1, B-6): none on JSON-RPC. Extended by D-3: on REST the subscribe path the line records as
  sent carries the id the request names (D-3a, D-3b, whose requests named no existing task). No D entry counted a task
  id key on any line.

**R5 agentgateway A2A handling, marking ON — not standing: C-9 (reverted after C-9) and D-5n (applied from a run
directory for one set of sends, then removed, under three accounts)**

- Caller identity, one account — E, C-11's cell: C-9 did not report src.identity on the marked lines.
- Caller identity, three accounts — M, marked only (D-5n's counts.txt, the record the D-5n entry cites as its result,
  l.29-33): every marked agent line at agw-central carries its source account, 6 of 6: sa=loadgen on the card GET and
  the SendMessage POST to lab/worker and to lab/orchestrator, and sa=orchestrator on 2 SendMessage POSTs to lab/worker,
  the orchestrator's forward. The entry's text does not state it; the cell rests on its cited record.
- Target Service — M, marked only, C-11's cell (C-9: the card rewrite wrote https at agw-central, and every client that
  followed a card to a Service address failed there, the orchestrator's forward 1 of 1 among them). The configuration
  differs in D-5n: its orchestrator held the worker's card from before the marking (D-5n's not-covered list), and its
  forward completed 2 of 2 under the marking (D-5n's counts.txt, l.33; every set 8 of 8 answered 200, D-5n). C-9's
  clients followed a card fetched under the marking. Extended by D-5n: the https card reproduced through agw-central,
  one GET per path, and the agents' third interface, protocolBinding GRPC with url worker.lab.svc.cluster.local:8081,
  rewritten too, to https://worker.lab.svc.cluster.local:8080 at agw-central and http://worker.lab.internal at the
  ingress (D-5n).
- Path and headers — M, marked only, C-11's cell (C-9): card GETs read protocol=a2a with no a2a.method.
- Operation, JSON-RPC — M, marked only. C-11's cell (C-9): a2a.method on 20 of 20 A2A POST lines on the Go receiver's
  ingress path, 0 arrivals from agw-central. Extended by D-5n: at agw-central, protocol=a2a on 6 of 6 agent lines and
  a2a.method=SendMessage on its 4 POSTs (D-5n). By D-5n's counts.txt (l.30-33), 2 of the 4 were the probe's curl
  SendMessage at the Service address, one per agent, src sa=loadgen, and 2 were the orchestrator's forward to
  lab/worker, an a2a-python client, src sa=orchestrator, on a card fetched before the marking (D-5n's not-covered list).
- Operation, REST — E. No D entry sent REST under the marking.
- Operation, gRPC — E. No D entry sent gRPC under the marking; the marking is on the HTTP port.
- messageId — M, marked only, none, C-11's cell (C-9).
- taskId — M, marked only, none, C-11's cell (C-9).
- Beside this row, not a cell of it: under D-5t's A2A backend type (a trial, not kept), which runs the same A2A block
  (read from source, D-5t), no request passed its card GET; agw-central's 25 of 25 lines and the ingress's 14 of 14 read
  protocol=a2a, and no a2a.method is reported (D-5t). D-5t writes that C-11's map is unchanged and the A2A handling row
  stays C-9's.

**R6 application, Go worker (a2a-go v2.5.0; no control plane)**

- Caller identity, one account — M, C-11's cell (C-1, C-10), changed by D-1h (one account): C-11 recorded "whether either
  proxy forwards an identity header: not established (C-10)". D-1h counted it: forwarded, x-forwarded-for,
  x-forwarded-proto, x-forwarded-host, x-real-ip, via and x-forwarded-client-cert on 0 of 15 arrivals across both agents;
  authorization_present false 15 of 15; the remote the forwarding proxy pod's own IP 15 of 15. x-caller arrived on 15 of
  15, loadgen or orchestrator, which D-1h reads as the caller's own declaration, set by the lab's clients.
- Caller identity, three accounts — M (D-4i; LEDGER_HEADERS for one window): 15 arrivals, the same names and counts as
  D-1h's, no forwarding, client-certificate or Authorization header, the remote a proxy's address 15 of 15. On Row Z's
  direct path, which crosses no proxy, the remote was the probe pod's own address (D-4z).
- Target Service — N/A, C-11's cell: C-1's map writes "it is the target".
- Path and headers — M, C-11's cell (C-1: the ledger keeps A2A-Version and Content-Type and no other header), extended
  by D-1h with LEDGER_HEADERS=on for one window (off by default, restored empty; not standing): the names that arrived
  over 15 arrivals were host, user-agent, accept-encoding, traceparent and x-caller 15 each, x-logical-work-item-id 14,
  a2a-version, content-type and content-length 8 each, accept 7, x-a2a-message-id 2 (both agents together).
- Operation, JSON-RPC — M, in the shapes counted (D-3a, D-3m). C-11's cell (C-1, C-10), extended by D-3: SubscribeToTask
  in three JSON-RPC shapes other than a POST to / arrived at the pre-dispatch ledger as SubscribeToTask and was
  dispatched: POST /x, POST /a2a/v1, and a JSON-RPC body with a gRPC content type, 5 each (D-3a). From an object naming
  method twice, a2a-go read the last key, 1 of 1; a batch was answered -32602 and not dispatched (D-3m). Read from source,
  not counted at the ledger: D-3b's routing reading of every shape the worker dispatches, from the pinned sources and a
  recording stub run against the SDK's handlers outside the cluster; D-3b's other shapes were refused at the fixture
  with 0 arrivals (D-3b).
- Operation, REST — M (D-2b, D-2a, D-3a): the arrival line names binding rest and the operation before dispatch; with
  REFUSE_OPERATION set for one window, a2a-go refused SubscribeToTask 10 of 10 after its arrival and received lines.
  The REST subscribe path with its colon percent-encoded arrived as SubscribeToTask, binding rest, and was dispatched on
  the REST handler, 5 of 5, TASK_NOT_FOUND (D-3a).
- Operation, gRPC — M (D-2b, D-2a): the arrival line names binding grpc and the operation; refused 5 of 5 with gRPC
  status 9 under REFUSE_OPERATION.
- messageId — M, C-11's cell (C-1): on every arrival and in all three ledgers.
- taskId — M, C-11's cell (C-1, B-6): minted by the execution ledger per dispatch; no A2A-hop span carries it.

**R7 application, Python orchestrator (a2a-python 1.1.4; no control plane)**

- Caller identity, one account — M, C-11's cell (C-1, C-10), changed by D-1h as R6's (the 15 arrivals are both agents'
  together).
- Caller identity, three accounts — M (D-4i): as R6's, the 15 arrivals being both agents' together.
- Target Service — N/A, as R6.
- Path and headers — M, C-11's cell (C-1), extended by D-1h as R6's.
- Operation, JSON-RPC — M, in the shapes counted (D-3a, D-3m). C-11's cell (C-1, C-10, B-6), extended by D-3: a
  JSON-RPC body with a gRPC content type arrived as SubscribeToTask and was dispatched, 5 of 5, -32001; POST /x and POST
  /a2a/v1 cannot reach its dispatch (Starlette's Route("/"), read from source by D-3a) (D-3a). It refused its x_pad form
  itself (-32600, 0 dispatch), read the last key of a duplicated method, 1 of 1, and refused a batch (-32600) (D-3m).
  D-3b's routing reading of the other shapes is read from source, not counted at the ledger (D-3b).
- Operation, REST — M (D-2b, D-2a, D-3a): binding rest on the arrival line; refused 10 of 10 with HTTP 400
  UNSUPPORTED_OPERATION under REFUSE_OPERATION. The percent-encoded REST subscribe path arrived as SubscribeToTask and
  was answered on the REST handler, 5 of 5, 404 TASK_NOT_FOUND (D-3a).
- Operation, gRPC — M (D-2b, D-2a): binding grpc on the arrival line, the ledger a server interceptor that wraps the
  deserializer; refused 5 of 5 with gRPC status 9. No Python gRPC server span: no gRPC instrumentation is installed, a
  recorded limit (D-2b).
- messageId — M, C-11's cell (C-1).
- taskId — M, C-11's cell (C-1, B-6).

**R8 external authorizer: agentgateway's extAuth to the lab's fixture (gRPC Check), on the four ingress routes — the
fixture standing from D-3, the policy applied from a run directory in each entry and NOT standing**

- Caller identity, one account — M (D-3a): source_principal empty on 190 of 190 decision lines of the deny and allow
  windows, 220 of 220 with the shapes row. Read from source: the principal is taken from the TLS connection the proxy
  accepted, and the ingress accepts plaintext from its own ztunnel (D-3a).
- Caller identity, three accounts — M (D-4i; D-3's overlay applied unedited from its record): empty on 15 of 15
  decision lines, with the load client running as lab/sa/loadgen. D-3b, rebuilt before D-4, read it empty on 345 of 345
  lines under one account (D-3b).
- Target Service — M (D-3a): :authority is among the header names the fixture received on the load client's JSON-RPC
  POST; the entry lists names, not values. The check is made on the routes the policy targets: agw-central's dump held 0
  extAuthz objects throughout (D-3a, D-3b).
- Path and headers — M (D-3a, D-3b): every request header and the pseudo-headers by name (:authority, :method, :path,
  :scheme, a2a-version, accept-encoding, content-length, content-type, traceparent, user-agent, x-caller,
  x-logical-work-item-id on the load client's JSON-RPC POST); the path the backend gets, undecoded and unnormalized
  (read from source, ext_authz.rs l.482-486, D-3b), and the fixture's line carries the decoded path beside it (D-3b).
- Operation, JSON-RPC — M (D-3a, D-3m, D-3b): by the body, the whole body received under maxSize (body_len equal to size,
  296 to 307 bytes); SubscribeToTask 40 of 40 refused, SendMessage and SendStreamingMessage 40 of 40 delivered. Past
  forwardBody.maxSize 2097152 the fixture received the first 2097152 bytes and size -1, 12 of 12 checks (D-3m). With the
  body read wherever a receiver's JSON-RPC handler would read it, 155 of 155 SubscribeToTask in 22 shapes refused (D-3b).
- Operation, REST — M (D-3a, D-3b): by the path; SubscribeToTask 10 of 10 refused, SendMessage 10 of 10 delivered; D-3b
  decides on the decoded path.
- Operation, gRPC — M (D-3a): by the path; 10 of 10 refused, 10 of 10 delivered. The body a gRPC check carries is the
  frame as lossy UTF-8, 135 bytes against a size of 133, and the fixture does not read it.
- messageId — E. The whole JSON-RPC body reached the fixture (D-3a), and no D entry read or ruled on a messageId in it.
- taskId — M, REST only (D-3b): the decoded path on the fixture's line carries the id a REST subscribe names. No D entry
  read a task id from a JSON-RPC or gRPC body.

## 2. The enforcement table

The rule is C-11's, "refuse SubscribeToTask, allow SendMessage" on one endpoint, except rows 20 and 21, which try
D-4's "allow the orchestrator, refuse the load client". Counts are the entry's own. "Arrivals" is the pre-dispatch
ingress ledger. Rows 1 to 10 are C-11's, carried with its wording shortened and its counts unchanged; rows 11 to 22 are
the D series'. None of the 22 is in the deployed configuration: each ran under a policy, route, backend or setting
applied or set for its window and removed, as each entry's Method records.

| # | Mechanism (entry; binding; configuration) | Could it express the rule? | Refused / let through, counted | The refusing layer's own record | What failed open or broke |
|---|---|---|---|---|---|
| 1 | ztunnel L4, ALLOW only agw-central's principal on the worker (C-3 via C-11; JSON-RPC; one account) | No: it admits by the identity a connection arrives with and separates paths, not operations; no SubscribeToTask was sent. Under three accounts see row 20 | Through agw-central 2 work items 1/1/1/1/1; direct refused, curl exit 56, 0 ledger lines; through the ingress on a fresh connection 503, 0 ledger lines; on a connection opened before the policy, delivered | ZtunnelAccepted=True; ztunnel "connection closed due to policy rejection: allow policies exist, but none allowed", naming the caller's identity and no policy | Closed the out-of-cluster path too; a connection opened before a selector-scoped ALLOW was not closed (C-3; C-3R 3 of 3; C-3R2 3 of 3) |
| 2 | ztunnel given an HTTP rule, to.operation.methods (C-4 via C-11; JSON-RPC; one account) | No, not even for two HTTP methods | 6 of 6 refused on all three paths; 0 delivered; 0 ledger lines | ZtunnelAccepted "True", reason UnsupportedValue; ztunnel's copy rules: []; 6 policy-rejection lines naming no policy | Closed the worker to every caller, the documented fail-safe |
| 3 | Istio AuthorizationPolicy, targetRefs agw-central, DENY on a probe header (C-5 via C-11; JSON-RPC; one account) | No: the API reads no body (authorization_policy.proto at 1.31.0, as C-5 cites it) | 0 refused; 12 of 12 header probes delivered, 18 of 18 in all | None at the proxy; istiod WaypointAccepted=True, "bound to agentgateway-waypoint/agw-central" | The status says bound while nothing reached the proxy (istio/istio#60024 lists that gap as out of scope) |
| 4 | HTTPRoute match on Accept: text/event-stream, no backendRefs (C-6 via C-11; JSON-RPC) | No: a header the client chose | 12 refused, 0 arrivals; 12 delivered, 6 of them curl SubscribeToTask | 500 "no valid backends" reason=NoHealthyBackend | curl's SubscribeToTask passed 6 of 6; SendStreamingMessage refused with SubscribeToTask |
| 5 | agentgateway Deny on request.headers['accept'] (C-7 via C-11; JSON-RPC) | No; the same split as row 4 | 12 refused, 0 arrivals; 12 delivered, 6 of them curl SubscribeToTask | 403 reason=Authorization | curl's SubscribeToTask passed 6 of 6 |
| 6 | agentgateway on source.identity, a Deny keyed on a probe header (C-7 via C-11; JSON-RPC; one account) | Not for an operation; for a caller, one value on agw-central and none on the ingress. Under three accounts see row 21 | agw-central 6 of 6 refused; ingress 0 of 9 fired | agw-central 403 reason=Authorization with src.identity; ingress nothing | On the ingress a Deny keyed on an identity never fired and nothing said so |
| 7 | agentgateway Deny on json(request.body).method (C-8 via C-11; JSON-RPC) | Yes, within the buffer limit | SubscribeToTask 40 of 40 refused, 0 arrivals; SendMessage 20 of 20 and SendStreamingMessage 20 of 20 delivered; past 2,097,152 bytes 2 of 2 passed; a batch passed 2 of 2; the duplicate key refused 2 of 2 | 403 reason=Authorization; a rule that failed to evaluate reads 200, no reason | Fails open past maxBufferSize, silently |
| 8 | the same as a Require (C-8 via C-11; JSON-RPC) | Not as written: it refuses every bodyless request on the route | Go path: card GET refused 15 of 15, so no POST; Python path: SendMessage 5 of 5 and SendStreamingMessage 5 of 5 delivered, SubscribeToTask 10 of 10 refused; pad 2 of 2 refused | 403 reason=Authorization | Broke discovery on the Go path |
| 9 | the scoped Require, request.method == "GET" or the body's method is not SubscribeToTask (C-8 via C-11; JSON-RPC) | Yes, on JSON-RPC (C-8: "held by one layer at this configuration"). On REST and gRPC see row 14 | Card GET 15 of 15, SendMessage 10 of 10, SendStreamingMessage 10 of 10 delivered; SubscribeToTask 20 of 20 refused, 0 arrivals; pad 2 of 2 refused | 403 reason=Authorization | Nothing counted; untested forms listed by C-8 |
| 10 | the application, REFUSE_OPERATION=SubscribeToTask (C-10 via C-11; JSON-RPC) | Yes | 42 of 42 SubscribeToTask refused, 0 executes, 0 invocations; 40 of 40 SendMessage and SendStreamingMessage served | JSON-RPC -32004 inside HTTP 200; the ingress and execution ledgers, 42 of 42; the proxy wrote 200 on 42 of 42 | The a2a-go client read the Python receiver's application/json refusal as an empty stream, 10 of 10 |
| 11 | Route layer, added beside the deployed routes with no backendRefs: an HTTPRoute path match ^/tasks/[^/]+:subscribe$ (REST) and a GRPCRoute method match lf.a2a.v1.A2AService / SubscribeToTask (gRPC) (D-2r; applied from a run directory) | Yes, on both bindings | REST per receiver: SubscribeToTask 5 of 5 load client and 5 of 5 curl refused, SendMessage 5 of 5 delivered. gRPC per receiver: 5 of 5 refused, 5 of 5 delivered. 30 refused, 0 with an arrival; 20 delivered | REST: 500 error="no valid backends" reason=NoHealthyBackend, the client 500. gRPC: http.status=200 reason=NoHealthyBackend, the client gRPC status 14 UNAVAILABLE | The refusal reads as a backend health failure on both; on gRPC an HTTP 200, so "a client or dashboard reading HTTP status sees a gRPC refusal as a success" (D-2r) |
| 12 | agentgateway Deny on request.path: endsWith(":subscribe") on the HTTPRoutes, == "/lf.a2a.v1.A2AService/SubscribeToTask" on the GRPCRoutes (D-2p; applied from a run directory) | Yes, on both bindings, for every client, curl included | REST per receiver: 5 of 5 load client and 5 of 5 curl refused, 5 of 5 SendMessage delivered. gRPC per receiver: 5 refused, 5 delivered. 30 refused, 0 arrivals; 20 delivered | REST: 403 reason=Authorization. gRPC: http.status=200 reason=Authorization, the client status 7 PERMISSION_DENIED "authorization failed" | Nothing counted |
| 13 | C-8's Deny on json(request.body).method, unchanged, on REST and gRPC (D-2y; applied from a run directory) | No: it fired on 0 of 50 sends | SendMessage 20 of 20 delivered; SubscribeToTask 30 of 30 passed and answered by the receiver, 1 arrival each, 0 executes, 0 invocations | None: it never fired | Passed every SubscribeToTask on both bindings; read from source, json() fails to evaluate on a REST body with no method field, an empty body and a protobuf frame, and the failure becomes false (D-2y) |
| 14 | C-8's scoped Require, unchanged, on REST and gRPC (D-2y; applied from a run directory) | No: it refused the allowed operation too | 50 of 50 refused, SendMessage and SubscribeToTask alike, 0 arrivals; the Go path's card GET passed 200 | REST: 403 reason=Authorization. gRPC: http.status 200 reason=Authorization, the client status 7 | Broke SendMessage on both bindings, 20 of 20 |
| 15 | the application, REFUSE_OPERATION=SubscribeToTask, on REST and gRPC (D-2a; set for one window) | Yes, binding-agnostic in where it happens | SubscribeToTask 30 of 30 refused after 1 arrival and 1 received line, 0 executes, 0 invocations; SendMessage 20 of 20 COMPLETED | Python REST: 400 UNSUPPORTED_OPERATION on the proxy's line and at the client. Go REST: HTTP 200 text/event-stream with the error as the stream's one event, the proxy's line 200 on all 10. gRPC: status 9 FAILED_PRECONDITION, grpc.status 9 on the proxy's line | a2a-go v2.5.0's REST server sends an error raised before the first event as HTTP 200, and its missing-task answer the same way, 12 of 12; a layer reading HTTP status sees success |
| 16 | External authorizer: D-3's fixture over the shapes the SDK clients send, extAuth on the four ingress routes, forwardBody.maxSize 2097152, failureMode and cache unset, EXTAUTHZ_UNDECIDABLE=deny (D-3a; JSON-RPC, REST, gRPC; policy from a run directory, one account) | Yes, on all three bindings, for those shapes | JSON-RPC per receiver: SubscribeToTask 10 of 10 load client and 10 of 10 curl refused; SendMessage 10 and SendStreamingMessage 10 delivered. REST and gRPC per receiver: 5 refused, 5 delivered. 60 refused, 0 arrivals; 60 delivered, 1 invocation each. The Go path's card GETs allowed 30 of 30 | The fixture's decision line before every answer, 180 in the deny window, 0 unjoined. The proxy: 403 reason=DirectResponse with no error field, 70 lines. The ExtAuthz span reads grpc.status 0 for a refusal and an allow alike, 190 of 190. The gRPC client: status 7 from a plain HTTP 403, "malformed header: missing HTTP content-type", 10 of 10 | 30 of 30 SubscribeToTask in D-3's other four shapes (POST /x, POST /a2a/v1, a gRPC content type on a JSON-RPC body, the percent-encoded REST path) allowed and dispatched; by its access line an authorizer's refusal cannot be told from any other direct response |
| 17 | The undecidable setting, EXTAUTHZ_UNDECIDABLE deny (default) and allow, on JSON-RPC bodies of 2,200,000 bytes past maxSize, a batch and a duplicate method key (D-3m, repeated in D-3b; policy from a run directory) | At deny yes, at the cost of a large legitimate request; at allow no | Every check past maxSize received 2097152 bytes and size -1, 12 of 12; the proxy rejected none before the check. Deny: 10 of 10 refused, 0 arrivals, the 2 padded SendMessage among them. Allow: 10 of 10 forwarded; 5 of the 8 SubscribeToTask probes reached an SDK's dispatch; the 2 padded SendMessage COMPLETED. D-3b: every field of D-3's rows equal, 324 of 324 | The decision line carries the setting and the reason (undecidable:partial-body, batch, duplicate-key); refusals 403 reason=DirectResponse | At allow, C-8's fail-open again, at the authorizer's layer; the CRD's description says a body past maxSize is rejected, and the count sides with the controller and the dataplane, which send it cut |
| 18 | The authorizer unavailable: the fixture scaled to 0, failureMode unset (FailClosed) (D-3u; JSON-RPC; policy from a run directory) | No rule: it refused every request on the route | 20 of 20 refused by the proxy; Go path: the card GET refused, no POST sent, 10 of 10; Python path: the POST refused, 10 of 10; 0 arrivals, 0 dispatches, 0 invocations; 0 decision lines | 403 error="external authorization failed" reason=ExtAuth duration=0ms, and one warn line per check, "no healthy backends", 20 | Fails closed at once for every request, SendMessage and the card included; read from source, no timeout on the gRPC check at v1.5.0, set to 2 s by agentgateway#3426 in prereleases only, not counted |
| 19 | D-3b's fixture over every shape the receivers dispatch, the path decoded as the receivers decode it and the body read wherever a JSON-RPC handler would read it (D-3b; D-3's four policies copied unchanged, from a run directory) | Yes, for every shape the routing reading found | 155 of 155 SubscribeToTask in 22 shapes refused (go 18 shapes, py 13, 5 each), 0 arrivals, 0 dispatches, 0 invocations; D-3's rows unchanged, 324 of 324 fields | The decision line with decoded_path and jsonrpc_reach, 155 lines, 0 unjoined; 403 reason=DirectResponse | A body in UTF-16 or UTF-32, and D-3's Row 3 and 4 classes on the orchestrator's route, stay undecidable and are refused only because the setting is deny; the fixture is as complete as its copy of the receivers' routing, which a version change on either side can reopen (D-3b) |
| 20 | ztunnel ALLOW on principals at the worker, agw-central's and lab/sa/orchestrator, for D-4's rule (D-4z; go receiver; JSON-RPC card GET and SendMessage by curl, direct to the worker pod; three accounts, policy from a run directory) | Yes, on the direct path. Behind agw-central it admits agw-central whoever its caller (Istio's l4-policy l.102, as D-4z cites it) | The orchestrator's identity 5 of 5 delivered, 1/1/1/1/1; the load client's 5 of 5 refused, curl exit 56, no ledger line of any kind; the forward control 5 of 5 COMPLETED | ztunnel, 10 inbound lines "connection closed due to policy rejection: allow policies exist, but none allowed", src lab/sa/loadgen, dst lab/sa/worker; the client a reset with no HTTP status | Nothing failed open in the counts. The forwards rode a connection agw-central opened before the policy, which ztunnel did not close, so the ALLOW admitting agw-central on a new connection is not counted |
| 21 | agentgateway Allow on source.identity on agw-central's route lab/worker, namespace lab and serviceAccount orchestrator, for D-4's rule (D-4a; go receiver; JSON-RPC; three accounts, policy from a run directory) | Yes | The load client to the worker 5 of 5 refused at its card GET, no SendMessage sent, 0 arrivals; the orchestrator's forward 5 of 5 COMPLETED, 1/1/1/1/1 | agw-central 403 reason=Authorization with src lab/sa/loadgen on the line, 5 lines; the client "resolve card: card request failed, status: 403 Forbidden" | Nothing counted; it holds only where agw-central is on the path |
| 22 | agentgateway's A2A backend type, AgentgatewayBackend spec.a2a on the four HTTP agent routes (D-5t; a trial from a run directory, not kept) | Read from source, not measured: it adds no rule surface; the controller makes it a Static backend with the marking's inline A2A policy, and AgentgatewayPolicy has no a2a field (D-5t; C-9 read that the A2A block adds none) | No rule tried. Every row failed at its card GET, 21 of 21; 0 arrivals, 0 executes, 0 Tasks, 0 invocations; 4 of 4 curl card GETs 503 | Not a refusal of an operation: agw-central 503 protocol=a2a reason=UpstreamFailure, 25 of 25; ztunnel at the agents "explicitly denied by: istio-system/istio_converted_static_strict", 25 connections; the ingress 503 reason=Internal "agent card invalid JSON", 14 of 14 | Broke every client on every path, 21 of 21: the upstream leg left the mesh in plaintext and STRICT refused it; not kept, the lab stays unmarked |

Cell counts, 22 rows by the four judgement columns, 88 cells: **M 86, D (read from source or documented) 2, E 0.** The
2 D cells: row 3's "could it" (the API reads no body, documented, as C-5 cites it) and row 22's "could it" (read from
source by D-5t and C-9). A cell with a measured reading and a read-from-source sentence beside it is counted M.

Not rows, and why:
- agentgateway's A2A handling under the marking (R5): C-9 did not re-run authorization under it, and D-5n did not
  either (C-11, D-5n).
- source.unverifiedWorkload at the ingress: read as a value by D-4i, kept out of the enforcement rows by the controller's
  ruling, and "nothing is concluded about using source.unverifiedWorkload for authorization" (D-4i).

## 3. Contradictions between entries

**Found and recorded, not resolved: one, reported to the controller.**

- C-11's interpretation reads "The application sees the operation and the ids, and nothing that tells one caller from
  another" (C-11, "So, in the proposal's terms"). D-1h counted x-caller arriving at both applications on 15 of 15,
  with the value loadgen or orchestrator, and reads it as "the caller's own declaration ... whatever the client chooses
  to send" (D-1h); B-6 names lab.caller among the attributes on the receiver's span (B-6, trace reading 5). C-11's own
  cells R6 and R7 read caller identity "none" and its source, C-1's map, has the ledger keep A2A-Version and
  Content-Type only. The two statements are set side by side here and not reconciled.

**Checked, consistent once the configuration or binding is named:**

- C-11 records one identity value for every caller at agw-central and "separated paths, not callers" at ztunnel; D-4a,
  D-4i and D-4z separate callers. One account against three, D-4b saying the earlier entries remain the records of the
  single-identity setup.
- C-11 says the scoped Require "held the rule on every case counted"; D-2y counts it refusing 50 of 50 on REST and gRPC.
  C-11's map is stated for the JSON-RPC binding only.
- D-5t writes that C-11's map is unchanged and the A2A handling row stays C-9's; D-5n adds two readings under the same
  marking, re-applied for one set of sends. Both keep the row in a configuration the lab does not run; this map adds
  D-5n's readings to R5 with that label.
- C-11 R6 "whether either proxy forwards an identity header: not established (C-10)"; D-1h counts none. D-1h closes the
  question C-10 left open; the cell changed, and the two do not disagree.
- D-3a's empty source principal "consistent with C-7's reading for source.identity on the same hop"; D-4i reads it empty
  under three accounts. The same hop, the same cause as each entry reads it.
- D-2r: curl's SubscribeToTask "which C-6's header match let through on JSON-RPC" refused 10 of 10 on REST; C-6: curl's
  passed 6 of 6 on JSON-RPC. Different bindings and rules.
- C-9 and D-5n on the https card through agw-central: D-5n reproduced it.
- C-9: the orchestrator's forward failed at agw-central under the marking, 1 of 1; D-5n: the forward completed 2 of 2
  under the marking. D-5n's orchestrator held the worker's card from before the marking (D-5n's not-covered list), C-9's
  had fetched it under the marking. A difference of configuration, named in R5's target Service cell.

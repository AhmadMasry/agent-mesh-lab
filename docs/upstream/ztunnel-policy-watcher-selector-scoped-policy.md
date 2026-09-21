# Draft issue — ztunnel: a connection opened before a selector-scoped ALLOW policy is not closed when the policy arrives

Status: **draft, not filed.** Text for a human to review and file, addressed to istio/ztunnel. No link until it is filed.

## Issue text to file

Everything between the two rules below is the issue, written to be pasted into GitHub as it stands
(istio/ztunnel). It is built on the lab's seven repetitions of 2026-09-21 (one control, three per scope) and on
ztunnel's source at tag `1.31.0`; how the lab came to it is under "Lab notes" and is not part of the issue.

---

**Title:** Existing connections are not closed when a workload-selector AuthorizationPolicy denies them (namespace-scoped policies close them)

### Versions and environment

- ztunnel **1.31.0** (`docker.io/istio/ztunnel:1.31.0-distroless`), istiod **1.31.0** (`docker.io/istio/pilot:1.31.0-distroless`), ambient
- Kubernetes v1.37.0 on kind, two nodes; the client and the server below ran on the same node, so one ztunnel carried both sides
- Mesh-wide STRICT mTLS: a `PeerAuthentication` `default` in `istio-system` with mode `STRICT` (and one
  `PeerAuthentication` with a port-level exception on a workload in another namespace). Because of it ztunnel held
  `istio-system/istio_converted_static_strict` on the server's policy list before every apply. No
  `AuthorizationPolicy` existed before each apply. Whether the STRICT policy matters to the result was not tested.
- Source read at tag `1.31.0` (tag object `e6fdcc5b`); every line cited below reads the same on `master` at
  `db40ece` (2026-09-18)

### What happens

A client TCP connection to a server pod is open, tunnelled by ztunnel as one HBONE CONNECT stream, with one HTTP/1.1
request already served on it. An ALLOW `AuthorizationPolicy` that does not admit the client's identity is then
applied. The two policies tried differ only in `selector`, and the outcome differed with it (three runs each, on one
node, with one client identity):

| policy | ztunnel scope | istiod push to the node's ztunnel | open connection | second request on it | new connection |
|---|---|---|---|---|---|
| no `selector` | `Namespace` | WADS 68 B | closed 0.18–0.20 ms after `handling RBAC update`, with `connection … closed because it's no longer allowed after a policy update` and an access line `error="connection closed due to policy change"` — 3 of 3 | not delivered — 3 of 3 | refused — 3 of 3 |
| `selector: app: server` | `WorkloadSelector` | WDS 238 B + WADS 67 B | **not closed; no watcher line** — 3 of 3 | **delivered to the app, 200**, 0.46–0.54 s after `handling RBAC update` — 3 of 3 | refused — 3 of 3 |

In the selector case ztunnel's own state already held the policy and listed it on the server workload before the
second request was sent (`istioctl ztunnel-config policy` / `workloads -o json`), and a new connection opened a moment
later was refused (`connection closed due to policy rejection: allow policies exist, but none allowed`). The
already-open connection kept working until the client closed it. With no policy at all (control), both requests on
the held connection and a new connection were delivered.

In every run the client ztunnel's pooled HBONE connection to the server's 15008 stayed `ESTABLISHED`: in the
namespace case the watcher closed the tunnelled stream, not the pooled connection, and the next connection attempt
arrived on that same pooled connection. ztunnel tracks inbound streams under the pooled connection's source address
(the watcher's line names it); exactly one stream was tracked under that key at each apply — the server's tracked
inbound list (`istioctl ztunnel-config connections`) read 0 before each run and 1 after its first request.

### Expected

The behaviour #772 added for #311 ("close connections which violate policy after updates"): an existing connection
that the new policy denies is closed — for a selector-scoped policy as it is for a namespace-scoped one.

### Reproduction

An ambient namespace with one HTTP/1.1 server on port 8080 that keeps a connection alive between requests, and one
client pod from `curlimages/curl:8.22.0`, whose busybox provides `nc`. The lab's server was a Go `net/http` server
with a 120 s idle timeout, and this has not been run with another server: substitute your own image, and for
`$REQ_PATH` a path it answers. The client below is the pod the lab ran.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: repro
  labels:
    istio.io/dataplane-mode: ambient
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: server
  namespace: repro
spec:
  replicas: 1
  selector:
    matchLabels:
      app: server
  template:
    metadata:
      labels:
        app: server
    spec:
      containers:
        - name: server
          image: <an HTTP/1.1 server that keeps connections alive, listening on 8080>
          ports:
            - containerPort: 8080
---
apiVersion: v1
kind: Pod
metadata:
  name: client
  namespace: repro
spec:
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 65532
    runAsGroup: 65532
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: client
      image: curlimages/curl:8.22.0
      command: ["sleep", "7200"]
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        runAsNonRoot: true
        capabilities:
          drop:
            - ALL
---
# policy A: namespace scope
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: repro-namespace
  namespace: repro
spec:
  action: ALLOW
  rules:
    - from:
        - source:
            principals: ["cluster.local/ns/repro/sa/someone-else"]
---
# policy B: workload-selector scope, otherwise identical
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: repro-selector
  namespace: repro
spec:
  selector:
    matchLabels:
      app: server
  action: ALLOW
  rules:
    - from:
        - source:
            principals: ["cluster.local/ns/repro/sa/someone-else"]
```

Apply the namespace, the server and the client first; keep the two policies for the steps. For each policy, starting
with no `AuthorizationPolicy` in the cluster:

1. Hold one connection open and send one request on it:
   ```sh
   mkfifo in; kubectl -n repro exec -i client -- nc "$SERVER_POD_IP" 8080 < in > out &
   exec 3> in
   printf 'GET %s HTTP/1.1\r\nHost: server\r\n\r\n' "$REQ_PATH" >&3   # answered 200
   ```
2. `kubectl apply` the policy, then wait until ztunnel holds it:
   `istioctl ztunnel-config policy --node <node> -o json | jq -e 'any(.[]; .name == "<policy name>")'` and, for
   policy B, until it is listed on the server:
   `istioctl ztunnel-config workloads --node <node> -o json | jq -e 'any(.[]; (.name | startswith("server")) and ((.authorizationPolicies // []) | index("repro/repro-selector")))'`
   (the table output of `workloads` has no policy column).
3. Read ztunnel's log for `no longer allowed after a policy update`.
4. Send the same request again on the same connection (the `printf … >&3` of step 1).
5. Open a new connection: `kubectl -n repro exec client -- curl -sS --retry 0 "http://$SERVER_POD_IP:8080$REQ_PATH"` —
   refused (`Recv failure: Connection reset by peer`) for both policies.
6. `exec 3>&-`, delete the policy.

Policy A: step 3 finds the line, the client's socket is in `CLOSE_WAIT` before step 4, and the second request never
reaches the server (ztunnel's outbound side logs `while closing connection: send: io error: broken pipe` when it
arrives). Policy B: step 3 finds nothing, and step 4 is answered 200 by the server.

### Where it comes from — as read at tag `1.31.0`, the likely cause; not proven by a run

- `PolicyWatcher::run` (`src/proxy/connection_manager.rs` l.364-381) re-checks every tracked inbound connection on
  every policy change with `self.state.assert_rbac(&conn.ctx)` (l.374) and closes the ones now denied (l.376 logs
  the line above).
- `DemandProxyState::assert_rbac` (`src/state.rs` l.584-611) takes namespace and global policies from current state
  (`state.policies.get_by_namespace(&wl.namespace)`, l.593) but workload-selector policies from
  `wl.authorization_policies` (l.595), where `wl = &ctx.dest_workload` (l.588).
- `ctx.dest_workload` is the `Arc<Workload>` fetched when the stream was accepted (`src/proxy/inbound.rs` l.404-410)
  and stored in the context (l.434-437, `dest_workload: destination_workload.clone()`); it is excluded from the
  connection's identity (`src/state.rs` l.158-159, `#[educe(Hash(ignore), PartialEq(ignore))]` on
  `pub dest_workload: Arc<Workload>`). Each new stream fetches the workload from state again
  (`src/proxy.rs` l.195-197, l.240-248), which is why new connections were refused.
- A `WorkloadSelector`-scope policy is not indexed by namespace in the policy store (`src/state/policy.rs` l.74);
  it reaches a workload only through that workload's own `authorization_policies` list, which istiod changes with a
  WDS push. Here the selector-scope policy came with a one-resource 238 B WDS push, after which ztunnel's copy of the
  server's workload listed the new policy beside `istio-system/istio_converted_static_strict`; the namespace-scope
  policy came with no WDS push, and the server's list did not change.
- So the re-check of a stream accepted before that WDS update reads the old list, which does not name the new
  policy, and the stream passes. A namespace-scope policy is read from state, and it closed the stream here; a
  global-scope one would too (as read; not run).
- The tracking key is the pooled connection's source address and destination: a stream arriving on an occupied key
  increments a count and leaves the first stream's key, and with it the first stream's captured workload, in place
  (`register`, `src/proxy/connection_manager.rs` l.254-268), and `close()` (l.287-296) drains every stream under the
  key. In these runs one stream was tracked under the key each time, so neither bears on the counts above.
- History, as read: at #772's merge (`b95e5dd2`) `assert_rbac` fetched the destination workload from state by
  address on every call, so the re-check saw the current workload. #1218 ("Fetch local workload directly, rather
  than based on IP", merged 2024-08-23, `4de5e896`) moved the re-check to the `dest_workload` captured in the
  context, while each new connection still fetches the workload from state. Older versions were not run.
- `test_policy_watcher_lifecycle` (l.615) uses a `Scope::Global` policy (l.671), which is read from state, so it
  would not show this. As read and not run: the test inserts the policy through the state mutator
  (`insert_authorization`, `src/xds.rs` l.360-376), which does not call `policies.send()` — only the xDS handler
  does (l.529, l.535) — and its close assertion runs in a spawned task (l.683) that the test does not await, so the
  test may pass whether or not the watcher closes anything.

### What else could produce the same counts

Neither of these was excluded by a run; both are contradicted by the source as read.

1. **ztunnel applied the WADS update before the WDS update**, so that a watcher reading current state saw the old
   list once. istiod stamped the WDS push to this ztunnel 21–46 µs before the WADS push in each of the three
   selector runs, and the source above reads the captured workload in any case, but the order in which ztunnel
   applied the two was not read (it logs `handling RBAC update` at info, not the workload update), and no second
   policy change was made after the WDS landed to separate the two.
2. **The watcher never ran for the selector-scope update.** As read, `policies.send()` follows every WADS batch
   whatever the policy's scope (`src/xds.rs` l.529, l.535), and here the watcher fired within 0.2 ms on the same
   proxy for the namespace-scope policy; but a re-check that passes logs nothing, so its run for the selector-scope
   policy is not observed.

### Suggested direction

Have the watcher's re-check read the destination workload's current policy list (for example by
`dest_workload.uid` from state) rather than the snapshot taken at connect, and re-run the check when a WDS update
changes a workload's `authorization_policies`. The second part matters on its own: as read, the workload and address
handlers (`src/xds.rs` l.384, l.408) never call `policies.send()` — only the authorization handler does (l.529,
l.535) — so a re-check that read current state would still run only on the WADS push, and its result would depend on
the order in which the WDS and WADS updates were applied.

### Related

- #311 "Determine if RBAC updates should drain" (closed)
- #772 "close connections which violate policy after updates" (merged 2024-02-05)
- #1218 "Fetch local workload directly, rather than based on IP" (merged 2024-08-23)

---

## Lab notes (not part of the issue)

**How the lab came to it.** Experiment C's C-3 reading of 2026-09-21 (`findings.md`, "C-3, ztunnel L4") applied
Istio's own "allow only the waypoint's identity" recipe — an ALLOW policy with a workload `selector` — to the lab's
worker, and found one connection, opened by the agentgateway ingress 18 s before the policy, carry an A2A request to
the worker 59 s after ztunnel held the policy, while new connections were being refused. That record could not tell
whether ztunnel re-checked the connection. Its review read the source above and named the hypothesis; the author
approved this reproduction on 2026-09-21.

**The reproduction.** `findings.md`, "Experiment C / ztunnel / open connections", with every object, command and
reading in `experiments/runs/2026-09-21-c3r-open-connections/`: the driver `rep.sh`, one directory per repetition,
`counts.csv` from `counts.py`, the source lines and their hashes in `sources.txt` (the `master` readings and the
lines added in the review round are at its end, with their own stamps). It ran in a throwaway ambient namespace
with the lab's worker image as the server (sent only agent-card GETs, `/.well-known/agent-card.json`, answered
without a model call) and the lab's pinned curl image as the client; the namespace was deleted afterwards and the
cluster read back as found. The generic reproduction above — another server image, another path — has not been
run: running it would be a new run, and that is the author's call.

**The tracker, searched 2026-09-21T19:41Z** (`tracker-search.txt` in the run directory, every query with its
output): in istio/ztunnel, `PolicyWatcher` (1 result, #1660, CRL support — unrelated), the watcher's log line
verbatim (0), "policy update existing connection" (17, of which #311 and #772 are the related ones and none reports
this), "authorization policy existing connections" (1, #311), "selector policy existing connection" (0),
"dest_workload policy watcher" (0), `AuthorizationPolicyLateRejection` (0), "policy selector connection drain" (0);
in istio/istio, the watcher's log line verbatim (0) and "ztunnel authorization policy existing connection" (8, none
about this). #311, #772 and #1218 were each read. No existing issue or pull request reports this.

**Filing.** By the author, never by the lab's agents. When it is filed, the link goes here and in the entry's
Follow-up as a dated note beside it.

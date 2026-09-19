# Draft issue — agentgateway: an AgentgatewayPolicy reports Attached to a waypoint its controller does not program

Status: **draft, not filed.** Text for a human to review and file. No link until it is filed.

## Issue text to file

Everything between the two rules below is the issue, written to be pasted into GitHub as it stands
(agentgateway/agentgateway). It is built on the project's own tracing page and on the lab's two repetitions of
2026-09-19; the lab's history with this behaviour is under "Lab notes" and is not part of the issue.

---

**Title:** AgentgatewayPolicy reports Attached=True on a Gateway owned by another controller (istiod waypoint)

### Versions

- agentgateway **v1.5.0**: controller `cr.agentgateway.dev/controller:v1.5.0`, proxy `cr.agentgateway.dev/agentgateway:v1.5.0`
- Istio **1.31.0**, ambient, istiod with `PILOT_ENABLE_AGENTGATEWAY=true`
- Gateway API v1.6.2 (experimental channel), Kubernetes v1.37.0 on kind
- Both control planes in one cluster: GatewayClass `agentgateway` has `controllerName: agentgateway.dev/agentgateway`; GatewayClass `istio-agentgateway-waypoint` has `controllerName: istio.io/agentgateway-waypoint-controller`

### What happens

An `AgentgatewayPolicy` whose `targetRefs` names a Gateway of class `istio-agentgateway-waypoint` is given
`Accepted=True` and `Attached=True` ("Attached to all targets") by `agentgateway.dev/agentgateway`. The proxy behind
that Gateway is an agentgateway process, but it is a client of istiod's xDS, not of agentgateway's, and it never
receives the policy. The status says the policy is in force on a proxy that holds no policy.

### Reproduction

1. A cluster with Istio 1.31 ambient (agentgateway waypoints enabled) and agentgateway v1.5.0 installed beside it,
   an OTLP collector Service, and a waypoint that istiod manages, used by a Service through
   `istio.io/use-waypoint: agentgateway-waypoint`:

   ```yaml
   apiVersion: gateway.networking.k8s.io/v1
   kind: Gateway
   metadata:
     name: agentgateway-waypoint
     namespace: lab
     labels:
       istio.io/waypoint-for: service
     annotations:
       gateway.istio.io/agentgatewayImage: cr.agentgateway.dev/agentgateway:v1.5.0
   spec:
     gatewayClassName: istio-agentgateway-waypoint
     listeners:
       - name: mesh
         port: 15008
         protocol: HBONE
   ```

   (The `gateway.istio.io/agentgatewayImage` annotation pins the proxy image to v1.5.0. It is read by Istio's
   injector, `pkg/kube/inject/inject.go` and the waypoint template at tag 1.31.0; Istio's agentgateway page does not
   name it.)

2. Apply the manifest of the tracing page
   (https://agentgateway.dev/docs/kubernetes/latest/documentation/observability/traces/configs/otel/, "Version 1.5.x"),
   field for field, with only the names changed (the namespace, the Gateway, the collector Service):

   ```yaml
   apiVersion: agentgateway.dev/v1alpha1
   kind: AgentgatewayPolicy
   metadata:
     name: tracing
     namespace: lab
   spec:
     targetRefs:
       - kind: Gateway
         name: agentgateway-waypoint
         group: gateway.networking.k8s.io
     frontend:
       tracing:
         backendRef:
           name: otel-collector
           namespace: telemetry
           port: 4317
         protocol: GRPC
         randomSampling: "true"
   ```

3. Read the status, send a request through the waypoint, and read the proxy:

   ```
   $ kubectl -n lab get agentgatewaypolicy tracing -o jsonpath='{.status.ancestors[0]}'
   $ kubectl -n lab port-forward deploy/agentgateway-waypoint 15000:15000 &
   $ curl -s localhost:15000/config_dump | jq -c '{policies: (.policies|length), tracing: .config.tracing, xds: .config.xds.address}'
   ```

### Expected

Either the policy reaches the proxy, or, since the Gateway's class belongs to another controller, the status does
not claim attachment: `Attached` (or `Accepted`) false, with a reason that names the GatewayClass.

### Actual

Observed twice on 2026-09-19, the second time from a script, with the same result:

1. **The status.** Written by `agentgateway.dev/agentgateway` within the second the policy was created, and
   unchanged a minute later:

   ```
   controller=agentgateway.dev/agentgateway ancestor=Gateway/lab/agentgateway-waypoint
     Accepted=True reason=Valid message=Policy accepted
     Attached=True reason=Attached message=Attached to all targets
   ```

2. **The waypoint's `/config_dump`**, 31 s after that status and again 63 s after it with traffic in between:

   ```json
   {"policies":0,"tracing":null,"xds":"https://istiod.istio-system.svc:15012"}
   ```

   The dump 31 s after the policy is byte for byte the dump taken before the policy existed. Across one traced
   work item the proxy's own endpoint counter for the backend Service went `totalRequests` 0 → 3: the work item's
   two requests (an Agent Card GET and the A2A `SendMessage` POST) and one control POST that the lab's trace script
   sends to the same Service. So the proxy was on the path; `policies` was still empty.

3. **The xDS address of the waypoint against a Gateway of class `agentgateway`** in the same cluster, read in the
   same second. That proxy holds a tracing policy of the page's shape plus `clientSampling: "true"`, by name:

   ```json
   {"policies":["frontend/agentgateway-ingress/access-logs:frontend-logging:agentgateway-ingress/agentgateway-ingress","frontend/agentgateway-ingress/tracing:frontend-tracing:agentgateway-ingress/agentgateway-ingress"],"xds":"https://agentgateway.agentgateway-system.svc.cluster.local:9978"}
   ```

   The waypoint is a client of `istiod.istio-system.svc:15012`; the policy's controller serves `:9978`.

4. **The controller's own log**, in the second the policy was created: it translated the policy and pushed it, on
   an xDS the waypoint is not a client of.

   ```json
   {"time":"2026-09-19T09:12:08.808930676Z","level":"info","msg":"push debounce stable","component":"krtxds","id":123,"debounced_events":1,"last_change":"10.396417ms","last_push":"10.39625ms","cause":"policy/frontend/lab/tracing:frontend-tracing:lab/agentgateway-waypoint"}
   ```

The effect on a trace, counted: one request sequence through the waypoint exports 10 spans with the policy
"attached" and 14 when the proxy is given the page's tracing settings plus `clientSampling` through its `--config`
argument. The 4 missing
spans are the waypoint's, and the 2 server spans behind it then name a parent span id that no exported span carries.
Removing the lab's own tracing pieces does not change this: with no Istio `Telemetry` object in the cluster, no
`parametersRef` on the Gateway (its `spec.infrastructure` empty) and a new pod, the counts are the same. Still in
place then: istiod's `PILOT_ENABLE_AGENTGATEWAY=true` (Istio's page: "agentgateway support is gated behind the
`PILOT_ENABLE_AGENTGATEWAY` feature flag on istiod, and is disabled by default."), the mesh's OpenTelemetry
extension provider, mesh-wide STRICT mTLS, and an HTTPRoute on the backend Service. Evidence 3 and 4
depend on none of them.

### Where the status comes from (v1.5.0, as read)

Read at tag `v1.5.0` (commit `fe673247`), in `controller/pkg/agentgateway/plugins/`; stated as read, with no claim
about intent. `traffic_plugin.go:226` resolves a policy target through `LookupGatewaysForPolicyTarget`, which for a
target of kind Gateway ends in `reference_indexes.go:406-410`:

```go
case wellknown.GatewayGVK.Kind:
	// Trivial case
	return sets.New(object.NamespacedName)
```

The Gateway resolves to itself; its GatewayClass is not read (neither file contains the string `GatewayClass`).
`resolvePolicyAncestorRefs` (`traffic_plugin.go:371-398`) reports "not attached" only for a target error or an empty
result, and otherwise makes that Gateway the ancestor ref, which `:251` gives the base conditions of `:347-356`:
`Accepted` true and `Attached` true. `:229-234` also emits the translated policy for that Gateway, which is the push
in evidence 4: `:227` clones the policy per target through `ClonePoliciesForTarget` (`:429-441`), whose
`clone.Key += attachmentName(policyTarget)` (`:436`) appends `":" + namespace + "/" + name` for a Gateway target
(`:2098-2109`), and that is the `:lab/agentgateway-waypoint` the push line's `cause` ends in.

### Version caveat

agentgateway's version table gives 1.5.x an Istio range of **1.23 - 1.30**, and this is Istio **1.31.0**. 1.31 is
the release in which the `istio-agentgateway-waypoint` GatewayClass first exists, so no Istio inside the stated range
can show this. Both projects are at their latest release as of 2026-09-19.

### What is not the complaint

That the policy is not delivered is consistent with what Istio documents ("agentgateway’s own native configuration
format and custom resources are likewise not managed by Istio"), and agentgateway's tracing page is written for a
Gateway of class `agentgateway` (its prerequisite creates one) and does not mention Istio. The complaint is the
status alone.

### Suggested direction

Have the controller decline to claim `Attached` for a Gateway whose GatewayClass names another controller: ignore
such targets, or set `Accepted`/`Attached` false with a reason that names the class, so that the status says what
the data plane will do.

### Related

- #1872 (open PR, "fix(controller): dont write pending status for resources we dont own") asks the same ownership
  question in the same file, `traffic_plugin.go`: it adds `string(gc.Spec.ControllerName) != agw.ControllerName` for
  route and ListenerSet targets on the Pending path. Not a duplicate: here the target is a Gateway and the status is
  `Attached=True`. A review comment there reads "Does not emitting an error mean we emit a success? that seems wrong".
- istio/istio#60024 ("Support agentgateway as a waypoint") lists, under "Out of scope for initial support", "Graceful
  handling of policies applied directly to the waypoint (gateway ParentRef)" and "Status or other indication to the
  user than non gateway api defined policies are not being enforced at the agw-based waypoint".

---

## Lab notes (not part of the issue)

Everything this draft held before 2026-09-19, kept as written with its headings one level down, and one
update. The reproduction and the counts in this part are the lab's own history: they use the lab's manifests and
include runs at earlier states of the lab.

Project: agentgateway/agentgateway. The Gateway in question is an agentgateway process, but its configuration is
translated and pushed by istiod, not by agentgateway's control plane: GatewayClass `istio-agentgateway-waypoint`,
Istio 1.31.0 ambient with `PILOT_ENABLE_AGENTGATEWAY=true`.
Version observed: agentgateway control plane `v1.5.0` (`cr.agentgateway.dev/controller:v1.5.0`) alongside the
istiod-driven proxy `cr.agentgateway.dev/agentgateway:v1.5.0`
(`sha256:bf2f339ef326d32def2aaeb44b1b4549801293c19b89e764a4228667d97d9896`), Kubernetes 1.37.0 on kind.

### Summary

A cluster can hold both control planes at once: agentgateway's own controller driving GatewayClass
`agentgateway`, and istiod driving GatewayClass `istio-agentgateway-waypoint`. An `AgentgatewayPolicy` that
targets a Gateway of the second class is accepted by the agentgateway controller and reports itself attached:

```
status.ancestors[0].conditions:
  - type: Accepted, status: "True", reason: Valid,    message: "Policy accepted"
  - type: Attached, status: "True", reason: Attached, message: "Attached to all targets"
  controllerName: agentgateway.dev/agentgateway
```

The proxy never receives it. Its own `/config_dump` holds `"tracing": null` and an empty policy list, and the
behaviour the policy asks for does not happen. A user reading `kubectl get agentgatewaypolicy -o yaml` is told the
policy is in force on that Gateway when it is not.

### Reproduction

With an agentgateway waypoint provisioned by istiod (`gatewayClassName: istio-agentgateway-waypoint`) and an
OTLP collector reachable in the cluster, apply a tracing policy naming that Gateway:

```yaml
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata:
  name: tracing-waypoint
  namespace: <the waypoint's namespace>
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: <the istiod-driven waypoint>
  frontend:
    tracing:
      backendRef:
        name: <collector service>
        namespace: <collector namespace>
        port: 4317
      protocol: GRPC
      randomSampling: "true"
      clientSampling: "true"
```

Then read the status, send traffic through the waypoint, and read the proxy:

```
$ kubectl get agentgatewaypolicy tracing-waypoint -o yaml     # Accepted True, Attached True
$ kubectl port-forward deploy/<waypoint> 15000:15000
$ curl -s localhost:15000/config_dump | jq '.policies | length'
0
$ curl -s localhost:15000/config_dump | grep -o '"tracing": *null'
"tracing": null
```

Measured here over ten clean requests (five per receiver) crossing two such waypoints: zero spans from either
waypoint, on every one of the ten, while the proxies under agentgateway's own control plane and configured by
policies of exactly this shape exported on every request they carried. The egress waypoint is on both receivers'
paths and exported two spans on all ten; the ingress is on one receiver's path only and exported two spans on
each of that receiver's five, and none on the other five, where it is not a hop. The waypoints are demonstrably on the path and demonstrably
processing the trace context: every receiver span behind one names a parent span id that no exported span
carries, so the proxy read the incoming `traceparent`, made a span of its own, and passed its id on without
exporting it.

### Note on what is and is not documented

Istio's page for agentgateway (https://istio.io/latest/docs/ambient/usage/agentgateway/, read 2026-09-09) says
istiod configures agentgateway "only through the Gateway API resources listed above" and that Istio's own
configuration APIs, including the Telemetry API, "are not applied to agentgateway proxies". So an istiod-driven
waypoint having no route to tracing configuration is consistent with what Istio documents; that part is not the
complaint. The complaint is narrower: agentgateway's controller claims a policy is attached to a proxy it does
not program, so the two control planes together produce a status that is not true of the data plane.

### Update, 2026-09-12: the proxy can be configured for tracing, just not through either control plane's policy API

Measured on the same cluster at the same versions (Istio 1.31.0 ambient with `PILOT_ENABLE_AGENTGATEWAY=true`,
agentgateway `v1.5.0`, Kubernetes 1.37.0 on kind). Three configurations were applied to the two istiod-driven
waypoints one at a time, each with its own counted run. What changes the complaint above is the third.

**Istio's own Telemetry API does not reach them, and that is documented.** Istio's mesh configuration was given
the OpenTelemetry extension provider from the project's own task page, and three `Telemetry` resources selected
it at 100% sampling: one mesh-wide in the root namespace, and one per waypoint using `targetRefs` to the Gateway,
which is the form the Telemetry reference requires ("Waypoint proxies are required to use this field for policies
to apply; `selector` policies will be ignored"). istiod accepted all three and pushed
(`Push debounce stable[219] 3 for config Telemetry/istio-system/mesh-tracing and 2 more configs`). Both proxies'
`/config_dump` still read `"tracing": null`, and two counted repetitions per receiver were identical to the runs
before the change: 8 spans over 2 trace ids on the worker path, 62 over 2 on the orchestrator path, **2 dangling
parents per work item** in both. This half is not a defect — Istio's agentgateway page lists `Telemetry` among the
APIs "not applied to agentgateway proxies" — and it is recorded here only to establish the boundary.

**Environment variables do not reach them either.** `OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_EXPORTER_OTLP_PROTOCOL`,
`OTEL_TRACES_EXPORTER` and `OTEL_SERVICE_NAME` were set on both waypoint containers; istiod re-rendered the
Deployments and the pods carried all four. Counts unchanged, `"tracing": null`, 2 dangling parents. Consistent
with the binary's own help text, read inside the running proxy, which lists `-c/--config`, `-f/--file`,
`--validate-only`, `-V`, `--version` and `-h` and no environment option.

**The proxy's own `config.tracing` does reach it, through the argument istiod already passes.** istiod starts each
waypoint with `args: ["--config","{}"]` — the agentgateway configuration document, empty. Filling it with the
`config.tracing` block the project's standalone documentation describes makes the waypoints export:

```json
{"config":{"tracing":{"otlpEndpoint":"http://<collector>:4317","otlpProtocol":"grpc","randomSampling":true,"clientSampling":true}}}
```

`/config_dump` then reads the tracing block instead of `null`, and the counts move for the first time: the worker
path goes 8 → **12** spans with `agentgateway-waypoint=4`, the orchestrator path 62 → **66** with
`agentgateway-waypoint=2` and `agentgateway-waypoint-orch=2`, and **dangling parents go 2 → 0** on every work item
of two repetitions per receiver. Every other hop is unchanged. So the waypoints were always producing spans and
propagating context — the earlier evidence of a parent id no exported span carried was right — and the only thing
missing was somewhere to send them.

**Why this sharpens rather than replaces the complaint.** The proxy is fully capable of exporting traces while
running as an istiod-managed waypoint; nothing about the waypoint role prevents it. What fails is specifically the
policy path: `AgentgatewayPolicy` is the documented way to turn tracing on for a Kubernetes-managed agentgateway
proxy, and against a proxy of GatewayClass `istio-agentgateway-waypoint` it reports itself attached and does
nothing. A user who reads the project's tracing page, applies the policy it prescribes, and sees `Attached: True`
has no way to learn that the proxy will never receive it.

**The reproduction above was re-run on 2026-09-12 and still holds.** It was re-run on a deliberately clean
waypoint state: the working `config.tracing` was lifted first, so both proxies were back to `--config '{}'` with
`"tracing": null` and `policies` of length 0 before the policies were applied. Both policies then reported
`Accepted: True` (reason `Valid`, "Policy accepted") and `Attached: True` (reason `Attached`, "Attached to all
targets"), and both proxies' `/config_dump` still read `"tracing": null` with `policies` of length **0**. A counted
run across both waypoints produced zero waypoint spans and the same two dangling parents per work item. Same
versions as the original: Istio 1.31.0, agentgateway v1.5.0, Kubernetes 1.37.0 on kind.

**One version caveat, stated up front.** agentgateway's own version-support table gives 1.5.x an Istio range of
**1.23 - 1.30**, and this cluster runs Istio **1.31.0** — a minor above the top of that range. Kubernetes 1.37.0
is inside the stated range. Everything above was measured on that combination, and nothing here is attributed to
the version gap: the behaviour is consistent across three separate configurations and eighteen counted work
items, and the `istio-agentgateway-waypoint` GatewayClass this report is about only exists in Istio 1.31. But it
is the first thing worth knowing before the rest is read.

**And the proxy implements the policy perfectly well — it simply never receives this one.** Reading the
`policies` list rather than only its length shows the two configuration surfaces converging on one internal
object. With `config.tracing` set, the istiod-driven waypoint's list holds:

```json
{"key": "frontend/tracing", "name": null,
 "target": {"gateway": {"gatewayName": "agentgateway-waypoint", "gatewayNamespace": "lab"}},
 "policy": {"frontend": {"tracing": {"inlineBackend": "<collector>:4317", "randomSampling": "true",
   "clientSampling": "true", "path": "/v1/traces", "protocol": "grpc",
   "attributes": {}, "resources": {}, "remove": []}}}}
```

and the ingress proxy — same version, configured the documented way by agentgateway's own control plane with an
`AgentgatewayPolicy` — holds the same structure, differing only in provenance and in how the collector is
addressed:

```json
{"key": "frontend/agentgateway-system/tracing:frontend-tracing:agentgateway-system/agentgateway-ingress",
 "name": {"kind": "AgentgatewayPolicy", "name": "tracing", "namespace": "agentgateway-system"},
 "target": {"gateway": {"gatewayName": "agentgateway-ingress", "gatewayNamespace": "agentgateway-system"}},
 "policy": {"frontend": {"tracing": {"service": {"name": "telemetry/<collector>", "port": 4317}, …}}}}
```

Identical `attributes`, `resources`, `remove`, `randomSampling`, `clientSampling`, `path` and `protocol`. So the
two configuration surfaces converge: the proxy compiles `config.tracing` into the same `frontend.tracing`
structure an `AgentgatewayPolicy` produces on an ingress, and it exports traces from that structure while running
as an istiod-managed waypoint. What that does **not** establish is how the proxy would treat a policy actually
delivered to a waypoint, because none ever was — no policy reached the data plane in any of these runs. The
measured gap is delivery: agentgateway's controller does not program GatewayClass `istio-agentgateway-waypoint`,
istiod does not translate this CRD, and the policy's status asserts `Attached: True` across that gap.

One caveat on the working route, stated plainly: it is not a documented one. agentgateway documents the
`config.tracing` fields, Istio documents the `parametersRef` Deployment overlay used to deliver them, and neither
project documents the combination — Istio's page says "agentgateway's own native configuration format and custom
resources are likewise not managed by Istio". It is reported here as what a user can measure, not as a supported
configuration.

### Update, 2026-09-19: re-checked against agentgateway's tracing page, twice; the draft made fileable

**Why.** The author pointed at agentgateway's Kubernetes tracing page
(https://agentgateway.dev/docs/kubernetes/latest/documentation/observability/traces/configs/otel/) — "there is no
way this will not work for tracing … review your work again against it and let's confirm it is working, otherwise
we need to report a bug" — and then asked whether the lab's own route for these waypoints (the `parametersRef`
overlay, the three Istio `Telemetry` objects) could be what conflicts with it.

**What was run.** The page's manifest, field for field with four names changed, against
`lab/agentgateway-waypoint`, in two repetitions of one sequence: the overlay lifted; the policy applied; then, for
the author's question, the policy and all three `Telemetry` objects deleted, a new pod, and the policy re-created;
then the lab restored and read back. Repetition 1 by hand by the controller (08:46Z–08:52Z), repetition 2 by
`reproduce.sh` (09:12:04Z–09:15:44Z). Records, the script and the sources are in
`experiments/runs/2026-09-19-waypoint-policy-recheck/`; the counts are in `findings.md` under "the documented
AgentgatewayPolicy tracing on an istiod-managed agentgateway waypoint".

**What it found, both times.** `Accepted=True`, `Attached=True`; the waypoint's dump `policies` 0 and
`config.tracing` null, the same bytes as before the policy; 10 spans with the waypoint hop without a span and 2
dangling parents; the ingress, class `agentgateway`, holding its tracing policy in the same second; the
controller's push line naming the policy. With nothing of the lab's around the waypoint: the same, to the span. So
the lab's overlay and `Telemetry` objects are not the cause, and the reproduction of 2026-09-12 above holds on the
page's own manifest as it did on the lab's. After each restore: 14 and 69 spans, no hop without a span.

**What the page covers.** Its prerequisite, "Set up an agentgateway proxy", creates the Gateway it targets with
`gatewayClassName: agentgateway`; its body names Istio, a waypoint or a GatewayClass 0 times. It is not wrong about
the proxies it is written for: the lab's ingress and egress are configured exactly this way and export on every
request. It is silent on a Gateway of the other class, and the status is what fills that silence with a wrong answer.

**What changed in this draft.** The issue text above is new and is built on the page's manifest, where the
reproduction below used the lab's (with `clientSampling`). Two pieces of evidence were added to the ones this draft
already had: the waypoint's xDS address against the ingress's (`istiod.istio-system.svc:15012` against
`agentgateway.agentgateway-system.svc.cluster.local:9978`), and the controller's push line. Repetition 2 added the
dump after traffic and the proxy's own request counter. After the review of the same day the controller's source at
tag v1.5.0 was read for where the status comes from (`sources.md` §9), and the issue text states it as read; the
issue text's "Related" items come from that review too (`sources.md` §6 says what the first round of searches
missed).

**One reading of 2026-09-12 that the newer records qualify.** The ingress policy quoted below is keyed
`frontend/agentgateway-system/tracing:…`; since 2026-09-15 the ingress lives in its own namespace and the key reads
`frontend/agentgateway-ingress/tracing:…`. The structure compared there is unchanged.

**Upstream, searched 2026-09-19** (`sources.md` §6 in the run directory): no issue or pull request was found that
reports this status on a Gateway target, in agentgateway/agentgateway (11 queries) or istio/istio (4). Two related
items exist and the issue text names both. agentgateway/agentgateway#1872, an open pull request since 2026-05-19
("fix(controller): dont write pending status for resources we dont own", one file, `traffic_plugin.go`), adds the
ownership test `string(gc.Spec.ControllerName) != agw.ControllerName` for route and ListenerSet targets, on the path
where no Gateway resolves and the status would read Pending; the lab's case is the other branch, a Gateway target
that resolves and reads `Attached=True`. A collaborator's review comment on it is the lab's complaint in one sentence:
"Does not emitting an error mean we emit a success? that seems wrong". istio/istio#60024, "Support agentgateway as a
waypoint" (open), lists under "Out of scope for initial support" both "Graceful handling of policies applied directly
to the waypoint (gateway ParentRef)" and "Status or other indication to the user than non gateway api defined
policies are not being enforced at the agw-based waypoint": Istio names this gap itself, which bears on the second
direction at the end of these notes. agentgateway v1.5.0 and Istio 1.31.0 are still the latest releases;
v1.6.0-alpha.1's notes do not name this.

### Suggested direction

Have the controller decline to claim `Attached` for a Gateway whose class it does not control — either by
ignoring such targets, or by setting `Accepted` false with a reason that names the class, so the status says what
the data plane will do.

A second direction, for the Istio side rather than this one, follows from the 2026-09-12 update and is noted here
only so the two halves are not addressed separately: the waypoint's tracing configuration already has a working
input — the `--config` document istiod composes and currently leaves as `{}`. istiod knows the mesh's configured
OpenTelemetry extension provider and which `Telemetry` resources target the Gateway. Rendering those into the
`config.tracing` block it already writes would make the Telemetry API reach an agentgateway waypoint without
either project changing its configuration surface, and without Istio having to manage agentgateway's custom
resources — which is the boundary its documentation draws.

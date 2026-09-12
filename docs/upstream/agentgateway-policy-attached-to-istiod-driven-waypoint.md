# Draft issue — agentgateway: an AgentgatewayPolicy reports Attached to a waypoint its controller does not program

Status: **draft, not filed.** Text for a human to review and file. No link until it is filed.

Project: agentgateway/agentgateway. The Gateway in question is an agentgateway process, but its configuration is
translated and pushed by istiod, not by agentgateway's control plane: GatewayClass `istio-agentgateway-waypoint`,
Istio 1.31.0 ambient with `PILOT_ENABLE_AGENTGATEWAY=true`.
Version observed: agentgateway control plane `v1.5.0` (`cr.agentgateway.dev/controller:v1.5.0`) alongside the
istiod-driven proxy `cr.agentgateway.dev/agentgateway:v1.5.0`
(`sha256:bf2f339ef326d32def2aaeb44b1b4549801293c19b89e764a4228667d97d9896`), Kubernetes 1.37.0 on kind.

## Summary

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

## Reproduction

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

## Note on what is and is not documented

Istio's page for agentgateway (https://istio.io/latest/docs/ambient/usage/agentgateway/, read 2026-09-09) says
istiod configures agentgateway "only through the Gateway API resources listed above" and that Istio's own
configuration APIs, including the Telemetry API, "are not applied to agentgateway proxies". So an istiod-driven
waypoint having no route to tracing configuration is consistent with what Istio documents; that part is not the
complaint. The complaint is narrower: agentgateway's controller claims a policy is attached to a proxy it does
not program, so the two control planes together produce a status that is not true of the data plane.

## Update, 2026-09-12: the proxy can be configured for tracing, just not through either control plane's policy API

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

## Suggested direction

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

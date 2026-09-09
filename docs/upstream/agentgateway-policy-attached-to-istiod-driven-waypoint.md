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

## Suggested direction

Have the controller decline to claim `Attached` for a Gateway whose class it does not control — either by
ignoring such targets, or by setting `Accepted` false with a reason that names the class, so the status says what
the data plane will do.

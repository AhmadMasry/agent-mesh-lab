# Draft issue — Istio ambient: a waypoint shared by two Services sends both Services' traffic to one backend

Status: **draft, not filed.** Text for a human to review and file. No link until it is filed.

Project: istio/istio. The waypoint is an agentgateway process, but the route configuration it serves is
translated and pushed by istiod: `istioctl x internal-debug syncz` reports this proxy as
`"proxy_type": "agentgateway"` receiving `type.googleapis.com/agentgateway.dev.resource.Resource` from istiod,
and `istioctl x internal-debug "config_dump?proxyID=<pod>.<ns>"` returns only empty Envoy sections for it, so the
agentgateway resource body could not be read with the tooling to hand. On that evidence the unscoped route is
emitted by istiod's Gateway-API-to-agentgateway translation rather than by agentgateway itself, and Istio owns
the integration in either case. This draft does not claim which line of the translation is at fault.

Version observed: Istio `1.31.0`; GatewayClass `istio-agentgateway-waypoint`, controller
`istio.io/agentgateway-waypoint-controller`; waypoint image `cr.agentgateway.dev/agentgateway:v1.5.0`
(`sha256:bf2f339ef326d32def2aaeb44b1b4549801293c19b89e764a4228667d97d9896`); Kubernetes `1.37.0` on kind.

## Summary

Two Services in one namespace bound to the same waypoint with `istio.io/use-waypoint` do not keep separate
routing. When one Service has an `HTTPRoute` attached to it as a `parentRef`, that route is applied to traffic
addressed to the other Service as well, and requests for the second Service are answered by the first
Service's backend. Adding a second `HTTPRoute` for the second Service does not scope the routes; it inverts the
result, and both Services are then answered by the second Service's backend. Under this configuration a
waypoint appears to serve one route table for every Service bound to it, rather than one per parent Service.

## Setup

Namespace `lab`, labelled `istio.io/dataplane-mode=ambient`. One waypoint:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: agentgateway-waypoint
  namespace: lab
  labels:
    istio.io/waypoint-for: service
spec:
  gatewayClassName: istio-agentgateway-waypoint
  listeners:
    - name: mesh
      port: 15008
      protocol: HBONE
```

Two Deployments with distinct HTTP backends, `worker` and `orchestrator`, each behind a Service of the same
name on port 8080. In the run quoted below they are two A2A agents, each serving a body that names itself at
`/.well-known/agent-card.json`, which is what the Reproduction's outputs show.

Any two distinguishable HTTP servers reproduce this. A minimal stand-in, if you would rather not run two
agents, is `hashicorp/http-echo`, which answers every path with a fixed string; with it, request `/` instead of
the agent-card path and expect the `-text` value where the Reproduction quotes a card body:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata: {name: worker, namespace: lab}
spec:
  replicas: 1
  selector: {matchLabels: {app: worker}}
  template:
    metadata: {labels: {app: worker}}
    spec:
      containers:
        - name: echo
          image: hashicorp/http-echo:1.0.0
          args: ["-listen=:8080", "-text=I am worker"]
          ports: [{name: http, containerPort: 8080}]
---
apiVersion: v1
kind: Service
metadata: {name: worker, namespace: lab}
spec:
  selector: {app: worker}
  ports: [{name: http, port: 8080, targetPort: http}]
```

and the same pair again with `orchestrator` substituted for `worker` in the four names and in the `-text` value.
A pod to issue the requests from, in the same namespace:

```
kubectl -n lab run curlpod --image=curlimages/curl:8.11.1 --restart=Never --command -- sleep 900
kubectl -n lab wait --for=condition=Ready pod/curlpod --timeout=60s
```

One route, attached to the `worker` Service:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: worker
  namespace: lab
spec:
  parentRefs:
    - group: ""
      kind: Service
      name: worker
      port: 8080
  rules:
    - backendRefs:
        - name: worker
          port: 8080
```

## Reproduction

1. Bind only `Service/worker` to the waypoint:

   ```
   kubectl -n lab label svc worker istio.io/use-waypoint=agentgateway-waypoint
   ```

   From a pod in the same namespace, each Service answers with its own backend. This is the expected state.

   ```
   $ kubectl -n lab exec curlpod -- curl -s http://orchestrator.lab.svc.cluster.local:8080/.well-known/agent-card.json
   {"name":"orchestrator", ...
   $ kubectl -n lab exec curlpod -- curl -s http://worker.lab.svc.cluster.local:8080/.well-known/agent-card.json
   {"supportedInterfaces":[{"url":"http://worker.lab.svc.cluster.local:8080" ... "name":"worker"
   ```

2. Bind `Service/orchestrator` to the same waypoint, changing nothing else:

   ```
   kubectl -n lab label svc orchestrator istio.io/use-waypoint=agentgateway-waypoint
   ```

   `istioctl ztunnel-config service --service-namespace lab` now shows both Services bound:

   ```
   lab       orchestrator          10.96.90.27           agentgateway-waypoint 1/1
   lab       worker                10.96.30.166          agentgateway-waypoint 1/1
   ```

   Both Services now answer with the `worker` backend:

   ```
   $ kubectl -n lab exec curlpod -- curl -s http://orchestrator.lab.svc.cluster.local:8080/.well-known/agent-card.json
   {"supportedInterfaces":[{"url":"http://worker.lab.svc.cluster.local:8080" ... "name":"worker"
   $ kubectl -n lab exec curlpod -- curl -s http://worker.lab.svc.cluster.local:8080/.well-known/agent-card.json
   {"supportedInterfaces":[{"url":"http://worker.lab.svc.cluster.local:8080" ... "name":"worker"
   ```

   Removing the label again restores step 1's result, so the label is the only variable.

3. Add a matching route for the second Service, mirroring the first:

   ```yaml
   apiVersion: gateway.networking.k8s.io/v1
   kind: HTTPRoute
   metadata:
     name: orchestrator
     namespace: lab
   spec:
     parentRefs:
       - group: ""
         kind: Service
         name: orchestrator
         port: 8080
     rules:
       - backendRefs:
           - name: orchestrator
             port: 8080
   ```

   Both Services now answer with the `orchestrator` backend:

   ```
   $ kubectl -n lab exec curlpod -- curl -s http://orchestrator.lab.svc.cluster.local:8080/.well-known/agent-card.json
   {"name":"orchestrator", ...
   $ kubectl -n lab exec curlpod -- curl -s http://worker.lab.svc.cluster.local:8080/.well-known/agent-card.json
   {"name":"orchestrator", ...
   ```

## Expected

Traffic addressed to `orchestrator.lab.svc.cluster.local:8080` reaches the `orchestrator` backend, and traffic
addressed to `worker.lab.svc.cluster.local:8080` reaches the `worker` backend, whether the two Services share a
waypoint or not. A route whose only `parentRef` is one Service is expected to apply to that Service's traffic.

## Observed

Both Services reach one backend, and which backend that is depends on which Service-attached `HTTPRoute` exists.

## Route status

Both routes report `Accepted=True` / `ResolvedRefs=True` from
`istio.io/agentgateway-waypoint-controller`, so the misrouting is not reported through route status:

```
$ kubectl -n lab get httproute worker -o jsonpath='{.status}'
{"parents":[{"conditions":[{... "reason":"Accepted","status":"True","type":"Accepted"},
{... "reason":"ResolvedRefs","status":"True","type":"ResolvedRefs"}],
"controllerName":"istio.io/agentgateway-waypoint-controller",
"parentRef":{"group":"","kind":"Service","name":"worker","port":8080}}]}
```

## Notes

- Both Services are in the same namespace as the waypoint and use the same port number and the same port name.
- The waypoint container has no shell, so its rendered route table was not read; the evidence here is
  black-box, from the responses and from the label toggle.
- Not tested: whether the same happens with GatewayClass `istio-waypoint`, or with two Services on different
  port numbers.

## Workaround in use

Giving each Service its own waypoint Gateway, so no waypoint is shared, restores per-Service routing: each
Service then answers with its own backend, and the first Service's route stays on the first Service's waypoint.
That is what the lab does, at the cost of one waypoint instance per receiver.

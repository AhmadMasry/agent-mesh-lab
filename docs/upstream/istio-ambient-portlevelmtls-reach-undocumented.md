# Draft issue — Istio docs: whether ztunnel honours `portLevelMtls` is not stated anywhere in the ambient documentation

Status: **draft, not filed.** Text for a human to review and file. No link until it is filed.

Project: istio/istio (documentation). Version observed: Istio **1.31.0** ambient with
`PILOT_ENABLE_AGENTGATEWAY=true`, Kubernetes 1.37.0 on kind, ztunnel from the same release.
Pages read 2026-09-12:
- https://istio.io/latest/docs/reference/config/security/peer_authentication/
- https://istio.io/latest/docs/ambient/usage/l4-policy/

## Summary

This is a documentation gap, not a defect: ztunnel behaves correctly. The problem is that a reader
cannot find out that it does.

`PeerAuthentication.spec.portLevelMtls` is documented on the API reference, which states its
semantics and its one precondition:

> Port specific mutual TLS settings. These only apply when a workload selector is specified. The
> port refers to the port of the workload, not the port of the Kubernetes service.

The ambient Layer 4 page is the page a reader goes to for what ztunnel enforces. It states that
peer authentication is supported:

> Istio's peer authentication policies, which configure mutual TLS (mTLS) modes, are supported by
> ztunnel.

and it is explicit about the one mode ambient cannot use:

> As ztunnel and HBONE implies the use of mTLS, it is not possible to use the `DISABLE` mode in a
> policy. Such policies will be ignored.

The API reference's own ambient paragraph restricts the same single mode ("Because of this,
`DISABLE` mode is not supported") and says nothing about port-level settings.

**Neither page mentions `portLevelMtls`, a port-level mode, or per-port exceptions at all.** So a
reader who needs one inbound port to stay reachable from outside the mesh — the common case being a
Prometheus that is not itself mesh-enrolled scraping a mesh workload — cannot tell from the
documentation whether the field will be honoured by ztunnel, silently ignored the way `DISABLE` is,
or rejected. The one explicit statement that touches mode variety in ambient is on a page that no
longer exists: the alpha-era `/v1.21/docs/ops/ambient/usage/ztunnel/` said "the `PeerAuthentication`
resource is not supported by all components (i.e. waypoint proxies) in Istio ambient mode. Hence it
is recommended to only use the `STRICT` mTLS mode currently." That page 404s under `/latest/`, and
nothing replaced that sentence, so the reader is left with a retired caution and no current answer.

## Reproduction

A cluster with an ambient-enrolled namespace, a mesh-wide STRICT `PeerAuthentication` in the root
namespace, and a scraper in a namespace that is **not** enrolled.

1. Apply mesh-wide STRICT:

```yaml
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata: { name: default, namespace: istio-system }
spec: { mtls: { mode: STRICT } }
```

2. Observe the unenrolled scraper's target go down within one scrape interval. ztunnel names the
   converted policy on every refusal:

```
error access connection complete src.workload="prometheus-..." src.namespace="telemetry"
  dst.addr=10.244.1.48:15020 dst.workload="agentgateway-ingress-..."
  dst.namespace="agentgateway-system" direction="inbound" bytes_sent=0 bytes_recv=0 duration="0ms"
  error="connection closed due to policy rejection: explicitly denied by:
         istio-system/istio_converted_static_strict"
```

Measured: the target went down inside 15 s and ztunnel logged **eight** such refusals, one per 15 s
scrape, spanning 105 s from 15:53:03Z to 15:54:48Z; Prometheus fell from 9/9 to 8/9 targets with
`Get "http://10.244.1.48:15020/metrics": read tcp ...: read: connection reset by peer`.

3. Add a port-level exception for the scrape port only:

```yaml
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata: { name: agentgateway-ingress-metrics, namespace: agentgateway-system }
spec:
  selector:
    matchLabels: { gateway.networking.k8s.io/gateway-name: agentgateway-ingress }
  mtls: { mode: STRICT }
  portLevelMtls:
    15020: { mode: PERMISSIVE }
```

4. Observe the target return and stay up. Measured: 9/9 targets across two readings three minutes
   apart, **zero** ztunnel refusals on that port over the same period, while the mesh-wide STRICT
   policy stayed in force and continued to refuse plaintext elsewhere — a probe pod in the
   unenrolled namespace still got `Recv failure: Connection reset by peer` on the application ports
   of two other workloads in the same window.

So at 1.31.0 **ztunnel does honour `portLevelMtls`**, including the workload-port semantics the API
reference gives (15020 is the container port, and there is no Service port of that number involved).

## What the documentation needs

One sentence on https://istio.io/latest/docs/ambient/usage/l4-policy/, in the "Peer authentication"
section beside the existing `DISABLE` sentence, saying whether ztunnel honours `portLevelMtls`. If it
does, as measured here, something like: "Port-level mTLS settings (`portLevelMtls`) are honoured by
ztunnel; as in sidecar mode they require a workload selector, and the port is the workload's port."

A worked example would help more than the sentence alone, because the case that drives users here is
concrete and common: a metrics or health port that must stay reachable from a scraper outside the
mesh while the rest of the workload is STRICT.

If instead the intent is that `portLevelMtls` should *not* be relied on under ztunnel, that needs
saying just as plainly, since the field is accepted, reported without warning in the object's status,
and — at this version — takes effect.

## Notes

- Not a behaviour complaint: the measured behaviour is the useful one and matches the API reference's
  semantics. The request is that the ambient documentation state it.
- The retired 1.21 sentence quoted above is recorded for context only; it concerns waypoint proxies
  rather than ztunnel and is two years of releases old. It is not being relied on as a claim about
  current behaviour.
- Measurements and full outputs come from an experiment lab; the numbers above are from one
  cluster, one run each side of the change, with the ledgers and the raw Prometheus series retained.

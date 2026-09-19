# Sources read for the 2026-09-19 re-check

Everything here was fetched on 2026-09-19 in the session that ran repetition 2, each page with one
`curl -sS --retry 0 --max-time 30`. The HTML is not committed; each page's byte count and sha256 are, with the
lines quoted. Stamps are `date -u`. The controller fetched the first page at 08:45:39Z, before repetition 1; its
copy and this session's are the same bytes.

Two rounds. §1–§7 were read before the commit, 08:57Z–09:01Z. After the review of 2026-09-19 (09:45Z), §6 was
corrected and extended and §8–§9 added, from reads of 09:46:53Z–09:48:45Z; what the first round got wrong is said
where it was wrong, not removed silently. After the delta check, two reads of 10:03Z were added to §8 (helm's values
for istiod, and the istiod chart) and one passage to §9.

## 1. agentgateway's Kubernetes tracing page — the page the re-check is read against

- URL: https://agentgateway.dev/docs/kubernetes/latest/documentation/observability/traces/configs/otel/
- Fetched 2026-09-19T08:57:12Z, HTTP 200, 455 555 bytes,
  sha256 `4c43d051148d4277392f2ecb926d9a635360cfe14fea1ebcbe505fde2c399803`.
- Breadcrumb: "Docs / Agentgateway on Kubernetes / **Version 1.5.x** / Documentation / Observability / Traces /
  Alternative backends". Title: "OTel Collector".
- "## Before you begin — 1. Set up an [agentgateway proxy](/docs/kubernetes/latest/documentation/setup/gateway/).
  2. Install the httpbin sample app."
- "## Configure tracing — Create an AgentgatewayPolicy that points the agentgateway proxy at the collector."
  The manifest, whole:

  ```yaml
  apiVersion: agentgateway.dev/v1alpha1
  kind: AgentgatewayPolicy
  metadata:
    name: tracing
    namespace: agentgateway-system
  spec:
    targetRefs:
      - kind: Gateway
        name: agentgateway-proxy
        group: gateway.networking.k8s.io
    frontend:
      tracing:
        backendRef:
          name: opentelemetry-collector
          namespace: tracing
          port: 4317
        protocol: GRPC
        randomSampling: "true"
  ```

- `2-doc-policy/policy.yaml`, applied in both repetitions, is this manifest field for field, in the page's field
  order. Four names differ and nothing else: `metadata.namespace` `agentgateway-system` -> `lab`; the target Gateway
  `agentgateway-proxy` -> `agentgateway-waypoint`; the collector Service `opentelemetry-collector` ->
  `otel-collector`; its namespace `tracing` -> `telemetry`. The page sets no `clientSampling`, so neither does the file
  (the lab's standing policies for the ingress and the egress set it as well; this one does not).
- What the page does not say: the text of the page's body names Istio, a waypoint, or a GatewayClass **0 times**
  (counted in the page's own "Page as Markdown" source, 3 151 characters). Which class the page means is on the
  prerequisite page, next.

## 2. The prerequisite page: which Gateway the tracing page targets

- URL: https://agentgateway.dev/docs/kubernetes/latest/documentation/setup/gateway/
- Fetched 2026-09-19T08:58:40Z, HTTP 200, 460 551 bytes,
  sha256 `818bd955a3aa106bd6973b63f0f0a317e64f48ef46396e0fc685ea6a9f3308b6`. "Version 1.5.x".
- "1. Create a Gateway that uses the `agentgateway` GatewayClass." The Gateway it creates is
  `name: agentgateway-proxy`, `namespace: agentgateway-system`, `gatewayClassName: agentgateway` — the Gateway the
  tracing page's `targetRefs` names.
- So the tracing page covers a proxy of class `agentgateway`. That is read from this page; the tracing page alone
  does not say it.

## 3. Istio's agentgateway page

- URL: https://istio.io/latest/docs/ambient/usage/agentgateway/
- Fetched 2026-09-19T08:59:07Z, HTTP 200, 122 275 bytes,
  sha256 `ad47855374ef6632dca35df8f5d898144a02c7f23a12e69c4f2978af08c90491`.
- "Istio supports the following Gateway API resources for agentgateway: Gateway (using the `istio-agentgateway` or
  `istio-agentgateway-waypoint` class) … Istio configures agentgateway only through the Gateway API resources listed
  above."
- "Istio’s own configuration APIs — such as VirtualService, DestinationRule, Sidecar, AuthorizationPolicy,
  PeerAuthentication, RequestAuthentication, Telemetry, WasmPlugin, and EnvoyFilter — are not applied to agentgateway
  proxies."
- "agentgateway’s own native configuration format and custom resources are likewise not managed by Istio; Istio
  programs the proxy solely through the Gateway API resources described in this guide."
- Both sentences are quoted with the page's own typographic apostrophe (U+2019) and dashes (U+2014). The page names
  `agentgatewayImage` 0 times: the `gateway.istio.io/agentgatewayImage` annotation on the lab's waypoint Gateways is
  sourced from Istio's code at tag 1.31.0 (`pkg/kube/inject/inject.go` and the waypoint template; `versions.yaml`,
  key `agentgateway`), not from this page.
- The three sentences read as they did on 2026-09-12 (`versions.yaml`, `istio-agentgateway-config-scope`).

## 4. agentgateway's version-support table

- URL: https://agentgateway.dev/docs/kubernetes/latest/release-notes/versions/
- Fetched 2026-09-19T08:59:36Z, HTTP 200, 447 635 bytes,
  sha256 `db2c380a0e5318dd56cd81d09d3c02c99a98ccdd7948d55162c6a38563dfee42`.
- First row: "| 1.5.x | 27 Aug 2026 | 1.32 - 1.37 | 1.4 - 1.6 | 2026-07-28 | >= 3.12 | 1.23 - 1.30 |" under the header
  "| agentgateway | Release date | Kubernetes | Gateway API`*` | MCP spec`†` | Helm | Istio`‡` |". The three marks are
  the page's footnotes; `‡` reads "Istio versions: Istio must run on a compatible version of Kubernetes. For example,
  Istio 1.29 is tested, but not supported, on Kubernetes 1.30." and changes nothing about the range.
- This cluster's Istio is 1.31.0, one minor above that range. Istio's 1.31 announcement is where the
  `istio-agentgateway-waypoint` GatewayClass first appears (`versions.yaml`, `istio`), so no Istio version inside
  agentgateway's stated range has the class this re-check is about.
- `versions.yaml` lists `…/agw-docs/versions/n-patch.md` beside the v1.5.0 pin; fetched 08:59:08Z, it is a
  patch-number shortcode (338 bytes) and holds no table. The table is on the page above.

## 5. The cluster's own statement of who controls which class

Read from the cluster by `reproduce.sh` at preflight (`rep-2/0-before/state.txt`), not from a page:
GatewayClass `agentgateway` has `spec.controllerName: agentgateway.dev/agentgateway`; GatewayClass
`istio-agentgateway-waypoint` has `spec.controllerName: istio.io/agentgateway-waypoint-controller`.

## 6. Upstream searches (gh, 2026-09-19T08:59:50Z–09:00:29Z, one more query 09:46:53Z), issues and pull requests, every state

agentgateway/agentgateway:

| query | hits |
|---|---|
| `istio-agentgateway-waypoint` | 15 listed, none about a policy's status or delivery: #3369 (log timestamps), #2716, #993, #1807, #1740, #1746, #994, #1567, #1457, #1391, #1260, #276, #1353, #859, #831 (HBONE, tunnel protocol, ingress-use-waypoint, route attachment, noisy waypoint logs) |
| `AgentgatewayPolicy Attached waypoint` | 0 |
| `istiod waypoint policy` | 0 |
| `Attached status GatewayClass` | 0 |
| `waypoint tracing` | 0 |
| `AgentgatewayPolicy istiod` | 0 |
| `AgentgatewayPolicy Attached` | 1: #3525, open, about reusing AgentgatewayBackends; unrelated |
| `policy status Attached not programmed` | 0 |
| `istio waypoint AgentgatewayPolicy` | 0 |
| `controllerName GatewayClass policy` | 0 |
| `AgentgatewayPolicy status` (added 09:46:53Z, after the review: none of the ten above surfaces #1872) | 3: #3325 (open PR, federated trust domains; unrelated), **#1872** (below), #1632 (merged PR, "controller: retain last transition time"; unrelated) |

istio/istio:

| query | hits |
|---|---|
| `agentgateway waypoint tracing` | 0 |
| `agentgateway Telemetry` | 0 |
| `AgentgatewayPolicy` | 0 |
| `istio-agentgateway-waypoint` | 12 listed: #61327, #61326, #61511, #61325, **#60024** (below), #61014, #60782, #56658, #61328, #61037, #61649, #61036. Eleven are about canary waypoints' route config, ambient index bindings and multicluster; #60024 bears on the subject |

**Related, not duplicates** (read 2026-09-19T09:46:53Z–09:47:28Z):

- **agentgateway/agentgateway#1872**, an OPEN pull request, "fix(controller): dont write pending status for resources
  we dont own" (created 2026-05-19T17:37:10Z, updated 2026-09-10T00:15:45Z, base `main`, +85 −1, one file:
  `controller/pkg/agentgateway/plugins/traffic_plugin.go`; body, whole: "don't write pending if there actually is a
  gateway"). Its diff adds `hasForeignParentGateway`, whose ownership test is
  `if string(gc.Spec.ControllerName) != agw.ControllerName {`, and uses it in `TranslateAgentgatewayPolicy` as
  `foreignOwned := targetExists && len(gatewayTargets) == 0 && hasForeignParentGateway(ctx, agw, targetObject)`. The
  target kinds its helper resolves are HTTPRoute, GRPCRoute, TCPRoute, TLSRoute and ListenerSet, and it acts only when
  no Gateway was resolved, that is on the Pending path. The lab's case is the other one: a target of kind Gateway,
  resolved, reported `Attached=True`. Same ownership question, same function, different branch. A collaborator's
  review comment on it (2026-05-19T17:51:07Z, `traffic_plugin.go:187`), whole: "Does not emitting an error mean we
  emit a success? that seems wrong". The last review comment (2026-09-10T00:15:44Z) asks whether it is still needed.
- **istio/istio#60024**, "Support agentgateway as a waypoint" (OPEN, created 2026-04-28T16:09:13Z, updated
  2026-06-24T16:55:05Z; body 2 004 bytes, sha256 `fec9203e9d1083e261e0228567ad7d3e5ed6496d9d11f4778d93012fc878373e`).
  Under "**Out of scope for initial support:**" its body lists, among five bullets:
  "Graceful handling of policies applied directly to the waypoint (gateway ParentRef)" and
  "Status or other indication to the user than non gateway api defined policies are not being enforced at the
  agw-based waypoint". Istio names this report's gap itself, as known and out of scope.
- **A misreading of the first round, corrected.** The first round searched that body for "telemetry", found
  "[ ] Extensions and Telemetry", and recorded it as an unticked work item. It is not one: it is a line of the Istio
  issue template's list "**Affected product area (please put an X in all that apply)**", in which the filer ticked
  "[x] Ambient" only. It bears on nothing, and the two bullets above, four lines higher in the same body, were missed.
- No issue or pull request was found that reports THIS status, `Attached=True` on a target of kind Gateway whose class
  belongs to another controller, in either repository (15 queries). The two items above are its neighbours.

## 7. Releases (gh, 2026-09-19T09:00:29Z)

- agentgateway: `v1.5.0` is the latest release (published 2026-08-27T18:01:08Z). `v1.6.0-alpha.1` is a prerelease
  (2026-09-14T22:03:44Z); its notes name Istio once ("helm: allow disabling istio permissions", #3218) and do not
  name waypoints, `Attached`, policy status or GatewayClass.
- Istio: `1.31.0` is the latest release (2026-08-31T15:47:13Z).
- Both are what this cluster runs, so the re-check is at each project's latest release.

## 8. What stayed in place through variant 3 (cluster reads, 2026-09-19T09:48:26Z; reads only)

Variant 3 removed the lab's own tracing pieces around `lab/agentgateway-waypoint`: the `parametersRef`, the three
`Telemetry` objects, the pod. The pieces below were not removed, and no step of either repetition touches them
(`reproduce.sh` names every object it changes). All are the lab's own settings but one, `PILOT_TRACE_SAMPLING`, which
is the chart's default and is marked so:

- istiod's environment, read from the Deployment: `PILOT_ENABLE_AGENTGATEWAY=true` and `PILOT_TRACE_SAMPLING=1`.
  - `PILOT_ENABLE_AGENTGATEWAY` is the lab's setting. `helm get values istiod -n istio-system` (read 10:03:09Z;
    release `istiod-1.31.0`, revision 1, deployed) holds three top-level keys, `meshConfig`, `pilot` and
    `profile: ambient`, and under `pilot.env` exactly two entries: `DEFAULT_WORKLOAD_CERT_TTL: 168h` and
    `PILOT_ENABLE_AGENTGATEWAY: "true"`. The class depends on it. Istio's agentgateway page, in the copy recorded by
    hash in §3, under "Install Istio with agentgateway enabled": "agentgateway support is gated behind the `PILOT_ENABLE_AGENTGATEWAY` feature flag on istiod, and is disabled by default."
  - `PILOT_TRACE_SAMPLING=1` is NOT lab-specific: it is the istiod chart's default. It is not among the user-supplied
    values above and is set nowhere under `deploy/` or in the Makefile (searched for `PILOT_TRACE_SAMPLING` and
    `traceSampling`: 0 lines). `helm get values … --all` holds `traceSampling: 1`, and the release's manifest renders
    `PILOT_TRACE_SAMPLING` `"1"`. The chart itself, pulled at 10:03:31Z from the Makefile's repository
    (https://blob.istio.io/istio-release/charts, `istiod` 1.31.0): `values.yaml:18` reads `traceSampling: 1.0`;
    `templates/deployment.yaml:199-200` renders the variable from `.Values.traceSampling`; `files/profile-ambient.yaml`
    does not set it (of the profile files only `profile-demo.yaml` does, and the lab does not use that profile).
- The mesh configuration (`istio-system/istio`, key `mesh`): `enableTracing: true` and `extensionProviders:` one entry,
  `name: otel-tracing`, `opentelemetry` {`port: 4317`, `resource_detectors.environment`, `service:
  otel-collector.telemetry.svc.cluster.local`}. Committed form: `deploy/step-2-ambient-agw/istio-values.yaml`. The
  three `Telemetry` objects only selected this provider.
- `PeerAuthentication`: `istio-system/default`, mode STRICT, no selector (mesh-wide); and
  `agentgateway-ingress/agentgateway-ingress-metrics`, STRICT with port 15020 PERMISSIVE, selecting the ingress's pods.
- `HTTPRoute lab/worker`: parentRef kind Service, name `worker`; its status is written by
  `istio.io/agentgateway-waypoint-controller`. (`worker-ingress` and `orchestrator-ingress` attach to the ingress
  Gateway; their status is written by `agentgateway.dev/agentgateway`.) `ServiceEntry lab/model-external`, hosts
  `model.lab.internal`.
- On the Gateway object: the `gateway.istio.io/agentgatewayImage` annotation and kubectl's
  `last-applied-configuration` (`rep-2/3-doc-policy-nothing-custom/steps.txt` lines 11–13).
- On the waypoint Deployment's pod template: `kubectl.kubernetes.io/restartedAt: 2026-09-19T12:13:11+03:00`, written by
  step 3's own `rollout restart` in repetition 2 (09:13:11Z). `agentgateway-waypoint-orch` carries no such annotation.
  The restore does not remove it and the readback's compared state does not include it; it was left in place.

## 9. Where the status comes from: agentgateway's controller at tag v1.5.0, as read

Tag `v1.5.0` is commit `fe6732474a96a0363dfb9822859af4e9bab360fa` (gh api, 09:47:43Z), the `git_revision` the running
proxies report in their own `/config_dump` (`agentgateway_version` in every `*.extract.json`). Two files, one
`curl -sS --retry 0` each, 2026-09-19T09:47:43Z, HTTP 200:

- https://raw.githubusercontent.com/agentgateway/agentgateway/v1.5.0/controller/pkg/agentgateway/plugins/reference_indexes.go
  — 28 248 bytes, 651 lines, sha256 `6b56604f7c544131731881b512e216fc0e26dc77e748937ca24e821f3c16c30f`.
- https://raw.githubusercontent.com/agentgateway/agentgateway/v1.5.0/controller/pkg/agentgateway/plugins/traffic_plugin.go
  — 81 193 bytes, 2 408 lines, sha256 `8ffd65250bb60027fa3eca3639f4f4d5ceb30ca278d228a3bbebc27876f40c4d`.

The lines, with their numbers in those files. Stated as read; nothing here is a claim about intent.

`traffic_plugin.go:226`, in `TranslateAgentgatewayPolicy` (from `:178`):

```go
gatewayTargets = references.LookupGatewaysForPolicyTarget(ctx, targetObject, policyTarget).UnsortedList()
```

`reference_indexes.go:462-467`: for a target that is not backend-like, `LookupGatewaysForPolicyTarget` returns
`p.LookupGatewaysForTarget(ctx, object)`. `reference_indexes.go:406-410`:

```go
func (p ReferenceIndex) LookupGatewaysForTarget(ctx krt.HandlerContext, object utils.TypedNamespacedName) sets.Set[types.NamespacedName] {
	switch object.Kind {
	case wellknown.GatewayGVK.Kind:
		// Trivial case
		return sets.New(object.NamespacedName)
```

(`:401`, in the index's own field list: "// Gateway --> Gateway: trivial, no collection needed".) A target of kind
Gateway resolves to itself; the Gateway object and its class are not read there.

`traffic_plugin.go:229-234` appends an `AgwPolicy{Gateway: …, Policy: …}` for each such Gateway, which is the
translated policy the controller pushes (the push line in the run's records). The policy's key is where that line's
`cause` gets its ending: `:227` calls `ClonePoliciesForTarget(baseTranslatedPolicies, policyTarget)` (`:429-441`),
which at `:436` does `clone.Key += attachmentName(policyTarget)`; `attachmentName` (`:2094`), for a Gateway target
(`:2098-2109`), returns `":" + v.Gateway.Namespace + "/" + v.Gateway.Name` (plus a listener or a `port=` marker
when the target names one). The recorded cause, `policy/frontend/lab/tracing:frontend-tracing:lab/agentgateway-waypoint`,
ends in exactly that: `:lab/agentgateway-waypoint`. `traffic_plugin.go:238` calls
`resolvePolicyAncestorRefs`, which (`:371-398`) returns "Policy is not attached: …" only when `targetErr != nil` or
`len(gatewayTargets) == 0`, and otherwise builds one `gwv1.ParentReference` of kind Gateway per resolved Gateway.
`:251` gives each one a status: `SetAncestorStatus(ar, existingStatus, policy.Generation, baseConds, controller)`.
The base conditions of a valid policy are (`:347-356`):

```go
conds[agentgateway.PolicyConditionAccepted] = &Condition{
	Status:  metav1.ConditionTrue,
	Reason:  agentgateway.PolicyReasonValid,
	Message: reporter.PolicyAcceptedMsg,
}
conds[agentgateway.PolicyConditionAttached] = &Condition{
	Status:  metav1.ConditionTrue,
	Reason:  agentgateway.PolicyReasonAttached,
	Message: reporter.PolicyAttachedMsg,
}
```

Neither file contains the string `GatewayClass` (searched without regard to case: 0 lines in each). `ControllerName`
appears in `traffic_plugin.go` three times (`:206`, `:247`, `:308`), each time as the controller's own name written
into, or matched against, the status it writes. #1872 (§6) edits this same `traffic_plugin.go`, on `main`.

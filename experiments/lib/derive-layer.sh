#!/usr/bin/env bash
# derive-layer.sh <repetition directory> <receiver service>
#
# Names the layer that made a second delivery, or a second model call, for one
# work item, and says why. It reads only what that repetition recorded: the three
# ledgers, the client lines and the exported trace. Nothing about which knob was
# switched on reaches this program, so a row cannot be labelled by what it was
# expected to do.
#
# Output on stdout, one attribution block. `layer=` and `reason=` are the two
# lines a caller reads; everything after them is the evidence the label came
# from, and is written next to the ledgers as attribution.txt.
#
#   layer=<client-http|client-sdk|gateway|model-client|none|not-attributable>
#   reason=<one line, no commas: it travels in a CSV notes column>
#
# WHICH HOP A PROXY SPAN BELONGS TO is read from the span's `route`, the column
# of that name in spans.csv, and from nothing else. Since 2026-09-19 one proxy,
# `agw-central`, serves the agent legs (routes `lab/worker`, `lab/orchestrator`)
# and the model leg (route `agentgateway-waypoint/model-via-agw`) under ONE
# service name, so the service name this program keyed the model hop on until
# then ("agw-egress") separates nothing. What the trace gives instead, measured
# that day at agentgateway v1.5.0 on both legs of that proxy and on the ingress
# (experiments/runs/2026-09-19-route-keyed-attribution/): the proxy's SERVER
# span, one per request it received, carries `route` = <namespace>/<HTTPRoute
# name>; its CLIENT spans, one per upstream attempt, are children of that SERVER
# span and carry no route, so an attempt's hop is its parent's. The SERVER span
# of a request the proxy re-sent also carries `retry.attempt` (1 after one
# re-send); it is printed as evidence and decides nothing, the count of upstream
# attempts does.
#
#   the model hop   the spans whose route is MODEL_ROUTE, a constant below, as the
#                   service name was before it. Rule (c) reads it.
#   the agent hop   the route of the proxy entry span found above a receiver
#                   server span that exists, by walking its parents. It is read
#                   from the trace, not named here, because which proxy and route
#                   front a receiver differs by stimulus path (`lab/worker`
#                   in-cluster, `lab/worker-ingress` from outside,
#                   `lab/orchestrator-ingress` for the Python receiver when its
#                   client dials the ingress its card advertises, and
#                   `lab/orchestrator` when the client addresses that receiver's
#                   Service, the matrix's SUB=service rows). Rule (b)'s fallback
#                   reads it.
#
# A TRACE WITH NO `route` COLUMN is a record exported before the exporter wrote
# that column, which the follow-ups 18 exporter of 2026-09-19 is the first to do.
# That is a statement about the EXPORTER and not about the day: fourteen committed
# work items dated 2026-09-19 were still exported by the older one, and six of them
# reach this reason (the probe row a3m-egress-go-fu18p-01 of
# 2026-09-19-route-keyed-attribution, and a3m-egress-go-fu15eg-01..05 of
# 2026-09-19-metrics-per-hop). Until the fix round of follow-ups 19 the reason
# called each "a record from before 2026-09-19", which those six are not. The
# attribution.txt files recorded before that fix
# round keep the earlier words; they are records. Where a rule needs the route --
# rule (c), and rule (b)'s fallback -- the answer is then `not-attributable`, with
# that reason: the hop is never guessed from a service name. Rules (a) and (b)'s
# two span-id shapes, and `none`, read no route and answer on such a record as
# they did when it was taken.
#
# NO USABLE spans.csv AT ALL is a different cause and the reason says so: the
# file is absent, or has no header. That is an export that failed or was never
# taken, not an older record -- `make export-trace` writes no spans.csv when its
# query fails, and leaves a 0-byte one when jq fails after the redirect. The
# label is the same, `not-attributable`, wherever a rule needs the route.
#
# WHAT THE SHARED PROXY FORCED, beyond rule (c): one thing, in rule (b)'s
# fallback. It counted "the inbound spans into the proxy in front of the
# receiver" by that proxy's service name, which on a shared proxy also counts the
# model call's entry; it now counts the entries of one route of that proxy.
# Rules (a), (d) and rule (b)'s two span-id shapes are unchanged: they compare
# span ids, and a shared service name does not touch them (measured: the
# converging shape on `lab/worker` of `agw-central` and on `lab/worker-ingress`).
#
# The rules, in order.
#
#   (a) A second arrival whose JSON-RPC id differs under the same A2A messageId
#       is the SDK-layer resend's signature, measured in Gate 2 A.2: nothing else
#       in this lab re-mints an id. -> client-sdk
#
#   (b) A byte-identical second arrival is a gateway's re-send or the client's
#       HTTP-layer one, and the LEDGERS CANNOT TELL THEM APART: both produce two
#       identical arrivals, and both produce exactly one client line at attempt 1,
#       because the lab's HTTP retry loops inside the transport, below the span
#       the client opens and below the line it prints. The discriminator is the
#       parent span id, not the parent's service name — at step 3 a proxy always
#       sits between the load client and the receiver, so the parent's service is
#       never the client's.
#
#         two receiver server spans sharing ONE parent span id  -> gateway
#           (the proxy put the same span context on the wire twice; measured on
#           the istiod-driven waypoint at Task 2, where both `POST /` server spans
#           named one dangling parent. That proxy class was retired on
#           2026-09-19; the shape stays for records taken before then and for
#           any proxy that exports no span)
#         two distinct parent span ids whose own parents are ONE span of a proxy
#         service                                              -> gateway
#           (the proxy opened a span per upstream attempt under one route span;
#           measured on the agentgateway ingress at Task 2, and on 2026-09-19 on
#           route `lab/worker` of `agw-central`)
#         anything else                                        -> client-http
#           (the client sent twice, so each attempt crossed the proxy separately
#           and got a context of its own)
#
#       FALLBACK when the receiver itself did not open a span for every delivery
#       (fewer receiver server spans than deliveries): a receiver-side injection
#       can answer before the receiver's own instrumentation opens a span for
#       that delivery -- measured at the Python receiver's `IngressMiddleware`,
#       which answers `http503-before-dispatch` and returns before the inner
#       Starlette app (and the OTel auto-instrumentation it carries) ever runs,
#       Gate 3 Task 4 R1. The refused delivery is still visible one hop out, at
#       the proxy route that DID export an entry span for the delivery that got
#       through -- the (service, route) of the nearest ancestor of that
#       delivery's receiver span that carries a `route`, read from the span's own
#       parents and never assumed. "Inbound spans into that proxy" below are the
#       entries on THAT route of that proxy, not every entry of its service: a
#       proxy that also serves the model route has the model call's entry under
#       the same service name. On this topology the fallback is reached by the
#       Python receiver only. When its POST enters through `agentgateway-ingress`
#       on `lab/orchestrator-ingress`, a proxy that serves no model route, the
#       route test removes nothing. When the client addresses the orchestrator
#       Service (the matrix's SUB=service rows, follow-ups 19), the POST enters
#       `agw-central` on `lab/orchestrator`, the proxy that also carries the model
#       call, and the route test is what keeps the model route's entries out of
#       the count: every entry of the service reads 2 on R2 and 3 on R4 and names
#       no layer (fixtures gateway-service-py and gateway-service-r4-py; the check
#       is experiments/runs/2026-09-19-orchestrator-service-rows/
#       route-filter-mutant.txt). The
#       discriminator is the number of upstream attempts PER inbound span, not
#       whether the inbound spans have distinct parents: measured on the
#       agentgateway ingress at Task 4 R1 py/http, in 20 of 20 the two inbound
#       spans share ONE loadgen parent (the client's HTTP-layer retry loops
#       inside the round-tripper, below the span it opens, `internal/httpclient
#       /httpclient.go`), each carrying exactly one upstream attempt of its own:
#
#         N inbound spans into that proxy, N = deliveries, each carrying
#         one upstream attempt of its own                       -> client-http
#           (each delivery crossed the proxy as a separate inbound request,
#           whether or not those requests share one client-side parent span;
#           measured on the agentgateway ingress at Task 4, R1 py/http)
#         one inbound span into that proxy carrying two upstream attempts
#                                                                 -> gateway
#           (the proxy re-sent the one delivery it received; the ingress-hop
#           mirror of the model-route rule in (c) below; measured on
#           `lab/orchestrator-ingress` on 2026-09-19)
#         anything else, no exporting proxy entry above the receiver (a dangling
#         parent), or a trace with no `route` column           -> not-attributable
#         a parent chain above the receiver span that loops    -> not-attributable
#           (no tracer produces one; a damaged or hand-assembled spans.csv can.
#           Until 2026-09-19, follow-ups 19, the walk up the parents did not
#           return on such a file; it now keeps the span ids it has visited, and
#           the reason says the trace is malformed. Fixture: synthetic-parent-cycle)
#
#       The ledger-first rule (a) is checked before this fallback is ever
#       reached, so a second delivery under a new JSON-RPC id is still
#       client-sdk regardless of how many receiver spans exist.
#
#       CAVEAT: the proxy's inbound-entry count is read from the EXPORTED
#       trace, not from the proxy itself, and `make export-trace` selects
#       whole traces by an attribute only a receiver or the mock span ever
#       carries. A delivery is visible here only when its own trace also
#       contains a span that carries that attribute -- which happens when both
#       deliveries share one trace (measured at Task 4 R1 py/http: the client's
#       HTTP-layer retry loops inside one client span, so both attempts and
#       both proxy entries land in the trace the successful delivery's
#       receiver span gets tagged into), and does not happen when a refused
#       delivery gets its own, separately-selected trace with no tagged span
#       anywhere in it (measured at R1 py/sdk: two SendMessage calls, two
#       trace ids, and the refused attempt's trace is simply never returned).
#       An undercounted `proxy_entries` cannot mislabel here, only fall
#       through: `client-http` needs the exact count, `gateway` needs exactly
#       one entry with two upstream attempts, so a proxy-hop delivery this
#       fallback cannot see degrades to `not-attributable` rather than being
#       misread as one of the other two. Say this before R2 or R4 lean on it.
#
#   (c) Two model invocations under one delivery are the receiver's model client
#       or the gateway on the model route, and both reach the model endpoint
#       through the same hop, so the discriminator is how many calls ENTERED that
#       hop. The hop is the spans whose `route` is MODEL_ROUTE, whichever service
#       exported them:
#
#         two entry spans on the model route                   -> model-client
#         one entry span on it with two upstream attempts      -> gateway
#         a trace with no `route` column                       -> not-attributable
#         no entry on it, and the route's NAME under another namespace
#                                                              -> not-attributable
#           (MODEL_ROUTE is ONE constant, dated MODEL_ROUTE_SINCE: a run taken on
#           the topology before that day's change is never re-derived, its labels
#           are read from its committed summary.csv. Its trace, re-exported with
#           today's exporter, carries `agentgateway-egress/model-via-agw`; the
#           label is the same not-attributable as any trace with no entry on the
#           model route, and the reason names the route that WAS found and says
#           the record was taken on the topology before that change, so it cannot
#           be read as a regression. Fixture: older-record-model-hop-reexported)
#
#       Until 2026-09-19 the hop was "spans of service agw-egress". Run against
#       this topology that reading finds 0 entries on every row and answers
#       not-attributable (measured live on the egress row and on R3, both
#       receivers, the day the key changed).
#
#   (d) Anything else is not-attributable, with the reason saying what was
#       missing. A work item with no second delivery and no second model call is
#       `none`, which is not a failure to attribute.
set -euo pipefail

if [ "$#" -ne 2 ]; then
	echo "usage: $0 <repetition directory> <receiver service>" >&2
	exit 1
fi

DIR="$1"
RECEIVER_SERVICE="$2"

if [ ! -d "$DIR" ]; then
	echo "derive-layer: ${DIR} is not a directory" >&2
	exit 1
fi

DIR="$DIR" RECEIVER_SERVICE="$RECEIVER_SERVICE" python3 - <<'PY'
import collections
import csv
import json
import os
import pathlib

d = pathlib.Path(os.environ["DIR"])
receiver = os.environ["RECEIVER_SERVICE"]

# The load client's service name. It is named so the gateway test can refuse to
# treat the client's own span as the proxy the two attempts converged on; the
# out-of-cluster sender emits no spans at all, and its absence changes nothing.
CLIENT_SERVICE = "loadgen"
MOCK_SERVICE = "mockllm"
# The HTTPRoute that carries the model call, as the proxy writes it on its SERVER
# span: <namespace>/<name>. It is the route `make retry-on ROUTE=egress` patches
# (deploy/step-3-stress/retry/egress). Until 2026-09-19 this constant was a
# service name, "agw-egress"; that proxy is retired, and the proxy that serves
# this route now serves the agent routes under the same service name.
MODEL_ROUTE = "agentgateway-waypoint/model-via-agw"
# The day the lab's topology changed and took that route. ONE constant, dated, and
# no set of earlier ones (the author's decision of 2026-09-19): a run taken on the
# topology before that change is never re-derived or re-exported, its labels are
# read from its committed summary.csv. "Before the change", not "before the day":
# of the committed work items that hold an attribution.txt, twelve dated
# 2026-09-19 were taken that day on the earlier topology (ten of
# 2026-09-19-metrics-per-hop, two of 2026-09-19-failed-model-call; their spans name
# the services agw-egress and agentgateway-waypoint), and one of them,
# a3m-egress-go-fu15eg-01, re-exported in a scratch directory, is what showed the
# first wording of this reason ("a record taken before 2026-09-19") to be untrue
# of it. A trace of such a run that IS re-exported carries the model route
# under the name it had then, `agentgateway-egress/model-via-agw`; rule (c) then
# finds no entry on MODEL_ROUTE, and says which route it found instead so that the
# answer cannot be read as a regression (same_name_model_routes below).
MODEL_ROUTE_SINCE = "2026-09-19"


def jsonl(name):
    path = d / name
    if not path.exists():
        return []
    out = []
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            out.append(json.loads(line))
        except ValueError:
            continue
    return out


def spans():
    """The exported trace's rows, and what kind of export this repetition holds.

      "route"            a spans.csv whose header has a `route` column. The column
                         was appended to the export on 2026-09-19.
      "no-route-column"  a spans.csv with a header and no such column: a record
                         exported before the exporter wrote it, whatever day
                         the record is dated. Not the same thing as a record
                         whose spans carry no route: the first cannot say which
                         leg a proxy span belongs to, the second says no proxy
                         span was exported.
      "no-export"        no usable spans.csv: the file is absent, or has no header
                         at all (0 bytes). The export failed or was never taken,
                         which is not an older record and is not reported as one.
    """
    path = d / "spans.csv"
    if not path.exists():
        return [], "no-export"
    with path.open() as fh:
        reader = csv.DictReader(fh)
        found = list(reader)
        names = reader.fieldnames or []
    if not names:
        return [], "no-export"
    return found, ("route" if "route" in names else "no-route-column")


def start(row):
    try:
        return int(row["start_us"] or 0)
    except ValueError:
        return 0


ingress = jsonl("ingress.jsonl")
execution = jsonl("execution.jsonl")
invocation = jsonl("invocation.jsonl")
client = jsonl("client.jsonl")
rows, export = spans()
has_route_column = export == "route"
# Said once, used by both places a rule needs the route and finds none to read.
NO_EXPORT = ("this repetition holds no usable spans.csv (the file is absent or has no header: the trace "
             "export failed or was never taken)")
# Said once as well, for the same two places. It speaks of the exporter, not of the
# day the record is dated: the header of this file says why.
NO_ROUTE_COLUMN = ("the exported trace has no route column (exported before the exporter wrote that column: the "
                   "follow-ups 18 exporter of 2026-09-19 is the first that does)")

arrivals = [x for x in ingress
            if x.get("source") == receiver and x.get("phase") == "arrival" and x.get("method") == "SendMessage"]
# The ingress ledger stamps an arrival with ts_arrival, written before the A2A
# SDK sees the request. Sorting by it is what makes "the first two arrivals" mean
# the first two in time rather than the first two in the file. File order is
# `kubectl logs` order for one pod, which is chronological today, so this is
# belt and braces; it is here so that a collection that ever merges two sources
# is still ordered. A line without the field leaves the order alone rather than
# sorting every arrival to the front under an empty key.
if arrivals and all(x.get("ts_arrival") for x in arrivals):
    arrivals.sort(key=lambda x: x["ts_arrival"])
deliveries = len(arrivals)
dispatched = sum(1 for x in execution if x.get("source") == receiver and x.get("event") == "execute")
# a stale-closed line records a connection close, not a call
invocations = sum(1 for x in invocation if x.get("outcome") != "stale-closed")
client_lines = len(client)


def field(i, name):
    if len(arrivals) > i:
        value = arrivals[i].get(name, "")
        return "" if value is None else str(value)
    return ""


def same(name):
    a, b = field(0, name), field(1, name)
    if not a or not b:
        return "n-a"
    return "yes" if a == b else "no"


msg_same, rpc_id_same, body_same = same("messageId"), same("id"), same("body_sha256")

by_id = {r["span_id"]: r for r in rows if r.get("span_id")}
by_service = collections.Counter(r["service"] for r in rows)


def parent_class(row):
    """The service that made this span's parent, or root, or dangling.

    A dangling parent is a span id no exported span carries. In records taken
    before 2026-09-19 that is an istiod-driven agentgateway waypoint, which read
    the trace context, made a span id of its own and exported nothing (measured
    at Task 1). Those waypoints are retired; on the topology since that day every
    proxy on a work item's path exports its spans, and its proof counted 0
    dangling parents.
    """
    pid = row.get("parent_span_id") or ""
    if not pid:
        return "root"
    parent = by_id.get(pid)
    return "dangling" if parent is None else parent["service"]


def entry_spans(service):
    """This service's POST spans that were entered from somewhere else.

    POST filters out the agent-card fetch, which is a GET and is not a delivery.
    A span whose parent is the same service is internal to it (an ASGI receive
    event, a client span under a server span), not an entry into the service.
    """
    out = []
    for row in sorted((r for r in rows if r["service"] == service), key=start):
        if not row["operation"].upper().startswith("POST"):
            continue
        if parent_class(row) == service:
            continue
        out.append(row)
    return out


def route_entries(route, service=None):
    """The POST requests a proxy received on one route: its spans that carry that
    `route`, in start order. Only a proxy's SERVER span carries the attribute, one
    per request it received, so no parent test is needed to tell an entry from an
    upstream attempt. `service` narrows it to one proxy when the caller has named
    one from the trace; the model route is read across every service, because
    which proxy serves it is a property of the deployment, not of this program.
    """
    out = []
    for row in sorted(rows, key=start):
        if (row.get("route") or "") != route:
            continue
        if service is not None and row["service"] != service:
            continue
        if not row["operation"].upper().startswith("POST"):
            continue
        out.append(row)
    return out


def same_name_model_routes():
    """(route, POST entries) for every route in this trace that has the model
    route's NAME under another namespace: `model-via-agw` anywhere but in
    MODEL_ROUTE's own namespace. The same full route on another proxy is not one of
    these, because route_entries reads MODEL_ROUTE across every service. Counted
    and named, never used to pick a label."""
    name = MODEL_ROUTE.rsplit("/", 1)[-1]
    found = collections.Counter()
    for row in rows:
        route = row.get("route") or ""
        if route == MODEL_ROUTE or route.rsplit("/", 1)[-1] != name:
            continue
        if row["operation"].upper().startswith("POST"):
            found[route] += 1
    return sorted(found.items())


def upstream_of(entry):
    """The proxy's own child spans directly under one entry span: its upstream
    attempts for that one request. Per entry, which is the actual discriminator
    (Task 4 fix round 1) -- not whether the entries have distinct parents, which
    the client-http shape measured at the agentgateway ingress does not have
    (both entries share one loadgen parent)."""
    return [r for r in rows if r["service"] == entry["service"] and (r.get("parent_span_id") or "") == entry["span_id"]]


receiver_entries = entry_spans(receiver)
# The model hop: the requests that entered the model route, and the attempts the
# proxy made upstream under each. One entry with two attempts is the proxy
# re-sending; two entries are two calls the receiver made.
model_entries = route_entries(MODEL_ROUTE)
model_upstream = [r for e in model_entries for r in upstream_of(e)]
mock_entries = entry_spans(MOCK_SERVICE)


def grandparent_of(span_id):
    parent = by_id.get(span_id)
    return (parent.get("parent_span_id") or "") if parent else ""


def service_of(span_id):
    parent = by_id.get(span_id)
    return parent["service"] if parent else ""


class ParentCycle(Exception):
    """The walk up a span's parents came back to a span it had already visited."""


def forwarding_entry(row):
    """The proxy entry span that forwarded the request this receiver span served:
    the nearest ancestor that carries a `route`, reached through spans of one
    service only (the proxy's upstream-attempt span, then its SERVER span). None
    when the parent is dangling, or when the walk leaves that service without
    meeting a route. Read from the span's own ancestry, never assumed or
    hardcoded per receiver: which proxy and which route front a receiver differs
    by stimulus path.

    Raises ParentCycle when the parents loop. No tracer produces that: a span is
    given its parent when it starts, from a span that already exists. A damaged or
    hand-assembled spans.csv can, and until 2026-09-19 (follow-ups 19) this walk
    did not return on one. The set of visited span ids is what ends it; the caller
    answers not-attributable and says why, rather than reading a hop off a file
    that cannot be a trace."""
    cur = by_id.get(row.get("parent_span_id") or "")
    service = cur["service"] if cur else ""
    seen = set()
    while cur is not None and cur["service"] == service:
        if cur["span_id"] in seen:
            raise ParentCycle(cur["span_id"])
        seen.add(cur["span_id"])
        if cur.get("route"):
            return cur
        cur = by_id.get(cur.get("parent_span_id") or "")
    return None


def agent_hop():
    """(proxy service, route) of the entry that forwarded a delivery which DID
    reach the receiver's own instrumentation, or None. The fallback's vantage
    point when some other delivery's receiver span never opened."""
    for r in receiver_entries:
        entry = forwarding_entry(r)
        if entry is not None:
            return entry["service"], entry["route"]
    return None


def proxy_fallback():
    """Attribute a second delivery from the entries of the proxy route in front
    of the receiver, when the receiver itself recorded fewer server spans than
    deliveries. Reached only after the ledger-first client-sdk rule and the
    byte-identical check, so this only ever sees a byte-identical second
    delivery the receiver did not fully instrument.

    The entries counted are those of ONE route of that proxy, the route that
    forwarded the delivery which got through. Counting every entry of the proxy's
    service, as this did until 2026-09-19, also counts the model call's entry
    wherever one proxy serves both legs."""
    if export == "no-export":
        return "not-attributable", (f"{deliveries} deliveries on the ledger / and {NO_EXPORT} / so there is "
                                    "no span to attribute the second delivery from")
    if not has_route_column:
        return "not-attributable", (f"{deliveries} deliveries on the ledger but {len(receiver_entries)} "
                                    f"{receiver} server spans in the trace / and {NO_ROUTE_COLUMN} / so the "
                                    "entries of the proxy in front of the receiver cannot be told from its "
                                    "other legs and are not guessed from its service name")
    try:
        hop = agent_hop()
    except ParentCycle:
        return "not-attributable", (f"{deliveries} deliveries on the ledger but {len(receiver_entries)} "
                                    f"{receiver} server spans in the trace / and the parent chain above the "
                                    f"{receiver} server span loops back on a span already visited / which no "
                                    "tracer produces / so the exported trace is malformed and no proxy entry is "
                                    "read from it")
    if hop is None:
        return "not-attributable", (f"{deliveries} deliveries on the ledger but {len(receiver_entries)} "
                                    f"{receiver} server spans in the trace and no receiver entry has an "
                                    "exported proxy entry carrying a route above it to fall back to / so the "
                                    "second delivery has no span to be attributed from")
    proxy, route = hop
    proxy_entries = route_entries(route, proxy)
    per_entry_upstream = [len(upstream_of(e)) for e in proxy_entries]
    proxy_upstream = sum(per_entry_upstream)
    if len(proxy_entries) == deliveries and all(n == 1 for n in per_entry_upstream):
        return "client-http", (f"route {route} on the {proxy} in front of {receiver} shows {len(proxy_entries)} "
                               "inbound spans with one upstream attempt each, one per delivery, regardless of "
                               f"whether they share one client-side parent / so the client sent this delivery "
                               f"{deliveries} times and the {receiver} span for the refused one never opened")
    if len(proxy_entries) == 1 and proxy_upstream >= 2:
        return "gateway", (f"route {route} on the {proxy} in front of {receiver} shows one inbound span with "
                           f"{proxy_upstream} upstream attempts / so the proxy re-sent the delivery it "
                           "received")
    return "not-attributable", (f"{deliveries} deliveries on the ledger but {len(receiver_entries)} {receiver} "
                                f"server spans / {len(proxy_entries)} entries on route {route} of {proxy} and "
                                f"{proxy_upstream} upstream attempts in the trace / which names no layer")


def decide():
    if deliveries >= 2:
        if rpc_id_same == "no" and msg_same == "yes":
            return "client-sdk", ("the second arrival carries a new JSON-RPC id under the same messageId "
                                  "which is the SDK-layer resend's signature")
        if body_same != "yes":
            return "not-attributable", (f"the two arrivals are not byte-identical (messageId_same={msg_same} "
                                        f"rpc_id_same={rpc_id_same} body_same={body_same}) and do not match a "
                                        "known resend shape")
        if len(receiver_entries) < deliveries:
            return proxy_fallback()
        p1 = receiver_entries[0].get("parent_span_id") or ""
        p2 = receiver_entries[1].get("parent_span_id") or ""
        if p1 and p1 == p2:
            return "gateway", (f"the two {receiver} server spans share one parent span id {p1} / so one proxy "
                               "span sent the request twice")
        g1, g2 = grandparent_of(p1), grandparent_of(p2)
        s1, s2 = service_of(p1), service_of(p2)
        if g1 and g1 == g2 and s1 == s2 and s1 not in ("", CLIENT_SERVICE, receiver):
            return "gateway", (f"the two {receiver} server spans have distinct parents {p1} and {p2} / both "
                               f"{s1} spans under one {s1} span {g1} / so one proxy made both attempts")
        return "client-http", (f"the two {receiver} server spans have distinct parent span ids {p1} and {p2} "
                               "that do not converge on one proxy span / so each attempt crossed the proxy "
                               f"separately / client lines {client_lines} which does not separate the two "
                               "layers because the lab's HTTP retry loops below the line the client prints "
                               "/ a proxy that exports nothing leaves both parents dangling and is caught by "
                               "the shared-parent rule instead because Task 2 measured the istiod-driven "
                               "waypoint (retired 2026-09-19) issuing one span id for both of its own attempts")
    if invocations >= 2:
        if export == "no-export":
            return "not-attributable", (f"{invocations} model invocations on the ledger / and {NO_EXPORT} / so "
                                        "the calls that entered the model route cannot be counted")
        if not has_route_column:
            return "not-attributable", (f"{invocations} model invocations on the ledger / and {NO_ROUTE_COLUMN} / "
                                        "so the calls that entered the model route cannot be counted and are "
                                        "not guessed from a service name")
        if len(model_entries) >= 2:
            return "model-client", (f"{len(model_entries)} calls entered route {MODEL_ROUTE} for one delivery / "
                                    "so the receiver's model client made both")
        if len(model_entries) == 1 and len(model_upstream) >= 2:
            return "gateway", (f"one call entered route {MODEL_ROUTE} and the proxy made {len(model_upstream)} "
                               "upstream attempts under it / so the proxy re-sent it")
        elsewhere = same_name_model_routes()
        if not model_entries and elsewhere:
            named = " and ".join(f"{n} call{'' if n == 1 else 's'} on route {route}" for route, n in elsewhere)
            return "not-attributable", (f"{invocations} model invocations on the ledger but no call entered route "
                                        f"{MODEL_ROUTE} / the trace carries {named} instead / the same route name "
                                        "under another namespace / which is how a record taken on the topology "
                                        f"before the change of {MODEL_ROUTE_SINCE} names its model route / this "
                                        "tool is keyed on the model route of the topology since that change and "
                                        "does not re-derive an earlier record's model hop / so read that record's "
                                        "label from its own summary.csv / this is not a regression")
        return "not-attributable", (f"{invocations} model invocations on the ledger but the trace shows "
                                    f"{len(model_entries)} calls entering route {MODEL_ROUTE} and "
                                    f"{len(model_upstream)} upstream attempts / which names no layer")
    return "none", "no second delivery and no second model invocation"


layer, reason = decide()
# The reason travels in the CSV notes column, whose own separator is ";", so it
# carries neither a comma nor a semicolon: clauses are joined with " / " instead
# and any that slipped through is mapped to the same thing, so the field survives
# as one value for whoever reads the column.
reason = " ".join(reason.replace(",", " / ").replace(";", " / ").split())


def ids(rowlist, key):
    return " ".join((r.get(key) or "(none)") for r in rowlist) or "(none)"


def hop_label(row):
    """The evidence line's words for the proxy entry above one receiver span. The
    span id a looping parent chain came back to is printed here, as evidence, and
    kept out of the reason."""
    try:
        entry = forwarding_entry(row)
    except ParentCycle as cycle:
        return "(parent chain loops at span %s)" % cycle
    if entry is None:
        return "(none)"
    return "%s %s retry.attempt=%s" % (entry["service"], entry["route"], entry.get("retry_attempt") or "(none)")


print("work item %s" % d.name)
print("layer=%s" % layer)
print("reason=%s" % reason)
print("spans by service: %s" % ("|".join(f"{n}={c}" for n, c in sorted(by_service.items())) or "none"))
print("parents of the receiver POST spans, in start order: %s"
      % ("+".join(parent_class(r) for r in receiver_entries) or "none"))
print("parents of the model endpoint POST spans, in start order: %s"
      % ("+".join(parent_class(r) for r in mock_entries) or "none"))
# "yes" and "no" are what this line has printed since it existed, so every recorded
# attribution keeps its text; the third value is the export that is not there.
print("route column in the exported trace: %s"
      % {"route": "yes", "no-route-column": "no", "no-export": "no usable spans.csv"}[export])
print("proxy entry above each receiver POST span, in start order: %s" % (" + ".join(hop_label(r) for r in receiver_entries) or "none"))
print("calls that entered the model route %s: %d" % (MODEL_ROUTE, len(model_entries)))
# Printed on every work item, "(none)" on a trace of this topology: the routes that
# carry the model route's name under another namespace, which is how a re-exported
# trace taken on the topology before the change of MODEL_ROUTE_SINCE shows its
# model hop. Evidence, never a label.
print("routes named like the model route under another namespace, with their POST entries: %s"
      % (" ".join(f"{route}={n}" for route, n in same_name_model_routes()) or "(none)"))
print("upstream attempts the proxy made under those calls: %d" % len(model_upstream))
# What the proxy itself says about re-sending, printed beside the structural count
# above and not used to decide: agentgateway writes retry.attempt on the entry
# span of a request it re-sent and leaves it off one it sent once (measured
# 2026-09-19 on both legs of agw-central and on the ingress).
print("retry.attempt on those model route entries, in start order: %s"
      % (" ".join((e.get("retry_attempt") or "(none)") for e in model_entries) or "(none)"))
print("receiver POST server span ids, in start order: %s" % ids(receiver_entries, "span_id"))
print("receiver POST server span parent ids, in start order: %s" % ids(receiver_entries, "parent_span_id"))
print("parents of those parents, in start order: %s"
      % (" ".join(grandparent_of(r.get("parent_span_id") or "") or "(none)" for r in receiver_entries) or "(none)"))
print("ledgers: deliveries=%d dispatched=%d invocations=%d client_lines=%d"
      % (deliveries, dispatched, invocations, client_lines))
print("identity across the first two arrivals: messageId_same=%s rpc_id_same=%s body_same=%s"
      % (msg_same, rpc_id_same, body_same))
PY

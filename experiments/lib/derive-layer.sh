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
#           named one dangling parent)
#         two distinct parent span ids whose own parents are ONE span of a proxy
#         service                                              -> gateway
#           (the proxy opened a span per upstream attempt under one route span;
#           measured on the agentgateway ingress at Task 2)
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
#       the nearest proxy that DID export a span for the delivery that got
#       through -- named from that span's own parent, never assumed. The
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
#           mirror of the egress rule in (c) below)
#         anything else, or no exporting proxy in front of the receiver
#         (a dangling parent)                                  -> not-attributable
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
#       or the egress gateway, and both reach the model endpoint through the same
#       hop, so the discriminator is how many calls ENTERED that hop:
#
#         two spans entering agw-egress                        -> model-client
#         one span entering it with two upstream attempts      -> gateway
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
EGRESS_SERVICE = "agw-egress"
MOCK_SERVICE = "mockllm"


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
    path = d / "spans.csv"
    if not path.exists():
        return []
    with path.open() as fh:
        return list(csv.DictReader(fh))


def start(row):
    try:
        return int(row["start_us"] or 0)
    except ValueError:
        return 0


ingress = jsonl("ingress.jsonl")
execution = jsonl("execution.jsonl")
invocation = jsonl("invocation.jsonl")
client = jsonl("client.jsonl")
rows = spans()

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

    A dangling parent is a span id no exported span carries. At these pins that
    is an istiod-driven agentgateway waypoint, which reads the trace context,
    makes a span id of its own and exports nothing (measured at Task 1).
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


receiver_entries = entry_spans(receiver)
egress_entries = entry_spans(EGRESS_SERVICE)
# Attempts the egress proxy made upstream: its own spans nested under one of its
# entry spans. One entry with two attempts is the proxy re-sending; two entries
# are two calls the receiver made.
egress_upstream = [r for r in rows if r["service"] == EGRESS_SERVICE and parent_class(r) == EGRESS_SERVICE]
mock_entries = entry_spans(MOCK_SERVICE)


def grandparent_of(span_id):
    parent = by_id.get(span_id)
    return (parent.get("parent_span_id") or "") if parent else ""


def service_of(span_id):
    parent = by_id.get(span_id)
    return parent["service"] if parent else ""


def nearest_proxy_service():
    """The service that exported the immediate parent of a receiver entry span
    that DOES exist, i.e. the proxy that forwarded the delivery which reached
    the receiver's own instrumentation. Used only as a fallback vantage point
    when some other delivery's receiver span never opened, so it is read from a
    real span's own parent rather than assumed or hardcoded per receiver. Empty
    when no receiver entry has an exported parent (a dangling parent, or no
    receiver entry at all), in which case there is no proxy to fall back to."""
    for r in receiver_entries:
        svc = service_of(r.get("parent_span_id") or "")
        if svc:
            return svc
    return ""


def upstream_of(entry):
    """The proxy's own child spans directly under one inbound entry span: its
    upstream attempts for that one delivery. Distinct from `proxy_upstream`
    below, which pools every such child across every entry; this is per entry,
    which is the actual discriminator (Task 4 fix round 1) -- not whether the
    entries have distinct parents, which the client-http shape measured at the
    agentgateway ingress does not have (both entries share one loadgen parent)."""
    return [r for r in rows if r["service"] == entry["service"] and (r.get("parent_span_id") or "") == entry["span_id"]]


def proxy_fallback():
    """Attribute a second delivery from the nearest exporting proxy's own
    entries when the receiver itself recorded fewer server spans than
    deliveries. Reached only after the ledger-first client-sdk rule and the
    byte-identical check, so this only ever sees a byte-identical second
    delivery the receiver did not fully instrument."""
    proxy = nearest_proxy_service()
    if not proxy:
        return "not-attributable", (f"{deliveries} deliveries on the ledger but {len(receiver_entries)} "
                                    f"{receiver} server spans in the trace and no receiver entry has an "
                                    "exported parent to fall back to / so the second delivery has no span "
                                    "to be attributed from")
    proxy_entries = entry_spans(proxy)
    proxy_upstream = [r for r in rows if r["service"] == proxy and parent_class(r) == proxy]
    per_entry_upstream = [len(upstream_of(e)) for e in proxy_entries]
    if len(proxy_entries) == deliveries and all(n == 1 for n in per_entry_upstream):
        return "client-http", (f"the {proxy} in front of {receiver} shows {len(proxy_entries)} inbound spans "
                               "with one upstream attempt each, one per delivery, regardless of whether they "
                               f"share one client-side parent / so the client sent this delivery {deliveries} "
                               f"times and the {receiver} span for the refused one never opened")
    if len(proxy_entries) == 1 and len(proxy_upstream) >= 2:
        return "gateway", (f"the {proxy} in front of {receiver} shows one inbound span with "
                           f"{len(proxy_upstream)} upstream attempts / so the proxy re-sent the delivery it "
                           "received")
    return "not-attributable", (f"{deliveries} deliveries on the ledger but {len(receiver_entries)} {receiver} "
                                f"server spans, {len(proxy_entries)} {proxy} entries and {len(proxy_upstream)} "
                                "upstream attempts in the trace / which names no layer")


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
                               "waypoint issuing one span id for both of its own attempts")
    if invocations >= 2:
        if len(egress_entries) >= 2:
            return "model-client", (f"{len(egress_entries)} calls entered the egress waypoint for one delivery / "
                                    "so the receiver's model client made both")
        if len(egress_entries) == 1 and len(egress_upstream) >= 2:
            return "gateway", (f"one call entered the egress waypoint and it made {len(egress_upstream)} "
                               "upstream attempts / so the proxy re-sent it")
        return "not-attributable", (f"{invocations} model invocations on the ledger but the trace shows "
                                    f"{len(egress_entries)} calls entering the egress waypoint and "
                                    f"{len(egress_upstream)} upstream attempts / which names no layer")
    return "none", "no second delivery and no second model invocation"


layer, reason = decide()
# The reason travels in the CSV notes column, whose own separator is ";", so it
# carries neither a comma nor a semicolon: clauses are joined with " / " instead
# and any that slipped through is mapped to the same thing, so the field survives
# as one value for whoever reads the column.
reason = " ".join(reason.replace(",", " / ").replace(";", " / ").split())


def ids(rowlist, key):
    return " ".join((r.get(key) or "(none)") for r in rowlist) or "(none)"


print("work item %s" % d.name)
print("layer=%s" % layer)
print("reason=%s" % reason)
print("spans by service: %s" % ("|".join(f"{n}={c}" for n, c in sorted(by_service.items())) or "none"))
print("parents of the receiver POST spans, in start order: %s"
      % ("+".join(parent_class(r) for r in receiver_entries) or "none"))
print("parents of the model endpoint POST spans, in start order: %s"
      % ("+".join(parent_class(r) for r in mock_entries) or "none"))
print("calls that entered the egress waypoint: %d" % len(egress_entries))
print("upstream attempts the egress waypoint made: %d" % len(egress_upstream))
print("receiver POST server span ids, in start order: %s" % ids(receiver_entries, "span_id"))
print("receiver POST server span parent ids, in start order: %s" % ids(receiver_entries, "parent_span_id"))
print("parents of those parents, in start order: %s"
      % (" ".join(grandparent_of(r.get("parent_span_id") or "") or "(none)" for r in receiver_entries) or "(none)"))
print("ledgers: deliveries=%d dispatched=%d invocations=%d client_lines=%d"
      % (deliveries, dispatched, invocations, client_lines))
print("identity across the first two arrivals: messageId_same=%s rpc_id_same=%s body_same=%s"
      % (msg_same, rpc_id_same, body_same))
PY

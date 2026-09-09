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


def decide():
    if deliveries >= 2:
        if rpc_id_same == "no" and msg_same == "yes":
            return "client-sdk", ("the second arrival carries a new JSON-RPC id under the same messageId "
                                  "which is the SDK-layer resend's signature")
        if body_same != "yes":
            return "not-attributable", (f"the two arrivals are not byte-identical (messageId_same={msg_same} "
                                        f"rpc_id_same={rpc_id_same} body_same={body_same}) and do not match a "
                                        "known resend shape")
        if len(receiver_entries) < 2:
            return "not-attributable", (f"{deliveries} deliveries on the ledger but {len(receiver_entries)} "
                                        f"{receiver} server spans in the trace / so the second delivery has no "
                                        "span to be attributed from")
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

#!/usr/bin/env python3
"""Follow-ups 14: the GenAI and agent spans per work item, counted per operation and checked attribute by attribute.

`spans.csv` carries ten fixed columns and none of them is a `gen_ai.*` attribute, so this
reads `trace.json` instead -- the raw response of the trace backend's /api/v3/traces
binding, a sequence of {"result": <TracesData>} chunks holding OTLP resourceSpans, the
same bytes experiments/lib/jaeger-spans.jq reads.

    python3 genai-spans.py <trace run directory> <out directory>

Writes three files into the out directory:

  per-operation.csv   one row per work item and span name: work_item,service,operation,spans
  chat-spans.csv      one row per `chat` span, with every attribute the conventions ask of it
  invoke-agent.csv    one row per `invoke_agent` span, the same way

and prints a summary: for each work item, the span total, the per-service counts, the
per-operation counts of the two GenAI operations, and whether every span carries
lab.work_item.

Attribute checks are stated as the conventions state them, at the revision in
versions.yaml (genai-semantic-conventions), and each span is checked against three sets
rather than against the two unconditionally Required attributes alone:

  required      Required outright. `gen_ai.operation.name` and `gen_ai.provider.name` on
                both spans.
  expected      Conditionally Required where this lab meets the condition, plus
                Recommended where the value is in the answer. On a chat span:
                gen_ai.request.model ("If available."), gen_ai.response.id,
                gen_ai.response.model, gen_ai.response.finish_reasons and the two token
                counts (Recommended; the mock answers all five), and server.address /
                server.port. On an invoke_agent span: gen_ai.agent.name,
                gen_ai.agent.version and gen_ai.agent.description ("When available.";
                an A2A card carries all three), gen_ai.conversation.id ("If and only if
                the instrumented library has one readily available" -- A2A gives one
                back on a Task), and server.address / server.port.
  never         gen_ai.agent.id, which is Conditionally Required "If applicable" and is
                not applicable: an A2A v1.0 AgentCard has no id field. A value here
                would be invented.

The columns `required_absent`, `expected_absent` and `never_present` list what each span
failed, or `none`. A span from an instrumentation this lab did not write is checked the
same way, so what the package does and does not carry is counted rather than assumed;
`lab_absent` lists the lab identity attributes it lacks, which are not conventions
attributes and are reported separately -- for an invoke_agent span against the three that
exist before the downstream agent has made a Task, not four.
"""
import collections
import csv
import glob
import json
import os
import sys


def chunks(path):
    """Read the concatenated JSON objects the streaming binding answers with."""
    text = open(path).read()
    decoder, index, out = json.JSONDecoder(), 0, []
    while index < len(text):
        while index < len(text) and text[index] in " \t\r\n":
            index += 1
        if index >= len(text):
            break
        value, index = decoder.raw_decode(text, index)
        out.append(value)
    return out


def value_of(v):
    if v is None:
        return ""
    for key in ("stringValue", "bytesValue"):
        if key in v:
            return v[key]
    for key in ("intValue", "boolValue", "doubleValue"):
        if key in v:
            return str(v[key])
    if "arrayValue" in v:
        return "|".join(value_of(x) for x in v["arrayValue"].get("values", []))
    return ""


def attributes(items):
    return {a["key"]: value_of(a.get("value")) for a in (items or [])}


KIND = {0: "UNSPECIFIED", 1: "INTERNAL", 2: "SERVER", 3: "CLIENT", 4: "PRODUCER", 5: "CONSUMER"}


def spans_of(path):
    out = []
    for chunk in chunks(path):
        data = chunk.get("result", chunk)
        for rs in data.get("resourceSpans", []):
            service = attributes(rs.get("resource", {}).get("attributes")).get("service.name", "")
            for ss in rs.get("scopeSpans", rs.get("instrumentationLibrarySpans", [])):
                scope = (ss.get("scope") or {}).get("name", "")
                for s in ss.get("spans", []):
                    kind = s.get("kind", 0)
                    out.append({
                        "service": service,
                        "scope": scope,
                        "operation": s.get("name", ""),
                        "kind": KIND.get(kind if isinstance(kind, int) else 0, str(kind)),
                        "span_id": s.get("spanId", ""),
                        "parent_span_id": s.get("parentSpanId", ""),
                        "attrs": attributes(s.get("attributes")),
                    })
    return out


REQUIRED = ["gen_ai.operation.name", "gen_ai.provider.name"]

CHAT_EXPECTED = ["gen_ai.request.model", "gen_ai.response.id", "gen_ai.response.model",
                 "gen_ai.response.finish_reasons", "gen_ai.usage.input_tokens",
                 "gen_ai.usage.output_tokens", "server.address", "server.port"]
AGENT_EXPECTED = ["gen_ai.agent.name", "gen_ai.agent.version", "gen_ai.agent.description",
                  "gen_ai.conversation.id", "server.address", "server.port"]
NEVER = ["gen_ai.agent.id"]

CHAT_FIELDS = REQUIRED + CHAT_EXPECTED + ["error.type"]
AGENT_FIELDS = REQUIRED + AGENT_EXPECTED + NEVER + ["error.type"]
LAB_FIELDS = ["lab.work_item", "lab.message_id", "lab.task_id", "lab.caller"]
# An invoke_agent span is opened before the downstream agent has made a Task, so its
# caller has no task id to put on it; `lab_absent` for that span is checked against the
# three values that do exist at that moment rather than against all four.
LAB_AGENT_FIELDS = ["lab.work_item", "lab.message_id", "lab.caller"]


def absent(attrs, keys):
    """Which of keys the span does not carry, as a printable field."""
    return "|".join(k for k in keys if not attrs.get(k)) or "none"


def present(attrs, keys):
    """Which of keys the span does carry, for the set that should carry none."""
    return "|".join(k for k in keys if attrs.get(k)) or "none"


def main(run_dir, out_dir):
    os.makedirs(out_dir, exist_ok=True)
    per_op = open(os.path.join(out_dir, "per-operation.csv"), "w", newline="")
    chat = open(os.path.join(out_dir, "chat-spans.csv"), "w", newline="")
    agent = open(os.path.join(out_dir, "invoke-agent.csv"), "w", newline="")
    per_op_w = csv.writer(per_op, lineterminator="\n")
    per_op_w.writerow(["work_item", "service", "operation", "kind", "spans"])
    chat_w = csv.writer(chat, lineterminator="\n")
    chat_w.writerow(["work_item", "service", "scope", "operation", "kind", "required_absent",
                     "expected_absent", "lab_absent", "children"] + CHAT_FIELDS + LAB_FIELDS)
    agent_w = csv.writer(agent, lineterminator="\n")
    agent_w.writerow(["work_item", "service", "scope", "operation", "kind", "required_absent",
                      "expected_absent", "never_present", "lab_absent"] + AGENT_FIELDS + LAB_FIELDS)

    print("work_item,spans,by_service,chat_spans,invoke_agent_spans,lab_work_item_on_all,"
          "spans_missing_required,spans_missing_expected,spans_with_agent_id")
    for path in sorted(glob.glob(os.path.join(run_dir, "*", "trace.json"))):
        work_item = os.path.basename(os.path.dirname(path))
        spans = spans_of(path)
        children = collections.Counter(s["parent_span_id"] for s in spans if s["parent_span_id"])

        by_service = collections.Counter(s["service"] for s in spans)
        by_op = collections.Counter((s["service"], s["operation"], s["kind"]) for s in spans)
        for (service, operation, kind), n in sorted(by_op.items()):
            per_op_w.writerow([work_item, service, operation, kind, n])

        chats = [s for s in spans if s["attrs"].get("gen_ai.operation.name") == "chat"]
        agents = [s for s in spans if s["attrs"].get("gen_ai.operation.name") == "invoke_agent"]
        for s in chats:
            a = s["attrs"]
            chat_w.writerow([work_item, s["service"], s["scope"], s["operation"], s["kind"],
                             absent(a, REQUIRED), absent(a, CHAT_EXPECTED), absent(a, LAB_FIELDS),
                             children.get(s["span_id"], 0)]
                            + [a.get(f, "") for f in CHAT_FIELDS] + [a.get(f, "") for f in LAB_FIELDS])
        for s in agents:
            a = s["attrs"]
            agent_w.writerow([work_item, s["service"], s["scope"], s["operation"], s["kind"],
                              absent(a, REQUIRED), absent(a, AGENT_EXPECTED), present(a, NEVER),
                              absent(a, LAB_AGENT_FIELDS)]
                             + [a.get(f, "") for f in AGENT_FIELDS] + [a.get(f, "") for f in LAB_FIELDS])

        carrying = sum(1 for s in spans if s["attrs"].get("lab.work_item") == work_item)
        genai = [(s, CHAT_EXPECTED) for s in chats] + [(s, AGENT_EXPECTED) for s in agents]
        missing_required = sum(1 for s, _ in genai if absent(s["attrs"], REQUIRED) != "none")
        missing_expected = sum(1 for s, exp in genai if absent(s["attrs"], exp) != "none")
        with_agent_id = sum(1 for s, _ in genai if present(s["attrs"], NEVER) != "none")
        print("%s,%d,%s,%d,%d,%s,%d,%d,%d" % (
            work_item, len(spans),
            "|".join("%s=%d" % kv for kv in sorted(by_service.items())),
            len(chats), len(agents),
            "yes" if spans and carrying == len(spans) else "no:%d/%d" % (carrying, len(spans)),
            missing_required, missing_expected, with_agent_id))
    for f in (per_op, chat, agent):
        f.close()


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else sys.argv[1])

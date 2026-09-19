#!/usr/bin/env python3
"""expected-spans.py <trace.json> -- the rows experiments/lib/jaeger-spans.jq is expected to write.

An independent reading of the same query response, in another language, so that
the committed expectation `make test` compares the jq program against is not that
program's own output. Columns: the ten the Gate 3 plan fixed, then `route` and
`retry_attempt`, appended at the end by follow-ups 18 task 3.
"""
import csv
import json
import sys

COLUMNS = ["trace_id", "span_id", "parent_span_id", "service", "operation", "start_us", "duration_us",
           "lab_work_item", "lab_message_id", "http_status", "route", "retry_attempt"]


def chunks(text):
    """The body is a sequence of JSON objects, not one."""
    dec, i, n = json.JSONDecoder(), 0, len(text)
    while i < n:
        while i < n and text[i].isspace():
            i += 1
        if i >= n:
            break
        obj, i = dec.raw_decode(text, i)
        yield obj


def scalar(value):
    for key in ("stringValue", "intValue", "boolValue", "doubleValue"):
        if key in value:
            v = value[key]
            return ("true" if v else "false") if isinstance(v, bool) else str(v)
    return ""


def attr(attrs, *keys):
    for key in keys:
        for a in attrs or []:
            if a.get("key") == key:
                v = scalar(a.get("value") or {})
                if v != "":
                    return v
    return ""


def us(nanos):
    s = str(nanos)
    return int(s[:-3]) if len(s) > 3 else 0


rows = []
for chunk in chunks(open(sys.argv[1]).read()):
    data = chunk.get("result", chunk)
    for rs in data.get("resourceSpans", []):
        service = attr(rs.get("resource", {}).get("attributes"), "service.name")
        for ss in rs.get("scopeSpans", []):
            for s in ss.get("spans", []):
                a = s.get("attributes")
                start = us(s["startTimeUnixNano"])
                rows.append([s.get("traceId", ""), s.get("spanId", ""), s.get("parentSpanId", ""), service,
                             s.get("name", ""), start, us(s["endTimeUnixNano"]) - start,
                             attr(a, "lab.work_item"), attr(a, "lab.message_id"),
                             attr(a, "http.response.status_code", "http.status_code"),
                             attr(a, "route"), attr(a, "retry.attempt")])
rows.sort(key=lambda r: (r[5], r[1]))
out = csv.writer(sys.stdout, lineterminator="\n")
out.writerow(COLUMNS)
out.writerows(rows)

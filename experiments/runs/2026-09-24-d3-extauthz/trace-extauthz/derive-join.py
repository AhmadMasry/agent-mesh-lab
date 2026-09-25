#!/usr/bin/env python3
"""Follow-on D-3 (review-d3 M10): derives trace-extauthz/join.csv from trace-extauthz/extauthz-spans.jsonl alone, one row per
checked request, with the columns join.csv carries. Run from the run directory; writes join.csv."""
import csv, json
rows = []
for l in open("trace-extauthz/extauthz-spans.jsonl"):
    o = json.loads(l)
    for s in o["extauthz_spans"] or [None]:
        tags = s["tags"] if s else {}
        parent = [r["spanID"] for r in (s["references"] if s else []) if r["refType"] == "CHILD_OF"]
        rows.append({
            "phase": o["phase"], "work_item": o["work_item"], "access_trace_id": o["access_trace_id"],
            "http_method": o["http_method"], "access_status": o["access_status"],
            "extauthz_spans": str(len(o["extauthz_spans"])),
            "extauthz_grpc_status": "|".join(str(x["tags"].get("grpc.status", "")) for x in o["extauthz_spans"]),
            "fixture_request_id": o["fixture_request_id"], "fixture_request_id_spans": str(o["fixture_request_id_spans"]),
            "access_span_id": o["access_span_id"], "extauthz_parent": ";".join(parent),
            "parent_is_access_span": str(bool(parent) and parent[0] == o["access_span_id"]),
            "service": s["service"] if s else "", "span_kind": tags.get("span.kind", ""),
            "span_http_path": tags.get("http.path", ""), "span_http_host": tags.get("http.host", ""),
        })
with open("trace-extauthz/join.csv", "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=list(rows[0].keys()), lineterminator="\n")
    w.writeheader()
    w.writerows(rows)
print(len(rows), "rows")

#!/usr/bin/env python3
"""Follow-ups 11: spans, trace ids, roots and dangling parents per work item, from each spans.csv under a
trace run directory. A dangling parent is a non-empty parent_span_id that is no span_id in the same file."""
import csv, glob, os, sys
d = sys.argv[1]
print("work_item,spans,trace_ids,roots,dangling_parents")
for f in sorted(glob.glob(os.path.join(d, "*", "spans.csv"))):
    rows = list(csv.DictReader(open(f)))
    ids = {r["span_id"] for r in rows}
    roots = sum(1 for r in rows if not r["parent_span_id"])
    dang = sum(1 for r in rows if r["parent_span_id"] and r["parent_span_id"] not in ids)
    print("%s,%d,%d,%d,%d" % (os.path.basename(os.path.dirname(f)), len(rows), len({r["trace_id"] for r in rows}), roots, dang))

#!/usr/bin/env python3
"""dangling-parents.py <spans.csv>...  ->  CSV on stdout, one row per file.

A dangling parent is a span whose parent_span_id is not the span_id of any exported span
of the same work item: some hop read the incoming trace context, made a span of its own,
passed its id on, and did not export it. The trace script's summary.csv counts hops
without a span by service name; this counts the same absence from the other side, by
span id, and names the services whose spans point at the missing parent.

Read with python's csv reader: the exporter quotes any field that holds a comma.
"""
import csv
import pathlib
import sys


def main() -> int:
    out = csv.writer(sys.stdout, lineterminator="\n")
    out.writerow(["work_item", "spans", "trace_ids", "dangling_parents", "children_of_missing_parent"])
    for arg in sys.argv[1:]:
        path = pathlib.Path(arg)
        work_item = path.parent.name
        if not path.exists():
            out.writerow([work_item, "no spans.csv", "", "", ""])
            continue
        rows = list(csv.DictReader(path.open()))
        ids = {row["span_id"] for row in rows}
        dangling = [row for row in rows if row["parent_span_id"] and row["parent_span_id"] not in ids]
        out.writerow([
            work_item,
            len(rows),
            len({row["trace_id"] for row in rows}),
            len(dangling),
            "|".join(f"{row['service']}:{row['operation']}" for row in dangling) or "none",
        ])
    return 0


if __name__ == "__main__":
    sys.exit(main())

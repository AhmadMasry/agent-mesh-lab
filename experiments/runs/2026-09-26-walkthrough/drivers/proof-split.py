"""Follow-ups 24: the second standard proof's trace files split by trace id, because two standard proofs ran on this
cluster and checks.sh names its work items with fixed nonces (fu3cc, fu3ct), so the second proof's make ledgers and
export-trace collected the first proof's lines and traces as well wherever they still stood: in the worker pod's log
(the orchestrator pod was replaced between the two proofs) and in the trace backend. For each trace directory of the
proof given, one line per trace id: its span count, the first span's start (UTC), and the services on it, sorted by
that start, so that the first proof's traces and this proof's stand apart. Reads files only.
usage: proof-split.py <proof dir>"""
import csv
import datetime
import glob
import os
import sys

P = sys.argv[1]
print(f'# {os.path.basename(P)}: spans per trace id, by the first span\'s start; two proofs\' traces share each work item name')
for d in sorted(glob.glob(os.path.join(P, 'trace', 'a3t-*'))):
    rows = list(csv.DictReader(open(os.path.join(d, 'spans.csv'))))
    by = {}
    for r in rows:
        by.setdefault(r['trace_id'], []).append(r)
    print(f'## {os.path.basename(d)}: {len(rows)} spans, {len(by)} trace ids')
    for t, rs in sorted(by.items(), key=lambda kv: min(int(r['start_us']) for r in kv[1])):
        s = min(int(r['start_us']) for r in rs)
        stamp = datetime.datetime.fromtimestamp(s / 1e6, datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
        print(f'  trace {t}: spans={len(rs)} first_start={stamp} services={",".join(sorted({r["service"] for r in rs}))}')

"""Follow-ups 24: every row of this walk beside the entry that recorded it, cell by cell.

The rows the walkthrough re-takes ran at two repetitions (one where the entry ran one probe) where the entries ran
N, so a column cannot be compared as a multiset. As in experiments/runs/2026-09-25-walkthrough/drivers/compare-rows.py,
each column is compared as the SET of its distinct values over the row's repetitions, after masking identifiers only:
UUIDs, 64-, 32- and 16-hex ids, IPv4 addresses with ports, pod-name suffixes, ISO stamps, a proxy's connection.id counter,
and the two runs' RUN_ID tokens
with the repetition number that follows them (the patterns and rule of experiments/runs/2026-09-25-currency-rebuild/drivers/cellcompare.py, plus the stamp).

A column reads "same" when the two sets are equal. It reads "timing" when the column is a timing (its name carries
_ms, _us or _s as a unit, or names a latency, duration, margin, stamp or time): a duration is not a count. Otherwise it reads "within"
when every value this run took is one the entry took but the entry took more: two draws against twenty cannot show
every value the entry saw. Otherwise it reads "timing" again when the two sets become equal, or this run's a subset of
the entry's, once every millisecond figure inside a value ("45003ms", "0.7ms") is replaced by <ms>. It reads "DIFFERS"
when this run took a value the entry never took, after those millisecond figures are masked: that is the class a row is
held on. Both sets are printed in full for
every class; nothing is hidden. A set comparison says that every value this run took is one the entry took and, for
"same", that every value the entry took appeared here; it does not say that a value would hold in N of N here.
Columns named in "skip" are not compared (work-item ids and per-send counters that carry the repetition count itself);
each skip is named in the output.

One column is a list rather than a value: old_pod_drain_lines (B-5a, B-5b, D-1) joins the removed proxy pod's log lines
after the removal with " | " in the order they were logged, and its listeners drain concurrently, so the same seven
lines come in a different order on almost every repetition. That column alone is compared with its lines sorted (the
set of lines a repetition logged, not their order), and the output says so beside it.

D-2's counts.csv is the one file whose rows are tallies over a window's sends rather than one line per send: there each
cell is first normalised to the row's own "sends" value, a number equal to it becoming <n> and an "Nx " prefix equal to
it becoming "<n>x ", so that 5 of 5 in the entry and 2 of 2 here read the same and 0 of 5 against 0 of 2 read the same,
while a mixed tally ("3x a, 2x b") keeps its numbers and differs. That normalisation is printed with the row.

Reads files only. usage: compare-rows.py <walk run dir> [<row label> ...]"""
import csv
import collections
import os
import re
import sys

WALK = sys.argv[1]
ONLY = set(sys.argv[2:])
RUNS = 'experiments/runs'


def P(*a):
    return os.path.join(*a)


# label, old csv, new csv, key columns, skip columns, old run tokens, new run tokens[, normalising column[, 'new-keys-only']]
OLDA = P(RUNS, '2026-09-20-experiment-a-agentgateway-only')
B3 = P(RUNS, '2026-09-21-b3-streaming-client')
CUR = P(RUNS, '2026-09-25-currency-rebuild')
D1 = P(RUNS, '2026-09-24-d1-current-topology')
C9 = P(RUNS, '2026-09-24-c9-a2a-marking', 'readings')
ROWS = [
    # Experiment A, the six rows of the existing walkthrough (fu23's table)
    ('a1-m1-go', P(OLDA, 'a1-m1-go/summary.csv'), P(WALK, 'a1-m1-go/summary.csv'), 'mode,receiver,path', '', ['002740'], ['wta1']),
    ('a2-go-http-503', P(OLDA, 'a2-go-http-503/summary.csv'), P(WALK, 'a2-go-http-503/summary.csv'), 'client,layer', '', ['020556'], ['wta2']),
    ('a3-baseline-go', P(OLDA, 'a3-baseline-go/summary.csv'), P(WALK, 'a3-baseline-go/summary.csv'), 'receiver,run,sub', '', ['022306'], ['wta3b']),
    ('a3-r1-go-http', P(OLDA, 'a3-r1-go-http/summary.csv'), P(WALK, 'a3-r1-go-http/summary.csv'), 'receiver,run,sub', '', ['024648'], ['wta3r1']),
    ('a3-egress-go', P(OLDA, 'a3-egress-go/summary.csv'), P(WALK, 'a3-egress-go/summary.csv'), 'receiver,run,sub', '', ['045639'], ['wta3e']),
    ('a3-r2-py-service', P(OLDA, 'a3-r2-py-service/summary.csv'), P(WALK, 'a3-r2-py-service/summary.csv'), 'receiver,run,sub', '', ['053247'], ['wta3s']),
    # Experiment B
    ('b3-model-call', P(B3, 'model-call/summary.csv'), P(WALK, 'b3/model-call/summary.csv'), 'receiver', '', ['r212542'], ['wtb3mc']),
    ('b3-stream', P(B3, 'stream/summary.csv'), P(WALK, 'b3/stream/summary.csv'), 'receiver', '', ['r221134'], ['wtb3st']),
    ('b3-subscribe-running', P(B3, 'subscribe-running/summary.csv'), P(WALK, 'b3/subscribe-running/summary.csv'), 'receiver', '', ['r222720'], ['wtb3sr']),
    ('b3-subscribe-terminal (the entry of 2026-09-21, a2a-go v2.5.0)', P(B3, 'subscribe-terminal/summary.csv'), P(WALK, 'b3/subscribe-terminal/summary.csv'), 'receiver', '', ['r231337'], ['wtb3sx']),
    ('b3-subscribe-terminal (the currency pass of 2026-09-25, a2a-go v2.6.0)', P(CUR, 'b3-subscribe-terminal/summary.csv'), P(WALK, 'b3/subscribe-terminal/summary.csv'), 'receiver', '', ['cur3y'], ['wtb3sx']),
    ('b4-control', P(RUNS, '2026-09-22-b4-control/control/summary.csv'), P(WALK, 'b4/control/summary.csv'), 'receiver', '', ['r171600'], ['wtb4']),
    ('b5a-removal', P(RUNS, '2026-09-22-b5a-removal/removal/summary.csv'), P(WALK, 'b5a/removal/summary.csv'), 'variant,proxy,method', '', ['r1'], ['wtb5a']),
    ('b5b-rows', P(RUNS, '2026-09-22-b5b-removal-resubscribe/rows/summary.csv'), P(WALK, 'b5b/rows/summary.csv'), 'variant,receiver,proxy,method', '', ['r1'], ['wtb5b']),
    ('d1-rollout', P(D1, 'rows/rollout-summary.csv'), P(WALK, 'd1-rollout/rows/summary.csv'), 'variant,receiver,proxy,method', '', ['r1'], ['wtd1r']),
    ('d1-pyclient (the entry of 2026-09-24, a2a-go v2.5.0)', P(D1, 'rows/pyclient-central-graceful/summary.csv'), P(WALK, 'd1-pyclient/rows/pyclient-central-graceful/summary.csv'), 'removal_sent', '', ['r1'], ['wtd1p']),
    ('d1-pyclient (the currency pass of 2026-09-25, a2a-go v2.6.0)', P(CUR, 'd1p/rows/pyclient-central-graceful/summary.csv'), P(WALK, 'd1-pyclient/rows/pyclient-central-graceful/summary.csv'), 'removal_sent', '', ['cur1p'], ['wtd1p']),
    # Experiment C
    ('c3-c4', P(RUNS, '2026-09-21-c3-c4-ztunnel/counts.csv'), P(WALK, 'c3c4/counts.csv'), 'work_item', '', [], []),
    ('c3r', P(RUNS, '2026-09-21-c3r-open-connections/counts.csv'), P(WALK, 'c3r/counts.csv'), 'scope', 'n', [], []),
    ('c3r2', P(RUNS, '2026-09-21-c3r2-public-server/counts.csv'), P(WALK, 'c3r2/counts.csv'), 'scope', 'n', [], []),
    ('c5', P(RUNS, '2026-09-23-c5-istio-policy-agw-central/counts.csv'), P(WALK, 'c5/counts.csv'), 'phase,receiver,op,probe_header', 'work_item', ['c5a'], ['wtc5']),
    ('c6', P(RUNS, '2026-09-23-c6-httproute/counts.csv'), P(WALK, 'c6/counts.csv'), 'phase,receiver,kind', 'work_item', ['c6a'], ['wtc6']),
    ('c7-header', P(RUNS, '2026-09-23-c7-agw-authorization/counts.csv'), P(WALK, 'c7/counts.csv'), 'phase,receiver,kind', 'work_item', ['c7a'], ['wtc7']),
    ('c7-identity', P(RUNS, '2026-09-23-c7-agw-authorization/identity-counts.csv'), P(WALK, 'c7/identity-counts.csv'), 'path', 'work_item', ['c7a'], ['wtc7']),
    ('c8', P(RUNS, '2026-09-23-c8-body-rule/counts.csv'), P(WALK, 'c8/counts.csv'), 'phase,rule,receiver,kind', 'work_item', ['c8a'], ['wtc8']),
    ('c8-batch-repeat (the two batch probes re-taken at the walk\'s end with the by-body-hash read; the entry\'s other keys are not compared here)', P(RUNS, '2026-09-23-c8-body-rule/counts.csv'), P(WALK, 'c8-repeat/counts.csv'), 'phase,rule,receiver,kind', 'work_item', ['c8a'], ['wtc8r'], None, 'new-keys-only'),
    ('c10', P(RUNS, '2026-09-24-c10-application/counts.csv'), P(WALK, 'c10/counts.csv'), 'phase,receiver,kind', 'n,lwi', ['c10'], ['c10']),
    ('c9-requests', P(C9, 'after/requests.csv'), P(WALK, 'c9/after/requests.csv'), 'phase,recv,kind,proxy,route,http.method,http.path', 'lwi,trace.id', ['a1'], ['a1']),
    ('c9-proxy-spans', P(C9, 'after/proxy-spans.csv'), P(WALK, 'c9/after/proxy-spans.csv'), 'phase,recv,kind,service,name,route', 'lwi,trace.id', ['a1'], ['a1']),
    ('c9-arrivals', P(C9, 'after/arrivals.csv'), P(WALK, 'c9/after/arrivals.csv'), 'phase,recv,kind,at,method', 'lwi,taskId,messageId', ['a1'], ['a1']),
    ('c9-clients', P(C9, 'after/clients.csv'), P(WALK, 'c9/after/clients.csv'), 'phase,recv,kind,method', 'lwi', ['a1'], ['a1']),
    ('c9-base-requests', P(C9, 'base/requests.csv'), P(WALK, 'c9/base/requests.csv'), 'phase,recv,kind,proxy,route,http.method,http.path', 'lwi,trace.id', ['b1'], ['b1']),
    ('c9-base-clients', P(C9, 'base/clients.csv'), P(WALK, 'c9/base/clients.csv'), 'phase,recv,kind,method', 'lwi', ['b1'], ['b1']),
    # the D rows
    ('d2 (cells normalised to the row\'s sends)', P(RUNS, '2026-09-24-d2-bindings/counts.csv'), P(WALK, 'd2/counts.csv'), 'window,binding,receiver,kind', 'sends', ['d2'], ['wtd2'], 'sends'),
    ('d3', P(RUNS, '2026-09-24-d3-extauthz/counts.csv'), P(WALK, 'd3/counts.csv'), 'phase,binding,receiver,kind', 'n,work_item', ['d3a'], ['d3a']),
    ('d3-batch-repeat (the two allow-window batch probes re-taken at the walk\'s end with the by-body-hash read; the entry\'s other keys are not compared here)', P(RUNS, '2026-09-24-d3-extauthz/counts.csv'), P(WALK, 'd3-repeat/counts.csv'), 'phase,binding,receiver,kind', 'n,work_item', ['d3a'], ['d3ar'], None, 'new-keys-only'),
    ('d3b', P(RUNS, '2026-09-25-d3b-extauthz-shapes/counts.csv'), P(WALK, 'd3b/counts.csv'), 'phase,binding,receiver,kind', 'n,work_item', ['d3b'], ['d3b']),
]
PATS = [(re.compile(r'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'), '<uuid>'),
        (re.compile(r'\b[0-9a-f]{64}\b'), '<sha256>'),
        (re.compile(r'\b[0-9a-f]{32}\b'), '<id32>'), (re.compile(r'\b[0-9a-f]{16}\b'), '<id16>'),
        (re.compile(r'\b\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d+)?Z\b'), '<stamp>'),
        (re.compile(r'\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}(:\d+)?\b'), '<ip>'),
        (re.compile(r'-[0-9a-f]{8,10}-[0-9a-z]{5}\b'), '-<pod>'),
        (re.compile(r'connection\.id=\d+'), 'connection.id=<n>')]
TIMING = re.compile(r'(_ms(_|$)|_us(_|$)|_s(_|$)|latency|duration|_at$|stamp|time|_margin_)', re.I)
MS = re.compile(r'\b\d+(\.\d+)?ms\b')


def mask(v, rids):
    for r in rids:
        if r:
            v = re.sub(r'(?<![0-9a-z])' + re.escape(r) + r'(?![0-9a-z])', '<run>', v)
    v = re.sub(r'<run>-\d+\b', '<run>-<rep>', v)
    for p, r in PATS:
        v = p.sub(r, v)
    return v


UNORDERED = {'old_pod_drain_lines'}


def unordered(c, v):
    return ' | '.join(sorted(v.split(' | '))) if c in UNORDERED and v else v


def norm(v, n):
    if not n:
        return v
    if v == n:
        return '<n>'
    return re.sub(r'(?<![0-9])' + re.escape(n) + r'x ', '<n>x ', v)


def load(p, keys, rids, normcol=None):
    g = collections.defaultdict(list)
    cols = None
    for r in csv.DictReader(open(p)):
        if not any(r.values()):
            continue
        cols = cols or list(r.keys())
        n = r.get(normcol) if normcol else None
        g[tuple(r.get(k, '') for k in keys)].append({c: unordered(c, mask(norm((r.get(c) or '').replace('\n', '\\n'), n), rids)) for c in r})
    return g, cols or []


tot = collections.Counter()
for row in ROWS:
    label, old, new, keys, skip, rid_old, rid_new = row[:7]
    normcol = row[7] if len(row) > 7 else None
    new_keys_only = len(row) > 8 and row[8] == 'new-keys-only'
    if ONLY and label not in ONLY:
        continue
    keys = keys.split(',')
    skip = set(skip.split(',')) - {''}
    if not os.path.exists(old) or not os.path.exists(new):
        print(f'## {label}: {"missing " + old if not os.path.exists(old) else ""}{"missing " + new if not os.path.exists(new) else ""}')
        tot['rows-missing'] += 1
        continue
    go, co = load(old, keys, rid_old + rid_new, normcol)
    gn, cn = load(new, keys, rid_old + rid_new, normcol)
    row_tot = collections.Counter()
    print(f'## {label}: {old} | {new}')
    if skip:
        print(f'  skipped (not compared): {", ".join(sorted(skip))}')
    if set(co) & UNORDERED:
        print(f'  compared with their lines sorted, not in logged order: {", ".join(sorted(set(co) & UNORDERED))}')
    if co != cn:
        print(f'  columns differ: {co} | {cn}')
    if new_keys_only:
        print(f'  compared on the keys this run holds only: {len(gn)} of the entry\'s {len(go)}')
    for k in sorted(set(gn) if new_keys_only else set(go) | set(gn)):
        a, b = go.get(k, []), gn.get(k, [])
        print(f'  key {",".join(k)}: repetitions {len(a)} | {len(b)}')
        for c in co:
            if c in keys or c in skip:
                continue
            sa, sb = sorted({r[c] for r in a}), sorted({r.get(c, '') for r in b})
            ma, mb = {MS.sub('<ms>', x) for x in sa}, {MS.sub('<ms>', x) for x in sb}
            if sa == sb:
                v = 'same'
            elif TIMING.search(c):
                v = 'timing'
            elif set(sb) < set(sa):
                v = 'within'
            elif ma == mb or mb < ma:
                v = 'timing'
            else:
                v = 'DIFFERS'
            tot[v] += 1
            row_tot[v] += 1
            print(f'    {v:8} {c}: {" / ".join(sa)} | {" / ".join(sb)}')
    print(f'  # this row: same={row_tot["same"]} within={row_tot["within"]} timing={row_tot["timing"]} DIFFERS={row_tot["DIFFERS"]}')
print(f'# cells: same={tot["same"]} within={tot["within"]} timing={tot["timing"]} DIFFERS={tot["DIFFERS"]}; rows missing: {tot["rows-missing"]}')

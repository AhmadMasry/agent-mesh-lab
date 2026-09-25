"""Follow-ups 23: the walkthrough's six Experiment A rows beside the entry that re-measured each on this topology
(experiments/runs/2026-09-20-experiment-a-agentgateway-only/<row>/summary.csv, twenty repetitions per row).

The walkthrough runs each row at two repetitions (one on the egress row), so a column cannot be compared as a
multiset. It is compared as the SET of its distinct values over the row's repetitions, after masking identifiers only
(the patterns and rule of experiments/runs/2026-09-25-currency-rebuild/drivers/cellcompare.py: UUIDs, 32- and 16-hex
ids, IPv4 addresses with ports, pod-name suffixes, and the two runs' RUN_ID tokens) and the repetition number at the
end of a work-item id. A column is "same" when the two sets are equal; otherwise "DIFFERS", both sets printed.
Reads files only. usage: compare-rows.py <walk run dir>"""
import csv, re, sys, collections
WALK = sys.argv[1]
OLD = 'experiments/runs/2026-09-20-experiment-a-agentgateway-only'
ROWS = [('a1-m1-go', 'mode,receiver,path', '002740', 'wta1'),
        ('a2-go-http-503', 'client,layer', '020556', 'wta2'),
        ('a3-baseline-go', 'receiver,run,sub', '022306', 'wta3b'),
        ('a3-r1-go-http', 'receiver,run,sub', '024648', 'wta3r1'),
        ('a3-egress-go', 'receiver,run,sub', '045639', 'wta3e'),
        ('a3-r2-py-service', 'receiver,run,sub', '053247', 'wta3s')]
PATS = [(re.compile(r'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'), '<uuid>'),
        (re.compile(r'\b[0-9a-f]{32}\b'), '<id32>'), (re.compile(r'\b[0-9a-f]{16}\b'), '<id16>'),
        (re.compile(r'\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}(:\d+)?\b'), '<ip>'),
        (re.compile(r'-[0-9a-f]{8,10}-[0-9a-z]{5}\b'), '-<pod>')]
def mask(v, rids):
    for r in rids: v = v.replace(r, '<run>')
    v = re.sub(r'<run>-\d\d\b', '<run>-<rep>', v)
    for p, r in PATS: v = p.sub(r, v)
    return v
def load(p, keys, rids):
    g = collections.defaultdict(list); cols = None
    for r in csv.DictReader(open(p)):
        if not any(r.values()): continue
        cols = cols or list(r.keys())
        g[tuple(r[k] for k in keys)].append({c: mask(r.get(c) or '', rids) for c in r})
    return g, cols
tot = collections.Counter()
for row, keys, rid_old, rid_new in ROWS:
    keys = keys.split(',')
    go, co = load(f'{OLD}/{row}/summary.csv', keys, [rid_old, rid_new])
    gn, cn = load(f'{WALK}/{row}/summary.csv', keys, [rid_old, rid_new])
    print(f'## {row}: {OLD}/{row}/summary.csv | {WALK}/{row}/summary.csv')
    if co != cn: print(f'  columns differ: {co} | {cn}')
    for k in sorted(set(go) | set(gn)):
        a, b = go.get(k, []), gn.get(k, [])
        print(f'  key {",".join(k)}: repetitions {len(a)} | {len(b)}')
        for c in co:
            if c in keys: continue
            sa, sb = sorted({r[c] for r in a}), sorted({r[c] for r in b})
            v = 'same' if sa == sb else 'DIFFERS'
            tot[v] += 1
            print(f'    {v:8} {c}: {" / ".join(sa)} | {" / ".join(sb)}')
print(f'# cells: same={tot["same"]} DIFFERS={tot["DIFFERS"]}')

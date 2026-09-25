"""Cell-by-cell comparison of two per-repetition CSVs (a committed entry's and this re-count's), grouped by the key
columns, each column compared as the distribution of its values over the group's repetitions.

Identifiers only are masked, never a whole field: UUIDs, 32- and 16-hex trace/span ids, IPv4 addresses (and their
ports), pod-name suffixes (-<hash>-<5 chars>), and the two runs' own RUN_ID tokens given on the command line. A column
is "same" when the masked multiset of its values is equal on both sides; otherwise "differs", both sides printed
(value counts, or min-max over the repetitions for a numeric column). Nothing is judged here: a differing cell keeps
that verdict and its cause is written beside it by hand in the record.

usage: cellcompare.py <old.csv> <new.csv> <key,cols> <old-runid> <new-runid> [<skip-cols>]"""
import csv, re, sys, collections
old, new, keys, rid_old, rid_new = sys.argv[1:6]
skip = set(sys.argv[6].split(',')) if len(sys.argv) > 6 and sys.argv[6] else set()
keys = keys.split(',')
PATS = [(re.compile(r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'), '<uuid>'),
        (re.compile(r'\b[0-9a-f]{32}\b'), '<id32>'), (re.compile(r'\b[0-9a-f]{16}\b'), '<id16>'),
        (re.compile(r'\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}(:\d+)?\b'), '<ip>'),
        (re.compile(r'-[0-9a-f]{8,10}-[0-9a-z]{5}\b'), '-<pod>')]
def mask(v):
    v = v.replace(rid_old, '<run>').replace(rid_new, '<run>')
    for p, r in PATS: v = p.sub(r, v)
    return v
def load(p):
    rows = [r for r in csv.DictReader(open(p)) if any(r.values())]
    g = collections.defaultdict(list)
    for r in rows: g[tuple(r.get(k, '') for k in keys)].append(r)
    return g, (list(rows[0].keys()) if rows else [])
go, co = load(old); gn, cn = load(new)
cols = [c for c in co if c not in keys and c not in skip]
extra = [c for c in cn if c not in co]
def num(x):
    try: return float(x)
    except: return None
def summ(vals):
    ns = [num(v) for v in vals]
    if vals and all(n is not None for n in ns): return f'{min(ns):g}..{max(ns):g} (n={len(vals)})'
    c = collections.Counter(vals); return ' | '.join(f'{k}: {n}' for k, n in sorted(c.items(), key=lambda x: -x[1]))
tot = collections.Counter()
for k in sorted(set(go) | set(gn)):
    a, b = go.get(k, []), gn.get(k, [])
    print(f'## {"/".join(k)}: repetitions {len(a)} | {len(b)}')
    for c in cols:
        va = [mask(r.get(c, '')) for r in a]; vb = [mask(r.get(c, '')) for r in b]
        v = 'same' if collections.Counter(va) == collections.Counter(vb) else 'differs'
        tot[v] += 1
        print(f'  {v:8} {c}: {summ(va)}' + ('' if v == 'same' else f'\n  {"":8} {" " * len(c)}  -> {summ(vb)}'))
if extra: print('## columns only in the re-count:', ', '.join(extra))
print(f'# cells: same={tot["same"]} differs={tot["differs"]}')

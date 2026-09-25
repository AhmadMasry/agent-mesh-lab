#!/usr/bin/env python3
# Follow-on D-5: every count in the entries, from this run directory alone -> counts.txt.
#   python3 counts.py > counts.txt        (run from this directory)
# Stamps are parsed from ztunnel's lines and from the driver's own date -u stamps; no figure is taken from an
# agentgateway access-line timestamp (#3369 at v1.5.0), and an agentgateway line is joined by its trace id and its
# fields only.
import collections, datetime, glob, json, os, re

def ts(s):
    s = s.rstrip('Z')
    if '.' in s:
        a, b = s.split('.')
        s = a + '.' + (b + '000000')[:6]
        return datetime.datetime.strptime(s, '%Y-%m-%dT%H:%M:%S.%f')
    return datetime.datetime.strptime(s, '%Y-%m-%dT%H:%M:%S')

def kv(line, key):
    m = re.search(r'(?:^|\s)' + re.escape(key) + r'=("([^"]*)"|(\S+))', line)
    if not m:
        return None
    return m.group(2) if m.group(2) is not None else m.group(3)

def lines(path):
    if not os.path.exists(path):
        return []
    with open(path) as f:
        return [l.rstrip('\n') for l in f if l.strip()]

def jsonl(path):
    out = []
    for l in lines(path):
        try:
            out.append(json.loads(l))
        except ValueError:
            pass
    return out

def counters(path):
    agg = collections.Counter()
    for l in lines(path):
        if 'value=' not in l:
            continue
        agg[(kv(l, 'reporter'), kv(l, 'src'), kv(l, 'dst'), kv(l, 'security'))] += int(kv(l, 'value'))
    return agg

LEGS = [('destination', 'agw-central', 'worker', 'mutual_tls'), ('destination', 'agw-central', 'orchestrator', 'mutual_tls'),
        ('destination', 'agw-central', 'worker', 'unknown'), ('destination', 'agw-central', 'orchestrator', 'unknown'),
        ('destination', 'agentgateway-ingress', 'worker', 'mutual_tls'), ('destination', 'agentgateway-ingress', 'orchestrator', 'mutual_tls')]

def legname(k):
    return '%s->%s %s (%s)' % (k[1], k[2], k[3], k[0])

print('# D-5 counts, from the run directory alone (counts.py).')
print()
print('## Step 2.1, the connection count: one set per phase, 8 curl requests from a probe under lab/sa/loadgen')
for phase in ('unmarked', 'marked', 'removed'):
    D = 'conn-' + phase
    w = dict(x.split('=') for x in open(os.path.join(D, 'window.txt')).read().split())
    o, c = ts(w['set_open']), ts(w['set_close'])
    print('### %s: set %s .. %s (%.3f s)' % (phase, w['set_open'], w['set_close'], (c - o).total_seconds()))
    pre, post, idle = (counters(os.path.join(D, 'counters-%s.txt' % x)) for x in ('pre', 'post', 'idle'))
    for k in LEGS:
        if pre[k] or post[k] or idle[k]:
            print('  counter %-52s pre=%d post=%d idle=%d  set delta=%d, after 100 s quiet +%d' % (legname(k), pre[k], post[k], idle[k], post[k] - pre[k], idle[k] - post[k]))
    for wi in sorted(glob.glob(os.path.join(D, 'd5c-*'))):
        cl = jsonl(os.path.join(wi, 'client.jsonl'))
        card = ''
        try:
            card = json.dumps([i.get('url') for i in json.load(open(os.path.join(wi, 'card.json'))).get('supportedInterfaces', [])])
        except (ValueError, OSError):
            card = '<no card>'
        states = collections.Counter(e.get('state') for e in jsonl(os.path.join(wi, 'execution.jsonl')) if e.get('event') == 'state')
        print('  %s: %s; ledgers ingress=%d execution=%d invocation=%d; final states %s; card interfaces %s' % (
            os.path.basename(wi), ' '.join('%s=%s/exit%s' % (x['op'], x['http_status'], x['exit_code']) for x in cl),
            len(lines(os.path.join(wi, 'ingress.jsonl'))), len(lines(os.path.join(wi, 'execution.jsonl'))), len(lines(os.path.join(wi, 'invocation.jsonl'))),
            dict(states), card))
    acc = collections.Counter()
    for l in lines(os.path.join(D, 'agw-central-access-set.txt')):
        acc[(kv(l, 'route'), kv(l, 'http.method'), kv(l, 'http.status'), kv(l, 'protocol'), kv(l, 'a2a.method'), (kv(l, 'src.identity') or '').split('/sa/')[-1])] += 1
    for k, v in sorted(acc.items(), key=lambda x: str(x)):
        print('  agw-central line x%d route=%s %s %s protocol=%s a2a.method=%s src sa=%s' % ((v,) + k))

print()
print('### the joined ztunnel lines (conn-join/ztunnel-window.txt): every inbound connection line from a proxy to an agent')
bursts = []
for phase in ('unmarked', 'marked', 'removed'):
    for l in lines('conn-%s/phases.txt' % phase):
        if ' reset http://worker' in l:
            bursts.append((ts(l.split()[0]), 'reset at the start of conn %s (control pod, lab/sa/default)' % phase))
    w = dict(x.split('=') for x in open('conn-%s/window.txt' % phase).read().split())
    bursts.append((ts(w['set_open']), 'set %s' % phase))
for l in lines('trial/phases.txt'):
    if ' reset http://worker' in l:
        bursts.append((ts(l.split()[0]), 'reset in the trial phase'))
bursts.sort()
for l in lines('conn-join/ztunnel-window.txt'):
    if 'connection complete' not in l or 'direction="inbound"' not in l:
        continue
    sw, dw = kv(l, 'src.workload') or '', kv(l, 'dst.workload') or ''
    if not (sw.startswith('agw-central') or sw.startswith('agentgateway-ingress')) or not (dw.startswith('worker') or dw.startswith('orchestrator')):
        continue
    close = ts(l.split()[1])
    dur = int(kv(l, 'duration').rstrip('ms'))
    opened = close - datetime.timedelta(milliseconds=dur)
    near = [b for b in bursts if abs((b[0] - opened).total_seconds()) <= 5]
    print('  opened %s closed %s dur %6.1f s %s -> %s src %s sent=%s recv=%s %s; burst within 5 s of the open: %s' % (
        opened.isoformat() + 'Z', close.isoformat() + 'Z', dur / 1000.0, sw.split('-')[0] if sw.startswith('agw') else 'agentgateway-ingress', dw.split('-')[0],
        kv(l, 'src.addr'), kv(l, 'bytes_sent'), kv(l, 'bytes_recv'), ('error=' + kv(l, 'error')) if kv(l, 'error') else 'no error',
        '; '.join(b[1] for b in near) or 'NONE'))

print()
print('## Step 2.2, the A2A backend type as a trial (trial/)')
rows = collections.OrderedDict()
for d in sorted(glob.glob('trial/d5t-*-t22-[0-9]')):
    rows.setdefault(os.path.basename(d).split('-')[1], []).append(d)
names = {'a': '(a) JSON-RPC, ingress by Host worker.lab.internal, CLIENT_DIAL=target', 'b': '(b) JSON-RPC, worker Service, card-following',
         'c': '(c) JSON-RPC, orchestrator Service, card-following', 'di': '(d) REST, ingress by Host, CLIENT_DIAL=target',
         'dc': '(d) REST, worker Service, card-following', 'e': '(e) gRPC, ingress by Host, authority worker-grpc.lab.internal',
         'f': '(f) the orchestrator forward: JSON-RPC to the ingress catch-all'}
for r in ('a', 'b', 'c', 'di', 'dc', 'e', 'f'):
    res = collections.Counter(); led = collections.Counter(); pl = collections.Counter()
    for d in rows.get(r, []):
        end = [x for x in jsonl(os.path.join(d, 'client.jsonl')) if x.get('error') is not None or x.get('result_kind')]
        res[end[-1].get('error') or end[-1].get('state') if end else '<no end line>'] += 1
        for n in ('ingress', 'execution', 'invocation'):
            led[n] += len(lines(os.path.join(d, n + '.jsonl')))
        for proxy, f in (('ingress', 'ingress-access.txt'), ('agw-central', 'agw-central-access.txt')):
            for l in lines(os.path.join(d, f)):
                pl[(proxy, kv(l, 'route'), kv(l, 'http.method'), kv(l, 'http.path'), kv(l, 'http.host'), kv(l, 'http.status'), kv(l, 'protocol'),
                    (kv(l, 'src.identity') or '<none>').split('/sa/')[-1], kv(l, 'reason'), kv(l, 'error'))] += 1
    print('### %s: %d repetitions' % (names[r], len(rows.get(r, []))))
    for k, v in res.items():
        print('  client: %d x %s' % (v, k))
    print('  ledgers: arrivals=%d execution lines=%d invocations=%d' % (led['ingress'], led['execution'], led['invocation']))
    for k, v in sorted(pl.items(), key=lambda x: str(x)):
        print('  %s line x%d route=%s %s %s host=%s status=%s protocol=%s src sa=%s reason=%s error=%s' % ((k[0], v) + k[1:]))
print('### the four card GETs by curl while the backend type was in force')
for d in sorted(glob.glob('trial/d5t-cards-*')):
    cl = jsonl(os.path.join(d, 'client.jsonl'))
    body = open(os.path.join(d, 'card.json')).read().strip() if os.path.exists(os.path.join(d, 'card.json')) else ''
    print('  %s: %s; body %r' % (os.path.basename(d), ' '.join('%s http=%s exit=%s' % (x['op'], x['http_status'], x['exit_code']) for x in cl), body[:120]))
print('### both proxies over the whole window (trial/*-in-force-with-cards.txt)')
for proxy in ('agw-central', 'ingress'):
    c = collections.Counter()
    for l in lines('trial/%s-access-in-force-with-cards.txt' % proxy):
        c[(kv(l, 'route'), kv(l, 'http.status'), kv(l, 'protocol'), kv(l, 'reason'), (kv(l, 'src.identity') or '<none>').split('/sa/')[-1])] += 1
    for k, v in sorted(c.items(), key=lambda x: str(x)):
        print('  %s x%d route=%s status=%s protocol=%s reason=%s src sa=%s' % ((proxy, v) + k))
z = collections.Counter()
for l in lines('trial/ztunnel-in-force-with-cards.txt'):
    if 'connection complete' in l and (kv(l, 'src.workload') or '').startswith('agw-central') and ':8080' in (kv(l, 'dst.addr') or ''):
        z[((kv(l, 'dst.workload') or '').split('-')[0], kv(l, 'src.identity') or '<no src.identity>', kv(l, 'error'))] += 1
print('### ztunnel: connections from agw-central to an agent pod on 8080 (plaintext, not 15008) in the window')
for k, v in z.items():
    print('  x%d dst=%s src.identity=%s error=%s' % ((v,) + k))
b, a = counters('trial/counters-before.txt'), counters('trial/counters-in-force.txt')
print('### counters, before the apply and after the 21 Jobs (before the four curl card GETs)')
for k in LEGS:
    if b[k] or a[k]:
        print('  %-52s before=%d in-force=%d delta=%d' % (legname(k), b[k], a[k], a[k] - b[k]))
print('### traces, read by the trace id of every proxy request line in the window (trial/traces/by-id)')
tc = collections.Counter()
for f in sorted(glob.glob('trial/traces/by-id/*.json')):
    d = json.load(open(f))['data'][0]
    svc = collections.Counter(d['processes'][s['processID']]['serviceName'] for s in d['spans'])
    tc[', '.join('%s=%d' % x for x in sorted(svc.items()))] += 1
for k, v in tc.items():
    print('  %d traces: %s' % (v, k))
print('### the dumps and the removal')
for l in lines('trial/dumps-applied.txt'):
    if l.startswith('agw-central') or l.startswith('agentgateway-ingress') or 'a2a' in l:
        print('  applied: ' + l.strip()[:240])
for l in lines('trial/phases.txt'):
    if 'restored' in l or 'DIFFERS' in l or 'after removal' in l:
        print('  ' + l.split(' ', 1)[1])
print('### the clean check after removal (clean-after/summary.csv)')
for l in lines('clean-after/summary.csv'):
    print('  ' + l)

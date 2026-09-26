"""Follow-ups 24: D-1's header reading beside its entry, as the set of header names each arrival carried.

D-1's headers.sh writes each receiver's ingress ledger with the headers reading on (<app>-ingress.jsonl); its entry reads
which request headers reach each application, per arrival kind. This prints, for both directories, one line per
(receiver, arrival kind) with the sorted set of header names its arrivals carried and the authorization_present value,
and marks each line same or DIFFERS between the two. The arrival kind is the JSON-RPC method, or the card GET when the
method is empty. Reads files only. usage: compare-headers.py <entry headers dir> <walk headers dir>"""
import json
import sys


def load(d):
    out = {}
    for app in ('worker', 'orchestrator'):
        for l in open(f'{d}/{app}-ingress.jsonl'):
            try:
                x = json.loads(l)
            except ValueError:
                continue
            if x.get('phase') != 'arrival' or not x.get('headers'):
                continue
            k = (app, x.get('method') or 'GET /.well-known/agent-card.json', str(x['headers'].get('authorization_present')))
            out.setdefault(k, set()).add(','.join(sorted(x['headers'].get('names', []))))
    return out


a, b = load(sys.argv[1]), load(sys.argv[2])
tot = {'same': 0, 'DIFFERS': 0}
for k in sorted(set(a) | set(b)):
    v = 'same' if a.get(k) == b.get(k) else 'DIFFERS'
    tot[v] += 1
    print(f'{v:8} {k[0]} {k[1]} authorization_present={k[2]}: {" / ".join(sorted(a.get(k, []))) or "-"} | {" / ".join(sorted(b.get(k, []))) or "-"}')
print(f'# header-name sets per receiver and arrival kind: same={tot["same"]} DIFFERS={tot["DIFFERS"]}')

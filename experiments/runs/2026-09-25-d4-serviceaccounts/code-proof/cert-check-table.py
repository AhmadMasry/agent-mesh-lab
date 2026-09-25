# The certificate check's program, read from the five scripts and from make -n step-3, run on
# synthetic istioctl ztunnel-config certificates tables. usage: python3 cert-check-table.py (from the checkout's top)
import re, subprocess
progs = {}
for f in ['experiments/gate2-a1.sh', 'experiments/gate2-a2.sh', 'experiments/gate3-gateway-retry-mechanics.sh',
          'experiments/gate3-matrix.sh', 'experiments/gate3-trace-per-work-item.sh']:
    for p in re.findall(r"awk '(\$2 == \"Leaf\".*?)'", open(f).read()):
        progs.setdefault(p, []).append(f)
mk = subprocess.run(['make', '-n', 'step-3'], capture_output=True, text=True).stdout
for p in re.findall(r"awk '(\$2 == \"Leaf\".*?)'", mk):
    progs.setdefault(p, []).append('Makefile (make -n step-3)')
print(len(progs), 'distinct program(s), occurrences:', {k: len(v) for k, v in progs.items()})
prog = list(progs)[0]
hdr = 'CERTIFICATE NAME  TYPE  STATUS  VALID CERT  SERIAL NUMBER  NOT AFTER  NOT BEFORE\n'
def row(sa, typ, valid):
    return f'spiffe://cluster.local/ns/lab/sa/{sa}  {typ}  Available  {valid}  1a2b  2026-09-27T03:48:06Z  2026-09-20T03:46:06Z\n'
cases = [('only-default', 'fail', [('default', 'Leaf', 'true'), ('default', 'Root', 'true')]),
         ('both-valid', 'pass', [('worker', 'Leaf', 'true'), ('orchestrator', 'Leaf', 'true'), ('worker', 'Root', 'true')]),
         ('worker-only', 'fail', [('worker', 'Leaf', 'true'), ('default', 'Leaf', 'true')]),
         ('orchestrator-not-valid', 'fail', [('worker', 'Leaf', 'true'), ('orchestrator', 'Leaf', 'false')]),
         ('roots-only', 'fail', [('worker', 'Root', 'true'), ('orchestrator', 'Root', 'true')]),
         ('suffix-mismatch', 'fail', [('worker', 'Leaf', 'true'), ('orchestratorx', 'Leaf', 'true')]),
         ('with-loadgen-and-default', 'pass', [('loadgen', 'Leaf', 'true'), ('worker', 'Leaf', 'true'),
                                               ('orchestrator', 'Leaf', 'true'), ('default', 'Leaf', 'false')])]
bad = 0
for name, want, rows in cases:
    rc = subprocess.run(['awk', prog], input=hdr + ''.join(row(*r) for r in rows), text=True).returncode
    got = 'pass' if rc == 0 else 'fail'
    bad += got != want
    print(f'{name}: want={want} got={got} rc={rc}')
print('wrong:', bad)

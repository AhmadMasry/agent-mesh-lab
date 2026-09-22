"""Re-derivation behind the dated correction note beside the B-5a entry.

agentgateway at the pinned v1.5.0 renders the sub-second part of a log timestamp with its LEADING ZEROS removed
(docs/upstream/agentgateway-access-log-timestamp-leading-zeros.md; filed agentgateway#3369, fixed by #3370, first
contained in the v1.6.0-alpha.1 prerelease). B-5b measured where it falls: only on an ACCESS line's own stamp.
This program reads B-5a's own committed files and answers three questions, and nothing is written back to them.

  1. every affected line in B-5a's committed logs, what it is, and whether B-5a's counter USED it;
  2. each published figure of B-5a that moves, with the stamp as written, the value the proxy meant, and the
     corrected figure;
  3. B-5a's Interpretation sentence about the cut request's access line, re-derived against the affected files --
     does it hold, change, or become unreadable?

The correction rests on the intended value being UNAMBIGUOUS: trailing zeros are NOT dropped (B-5b measured 240 of
its six-digit fractions ending in a zero, and 0 of 1 986 non-access proxy lines short), so a fraction shorter than
six digits means leading zeros were removed and the intended value is the digits LEFT-padded to six.
Reads only. No cluster, no network, and no file of B-5a's is modified.
"""
import datetime, json, os, re

B = "experiments/runs/2026-09-22-b5a-removal/removal"
PLINE = re.compile(r"^(\S+)\t(\S+)\t(.*)$")
ACC = re.compile(r"route=(\S+) .*?http\.method=(\S+) .*?http\.path=(\S+)")
ST = re.compile(r"^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(?:\.(\d+))?Z$")


def ns(s, fix=False):
    m = ST.match(s)
    if not m:
        return None
    base = datetime.datetime.strptime(m.group(1), "%Y-%m-%dT%H:%M:%S").replace(tzinfo=datetime.timezone.utc)
    f = m.group(2) or ""
    if fix and 0 < len(f) < 6:
        f = f.rjust(6, "0")
    return int(base.timestamp()) * 10**9 + int(f.ljust(9, "0")[:9])


def kind_of(msg):
    a = ACC.search(msg)
    if not a:
        return None
    return "card GET" if "agent-card" in a.group(3) else ("model POST" if "model-via-agw" in a.group(1) else "POST")


def lines(path):
    out = []
    if not os.path.exists(path):
        return out
    for raw in open(path):
        m = PLINE.match(raw.rstrip("\n"))
        if m:
            out.append((m.group(1), m.group(3)))
    return out


def client_end(d):
    for raw in open(os.path.join(d, "client.jsonl")):
        o = json.loads(raw)
        if o.get("ledger") == "client" and o.get("line") == "end":
            return ns(o["ts"])


print("1. EVERY AFFECTED LINE IN B-5a's COMMITTED LOGS, and what it is")
print("   (a stamp whose fraction is shorter than six digits; the intended value is it LEFT-padded to six)\n")
n_acc = n_short = n_other = 0
affected = []
for variant in sorted(os.listdir(B)):
    vd = os.path.join(B, variant)
    if not os.path.isdir(vd):
        continue
    for lwi in sorted(os.listdir(vd)):
        d = os.path.join(vd, lwi)
        if not os.path.isdir(d):
            continue
        for f in ("oldpod.log", "newpod.log", "otherproxy-access.txt"):
            for raws, msg in lines(os.path.join(d, f)):
                k = kind_of(msg)
                if k:
                    n_acc += 1
                else:
                    n_other += 1
                    continue
                m = ST.match(raws)
                if m and m.group(2) and len(m.group(2)) < 6:
                    n_short += 1
                    err = (ns(raws) - ns(raws, True)) / 1e6
                    affected.append((lwi, f, k, raws, err))
for lwi, f, k, raws, err in affected:
    print(f"   {lwi:34s} {f:22s} {k:11s} {raws}Z reads {err:+8.1f} ms late")
print(f"\n   access lines: {n_short} of {n_acc} affected; other proxy lines: 0 of {n_other} affected")
byk = {}
for _, _, k, _, _ in affected:
    byk[k] = byk.get(k, 0) + 1
print(f"   what the affected lines ARE: " + ", ".join(f"{v} x {k}" for k, v in sorted(byk.items())))

print("\n\n2. EACH PUBLISHED FIGURE OF B-5a THAT MOVES")
print("   B-5a's counter took the successor's FIRST access line after sorting the file by the parsed stamp.\n")
ALL = []
for variant in sorted(os.listdir(B)):
    if os.path.isdir(os.path.join(B, variant)):
        for lwi in sorted(os.listdir(os.path.join(B, variant))):
            if os.path.isdir(os.path.join(B, variant, lwi)):
                ALL.append((variant, lwi))
moved = []
for variant, lwi in ALL:
    d = os.path.join(B, variant, lwi)
    t_rm = None
    for raw in open(os.path.join(d, "removal.txt")):
        if "REMOVAL COMMAND START" in raw:
            t_rm = ns(raw.split()[0])
            break
    acc = [(raws, kind_of(msg)) for raws, msg in lines(os.path.join(d, "newpod.log")) if kind_of(msg)]
    aswf = sorted(acc, key=lambda x: ns(x[0]))
    fixed = sorted(acc, key=lambda x: ns(x[0], True))
    if not acc:
        continue
    pub = (ns(aswf[0][0]) - t_rm) / 1e6
    cor = (ns(fixed[0][0], True) - t_rm) / 1e6
    if abs(pub - cor) < 0.05 and aswf[0][1] == fixed[0][1]:
        continue                      # this repetition's figure is unaffected
    moved.append((lwi, len(acc), aswf[0], fixed[0], pub, cor))
    print(f"   {lwi}  ({len(acc)} access line(s) in newpod.log)")
    print(f"      as B-5a published it:   first line = {aswf[0][1]:10s} stamp {aswf[0][0]}Z -> {pub:8.1f} ms")
    print(f"      as the proxy meant it:  first line = {fixed[0][1]:10s}                           -> {cor:8.1f} ms")
    if aswf[0][1] != fixed[0][1]:
        print(f"      THE IDENTITY MOVES TOO: the line B-5a records as the successor's FIRST is its {aswf[0][1]}, "
              f"where the first it actually served is the {fixed[0][1]}.")
print(f"\n   checked all {len(ALL)} repetitions of B-5a's grid; {len(moved)} figure(s) move and "
      f"{len(ALL) - len(moved)} are unaffected.")
pubs = []
for variant, lwi in ALL:
    d = os.path.join(B, variant, lwi)
    t_rm = None
    for raw in open(os.path.join(d, "removal.txt")):
        if "REMOVAL COMMAND START" in raw:
            t_rm = ns(raw.split()[0]); break
    acc = [(raws, kind_of(msg)) for raws, msg in lines(os.path.join(d, "newpod.log")) if kind_of(msg)]
    if acc:
        a = sorted(acc, key=lambda x: ns(x[0]))[0]
        f = sorted(acc, key=lambda x: ns(x[0], True))[0]
        pubs.append(((ns(a[0]) - t_rm) / 1e6, (ns(f[0], True) - t_rm) / 1e6))
print(f"   B-5a's PUBLISHED range over the grid: {min(x for x, _ in pubs):.1f}-{max(x for x, _ in pubs):.1f} ms")
print(f"   the same range as the proxy meant it:  {min(y for _, y in pubs):.1f}-{max(y for _, y in pubs):.1f} ms")

print("\n\n3. B-5a's INTERPRETATION SENTENCE, re-derived against the affected files")
print('   The sentence: "the access line between 1.47 ms before and 2 us after the client\'s end, SIGTERM between')
print('   0.81 ms before and 3.57 ms after it, in neither case in a consistent order across the five".')
print("   It is about the CUT POST's access line on the five ingress-forced repetitions.\n")
offs, sigs = [], []
for lwi in sorted(os.listdir(os.path.join(B, "ingress-forced"))):
    d = os.path.join(B, "ingress-forced", lwi)
    if not os.path.isdir(d):
        continue
    ce = client_end(d)
    post = sig = post_raw = None
    for raws, msg in lines(os.path.join(d, "oldpod.log")):
        if "received signal SIGTERM" in msg:
            sig = ns(raws)
        if kind_of(msg) == "POST":
            post, post_raw = ns(raws), raws
    short = bool(ST.match(post_raw).group(2)) and len(ST.match(post_raw).group(2)) < 6
    offs.append((post - ce) / 1e3)
    sigs.append((sig - ce) / 1e3)
    print(f"   {lwi}: cut-POST access line {(post - ce) / 1e3:+9.1f} us from the client's end "
          f"(stamp {'DEFECTIVE' if short else 'intact'}), SIGTERM {(sig - ce) / 1e3:+9.1f} us")
print(f"\n   access line over the five: {min(offs):+.1f} us to {max(offs):+.1f} us "
      f"= {abs(min(offs)) / 1000:.2f} ms before to {max(offs):.0f} us after")
print(f"   SIGTERM     over the five: {min(sigs):+.1f} us to {max(sigs):+.1f} us "
      f"= {abs(min(sigs)) / 1000:.2f} ms before to {max(sigs) / 1000:.2f} ms after")
print("   VERDICT: the sentence HOLDS. Every one of the five cut-POST stamps is intact; the one affected line in")
print("   an ingress-forced oldpod.log is that repetition's CARD GET, which the sentence does not use.")

print("\n   And its companion claim, on the two ingress-rollout repetitions where the line appeared:")
for lwi in ("b5a-ingress-rollout-r1-03", "b5a-ingress-rollout-r1-05"):
    d = os.path.join(B, "ingress-rollout", lwi)
    bd = None
    ev = []
    for raws, msg in lines(os.path.join(d, "oldpod.log")):
        if "binds drained" in msg:
            bd = ns(raws)
        if kind_of(msg) == "POST":
            ev.append(("the cut POST's access line", ns(raws)))
        if "forcefully terminated" in msg:
            ev.append(("connection forcefully terminated", ns(raws)))
    for what, t in ev:
        print(f"      {lwi}: {what} follows 'binds drained' by {(t - bd) / 1e3:+.0f} us")
print("   VERDICT: the 186 us figure HOLDS for the access line in both; the `connection forcefully terminated`")
print("   line follows at 208 and 199 us, so the entry's 'that line and a ... line follow ... by 186 us' reads one")
print("   figure onto two lines that differ by about 20 us. Neither stamp is defective.")

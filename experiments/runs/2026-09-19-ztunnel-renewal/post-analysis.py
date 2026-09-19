#!/usr/bin/env python3
"""Two readings added after the run, from its records only (standard library).

1. renewals-logstamp.csv: certificate stamps are whole seconds, so renewals.csv's residual carries up to 1 s of
   truncation. ztunnel's debug line "certificate fetch succeeded" (ztunnel-worker-identity.after-*) carries
   sub-second stamps from the node's clock. Each collected line has two: the first is the container runtime's
   (`kubectl logs --timestamps`), the second is ztunnel's own; on the 48 lines of this run they are at most
   0.343 ms apart, the runtime's the later. This script pairs the FIRST. For every renewal of renewals.csv it takes
   the line of the same identity whose stamp falls in [t_w, t_w + 1 s) and gives
   residual_log = t_fetch - D(t_w) - R_prev. t_fetch is when the fetched certificate was logged, a few ms after
   istiod signed it.
2. probe-by-validity.csv: every probe row placed against the tracked leaf's NOT BEFORE / NOT AFTER twice:
   by the HOST's clock at the probe (the clock istioctl's VALID CERT column uses), and by the GUEST's wall clock at
   that moment (the clock ztunnel and its peers judge a certificate by: research.md 1f), which is the host time
   minus the host-minus-guest offset of the nearest clock.csv sample of the worker node. The two differ only in the
   seconds after a wake, before the guest's wall clock is stepped.
"""
import calendar, csv, glob, os, re, sys, time
run = sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(os.path.abspath(__file__))
TRACK = "spiffe://cluster.local/ns/lab/sa/default"
iso = lambda s: float(calendar.timegm(time.strptime(s, "%Y-%m-%dT%H:%M:%SZ")))
utc = lambda t: time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t))
rows = lambda p: list(csv.DictReader(l for l in open(os.path.join(run, p), encoding="utf-8") if not l.startswith("#")))

fetch = {}                                     # identity -> sorted fetch stamps (guest clock, float)
# the driver writes these extracts as *.log, which the repository's .gitignore leaves out; the committed copies are *.txt
for p in sorted(glob.glob(os.path.join(run, "ztunnel-worker-identity.after-*.log")) + glob.glob(os.path.join(run, "ztunnel-worker-identity.after-*.txt"))):
    for line in open(p, encoding="utf-8", errors="replace"):
        if "certificate fetch succeeded" not in line:
            continue
        m = re.match(r"(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)\.(\d+)Z", line)
        ident = re.search(r"id=(spiffe://\S+)", line)
        if m and ident:
            fetch.setdefault(ident.group(1), set()).add(iso(m.group(1) + "Z") + float("0." + m.group(2)))
out = []
for r in rows("renewals.csv"):
    if r["kind"] != "renewal" or not r["D_s"]:
        continue
    t_w, d, r_prev = iso(r["t_w"]), float(r["D_s"]), iso(r["R_prev"])
    hit = [t for t in fetch.get(r["identity"], ()) if t_w <= t < t_w + 1.0]
    out.append({"arm": r["arm"], "identity": r["identity"], "R_prev": r["R_prev"], "t_w_cert": r["t_w"], "D_s": r["D_s"],
                "residual_cert_s": r["residual_s"], "t_fetch_log": f"{hit[0]:.6f}" if len(hit) == 1 else "",
                "fetch_minus_t_w_s": f"{hit[0] - t_w:.3f}" if len(hit) == 1 else "",
                "residual_log_s": f"{hit[0] - d - r_prev:.3f}" if len(hit) == 1 else ""})
with open(os.path.join(run, "renewals-logstamp.csv"), "w", newline="", encoding="utf-8") as f:
    w = csv.DictWriter(f, fieldnames=list(out[0]), lineterminator="\n"); w.writeheader(); w.writerows(out)
print("## residuals from the sub-second stamp of ztunnel's 'certificate fetch succeeded' line (the line's first stamp), per arm (min / median / max), and renewals paired")
import statistics
for arm in dict.fromkeys(o["arm"] for o in out):
    v = [float(o["residual_log_s"]) for o in out if o["arm"] == arm and o["residual_log_s"]]
    n = sum(1 for o in out if o["arm"] == arm)
    print(f"{arm:<7} paired {len(v)}/{n}  min {min(v):+.3f}  median {statistics.median(v):+.3f}  max {max(v):+.3f}")

leaves = {}
for r in rows("certs.csv"):
    if r["identity"] == TRACK and r["type"] == "Leaf" and r["serial"]:
        leaves[r["serial"]] = (iso(r["not_before"]), iso(r["not_after"]), float(r["host_epoch"]) if r["serial"] not in leaves else leaves[r["serial"]][2])
first_seen = {}
for r in rows("certs.csv"):
    if r["identity"] == TRACK and r["type"] == "Leaf" and r["serial"]:
        first_seen.setdefault(r["serial"], float(r["host_epoch"]))
order = sorted(first_seen, key=first_seen.get)
clock = [r for r in rows("clock.csv") if r["node"].endswith("-worker") and r["rc"] == "0" and r["guest_wall_1"]]
def guest_wall(t):
    """The guest's wall clock at host time t, from the nearest clock sample of the worker node."""
    near = min(clock, key=lambda r: abs(float(r["host_before"]) - t))
    return t - (float(near["host_before"]) - float(near["guest_wall_1"]))
res = []
for p in rows("probe.csv"):
    t = float(p["host_epoch"])
    g = guest_wall(t)
    cur = [s for s in order if first_seen[s] <= t]
    if not cur:
        by_host = by_guest = "before the first reading"
    else:
        nb, na, _ = leaves[cur[-1]]
        by_host = "valid" if nb < t < na else "expired"
        by_guest = "valid" if nb < g < na else "expired"
    res.append({"host_utc": p["host_utc"], "guest_wall_utc": utc(g), "arm": p["arm"], "leaf_by_host_clock": by_host,
                "leaf_by_guest_clock": by_guest, "rc": p["rc"], "http_code": p["http_code"], "time_total": p["time_total"]})
with open(os.path.join(run, "probe-by-validity.csv"), "w", newline="", encoding="utf-8") as f:
    w = csv.DictWriter(f, fieldnames=list(res[0]), lineterminator="\n"); w.writeheader(); w.writerows(res)
print("\n## probe rows by arm, the tracked leaf's validity by the host's clock and by the guest's, exit code and HTTP code")
count = {}
for r in res:
    k = (r["arm"], r["leaf_by_host_clock"], r["leaf_by_guest_clock"], r["rc"], r["http_code"]); count[k] = count.get(k, 0) + 1
for k in sorted(count):
    print(f"{k[0]:<8} host clock: {k[1]:<8} guest clock: {k[2]:<8} rc={k[3]:<4} http={k[4]:<4} rows {count[k]}")
print(f"past NOT AFTER by the host's clock: {sum(r['leaf_by_host_clock'] == 'expired' for r in res)}; by the guest's: {sum(r['leaf_by_guest_clock'] == 'expired' for r in res)}")
for r in res:
    if r["leaf_by_host_clock"] != r["leaf_by_guest_clock"]:
        print(f"differs: probe at host {r['host_utc']}, guest wall {r['guest_wall_utc']}: {r['leaf_by_host_clock']} by the host's clock, {r['leaf_by_guest_clock']} by the guest's")

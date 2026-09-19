#!/usr/bin/env python3
"""Derive renewals.csv and the per-arm summary from a run directory written by driver.sh.

Standard library only.

    derive-renewals.py RUN_DIR [--track-id ID --track-node NODE]
                       [--gate-arm C --max-abs-residual 5 --min-renewals 3]
                       [--step-threshold 0.5]

The model under test (research.md 1b): ztunnel fires a leaf's refresh at the wall time t where
t - D(t) = R, with R = NOT BEFORE + (NOT AFTER - NOT BEFORE)/2 of the leaf being replaced and
D(t) = (guest wall - guest monotonic)(t) - (guest wall - guest monotonic) at the first clock
sample after that ztunnel process started. For every change of serial this script computes

    R_prev   = NB_prev + (NA_prev - NB_prev) / 2
    t_w      = NB_next + 120 s         (istiod backdates NOT BEFORE by 2 min: generate_cert.go 283-285)
    D(t_w)   from clock.csv, on the guest's wall-clock axis, between the two samples that bracket t_w
    residual = t_w - D(t_w) - R_prev

and marks the residual "ambiguous" instead of guessing when the wall-minus-monotonic offset steps
between the two bracketing samples. A serial change that spans a recorded ztunnel (re)start
(anchors.csv) is a restart issuance, not a renewal, and has no residual.

Writes renewals.csv, d-series.csv, gaps-d.csv and summary.txt into RUN_DIR and prints the summary.
Exit codes: 0; 2 input error; 3 the --gate-arm check failed.
"""
import argparse
import calendar
import csv
import glob
import os
import re
import statistics
import sys
import time

BACKDATE = 120.0


def rows(path):
    if not os.path.exists(path):
        return []
    with open(path, newline="", encoding="utf-8") as f:
        return list(csv.DictReader(line for line in f if not line.startswith("#")))


def iso(s):
    return float(calendar.timegm(time.strptime(s, "%Y-%m-%dT%H:%M:%SZ")))


def utc(t):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t))


def fnum(s):
    try:
        return float(s)
    except (TypeError, ValueError):
        return None


def load_clock(run):
    """Per node: samples sorted by host time with wall (mid of the two guest reads) and both offsets."""
    per = {}
    for r in rows(os.path.join(run, "clock.csv")):
        w1, w2, mono, up = fnum(r["guest_wall_1"]), fnum(r["guest_wall_2"]), fnum(r["guest_mono_ns"]), fnum(r["guest_uptime_s"])
        hb, ha = fnum(r["host_before"]), fnum(r["host_after"])
        if r.get("rc") not in ("0", 0) or w1 is None or w2 is None or hb is None:
            continue
        wall = (w1 + w2) / 2.0
        per.setdefault(r["node"], []).append({
            "host": (hb + (ha if ha is not None else hb)) / 2.0, "host_before": hb, "wall": wall,
            "off_mono": wall - mono / 1e9 if mono is not None else None,
            "off_boot": wall - up if up is not None else None,
            "arm": r.get("arm", ""), "host_slept": fnum(r.get("host_slept_total_s")),
        })
    for v in per.values():
        v.sort(key=lambda s: s["host_before"])
    return per


def pick_source(samples):
    return "mono" if samples and all(s["off_mono"] is not None for s in samples) else "boot"


def anchor_for(anchors, node, host_t):
    """The latest recorded ztunnel (re)start on `node` at or before host time host_t (None: before any)."""
    best = None
    for a in anchors:
        if a["node"] == node and a["t"] <= host_t and (best is None or a["t"] > best["t"]):
            best = a
    return best


def anchor_offset(samples, src, anchor_t):
    for s in samples:
        if s["host_before"] >= anchor_t and s["off_" + src] is not None:
            return s["off_" + src], s
    return None, None


def d_at(samples, src, off0, anchor_t, t_w, step_threshold):
    """D at guest wall time t_w. Returns (D or None, status, D_lo, D_hi, bracket width in guest seconds)."""
    key = "off_" + src
    usable = [s for s in samples if s["host_before"] >= anchor_t and s[key] is not None]
    for a, b in zip(usable, usable[1:]):
        if a["wall"] <= t_w <= b["wall"]:
            lo, hi = a[key] - off0, b[key] - off0
            if abs(hi - lo) > step_threshold:
                return None, "ambiguous", lo, hi, b["wall"] - a["wall"]
            return (lo + hi) / 2.0, "ok", lo, hi, b["wall"] - a["wall"]
    return None, "no-bracket", None, None, None


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("run_dir")
    ap.add_argument("--track-id", default="spiffe://cluster.local/ns/lab/sa/default")
    ap.add_argument("--track-node", default="agent-mesh-lab-worker")
    ap.add_argument("--gate-arm")
    ap.add_argument("--max-abs-residual", type=float, default=5.0)
    ap.add_argument("--min-renewals", type=int, default=3)
    ap.add_argument("--step-threshold", type=float, default=0.5)
    args = ap.parse_args()
    run = args.run_dir

    all_cert_rows = rows(os.path.join(run, "certs.csv"))
    certs = [r for r in all_cert_rows if r.get("type") == "Leaf" and r.get("serial") and r.get("not_before") not in ("", "NA")]
    if not certs:
        print("no Leaf rows in certs.csv", file=sys.stderr)
        return 2
    clock = load_clock(run)
    anchors = [{"t": float(r["host_epoch"]), "node": r["node"], "reason": r["reason"], "pod": r["pod"]} for r in rows(os.path.join(run, "anchors.csv"))]
    arms = [{"arm": r["arm"], "start": float(r["start_epoch"]), "end": float(r["end_epoch"])} for r in rows(os.path.join(run, "arms.csv"))]
    gaps = [{"start": float(r["gap_start_epoch"]), "end": float(r["gap_end_epoch"]), "len": float(r["gap_s"]), "arm": r["arm"]} for r in rows(os.path.join(run, "gaps.csv"))]
    arm_order = []
    for r in certs:
        if r["arm"] not in arm_order:
            arm_order.append(r["arm"])

    # ---- leaves in order of first sight, per (node, identity)
    series = {}
    for r in sorted(certs, key=lambda r: float(r["host_epoch"])):
        k = (r["node"], r["identity"])
        lst = series.setdefault(k, [])
        t = float(r["host_epoch"])
        if not lst or lst[-1]["serial"] != r["serial"]:
            lst.append({"serial": r["serial"], "nb": iso(r["not_before"]), "na": iso(r["not_after"]),
                        "first_seen": t, "last_seen": t, "arm": r["arm"]})
        else:
            lst[-1]["last_seen"] = t

    out = []
    for (node, ident), leaves in sorted(series.items()):
        samples = clock.get(node, [])
        src = pick_source(samples)
        for prev, nxt in zip(leaves, leaves[1:]):
            r_prev = prev["nb"] + (prev["na"] - prev["nb"]) / 2.0
            t_w = nxt["nb"] + BACKDATE
            rec = {"node": node, "identity": ident, "arm": nxt["arm"], "prev_serial": prev["serial"], "next_serial": nxt["serial"],
                   "prev_not_before": utc(prev["nb"]), "prev_not_after": utc(prev["na"]), "R_prev": utc(r_prev),
                   "next_not_before": utc(nxt["nb"]), "t_w": utc(t_w), "first_seen": utc(nxt["first_seen"]),
                   "t_w_minus_R_s": f"{t_w - r_prev:.1f}", "expired_before_renewal_s": f"{max(0.0, t_w - prev['na']):.1f}",
                   "d_source": src, "D_s": "", "D_lo_s": "", "D_hi_s": "", "bracket_s": "", "residual_s": "", "status": "", "kind": "renewal",
                   "since_last_gap_end_s": ""}
            restarted = [a for a in anchors if a["node"] == node and prev["last_seen"] < a["t"] <= nxt["first_seen"]]
            if restarted:
                rec["kind"] = "restart"
                rec["status"] = "restart: " + restarted[-1]["reason"]
                out.append((rec, None, t_w))
                continue
            anc = anchor_for(anchors, node, nxt["first_seen"])
            anchor_t = anc["t"] if anc else (samples[0]["host_before"] if samples else 0.0)
            off0, _ = anchor_offset(samples, src, anchor_t)
            resid = None
            if off0 is None:
                rec["status"] = "no clock sample after the anchor"
            else:
                d, status, lo, hi, width = d_at(samples, src, off0, anchor_t, t_w, args.step_threshold)
                rec["status"] = status
                if lo is not None:
                    rec["D_lo_s"], rec["D_hi_s"], rec["bracket_s"] = f"{lo:.3f}", f"{hi:.3f}", f"{width:.1f}"
                if d is not None:
                    resid = t_w - d - r_prev
                    rec["D_s"], rec["residual_s"] = f"{d:.3f}", f"{resid:.3f}"
            before = [g for g in gaps if g["end"] <= nxt["first_seen"]]
            if before:
                rec["since_last_gap_end_s"] = f"{t_w - before[-1]['end']:.1f}"
            out.append((rec, resid, t_w))

    fields = ["arm", "node", "identity", "kind", "status", "prev_serial", "next_serial", "prev_not_before", "prev_not_after", "R_prev",
              "next_not_before", "t_w", "first_seen", "t_w_minus_R_s", "d_source", "D_s", "D_lo_s", "D_hi_s", "bracket_s", "residual_s",
              "expired_before_renewal_s", "since_last_gap_end_s"]
    with open(os.path.join(run, "renewals.csv"), "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=fields, lineterminator="\n")
        w.writeheader()
        for rec, _, _ in out:
            w.writerow(rec)

    # ---- D series, and D across each gap
    with open(os.path.join(run, "d-series.csv"), "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f, lineterminator="\n")
        w.writerow(["host_epoch", "host_utc", "node", "arm", "guest_wall", "host_minus_guest_wall_s", "off_mono", "off_boot", "D_mono_s", "D_boot_s", "anchor"])
        for node, samples in sorted(clock.items()):
            for s in samples:
                anc = anchor_for(anchors, node, s["host_before"])
                anchor_t = anc["t"] if anc else samples[0]["host_before"]
                om, _ = anchor_offset(samples, "mono", anchor_t)
                ob, _ = anchor_offset(samples, "boot", anchor_t)
                w.writerow([f"{s['host']:.3f}", utc(s["host"]), node, s["arm"], f"{s['wall']:.3f}", f"{s['host'] - s['wall']:.3f}",
                            "" if s["off_mono"] is None else f"{s['off_mono']:.3f}", "" if s["off_boot"] is None else f"{s['off_boot']:.3f}",
                            "" if s["off_mono"] is None or om is None else f"{s['off_mono'] - om:.3f}",
                            "" if s["off_boot"] is None or ob is None else f"{s['off_boot'] - ob:.3f}",
                            anc["reason"] if anc else "first sample"])
    gap_lines = []
    with open(os.path.join(run, "gaps-d.csv"), "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f, lineterminator="\n")
        w.writerow(["node", "gap_start_utc", "gap_end_utc", "gap_s", "d_source", "offset_before", "offset_after_settled", "D_growth_s",
                    "first_sample_after_wake_s", "guest_wall_behind_host_at_first_sample_s", "step_seen_after_wake_s", "host_slept_across_gap_s"])
        for node, samples in sorted(clock.items()):
            src = pick_source(samples)
            key = "off_" + src
            for g in gaps:
                pre = [s for s in samples if s["host_before"] <= g["start"] and s[key] is not None]
                post = [s for s in samples if s["host_before"] >= g["end"] and s[key] is not None]
                nxt_gap = min([x["start"] for x in gaps if x["start"] > g["end"]] + [float("inf")])
                post = [s for s in post if s["host_before"] < nxt_gap]
                if not pre or not post:
                    continue
                before = pre[-1][key]
                window = [s for s in post if s["host_before"] <= g["end"] + 180] or post[:1]
                settled = window[-1][key]
                stepped = next((s for s in post if s[key] - before > args.step_threshold and abs(s[key] - settled) <= args.step_threshold), None)
                row = [node, utc(g["start"]), utc(g["end"]), f"{g['len']:.0f}", src, f"{before:.3f}", f"{settled:.3f}", f"{settled - before:.3f}",
                       f"{post[0]['host_before'] - g['end']:.1f}", f"{post[0]['host'] - post[0]['wall']:.1f}",
                       "" if stepped is None else f"{stepped['host_before'] - g['end']:.1f}",
                       "" if pre[-1]["host_slept"] is None or window[-1]["host_slept"] is None else f"{window[-1]['host_slept'] - pre[-1]['host_slept']:.3f}"]
                w.writerow(row)
                gap_lines.append(row)

    # ---- summary
    L = []
    L.append(f"# derive-renewals.py over {run} at {utc(time.time())}")
    L.append(f"# model: residual = t_w - D(t_w) - R_prev; t_w = NOT BEFORE(next) + {BACKDATE:.0f}s; step threshold {args.step_threshold}s")
    for node, samples in sorted(clock.items()):
        L.append(f"# D source on {node}: {'CLOCK_MONOTONIC from /proc/timer_list' if pick_source(samples) == 'mono' else 'CLOCK_BOOTTIME from /proc/uptime (/proc/timer_list was not readable)'}; {len(samples)} clock samples")
    L.append("")
    L.append("## renewals per arm (kind=renewal; restart issuances listed apart)")
    L.append(f"{'arm':<8} {'node':<30} {'identity':<72} {'n':>3} {'ambig':>5} {'nobr':>4} {'min':>9} {'median':>9} {'max':>9} {'restart':>7}")
    for arm in arm_order:
        for (node, ident) in sorted(series):
            mine = [(rec, resid) for rec, resid, _ in out if rec["arm"] == arm and rec["node"] == node and rec["identity"] == ident]
            if not mine:
                continue
            ren = [(rec, resid) for rec, resid in mine if rec["kind"] == "renewal"]
            res = [resid for _, resid in ren if resid is not None]
            amb = sum(1 for rec, _ in ren if rec["status"] == "ambiguous")
            nobr = sum(1 for rec, _ in ren if rec["status"] not in ("ok", "ambiguous"))
            fmt = lambda v: f"{v:9.3f}"
            L.append(f"{arm:<8} {node:<30} {ident:<72} {len(ren):>3} {amb:>5} {nobr:>4} "
                     + (f"{fmt(min(res))} {fmt(statistics.median(res))} {fmt(max(res))}" if res else f"{'-':>9} {'-':>9} {'-':>9}")
                     + f" {sum(1 for rec, _ in mine if rec['kind'] == 'restart'):>7}")
    L.append("")
    L.append("## every renewal, in order")
    for rec, resid, _ in sorted(out, key=lambda x: (x[0]["node"], x[0]["identity"], x[2])):
        L.append(f"{rec['arm']:<8} {'cp' if rec['node'].endswith('control-plane') else 'worker':<7} {rec['identity'].split('/ns/')[-1]:<48} {rec['kind']:<8} R_prev={rec['R_prev']} t_w={rec['t_w']} "
                 f"t_w-R={rec['t_w_minus_R_s']:>8}s D={rec['D_s'] or '-':>10} residual={rec['residual_s'] or '-':>8} expired_before={rec['expired_before_renewal_s']:>8}s "
                 f"since_gap_end={rec['since_last_gap_end_s'] or '-':>8} {rec['status']}")
    L.append("")
    L.append("## minutes each leaf read VALID CERT false (sum of intervals between consecutive readings of at most 90 s whose earlier reading was false)")
    for arm in arm_order:
        for (node, ident) in sorted(series):
            rs = sorted((r for r in certs if r["arm"] == arm and r["node"] == node and r["identity"] == ident), key=lambda r: float(r["host_epoch"]))
            false_s, n_false = 0.0, 0
            for a, b in zip(rs, rs[1:]):
                dt = float(b["host_epoch"]) - float(a["host_epoch"])
                if a["valid"] != "true":
                    n_false += 1
                    if dt <= 90:
                        false_s += dt
            if rs and rs[-1]["valid"] != "true":
                n_false += 1
            L.append(f"{arm:<8} {node:<30} {ident:<72} readings {len(rs):>5}  false {n_false:>5}  minutes false {false_s / 60.0:7.1f}")
    L.append("")
    L.append("## readings that were not a Leaf row: identities with no certificate chain (TYPE NA), unparsed rows, failed reads")
    odd = {}
    for r in all_cert_rows:
        if r.get("type") == "Leaf" and not (r.get("status") or "").startswith("UNPARSED"):
            continue
        k = (r.get("arm", ""), r.get("node", ""), r.get("identity", ""), (r.get("type") or "-") + " " + (r.get("status") or "")[:40] + (" rc=" + r["rc"] if r.get("rc") not in ("0", "", None) else ""))
        odd[k] = odd.get(k, 0) + 1
    for k, v in sorted(odd.items()):
        L.append(f"{k[0]:<8} {k[1]:<30} {k[2]:<72} {k[3]}: {v}")
    if not odd:
        L.append("none")
    L.append("")
    L.append("## istiod CSR counters against issuances counted from serials (both nodes, every identity; restart issuances included)")
    L.append("## window per arm: from the last counter sample at or before the arm's start to the last one at or before its end; issuances counted by t_w in that window")
    counters = sorted((r for r in rows(os.path.join(run, "csr-counters.csv")) if r.get("csr_count")), key=lambda r: float(r["host_epoch"]))

    def issued_between(t0, t1):
        return sum(1 for _, _, t_w in out if t0 < t_w <= t1)

    for a in arms:
        upto_start = [r for r in counters if float(r["host_epoch"]) <= a["start"]]
        upto_end = [r for r in counters if float(r["host_epoch"]) <= a["end"]]
        c0 = upto_start[-1] if upto_start else next((r for r in counters if float(r["host_epoch"]) >= a["start"]), None)
        c1 = upto_end[-1] if upto_end else None
        if c0 is None or c1 is None or float(c1["host_epoch"]) <= float(c0["host_epoch"]):
            L.append(f"{a['arm']:<8} fewer than two counter samples span the arm")
            continue
        t0, t1 = float(c0["host_epoch"]), float(c1["host_epoch"])
        d1 = float(c1["csr_count"]) - float(c0["csr_count"])
        d2 = (float(c1["success_count"]) - float(c0["success_count"])) if c0.get("success_count") and c1.get("success_count") else float("nan")
        pods = sorted({r["istiod_pod"] for r in counters if t0 <= float(r["host_epoch"]) <= t1})
        L.append(f"{a['arm']:<8} csr_count {c0['csr_count']} -> {c1['csr_count']} (delta {d1:.0f}); success delta {d2:.0f}; serial changes with t_w in the window {issued_between(t0, t1)}; "
                 f"window {utc(t0)}..{utc(t1)}; istiod pod(s) {','.join(pods)}")
    if len(counters) >= 2:
        t0, t1 = float(counters[0]["host_epoch"]), float(counters[-1]["host_epoch"])
        L.append(f"{'whole':<8} csr_count {counters[0]['csr_count']} -> {counters[-1]['csr_count']} (delta {float(counters[-1]['csr_count']) - float(counters[0]['csr_count']):.0f}); "
                 f"serial changes with t_w in the window {issued_between(t0, t1)}; window {utc(t0)}..{utc(t1)}")
    L.append("")
    L.append("## D across each gap (gaps-d.csv)")
    for row in gap_lines:
        L.append(f"{row[0]:<30} gap {row[1]}..{row[2]} ({row[3]}s): D grew {row[7]}s ({row[4]}); first sample {row[8]}s after the wake with the guest wall clock {row[9]}s behind the host; step seen {row[10] or '-'}s after the wake; the host's own clocks put its sleep across the gap at {row[11] or '-'}s")
    if not gap_lines:
        L.append("no gap recorded")
    L.append("")
    L.append("## 'certificate fetch succeeded' lines in the collected ztunnel logs (whole-pod logs, cumulative per pod)")
    logs = sorted(glob.glob(os.path.join(run, "logs", "ztunnel-*.log")))
    for p in logs:
        per = {}
        with open(p, encoding="utf-8", errors="replace") as f:
            for line in f:
                if "certificate fetch succeeded" in line:
                    m = re.search(r"spiffe://[^\s\"',]+", line)
                    per[m.group(0) if m else "?"] = per.get(m.group(0) if m else "?", 0) + 1
        L.append(f"{os.path.basename(p)}: {sum(per.values())} " + " ".join(f"[{k.split('/ns/')[-1]}: {v}]" for k, v in sorted(per.items())))
    if not logs:
        L.append("no collected logs")

    rc = 0
    if args.gate_arm:
        L.append("")
        L.append(f"## gate over arm {args.gate_arm}")
        ren = [(rec, resid) for rec, resid, _ in out if rec["arm"] == args.gate_arm and rec["kind"] == "renewal"]
        tracked = [x for x in ren if x[0]["node"] == args.track_node and x[0]["identity"] == args.track_id]
        bad = [(rec, resid) for rec, resid in ren if resid is not None and abs(resid) > args.max_abs_residual]
        measured = [resid for _, resid in ren if resid is not None]
        falses = [r for r in certs if r["arm"] == args.gate_arm and r["valid"] != "true"]
        checks = [
            (len(tracked) >= args.min_renewals, f"renewals of {args.track_id} on {args.track_node}: {len(tracked)} (need >= {args.min_renewals})"),
            (len(measured) > 0 and not bad, f"residuals measured: {len(measured)}; beyond +/-{args.max_abs_residual}s: {len(bad)}" + "".join(f" [{rec['identity'].split('/ns/')[-1]} {resid:.3f}s]" for rec, resid in bad)),
            (not falses, f"VALID CERT false readings in the arm: {len(falses)}"),
        ]
        for ok, text in checks:
            L.append(("PASS  " if ok else "FAIL  ") + text)
            if not ok:
                rc = 3
        L.append("gate: " + ("passed" if rc == 0 else "FAILED"))

    text = "\n".join(L) + "\n"
    with open(os.path.join(run, "summary.txt"), "w", encoding="utf-8") as f:
        f.write(text)
    sys.stdout.write(text)
    return rc


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Write a hand-built run directory for derive-renewals.py with a known answer.

One identity on one node. The wall-minus-monotonic offset is constant, then steps by +1500 s
(a 1500 s host sleep), then by +600 s. Every refresh is placed exactly where the model puts it
(t_w - D(t_w) = R_prev), so every measurable residual must come out 0, with D = 0, then 1500.
The last renewal fires 11 s after the second wake while the guest's wall clock still lags (one
second before the step), so the step falls between the two clock samples that bracket it: that one must be reported "ambiguous"
with D_lo = 1500 and D_hi = 2100, not given a number.
"""
import sys, os, time
out = sys.argv[1]
os.makedirs(out, exist_ok=True)
T0, OFF0, NODE, ID = 1790100000, 1000000.0, "agent-mesh-lab-worker", "spiffe://cluster.local/ns/lab/sa/default"
iso = lambda t: time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t))
GAPS = [(T0 + 1000, T0 + 2500), (T0 + 6030, T0 + 6630)]      # host asleep; guest frozen
STEP_AT = [T0 + 2500, T0 + 6642]                              # host time at which the guest wall clock is stepped

def frozen(h): return sum(e - s for s, e in GAPS if e <= h)
def stepped(h): return sum(e - s for (s, e), at in zip(GAPS, STEP_AT) if at <= h)
def guest_wall(h): return h - (frozen(h) - stepped(h))
def asleep(h): return any(s < h < e for s, e in GAPS)

with open(os.path.join(out, "clock.csv"), "w") as f:
    f.write("host_before,host_after,node,guest_wall_1,guest_mono_ns,guest_uptime_s,guest_wall_2,arm,rc\n")
    for h in list(range(T0, T0 + 7000, 10)) + [T0 + 6635, T0 + 6645]:
        if asleep(h): continue
        w = guest_wall(h); mono = h - OFF0 - frozen(h)
        f.write(f"{h}.000000,{h}.200000,{NODE},{w}.100000000,{int(mono * 1e9) + 100000000},{mono + 0.1:.2f},{w}.100000000,{'C' if h < T0 + 1000 else 'T'},0\n")

# issuance host times, each where the model puts it; guest-wall stamps go into the certificate
issued = [T0 + 100, T0 + 340, T0 + 580, T0 + 820, T0 + 2560, T0 + 4300, T0 + 6641]
leaves = [(f"{i:032x}", guest_wall(h) - 120, guest_wall(h) + 600, h) for i, h in enumerate(issued, 1)]
with open(os.path.join(out, "certs.csv"), "w") as f:
    f.write("host_epoch,host_utc,arm,node,identity,type,status,valid,serial,not_after,not_before,rc\n")
    for h in range(T0 + 100, T0 + 7000, 30):
        if asleep(h): continue
        cur = [l for l in leaves if l[3] <= h][-1]
        valid = "true" if cur[1] < h < cur[2] else "false"
        f.write(f"{h},{iso(h)},{'C' if h < T0 + 1000 else 'T'},{NODE},{ID},Leaf,Available,{valid},{cur[0]},{iso(cur[2])},{iso(cur[1])},0\n")
with open(os.path.join(out, "gaps.csv"), "w") as f:
    f.write("gap_start_epoch,gap_end_epoch,gap_s,gap_start_utc,gap_end_utc,arm\n")
    for s, e in GAPS: f.write(f"{s},{e},{e - s},{iso(s)},{iso(e)},T\n")
print(f"fixture written to {out}: 6 serial changes; expected residuals 0,0,0 (D=0), 0,0 (D=1500), and one ambiguous (D 1500..2100)")

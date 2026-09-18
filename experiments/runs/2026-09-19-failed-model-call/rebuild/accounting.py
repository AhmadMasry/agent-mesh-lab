#!/usr/bin/env python3
"""Follow-ups 15: every second of the rebuild and of the proof readings, from the epochs their logs stamped.

build.txt: the header's start epoch, `## header reads: <s>`, and each make target's started/finished epochs.
checks.txt: each reading's started/finished epochs. Between two stamped intervals the gap is printed as a gap,
so a second no stamp covers shows up rather than being absorbed. Read-only.
"""
import re, sys
d = sys.argv[1]
b = open(f"{d}/build.txt").read()
t0 = float(re.search(r"\(epoch ([0-9.]+)\)", b).group(1))
hdr = float(re.search(r"## header reads: ([0-9.]+) s", b).group(1))
steps = re.findall(r"## make (\S+)  started \S+  epoch ([0-9.]+)\n(?:.*\n)*?## make \1  finished \S+  epoch ([0-9.]+)  exit=(\d+)", b)
te = float(re.search(r"# build finished \S+ \(epoch ([0-9.]+)\)", b).group(1))
print("# the build (build.txt)")
print(f"  header reads                       {hdr:9.3f} s  from epoch {t0:.3f}")
prev = t0 + hdr
total = hdr
for name, s, e, rc in steps:
    s, e = float(s), float(e)
    print(f"  gap                                {s - prev:9.3f} s  (status read and log lines)")
    print(f"  make {name:<29} {e - s:9.3f} s  exit={rc}")
    total += (s - prev) + (e - s)
    prev = e
print(f"  close                              {te - prev:9.3f} s  (after-status read and last line)")
total += te - prev
print(f"  sum                                {total:9.3f} s  against first-line-to-last {te - t0:.3f} s")
c = open(f"{d}/checks.txt").read()
reads = re.findall(r"## (.+?)  started \S+  epoch ([0-9.]+)\n(?:.*\n)*?## \1  finished \S+  epoch ([0-9.]+)  exit=(\d+)", c)
print()
print("# between the build and the readings")
first = float(reads[0][1])
print(f"  gap                                {first - te:9.3f} s  build end -> first reading")
print()
print("# the proof readings (checks.txt)")
prev = first
for label, s, e, rc in reads:
    s, e = float(s), float(e)
    if s - prev > 0:
        print(f"  gap                                {s - prev:9.3f} s")
    print(f"  {label[:34]:<34} {e - s:9.3f} s  exit={rc}")
    prev = e
print(f"  readings, first start to last end  {prev - first:9.3f} s")

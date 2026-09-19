"""Follow-ups 19, task 3: where the wall time of build.txt and checks.txt went, from the epochs the two logs print.

Every `## <label>  started <utc>  epoch <e>` / `## <label>  finished <utc>  epoch <e>  exit=<n>  wall=<s>s`
pair is a step; what lies between two steps is a gap. The build's sum is checked against its first line to its
last. Reads the two logs; touches no cluster.

  python3 accounting.py <build.txt> <checks.txt>
"""
import re
import sys

START = re.compile(r"^## (.+?)  started (\S+)  epoch ([\d.]+)$")
END = re.compile(r"^## (.+?)  finished (\S+)  epoch ([\d.]+)  exit=(\d+)  wall=([\d.]+)s$")


def steps(path):
    out, open_ = [], {}
    for line in open(path, errors="replace"):
        line = line.rstrip("\n")
        m = START.match(line)
        if m:
            open_[m.group(1)] = float(m.group(3))
            continue
        m = END.match(line)
        if m and m.group(1) in open_:
            out.append((m.group(1), open_.pop(m.group(1)), float(m.group(3)), int(m.group(4)), float(m.group(5))))
    return out


build, checks = sys.argv[1], sys.argv[2]
text = open(build, errors="replace").read()
t0 = float(re.search(r"^# Started \S+ \(epoch ([\d.]+)\)", text, re.M).group(1))
te = float(re.search(r"^# build finished \S+ \(epoch ([\d.]+)\); from the first line of this log ([\d.]+) s", text, re.M).group(1))
span = float(re.search(r"from the first line of this log ([\d.]+) s", text).group(1))
hdr = float(re.search(r"^## header reads: ([\d.]+) s", text, re.M).group(1))
print("# the build (build.txt)")
print("  %-58s %9.3f s  from epoch %.3f" % ("header reads", hdr, t0))
total, prev = hdr, t0 + hdr
for label, s, e, rc, wall in steps(build):
    print("  %-58s %9.3f s  (status reads and log lines)" % ("gap", s - prev)); total += s - prev
    print("  %-58s %9.3f s  exit=%d" % (label, wall, rc)); total += e - s
    prev = e
print("  %-58s %9.3f s  (after-status read and last line)" % ("close", te - prev)); total += te - prev
print("  %-58s %9.3f s  against first-line-to-last %.3f s" % ("sum", total, span))
print("  %-58s %9.3f s" % ("the seven targets alone", sum(w for _, _, _, _, w in steps(build))))
print()
cs = steps(checks)
print("# between the build and the readings")
print("  %-58s %9.3f s  build end -> first reading" % ("gap", cs[0][1] - te))
print()
print("# the readings (checks.txt), in the order taken; a gap of more than a second is this agent's own turn between two parts")
prev = None
for label, s, e, rc, wall in cs:
    if prev is not None:
        print("  %-58s %9.3f s" % ("gap", s - prev))
    print("  %-58s %9.3f s  exit=%d" % (label[:58], wall, rc))
    prev = e
print("  %-58s %9.3f s" % ("readings, first start to last end", cs[-1][2] - cs[0][1]))
print("  %-58s %9.3f s" % ("of it inside a reading", sum(e - s for _, s, e, _, _ in cs)))

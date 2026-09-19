"""Follow-ups 19, task 3, reading (a): the lines of a collector-style log at warn level or above, verbatim.

The OpenTelemetry Collector and Jaeger v2 (built on it) log `<stamp>\t<level>\t<caller>\t<message>\t<json>`;
the level is the second tab field. A line with no tab fields is tested by a whole-word match instead, so
nothing at those levels can hide in another format. Reads a file and writes a file; touches no cluster.

  python3 log-levels.py <log> <out.txt> <name>
"""
import re
import sys

src, out, name = sys.argv[1:4]
lines = open(src, errors="replace").read().splitlines()
LEVELS = ("warn", "warning", "error", "fatal", "panic", "dpanic")
hit, by_level = [], {}
for line in lines:
    f = line.split("\t")
    level = f[1].strip().lower() if len(f) > 2 else ""
    if level:
        by_level[level] = by_level.get(level, 0) + 1
    if level in LEVELS or (not level and re.search(r"\b(warn|warning|error|fatal|panic)\b", line, re.I)):
        hit.append(line)
with open(out, "w") as f:
    f.write("# %s: %d log lines since the container started (by level field: %s); %d at warn level or above. Each one, verbatim:\n" % (
        name, len(lines), ", ".join("%s=%d" % kv for kv in sorted(by_level.items())) or "no level field", len(hit)))
    f.write("\n".join(hit) + ("\n" if hit else ""))
print("%s: %d log lines (by level field: %s), %d at warn or above" % (
    name, len(lines), ", ".join("%s=%d" % kv for kv in sorted(by_level.items())) or "no level field", len(hit)))
for line in hit:
    print("   " + line[:600])

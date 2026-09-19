"""Follow-ups 19, task 3c, reading (f), second half: what each rebuild's log observed while `make orchestrator-image`
built the orchestrator image -- the base image digest, the uv image digest, the Amazon Linux release, the Python
package and the uv version -- this rebuild's build.txt beside task 3's. For each log: how many `docker build` lines,
how many of them carry --no-cache, and the DISTINCT values of each of the five, with how many lines carry each. Reads
two files; touches no cluster.

  python3 image-build-values.py <task-3 build.txt> <this build.txt>
"""
import collections
import re
import sys

PATTERNS = (
    ("base image digest (amazonlinux:2023@sha256)", re.compile(r"amazonlinux/amazonlinux:2023@(sha256:[0-9a-f]{64})")),
    ("uv image digest (ghcr.io/astral-sh/uv@sha256)", re.compile(r"ghcr\.io/astral-sh/uv:\S*@(sha256:[0-9a-f]{64})")),
    ("Amazon Linux release (system-release)", re.compile(r"system-release-(2023\.\d+\.\d{8}-\d+\.amzn2023)")),
    ("Python package", re.compile(r"(python3\.14-3\.14\.\d+-\d+\.amzn2023\.\d+\.\d+)\.aarch64\s*$")),
    ("uv inside the image", re.compile(r"^#\d+ [\d.]+ (uv \d+\.\d+\.\d+) \(\S*linux\S*\)")),
)


def read(path):
    builds = nocache = 0
    vals = {k: collections.Counter() for k, _ in PATTERNS}
    for line in open(path, errors="replace"):
        if line.startswith("docker build "):
            builds += 1
            nocache += "--no-cache" in line
        for k, p in PATTERNS:
            m = p.search(line)
            if m:
                vals[k][m.group(1)] += 1
    return builds, nocache, vals


(ba, na, va), (bb, nb, vb) = read(sys.argv[1]), read(sys.argv[2])
print("# every row: verdict, what, this rebuild | task 3")
same = differs = 0
for what, here, there in [("`docker build` lines", bb, ba), ("of them with --no-cache", nb, na)] + [
        ("%s, distinct values" % k, " ; ".join(sorted(vb[k])), " ; ".join(sorted(va[k]))) for k, _ in PATTERNS]:
    v = "same" if here == there else "DIFFERS"
    same += v == "same"
    differs += v != "same"
    print("  %-8s %s: %s | %s" % (v, what, here, there))
print("# lines carrying each value (this rebuild | task 3); a line count is how often the builder printed it, not a build count:")
for k, _ in PATTERNS:
    for val in sorted(set(va[k]) | set(vb[k])):
        print("    %s = %s: %d | %d" % (k, val, vb[k].get(val, 0), va[k].get(val, 0)))
print("# rows: same=%d DIFFERS=%d" % (same, differs))

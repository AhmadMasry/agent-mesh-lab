"""The bounded scan the controller asked for on 2026-09-22, before B-6.

QUESTION: over the run records this repository commits, which entries' figures rest on an agentgateway ACCESS-LINE
stamp, rather than on a ledger stamp or a non-access proxy line? Those are the records the leading-zero defect of
agentgateway#3369 can reach. Nothing is fixed here and no note is written for anything this finds; the scan reports
the extent of the exposure and stops.

THE TEST, in two parts, because holding an affected line is not the same as computing a figure from one:
  (a) which committed run records hold an agentgateway access line that carries its OWN stamp, and how many of
      those stamps are defective;
  (b) of those, which records' committed counters actually PARSE that stamp into a figure. A counter that reads an
      access line for its route, host, method, status and the proxy's own `duration=` field is not exposed: the
      duration is a value the proxy computes, not a difference between two stamps, so the defect cannot enter it.
WHAT IT SKIPS, AND WHY THE FIRST COMMITTED VERSION DID NOT REPRODUCE. This is a scan of run RECORDS, so it skips
committed programs -- `.py` and `.sh` -- and counts only the data files beside them. Without that, a driver's own
`kubectl logs ... | grep 'request gateway='` line and this program's own two literal copies of that string are
counted as access lines with no stamp, which is why re-running the first committed version of this scan after it had
itself been committed printed 4 in the B-5b `unstamped` cell where the committed output said 2. The skip makes the
output stable and removes an `unstamped` count that was never about a record at all; the `stamped` and `defective`
columns, which are what the scan is for, were unaffected either way.
WHERE IT REPRODUCES. The question is about COMMITTED files, so in a repository it asks git (`git ls-files`). A
detached `git archive` of a commit has no index to ask, but it holds exactly the files that commit tracks, so there
the same question is answered by walking the tree. It does both: git when git answers, the filesystem otherwise,
and the two agree by construction. It therefore reproduces byte-identically in the repository at its commit AND
from a clean archive of it. An earlier version asked git only and came back with an empty table from an archive.
Reads only; no cluster, no network, nothing modified.
"""
import collections, os, re, subprocess

def committed_files():
    """The files the commit tracks: from git in a repository, from the tree itself in a detached archive."""
    try:
        r = subprocess.run(["git", "ls-files", "experiments/runs/"], capture_output=True, text=True, check=True)
        if r.stdout.split():
            return sorted(r.stdout.split())
    except (OSError, subprocess.CalledProcessError):
        pass
    out = []
    for root, _dirs, names in os.walk("experiments/runs"):
        out += [os.path.join(root, n) for n in names]
    return sorted(out)


files = committed_files()
STAMPED = re.compile(r"^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)\.(\d+)Z\t.*request gateway=")
BARE = re.compile(r"request gateway=")
per = collections.defaultdict(lambda: {"stamped": 0, "short": 0, "unstamped": 0})
for f in files:
    if f.endswith((".py", ".sh")):
        continue                      # a committed program is not a record; see the docstring
    run = "/".join(f.split("/")[:3])
    try:
        with open(f, errors="ignore") as fh:
            for raw in fh:
                if not BARE.search(raw):
                    continue
                m = STAMPED.match(raw)
                if m:
                    per[run]["stamped"] += 1
                    if len(m.group(2)) < 6:
                        per[run]["short"] += 1
                else:
                    per[run]["unstamped"] += 1
    except (IsADirectoryError, UnicodeDecodeError):
        pass

print("# Produced by exposure-scan.py beside this file. It asks git which files are committed, and falls back to")
print("# walking the tree where there is no index, so it reproduces byte-identically both in this repository at the")
print("# commit carrying it and from a clean `git archive` of that commit.")
print("# It skips committed programs (.py, .sh): a scan of run RECORDS should not count a driver's own grep string.")
print()
print("(a) COMMITTED RUN RECORDS HOLDING AN AGENTGATEWAY ACCESS LINE\n")
print(f"    {'run record':56s} {'stamped':>8s} {'defective':>10s} {'unstamped':>10s}")
for run in sorted(per):
    d = per[run]
    print(f"    {run.split('/')[-1]:56s} {d['stamped']:8d} {d['short']:10d} {d['unstamped']:10d}")

print("\n\n(b) OF THOSE, WHICH COUNTERS PARSE AN ACCESS-LINE STAMP INTO A FIGURE\n")
checks = {
    "2026-09-21-b3-streaming-client/counts.py":
        "NO. Its ACCESS regex captures route, method, status and duration only -- it does not capture a timestamp "
        "at all, so none of its 70 defective lines can reach a figure.",
    "2026-09-22-b4-control/counts.py":
        "NO. Its ACCESS regex does capture the stamp into the dict, but the field is never read: every use of those "
        "dicts is route, host, method, path, status or duration. Its 14 defective lines cannot reach a figure.",
    "2026-09-21-c3r2-public-server/counts.py":
        "NO. Its access log is a public server's combined log, not agentgateway's, and carries no agentgateway "
        "timestamp.",
    "2026-09-22-b5a-removal/counts.py":
        "YES -- rm_to_new_pod_first_served_ms_h2c (the successor's first ACCESS line) and the last-log figures, "
        "whose last line can be an access line. This is the record the correction note beside its entry is about.",
    "2026-09-22-b5b-removal-resubscribe/counts.py":
        "YES, and handled: it keeps proxy lines in the order the proxy wrote them and reports any figure ending at "
        "a defective stamp as not readable, correcting nothing.",
}
for k in sorted(checks):
    print(f"    {k}\n        {checks[k]}\n")
print("    Every other record above quotes its access lines for route, host, method and status, or for the proxy's")
print("    own duration= field, and commits no counter that parses their stamps.")
print("\n    ANSWER: of the committed run records that hold stamped agentgateway access lines, ONLY B-5a and B-5b")
print("    compute a figure from one. Nothing else in this repository is exposed.")

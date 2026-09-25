#!/usr/bin/env python3
"""compare.py -- D-5c: per record, the word pass's counts and the items it returns that no page of the original showed.

Reads search-words-<r>.jsonl (this directory) and the original record's result lines; writes new-items.txt.
Original items: B-5a, B-6 and C-9 from the "     #N [" result lines of their tracker-search.txt, the repository taken
from the preceding "== ... repo:<owner>/<name>" line (B-5a has one repository); B-3 from original-items-b3.txt.
"""
import json, re, pathlib, collections

HERE = pathlib.Path(__file__).resolve().parent
RUNS = HERE.parent
ORIG = {
    "b5a": RUNS / "2026-09-22-b5a-removal/tracker-search.txt",
    "b6": RUNS / "2026-09-23-b6-traces-and-table/tracker-search.txt",
    "c9": RUNS / "2026-09-24-c9-a2a-marking/tracker-search.txt",
}

def original(r):
    if r == "b3":
        s = set()
        for line in (HERE / "original-items-b3.txt").read_text().splitlines():
            if line and not line.startswith("#"):
                repo, n = line.split()
                s.add((repo, int(n)))
        return s
    s, repo = set(), "agentgateway/agentgateway"
    for line in ORIG[r].read_text().splitlines():
        m = re.search(r"repo:(\S+/\S+)", line)
        if line.startswith("==") and m:
            repo = m.group(1)
        m = re.match(r"^\s+#(\d+) \[", line)
        if m:
            s.add((repo, int(m.group(1))))
    return s

out = []
for r in ["b3", "b5a", "b6", "c9"]:
    rows = [json.loads(l) for l in (HERE / f"search-words-{r}.jsonl").read_text().splitlines() if l.strip()]
    txt = (HERE / f"search-words-{r}.txt").read_text()
    pages = len(re.findall(r"^== .* page \d+ +total_count=", txt, re.M))
    failed = len(re.findall(r"^   FAILED", txt, re.M))
    queries = len({row["q"] for row in rows} | set(re.findall(r"q=(.*?)  page", txt)))
    items = {}
    hits = collections.Counter()
    for row in rows:
        k = (row["repo"], row["number"])
        items[k] = row
        hits[k] += 1
    orig = original(r)
    new = sorted(k for k in items if k not in orig)
    tot = collections.OrderedDict()
    for m in re.finditer(r"^== \S+  q=repo:(\S+) is:(issue|pr) (.*?)  page 1 +total_count=(\d+)", txt, re.M):
        tot.setdefault((m.group(1), m.group(3)), {})[m.group(2)] = int(m.group(4))
    out.append(f"== {r}: {queries} queries sent (issue and pr counted apart), {pages} pages, {failed} FAILED lines, "
               f"{len(items)} distinct items, {len(orig)} distinct items on the original's pages, "
               f"{len(new)} new (on no original page)")
    out.append("   per query, the word pass's total_count (issues + pull requests):")
    for (repo, words), t in tot.items():
        out.append(f"     {repo} {words}: {t.get('issue')} + {t.get('pr')}")
    out.append("   new items:")
    for k in new:
        row = items[k]
        st = row["state"] + (" merged" if row["merged"] else "")
        kind = "PR" if row["pr"] else "issue"
        out.append(f"   {k[0]}#{k[1]} [{st}] {kind} ({hits[k]} queries) {row['title']}")
(HERE / "new-items.txt").write_text("# D-5c: written by compare.py from the four search-words-*.jsonl files.\n" + "\n".join(out) + "\n")
print("\n".join(l for l in out if l.startswith("==")))

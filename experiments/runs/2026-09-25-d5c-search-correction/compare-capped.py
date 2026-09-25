#!/usr/bin/env python3
"""compare-capped.py -- D-5c, review round (M-1): the capped single-token pass against the earlier pages.

Reads search-words-capped.jsonl; writes new-items-capped.txt. Per record (B-6, B-5a), the items of the pass that are
on no page of the original record, and of those, the ones also on no page of that record's multi-word word pass
(search-words-<r>.jsonl). Original items are read the way compare.py reads them.
"""
import json, pathlib, collections

HERE = pathlib.Path(__file__).resolve().parent
src = (HERE / "compare.py").read_text().split("\nout = []")[0]  # the helper definitions only, not the run
cmp_ns = {"__file__": str(HERE / "compare.py")}
exec(src, cmp_ns)
original = cmp_ns["original"]

rows = [json.loads(l) for l in (HERE / "search-words-capped.jsonl").read_text().splitlines() if l.strip()]
out = ["# D-5c, review round: written by compare-capped.py from search-words-capped.jsonl."]
for r in ["b6", "b5a"]:
    mine = [row for row in rows if row["tag"] == r]
    items = collections.OrderedDict()
    for row in mine:
        items[(row["repo"], row["number"])] = row
    orig = original(r)
    words = {(json.loads(l)["repo"], json.loads(l)["number"])
             for l in (HERE / f"search-words-{r}.jsonl").read_text().splitlines() if l.strip()}
    not_orig = sorted(k for k in items if k not in orig)
    not_either = [k for k in not_orig if k not in words]
    out.append(f"== {r}: {len({row['q'] for row in mine})} calls' queries, {len(items)} distinct items, "
               f"{len(not_orig)} on no page of the original, {len(not_either)} of them also on no page of the "
               f"multi-word word pass")
    for k in not_orig:
        row = items[k]
        st = row["state"] + (" merged" if row["merged"] else "")
        mark = "  " if k in not_either else "w "
        out.append(f"   {mark}{k[0]}#{k[1]} [{st}] {'PR' if row['pr'] else 'issue'} {row['title']}")
# The same, against every earlier page of all four records (originals and word passes), any repository.
allorig = set().union(*[original(r) for r in ["b3", "b5a", "b6", "c9"]])
allwords = {(json.loads(l)["repo"], json.loads(l)["number"]) for r in ["b3", "b5a", "b6", "c9"]
            for l in (HERE / f"search-words-{r}.jsonl").read_text().splitlines() if l.strip()}
cap = {(row["repo"], row["number"]) for row in rows}
own = set()
for r in ["b6", "b5a"]:
    it = {(row["repo"], row["number"]) for row in rows if row["tag"] == r}
    w = {(json.loads(l)["repo"], json.loads(l)["number"])
         for l in (HERE / f"search-words-{r}.jsonl").read_text().splitlines() if l.strip()}
    own |= it - original(r) - w
x = cap - allorig - allwords
out.append(f"== all records: {len(cap)} distinct items, {len(x)} on no earlier page of any of the four records "
           f"({len(own)} per record; the {len(own - x)} between are on another record's pages: "
           + ", ".join(f"{k[0]}#{k[1]}" for k in sorted(own - x)) + ")")
out.append("# A line marked w is on a page of the multi-word word pass as well; an unmarked line is on no earlier page.")
(HERE / "new-items-capped.txt").write_text("\n".join(out) + "\n")
print("\n".join(l for l in out if l.startswith("==")))

"""Follow-ups 24: a counting tool's text output of this walk beside the entry's, line by line, identifiers masked only.

For the rows whose committed counting tool prints prose and tallies rather than one CSV line per repetition (D-4's
counts.txt, D-5's counts.txt, C-1's cells, C-9's card readings), the two texts are compared after masking the same
identifiers compare-rows.py masks (UUIDs, 64-, 32- and 16-hex ids, IPv4 addresses with ports, pod-name suffixes, ISO stamps) and the
run tokens given, plus the run directory's own name. Every line that differs is printed as a unified diff, and the
summary counts the lines the same and the lines differing on each side. Nothing is judged here: a differing line keeps
its verdict and its cause is written beside it in the record.

Reads files only. usage: compare-text.py <old file> <new file> [<token to mask> ...]"""
import difflib
import re
import sys

old, new = sys.argv[1], sys.argv[2]
tokens = sys.argv[3:]
PATS = [(re.compile(r'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'), '<uuid>'),
        (re.compile(r'\b[0-9a-f]{64}\b'), '<sha256>'),
        (re.compile(r'\b[0-9a-f]{32}\b'), '<id32>'), (re.compile(r'\b[0-9a-f]{16}\b'), '<id16>'),
        (re.compile(r'\b\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d+)?Z\b'), '<stamp>'),
        (re.compile(r'\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}(:\d+)?\b'), '<ip>'),
        (re.compile(r'-[0-9a-f]{8,10}-[0-9a-z]{5}\b'), '-<pod>'),
        (re.compile(r'2026-09-\d\d-[a-z0-9-]+'), '<run-dir>')]


def mask(line):
    for t in tokens:
        if t:
            line = re.sub(r'(?<![0-9a-z])' + re.escape(t) + r'(?![0-9a-z])', '<run>', line)
    for p, r in PATS:
        line = p.sub(r, line)
    return line


a = [mask(l.rstrip('\n')) for l in open(old, encoding='utf-8', errors='replace')]
b = [mask(l.rstrip('\n')) for l in open(new, encoding='utf-8', errors='replace')]
print(f'## {old} | {new} ({len(a)} | {len(b)} lines, identifiers masked)')
diff = list(difflib.unified_diff(a, b, fromfile=old, tofile=new, lineterm='', n=0))
minus = sum(1 for l in diff if l.startswith('-') and not l.startswith('---'))
plus = sum(1 for l in diff if l.startswith('+') and not l.startswith('+++'))
for l in diff:
    print(l)
same = len(a) - minus
print(f'# lines: same={same} differing: {minus} in the entry only, {plus} in this run only')

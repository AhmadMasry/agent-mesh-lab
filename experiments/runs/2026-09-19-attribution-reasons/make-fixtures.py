#!/usr/bin/env python3
"""make-fixtures.py -- writes the two derive-layer fixtures follow-ups 19 task 2 added.

Run from the repository root, after experiments/lib/jaeger-spans.jq reads `http.status`:

    python3 experiments/runs/2026-09-19-attribution-reasons/make-fixtures.py

Both are written by this program from committed files, so neither is edited by hand
and either can be written again and compared.

  older-record-model-hop-reexported   REAL. Work item a3r-egress-171458-01 of
      experiments/runs/2026-09-09-a3-gateway-retry-mechanics/ (Gate 3 Task 2's egress
      retry probe, on the topology this lab ran until 2026-09-19). The four ledger files
      are copied byte for byte. spans.csv is what TODAY's exporter writes from that run's
      committed trace.json, so unlike the record's own spans.csv it has the `route`
      column, and the route it carries is the old topology's:
      agentgateway-egress/model-via-agw. It is the same work item as the fixture
      `older-record-model-hop`, which keeps the record's own spans.csv (no route column).

  synthetic-parent-cycle              SYNTHETIC, and it cannot be otherwise: a tracer
      assigns a span its parent when the span starts, from a span that already exists,
      so no trace holds a span that is its own ancestor. It is the live fixture
      `gateway-ingress-py` with two cells of spans.csv changed: the proxy's two upstream
      attempt spans, both children of the one entry span on lab/orchestrator-ingress,
      are made to name each other as parent. The walk from the orchestrator's server
      span up through the proxy's spans then never meets a span carrying a route and
      never leaves the proxy's service. Everything else, the four ledger files included,
      is byte for byte that fixture's.
"""
import pathlib
import shutil
import subprocess

ROOT = pathlib.Path(".")
FIXTURES = ROOT / "experiments/fixtures/derive-layer"
LEDGERS = ["client.jsonl", "execution.jsonl", "ingress.jsonl", "invocation.jsonl"]


def reexported():
    source = ROOT / "experiments/runs/2026-09-09-a3-gateway-retry-mechanics/a3r-egress-171458-01"
    target = FIXTURES / "older-record-model-hop-reexported"
    target.mkdir(exist_ok=True)
    for name in LEDGERS:
        shutil.copyfile(source / name, target / name)
    out = subprocess.run(["jq", "-r", "-s", "-f", "experiments/lib/jaeger-spans.jq", str(source / "trace.json")],
                         check=True, capture_output=True, text=True).stdout
    (target / "spans.csv").write_text(out)


def parent_cycle():
    source = FIXTURES / "gateway-ingress-py"
    target = FIXTURES / "synthetic-parent-cycle"
    target.mkdir(exist_ok=True)
    for name in LEDGERS:
        shutil.copyfile(source / name, target / name)
    entry, first, second = "b0106a30244a98b2", "9188880051321e5e", "64a9b7070fc08e9f"
    text = (source / "spans.csv").read_text()
    # span_id,parent_span_id are the second and third columns; each pair occurs once.
    for span, new_parent in ((first, second), (second, first)):
        old = f",{span},{entry},"
        assert text.count(old) == 1, old
        text = text.replace(old, f",{span},{new_parent},")
    (target / "spans.csv").write_text(text)


reexported()
parent_cycle()

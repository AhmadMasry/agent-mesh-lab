#!/usr/bin/env python3
"""Follow-ups 15, commit 3: the inventory -- for each scrape target, the metric families that describe request flow,
from the live exposition (families-start.csv and families-end.csv, written by exposition.sh), with the document URL
and sentence where the project documents the family, else "exposition only" with the family's own HELP line from
the exposition. Families a project documents that no
target exposed are listed too, with the targets that could have. Read-only; CSV on stdout.

The selection is by family name, and it is the whole of this file's judgement:
  agentgateway proxies  requests, retries, request/response durations and processing, response bytes, shed
                        counters, downstream connections and bytes, upstream call and connect durations, and the
                        documented LLM and MCP families
  ztunnel               istio_tcp_* and istio_requests_total
  istiod, control plane every family is listed by exposition.sh; none is on a work item's path (they describe
                        configuration: pilot_*, agentgateway_controller_*, xds), so one row says so
  otel-collector        whatever 8889 exposes, and the documented internal span counters
"""
import csv, re, sys

AGW = "https://agentgateway.dev/docs/kubernetes/latest/documentation/observability/metrics/dataplane.md"
IST = "https://istio.io/latest/docs/reference/config/metrics/"
ZT = "https://istio.io/latest/docs/ambient/usage/troubleshoot-ztunnel/"
OTC = "https://opentelemetry.io/docs/collector/internal-telemetry/"
DOCS = {
    "agentgateway_requests": (AGW, "`agentgateway_requests_total` | Counter | -- | The total number of HTTP requests sent."),
    "agentgateway_retries": (AGW, "`agentgateway_retries_total` | Counter | -- | The total number of request retries."),
    "agentgateway_request_duration_seconds": (AGW, "`agentgateway_request_duration_seconds` | Histogram | seconds | Duration of HTTP requests."),
    "agentgateway_request_processing_seconds": (AGW, "`agentgateway_request_processing_seconds` | Histogram | seconds | Duration from receiving an HTTP request to sending the primary outbound call."),
    "agentgateway_response_processing_seconds": (AGW, "`agentgateway_response_processing_seconds` | Histogram | seconds | Duration from receiving the primary outbound response to sending the HTTP response."),
    "agentgateway_response_bytes": (AGW, "`agentgateway_response_bytes_total` | Counter | bytes | Total HTTP response bytes received."),
    "agentgateway_requests_shed": (AGW, "`agentgateway_requests_shed_total` | Counter | -- | Total downstream requests rejected by the in-flight request limit."),
    "agentgateway_downstream_connections": (AGW, "`agentgateway_downstream_connections_total` | Counter | -- | The total number of downstream connections established."),
    "agentgateway_downstream_connections_shed": (AGW, "`agentgateway_downstream_connections_shed_total` | Counter | -- | Total downstream connections closed by the active connection limit."),
    "agentgateway_downstream_received_bytes": (AGW, "`agentgateway_downstream_received_bytes_total` | Counter | bytes | Total TCP bytes received per connection labels."),
    "agentgateway_downstream_sent_bytes": (AGW, "`agentgateway_downstream_sent_bytes_total` | Counter | bytes | Total TCP bytes transmitted per connection labels."),
    "agentgateway_upstream_connect_duration_seconds": (AGW, "`agentgateway_upstream_connect_duration_seconds` | Histogram | seconds | Duration to establish upstream connection."),
    "agentgateway_upstream_call_duration_seconds": (AGW, "`agentgateway_upstream_call_duration_seconds` | Histogram | seconds | Duration of outbound calls made by agentgateway."),
    "agentgateway_gen_ai_client_token_usage": (AGW, "`agentgateway_gen_ai_client_token_usage` | Histogram | -- | Number of tokens used per request."),
    "agentgateway_gen_ai_server_request_duration": (AGW, "`agentgateway_gen_ai_server_request_duration` | Histogram | -- | Duration of generative AI request."),
    "agentgateway_mcp_requests": (AGW, "`agentgateway_mcp_requests_total` | Counter | -- | Total number of MCP requests."),
    "istio_tcp_connections_opened": (IST, "Tcp Connections Opened (istio_tcp_connections_opened_total): This is a COUNTER incremented for every opened connection."),
    "istio_tcp_connections_closed": (IST, "Tcp Connections Closed (istio_tcp_connections_closed_total): This is a COUNTER incremented for every closed connection."),
    "istio_tcp_sent_bytes": (IST, "Tcp Bytes Sent (istio_tcp_sent_bytes_total): This is a COUNTER which measures the size of total bytes sent during response in case of a TCP connection."),
    "istio_tcp_received_bytes": (IST, "Tcp Bytes Received (istio_tcp_received_bytes_total): This is a COUNTER which measures the size of total bytes received during request in case of a TCP connection."),
    "istio_requests": (IST, "Request Count (istio_requests_total): This is a COUNTER incremented for every request handled by an Istio proxy."),
    "otelcol_receiver_accepted_spans": (OTC, "otelcol_receiver_accepted_spans | Number of spans successfully ingested and pushed into the pipeline. | Counter"),
    "otelcol_exporter_sent_spans": (OTC, "otelcol_exporter_sent_spans | Number of spans successfully sent to destination. | Counter"),
}
ZT_SENTENCE = ("If a service is only using the secure overlay provided by ztunnel, the Istio metrics reported will only be the L4 "
               "TCP metrics (namely istio_tcp_sent_bytes_total, istio_tcp_received_bytes_total, istio_tcp_connections_opened_total, "
               "istio_tcp_connections_closed_total). The full set of Istio and Envoy metrics will be reported if a waypoint proxy is used.")
AGW_FLOW = re.compile(r"^agentgateway_(requests|retries|request_duration_seconds|request_processing_seconds|response_processing_seconds|"
                      r"response_bytes|requests_shed|downstream_connections|downstream_connections_shed|downstream_received_bytes|"
                      r"downstream_sent_bytes|upstream_connect_duration_seconds|upstream_call_duration_seconds|gen_ai_.*|mcp_requests)$")
ZT_FLOW = re.compile(r"^istio_(tcp_.*|requests)$")

def load(path):
    out = {}
    for r in csv.DictReader(open(path)):
        out[(r["job"], r["target"], r["family"])] = r
    return out

start, end = load(sys.argv[1]), load(sys.argv[2])
import glob, os
HELP = {}
for raw in sys.argv[3:]:
    for pth in glob.glob(os.path.join(raw, "*.prom")):
        for l in open(pth, errors="replace"):
            if l.startswith("# HELP "):
                _, _, fam, txt = l.rstrip("\n").split(" ", 3)
                HELP.setdefault(fam, txt)
targets = sorted({(j, t) for (j, t, _) in list(start) + list(end)})
for raw in sys.argv[3:]:
    for l in open(os.path.join(raw, "read.tsv")):
        job, name, who, path = l.rstrip("\n").split("\t")
        if (job, who) not in targets:
            targets.append((job, who))
targets = sorted(set(targets))
rows = []
for job, tgt in targets:
    fams = sorted({f for (j, t, f) in list(start) + list(end) if (j, t) == (job, tgt)})
    if job == "agentgateway-proxies":
        sel = [f for f in fams if AGW_FLOW.match(f)]
        documented = [f for f in DOCS if f.startswith("agentgateway_")]
    elif job == "ztunnel":
        sel = [f for f in fams if ZT_FLOW.match(f)]
        documented = [f for f in DOCS if f.startswith("istio_")]
    elif job == "otel-collector":
        sel = fams
        documented = [f for f in DOCS if f.startswith("otelcol_")]
    else:
        sel, documented = [], []
    for f in sel:
        r = end.get((job, tgt, f)) or start.get((job, tgt, f))
        url, sentence = DOCS.get(f, ("exposition only", "HELP: " + HELP.get(f, "(none)")))
        rows.append({"job": job, "target": tgt, "family": f, "type": r["type"], "labels": r["labels"],
                     "at_start": "yes" if (job, tgt, f) in start else "no", "at_end": "yes" if (job, tgt, f) in end else "no",
                     "doc_url": url, "doc_sentence": sentence})
    for f in documented:
        if f not in fams:
            url, sentence = DOCS[f]
            rows.append({"job": job, "target": tgt, "family": f, "type": "(absent)", "labels": "",
                         "at_start": "no", "at_end": "no", "doc_url": url, "doc_sentence": sentence})
    if job == "agentgateway-proxies" and "waypoint" in tgt and "istio_requests" not in fams:
        rows.append({"job": job, "target": tgt, "family": "istio_requests", "type": "(absent)", "labels": "",
                     "at_start": "no", "at_end": "no", "doc_url": ZT, "doc_sentence": ZT_SENTENCE})
    if job == "ztunnel" and not sel:
        rows.append({"job": job, "target": tgt, "family": "(no istio_tcp_* or istio_requests family)", "type": "", "labels": "",
                     "at_start": "", "at_end": "", "doc_url": ZT, "doc_sentence": "no workload of the mesh runs on this node"})
    if job in ("istiod", "agentgateway-controlplane"):
        n = len(fams)
        rows.append({"job": job, "target": tgt, "family": f"(none of {n} families is on a work item's path)", "type": "", "labels": "",
                     "at_start": "", "at_end": "", "doc_url": "exposition only", "doc_sentence": "control plane: configuration and xDS, not requests"})
    if job == "otel-collector" and not fams:
        rows.append({"job": job, "target": tgt, "family": "(the exposition on 8889 is empty)", "type": "", "labels": "",
                     "at_start": "", "at_end": "", "doc_url": "exposition only", "doc_sentence": "the prometheus exporter of a metrics pipeline no emitter sends to"})
# The collector's own telemetry is not a scrape target: the chart's values remove the 8888 pull reader from the
# rendered configuration (telemetry.metrics: null), and the collector then serves its default, which the page
# describes. Read once at the end through a port-forward to the pod (raw/end/otel-collector-8888.prom).
p8888 = os.path.join(sys.argv[-1], "otel-collector-8888.prom") if len(sys.argv) > 3 else ""
if p8888 and os.path.exists(p8888):
    types, labels = {}, {}
    for l in open(p8888, errors="replace"):
        if l.startswith("# TYPE "):
            _, _, fam, typ = l.split(None, 3); types[fam] = typ.strip()
        elif l.startswith("otelcol_"):
            name = re.match(r"([a-z_]+)", l).group(1)
            labels.setdefault(name, set()).update(re.findall(r'([a-zA-Z_][a-zA-Z0-9_]*)="', l))
    for f in ("otelcol_receiver_accepted_spans", "otelcol_receiver_refused_spans", "otelcol_exporter_sent_spans"):
        rows.append({"job": "(not scraped)", "target": "otel-collector pod, 127.0.0.1:8888", "family": f, "type": types.get(f, "(absent)"),
                     "labels": "|".join(sorted(labels.get(f, set()))), "at_start": "not read", "at_end": "yes" if f in types else "no",
                     "doc_url": OTC, "doc_sentence": "By default, the Collector generates basic metrics about itself and exposes them using the OpenTelemetry Go Prometheus exporter for scraping at http://127.0.0.1:8888/metrics."})
for hop, why in (("loadgen", "no /metrics route and no meter provider in fixtures/loadgen or internal/otel; not a scrape target"),
                 ("worker", "no /metrics route (agents/worker/main.go: /healthz, /control/*, the A2A mux) and no meter provider; not a scrape target"),
                 ("orchestrator", "OTEL_METRICS_EXPORTER=none (deploy/step-3-stress/orchestrator-instrumentation.yaml); not a scrape target"),
                 ("mockllm", "no /metrics route (fixtures/mockllm/server.go: chat completions, /control/*, /healthz) and no meter provider; not a scrape target")):
    rows.append({"job": "(none)", "target": hop, "family": "(none)", "type": "", "labels": "", "at_start": "", "at_end": "",
                 "doc_url": "code and manifests", "doc_sentence": why})
w = csv.DictWriter(sys.stdout, fieldnames=["job", "target", "family", "type", "labels", "at_start", "at_end", "doc_url", "doc_sentence"], lineterminator="\n")
w.writeheader()
w.writerows(rows)

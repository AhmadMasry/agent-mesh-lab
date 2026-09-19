#!/usr/bin/env python3
"""requests-carried.py <label>=<full-dump.json>...  ->  CSV on stdout, one row per dump.

A reading added after the run, from its records only. An agentgateway /config_dump holds,
for each Service the proxy routes to, a per-endpoint counter `info.totalRequests`: how many
requests THIS proxy process has sent to that endpoint since it started. It answers the
question a missing span leaves open -- was the proxy on the path at all? -- from the
proxy's own state rather than from the trace.

Per dump: how many policies the proxy held, whether config.tracing was null, the sum of
totalRequests over the endpoints of worker.lab.svc.cluster.local (the Service behind
lab/agentgateway-waypoint), and the whole dump's sha256, which shows when two dumps are the
same bytes.

It needs the full dumps, which are left out of the commit (.gitignore); its output is
committed. Run on the host that took them, 2026-09-19.
"""
import csv
import hashlib
import json
import sys

SERVICE = "worker.lab.svc.cluster.local"


def main() -> int:
    out = csv.writer(sys.stdout, lineterminator="\n")
    out.writerow(["dump", "pod", "policies", "config_tracing_null", f"total_requests_to_{SERVICE}", "dump_bytes", "dump_sha256"])
    for arg in sys.argv[1:]:
        label, _, path = arg.partition("=")
        raw = open(path, "rb").read()
        dump = json.loads(raw)
        total = 0
        for service in dump.get("services") or []:
            if service.get("hostname") != SERVICE:
                continue
            for group in service.get("endpoints") or []:
                for endpoint in (group.get("active") or {}).values():
                    total += (endpoint.get("info") or {}).get("totalRequests", 0)
        config = dump.get("config") or {}
        pod = (config.get("proxyMetadata") or {}).get("podName", "")
        out.writerow([
            label,
            pod,
            len(dump.get("policies") or []),
            str(config.get("tracing") is None).lower(),
            total,
            len(raw),
            hashlib.sha256(raw).hexdigest(),
        ])
    return 0


if __name__ == "__main__":
    sys.exit(main())

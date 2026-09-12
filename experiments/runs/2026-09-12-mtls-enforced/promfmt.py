"""Follow-ups 7 / formats what promq.sh reads out of Prometheus.

Two modes, both reading one Prometheus JSON body on stdin and printing text:

  targets   the scrape-target roster: job, health, URL, last error, and the up/total
            count. Recorded before and after the policy, because a scrape is a
            plaintext request from `telemetry` (not mesh-enrolled) into whatever it
            scrapes, so STRICT can change this roster.
  series    every series of istio_tcp_connections_opened_total with its full label
            set and value. Printed before anything is tabulated from it, so the raw
            reading is in the record.
"""

import json
import sys

mode = sys.argv[1]
body = json.load(sys.stdin)

if mode == "targets":
    targets = body["data"]["activeTargets"]
    for t in sorted(targets, key=lambda t: (t["labels"].get("job", ""), t["scrapeUrl"])):
        print("{:26s} {:9s} {:54s} {}".format(
            t["labels"].get("job", "?"), t["health"], t["scrapeUrl"], t.get("lastError", "")))
    up = sum(1 for t in targets if t["health"] == "up")
    print("-- {}/{} targets up".format(up, len(targets)))
elif mode == "series":
    if body.get("status") != "success":
        print("query failed:", json.dumps(body))
        sys.exit(1)
    result = body["data"]["result"]
    print("-- {} series".format(len(result)))
    for r in sorted(result, key=lambda r: json.dumps(r["metric"], sort_keys=True)):
        print(json.dumps(r["metric"], sort_keys=True), "=>", r["value"][1])
else:
    print("unknown mode {}".format(mode), file=sys.stderr)
    sys.exit(2)

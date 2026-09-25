# The currency pass of 2026-09-25, Phase 2: the rebuild at the pins of 2026-09-25, the standard proof, the approved rows

Phase 1 (the pins read and moved, the local proof, the impact list) is ../2026-09-25-currency-pass/. This directory is
the cluster side: a rebuild from a deleted cluster at 7ec46496, the standard proof compared with D-4's, every moved pin
read back from the cluster, and the rows the controller approved from the impact list, each re-counted with its
committed driver and compared cell by cell with its original entry (identifiers masked only, drivers/cellcompare.py).
reading-notes.txt holds every deviation and the ruling behind it.

| What | Where |
| --- | --- |
| rebuild: driver, log, per-target timings | drivers/rebuild.sh, build.txt, timings.csv, rebuild-driver.txt |
| standard proof (D-4's checks.sh, unedited) and its comparison with D-4's | drivers/proof.sh, proof-driver.txt, checks.txt, standard-counts-vs-last-proof.txt, clean-check/, trace/, strict/, proxies/, cluster/, retry-knobs/, prometheus-targets.txt, checks-as-run-sha256.txt |
| the Prometheus scrape leg measured | drivers/prom-ingress-rate.sh, prom-ingress-rate.txt |
| every moved pin read back | versions-readback.txt, drivers/pins-readback.sh, pins-readback.txt |
| A2A-Version per SDK (gate1-wire-version.sh, unedited) | wire-version/ |
| make scan-images | scan/ |
| B-3 D3 (attempt 1; attempt 2 from drivers/b3-rows.sh) | b3-attempt-1/, b3-subscribe-terminal/ (counts.txt, summary.csv, compare-with-b3.txt) |
| D-1p | d1p/rows/pyclient-central-graceful/ (summary.csv, counts.txt, compare-with-d1p.txt) |
| C-3/C-4 | c3c4/ (replay.sh, counts.csv, compare-with-c3c4.txt) |
| C-3R | c3r-replay.sh, c3r/ (counts.csv, compare-with-c3r.txt, push-sizes-current-pod.txt) |
| C-3R2 (attempt 1, attempt 2) | c3r2-attempt-1/, c3r2/ (counts.csv, compare-with-c3r2.txt, push-sizes-current-pod.txt) |
| C-5 | c5/ (replay.sh, counts.csv, compare-with-c5.txt) |
| D-4 Row Z | d4z/ (z/, counts-z.py, counts.txt) |
| D-5 connection count | d5/ (replay.sh, counts.txt, conn-*/, conn-join/) |
| A.3 R3 py, R4 py, R4 py service (attempt 1; attempt 2 from drivers/gate3-matrix.sh) | matrix-attempt-1/, a3-r3-py/, a3-r4-py/, a3-r4-py-service/ (summary.csv, compare-with-a.txt) |
| the stale Go-sources lists in committed scripts | go-sources-hash-audit.txt |
| the util-genai constraint checked | local/util-genai-constraint.txt |
| istioctl directories renamed aside and back | istioctl-renames.txt |
| host sleep over the window (kinds and stamps only) | sleep-events.csv |
| every row's driver output and the order of the rows | rows-logs/ |
| the cluster left at step 3 | cluster-after.txt |

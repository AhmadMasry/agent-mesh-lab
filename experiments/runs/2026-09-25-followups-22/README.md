# Follow-ups 22: the currency pass's follow-up fix, rebuilt from a deleted cluster and proved; one matrix row run unedited

The author's note of 2026-09-25 (the last note in docs/proposal-notes.md) orders the fix the currency pass recorded
(its reading-notes.txt item 19): experiments/gate3-matrix.sh's Go-sources path list brought to the Makefile's, the two
stale pyproject comments, and the grpc-go hold wording. Three commits on cb9ae947 precede this record: the
contradictions entry (records only), the fix, and the pin-audit correction. This directory is the rebuild at the tip of
those three, the standard proof compared with the currency pass's, and one Experiment A row run with the committed
matrix script, unedited, from the repository.

| What | Where |
| --- | --- |
| the Go-sources hash before and after the fix, computed locally | go-sources-hash.txt |
| make test at the tip (the guard and its three mutants), and the live mutant shown before the fix was committed | make-test.txt, make-test-live-mutant.txt |
| the lab-scoped istioctl 1.31.1, its checksum against the release's published file | istioctl.txt |
| rebuild: driver, log, per-target timings | drivers/rebuild.sh, build.txt, timings.csv, rebuild-driver.txt |
| standard proof (D-4's checks.sh, unedited) and its comparison with the currency pass's | drivers/proof.sh, proof-driver.txt, checks.txt, standard-counts-vs-last-proof.txt, clean-check/, trace/, strict/, proxies/, cluster/, retry-knobs/, prometheus-targets.txt, versions-readback.txt, checks-as-run-sha256.txt |
| A.3 baseline, go receiver, REPS=20, experiments/gate3-matrix.sh unedited | a3-baseline-go/ (driver.txt, knobs.txt, control.txt, summary.csv, compare-with-a.txt, one directory per repetition) |
| host sleep over the window (kinds and stamps only) | sleep-events.csv |
| the cluster left at step 3 | cluster-after.txt |
| the telemetry pods' creation and start stamps, read after the run on the same pods (review round) | telemetry-pods-after.txt |
| the git status at the row's start and the script's identity (review round) | row-start-git-status.txt |
| A2A-Version on the row's own ingress ledgers (review round) | a2a-version-row.txt |
| what each of those readings is, and what the make test guard checks | reading-notes.txt |

How each step ran:

- The drivers are the currency pass's rebuild.sh and proof.sh, changed only in their headers, the scratch and tool
  paths, the subjects of the built and compared trees, and LASTPROOF (each header lists its changes). Their logs were
  written to scratch while they ran and copied in afterwards, so the checkout stayed clean for the whole build.
- The rebuild tools: a lab-scoped istioctl 1.31.1 first on PATH for the drivers' processes only, and an empty Helm scope
  (a 0-byte repositories file, empty cache directories). Nothing on the host changed.
- The matrix row: RUN=baseline RECEIVER=go REPS=20, the script's own one-repetition dry run first (its directory
  removed by the script). The environment gave it the same lab-scoped istioctl on PATH and RUN_ITEM, the script's own
  output-path setting, pointed here. Nothing else: no copy, no edit, no REPO_ROOT (the script finds the root from its
  own path, l.123).
- The comparison: the currency pass's cellcompare.py, unedited, against
  ../2026-09-20-experiment-a-agentgateway-only/a3-baseline-go/summary.csv, keyed receiver,run,sub; identifiers masked
  only (the two RUN_IDs 022306 and 001001, UUIDs, hex ids, IPs, pod suffixes).
- checks.sh keeps byte copies of itself at each invocation (checks-as-run/); they are not committed and were moved to
  the task's scratch; their sha256, equal to the committed checks.sh's, is in checks-as-run-sha256.txt.
- Keep-awake: this task started none and changed no power setting; keep-awake is not claimed absent. The sleep record
  carries kinds and stamps only.

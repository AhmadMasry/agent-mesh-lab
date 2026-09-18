#!/usr/bin/env bash
# Follow-ups 15, review fix I2: the receivers' own pre-dispatch ingress ledgers, read from their pod logs, paired
# arrival to response for every request between two stamps (pairs.py beside this script). Read-only (kubectl logs).
# Written because the entry's "every request has its arrival and response" needed a record: the committed run
# directories hold only the work items their scripts collected, and one work item's ledgers -- the A.3 baseline's
# own dry run, deleted by gate3-matrix.sh with its directory -- were never collected.
# $1 = start (UTC, ISO 8601 Z), $2 = end.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "# pairs.sh $1 $2, read $(date -u +%Y-%m-%dT%H:%M:%SZ)"
for d in worker orchestrator; do
	echo "# $d pod: $(kubectl -n lab get pod -l app=$d -o jsonpath='{.items[0].metadata.name} started {.items[0].status.startTime}, restarts {.items[0].status.containerStatuses[0].restartCount}')"
done
for d in worker orchestrator; do kubectl -n lab logs "deploy/$d" 2>/dev/null | sed "s/^/$d\t/"; done | python3 "$DIR/pairs.py" "$1" "$2"

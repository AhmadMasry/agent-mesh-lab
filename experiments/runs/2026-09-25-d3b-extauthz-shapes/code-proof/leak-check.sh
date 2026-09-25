#!/usr/bin/env bash
# leak-check.sh <archive-copy-dir>: the forced failure, then the worker.test children left running and port 8081.
set -u
cd "$1" || exit 1
python3 "$(dirname "$0")/leak-force.py" || exit 1
n0=$(pgrep -f 'worker.test -test.run=\^TestMain_' | wc -l | tr -d ' ')
echo "children before: $n0"
go test ./agents/worker -run 'TestMain_' -count=1 2>&1 | grep -E -- '--- FAIL|never accepted|^(ok|FAIL)'
sleep 2
echo "children after: $(pgrep -f 'worker.test -test.run=\^TestMain_' | wc -l | tr -d ' ')"
pgrep -f 'worker.test -test.run=\^TestMain_' | while read -r p; do ps -o pid=,ppid=,command= -p "$p" | sed 's#/[^ ]*/worker.test#<tmp>/worker.test#'; done
echo "8081 listeners: $(lsof -nP -iTCP:8081 -sTCP:LISTEN | tail -n +2 | wc -l | tr -d ' ')"

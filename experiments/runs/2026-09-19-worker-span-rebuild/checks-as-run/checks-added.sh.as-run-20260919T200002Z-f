#!/usr/bin/env bash
# Follow-ups 19, task 3c: two readings ADDED by the controller's ruling after checks.sh had run (its one invocation
# ended 19:50:04Z), because this task showed a premise of its brief wrong: the brief left the image scan out as "the
# four images the commit does not rebuild differently", and all four of the lab's own images differ from task 3's in
# digest (reading (c)). checks.sh is left exactly as it ran; this is a second, separate driver. Like checks.sh it logs
# its own sha256 and keeps a byte copy of itself under checks-as-run/ at every invocation.
#   f   FIRST, and this task's LAST calls on the cluster (two reads: a `kubectl get pods` naming the orchestrator pod and
#       its imageID, and one `kubectl exec`): the distributions installed
#       in the running orchestrator container, by the command task 3's checks.sh used, against uv.lock by task 3's
#       lock-vs-installed.py, unedited (task 3: 53 of 53); then, from the two build logs and no cluster, what each
#       rebuild observed while it built the orchestrator image (image-build-values.py).
#   e   after the cluster was handed over to another agent: `make scan-images` as task 3 took it, and `go version -m`
#       of THIS build's scanned Go binaries: the build settings (vcs.revision and its two companions) and the module
#       versions, beside task 3's (go-binaries-vs-task-3.py). The make target's script makes ONE read-only cluster
#       call of its own, `kubectl -n lab get pod -l 'app in (worker,mockllm,orchestrator)'` (experiments/scan-images.sh
#       l.125), to print the image ids the pods run into scan-context.txt; the controller was told before it ran.
# $1 = log (outside the repository, copied in afterwards). $2 = the run directory's name. $3 = f | e.
# No retry anywhere. Keep-awake: this script starts none and changes no power setting.
set -uo pipefail
cd $(git rev-parse --show-toplevel)
LOG="$1"
RUNREL="$2"
ONLY="$3"
D=experiments/runs/$RUNREL
T3=experiments/runs/2026-09-19-currency-rebuild
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
step() { # label, command...
	local label="$1"; shift; local s; s=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
	echo "## $label  started $(ts)  epoch $s" >> "$LOG"
	"$@" >> "$LOG" 2>&1; local rc=$?
	local e; e=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
	echo "## $label  finished $(ts)  epoch $e  exit=$rc  wall=$(perl -e "printf '%.3f', $e - $s")s" >> "$LOG"; echo >> "$LOG"
	echo "$(ts) $label exit=$rc"
}
mkdir -p "$D/orchestrator-image" "$D/scan" "$D/checks-as-run"
DEPLOYED=(deploy Makefile agents fixtures internal experiments/lib ':(glob)experiments/*.sh' .ko.yaml go.mod go.sum kind-config.yaml)
SELF_SHA=$(shasum -a 256 "$0" | awk '{print $1}')
ASRUN="$D/checks-as-run/checks-added.sh.as-run-$(date -u +%Y%m%dT%H%M%SZ)-$ONLY"
cp "$0" "$ASRUN"; chmod 644 "$ASRUN"
echo "# Follow-ups 19 task 3c ADDED readings ($ONLY), started $(ts). HEAD $(git rev-parse HEAD) ($(git log --format=%s -1 | cut -c1-60)...); git status --short over the deployed paths -> $(git status --short -- "${DEPLOYED[@]}" | tr '\n' ' ')" >> "$LOG"
echo "# this driver as it runs: sha256 $SELF_SHA; byte copy kept as $ASRUN" >> "$LOG"

if [ "$ONLY" = f ]; then
installed() {
	echo "== $(ts) the orchestrator: every installed distribution inside the running container, name==version (the command of task 3's checks.sh l.180-181) =="
	kubectl -n lab get pods -l app=orchestrator -o jsonpath='{range .items[*]}{.metadata.name}{"  "}{.status.containerStatuses[0].imageID}{"  started "}{.status.startTime}{"\n"}{end}'
	kubectl -n lab exec deploy/orchestrator -- python -c 'import importlib.metadata as m
for n, v in sorted({(d.metadata["Name"].lower().replace("_", "-"), d.version) for d in m.distributions()}): print("%s==%s" % (n, v))' > "$D/orchestrator-image/orchestrator-installed.txt" 2>&1
	echo "distributions installed in the running orchestrator container: $(grep -c '==' "$D/orchestrator-image/orchestrator-installed.txt")"
	echo "== $(ts) THE LAST CLUSTER CALL OF THIS TASK WAS THE EXEC ABOVE. From here on: files only. =="
	echo "== $(ts) against uv.lock: task 3's lock-vs-installed.py, unedited =="
	python3 "$T3/pins/lock-vs-installed.py" agents/orchestrator/uv.lock "$D/orchestrator-image/orchestrator-installed.txt" "$D/orchestrator-image/lock-vs-installed.csv"
	echo "== $(ts) the installed list beside task 3's (pins/orchestrator-installed.txt): diff =="
	if diff "$T3/pins/orchestrator-installed.txt" "$D/orchestrator-image/orchestrator-installed.txt"; then echo "identical: $(grep -c '' "$D/orchestrator-image/orchestrator-installed.txt") lines"; fi
	echo "== $(ts) what each rebuild's log observed while it built the image: image-build-values.py =="
	python3 "$D/orchestrator-image/image-build-values.py" "$T3/build.txt" "$D/build.txt"
}
step "(f) the running orchestrator's distributions against uv.lock, and the image build's observed values" bash -c "D=$D; T3=$T3; $(declare -f installed ts); installed 2>&1 | tee $D/orchestrator-image/readings.txt"
fi

if [ "$ONLY" = e ]; then
step "(e) make scan-images" make --no-print-directory scan-images SCAN_OUT=$D/scan
gomods() { # the Go images the scan just built into the Docker daemon: build settings and module versions of each binary
	local tmp; tmp=$(mktemp -d)
	echo "image,binary,go,module,version" > "$D/scan/go-binary-modules.csv"
	echo "image,binary,setting,value" > "$D/scan/go-binary-build-settings.csv"
	echo "tip of the checkout these were built from: $(git rev-parse HEAD); git status --short, lines: $(git status --short | grep -c '' || true) (the run directory, not yet committed, is what is listed)"
	for n in worker mockllm loadgen replay; do
		local img cid; img=$(docker images --format '{{.Repository}}:{{.Tag}}' | grep "^ko.local/$n-" | grep ':latest$' | head -1)
		[ -n "$img" ] || { echo "$n: no ko.local image found"; continue; }
		cid=$(docker create "$img"); docker cp "$cid:/ko-app/$n" "$tmp/$n" >/dev/null; docker rm "$cid" >/dev/null
		go version -m "$tmp/$n" > "$tmp/$n.mods.txt"
		local gov; gov=$(head -1 "$tmp/$n.mods.txt" | awk '{print $2}')
		awk -v img="$img" -v bin="$n" -v gov="$gov" '$1 == "dep" || $1 == "=>" { print img "," bin "," gov "," $2 "," $3 }' "$tmp/$n.mods.txt" >> "$D/scan/go-binary-modules.csv"
		awk -v img="$img" -v bin="$n" '$1 == "build" { i = index($2, "="); print img "," bin "," substr($2, 1, i - 1) "," substr($2, i + 1) }' "$tmp/$n.mods.txt" >> "$D/scan/go-binary-build-settings.csv"
		local nmods grpc a2a otel otelhttp rev mod
		nmods=$(awk '$1=="dep"{n++} END{print n+0}' "$tmp/$n.mods.txt")
		grpc=$(awk '$1=="dep" && $2=="google.golang.org/grpc" {print $3}' "$tmp/$n.mods.txt")
		a2a=$(awk '$1=="dep" && $2 ~ /a2a-go/ {printf "%s@%s ", $2, $3}' "$tmp/$n.mods.txt")
		otel=$(awk '$1=="dep" && $2=="go.opentelemetry.io/otel" {print $3}' "$tmp/$n.mods.txt")
		otelhttp=$(awk '$1=="dep" && $2 ~ /otelhttp$/ {print $3}' "$tmp/$n.mods.txt")
		rev=$(awk '$1=="build" && $2 ~ /^vcs.revision=/ {sub(/^vcs.revision=/, "", $2); print $2}' "$tmp/$n.mods.txt")
		mod=$(awk '$1=="build" && $2 ~ /^vcs.modified=/ {sub(/^vcs.modified=/, "", $2); print $2}' "$tmp/$n.mods.txt")
		echo "$n ($img, $gov): $nmods modules linked; grpc: ${grpc:-not linked}; a2a-go: ${a2a:-not linked}; otel: ${otel:-not linked}; otelhttp: ${otelhttp:-not linked}; vcs.revision: ${rev:-not stamped}; vcs.modified: ${mod:-not stamped}"
	done
	rm -rf "$tmp"
	echo "== beside task 3's scan: go-binaries-vs-task-3.py =="
	python3 "$D/scan/go-binaries-vs-task-3.py" "$T3/scan/go-binary-modules.csv" "$D/scan/go-binary-modules.csv" "$T3/scan/summary.csv" "$D/scan/summary.csv"
}
step "(e) build settings and module versions linked into the scanned Go binaries (go version -m), beside task 3's" bash -c "D=$D; T3=$T3; $(declare -f gomods ts); gomods 2>&1 | tee $D/scan/go-binary-modules.txt"
fi

echo "# ADDED readings ($ONLY) finished $(ts)" >> "$LOG"
echo "$(ts) added checks done ($ONLY)"

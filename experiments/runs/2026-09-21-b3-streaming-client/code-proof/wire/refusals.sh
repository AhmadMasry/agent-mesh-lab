#!/usr/bin/env bash
W="${TMPDIR%/}/b3/wire"
for bin in parent tip; do
	while IFS='|' read -r name envs; do
		# shellcheck disable=SC2086
		out=$(env -i PATH="$PATH" $envs "$W/loadgen-$bin" 2>&1); rc=$?
		echo "$bin $name exit=$rc :: $out"
	done <<'CASES'
no-lwi|TARGET_URL=http://127.0.0.1:9
bad-dial|TARGET_URL=http://127.0.0.1:9 LWI=x CLIENT_DIAL=bogus
placeholder-mode|TARGET_URL=http://127.0.0.1:9 LWI=x MODE=${MODE}
subscribe-no-task|TARGET_URL=http://127.0.0.1:9 LWI=x MODE=subscribe
stream-with-retry|TARGET_URL=http://127.0.0.1:9 LWI=x MODE=stream CLIENT_RETRIES=1
CASES
done

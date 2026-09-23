#!/usr/bin/env bash
# summarize.sh: for every captured POST in runs/, the request line, the query (the part after ? if any), and the
# Accept, A2a-Version and Content-Type header values, and the JSON-RPC method in the body. Reads files only.
set -euo pipefail
cd "$(dirname "$0")"
printf 'run,request_line,query,accept,a2a_version,content_type,jsonrpc_method\n'
for f in runs/*/req-2.escaped.txt; do
	r=$(basename "$(dirname "$f")")
	line=$(head -1 "$f" | sed 's/<CR>$//')
	path=$(printf '%s' "$line" | awk '{print $2}')
	q=""; case "$path" in *\?*) q="${path#*\?}" ;; esac
	h() { grep -i "^$1:" "$f" | head -1 | sed 's/<CR>$//' | sed 's/^[^:]*: //'; }
	m=$(tail -1 "$f" | jq -r .method)
	printf '%s,"%s",%s,%s,%s,%s,%s\n' "$r" "$line" "${q:-<none>}" "$(h Accept)" "$(h A2a-Version)" "$(h Content-Type)" "$m"
done

#!/usr/bin/env bash
# go-sources-lists.sh <Makefile> <matrix script>
#
# Says whether the Go-sources pathspec the matrix harness hashes and dirty-checks
# is, word for word, the one the Makefile stamps the Deployments with. The two
# drifted once: fixtures/extauthz joined the Makefile's GO_SOURCES_HASH and
# GO_SOURCES_DIRTY with D-3's deploy commit and not the harness's list, so the
# harness's freshness check could not pass on any tree after it (the currency
# pass of 2026-09-25, go-sources-hash-audit.txt). It compares three strings:
# the pathspec after "git ls-files -s --" in GO_SOURCES_HASH, the one after
# "git status --porcelain --" in GO_SOURCES_DIRTY, and the words of the
# harness's GO_SOURCES_PATHS array; and it requires the harness's two git
# commands to pass that array and nothing else. Follow-ups 23 closed the two
# shapes follow-ups 22's review found accepted: a later line that changes the
# array after its definition (GO_SOURCES_PATHS+=(...), an indexed assignment,
# unset, declare, read and the like) is refused, and each git command must be
# a whole line of its own outside a comment, so the command text kept in a
# comment while the real line differs is refused. It reads the files only.
#
# Output: "ok ..." and exit 0, or "FAIL ..." lines on stderr and exit 1.
set -u
mk="$1"
sh="$2"
fail=0

mk_hash="$(sed -n 's/^GO_SOURCES_HASH := $(shell git ls-files -s -- \(.*\) | git hash-object --stdin)$/\1/p' "$mk")"
mk_dirty="$(sed -n 's/^GO_SOURCES_DIRTY := $(shell git status --porcelain -- \(.*\))$/\1/p' "$mk")"
sh_list="$(sed -n 's/^GO_SOURCES_PATHS=(\(.*\))$/\1/p' "$sh")"

for v in mk_hash mk_dirty sh_list; do
	if [ -z "${!v}" ] || [ "$(printf '%s\n' "${!v}" | wc -l | tr -d ' ')" != "1" ]; then
		echo "FAIL go-sources-lists: $v not found exactly once" >&2
		fail=1
	fi
done
if [ "$fail" = "0" ]; then
	if [ "$mk_hash" != "$mk_dirty" ]; then
		echo "FAIL go-sources-lists: the Makefile's GO_SOURCES_HASH and GO_SOURCES_DIRTY lists differ" >&2
		echo "  hash:  $mk_hash" >&2
		echo "  dirty: $mk_dirty" >&2
		fail=1
	fi
	if [ "$sh_list" != "$mk_hash" ]; then
		echo "FAIL go-sources-lists: $sh's GO_SOURCES_PATHS differs from the Makefile's list" >&2
		echo "  Makefile: $mk_hash" >&2
		echo "  harness:  $sh_list" >&2
		fail=1
	fi
fi
# The harness's lines outside comments; a comment is a line whose first
# non-blank character is #.
code="$(grep -v '^[[:space:]]*#' "$sh")"
# The array is set once and never changed after: its definition is the only
# line that assigns it, whole, indexed or appended, and no builtin writes it.
assigns="$(printf '%s\n' "$code" | grep -cE '(^|[^A-Za-z0-9_{])GO_SOURCES_PATHS(\[[^]]*\])?\+?=')"
if [ "$assigns" != "1" ]; then
	echo "FAIL go-sources-lists: $sh assigns GO_SOURCES_PATHS on $assigns lines, not once" >&2
	fail=1
fi
if printf '%s\n' "$code" | grep -qE '(^|[^A-Za-z0-9_])(unset|declare|typeset|local|readonly|read|mapfile|readarray)[[:space:]][^#]*GO_SOURCES_PATHS'; then
	echo "FAIL go-sources-lists: $sh writes GO_SOURCES_PATHS by a builtin" >&2
	fail=1
fi
# The array is the whole pathspec of both commands: nothing added after it,
# each command a whole line outside a comment, exactly once.
# shellcheck disable=SC2016
for cmd in 'GO_SOURCES_DIRTY="$(git status --porcelain -- "${GO_SOURCES_PATHS[@]}" 2>/dev/null || true)"' 'CHECKOUT_GO_SOURCES_HASH="$(git ls-files -s -- "${GO_SOURCES_PATHS[@]}" 2>/dev/null | git hash-object --stdin 2>/dev/null || true)"'; do
	if [ "$(printf '%s\n' "$code" | grep -cxF -- "$cmd")" != "1" ]; then
		echo "FAIL go-sources-lists: $sh does not run exactly once, as a whole line outside a comment: $cmd" >&2
		fail=1
	fi
done
[ "$fail" = "0" ] || exit 1
echo "ok  go-sources-lists: the harness's pathspec is the Makefile's, and both of its git commands pass it whole"

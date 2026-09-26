#!/usr/bin/env bash
# Follow-ups 24: the host-identifying scan of every file under the run directory before a commit (CLAUDE.md's rule and the
# brief's list): the home-directory prefix and its dashed form, the two temporary-directory prefixes, the host's name
# (read from the host at run time and never printed), email addresses, and every IPv4 address outside the cluster's
# ranges (pod 10.244/16, Service 10.96/12, the kind node network 172.18/16, loopback, Istio's automatic ServiceEntry
# address 240.240.0.1 and the unspecified 0.0.0.0), each with its count of lines per file. It prints counts and the
# matching files only, never the host name. Reads files only. usage: bash scan.sh <run dir>
set -u
R="${1:?}"
HN_S="$(hostname -s 2>/dev/null)"; HN_F="$(hostname 2>/dev/null)"
# the four prefixes are spelled in two halves so that this file does not itself carry the strings it looks for
P1='/Us''ers/'; P2='-Us''ers-'; P3='/private''/tmp'; P4='/var''/folders'
echo "## home and scratch prefixes (lines per file; nothing printed = 0 everywhere)"
grep -rIl -e "$P1" -e "$P2" -e "$P3" -e "$P4" "$R" | while read -r f; do printf '%s %s\n' "$(grep -c -e "$P1" -e "$P2" -e "$P3" -e "$P4" "$f")" "$f"; done
echo "## the host's name (short and full), files matching"
for h in "$HN_S" "$HN_F"; do [ -n "$h" ] && grep -rIl -F -- "$h" "$R"; done | sort -u | while read -r f; do printf '%s %s\n' "$(grep -c -F -e "$HN_S" -e "$HN_F" "$f")" "$f"; done
echo "## email addresses (distinct, with the count of files carrying each)"
grep -rIoh -E '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' "$R" | sort | uniq -c | sort -rn
echo "## IPv4 addresses outside the cluster's ranges (distinct, with counts of lines)"
grep -rIoh -E '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' "$R" | grep -v -E '^(10\.244\.|10\.(9[6-9]|1[0-1][0-9])\.|172\.18\.|127\.0\.0\.1$|240\.240\.0\.1$|0\.0\.0\.0$)' | sort | uniq -c | sort -rn | head -40
echo "## done"

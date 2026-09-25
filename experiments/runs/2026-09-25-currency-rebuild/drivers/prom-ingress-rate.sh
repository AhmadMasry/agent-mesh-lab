#!/usr/bin/env bash
# Reads only: ztunnel's istio_tcp_connections_opened_total for the leg prometheus -> agentgateway-ingress (reporter
# destination), summed over the ztunnel pods, twice, 60 s apart.
readc() { for z in $(kubectl -n istio-system get pod -l app=ztunnel -o jsonpath='{.items[*].metadata.name}'); do kubectl get --raw "/api/v1/namespaces/istio-system/pods/$z:15020/proxy/metrics" 2>/dev/null | grep '^istio_tcp_connections_opened_total' | grep 'source_workload="prometheus"' | grep 'destination_workload="agentgateway-ingress"' | grep 'reporter="destination"' | awk '{s+=$NF} END{print s+0}'; done | awk '{s+=$1} END{print s+0}'; }
t0=$(date -u +%FT%TZ); a=$(readc); e=$(( $(date +%s) + 60 )); while [ "$(date +%s)" -lt "$e" ]; do perl -e 'select(undef,undef,undef,1)'; done
t1=$(date -u +%FT%TZ); b=$(readc); echo "$t0 $a ; $t1 $b ; delta $((b-a)) in 60 s (scrape interval 15 s)"

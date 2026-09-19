#!/bin/bash
# Local check of Jaeger's service-list endpoints on both sides of the 2.20.0 -> 2.21.0 bump.
# Local docker only: no cluster is involved. Two spans of two service names are sent over
# OTLP/HTTP so the list is not empty, then the legacy and the v3 endpoints are read. The query
# port is published on loopback 26686 (the walkthrough forwards 16686; another port is used here
# so the check cannot collide with a port-forward) and OTLP/HTTP on 24318.
set -u
wait_for() { i=0; until curl -s -o /dev/null "$1" || [ $i -ge 80 ]; do i=$((i+1)); python3 -c 'import time; time.sleep(0.5)'; done; }
now_ns() { python3 -c 'import time; print(time.time_ns())'; }
for tag in 2.21.0 2.20.0; do
  name="fu19-jaeger-${tag//./-}"
  docker rm -f "$name" >/dev/null 2>&1
  echo "## jaegertracing/jaeger:$tag   started $(date -u +%FT%TZ)"
  echo "\$ docker run -d --name $name --read-only -p 127.0.0.1:26686:16686 -p 127.0.0.1:24318:4318 jaegertracing/jaeger:$tag"
  docker run -d --name "$name" --read-only -p 127.0.0.1:26686:16686 -p 127.0.0.1:24318:4318 "jaegertracing/jaeger:$tag" >/dev/null
  echo "image id: $(docker inspect -f '{{.Image}}' "$name")"
  wait_for http://127.0.0.1:26686/
  for svc in worker orchestrator; do
    t0=$(now_ns); t1=$((t0 + 1000000))
    tid=$(python3 -c 'import secrets; print(secrets.token_hex(16))'); sid=$(python3 -c 'import secrets; print(secrets.token_hex(8))')
    body="{\"resourceSpans\":[{\"resource\":{\"attributes\":[{\"key\":\"service.name\",\"value\":{\"stringValue\":\"$svc\"}}]},\"scopeSpans\":[{\"scope\":{\"name\":\"fu19-local-check\"},\"spans\":[{\"traceId\":\"$tid\",\"spanId\":\"$sid\",\"name\":\"local-check\",\"kind\":2,\"startTimeUnixNano\":\"$t0\",\"endTimeUnixNano\":\"$t1\"}]}]}]}"
    echo "POST /v1/traces (service.name=$svc) -> HTTP $(curl -s -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' -d "$body" http://127.0.0.1:24318/v1/traces)"
  done
  python3 -c 'import time; time.sleep(2)'
  for path in /api/services /api/v3/services; do
    code=$(curl -s -o body.tmp -w '%{http_code}' "http://127.0.0.1:26686$path")
    echo "\$ curl -s http://127.0.0.1:26686$path    -> HTTP $code"
    echo "raw response: $(head -c 400 body.tmp | tr '\n' ' ')"
  done
  echo "\$ curl -s http://127.0.0.1:26686/api/v3/services | jq -r '.services[]' | sort"
  curl -s http://127.0.0.1:26686/api/v3/services | jq -r '.services[]' | sort
  echo "shape: $(curl -s http://127.0.0.1:26686/api/v3/services | jq -c '{keys: keys, services_type: (.services|type), element_type: (.services[0]|type)}')"
  docker rm -f "$name" >/dev/null 2>&1 && echo "container $name stopped and removed $(date -u +%FT%TZ)"
  echo
done
rm -f body.tmp

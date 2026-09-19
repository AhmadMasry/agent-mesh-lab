# jaeger-spans.jq — one CSV row per span, from a response to the trace backend's
# GET /api/v3/traces binding.
#
# Run slurped, because that binding is a server-streaming RPC and its HTTP body is
# a sequence of JSON objects rather than one:
#
#   jq -r -s -f experiments/lib/jaeger-spans.jq trace.json
#
# Each chunk is the documented result envelope, {"result": <TracesData>}, holding
# OTLP resourceSpans. Both the envelope and the bare TracesData are accepted, so a
# chunk that arrives without the envelope is still read.
#
# Columns. The first ten were fixed by the Gate 3 plan; the last two were appended
# at the end on 2026-09-19 (follow-ups 18), so a reader that takes the first ten
# by position, or any of them by name, reads what it read before:
#   trace_id,span_id,parent_span_id,service,operation,start_us,duration_us,
#   lab_work_item,lab_message_id,http_status,route,retry_attempt
#
# `route` and `retry_attempt` are agentgateway's span attributes `route` and
# `retry.attempt`, copied as written. Measured at agentgateway v1.5.0 on the
# topology of 2026-09-19, where one proxy (`agw-central`) serves the agent routes
# and the model route: the proxy's SERVER span, one per request it received,
# carries `route` as <namespace>/<HTTPRoute name>, and carries `retry.attempt`
# only when the proxy re-sent that request (value 1 after one re-send; absent on
# a request it sent once). Its CLIENT spans, one per upstream attempt and children
# of that SERVER span, carry neither. No other service in this lab sets either
# attribute, so both columns are empty on every other row. The service name no
# longer says which leg of a work item a proxy span belongs to; `route` does, and
# experiments/lib/derive-layer.sh keys on it.
#
# `http_status` is the response status under whichever name the span's writer
# uses, first match in this order: `http.response.status_code` and
# `http.status_code`, the two names the HTTP semantic conventions have used (read
# from recorded traces of 2026-09-19: the lab's Go binaries write the first, the
# Python orchestrator the second), then `http.status`, the name agentgateway
# v1.5.0 writes it under on both of its proxies. The third was added on 2026-09-19
# (follow-ups 19): until then the column was empty on every proxy row, so a
# spans.csv exported before that day says nothing about what a proxy answered,
# and one exported since does -- a proxy's 503 for an upstream that closed its
# connection now shows beside the 200 that upstream's own span may carry. No
# lab TOOL reads this column: no script, no Makefile line and no positional reader
# of spans.csv. One DOCUMENT does: a step of docs/walkthrough.md reads and prints
# it for every span, and the listing under that step, taken before this change,
# shows the proxy rows' cell empty where an export taken since fills it (`200`, or
# `503` on a closed upstream). That document is re-taken whole in follow-ups 20 and
# was left as it is here.
#
# Two shapes are handled deliberately. Identifiers arrive from this binding as
# lowercase hex; anything else is passed through unchanged rather than guessed at,
# so a change in the backend's encoding shows up in the file instead of being
# silently reformatted. Timestamps arrive as nanoseconds in a JSON string, which is
# larger than a double can hold exactly, so microseconds are taken by dropping the
# last three digits of the string rather than by dividing.

def anyval:
  if . == null then ""
  elif type == "string" then .
  elif has("stringValue") then .stringValue
  elif has("intValue") then (.intValue | tostring)
  elif has("boolValue") then (.boolValue | tostring)
  elif has("doubleValue") then (.doubleValue | tostring)
  elif has("bytesValue") then .bytesValue
  elif has("arrayValue") then ((.arrayValue.values // []) | map(anyval) | join("|"))
  elif has("kvlistValue") then ((.kvlistValue.values // []) | map(.key + "=" + (.value | anyval)) | join("|"))
  else "" end;

def attr($attrs; $key):
  ($attrs // []) | map(select(.key == $key)) as $hit
  | if ($hit | length) == 0 then null else ($hit[0].value | anyval) end;

# First non-null of a list of attribute keys, for fields the semantic conventions
# have renamed between versions.
def firstattr($attrs; $keys):
  ($keys | map(attr($attrs; .)) | map(select(. != null and . != ""))) as $hit
  | if ($hit | length) == 0 then "" else $hit[0] end;

def us:
  if . == null then 0
  elif type == "string" then (if (. | length) > 3 then (.[0:(. | length) - 3] | tonumber) else 0 end)
  elif type == "number" then ((. / 1000) | floor)
  else 0 end;

def csv:
  tostring
  | if test("[\",\n\r]") then "\"" + (gsub("\"" ; "\"\"")) + "\"" else . end;

def rows:
  [ .[]
    | (if type == "object" and has("result") then .result else . end)
    | (.resourceSpans // [])[]
    | . as $rs
    | ($rs.resource.attributes // []) as $ra
    | ($rs.scopeSpans // $rs.instrumentationLibrarySpans // [])[]
    | (.spans // [])[]
    | . as $s
    | ($s.attributes // []) as $sa
    | {
        trace_id:       ($s.traceId // ""),
        span_id:        ($s.spanId // ""),
        parent_span_id: ($s.parentSpanId // ""),
        service:        (attr($ra; "service.name") // ""),
        operation:      ($s.name // ""),
        start_us:       ($s.startTimeUnixNano | us),
        duration_us:    (($s.endTimeUnixNano | us) - ($s.startTimeUnixNano | us)),
        lab_work_item:  (firstattr($sa; ["lab.work_item"])),
        lab_message_id: (firstattr($sa; ["lab.message_id"])),
        http_status:    (firstattr($sa; ["http.response.status_code", "http.status_code", "http.status"])),
        route:          (firstattr($sa; ["route"])),
        retry_attempt:  (firstattr($sa; ["retry.attempt"]))
      }
  ]
  | sort_by(.start_us, .span_id);

"trace_id,span_id,parent_span_id,service,operation,start_us,duration_us,lab_work_item,lab_message_id,http_status,route,retry_attempt",
( rows[]
  | [ .trace_id, .span_id, .parent_span_id, .service, .operation,
      .start_us, .duration_us, .lab_work_item, .lab_message_id, .http_status,
      .route, .retry_attempt ]
  | map(csv) | join(",") )

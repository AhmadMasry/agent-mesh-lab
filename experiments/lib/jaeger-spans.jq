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
# Columns, fixed by the Gate 3 plan:
#   trace_id,span_id,parent_span_id,service,operation,start_us,duration_us,
#   lab_work_item,lab_message_id,http_status
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
        http_status:    (firstattr($sa; ["http.response.status_code", "http.status_code"]))
      }
  ]
  | sort_by(.start_us, .span_id);

"trace_id,span_id,parent_span_id,service,operation,start_us,duration_us,lab_work_item,lab_message_id,http_status",
( rows[]
  | [ .trace_id, .span_id, .parent_span_id, .service, .operation,
      .start_us, .duration_us, .lab_work_item, .lab_message_id, .http_status ]
  | map(csv) | join(",") )

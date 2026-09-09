# A.2 / where a client retry can be configured — the lines that were read

Read on 2026-09-09 for the third A.2 checklist box. Each entry names the upstream
URL the text was fetched from in that session and the local file that is the
pinned artifact the lab actually runs, so the quote can be checked against both.

One quotation below is cut short. Two a2a-go doc comments open with a clause
naming a deployment context whose first word this repository's language rule
(CLAUDE.md rule 9) forbids in tracked text. The rest of each sentence is quoted
verbatim and contiguously, and the file and line number are given so the full
line can be read at the URL.

---

## 1. a2a-go v2.5.0 — no retry option; the caller's `*http.Client` is the only place

- URL: `https://raw.githubusercontent.com/a2aproject/a2a-go/v2.5.0/a2aclient/jsonrpc.go`
- Local: `~/go/pkg/mod/github.com/a2aproject/a2a-go/v2@v2.5.0/a2aclient/`
- Pinned in `versions.yaml` as `a2a-go: v2.5.0`.

The transport constructors take an `*http.Client` and nothing else that bears on
retrying:

```go
// jsonrpc.go:57
func NewJSONRPCTransport(url string, client *http.Client) Transport

// jsonrpc.go:40
func WithJSONRPCTransport(client *http.Client) FactoryOption
```

`jsonrpc.go:50-51`, quoted from the second word of the sentence onward:

> provide a client with appropriate timeout, retry policy,
> and connection pooling configured for your requirements.

`rest.go:42-43` carries the same sentence for `NewRESTTransport`.

`agentcard/resolver.go:62`, quoted in full:

> // Client can be used to configure appropriate timeout, retry policy, and connection pooling

Those three lines are the only occurrences of `retry` anywhere under
`a2aclient/` outside its tests (`grep -rn -i 'retry\|retries\|backoff' a2aclient/`,
three hits, all doc comments). They tell the caller to bring a retry policy on
the HTTP client; the SDK offers none of its own.

`Config`, the struct `WithConfig` sets (`client.go:28-46`), holds four fields:
`PushConfig`, `AcceptedOutputModes`, `PreferredTransports`,
`DisableTenantPropagation`. None is a retry.

The complete set of `FactoryOption`s at this version is seven: `WithConfig`,
`WithTransport`, `WithCompatTransport`, `WithCallInterceptors`,
`WithDefaultsDisabled` (`factory.go`), `WithJSONRPCTransport` (`jsonrpc.go:40`)
and `WithRESTTransport` (`rest.go:57`). None is a retry. `WithAdditionalOptions`
(`factory.go:304`) is not one of them: it takes a `*Factory` and more options and
returns a `*Factory`.

## 2. a2a-python 1.1.2 — no retry option; the caller's `httpx.AsyncClient` is the only place

- URL: `https://raw.githubusercontent.com/a2aproject/a2a-python/v1.1.2/src/a2a/client/client.py`
- Local: `agents/orchestrator/.venv/lib/python3.13/site-packages/a2a/client/`
- Pinned in `versions.yaml` as `a2a-python: 1.1.2`.

`ClientConfig`, the one configuration object `create_client` takes, has eight
fields: `streaming` (True), `polling` (False), `httpx_client` (None),
`grpc_channel_factory` (None), `supported_protocol_bindings` ([]),
`use_client_preference` (False), `accepted_output_modes` ([]),
`push_notification_config` (None). None is a retry.

`grep -rni 'retry\|retries\|backoff'` over the whole installed `a2a/client/`
package returns **no matches at all** — not even a doc comment. The transport
takes the caller's client and sends through it:

```python
# a2a/client/transports/jsonrpc.py:346-349
request = self.httpx_client.build_request(
    'POST', self.url, json=payload, **(http_kwargs or {})
)
return await send_http_request(self.httpx_client, request)
```

## 3. httpx 0.28.1 — `retries` exists, and covers connection attempts only

- URL: `https://raw.githubusercontent.com/encode/httpx/0.28.1/httpx/_transports/default.py`
- Local: `agents/orchestrator/.venv/lib/python3.13/site-packages/httpx/_transports/default.py`
- Version from the committed lockfile `agents/orchestrator/uv.lock` (`name = "httpx"`,
  `version = "0.28.1"`), a transitive dependency of `a2a-sdk[http-server]==1.1.2`.

Module docstring, verbatim:

> The following additional keyword arguments are currently supported by httpcore...
>
> * uds: str
> * local_address: str
> * retries: int

> \# Using advanced httpcore configuration, with connection retries.
> transport = httpx.HTTPTransport(retries=1)

Both `HTTPTransport.__init__` (line 147) and `AsyncHTTPTransport.__init__`
(line 291) declare `retries: int = 0`, and both pass it straight through:
`httpcore.ConnectionPool(..., retries=retries, ...)` at line 165 and
`httpcore.AsyncConnectionPool(..., retries=retries, ...)` at line 309.

**What httpcore does with it** (httpcore 1.0.9, same lockfile;
`https://raw.githubusercontent.com/encode/httpcore/1.0.9/httpcore/_async/connection.py`):
the value is used in exactly one place, the `_connect` method, and nowhere else:

```python
# httpcore/_async/connection.py:110
retries_left = self._retries
...
# 159-162
            except (ConnectError, ConnectTimeout):
                if retries_left <= 0:
                    raise
                retries_left -= 1
```

So `retries` retries the establishment of a TCP connection, and only for
`ConnectError` and `ConnectTimeout`. A request that was already written and then
failed is not covered.

## 4. Go `net/http` — what it replays without being asked

Already recorded in the Gate 1 baseline findings entry and in the package
documentation of `internal/httpclient/httpclient.go`, which names the two
`net/http` rules it depends on: `persistConn.shouldRetryRequest` in
`net/http/transport.go` and `Request.isReplayable` in `net/http/request.go`. A
POST without an `Idempotency-Key` header is never replayed once it has been
written; a request lost on a reused connection before anything was written is
redialled, and that replay never reached the server.

## 5. The layers the lab added, and their defaults

None of these existed before this task, none is on unless asked, and each has a
test that fails if its default changes.

| Knob | Where it lives | Default | Asserted off by |
|---|---|---|---|
| `CLIENT_RETRIES` (Go) | `httpclient.NewRetryingOn` wraps the transport in `retryTransport` | `0`, i.e. `httpclient.New`, no wrapper | `TestNew_DefaultsHaveNoRetries`, `TestKnobs_DefaultOff` |
| `CLIENT_RETRY_ON` (Go) | the mode `retryTransport` re-sends on | `transport` | `TestParseRetryOn_DefaultsToTransport`, `TestKnobs_DefaultOff` |
| `CLIENT_SDK_RESEND` (Go) | `fixtures/loadgen`, one more `client.SendMessage(ctx, req)` with the same request | `off` | `TestKnobs_DefaultOff` |
| `CLIENT_RETRIES` (Python) | `httpx.AsyncHTTPTransport(retries=n)` | `0` | `test_knobs_default_off`, `test_transport_retries_setting_recorded` |
| `CLIENT_TRANSPORT_RESEND` (Python) | `ResendOnceTransport` wrapping the httpx transport | `off` | `test_knobs_default_off` |
| `CLIENT_RETRY_ON` (Python) | the mode `ResendOnceTransport` re-sends on | `transport` | `test_knobs_default_off`, `test_retry_on_mode_is_asked_for_by_name` |
| `CLIENT_SDK_RESEND` (Python) | `Forwarder.forward`, one more `client.send_message(request)` with the same request object | `off` | `test_knobs_default_off` |

The two HTTP-layer additions (`retryTransport`, `ResendOnceTransport`) take one
of two modes. `transport`, the default, re-sends on a transport error and never
on a response, asserted by `TestNewRetrying_DoesNotRetryOnResponse`,
`TestNewRetrying_DoesNotRetryOn503ByDefault` and
`test_resend_once_transport_does_not_resend_a_response`. `transport+503` also
re-sends once on an HTTP 503, and on no other status, asserted by
`TestNewRetrying_503ModeDoesNotRetryOnOtherResponses` and
`test_resend_once_transport_on_503_does_not_resend_other_statuses`. The mode
exists because of a measured path property rather than a preference: behind the
worker's agentgateway waypoint a receiver-side connection close reaches the
client as a 503, so an HTTP-layer retry there has to be written against a
response class or it can never fire. The evidence is
`experiments/runs/2026-09-09-a2-go-http/waypoint-503-probe.txt`. Naming the mode
is not the same as switching a retry on: with `CLIENT_RETRIES` unset, or
`CLIENT_TRANSPORT_RESEND` off, there is nothing to widen, which
`TestKnobs_RetryOnModeIsAskedForByName` and `test_retry_on_mode_is_asked_for_by_name`
assert, and the run script refuses the mode on rows that have no HTTP-layer
resend.

For completeness, the lab's third retry-capable layer is not an A2A client at
all: the model client's `MODEL_MAX_RETRIES` (default 0) sets `max_retries` on the
`openai` client, whose own default is 2. That layer is the A.3 matrix's R3 row,
not A.2's subject.

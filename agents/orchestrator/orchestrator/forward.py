"""Forward mode: send the message on to a downstream agent with the a2a-python client.

The httpx client is built by hand with connection retries off; the a2a-python
client has no retry option of its own. One SendMessage per forward().

Every forward also names itself in three headers beside the message:
``X-Logical-Work-Item-Id``, ``X-A2A-Message-Id`` (the id this forward minted) and
``X-Caller``. The work item travels in ``Message.metadata``, which no HTTP
instrumentation reads, so without the headers the downstream agent's server span
could not be attributed to the work item. The A2A body is unchanged by them, and
no task id is sent because the forward has none yet.

Three knobs exist for Experiment A.2, which asks what a client puts on the wire
when it retries. All three are read from the environment, all three default to
off, and `test_knobs_default_off` asserts that:

  * ``CLIENT_RETRIES=<n>``          n > 0 builds the httpx transport with
    ``retries=n``. httpx passes that to the httpcore pool, which applies it to
    connection attempts only, so it covers a failure to connect and nothing that
    happens after the request was written.
  * ``CLIENT_TRANSPORT_RESEND=on``  wraps the transport in ResendOnceTransport,
    which re-sends the same request once when the send fails at the transport,
    whatever the failure was.
  * ``CLIENT_RETRY_ON=<mode>``      what that resend acts on: ``transport``
    (default; a transport error only) or ``transport+503`` (also one resend on an
    HTTP 503 response, and on no other status). The mode is not a switch: with
    ``CLIENT_TRANSPORT_RESEND`` off there is no resend to widen.
  * ``CLIENT_SDK_RESEND=on``        after a failed send, hand the same
    SendMessageRequest object to the SDK's send_message a second time.

The A.2 run script sets one of them for one measured repetition. Nothing else in
the lab sets any of them, so every other run sends exactly once.

One setting exists for follow-on D-1, which runs Experiment B with this SDK as
the reconnecting client (the author's note of 2026-09-24). It is read by
server.app_from_env, stops the process at start on a value it does not read, and
is off by default:

  * ``FORWARD_RESUBSCRIBE=on``  the forward is one ``SendStreamingMessage``, and
    if that stream ends without a terminal event -- it runs out, or it raises --
    and a task id was seen on it, EXACTLY ONE ``SubscribeToTask`` is sent for
    that task and read to its end. Whatever that one does, nothing is sent
    after it: it is the behaviour under test, and rule 4 forbids anything more.
    Both requests are recorded as ``forward`` ledger lines (ForwardLedger). Off,
    the forward is the unary ``SendMessage`` it has always been and no forward
    line is written. On together with CLIENT_RETRIES, CLIENT_TRANSPORT_RESEND
    or CLIENT_SDK_RESEND it is refused when the Forwarder is built, which is at
    start.
"""
from __future__ import annotations

import asyncio
import os
import uuid
from contextvars import ContextVar
from dataclasses import dataclass
from typing import Any, TextIO
from urllib.parse import urlsplit

import httpx
from a2a.client import A2ACardResolver, ClientConfig, create_client
from a2a.types import Message, Part, Role, SendMessageRequest, SubscribeToTaskRequest, Task, TaskState
from opentelemetry import trace
from opentelemetry.trace import SpanKind

from orchestrator.ledger import LineWriter, now

FORWARD_RESUBSCRIBE_ENV = "FORWARD_RESUBSCRIBE"


def forward_resubscribe_from(value: str) -> bool:
    """The setting's value: False when empty, True for exactly "on", ValueError
    otherwise. Matched exactly, as REFUSE_OPERATION and LEDGER_HEADERS are."""
    if value == "":
        return False
    if value == "on":
        return True
    raise ValueError(f"{FORWARD_RESUBSCRIBE_ENV}={value!r} is not a value this agent reads; want on, or empty for off")


# The states after which a task changes no more (A2A v1.0: completed, failed,
# canceled, rejected). input-required and auth-required are interrupted, not
# terminal; this lab's executors never enter them.
TERMINAL_STATES = frozenset({TaskState.TASK_STATE_COMPLETED, TaskState.TASK_STATE_FAILED,
                             TaskState.TASK_STATE_CANCELED, TaskState.TASK_STATE_REJECTED})

OP_STREAM = "SendStreamingMessage"
OP_SUBSCRIBE = "SubscribeToTask"

# What the first stream's end line says was done about it.
RESUBSCRIBE_SENT = "sent"
RESUBSCRIBE_NOT_NEEDED = "not-needed"  # a terminal event arrived on the stream
RESUBSCRIBE_NO_TASK_ID = "no-task-id"  # the stream ended before any event named a task


def text_of(obj: Task | Message) -> str:
    if isinstance(obj, Task):
        for artifact in obj.artifacts:
            for part in artifact.parts:
                if part.HasField("text"):
                    return part.text
        if obj.status.HasField("message"):
            return text_of(obj.status.message)
        return ""
    return "".join(part.text for part in obj.parts if part.HasField("text"))


def _positive_int(name: str) -> int:
    """Read a count knob. Anything that is not a positive integer leaves it at 0."""
    try:
        value = int(os.getenv(name, ""))
    except ValueError:
        return 0
    return value if value > 0 else 0


def _switched_on(name: str) -> bool:
    """Read a flag knob. Only the exact value "on" turns it on."""
    return os.getenv(name) == "on"


# What ResendOnceTransport re-sends on. The 503 mode exists because A.2 measured
# what a receiver-side connection close looks like to this client through an
# agentgateway waypoint: the waypoint answers 503, so a client that re-sends only
# on a transport error never re-sends at all on that path.
RETRY_ON_TRANSPORT = "transport"
RETRY_ON_TRANSPORT_OR_503 = "transport+503"


def _retry_on() -> str:
    """Read the mode. Only the exact string "transport+503" widens it."""
    return RETRY_ON_TRANSPORT_OR_503 if os.getenv("CLIENT_RETRY_ON") == RETRY_ON_TRANSPORT_OR_503 else RETRY_ON_TRANSPORT


# The GenAI `invoke_agent` span, added 2026-09-16 (follow-ups 14). This is the
# only OpenTelemetry code in this project: everything else the agent emits comes
# from instrumentations the `opentelemetry-instrument` launcher loads, and none of
# them knows that a forward is an agent invocation rather than one more HTTP
# request. The names below were read from the OpenTelemetry GenAI semantic
# conventions, docs/gen-ai/gen-ai-agent-spans.md in
# open-telemetry/semantic-conventions-genai at commit
# c88d504ab3d9879f8e50d3cc87e69775e11db234, whose Status is Development
# (versions.yaml, genai-semantic-conventions). The Go client says the same things
# through internal/otel.InvokeAgent.
#
# The span wraps the send, including whichever of the knobs above re-sends: the
# conventions say a span "SHOULD cover the duration of the logical operation with
# all retries", and it keeps this instrumentation out of the knobs' code paths,
# which A.2 counts.
_TRACER = trace.get_tracer("orchestrator.forward")

_GEN_AI_OPERATION_NAME = "gen_ai.operation.name"
_GEN_AI_PROVIDER_NAME = "gen_ai.provider.name"
_GEN_AI_AGENT_NAME = "gen_ai.agent.name"
_GEN_AI_AGENT_VERSION = "gen_ai.agent.version"
_GEN_AI_AGENT_DESCRIPTION = "gen_ai.agent.description"
_GEN_AI_CONVERSATION_ID = "gen_ai.conversation.id"
_SERVER_ADDRESS = "server.address"
_SERVER_PORT = "server.port"
_ERROR_TYPE = "error.type"

_OPERATION_INVOKE_AGENT = "invoke_agent"
# The recorded provider-name choice for the agent leg; internal/otel.go and
# versions.yaml (genai-provider-name) carry the reasoning and the quoted sentence.
_PROVIDER_A2A = "a2a"


def _server_attributes(raw_url: str) -> dict[str, object]:
    """``server.address`` and ``server.port`` from the URL this client dials.

    The conventions mark ``server.address`` Recommended and ``server.port``
    Conditionally Required "If ``server.address`` is set", and the note beside each
    says the value "SHOULD represent the server address behind any intermediaries,
    for example proxies, if it's available". What is available here is the URL the
    card advertised and nothing more. A URL that does not parse, or that names no
    host, sets neither attribute; a port the URL omits is the scheme's default,
    which is what this client will dial.

    The host is read inside the same ``ValueError`` guard as the split, so every
    read of the URL that can refuse it is covered. Under Python 3.14.7, the
    interpreter the tests run on, a malformed IPv6 literal such as ``http://[::1/``
    is refused by ``urlsplit`` itself and ``.hostname`` has no raising path; the
    guard does not depend on either staying true.

    A port that is not a TCP server port leaves ``server.address`` set and
    ``server.port`` unset, rather than filled with the scheme's default, which would
    be a guess: one that does not read as a number, one above 65535 however long
    (both refused by ``.port`` with ``ValueError``), and 0, which no server listens
    on. These are internal/otel serverAttributes' answers on the same inputs, with
    one difference that belongs to the parsers: Go's ``url.Parse`` refuses a port
    that is not all digits, so Go sets neither attribute there, while ``urlsplit``
    accepts the URL and keeps its host.
    """
    try:
        parsed = urlsplit(raw_url)
        hostname = parsed.hostname
    except ValueError:
        return {}
    if not hostname:
        return {}
    try:
        port = parsed.port
    except ValueError:
        return {_SERVER_ADDRESS: hostname}
    if port == 0:
        return {_SERVER_ADDRESS: hostname}
    if port is None:
        port = {"http": 80, "https": 443}.get(parsed.scheme)
    if port is None:
        return {_SERVER_ADDRESS: hostname}
    return {_SERVER_ADDRESS: hostname, _SERVER_PORT: port}


def _agent_url(card) -> str:
    """The interface URL this client will dial, when the card leaves no choice.

    Taken only when the card advertises exactly one interface -- a lab card does --
    because with several the client's own choice of interface, not this function's,
    is the one being dialled.
    """
    if card is None or len(card.supported_interfaces) != 1:
        return ""
    return card.supported_interfaces[0].url


def _invoke_agent_span(card, work_item: str, message_id: str):
    """Start the client span for one invocation of the downstream agent.

    Span name is ``invoke_agent {gen_ai.agent.name}`` when the card gave a name and
    ``invoke_agent`` when it did not, which is what the conventions ask for. The
    agent's name, version and description are each Conditionally Required "When
    available." and the resolved card carries all three; ``gen_ai.agent.id`` is not
    set, because it is Conditionally Required "If applicable" and an A2A v1.0
    AgentCard has no id field. The lab identity attributes are set here rather than
    left to the collector's transform: this span is not an HTTP span, so it carries
    none of the captured headers the transform reads.
    """
    agent_name = card.name if card is not None else ""
    name = f"{_OPERATION_INVOKE_AGENT} {agent_name}" if agent_name else _OPERATION_INVOKE_AGENT
    attributes: dict[str, object] = {
        _GEN_AI_OPERATION_NAME: _OPERATION_INVOKE_AGENT,
        _GEN_AI_PROVIDER_NAME: _PROVIDER_A2A,
        "lab.work_item": work_item,
        "lab.message_id": message_id,
        "lab.caller": "orchestrator",
    }
    if card is not None:
        for key, value in ((_GEN_AI_AGENT_NAME, card.name),
                           (_GEN_AI_AGENT_VERSION, card.version),
                           (_GEN_AI_AGENT_DESCRIPTION, card.description)):
            if value:
                attributes[key] = value
    attributes.update(_server_attributes(_agent_url(card)))
    return _TRACER.start_as_current_span(name, kind=SpanKind.CLIENT, attributes=attributes)


@dataclass(frozen=True)
class ForwardIdentity:
    """The two identity values that change from one forward to the next."""

    work_item: str = ""
    message_id: str = ""


# Read by the request event hook below. A context variable rather than an
# attribute because two forwards can be in flight at once in this process, and
# each asyncio task carries its own copy; the default is empty, so a request the
# client sends outside a forward (the downstream card fetch) carries neither header.
FORWARD_IDENTITY: ContextVar[ForwardIdentity] = ContextVar("forward_identity", default=ForwardIdentity())


async def set_identity_headers(request: httpx.Request) -> None:
    """Put the current forward's identity on the request about to be sent.

    A request event hook, because the SDK builds and sends the request itself and
    takes no per-request headers from this agent. X-Caller is not set here: it
    never changes, so it is a client-level header.
    """
    identity = FORWARD_IDENTITY.get()
    if identity.work_item:
        request.headers["X-Logical-Work-Item-Id"] = identity.work_item
    if identity.message_id:
        request.headers["X-A2A-Message-Id"] = identity.message_id


class ResendOnceTransport(httpx.AsyncBaseTransport):
    """Re-sends the same request once when the wrapped transport fails.

    This is the lab's own HTTP-layer retry for the A.2 runs, and it exists because
    httpx's own ``retries`` covers connection attempts only. What it re-sends is
    the same httpx.Request object: the same bytes, the same headers, so the
    receiver's pre-dispatch ledger sees the second delivery carrying the same
    JSON-RPC id, the same messageId and the same body hash as the first.

    With ``on_503=False``, the default, only an ``httpx.TransportError`` is
    re-sent and a response of any status is returned to the caller untouched.
    With ``on_503=True`` a 503 response is also re-sent, once, and no other status
    ever is: a narrow allowance for one measured gateway behaviour rather than a
    retry-on-failure policy.
    """

    def __init__(self, inner: httpx.AsyncBaseTransport, *, on_503: bool = False) -> None:
        self._inner = inner
        self.on_503 = on_503
        self.resends = 0

    async def handle_async_request(self, request: httpx.Request) -> httpx.Response:
        try:
            response = await self._inner.handle_async_request(request)
        except httpx.TransportError:
            self.resends += 1
            return await self._inner.handle_async_request(request)
        if self.on_503 and response.status_code == 503:
            # A response the caller will never see is closed first, so no reader
            # is left open on it.
            await response.aclose()
            self.resends += 1
            return await self._inner.handle_async_request(request)
        return response

    async def aclose(self) -> None:
        await self._inner.aclose()


class StreamRead:
    """What one streamed request carried, as this client read it: every event,
    in order, and how the request ended. Reads; never sends."""

    def __init__(self, operation: str, work_item: str, message_id: str, requested_task_id: str = "") -> None:
        self.operation = operation
        self.work_item = work_item
        self.message_id = message_id
        self.requested_task_id = requested_task_id
        self.ts_sent = now()
        self.events = 0
        self.first: tuple[str, str, str] = ("", "", "")
        self.last: tuple[str, str] = ("", "")
        self.task_id = ""
        self.context_id = ""
        self.terminal_state: int | None = None
        self.message: Message | None = None
        self.answer = ""
        self.status_text = ""
        self.stream_end = ""
        self.error = ""
        self.error_type = ""

    @property
    def terminal_seen(self) -> bool:
        return self.terminal_state is not None or self.message is not None

    def read(self, response) -> tuple[str, str, str, str]:
        """Take one StreamResponse in; return its kind, task id, context id and
        state for the event line."""
        kind, task_id, context_id, state = "", "", "", ""
        if response.HasField("task"):
            task = response.task
            kind, task_id, context_id, state = "task", task.id, task.context_id, TaskState.Name(task.status.state)
            if text_of(task):
                self.answer = text_of(task)
            if task.status.state in TERMINAL_STATES:
                self.terminal_state = task.status.state
                if task.status.HasField("message"):
                    self.status_text = text_of(task.status.message)
        elif response.HasField("message"):
            message = response.message
            kind, task_id, context_id = "message", message.task_id, message.context_id
            self.message = message
        elif response.HasField("status_update"):
            update = response.status_update
            kind, task_id, context_id = "status-update", update.task_id, update.context_id
            state = TaskState.Name(update.status.state)
            if update.status.state in TERMINAL_STATES:
                self.terminal_state = update.status.state
                if update.status.HasField("message"):
                    self.status_text = text_of(update.status.message)
        elif response.HasField("artifact_update"):
            update = response.artifact_update
            kind, task_id, context_id = "artifact-update", update.task_id, update.context_id
            text = "".join(part.text for part in update.artifact.parts if part.HasField("text"))
            self.answer = self.answer + text if update.append else text
        self.events += 1
        if self.events == 1:
            self.first = (kind, state, task_id)
        self.last = (kind, state)
        if task_id:
            self.task_id = task_id
        if context_id:
            self.context_id = context_id
        return kind, task_id, context_id, state

    def ended(self, exc: BaseException | None) -> None:
        if exc is None:
            self.stream_end = "eof"
        else:
            self.stream_end = "error"
            self.error = str(exc)
            self.error_type = type(exc).__qualname__

    def result(self) -> str:
        """The answer, or the error a caller should see: a terminal state other
        than completed is a response that arrived, and it is reported as such."""
        if self.message is not None:
            return text_of(self.message)
        if self.terminal_state == TaskState.TASK_STATE_COMPLETED:
            return self.answer
        if self.terminal_state is not None:
            raise RuntimeError(f"downstream task {self.task_id} ended in {TaskState.Name(self.terminal_state)}: "
                               f"{self.status_text}")
        raise RuntimeError(f"downstream {self.operation} ended without a terminal event "
                           f"({self.stream_end}{': ' + self.error if self.error else ''})")


class ForwardLedger:
    """The forward's own lines, written only with FORWARD_RESUBSCRIBE on: one
    "event" line per event this client read and one "end" line per request,
    saying how it ended. The end line of the SendStreamingMessage says what was
    done about it in "resubscribe"."""

    def __init__(self, out: TextIO | None) -> None:
        self.writer = LineWriter(out)

    def event(self, read: StreamRead, kind: str, task_id: str, context_id: str, state: str) -> None:
        self.writer.write({
            "ledger": "forward", "ts": now(), "operation": read.operation, "line": "event", "seq": read.events,
            "logical_work_item_id": read.work_item, "messageId": read.message_id, "taskId": task_id,
            "contextId": context_id, "kind": kind, "state": state,
        })

    def end(self, read: StreamRead, resubscribe: str = "") -> None:
        line: dict[str, Any] = {
            "ledger": "forward", "ts": now(), "operation": read.operation, "line": "end",
            "logical_work_item_id": read.work_item, "messageId": read.message_id, "taskId": read.task_id,
            "requested_task_id": read.requested_task_id, "ts_sent": read.ts_sent, "events": read.events,
            "first_kind": read.first[0], "first_state": read.first[1], "first_task_id": read.first[2],
            "last_kind": read.last[0], "last_state": read.last[1], "terminal_seen": read.terminal_seen,
            "stream_end": read.stream_end, "error": read.error, "error_type": read.error_type,
        }
        if read.operation == OP_STREAM:
            line["resubscribe"] = resubscribe
        self.writer.write(line)


class Forwarder:
    def __init__(self, *, url: str, http_client: httpx.AsyncClient | None = None, caller: str = "orchestrator",
                 timeout: float = 90.0, resubscribe: bool = False, out: TextIO | None = None) -> None:
        self.url = url
        self.transport_retries = _positive_int("CLIENT_RETRIES")
        self.transport_resend = _switched_on("CLIENT_TRANSPORT_RESEND")
        self.retry_on = _retry_on()
        self.sdk_resend = _switched_on("CLIENT_SDK_RESEND")
        # FORWARD_RESUBSCRIBE, read by app_from_env. Each of A.2's three
        # re-sending knobs is a second send after a failed one: the SDK-layer
        # resend a second SendMessage, the transport resend and the connection
        # retries a second write of the same request. With the resubscription on
        # the forward is a stream and its one follow-up is the resubscription, so
        # any of them beside it would be a follow-up nobody measured. Refused
        # here, which app_from_env reaches at start, before the app exists (D-1's
        # review, M5: until D-2 only the SDK-layer resend was refused).
        self.resubscribe = resubscribe
        if resubscribe:
            also = [name for name, on in (("CLIENT_RETRIES", self.transport_retries > 0),
                                          ("CLIENT_TRANSPORT_RESEND", self.transport_resend),
                                          ("CLIENT_SDK_RESEND", self.sdk_resend)) if on]
            if also:
                raise ValueError(f"{FORWARD_RESUBSCRIBE_ENV}=on together with {', '.join(also)} is not a forward "
                                 "this agent sends")
        self.ledger = ForwardLedger(out) if resubscribe else None
        # Counts the resubscriptions this forwarder sent, so a run and a test read
        # a number: it can only ever be 0 or 1 per forward.
        self.resubscriptions = 0
        # Counts what the SDK-layer knob actually did, so a run reads a number
        # rather than inferring one from the knob having been set.
        self.sdk_resends = 0
        self.transport: httpx.AsyncBaseTransport | None = None
        if http_client is None:
            transport: httpx.AsyncBaseTransport = httpx.AsyncHTTPTransport(retries=self.transport_retries)
            if self.transport_resend:
                transport = ResendOnceTransport(transport, on_503=self.retry_on == RETRY_ON_TRANSPORT_OR_503)
            self.transport = transport
            http_client = httpx.AsyncClient(transport=transport, timeout=timeout, headers={"X-Caller": caller})
        self._http = http_client
        # Attached whether the client was built here or handed in, so a forward
        # carries its identity however this Forwarder was constructed.
        self._http.event_hooks["request"].append(set_identity_headers)
        self._client = None
        self._card = None
        self._client_lock = asyncio.Lock()

    async def _get_client(self):
        # One card fetch per process, even under concurrent forwards: a second
        # fetch would be an extra physical delivery downstream that no work item explains.
        #
        # The card is resolved here rather than left to create_client(url) so that
        # the downstream agent's name and version, which the invoke_agent span is
        # named and attributed for, are read from the card this agent holds. It is
        # the same one fetch: create_client(url) resolves the card with this same
        # A2ACardResolver over this same httpx client and then creates the client
        # from it (a2a.client.client_factory.create_from_url).
        async with self._client_lock:
            if self._client is None:
                self._card = await A2ACardResolver(self._http, self.url).get_agent_card()
                # streaming=False unless the resubscription is on: off, the
                # forward is the unary SendMessage it has always been.
                self._client = await create_client(self._card, client_config=ClientConfig(
                    httpx_client=self._http, streaming=self.resubscribe))
        return self._client

    async def _read_stream(self, stream, read: StreamRead) -> None:
        """Read one streamed request to its end, one event line per event, then
        the end line's facts. An exception ends the read and is kept on it; it
        is not raised, because what happens next is the caller's decision."""
        assert self.ledger is not None
        try:
            async for response in stream:
                kind, task_id, context_id, state = read.read(response)
                self.ledger.event(read, kind, task_id, context_id, state)
        except Exception as exc:
            read.ended(exc)
            return
        read.ended(None)

    async def _forward_streaming(self, client, request: SendMessageRequest, work_item: str,
                                 message_id: str) -> StreamRead:
        """One SendStreamingMessage; if it ends without a terminal event and a
        task id was seen on it, exactly one SubscribeToTask for that task.
        Returns the read whose outcome the forward reports: the resubscription's
        when one was sent, the stream's otherwise."""
        assert self.ledger is not None
        if not self._card.capabilities.streaming:
            # The SDK would send a unary SendMessage instead, silently; a run that
            # asked for a stream is told it did not get one.
            raise RuntimeError(f"{FORWARD_RESUBSCRIBE_ENV}=on, but the downstream card does not declare streaming")
        first = StreamRead(OP_STREAM, work_item, message_id)
        await self._read_stream(client.send_message(request), first)
        if first.terminal_seen:
            self.ledger.end(first, RESUBSCRIBE_NOT_NEEDED)
            return first
        if not first.task_id:
            self.ledger.end(first, RESUBSCRIBE_NO_TASK_ID)
            return first
        self.ledger.end(first, RESUBSCRIBE_SENT)
        # The one resubscription. Nothing below sends again, whatever it gets.
        self.resubscriptions += 1
        second = StreamRead(OP_SUBSCRIBE, work_item, message_id, requested_task_id=first.task_id)
        await self._read_stream(client.subscribe(SubscribeToTaskRequest(id=first.task_id)), second)
        self.ledger.end(second)
        return second

    async def _invoke(self, client, request: SendMessageRequest):
        """One SendMessage through the SDK, returning the last response it yielded."""
        last = None
        async for response in client.send_message(request):
            last = response
        if last is None:
            raise RuntimeError("downstream returned no response")
        return last

    def _interpret(self, last) -> str:
        if last.HasField("task"):
            task = last.task
            if task.status.state != TaskState.TASK_STATE_COMPLETED:
                raise RuntimeError(f"downstream task {task.id} ended in {TaskState.Name(task.status.state)}: {text_of(task)}")
            return text_of(task)
        if last.HasField("message"):
            return text_of(last.message)
        raise RuntimeError("downstream response carried neither task nor message")

    async def forward(self, text: str, work_item: str) -> str:
        client = await self._get_client()
        msg = Message(message_id=str(uuid.uuid4()), role=Role.ROLE_USER, parts=[Part(text=text)],
                      metadata={"logical_work_item_id": work_item})
        request = SendMessageRequest(message=msg)
        # Scoped to the send, so the identity on the wire is this forward's. A
        # resend is the same forward and carries the same two values.
        token = FORWARD_IDENTITY.set(ForwardIdentity(work_item=work_item, message_id=msg.message_id))
        if self.resubscribe:
            # The span covers the stream and the one resubscription, as it covers
            # a resend: the conventions' "duration of the logical operation with
            # all retries".
            try:
                with _invoke_agent_span(self._card, work_item, msg.message_id) as span:
                    outcome = await self._forward_streaming(client, request, work_item, msg.message_id)
                    if outcome.context_id:
                        span.set_attribute(_GEN_AI_CONVERSATION_ID, outcome.context_id)
                    if not outcome.terminal_seen and outcome.error_type:
                        span.set_attribute(_ERROR_TYPE, outcome.error_type)
            finally:
                FORWARD_IDENTITY.reset(token)
            return outcome.result()
        try:
            with _invoke_agent_span(self._card, work_item, msg.message_id) as span:
                try:
                    try:
                        last = await self._invoke(client, request)
                    except Exception:
                        if not self.sdk_resend:
                            raise
                        # The SDK-layer resend asked for by CLIENT_SDK_RESEND: the same
                        # request object handed back to send_message. Only a failure of the
                        # send itself is resent; a downstream answer this agent then rejects
                        # is interpreted below and never re-sent.
                        self.sdk_resends += 1
                        last = await self._invoke(client, request)
                except Exception as exc:
                    # The span's own context manager records the exception and sets
                    # the error status; error.type is the conventions' attribute and
                    # is set here.
                    span.set_attribute(_ERROR_TYPE, type(exc).__qualname__)
                    raise
                # The A2A contextId is the conversation identifier the conventions
                # ask for, and A2A gives one back only on a Task. It is left unset
                # otherwise rather than filled with something invented, which the
                # conventions rule out.
                if last.HasField("task") and last.task.context_id:
                    span.set_attribute(_GEN_AI_CONVERSATION_ID, last.task.context_id)
        finally:
            FORWARD_IDENTITY.reset(token)
        # Interpreting the answer is this agent's own decision and happens after the
        # invocation ended: a downstream task that failed is a response that arrived.
        return self._interpret(last)

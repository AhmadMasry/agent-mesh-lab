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
"""
from __future__ import annotations

import asyncio
import os
import uuid
from contextvars import ContextVar
from dataclasses import dataclass
from urllib.parse import urlsplit

import httpx
from a2a.client import A2ACardResolver, ClientConfig, create_client
from a2a.types import Message, Part, Role, SendMessageRequest, Task, TaskState
from opentelemetry import trace
from opentelemetry.trace import SpanKind


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
# 0c87594975195608dc91b3f702e250a7b240c151, whose Status is Development
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
    """
    try:
        parsed = urlsplit(raw_url)
    except ValueError:
        return {}
    if not parsed.hostname:
        return {}
    try:
        port = parsed.port
    except ValueError:
        port = None
    if port is None:
        port = {"http": 80, "https": 443}.get(parsed.scheme)
    if port is None:
        return {_SERVER_ADDRESS: parsed.hostname}
    return {_SERVER_ADDRESS: parsed.hostname, _SERVER_PORT: port}


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


class Forwarder:
    def __init__(self, *, url: str, http_client: httpx.AsyncClient | None = None, caller: str = "orchestrator",
                 timeout: float = 90.0) -> None:
        self.url = url
        self.transport_retries = _positive_int("CLIENT_RETRIES")
        self.transport_resend = _switched_on("CLIENT_TRANSPORT_RESEND")
        self.retry_on = _retry_on()
        self.sdk_resend = _switched_on("CLIENT_SDK_RESEND")
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
                self._client = await create_client(self._card, client_config=ClientConfig(httpx_client=self._http, streaming=False))
        return self._client

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

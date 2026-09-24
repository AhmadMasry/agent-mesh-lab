"""The GenAI semantic conventions on this agent's two outbound operations.

Two spans, from two sources, checked against the same document:

  * the model call's ``chat <model>`` span, which no code here creates --
    ``opentelemetry-instrumentation-openai-v2`` does, loaded by the
    ``opentelemetry-instrument`` launcher in the image and, here, instrumented
    explicitly so the test measures the package rather than the launcher;
  * the forward's ``invoke_agent <name>`` span, which ``orchestrator.forward``
    creates itself, because no instrumentation knows that a forward is an agent
    invocation.

The names and rules are quoted in ``orchestrator/forward.py`` and
``internal/otel/otel.go`` beside the document revision they were read from.

Rule 4 is checked here too: switching the instrumentation on must not change how
many calls reach the endpoint.
"""
import httpx
import pytest
from a2a.types import AgentCard, AgentInterface, Message, Part, Role, StreamResponse, Task, TaskState
from opentelemetry import trace as otel_trace
from opentelemetry.instrumentation.openai_v2 import OpenAIInstrumentor
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import SimpleSpanProcessor
from opentelemetry.sdk.trace.export.in_memory_span_exporter import InMemorySpanExporter
from google.protobuf.json_format import MessageToJson
from opentelemetry.trace import SpanKind, StatusCode

from orchestrator.forward import Forwarder, _server_attributes
from orchestrator.model import Identity

from test_forward import FakeClient
from test_model import FakeModel


@pytest.fixture(scope="session")
def recording_provider():
    """One tracer provider that keeps its spans, installed globally.

    Global and installed once, because that is how the agent gets one: the
    launcher sets the process's provider before anything runs, the OpenTelemetry
    API refuses to replace a provider once set, and the tracer
    ``orchestrator.forward`` takes at import time resolves through it. Tests share
    it and clear the exporter between them.
    """
    exporter = InMemorySpanExporter()
    provider = TracerProvider()
    provider.add_span_processor(SimpleSpanProcessor(exporter))
    otel_trace.set_tracer_provider(provider)
    return exporter


@pytest.fixture
def spans(recording_provider):
    recording_provider.clear()
    return recording_provider


@pytest.fixture
def openai_instrumented(spans):
    """The contrib instrumentation, switched on for one test and off afterwards."""
    instrumentor = OpenAIInstrumentor()
    instrumentor.instrument(tracer_provider=otel_trace.get_tracer_provider())
    yield spans
    instrumentor.uninstrument()


def by_name(exporter, name):
    return [s for s in exporter.get_finished_spans() if s.name == name]


async def test_model_call_emits_a_chat_span_with_the_conventions_attributes(openai_instrumented):
    fake = FakeModel()

    text = await fake.client().complete(Identity(work_item="w1", message_id="m1", task_id="t1", caller="orchestrator"), "hi")

    assert text == "the fixed answer"
    # Rule 4: the instrumentation wraps the call, it does not add one.
    assert fake.calls == 1

    chat = by_name(openai_instrumented, "chat mock")
    assert len(chat) == 1, [s.name for s in openai_instrumented.get_finished_spans()]
    span = chat[0]
    assert span.kind is SpanKind.CLIENT
    attributes = dict(span.attributes)
    assert attributes["gen_ai.operation.name"] == "chat"
    assert attributes["gen_ai.provider.name"] == "openai"
    assert attributes["gen_ai.request.model"] == "mock"
    assert attributes["gen_ai.response.id"] == "chatcmpl-x"
    # The endpoint's own counts, read back onto the span.
    assert attributes["gen_ai.usage.input_tokens"] == 1
    assert attributes["gen_ai.usage.output_tokens"] == 1


async def test_model_call_with_max_retries_zero_still_reaches_the_endpoint_once(openai_instrumented):
    """The instrumented client is still the retry-free client (rule 4, both ways)."""
    fake = FakeModel(status=500)

    with pytest.raises(Exception):
        await fake.client(retries=0).complete(Identity(work_item="w1"), "x")

    assert fake.calls == 1


AGENT_URL = "http://worker.lab.svc.cluster.local:8080"


def a_card(name: str = "worker", version: str = "0.1.0", url: str = AGENT_URL) -> AgentCard:
    return AgentCard(
        name=name,
        version=version,
        description="the downstream agent",
        supported_interfaces=[AgentInterface(url=url, protocol_binding="JSONRPC", protocol_version="1.0")],
    )


def a_forwarder(client, card: AgentCard | None = None) -> Forwarder:
    f = Forwarder(url="http://downstream/")
    f._client = client
    f._card = card
    return f


class TaskClient(FakeClient):
    """A downstream that answers with a completed Task, so a contextId exists."""

    def __init__(self, context_id: str = "ctx-1") -> None:
        super().__init__()
        self.context_id = context_id

    def send_message(self, request):
        self.requests.append(request)
        context_id = self.context_id

        async def stream():
            response = StreamResponse()
            task = Task(id="task-1", context_id=context_id)
            task.status.state = TaskState.TASK_STATE_COMPLETED
            task.status.message.CopyFrom(
                Message(message_id="downstream", role=Role.ROLE_AGENT, parts=[Part(text="the fixed answer")])
            )
            response.task.CopyFrom(task)
            yield response

        return stream()


async def test_forward_emits_an_invoke_agent_span_with_the_conventions_attributes(spans):
    client = TaskClient()

    text = await a_forwarder(client, a_card()).forward("hello", "w1")

    assert text == "the fixed answer"
    invoke = by_name(spans, "invoke_agent worker")
    assert len(invoke) == 1, [s.name for s in spans.get_finished_spans()]
    span = invoke[0]
    assert span.kind is SpanKind.CLIENT
    attributes = dict(span.attributes)
    assert attributes["gen_ai.operation.name"] == "invoke_agent"
    assert attributes["gen_ai.provider.name"] == "a2a"
    assert attributes["gen_ai.agent.name"] == "worker"
    assert attributes["gen_ai.agent.version"] == "0.1.0"
    # Conditionally Required "When available." like the two above, and the card
    # carries it, so the condition holds.
    assert attributes["gen_ai.agent.description"] == "the downstream agent"
    # The A2A contextId is the conversation the conventions ask for.
    assert attributes["gen_ai.conversation.id"] == "ctx-1"
    # The endpoint this client dials, from the card's one interface.
    assert attributes["server.address"] == "worker.lab.svc.cluster.local"
    assert attributes["server.port"] == 8080
    # Set here rather than by the collector's transform, which reads captured
    # HTTP headers and this span has none.
    assert attributes["lab.work_item"] == "w1"
    assert attributes["lab.caller"] == "orchestrator"
    assert attributes["lab.message_id"] == client.requests[0].message.message_id
    assert "gen_ai.agent.id" not in attributes


async def test_forward_without_a_card_names_the_span_for_the_operation_alone(spans):
    await a_forwarder(FakeClient()).forward("hello", "w1")

    assert by_name(spans, "invoke_agent")
    span = by_name(spans, "invoke_agent")[0]
    attributes = dict(span.attributes)
    for absent in ("gen_ai.agent.name", "gen_ai.agent.version", "gen_ai.agent.description",
                   "server.address", "server.port"):
        assert absent not in attributes
    # The downstream answered with a Message, which carries no contextId of its own.
    assert "gen_ai.conversation.id" not in attributes


async def test_a_card_url_with_a_malformed_ipv6_literal_still_starts_the_span(spans):
    """A card URL the parser refuses sets no server attribute and raises nothing.

    ``http://[::1/`` opens an IPv6 literal and never closes it. The span is still
    started and ended around the send, with its other attributes, and the forward
    returns the downstream's answer: the URL is only read for attributes.
    """
    client = TaskClient()

    text = await a_forwarder(client, a_card(url="http://[::1/")).forward("hello", "w1")

    assert text == "the fixed answer"
    invoke = by_name(spans, "invoke_agent worker")
    assert len(invoke) == 1, [s.name for s in spans.get_finished_spans()]
    attributes = dict(invoke[0].attributes)
    assert "server.address" not in attributes
    assert "server.port" not in attributes
    assert attributes["gen_ai.agent.name"] == "worker"
    assert attributes["lab.work_item"] == "w1"


# The same inputs internal/otel's TestServerAttributes_AURLWithABadPort and
# TestServerAttributes_AURLWithoutAPort use, so the two agents are held to the same
# answers. A port that does not read as a TCP server port -- above 65535, however
# long, or 0 -- leaves server.port unset rather than filled with the scheme's
# default, which would be a guess. Two inputs differ by parser, not by rule, the two
# whose port is not all digits (`:abc`, and `:x` after an IPv6 literal): Go's
# url.Parse refuses such a URL and so sets neither attribute, while urlsplit accepts
# it and only .port refuses it, so server.address stays -- for the literal, without
# its brackets, which is how .hostname reads one. Follow-ups 15 measured the IPv6
# case by hand; it is a case here since follow-ups 19, so every input of the Go
# table is now an input of this one.
@pytest.mark.parametrize(
    "url, expected",
    [
        ("http://h:99999/", {"server.address": "h"}),
        ("https://h:70000/", {"server.address": "h"}),
        ("http://example.test:65536/v1", {"server.address": "example.test"}),
        ("http://example.test:99999999999999999999999/v1", {"server.address": "example.test"}),
        ("http://example.test:0/v1", {"server.address": "example.test"}),
        ("http://example.test:abc/v1", {"server.address": "example.test"}),
        ("http://[::1]:x/v1", {"server.address": "::1"}),
        ("http://example.test:65535/v1", {"server.address": "example.test", "server.port": 65535}),
    ],
)
def test_a_bad_port_leaves_server_port_unset(url, expected):
    assert _server_attributes(url) == expected


@pytest.mark.parametrize(
    "url, expected",
    [
        ("http://worker.lab.svc.cluster.local/", {"server.address": "worker.lab.svc.cluster.local", "server.port": 80}),
        ("https://example.test", {"server.address": "example.test", "server.port": 443}),
        ("http://example.test:/v1", {"server.address": "example.test", "server.port": 80}),
        ("grpc://example.test/v1", {"server.address": "example.test"}),
    ],
)
def test_a_url_without_a_port_records_the_scheme_default_or_the_address_alone(url, expected):
    assert _server_attributes(url) == expected


async def test_a_failed_forward_records_the_error_on_the_span(spans):
    with pytest.raises(Exception):
        await a_forwarder(FakeClient(failures=1), a_card()).forward("hello", "w1")

    span = by_name(spans, "invoke_agent worker")[0]
    assert span.status.status_code is StatusCode.ERROR
    assert dict(span.attributes)["error.type"] == "RemoteProtocolError"


async def test_get_client_resolves_the_card_once_and_keeps_it():
    """The card the invoke_agent span is attributed from is fetched, once, by _get_client.

    The other tests here hand the Forwarder a client and a card, so this is the one
    that exercises the resolver step itself: one GET of the well-known path, and the
    resolved card kept on the Forwarder.
    """
    card = a_card()
    requests: list[str] = []

    def handle(request: httpx.Request) -> httpx.Response:
        requests.append(str(request.url))
        return httpx.Response(200, content=MessageToJson(card), headers={"content-type": "application/json"})

    http = httpx.AsyncClient(transport=httpx.MockTransport(handle))
    forwarder = Forwarder(url="http://downstream", http_client=http)

    client = await forwarder._get_client()

    assert requests == ["http://downstream/.well-known/agent-card.json"]
    assert forwarder._card is not None
    assert forwarder._card.name == "worker"
    assert forwarder._card.version == "0.1.0"
    assert forwarder._card.description == "the downstream agent"
    # A second call reuses both: one card fetch per process, which is what keeps a
    # second physical delivery from appearing downstream with no work item to explain it.
    assert await forwarder._get_client() is client
    assert len(requests) == 1


async def test_the_sdk_resend_knob_still_sends_twice_under_one_span(monkeypatch, spans):
    """A.2's counts are what they were: the span wraps the knob, it is not inside it."""
    monkeypatch.setenv("CLIENT_SDK_RESEND", "on")
    client = FakeClient(failures=1)

    text = await a_forwarder(client, a_card()).forward("hello", "w1")

    assert text == "the fixed answer"
    assert len(client.requests) == 2
    assert client.requests[0] is client.requests[1]
    assert len(by_name(spans, "invoke_agent worker")) == 1


async def test_the_span_names_the_json_rpc_interface_of_a_three_binding_card(spans):
    """Follow-on D-2: the worker's card lists JSONRPC, HTTP+JSON and GRPC, in
    any order a card may give them; the span's address is the JSON-RPC one,
    the interface the forward dials, as it was when the card listed one."""
    card = a_card()
    three = AgentCard(name=card.name, version=card.version, description=card.description,
                      supported_interfaces=[
                          AgentInterface(url="http://rest.example:9000", protocol_binding="HTTP+JSON", protocol_version="1.0"),
                          AgentInterface(url="grpc.example:8081", protocol_binding="GRPC", protocol_version="1.0"),
                          *card.supported_interfaces])
    await a_forwarder(TaskClient(), three).forward("hello", "w1")
    (span,) = by_name(spans, "invoke_agent worker")
    attributes = dict(span.attributes)
    assert attributes["server.address"] == "worker.lab.svc.cluster.local"
    assert attributes["server.port"] == 8080


def test_two_json_rpc_interfaces_leave_the_choice_to_the_sdk():
    from orchestrator.forward import _agent_url
    two = AgentCard(name="w", supported_interfaces=[
        AgentInterface(url="http://a", protocol_binding="JSONRPC", protocol_version="1.0"),
        AgentInterface(url="http://b", protocol_binding="JSONRPC", protocol_version="1.0")])
    assert _agent_url(two) == ""
    none = AgentCard(name="w", supported_interfaces=[
        AgentInterface(url="http://a", protocol_binding="HTTP+JSON", protocol_version="1.0")])
    assert _agent_url(none) == ""

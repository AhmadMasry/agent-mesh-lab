"""Forward mode's client: no retry unless the A.2 knobs ask for one, and what a retry re-sends.

Rule 4 of CLAUDE.md is that the lab's clients carry no retry. The three knobs
below exist so Experiment A.2 can switch one on for a measured repetition and see
what the second delivery carries; `test_knobs_default_off` is what keeps their
absence from every other run a fact rather than an intention.
"""
import httpx
import pytest

from a2a.types import Message, Part, Role, SendMessageRequest, StreamResponse
from orchestrator.forward import (
    RETRY_ON_TRANSPORT,
    RETRY_ON_TRANSPORT_OR_503,
    Forwarder,
    ResendOnceTransport,
)

KNOBS = ("CLIENT_RETRIES", "CLIENT_TRANSPORT_RESEND", "CLIENT_SDK_RESEND", "CLIENT_RETRY_ON")


@pytest.fixture(autouse=True)
def clear_knobs(monkeypatch):
    """Every test states the knobs it wants; none inherits the shell's."""
    for name in KNOBS:
        monkeypatch.delenv(name, raising=False)


class ClosingStream(httpx.AsyncByteStream):
    """A response body that records whether it was closed.

    An httpx.Response built from `content=` or `json=` reports `is_closed` True
    the moment it is constructed, so asserting on that would prove nothing about
    a discarded response. A stream-backed response starts open and closes only
    when someone closes it, which is what the 503 tests need to see.
    """

    def __init__(self, data: bytes) -> None:
        self._data = data
        self.closed = False

    async def __aiter__(self):
        yield self._data

    async def aclose(self) -> None:
        self.closed = True


class RecordingTransport(httpx.AsyncBaseTransport):
    """Inner transport that fails the first `failures` sends and records every request it read."""

    def __init__(self, failures: int = 0, status: int = 200, status_after_first: int | None = None) -> None:
        self.failures = failures
        self.status = status
        self.status_after_first = status_after_first
        self.bodies: list[bytes] = []
        self.headers: list[dict[str, str]] = []
        self.responses: list[httpx.Response] = []
        self.streams: list[ClosingStream] = []
        self.calls = 0

    async def handle_async_request(self, request: httpx.Request) -> httpx.Response:
        self.calls += 1
        self.bodies.append(await request.aread())
        self.headers.append(dict(request.headers))
        if self.calls <= self.failures:
            raise httpx.RemoteProtocolError("Server disconnected without sending a response.", request=request)
        status = self.status_after_first if (self.calls > 1 and self.status_after_first is not None) else self.status
        stream = ClosingStream(b'{"ok": true}')
        response = httpx.Response(status, stream=stream, headers={"content-type": "application/json"}, request=request)
        self.streams.append(stream)
        self.responses.append(response)
        return response


def a_request(text: str = "hello") -> httpx.Request:
    return httpx.Request("POST", "http://downstream/", json={"jsonrpc": "2.0", "id": "fixed", "method": "SendMessage", "params": {"text": text}})


class FakeClient:
    """Stands in for the a2a-python client: records the request object of every send_message."""

    def __init__(self, failures: int = 0) -> None:
        self.failures = failures
        self.requests: list[SendMessageRequest] = []

    def send_message(self, request: SendMessageRequest):
        self.requests.append(request)
        fail = len(self.requests) <= self.failures

        async def stream():
            if fail:
                raise httpx.RemoteProtocolError("Server disconnected without sending a response.")
            response = StreamResponse()
            response.message.CopyFrom(Message(message_id="downstream", role=Role.ROLE_AGENT, parts=[Part(text="the fixed answer")]))
            yield response

        return stream()


def a_forwarder(client: FakeClient) -> Forwarder:
    # The card fetch is what _get_client does; a test that is about the send
    # substitutes the client the fetch would have produced.
    f = Forwarder(url="http://downstream/")
    f._client = client
    return f


def test_knobs_default_off():
    f = Forwarder(url="http://downstream/")

    assert f.transport_retries == 0
    assert f.transport_resend is False
    assert f.sdk_resend is False
    assert f.retry_on == RETRY_ON_TRANSPORT
    assert not isinstance(f.transport, ResendOnceTransport)
    assert isinstance(f.transport, httpx.AsyncHTTPTransport)
    assert f.transport._pool._retries == 0


def test_transport_retries_setting_recorded(monkeypatch):
    monkeypatch.setenv("CLIENT_RETRIES", "2")
    f = Forwarder(url="http://downstream/")
    assert f.transport_retries == 2
    # Recorded where it takes effect, not only where it was read: httpx passes
    # `retries` to the httpcore pool, which applies it to connection attempts.
    assert f.transport._pool._retries == 2

    # A value that is not a positive count leaves the knob off rather than
    # guessing what was meant, so a run-script typo cannot add a retry.
    for value in ("", "off", "-1", "0", "1.5"):
        monkeypatch.setenv("CLIENT_RETRIES", value)
        assert Forwarder(url="http://downstream/").transport_retries == 0, value

    monkeypatch.setenv("CLIENT_TRANSPORT_RESEND", "on")
    f = Forwarder(url="http://downstream/")
    assert f.transport_resend is True
    assert isinstance(f.transport, ResendOnceTransport)


async def test_resend_once_transport_resends_identical_request_on_transport_error():
    inner = RecordingTransport(failures=1)
    transport = ResendOnceTransport(inner)

    response = await transport.handle_async_request(a_request())

    assert response.status_code == 200
    assert inner.calls == 2
    assert inner.bodies[0] == inner.bodies[1]
    assert inner.headers[0] == inner.headers[1]
    assert transport.resends == 1


async def test_resend_once_transport_resends_once_and_no_more():
    inner = RecordingTransport(failures=2)
    with pytest.raises(httpx.TransportError):
        await ResendOnceTransport(inner).handle_async_request(a_request())
    assert inner.calls == 2


async def test_resend_once_transport_does_not_resend_a_response():
    inner = RecordingTransport(failures=0, status=503)
    response = await ResendOnceTransport(inner).handle_async_request(a_request())
    assert response.status_code == 503
    assert inner.calls == 1


async def test_sdk_resend_reinvokes_send_with_same_request_object_once(monkeypatch):
    monkeypatch.setenv("CLIENT_SDK_RESEND", "on")
    client = FakeClient(failures=1)

    text = await a_forwarder(client).forward("hello", "w1")

    assert text == "the fixed answer"
    assert len(client.requests) == 2
    # The same object, not an equal one: A.2 asks what the SDK puts on the wire
    # when the caller hands it back the request it already tried.
    assert client.requests[0] is client.requests[1]
    assert client.requests[0].message.message_id == client.requests[1].message.message_id


async def test_sdk_resend_off_sends_once_and_raises():
    client = FakeClient(failures=1)
    with pytest.raises(Exception):
        await a_forwarder(client).forward("hello", "w1")
    assert len(client.requests) == 1


# Behind a gateway that answers 503 when the receiver's connection goes away, a
# client that re-sends only on a transport error never re-sends at all, which
# A.2 measured. This is the opt-in mode that does re-send there, and what it
# re-sends is the same request: same JSON-RPC id, same messageId, same body.
async def test_resend_once_transport_resends_identical_request_on_503_when_asked():
    inner = RecordingTransport(status=503, status_after_first=200)
    transport = ResendOnceTransport(inner, on_503=True)

    response = await transport.handle_async_request(a_request())

    assert response.status_code == 200
    assert inner.calls == 2
    assert inner.bodies[0] == inner.bodies[1]
    assert inner.headers[0] == inner.headers[1]
    assert transport.resends == 1
    # The 503 the caller never sees is closed rather than left open, and the one
    # handed back is not.
    assert inner.streams[0].closed is True
    assert inner.streams[1].closed is False
    assert inner.responses[1] is response


async def test_resend_once_transport_on_503_returns_second_503():
    """The resend is bounded: a second 503 is the caller's answer, not a third attempt."""
    inner = RecordingTransport(status=503)
    transport = ResendOnceTransport(inner, on_503=True)

    response = await transport.handle_async_request(a_request())

    assert response.status_code == 503
    assert inner.calls == 2
    assert transport.resends == 1
    assert inner.bodies[0] == inner.bodies[1]
    assert inner.streams[0].closed is True
    assert inner.responses[1] is response


async def test_resend_once_transport_on_503_does_not_resend_other_statuses():
    for status in (200, 500, 404, 502, 504):
        inner = RecordingTransport(status=status)
        transport = ResendOnceTransport(inner, on_503=True)
        response = await transport.handle_async_request(a_request())
        assert response.status_code == status, status
        assert inner.calls == 1, status
        assert transport.resends == 0, status
        # A response that is handed to the caller is never closed on the way.
        assert inner.streams[0].closed is False, status


async def test_resend_once_transport_on_503_still_resends_on_transport_error():
    inner = RecordingTransport(failures=1)
    transport = ResendOnceTransport(inner, on_503=True)
    response = await transport.handle_async_request(a_request())
    assert response.status_code == 200
    assert inner.calls == 2


def test_retry_on_mode_is_asked_for_by_name(monkeypatch):
    monkeypatch.setenv("CLIENT_TRANSPORT_RESEND", "on")
    monkeypatch.setenv("CLIENT_RETRY_ON", "transport+503")
    f = Forwarder(url="http://downstream/")
    assert f.retry_on == RETRY_ON_TRANSPORT_OR_503
    assert isinstance(f.transport, ResendOnceTransport)
    assert f.transport.on_503 is True

    # Only the exact name widens the mode, and the mode is not itself a switch:
    # with CLIENT_TRANSPORT_RESEND off there is no resend to widen.
    for value in ("", "503", "transport+500", " transport+503", "TRANSPORT+503", "on", "transport"):
        monkeypatch.setenv("CLIENT_RETRY_ON", value)
        f_bad = Forwarder(url="http://downstream/")
        assert f_bad.retry_on == RETRY_ON_TRANSPORT, value
        assert f_bad.transport.on_503 is False, value
    monkeypatch.delenv("CLIENT_TRANSPORT_RESEND")
    monkeypatch.setenv("CLIENT_RETRY_ON", "transport+503")
    assert not isinstance(Forwarder(url="http://downstream/").transport, ResendOnceTransport)

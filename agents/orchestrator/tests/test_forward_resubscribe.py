"""FORWARD_RESUBSCRIBE: the forward as one SendStreamingMessage and, if that
stream ends without a terminal event, exactly one SubscribeToTask -- never a
second, and never after a terminal event. Off, the forward is today's."""
from __future__ import annotations

import asyncio
import io
import json
import os
import socket
import subprocess
import sys
import threading
import time
from pathlib import Path

import httpx
import pytest
from a2a.types import (
    AgentCapabilities,
    AgentCard,
    Artifact,
    Message,
    Part,
    Role,
    StreamResponse,
    Task,
    TaskArtifactUpdateEvent,
    TaskState,
    TaskStatus,
    TaskStatusUpdateEvent,
)

from orchestrator.forward import (
    FORWARD_RESUBSCRIBE_ENV,
    RESUBSCRIBE_NO_TASK_ID,
    RESUBSCRIBE_NOT_NEEDED,
    RESUBSCRIBE_SENT,
    Forwarder,
    forward_resubscribe_from,
)
from orchestrator.server import app_from_env, build_app
from tests.socket_harness import HeldModel, ServedApp, ledger, wait_for

KNOBS = ("CLIENT_RETRIES", "CLIENT_TRANSPORT_RESEND", "CLIENT_SDK_RESEND", "CLIENT_RETRY_ON",
         FORWARD_RESUBSCRIBE_ENV)


@pytest.fixture(autouse=True)
def clear_knobs(monkeypatch):
    for name in KNOBS:
        monkeypatch.delenv(name, raising=False)


# --- scripted events -------------------------------------------------------

def ev_task(state=TaskState.TASK_STATE_SUBMITTED, task_id="t-1", text=""):
    r = StreamResponse()
    task = Task(id=task_id, context_id="c-1", status=TaskStatus(state=state))
    if text:
        task.artifacts.append(Artifact(artifact_id="a", parts=[Part(text=text)]))
    r.task.CopyFrom(task)
    return r


def ev_status(state, task_id="t-1", text=""):
    r = StreamResponse()
    status = TaskStatus(state=state)
    if text:
        status.message.CopyFrom(Message(message_id="s", role=Role.ROLE_AGENT, parts=[Part(text=text)]))
    r.status_update.CopyFrom(TaskStatusUpdateEvent(task_id=task_id, context_id="c-1", status=status))
    return r


def ev_artifact(text, task_id="t-1"):
    r = StreamResponse()
    r.artifact_update.CopyFrom(TaskArtifactUpdateEvent(task_id=task_id, context_id="c-1",
                                                       artifact=Artifact(artifact_id="a", parts=[Part(text=text)])))
    return r


def ev_message(text, task_id=""):
    r = StreamResponse()
    r.message.CopyFrom(Message(message_id="m", role=Role.ROLE_AGENT, parts=[Part(text=text)], task_id=task_id))
    return r


WORKING = [ev_task(), ev_status(TaskState.TASK_STATE_WORKING)]
COMPLETES = [ev_artifact("the answer"), ev_status(TaskState.TASK_STATE_COMPLETED)]
CUT = httpx.RemoteProtocolError("peer closed connection without sending complete message body")


class Script:
    """One scripted request: the events it yields, then either a quiet end or
    the exception it raises."""

    def __init__(self, events, raises: BaseException | None = None) -> None:
        self.events = events
        self.raises = raises

    async def run(self):
        for e in self.events:
            yield e
        if self.raises is not None:
            raise self.raises


class FakeStreamingClient:
    """Stands in for the a2a-python client: counts every send_message and every
    subscribe and plays the next script for each."""

    def __init__(self, stream: Script, subscriptions: list[Script] | None = None) -> None:
        self.stream = stream
        self.subscriptions = list(subscriptions or [])
        self.sends = 0
        self.subscribed: list[str] = []

    def send_message(self, request):
        self.sends += 1
        return self.stream.run()

    def subscribe(self, request):
        self.subscribed.append(request.id)
        script = self.subscriptions.pop(0) if self.subscriptions else Script([])
        return script.run()


def streaming_card(streaming=True) -> AgentCard:
    return AgentCard(name="worker", version="0.0.0", description="d",
                     capabilities=AgentCapabilities(streaming=streaming))


def a_forwarder(client, out=None, resubscribe=True, streaming=True) -> Forwarder:
    f = Forwarder(url="http://downstream/", resubscribe=resubscribe, out=out)
    f._client = client
    f._card = streaming_card(streaming)
    return f


def forward_lines(out: io.StringIO) -> list[dict]:
    return [json.loads(line) for line in out.getvalue().splitlines() if line.strip()]


def ends(out: io.StringIO) -> list[dict]:
    return [line for line in forward_lines(out) if line["line"] == "end"]


# --- the setting -----------------------------------------------------------

def test_default_off(monkeypatch):
    assert forward_resubscribe_from(os.environ.get(FORWARD_RESUBSCRIBE_ENV, "")) is False
    f = Forwarder(url="http://downstream/")
    assert f.resubscribe is False and f.ledger is None and f.resubscriptions == 0


def test_app_from_env_passes_the_setting(monkeypatch):
    seen = {}
    import orchestrator.server as server

    real = server.Forwarder

    def spy(**kwargs):
        seen.update(kwargs)
        return real(**kwargs)

    monkeypatch.setattr(server, "Forwarder", spy)
    monkeypatch.setenv("DOWNSTREAM_A2A_URL", "http://downstream/")
    app_from_env()
    assert seen["resubscribe"] is False
    monkeypatch.setenv(FORWARD_RESUBSCRIBE_ENV, "on")
    app_from_env()
    assert seen["resubscribe"] is True


def test_only_on_turns_it_on():
    assert forward_resubscribe_from("on") is True


@pytest.mark.parametrize("value", ["ON", "On", " on", "on ", "1", "true", "yes", "off", "0", "twice",
                                   "${FORWARD_RESUBSCRIBE}"])
def test_anything_else_is_refused_as_a_value(value):
    with pytest.raises(ValueError, match=FORWARD_RESUBSCRIBE_ENV):
        forward_resubscribe_from(value)


@pytest.mark.parametrize("downstream", ["", "http://downstream/"])
def test_app_from_env_raises_on_any_other_value_in_either_mode(monkeypatch, downstream):
    monkeypatch.setenv(FORWARD_RESUBSCRIBE_ENV, "ON")
    monkeypatch.setenv("DOWNSTREAM_A2A_URL", downstream)
    with pytest.raises(ValueError, match=FORWARD_RESUBSCRIBE_ENV):
        app_from_env()


def test_refused_together_with_the_sdk_resend(monkeypatch):
    monkeypatch.setenv("CLIENT_SDK_RESEND", "on")
    with pytest.raises(ValueError, match="CLIENT_SDK_RESEND"):
        Forwarder(url="http://downstream/", resubscribe=True)
    assert Forwarder(url="http://downstream/").sdk_resend is True


# --- off is today's forward ------------------------------------------------

class FakeUnaryClient:
    def __init__(self) -> None:
        self.sends = 0
        self.subscribed = 0

    def send_message(self, request):
        self.sends += 1

        async def stream():
            yield ev_message("the fixed answer")

        return stream()

    def subscribe(self, request):  # pragma: no cover - must never be called
        self.subscribed += 1
        raise AssertionError("subscribe called with the setting off")


async def test_off_sends_once_and_writes_no_forward_line(capsys):
    client = FakeUnaryClient()
    f = Forwarder(url="http://downstream/")
    f._client = client
    f._card = streaming_card()
    assert await f.forward("hello", "w-1") == "the fixed answer"
    assert client.sends == 1 and client.subscribed == 0
    assert '"ledger":"forward"' not in capsys.readouterr().out


async def test_off_builds_a_client_that_does_not_stream():
    """Off, the client the forwarder builds is configured as it always was:
    streaming False, so the SDK sends the unary SendMessage."""
    card = streaming_card()
    card.supported_interfaces.add(url="http://downstream/", protocol_binding="JSONRPC", protocol_version="1.0")

    async def handler(request: httpx.Request) -> httpx.Response:
        from google.protobuf.json_format import MessageToDict
        return httpx.Response(200, json=MessageToDict(card))

    for resubscribe, want in ((False, False), (True, True)):
        f = Forwarder(url="http://downstream/", http_client=httpx.AsyncClient(transport=httpx.MockTransport(handler)),
                      resubscribe=resubscribe, out=io.StringIO())
        client = await f._get_client()
        assert client._config.streaming is want


# --- on: the decision ------------------------------------------------------

async def test_on_a_stream_with_a_terminal_event_is_not_resubscribed():
    out = io.StringIO()
    client = FakeStreamingClient(Script(WORKING + COMPLETES))
    f = a_forwarder(client, out)
    assert await f.forward("hello", "w-1") == "the answer"
    assert client.sends == 1 and client.subscribed == [] and f.resubscriptions == 0
    (end,) = ends(out)
    assert end["operation"] == "SendStreamingMessage" and end["resubscribe"] == RESUBSCRIBE_NOT_NEEDED
    assert end["terminal_seen"] is True and end["stream_end"] == "eof" and end["events"] == 4
    assert end["last_state"] == "TASK_STATE_COMPLETED"


async def test_on_a_failed_terminal_event_is_reported_and_not_resubscribed():
    out = io.StringIO()
    client = FakeStreamingClient(Script(WORKING + [ev_status(TaskState.TASK_STATE_FAILED, text="model call: EOF")]))
    f = a_forwarder(client, out)
    with pytest.raises(RuntimeError, match="TASK_STATE_FAILED: model call: EOF"):
        await f.forward("hello", "w-1")
    assert client.subscribed == [] and f.resubscriptions == 0
    assert ends(out)[0]["resubscribe"] == RESUBSCRIBE_NOT_NEEDED


async def test_on_a_terminal_event_then_a_cut_is_not_resubscribed():
    """The terminal event arrived; what the transport did afterwards changes
    nothing, and nothing is sent."""
    out = io.StringIO()
    client = FakeStreamingClient(Script(WORKING + COMPLETES, raises=CUT))
    f = a_forwarder(client, out)
    assert await f.forward("hello", "w-1") == "the answer"
    assert client.subscribed == []
    (end,) = ends(out)
    assert end["resubscribe"] == RESUBSCRIBE_NOT_NEEDED and end["stream_end"] == "error"


async def test_on_a_message_ends_the_forward_without_a_resubscription():
    out = io.StringIO()
    """A Message is the final answer of a stream (the SDK stops reading after
    one), so it is a terminal event even when it names a task."""
    client = FakeStreamingClient(Script([ev_message("a direct answer", task_id="t-1")]),
                                 [Script([ev_task(TaskState.TASK_STATE_WORKING)] + COMPLETES)])
    f = a_forwarder(client, out)
    assert await f.forward("hello", "w-1") == "a direct answer"
    assert client.subscribed == []
    (end,) = ends(out)
    assert end["resubscribe"] == RESUBSCRIBE_NOT_NEEDED and end["terminal_seen"] is True
    assert (end["first_kind"], end["taskId"]) == ("message", "t-1")


@pytest.mark.parametrize("raises", [None, CUT], ids=["quiet-end", "cut"])
async def test_on_a_stream_ended_without_a_terminal_event_is_resubscribed_once(raises):
    out = io.StringIO()
    client = FakeStreamingClient(Script(WORKING, raises=raises),
                                 [Script([ev_task(TaskState.TASK_STATE_WORKING)] + COMPLETES)])
    f = a_forwarder(client, out)
    assert await f.forward("hello", "w-1") == "the answer"
    assert client.sends == 1 and client.subscribed == ["t-1"] and f.resubscriptions == 1
    first, second = ends(out)
    assert first["operation"] == "SendStreamingMessage" and first["resubscribe"] == RESUBSCRIBE_SENT
    assert first["terminal_seen"] is False and first["events"] == 2 and first["taskId"] == "t-1"
    assert first["last_kind"] == "status-update" and first["last_state"] == "TASK_STATE_WORKING"
    assert first["stream_end"] == ("eof" if raises is None else "error")
    if raises is not None:
        assert first["error_type"] == "RemoteProtocolError" and "peer closed" in first["error"]
    assert second["operation"] == "SubscribeToTask" and second["requested_task_id"] == "t-1"
    assert "resubscribe" not in second
    assert (second["first_kind"], second["first_state"], second["first_task_id"]) == \
           ("task", "TASK_STATE_WORKING", "t-1")
    assert second["terminal_seen"] is True and second["stream_end"] == "eof" and second["events"] == 3
    events = [line for line in forward_lines(out) if line["line"] == "event"]
    assert [(e["operation"], e["seq"], e["kind"], e["state"]) for e in events] == [
        ("SendStreamingMessage", 1, "task", "TASK_STATE_SUBMITTED"),
        ("SendStreamingMessage", 2, "status-update", "TASK_STATE_WORKING"),
        ("SubscribeToTask", 1, "task", "TASK_STATE_WORKING"),
        ("SubscribeToTask", 2, "artifact-update", ""),
        ("SubscribeToTask", 3, "status-update", "TASK_STATE_COMPLETED"),
    ]
    for line in forward_lines(out):
        assert line["logical_work_item_id"] == "w-1" and line["messageId"]


@pytest.mark.parametrize("second", [Script([ev_task(TaskState.TASK_STATE_WORKING)]),
                                    Script([ev_task(TaskState.TASK_STATE_WORKING)], raises=CUT),
                                    Script([], raises=CUT)],
                         ids=["quiet-end", "cut-after-an-event", "cut-before-any-event"])
async def test_on_the_resubscription_is_never_followed_by_another(second):
    """The one resubscription ends without a terminal event too: the forward
    fails, and nothing further is sent, whatever the second stream did."""
    out = io.StringIO()
    third = Script([ev_task(TaskState.TASK_STATE_WORKING)] + COMPLETES)
    client = FakeStreamingClient(Script(WORKING, raises=CUT), [second, third])
    f = a_forwarder(client, out)
    with pytest.raises(RuntimeError, match="SubscribeToTask ended without a terminal event"):
        await f.forward("hello", "w-1")
    assert client.sends == 1 and client.subscribed == ["t-1"] and f.resubscriptions == 1
    assert [e["operation"] for e in ends(out)] == ["SendStreamingMessage", "SubscribeToTask"]


async def test_on_the_resubscription_carrying_a_failure_reports_it():
    out = io.StringIO()
    client = FakeStreamingClient(Script(WORKING, raises=CUT),
                                 [Script([ev_task(TaskState.TASK_STATE_WORKING),
                                          ev_status(TaskState.TASK_STATE_FAILED, text="Connection error.")])])
    f = a_forwarder(client, out)
    with pytest.raises(RuntimeError, match="TASK_STATE_FAILED: Connection error."):
        await f.forward("hello", "w-1")
    assert client.subscribed == ["t-1"]


async def test_on_a_stream_cut_before_any_task_id_is_not_resubscribed():
    out = io.StringIO()
    client = FakeStreamingClient(Script([], raises=CUT), [Script(COMPLETES)])
    f = a_forwarder(client, out)
    with pytest.raises(RuntimeError, match="SendStreamingMessage ended without a terminal event"):
        await f.forward("hello", "w-1")
    assert client.subscribed == [] and f.resubscriptions == 0
    (end,) = ends(out)
    assert end["resubscribe"] == RESUBSCRIBE_NO_TASK_ID and end["events"] == 0 and end["stream_end"] == "error"


async def test_on_the_resubscription_names_the_task_the_stream_named():
    out = io.StringIO()
    client = FakeStreamingClient(Script([ev_task(task_id="t-9"), ev_status(TaskState.TASK_STATE_WORKING, task_id="t-9")]),
                                 [Script([ev_task(TaskState.TASK_STATE_WORKING, task_id="t-9", text="partial")] +
                                         [ev_status(TaskState.TASK_STATE_COMPLETED, task_id="t-9")])])
    f = a_forwarder(client, out)
    assert await f.forward("hello", "w-1") == "partial"
    assert client.subscribed == ["t-9"]


async def test_on_a_card_that_does_not_declare_streaming_is_refused_before_sending():
    client = FakeStreamingClient(Script(WORKING + COMPLETES))
    f = a_forwarder(client, io.StringIO(), streaming=False)
    with pytest.raises(RuntimeError, match="does not declare streaming"):
        await f.forward("hello", "w-1")
    assert client.sends == 0 and client.subscribed == []


# --- over a socket: the SDK's own client, a real downstream, a real cut ----

class CuttingProxy:
    """A TCP relay in front of the downstream agent that the test can cut.

    cut() closes every connection open through it at that moment, both halves;
    connections opened afterwards are relayed as before. It is the socket-level
    stand-in for a removed proxy. It never retries or reconnects anything: a
    connection that fails to reach the downstream is closed.
    """

    def __init__(self, target_port: int) -> None:
        self.target = target_port
        self.listener = socket.socket()
        self.listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.listener.bind(("127.0.0.1", 0))
        self.listener.listen(16)
        self.port = self.listener.getsockname()[1]
        self.open: list[socket.socket] = []
        self.accepted = 0
        self.lock = threading.Lock()
        threading.Thread(target=self._accept, daemon=True).start()

    def _accept(self) -> None:
        while True:
            try:
                client, _ = self.listener.accept()
            except OSError:
                return
            try:
                upstream = socket.create_connection(("127.0.0.1", self.target), timeout=15)
            except OSError:
                client.close()
                continue
            with self.lock:
                self.accepted += 1
                self.open += [client, upstream]
            for a, b in ((client, upstream), (upstream, client)):
                threading.Thread(target=self._pump, args=(a, b), daemon=True).start()

    @staticmethod
    def _pump(src: socket.socket, dst: socket.socket) -> None:
        try:
            while True:
                data = src.recv(65536)
                if not data:
                    break
                dst.sendall(data)
        except OSError:
            pass
        for s in (src, dst):
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass

    def cut(self) -> None:
        with self.lock:
            victims, self.open = self.open, []
        for s in victims:
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            s.close()

    def close(self) -> None:
        self.listener.close()
        self.cut()


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class Downstream:
    """The Python receiver in model mode, served by uvicorn, with its card
    advertising the cutting proxy, so the SDK client dials through it."""

    def __init__(self) -> None:
        self.out = io.StringIO()
        self.model = HeldModel()
        port = _free_port()
        self.proxy = CuttingProxy(port)
        app = build_app(name="worker", model=self.model.client(), forwarder=None, out=self.out,
                        public_url=f"http://127.0.0.1:{self.proxy.port}")
        self.served = ServedApp(app)
        self.served._server.config.port = port

    def __enter__(self):
        self.served.__enter__()
        return self

    def __exit__(self, *exc):
        self.model.release()
        self.proxy.close()
        self.served.__exit__(*exc)

    def arrivals(self) -> list[str]:
        return [line["method"] for line in ledger(self.out, "ingress", phase="arrival")]


def run_forward(forwarder: Forwarder, result: dict) -> threading.Thread:
    def target():
        try:
            result["answer"] = asyncio.run(forwarder.forward("hello", "w-sock"))
        except Exception as exc:  # recorded, never retried
            result["error"] = exc

    t = threading.Thread(target=target, daemon=True)
    t.start()
    return t


def wait_forward(out: io.StringIO, predicate, what: str, timeout: float = 15.0) -> None:
    deadline = time.monotonic() + timeout
    while not predicate(forward_lines(out)):
        if time.monotonic() > deadline:
            raise AssertionError(f"the forward never reached {what}: {out.getvalue()}")
        time.sleep(0.02)


def test_over_a_socket_a_cut_stream_is_resubscribed_once_and_the_task_completes():
    with Downstream() as down:
        out = io.StringIO()
        f = Forwarder(url=f"http://127.0.0.1:{down.proxy.port}", resubscribe=True, out=out)
        result: dict = {}
        t = run_forward(f, result)
        wait_forward(out, lambda ls: any(l.get("state") == "TASK_STATE_WORKING" for l in ls), "WORKING")
        down.model.wait_until_called()
        down.proxy.cut()
        wait_forward(out, lambda ls: any(l["operation"] == "SubscribeToTask" and l["line"] == "event" for l in ls),
                     "the resubscription's first event")
        down.model.release()
        t.join(timeout=30)
        assert result.get("answer") == "the fixed answer", result
        first, second = ends(out)
        assert first["resubscribe"] == RESUBSCRIBE_SENT and first["terminal_seen"] is False
        assert (first["events"], first["last_state"]) == (2, "TASK_STATE_WORKING")
        assert second["requested_task_id"] == first["taskId"] and second["first_task_id"] == first["taskId"]
        assert (second["first_kind"], second["first_state"]) == ("task", "TASK_STATE_WORKING")
        assert second["terminal_seen"] is True and second["last_state"] == "TASK_STATE_COMPLETED"
        wait_for(down.out, lambda ls: sum(1 for l in ls if l.get("state") == "TASK_STATE_COMPLETED") >= 1,
                 "the downstream task completed")
        assert down.arrivals() == ["GET /.well-known/agent-card.json", "SendStreamingMessage", "SubscribeToTask"]
        assert len(ledger(down.out, "execution", event="execute")) == 1
        assert down.model.entries == 1
        sub = ledger(down.out, "ingress", phase="arrival", method="SubscribeToTask")[0]
        assert sub["taskId"] == first["taskId"] and sub["logical_work_item_id"] == "w-sock"


def test_over_a_socket_a_cut_resubscription_is_not_followed_by_another():
    with Downstream() as down:
        out = io.StringIO()
        f = Forwarder(url=f"http://127.0.0.1:{down.proxy.port}", resubscribe=True, out=out)
        result: dict = {}
        t = run_forward(f, result)
        wait_forward(out, lambda ls: any(l.get("state") == "TASK_STATE_WORKING" for l in ls), "WORKING")
        down.model.wait_until_called()
        down.proxy.cut()
        wait_forward(out, lambda ls: any(l["operation"] == "SubscribeToTask" and l["line"] == "event" for l in ls),
                     "the resubscription's first event")
        down.proxy.cut()
        t.join(timeout=30)
        assert isinstance(result.get("error"), RuntimeError), result
        time.sleep(0.5)
        accepted = down.proxy.accepted
        down.model.release()
        wait_for(down.out, lambda ls: any(l.get("state") == "TASK_STATE_COMPLETED" for l in ls),
                 "the downstream task completed")
        time.sleep(0.5)
        assert down.arrivals() == ["GET /.well-known/agent-card.json", "SendStreamingMessage", "SubscribeToTask"]
        assert down.proxy.accepted == accepted
        assert [e["operation"] for e in ends(out)] == ["SendStreamingMessage", "SubscribeToTask"]
        assert f.resubscriptions == 1


def test_over_a_socket_off_is_one_unary_send_message():
    with Downstream() as down:
        f = Forwarder(url=f"http://127.0.0.1:{down.proxy.port}")
        down.model.release()
        assert asyncio.run(f.forward("hello", "w-off")) == "the fixed answer"
        assert down.arrivals() == ["GET /.well-known/agent-card.json", "SendMessage"]


# --- the process -----------------------------------------------------------

def _process(value: str, port: int) -> subprocess.Popen:
    env = {k: v for k, v in os.environ.items() if not k.startswith("OTEL_")}
    env.update({FORWARD_RESUBSCRIBE_ENV: value, "PORT": str(port), "DOWNSTREAM_A2A_URL": "http://127.0.0.1:9/"})
    return subprocess.Popen([sys.executable, "-m", "orchestrator.server"], cwd=Path(__file__).parent.parent,
                            env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)


@pytest.mark.parametrize("value", ["ON", "true", "on "])
def test_the_process_stops_at_start_on_any_other_value(value):
    port = _free_port()
    proc = _process(value, port)
    try:
        _, stderr = proc.communicate(timeout=30)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.communicate()
        pytest.fail(f"{value!r}: the process was still running after 30 s")
    assert proc.returncode != 0
    assert FORWARD_RESUBSCRIBE_ENV in stderr
    with socket.socket() as s:
        assert s.connect_ex(("127.0.0.1", port)) != 0, "nothing may be listening"

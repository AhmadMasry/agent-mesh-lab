"""REFUSE_OPERATION on the Python receiver: off by default, one operation refused
inside the lab's request handler before the SDK's, and a stop at start on any
value it cannot refuse."""
from __future__ import annotations

import io
import json
import os
import socket
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

import pytest
from a2a.server.context import ServerCallContext
from a2a.types import Message, Part, Role, SendMessageRequest, SubscribeToTaskRequest
from a2a.utils.errors import TaskNotFoundError, UnsupportedOperationError

from orchestrator.agent import build_handler
from orchestrator.refuse import REFUSE_OPERATION_ENV, refuse_operation_from
from orchestrator.server import app_from_env, build_app
from tests.socket_harness import ServedApp
from tests.test_model import FakeModel

OPS = ("SendMessage", "SendStreamingMessage", "SubscribeToTask")
NO_TASK = "task-that-does-not-exist"

SEND_BODY = ('{"jsonrpc":"2.0","method":"SendMessage","params":{"message":{"messageId":"m-unary",'
             '"metadata":{"logical_work_item_id":"w-unary"},"parts":[{"text":"lwi:w-unary hello"}],'
             '"role":"ROLE_USER"}},"id":"rpc-unary"}')
STREAM_BODY = ('{"jsonrpc":"2.0","method":"SendStreamingMessage","params":{"message":{"messageId":"m-stream",'
               '"metadata":{"logical_work_item_id":"w-stream"},"parts":[{"text":"lwi:w-stream hello"}],'
               '"role":"ROLE_USER"}},"id":"rpc-stream"}')
SUBSCRIBE_BODY = '{"jsonrpc":"2.0","method":"SubscribeToTask","params":{"id":"%s"},"id":"rpc-sub"}' % NO_TASK
BODIES = {"SendMessage": SEND_BODY, "SendStreamingMessage": STREAM_BODY, "SubscribeToTask": SUBSCRIBE_BODY}


def _request(op: str) -> SendMessageRequest:
    lwi = f"w-{op}"
    msg = Message(message_id=f"m-{op}", role=Role.ROLE_USER, parts=[Part(text=f"lwi:{lwi} hello")],
                  metadata={"logical_work_item_id": lwi})
    return SendMessageRequest(message=msg)


def _lines(out: io.StringIO) -> list[dict]:
    return [json.loads(line) for line in out.getvalue().splitlines() if line.strip()]


def _execution(out: io.StringIO) -> list[dict]:
    return [line for line in _lines(out) if line["ledger"] == "execution"]


async def _run(handler, op: str) -> tuple[BaseException | None, int]:
    """What one request got from the handler, read as the dispatcher reads it:
    the first error the call or the sequence raises, and how many events left."""
    events = 0
    try:
        if op == "SendMessage":
            await handler.on_message_send(_request(op), ServerCallContext())
        elif op == "SendStreamingMessage":
            async for _ in handler.on_message_send_stream(_request(op), ServerCallContext()):
                events += 1
        else:
            async for _ in handler.on_subscribe_to_task(SubscribeToTaskRequest(id=NO_TASK), ServerCallContext()):
                events += 1
    except Exception as exc:  # the answer under test, not a failure of the test
        return exc, events
    return None, events


def _handler(out: io.StringIO, model: FakeModel, refuse: str):
    return build_handler(name="orchestrator", model=model.client(), forwarder=None, out=out,
                         public_url="http://orchestrator", refuse=refuse)


def test_default_off():
    assert refuse_operation_from("") == ""
    handler = _handler(io.StringIO(), FakeModel(), refuse_operation_from(os.environ.get("UNSET_FOR_THIS_TEST", "")))
    assert handler.refuse == ""


def test_app_from_env_reads_the_setting_and_is_off_when_empty(monkeypatch):
    monkeypatch.delenv("DOWNSTREAM_A2A_URL", raising=False)
    for value in (None, ""):
        if value is None:
            monkeypatch.delenv(REFUSE_OPERATION_ENV, raising=False)
        else:
            monkeypatch.setenv(REFUSE_OPERATION_ENV, value)
        with ServedApp(app_from_env()) as served:
            answer = _post(served.port, SUBSCRIBE_BODY)
        assert answer["code"] == -32001, answer  # the SDK's own task-not-found: nothing refused
    monkeypatch.setenv(REFUSE_OPERATION_ENV, "SubscribeToTask")
    with ServedApp(app_from_env()) as served:
        answer = _post(served.port, SUBSCRIBE_BODY)
    assert answer["code"] == -32004, answer


def test_the_three_operations_are_accepted():
    for op in OPS:
        assert refuse_operation_from(op) == op


BAD_VALUES = ["GetTask", "CancelTask", "ListTasks", "GetExtendedAgentCard",
              "subscribetotask", "SUBSCRIBETOTASK", "subscribeToTask",
              " SubscribeToTask", "SubscribeToTask ", "SubscribeToTask\n",
              "tasks/resubscribe", "message/send", "SubscribeToTask,SendMessage",
              "${REFUSE_OPERATION}", "on", "yes", "true", "1", "*", "all", "off", " "]


@pytest.mark.parametrize("value", BAD_VALUES)
def test_anything_else_is_refused_as_a_value(value):
    with pytest.raises(ValueError, match=REFUSE_OPERATION_ENV):
        refuse_operation_from(value)


@pytest.mark.parametrize("value", ["GetTask", "subscribetotask"])
def test_app_from_env_raises_on_a_value_it_cannot_refuse(monkeypatch, value):
    monkeypatch.setenv(REFUSE_OPERATION_ENV, value)
    with pytest.raises(ValueError, match=REFUSE_OPERATION_ENV):
        app_from_env()


@pytest.mark.parametrize("setting", ("",) + OPS)
@pytest.mark.parametrize("op", OPS)
async def test_each_setting_refuses_only_its_operation(setting, op):
    out, model = io.StringIO(), FakeModel()
    err, events = await _run(_handler(out, model, setting), op)
    executes = [line for line in _execution(out) if line["event"] == "execute"]
    if op == setting:
        assert isinstance(err, UnsupportedOperationError), err
        assert f"{op} is refused by this agent (REFUSE_OPERATION)" in str(err)
        assert events == 0 and executes == [] and model.calls == 0
    elif op == "SubscribeToTask":
        assert isinstance(err, TaskNotFoundError), err
    else:
        assert err is None and len(executes) == 1 and model.calls == 1


@pytest.mark.parametrize("op", OPS)
async def test_a_refused_requests_execution_lines(op):
    out = io.StringIO()
    await _run(_handler(out, FakeModel(), op), op)
    lines = _execution(out)
    assert [line["event"] for line in lines] == ["received", "result"], lines
    assert all(line["method"] == op for line in lines)
    result = lines[1]
    assert f"this operation is not supported: {op} is refused by this agent" in result["error"]
    assert "result_kind" not in result and "state" not in result
    if op == "SendMessage":
        assert "stream_end" not in result
    else:
        assert result["stream_end"] == "error"
    if op != "SubscribeToTask":
        assert lines[0]["messageId"] == f"m-{op}" and lines[0]["logical_work_item_id"] == f"w-{op}"


def _normalized(out: io.StringIO) -> list[dict]:
    lines = _execution(out)
    for line in lines:
        line["ts"] = ""
        if line.get("taskId") and line["taskId"] != NO_TASK:
            line["taskId"] = "<task>"
        if line.get("contextId"):
            line["contextId"] = "<context>"
    return lines


async def test_ledger_unchanged_for_operations_not_refused():
    off = {}
    for op in OPS:
        out = io.StringIO()
        await _run(_handler(out, FakeModel(), ""), op)
        off[op] = _normalized(out)
        assert off[op]
    for setting in OPS:
        for op in OPS:
            if op == setting:
                continue
            out = io.StringIO()
            await _run(_handler(out, FakeModel(), setting), op)
            assert _normalized(out) == off[op], (setting, op)


def _post(port: int, body: str) -> dict:
    """One POST, no retry (urllib has none): the HTTP status, content type and
    the JSON-RPC error of the one body or of the first SSE event."""
    req = urllib.request.Request(f"http://127.0.0.1:{port}/", data=body.encode(), method="POST",
                                 headers={"Content-Type": "application/json", "A2A-Version": "1.0"})
    try:
        resp = urllib.request.urlopen(req, timeout=15)
    except urllib.error.HTTPError as exc:
        resp = exc
    status, ctype, raw = resp.status, resp.headers.get("Content-Type", ""), resp.read().decode()
    payload = raw
    if ctype.startswith("text/event-stream"):
        payload = next(line[len("data: "):] for line in raw.splitlines() if line.startswith("data: "))
    env = json.loads(payload)
    error = env.get("error") or {}
    return {"status": status, "content_type": ctype, "code": error.get("code", 0),
            "message": error.get("message", ""), "result": "result" in env}


def _served(out: io.StringIO, model: FakeModel, refuse: str) -> ServedApp:
    return ServedApp(build_app(name="orchestrator", model=model.client(), forwarder=None, out=out,
                               public_url="http://orchestrator", refuse=refuse))


@pytest.mark.parametrize("op", OPS)
def test_over_the_wire(op):
    """As the process serves it: the refused request still arrives at the
    ingress ledger, which is written before the SDK sees it, and gets -32004 with
    the refusal's text; the model is never called for it; the other send on the
    same server is served with one model call."""
    out, model = io.StringIO(), FakeModel()
    with _served(out, model, op) as served:
        answer = _post(served.port, BODIES[op])
        assert answer["code"] == -32004 and not answer["result"], answer
        assert f"{op} is refused by this agent (REFUSE_OPERATION)" in answer["message"]
        assert answer["status"] == 200, answer
        # a2a-python 1.1.4 reads a streamed operation's first event before it
        # chooses the response (jsonrpc_dispatcher.py l.377-380), so a refusal
        # raised before any event is a JSON body, not an event stream.
        assert answer["content_type"].startswith("application/json"), answer
        ingress = [line for line in _lines(out) if line["ledger"] == "ingress"]
        assert [(line["phase"], line["method"]) for line in ingress] == [("arrival", op), ("response", op)]
        assert ingress[1]["status"] == 200
        events = [line["event"] for line in _execution(out)]
        assert events == ["received", "result"], events
        assert model.calls == 0
        other = STREAM_BODY if op == "SendMessage" else SEND_BODY
        served_answer = _post(served.port, other)
        assert served_answer["code"] == 0 and served_answer["result"], served_answer
        assert model.calls == 1


def test_ingress_lines_and_model_call_unchanged_for_operations_not_refused():
    def read(setting: str):
        out, model = io.StringIO(), FakeModel()
        with _served(out, model, setting) as served:
            for body in (SEND_BODY, STREAM_BODY):
                answer = _post(served.port, body)
                assert answer["result"], answer
        ingress = []
        for line in _lines(out):
            if line["ledger"] != "ingress":
                continue
            for key in ("ts_arrival", "ts_end", "remote"):
                if key in line:
                    line[key] = "<masked>"
            ingress.append(line)
        calls = [{k: v for k, v in h.items() if k in ("x-logical-work-item-id", "x-a2a-message-id", "x-caller",
                                                      "content-type")} | {"task-set": bool(h.get("x-a2a-task-id"))}
                 for h in model.headers]
        return ingress, calls

    off_ingress, off_calls = read("")
    on_ingress, on_calls = read("SubscribeToTask")
    assert len(off_ingress) == 4 and on_ingress == off_ingress
    assert len(off_calls) == 2 and on_calls == off_calls


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def _process(value: str, port: int) -> subprocess.Popen:
    env = {k: v for k, v in os.environ.items() if not k.startswith("OTEL_")}
    env.update({REFUSE_OPERATION_ENV: value, "PORT": str(port), "DOWNSTREAM_A2A_URL": ""})
    return subprocess.Popen([sys.executable, "-m", "orchestrator.server"], cwd=Path(__file__).parent.parent,
                            env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)


@pytest.mark.parametrize("value", ["GetTask", "subscribetotask", "SubscribeToTask "])
def test_the_process_stops_at_start_on_a_value_it_cannot_refuse(value):
    port = _free_port()
    proc = _process(value, port)
    try:
        _, stderr = proc.communicate(timeout=30)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.communicate()
        pytest.fail(f"{value!r}: the process was still running after 30 s")
    assert proc.returncode != 0
    assert REFUSE_OPERATION_ENV in stderr
    with socket.socket() as s:
        assert s.connect_ex(("127.0.0.1", port)) != 0, "nothing may be listening"


def test_the_process_starts_and_refuses_with_a_value_it_can_refuse():
    port = _free_port()
    proc = _process("SubscribeToTask", port)
    try:
        deadline = time.monotonic() + 30
        while True:
            with socket.socket() as s:
                if s.connect_ex(("127.0.0.1", port)) == 0:
                    break
            assert proc.poll() is None, proc.stderr.read()
            assert time.monotonic() < deadline, "the process never listened"
            time.sleep(0.05)
        answer = _post(port, SUBSCRIBE_BODY)
        assert answer["code"] == -32004 and "SubscribeToTask is refused by this agent" in answer["message"], answer
    finally:
        proc.kill()
        proc.communicate()

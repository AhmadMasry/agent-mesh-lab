"""Follow-on D-2: the gRPC binding on the Python receiver. The ledger is a
server interceptor wrapping the deserializer and the behaviour, so a request is
on the ingress ledger before the SDK's servicer sees it -- including one the
servicer then refuses, and one that never deserializes."""
from __future__ import annotations

import hashlib
import io
import json
import struct

import grpc
import grpc.aio
import pytest
from a2a.types import a2a_pb2, a2a_pb2_grpc
from google.protobuf import struct_pb2

from orchestrator.agent import build_card, build_handler
from orchestrator.grpc_ingress import build_grpc_server
from tests.test_model import FakeModel


def _lines(out: io.StringIO) -> list[dict]:
    return [json.loads(line) for line in out.getvalue().splitlines() if line.strip()]


def _ingress(out):
    return [line for line in _lines(out) if line["ledger"] == "ingress"]


def _execution(out):
    return [line for line in _lines(out) if line["ledger"] == "execution"]


class Served:
    def __init__(self, refuse: str = "", read_headers: bool = False) -> None:
        self.out = io.StringIO()
        handler = build_handler(name="orchestrator", model=FakeModel().client(), forwarder=None, out=self.out,
                                public_url="http://orchestrator", refuse=refuse, grpc_url="orchestrator:8081")
        self.server, self.port = build_grpc_server(handler, out=self.out, read_headers=read_headers,
                                                   address="127.0.0.1:0")

    async def __aenter__(self):
        await self.server.start()
        self.channel = grpc.aio.insecure_channel(f"127.0.0.1:{self.port}", options=[("grpc.enable_retries", 0)])
        self.stub = a2a_pb2_grpc.A2AServiceStub(self.channel)
        return self

    async def __aexit__(self, *_):
        await self.channel.close()
        await self.server.stop(grace=None)


def _send_request(message_id="m-grpc", lwi="w-grpc") -> a2a_pb2.SendMessageRequest:
    md = struct_pb2.Struct()
    md.update({"logical_work_item_id": lwi})
    return a2a_pb2.SendMessageRequest(message=a2a_pb2.Message(
        message_id=message_id, role=a2a_pb2.ROLE_USER, parts=[a2a_pb2.Part(text="hello")], metadata=md))


def test_card_lists_three_bindings_json_rpc_first():
    card = build_card("orchestrator", "http://orchestrator:8080", "orchestrator:8081")
    assert [(i.protocol_binding, i.url) for i in card.supported_interfaces] == [
        ("JSONRPC", "http://orchestrator:8080"), ("HTTP+JSON", "http://orchestrator:8080"),
        ("GRPC", "orchestrator:8081")]


async def test_send_message_is_ledgered_before_dispatch_and_dispatched_once():
    async with Served() as s:
        request = _send_request()
        resp = await s.stub.SendMessage(request, metadata=(("a2a-version", "1.0"),))
    assert resp.task.status.state == a2a_pb2.TASK_STATE_COMPLETED
    arrival, response = _ingress(s.out)
    raw = request.SerializeToString()
    framed = b"\x00" + struct.pack(">I", len(raw)) + raw
    assert (arrival["phase"], arrival["method"], arrival["binding"]) == ("arrival", "SendMessage", "grpc")
    assert (arrival["messageId"], arrival["logical_work_item_id"], arrival["id"]) == ("m-grpc", "w-grpc", "")
    assert arrival["body_sha256"] == hashlib.sha256(framed).hexdigest() and arrival["body_len"] == len(framed)
    assert arrival["a2a_version"] == "1.0" and arrival["remote"].startswith("127.0.0.1:")
    keys = list(arrival)
    assert keys[keys.index("method") + 1] == "binding"
    assert response["phase"] == "response" and response["grpc_status"] == 0 and response["status"] is None
    assert "stream_end" not in response
    received = [e for e in _execution(s.out) if e["event"] == "received"]
    assert [(e["method"], e["messageId"]) for e in received] == [("SendMessage", "m-grpc")]
    assert [e["event"] for e in _execution(s.out)].count("execute") == 1
    # The arrival is written before the SDK's servicer ran: it precedes the
    # execution ledger's received line.
    order = [(line["ledger"], line.get("phase") or line.get("event")) for line in _lines(s.out)]
    assert order.index(("ingress", "arrival")) < order.index(("execution", "received"))


async def test_subscribe_to_a_missing_task_is_ledgered_with_its_task_id_and_status():
    async with Served() as s:
        call = s.stub.SubscribeToTask(a2a_pb2.SubscribeToTaskRequest(id="no-such-task"),
                                      metadata=(("x-logical-work-item-id", "w-sub"), ("a2a-version", "1.0")))
        with pytest.raises(grpc.aio.AioRpcError) as err:
            async for _ in call:
                pass
    assert err.value.code() == grpc.StatusCode.NOT_FOUND
    arrival, response = _ingress(s.out)
    assert (arrival["method"], arrival["binding"], arrival["taskId"]) == ("SubscribeToTask", "grpc", "no-such-task")
    assert (arrival["logical_work_item_id"], arrival["lwi_source"]) == ("w-sub", "header")
    assert response["grpc_status"] == grpc.StatusCode.NOT_FOUND.value[0]
    assert response["stream_end"] == "error" and response["ts_end"]


async def test_a_request_the_servicer_refuses_is_counted_first():
    async with Served(refuse="SendMessage") as s:
        with pytest.raises(grpc.aio.AioRpcError) as err:
            await s.stub.SendMessage(_send_request("m-refused", "w-refused"))
    assert err.value.code() == grpc.StatusCode.FAILED_PRECONDITION  # UnsupportedOperationError, spec §5.4
    arrival, response = _ingress(s.out)
    assert (arrival["method"], arrival["messageId"]) == ("SendMessage", "m-refused")
    assert response["grpc_status"] == grpc.StatusCode.FAILED_PRECONDITION.value[0]
    assert [e["event"] for e in _execution(s.out)].count("execute") == 0


async def test_bytes_that_do_not_deserialize_are_still_counted():
    async with Served() as s:
        raw_call = s.channel.unary_unary("/lf.a2a.v1.A2AService/SendMessage",
                                         request_serializer=lambda b: b, response_deserializer=lambda b: b)
        with pytest.raises(grpc.aio.AioRpcError):
            await raw_call(b"\xff\xff\xff not protobuf", metadata=(("x-logical-work-item-id", "w-bad"),))
    lines = _ingress(s.out)
    assert len(lines) == 1
    (arrival,) = lines
    assert arrival["method"] == "SendMessage" and arrival["remote"] == "" and arrival["logical_work_item_id"] == "w-bad"
    assert _execution(s.out) == []


async def test_the_header_reading_is_on_the_arrival_line_only():
    async with Served(read_headers=True) as s:
        await s.stub.SendMessage(_send_request(), metadata=(("x-caller", "loadgen"), ("authorization", "Bearer x")))
    arrival, response = _ingress(s.out)
    assert "headers" in arrival and "headers" not in response
    assert arrival["headers"]["values"].get("x-caller") == "loadgen"
    assert arrival["headers"]["authorization_present"] is True
    assert "Bearer" not in json.dumps(arrival)


def _free_port() -> int:
    import socket
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def test_the_process_serves_both_ports_and_stops_on_sigterm():
    """python -m orchestrator.server, as the image's CMD runs it under the
    launcher: JSON-RPC and REST on PORT, gRPC on GRPC_PORT, one process; a
    SIGTERM ends both: uvicorn shuts down, the lifespan stops the gRPC server,
    and uvicorn re-raises the signal, as uvicorn.run always has."""
    import os
    import signal
    import subprocess
    import sys
    import time
    import urllib.request

    http_port, grpc_port = _free_port(), _free_port()
    env = {**os.environ, "PORT": str(http_port), "GRPC_PORT": str(grpc_port), "MODEL_BASE_URL": "http://127.0.0.1:9/v1"}
    for k in ("DOWNSTREAM_A2A_URL", "REFUSE_OPERATION", "LEDGER_HEADERS", "FORWARD_RESUBSCRIBE"):
        env.pop(k, None)
    proc = subprocess.Popen([sys.executable, "-m", "orchestrator.server"], env=env, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE)
    try:
        deadline = time.monotonic() + 20
        while True:
            try:
                with urllib.request.urlopen(f"http://127.0.0.1:{http_port}/healthz", timeout=1) as r:
                    assert r.status == 200
                    break
            except OSError:
                if time.monotonic() > deadline:
                    raise
                time.sleep(0.1)
        with urllib.request.urlopen(f"http://127.0.0.1:{http_port}/.well-known/agent-card.json", timeout=5) as r:
            card = json.loads(r.read())
        assert [i["protocolBinding"] for i in card["supportedInterfaces"]] == ["JSONRPC", "HTTP+JSON", "GRPC"]
        channel = grpc.insecure_channel(f"127.0.0.1:{grpc_port}", options=[("grpc.enable_retries", 0)])
        stub = a2a_pb2_grpc.A2AServiceStub(channel)
        with pytest.raises(grpc.RpcError) as err:
            for _ in stub.SubscribeToTask(a2a_pb2.SubscribeToTaskRequest(id="none"), timeout=10):
                pass
        assert err.value.code() == grpc.StatusCode.NOT_FOUND
        channel.close()
    finally:
        proc.send_signal(signal.SIGTERM)
        out, _ = proc.communicate(timeout=30)
    assert proc.returncode == -signal.SIGTERM
    methods = [json.loads(line)["method"] for line in out.decode().splitlines()
               if line.startswith("{") and json.loads(line).get("phase") == "arrival"]
    assert "SubscribeToTask" in methods

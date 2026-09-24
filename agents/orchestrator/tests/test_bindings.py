"""Follow-on D-2: the REST binding beside JSON-RPC on the Python receiver.

The card lists JSON-RPC first; the forward stays on JSON-RPC whatever a card
lists; a REST arrival is on the ingress ledger, with its operation read from
the path, before the SDK sees it; the execution ledger counts a REST dispatch
as it counts a JSON-RPC one; a JSON-RPC line carries no new key."""
from __future__ import annotations

import io
import json

import httpx
import pytest
from a2a.types import AgentCapabilities, AgentCard, AgentInterface

from orchestrator.agent import build_card
from orchestrator.forward import Forwarder
from orchestrator.ledger import rest_operation
from orchestrator.server import build_app
from tests.socket_harness import ServedApp
from tests.test_model import FakeModel

KNOBS = ("CLIENT_RETRIES", "CLIENT_TRANSPORT_RESEND", "CLIENT_SDK_RESEND", "CLIENT_RETRY_ON", "FORWARD_RESUBSCRIBE")


@pytest.fixture(autouse=True)
def clear_knobs(monkeypatch):
    for name in KNOBS:
        monkeypatch.delenv(name, raising=False)


def _lines(out: io.StringIO) -> list[dict]:
    return [json.loads(line) for line in out.getvalue().splitlines() if line.strip()]


def _ingress(out: io.StringIO) -> list[dict]:
    return [line for line in _lines(out) if line["ledger"] == "ingress"
            and line["method"] != "GET /.well-known/agent-card.json"]


def _execution(out: io.StringIO) -> list[dict]:
    return [line for line in _lines(out) if line["ledger"] == "execution"]


def _app(out: io.StringIO, refuse: str = ""):
    return build_app(name="orchestrator", model=FakeModel().client(), forwarder=None, out=out,
                     public_url="http://orchestrator", refuse=refuse)


REST_SEND = {"message": {"messageId": "m-rest", "role": "ROLE_USER", "parts": [{"text": "hello"}],
                         "metadata": {"logical_work_item_id": "w-rest"}}}
JSONRPC_SEND = ('{"jsonrpc":"2.0","method":"SendMessage","params":{"message":{"messageId":"m-rpc",'
                '"metadata":{"logical_work_item_id":"w-rpc"},"parts":[{"text":"hello"}],'
                '"role":"ROLE_USER"}},"id":"rpc-1"}')


def test_card_lists_json_rpc_first():
    card = build_card("orchestrator", "http://orchestrator:8080")
    assert [(i.protocol_binding, i.url, i.protocol_version) for i in card.supported_interfaces] == [
        ("JSONRPC", "http://orchestrator:8080", "1.0"),
        ("HTTP+JSON", "http://orchestrator:8080", "1.0"),
    ]


def test_rest_send_message_is_ledgered_before_dispatch_and_dispatched_once():
    out = io.StringIO()
    with ServedApp(_app(out)) as served:
        r = httpx.post(f"http://127.0.0.1:{served.port}/message:send", json=REST_SEND,
                       headers={"A2A-Version": "1.0"}, timeout=10)
    assert r.status_code == 200, r.text
    assert r.json()["task"]["status"]["state"] == "TASK_STATE_COMPLETED"
    arrival, response = _ingress(out)
    assert arrival["phase"] == "arrival" and arrival["binding"] == "rest" and arrival["method"] == "SendMessage"
    assert (arrival["messageId"], arrival["logical_work_item_id"], arrival["id"]) == ("m-rest", "w-rest", "")
    assert "lwi_source" not in arrival and arrival["a2a_version"] == "1.0"
    keys = list(arrival)
    assert keys[keys.index("method") + 1] == "binding"
    assert response["phase"] == "response" and response["status"] == 200 and response["binding"] == "rest"
    received = [e for e in _execution(out) if e["event"] == "received"]
    assert [(e["method"], e["messageId"], e["logical_work_item_id"]) for e in received] == [
        ("SendMessage", "m-rest", "w-rest")]
    assert [e["event"] for e in _execution(out)].count("execute") == 1


@pytest.mark.parametrize("method", ["POST", "GET"])
def test_rest_subscribe_is_ledgered_with_the_task_id_from_the_path(method):
    out = io.StringIO()
    with ServedApp(_app(out)) as served:
        r = httpx.request(method, f"http://127.0.0.1:{served.port}/tasks/no-such-task:subscribe",
                          headers={"A2A-Version": "1.0", "X-Logical-Work-Item-Id": "w-sub"}, timeout=10)
    assert r.status_code == 404, r.text
    arrival = _ingress(out)[0]
    assert (arrival["binding"], arrival["method"], arrival["taskId"]) == ("rest", "SubscribeToTask", "no-such-task")
    assert (arrival["logical_work_item_id"], arrival["lwi_source"], arrival["messageId"]) == ("w-sub", "header", "")


def test_json_rpc_lines_carry_no_new_key():
    out = io.StringIO()
    with ServedApp(_app(out)) as served:
        r = httpx.post(f"http://127.0.0.1:{served.port}/", content=JSONRPC_SEND,
                       headers={"Content-Type": "application/json", "A2A-Version": "1.0"}, timeout=10)
    assert r.status_code == 200
    for line in _ingress(out):
        assert "binding" not in line and "grpc_status" not in line
        assert line["method"] == "SendMessage" and line["id"] == "rpc-1"


def test_the_tenant_mount_is_not_served():
    """server.py serves the SDK's REST routes at the root only, as the Go worker
    does; a tenant-prefixed path is not a REST route here and the ledger records
    it as the plain request it is."""
    out = io.StringIO()
    with ServedApp(_app(out)) as served:
        r = httpx.post(f"http://127.0.0.1:{served.port}/t1/message:send", json=REST_SEND, timeout=10)
    assert r.status_code in (404, 405)
    (arrival, _) = _ingress(out)
    assert "binding" not in arrival and arrival["method"] == ""
    assert rest_operation("POST", "/t1/message:send") is None


def test_refuse_holds_on_rest():
    out = io.StringIO()
    with ServedApp(_app(out, refuse="SendMessage")) as served:
        r = httpx.post(f"http://127.0.0.1:{served.port}/message:send", json=REST_SEND, timeout=10)
    assert r.status_code == 400, r.text  # UnsupportedOperationError, spec §5.4
    arrival = _ingress(out)[0]
    assert (arrival["binding"], arrival["method"]) == ("rest", "SendMessage")
    assert [e["event"] for e in _execution(out)].count("execute") == 0


@pytest.mark.parametrize("path,method,want", [
    ("/message:send", "POST", ("SendMessage", "")),
    ("/message:stream", "POST", ("SendStreamingMessage", "")),
    ("/tasks/t1:subscribe", "POST", ("SubscribeToTask", "t1")),
    ("/tasks/t1:subscribe", "GET", ("SubscribeToTask", "t1")),
    ("/tasks/t1:cancel", "POST", ("CancelTask", "t1")),
    ("/tasks/t1", "GET", ("GetTask", "t1")),
    ("/tasks", "GET", ("ListTasks", "")),
    ("/tasks/t1/pushNotificationConfigs", "POST", ("CreateTaskPushNotificationConfig", "t1")),
    ("/tasks/t1/pushNotificationConfigs/p", "DELETE", ("DeleteTaskPushNotificationConfig", "t1")),
    ("/extendedAgentCard", "GET", ("GetExtendedAgentCard", "")),
    ("/", "POST", None),
    ("/message:send", "GET", None),
    ("/tasks/:subscribe", "POST", None),
    ("/.well-known/agent-card.json", "GET", None),
])
def test_rest_operation_reads_the_served_routes(path, method, want):
    assert rest_operation(method, path) == want


async def test_the_forward_stays_on_json_rpc_when_the_card_lists_rest_first():
    """The invariant the forward's rows rest on: the a2a-python client this
    agent forwards with, configured as the Forwarder configures it, POSTs
    JSON-RPC to the JSON-RPC interface even when the downstream card lists
    HTTP+JSON first and gRPC beside it."""
    card = AgentCard(name="worker", version="0.0.0", description="d", capabilities=AgentCapabilities(streaming=True),
                     supported_interfaces=[
                         AgentInterface(url="http://downstream/rest", protocol_binding="HTTP+JSON", protocol_version="1.0"),
                         AgentInterface(url="downstream:8081", protocol_binding="GRPC", protocol_version="1.0"),
                         AgentInterface(url="http://downstream/rpc", protocol_binding="JSONRPC", protocol_version="1.0"),
                     ])
    seen: list[tuple[str, str, bytes]] = []

    async def handler(request: httpx.Request) -> httpx.Response:
        from google.protobuf.json_format import MessageToDict
        seen.append((request.method, str(request.url), request.content))
        if request.method == "GET":
            return httpx.Response(200, json=MessageToDict(card))
        rpc = json.loads(request.content)
        return httpx.Response(200, json={"jsonrpc": "2.0", "id": rpc["id"], "result": {"message": {
            "messageId": "a", "role": "ROLE_AGENT", "parts": [{"text": "the answer"}]}}})

    f = Forwarder(url="http://downstream/", http_client=httpx.AsyncClient(transport=httpx.MockTransport(handler)))
    assert await f.forward("hello", "w-1") == "the answer"
    posts = [s for s in seen if s[0] == "POST"]
    assert len(posts) == 1 and posts[0][1] == "http://downstream/rpc"
    body = json.loads(posts[0][2])
    assert body["jsonrpc"] == "2.0" and body["method"] == "SendMessage"

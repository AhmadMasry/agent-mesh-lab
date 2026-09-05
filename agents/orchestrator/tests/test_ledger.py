"""Ingress ledger: one line per physical delivery, written before the SDK sees the request."""
import hashlib
import io
import json

from starlette.applications import Starlette
from starlette.responses import PlainTextResponse
from starlette.routing import Route
from starlette.testclient import TestClient

from orchestrator.ledger import IngressMiddleware, parse_ingress

# Recorded on 2026-09-05 from the a2a-go v2.5.0 client against a request-dump listener.
GO_BODY = (
    b'{"jsonrpc":"2.0","method":"SendMessage","params":{"message":{"messageId":'
    b'"01a06f19-cf55-7daf-af2b-a251c81a0375","metadata":{"logical_work_item_id":"go-dump"},'
    b'"parts":[{"text":"lwi:go-dump hello"}],"role":"ROLE_USER"}},"id":"66f3ae4b-47df-4346-8fdb-0aacc23d7869"}'
)
# Hand-written pre-1.0 shape (0.3): method message/send, numeric id, kind-tagged parts.
V03_BODY = (
    b'{"jsonrpc":"2.0","id":7,"method":"message/send","params":{"message":{"messageId":"m-03",'
    b'"role":"user","parts":[{"kind":"text","text":"lwi:x hi"}],"metadata":{"logical_work_item_id":"x"}}}}'
)


def test_parse_ingress_a2a_go_body():
    line = parse_ingress(method="POST", path="/", headers={"a2a-version": "1.0", "content-type": "application/json"},
                         remote="10.0.0.1:1234", body=GO_BODY)
    assert line["ledger"] == "ingress"
    assert line["method"] == "SendMessage"
    assert line["id"] == "66f3ae4b-47df-4346-8fdb-0aacc23d7869"
    assert line["messageId"] == "01a06f19-cf55-7daf-af2b-a251c81a0375"
    assert line["taskId"] == ""
    assert line["logical_work_item_id"] == "go-dump"
    assert line["a2a_version"] == "1.0"
    assert line["body_sha256"] == hashlib.sha256(GO_BODY).hexdigest()
    assert line["body_len"] == len(GO_BODY)
    assert line["ts_arrival"] and line["content_type"] == "application/json"


def test_parse_ingress_zero_point_three_body_is_counted_too():
    line = parse_ingress(method="POST", path="/", headers={}, remote="r", body=V03_BODY)
    assert (line["method"], line["id"], line["messageId"], line["logical_work_item_id"]) == ("message/send", "7", "m-03", "x")
    assert line["a2a_version"] == ""


def test_parse_ingress_non_jsonrpc_request_still_counted():
    line = parse_ingress(method="GET", path="/.well-known/agent-card.json", headers={}, remote="r", body=b"")
    assert line["method"] == "GET /.well-known/agent-card.json"
    assert line["id"] == "" and line["messageId"] == "" and line["body_len"] == 0


def _app_with_middleware(out):
    seen = {}

    async def echo(request):
        seen["body"] = await request.body()
        return PlainTextResponse("created", status_code=201)

    app = Starlette(routes=[Route("/", echo, methods=["POST"])])
    app.add_middleware(IngressMiddleware, out=out)
    return app, seen


def test_middleware_passes_body_through_unchanged_and_records_status():
    out = io.StringIO()
    app, seen = _app_with_middleware(out)
    client = TestClient(app)
    r = client.post("/", content=GO_BODY, headers={"A2A-Version": "1.0", "Content-Type": "application/json"})
    assert r.status_code == 201
    assert seen["body"] == GO_BODY
    lines = [json.loads(l) for l in out.getvalue().splitlines() if l.strip()]
    assert len(lines) == 1
    assert lines[0]["status"] == 201 and lines[0]["messageId"] == "01a06f19-cf55-7daf-af2b-a251c81a0375"


def test_middleware_malformed_body_is_counted_not_rejected():
    out = io.StringIO()
    app, _ = _app_with_middleware(out)
    r = TestClient(app).post("/", content=b"{not json")
    assert r.status_code == 201
    line = json.loads(out.getvalue().strip())
    assert line["body_sha256"] == hashlib.sha256(b"{not json").hexdigest() and line["method"] == ""

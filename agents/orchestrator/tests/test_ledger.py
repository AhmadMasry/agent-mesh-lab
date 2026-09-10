"""Ingress ledger: one line per physical delivery, written before the SDK sees the request."""
import asyncio
import hashlib
import io
import json

from starlette.applications import Starlette
from starlette.responses import PlainTextResponse, StreamingResponse
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
    assert [l["phase"] for l in lines] == ["arrival", "response"]
    assert "status" not in lines[0] and lines[0]["messageId"] == "01a06f19-cf55-7daf-af2b-a251c81a0375"
    assert lines[1]["status"] == 201 and lines[1]["messageId"] == lines[0]["messageId"]
    assert lines[1]["ts_arrival"] == lines[0]["ts_arrival"] and lines[1]["body_sha256"] == lines[0]["body_sha256"]


def test_middleware_arrival_line_is_written_before_dispatch():
    out = io.StringIO()
    seen = {}

    async def endpoint(request):
        seen["at_dispatch"] = out.getvalue()
        return PlainTextResponse("ok")

    app = Starlette(routes=[Route("/", endpoint, methods=["POST"])])
    app.add_middleware(IngressMiddleware, out=out)
    TestClient(app).post("/", content=GO_BODY)
    line = json.loads(seen["at_dispatch"].strip())
    assert line["phase"] == "arrival" and "status" not in line


def test_middleware_malformed_body_is_counted_not_rejected():
    out = io.StringIO()
    app, _ = _app_with_middleware(out)
    r = TestClient(app).post("/", content=b"{not json")
    assert r.status_code == 201
    line = json.loads(out.getvalue().splitlines()[0])
    assert line["body_sha256"] == hashlib.sha256(b"{not json").hexdigest() and line["method"] == "" and line["phase"] == "arrival"


# The middleware replays the body it read, so the app's receive() is the
# middleware's, not the server's. A streaming response also awaits receive() to
# watch for a client disconnect, so the replay must hand the rest of the ASGI
# conversation back to the real receive instead of reporting a disconnect.
def test_streaming_response_survives_replayed_receive():
    out = io.StringIO()

    async def stream(request):
        await request.body()  # the SDK reads the body before responding

        async def chunks():
            yield b"first-chunk;"
            await asyncio.sleep(0)
            yield b"second-chunk;"
            await asyncio.sleep(0)
            yield b"third-chunk"

        return StreamingResponse(chunks(), media_type="text/plain")

    app = Starlette(routes=[Route("/", stream, methods=["POST"])])
    app.add_middleware(IngressMiddleware, out=out)
    r = TestClient(app).post("/", content=GO_BODY)

    assert r.status_code == 200
    assert r.text == "first-chunk;second-chunk;third-chunk"
    lines = [json.loads(l) for l in out.getvalue().splitlines() if l.strip()]
    assert [l["phase"] for l in lines] == ["arrival", "response"]
    assert lines[1]["status"] == 200


# A client that goes away mid-body is not a small request. An ASGI server answers
# receive() with http.disconnect instead of the rest of the body, and the middleware
# reads the body before the SDK does, so what it does with that message decides what
# both the ledger and the SDK see. These two drive the middleware directly, because a
# TestClient cannot cut a connection in the middle of a body.
def _scripted(incoming):
    """A receive that hands back `incoming` in order, a send that records, and a scope.

    Once `incoming` runs out the receive reports a disconnect, which is what an ASGI
    server does after the client is gone."""
    got, sent = [], []

    async def receive():
        return incoming.pop(0) if incoming else {"type": "http.disconnect"}

    async def send(message):
        sent.append(message)

    scope = {
        "type": "http", "method": "POST", "path": "/",
        "headers": [(b"content-type", b"application/json")], "client": ("10.0.0.1", 1234),
    }
    return got, sent, receive, send, scope


def test_receive_replay_passes_a_mid_body_disconnect_through():
    out = io.StringIO()
    first_half = GO_BODY[:40]
    got, sent, receive, send, scope = _scripted([
        {"type": "http.request", "body": first_half, "more_body": True},
        {"type": "http.disconnect"},
    ])

    async def app(scope, receive, send):
        got.append(await receive())
        got.append(await receive())
        got.append(await receive())  # after the disconnect, the disconnect again

    asyncio.run(IngressMiddleware(app, out=out)(scope, receive, send))

    # The application is handed the bytes that arrived, marked unfinished, and then
    # the disconnect: never a truncated body presented as a complete one.
    assert got[0] == {"type": "http.request", "body": first_half, "more_body": True}
    assert got[1] == {"type": "http.disconnect"}
    assert got[2] == {"type": "http.disconnect"}

    # The delivery is still counted, and the line says the bytes are partial.
    lines = [json.loads(l) for l in out.getvalue().splitlines() if l.strip()]
    assert [l["phase"] for l in lines] == ["arrival", "response"]
    assert lines[0]["truncated"] is True and lines[1]["truncated"] is True
    assert lines[0]["body_len"] == len(first_half)
    assert lines[0]["body_sha256"] == hashlib.sha256(first_half).hexdigest()
    # The truncated JSON does not parse, so no identity is claimed from it.
    assert lines[0]["method"] == "" and lines[0]["messageId"] == ""
    assert sent == []
    # Nothing was sent, so no http.response.start named a status: the response line
    # carries 0. Pinned here so a counter reading these lines sees a shape that was
    # asserted rather than one that happened.
    assert lines[1]["status"] == 0


def test_receive_replay_hands_a_complete_body_over_whole():
    out = io.StringIO()
    got, sent, receive, send, scope = _scripted([
        {"type": "http.request", "body": GO_BODY[:40], "more_body": True},
        {"type": "http.request", "body": GO_BODY[40:], "more_body": False},
    ])

    async def app(scope, receive, send):
        got.append(await receive())
        await send({"type": "http.response.start", "status": 201, "headers": []})
        await send({"type": "http.response.body", "body": b"created"})

    asyncio.run(IngressMiddleware(app, out=out)(scope, receive, send))

    # Two chunks in, one complete body out; unchanged by the disconnect handling.
    assert got == [{"type": "http.request", "body": GO_BODY, "more_body": False}]
    lines = [json.loads(l) for l in out.getvalue().splitlines() if l.strip()]
    assert [l["phase"] for l in lines] == ["arrival", "response"]
    assert "truncated" not in lines[0] and "truncated" not in lines[1]
    assert lines[0]["body_len"] == len(GO_BODY)
    assert lines[0]["body_sha256"] == hashlib.sha256(GO_BODY).hexdigest()
    assert lines[0]["messageId"] == "01a06f19-cf55-7daf-af2b-a251c81a0375"
    assert lines[1]["status"] == 201

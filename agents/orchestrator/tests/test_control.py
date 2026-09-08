"""Receiver-side injection hooks: one firing per armed work item, counted first."""
import io
import json

from starlette.applications import Starlette
from starlette.responses import PlainTextResponse
from starlette.routing import Route
from starlette.testclient import TestClient

from orchestrator.control import MODE_HTTP503_BEFORE_DISPATCH, Injector
from orchestrator.ledger import IngressMiddleware
from orchestrator.server import build_app
from tests.test_ledger import GO_BODY
from tests.test_model import FakeModel


def _app(out=None) -> TestClient:
    return TestClient(build_app(name="orchestrator", model=FakeModel().client(), forwarder=None,
                                out=out if out is not None else io.StringIO(),
                                public_url="http://orchestrator"))


# The work item in GO_BODY. The A2A-Version header is required: without it the
# a2a-python handler treats the request as 0.3 and answers a JSON-RPC version
# error with HTTP 200, which would make a status-only assertion meaningless.
LWI = "go-dump"
SEND_HEADERS = {"Content-Type": "application/json", "A2A-Version": "1.0"}


def test_inject_arms_once_and_disarms_after_firing():
    injector = Injector()
    injector.arm(MODE_HTTP503_BEFORE_DISPATCH, "w1")
    assert injector.take("w1") == MODE_HTTP503_BEFORE_DISPATCH
    assert injector.take("w1") is None
    assert injector.take("w2") is None
    assert injector.take("") is None


def test_inject_rejects_unknown_mode_and_missing_lwi():
    client = _app()
    for body in [{"mode": "nonsense", "lwi": "w1"}, {"mode": MODE_HTTP503_BEFORE_DISPATCH}, {"mode": "", "lwi": "w1"}]:
        assert client.post("/control/inject", json=body).status_code == 400, body
    assert client.post("/control/inject", content=b"{not json").status_code == 400
    assert client.get("/control/inject").status_code == 405
    assert client.get("/control/reset").status_code == 405


def test_reset_clears_armed():
    client = _app()
    assert client.post("/control/inject", json={"mode": MODE_HTTP503_BEFORE_DISPATCH, "lwi": LWI}).status_code == 204
    assert client.post("/control/reset").status_code == 204
    r = client.post("/", content=GO_BODY, headers=SEND_HEADERS)
    assert r.status_code == 200, "the work item was still armed after a reset"
    # The request reached the SDK and produced a Task, not a JSON-RPC error.
    assert r.json()["result"]["task"]["status"]["state"] == "TASK_STATE_COMPLETED", r.text


def test_http503_before_dispatch_counts_arrival_and_skips_app():
    out = io.StringIO()
    calls = {"n": 0}

    async def endpoint(_request):
        calls["n"] += 1
        return PlainTextResponse("ok")

    injector = Injector()
    injector.arm(MODE_HTTP503_BEFORE_DISPATCH, LWI)
    app = Starlette(routes=[Route("/", endpoint, methods=["POST"])])
    app.add_middleware(IngressMiddleware, out=out, injector=injector)

    r = TestClient(app).post("/", content=GO_BODY, headers=SEND_HEADERS)
    assert r.status_code == 503
    assert r.json() == {"error": "injected"}
    assert calls["n"] == 0, "the app was called for an injected request"

    lines = [json.loads(l) for l in out.getvalue().splitlines() if l.strip()]
    assert [l["phase"] for l in lines] == ["arrival", "response"]
    assert lines[0]["logical_work_item_id"] == LWI and "injection" not in lines[0]
    assert lines[1]["status"] == 503 and lines[1]["injection"] == MODE_HTTP503_BEFORE_DISPATCH
    assert injector.take(LWI) is None, "the work item is still armed after firing"


# ASGI has no portable connection hijack, and A.2's close-after-read trigger is
# the Go receiver, so this receiver rejects the mode at the control endpoint
# rather than pretending to support it.
def test_close_after_read_reports_unsupported():
    r = _app().post("/control/inject", json={"mode": "close-after-read", "lwi": LWI})
    assert r.status_code == 400
    assert r.json() == {"error": "close-after-read is not supported by this receiver"}


def test_control_endpoints_are_not_ledgered():
    out = io.StringIO()
    client = TestClient(build_app(name="orchestrator", model=FakeModel().client(), forwarder=None, out=out,
                                  public_url="http://orchestrator"))
    assert client.post("/control/reset").status_code == 204
    assert client.post("/control/inject", json={"mode": MODE_HTTP503_BEFORE_DISPATCH, "lwi": LWI}).status_code == 204
    assert out.getvalue() == "", "arming a work item was counted as a delivery"


# The end-to-end path A.2 depends on: arm through the control endpoint on the app
# build_app assembles, then watch the injection fire on a routed request for that
# work item, then watch the next request for the same work item go through. The
# test never touches the Injector object, so this is what asserts that the
# endpoint and the middleware share one.
def test_arm_then_fire_through_routed_app():
    out = io.StringIO()
    client = _app(out)

    assert client.post("/control/inject", json={"mode": MODE_HTTP503_BEFORE_DISPATCH, "lwi": LWI}).status_code == 204
    assert out.getvalue() == "", "arming was ledgered"

    first = client.post("/", content=GO_BODY, headers=SEND_HEADERS)
    assert first.status_code == 503
    assert first.json() == {"error": "injected"}
    lines = [json.loads(l) for l in out.getvalue().splitlines() if l.strip()]
    ingress = [l for l in lines if l["ledger"] == "ingress"]
    assert [l["phase"] for l in ingress] == ["arrival", "response"]
    assert ingress[0]["logical_work_item_id"] == LWI and "injection" not in ingress[0]
    assert ingress[1]["status"] == 503 and ingress[1]["injection"] == MODE_HTTP503_BEFORE_DISPATCH
    # The SDK never saw it: no execution line for the work item.
    assert [l for l in lines if l["ledger"] == "execution"] == []

    # One arming, one firing: the same work item is served normally next time.
    second = client.post("/", content=GO_BODY, headers=SEND_HEADERS)
    assert second.status_code == 200, second.text
    assert second.json()["result"]["task"]["status"]["state"] == "TASK_STATE_COMPLETED"
    lines = [json.loads(l) for l in out.getvalue().splitlines() if l.strip()]
    ingress = [l for l in lines if l["ledger"] == "ingress"]
    assert [l["phase"] for l in ingress] == ["arrival", "response", "arrival", "response"]
    assert ingress[3]["status"] == 200 and "injection" not in ingress[3]
    events = [l["event"] for l in lines if l["ledger"] == "execution"]
    assert events == ["received", "execute", "state", "state", "state", "result"], events

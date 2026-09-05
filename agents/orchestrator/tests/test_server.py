"""The assembled app: card, JSON-RPC endpoint behind the ingress ledger, healthz."""
import io
import json

from starlette.testclient import TestClient

from orchestrator.server import build_app
from tests.test_ledger import GO_BODY
from tests.test_model import FakeModel


def test_app_serves_card_and_completes_a_task_from_the_recorded_go_body():
    fake = FakeModel()
    out = io.StringIO()
    app = build_app(name="orchestrator", model=fake.client(), forwarder=None, out=out,
                    public_url="http://orchestrator.lab.svc.cluster.local:8080")
    client = TestClient(app)

    card = client.get("/.well-known/agent-card.json")
    assert card.status_code == 200
    body = card.json()
    assert body["supportedInterfaces"][0]["protocolVersion"] == "1.0"
    assert body["supportedInterfaces"][0]["url"] == "http://orchestrator.lab.svc.cluster.local:8080"

    assert client.get("/healthz").status_code == 200

    r = client.post("/", content=GO_BODY, headers={"A2A-Version": "1.0", "Content-Type": "application/json"})
    assert r.status_code == 200, r.text
    result = r.json()["result"]
    # a2a-python wraps the SendMessage result in a oneof: {"task": ...} or {"message": ...}
    assert result["task"]["status"]["state"] == "TASK_STATE_COMPLETED"
    assert fake.calls == 1

    lines = [json.loads(l) for l in out.getvalue().splitlines() if l.strip()]
    ingress = [l for l in lines if l["ledger"] == "ingress" and l["method"] == "SendMessage"]
    assert [l["phase"] for l in ingress] == ["arrival", "response"]
    assert ingress[1]["status"] == 200 and ingress[0]["a2a_version"] == "1.0"
    assert ingress[0]["messageId"] == "01a06f19-cf55-7daf-af2b-a251c81a0375"
    assert not [l for l in lines if l["ledger"] == "ingress" and "healthz" in l["method"]]

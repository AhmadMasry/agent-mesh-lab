"""App assembly: agent card and JSON-RPC routes from the SDK, a health route, and
the ingress ledger in front of everything."""
from __future__ import annotations

import os
from typing import TextIO

from a2a.server.routes import create_agent_card_routes, create_jsonrpc_routes
from starlette.applications import Starlette
from starlette.responses import PlainTextResponse
from starlette.routing import Route

from orchestrator.agent import build_handler
from orchestrator.control import Injector
from orchestrator.forward import FORWARD_RESUBSCRIBE_ENV, Forwarder, forward_resubscribe_from
from orchestrator.headers import LEDGER_HEADERS_ENV, ledger_headers_from
from orchestrator.ledger import IngressMiddleware
from orchestrator.model import ModelClient
from orchestrator.refuse import REFUSE_OPERATION_ENV, refuse_operation_from


def build_app(*, name: str, model: ModelClient | None, forwarder: Forwarder | None, out: TextIO | None,
              public_url: str, plan_model_call: bool = False, refuse: str = "",
              ledger_headers: bool = False) -> Starlette:
    handler = build_handler(name=name, model=model, forwarder=forwarder, out=out, public_url=public_url,
                            plan_model_call=plan_model_call, refuse=refuse)
    card = handler.card

    async def healthz(_request):
        return PlainTextResponse("ok\n")

    # The control endpoints sit outside the ingress ledger, like the readiness
    # probe, so arming a work item is never counted as a delivery.
    injector = Injector()
    routes = [*create_agent_card_routes(card), *create_jsonrpc_routes(handler, rpc_url="/"),
              Route("/healthz", healthz, methods=["GET"]),
              Route("/control/inject", injector.handle_inject, methods=["POST"]),
              Route("/control/reset", injector.handle_reset, methods=["POST"])]
    app = Starlette(routes=routes)
    app.add_middleware(IngressMiddleware, out=out, injector=injector,
                       skip_paths=("/healthz", "/control/inject", "/control/reset"),
                       read_headers=ledger_headers)
    return app


def app_from_env() -> Starlette:
    # Read before anything else is built: a value that is not an operation this
    # agent can refuse raises here, and the process stops rather than serving
    # everything.
    refuse = refuse_operation_from(os.environ.get(REFUSE_OPERATION_ENV, ""))
    # The same for the ledger's header reading: a value that is not "on" raises.
    ledger_headers = ledger_headers_from(os.environ.get(LEDGER_HEADERS_ENV, ""))
    # And for the forward's one resubscription: read in either mode, so a bad
    # value stops the process in model mode too, where it would do nothing.
    resubscribe = forward_resubscribe_from(os.environ.get(FORWARD_RESUBSCRIBE_ENV, ""))
    name = os.environ.get("AGENT_NAME", "orchestrator")
    downstream = os.environ.get("DOWNSTREAM_A2A_URL", "")
    plan = os.environ.get("PLAN_MODEL_CALL", "off") == "on"
    max_retries = int(os.environ.get("MODEL_MAX_RETRIES", "0"))
    # A model client exists only where a model call can happen: model mode, or
    # forward mode with the plan call on. Pure forward mode owns no model connection.
    model = None
    if not downstream or plan:
        model = ModelClient(
            base_url=os.environ.get("MODEL_BASE_URL", "http://mockllm.lab.svc.cluster.local:8080/v1"),
            model=os.environ.get("MODEL_NAME", "mock"),
            api_key=os.environ.get("MODEL_API_KEY", "unused"),
            max_retries=max_retries,
        )
    forwarder = Forwarder(url=downstream, caller=name, resubscribe=resubscribe) if downstream else None
    return build_app(name=name, model=model, forwarder=forwarder, out=None,
                     public_url=os.environ.get("PUBLIC_URL", f"http://{name}.lab.svc.cluster.local:8080"),
                     plan_model_call=plan, refuse=refuse, ledger_headers=ledger_headers)


# The uvicorn arguments this agent is served with, in one place so that a test
# harness can serve the app the same way and an argument that matters cannot
# drift between the two. Host and port are not here: they are per-deployment,
# and a harness binds a loopback port of its own.
SERVER_SETTINGS: dict[str, object] = {"log_level": "warning", "timeout_keep_alive": 120}


def main() -> None:
    import uvicorn

    uvicorn.run(app_from_env(), host="0.0.0.0", port=int(os.environ.get("PORT", "8080")),
                **SERVER_SETTINGS)


if __name__ == "__main__":
    main()

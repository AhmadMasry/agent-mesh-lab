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
from orchestrator.forward import Forwarder
from orchestrator.ledger import IngressMiddleware
from orchestrator.model import ModelClient


def build_app(*, name: str, model: ModelClient | None, forwarder: Forwarder | None, out: TextIO | None,
              public_url: str, plan_model_call: bool = False) -> Starlette:
    handler = build_handler(name=name, model=model, forwarder=forwarder, out=out, public_url=public_url,
                            plan_model_call=plan_model_call)
    card = handler.card

    async def healthz(_request):
        return PlainTextResponse("ok\n")

    routes = [*create_agent_card_routes(card), *create_jsonrpc_routes(handler, rpc_url="/"),
              Route("/healthz", healthz, methods=["GET"])]
    app = Starlette(routes=routes)
    app.add_middleware(IngressMiddleware, out=out)
    return app


def app_from_env() -> Starlette:
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
    forwarder = Forwarder(url=downstream, caller=name) if downstream else None
    return build_app(name=name, model=model, forwarder=forwarder, out=None,
                     public_url=os.environ.get("PUBLIC_URL", f"http://{name}.lab.svc.cluster.local:8080"),
                     plan_model_call=plan)


def main() -> None:
    import uvicorn

    uvicorn.run(app_from_env(), host="0.0.0.0", port=int(os.environ.get("PORT", "8080")),
                log_level="warning", timeout_keep_alive=120)


if __name__ == "__main__":
    main()

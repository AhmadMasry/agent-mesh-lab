"""App assembly: agent card, JSON-RPC and REST routes from the SDK, a health route,
and the ingress ledger in front of everything.

JSON-RPC and REST share the one HTTP port (PORT, 8080): the SDK's REST paths
(create_rest_routes, a2a-sdk 1.1.4 server/routes/rest_routes.py l.75-114) are
disjoint from JSON-RPC's POST /, so the routes that carry 8080 today carry REST
unchanged.

The REST routes are served at the root only. create_rest_routes also returns a
Mount("/{tenant}", ...) of the same routes (l.116); it is left out, because it
matches every two-segment path, the control endpoints' included, and would
turn their wrong-method 405 into a 404 (test_control.py). a2a-go's
a2asrv.NewRESTHandler, which the Go worker serves, has no tenant routes either
(NewTenantRESTHandler is a separate constructor), so both receivers serve the
same REST paths."""
from __future__ import annotations

import contextlib
import os
from typing import TextIO

from a2a.server.routes import create_agent_card_routes, create_jsonrpc_routes, create_rest_routes
from starlette.applications import Starlette
from starlette.responses import PlainTextResponse
from starlette.routing import Mount, Route

from orchestrator.agent import build_handler
from orchestrator.control import Injector
from orchestrator.grpc_ingress import GRPC_PORT_ENV
from orchestrator.forward import FORWARD_RESUBSCRIBE_ENV, Forwarder, forward_resubscribe_from
from orchestrator.headers import LEDGER_HEADERS_ENV, ledger_headers_from
from orchestrator.ledger import IngressMiddleware
from orchestrator.model import ModelClient
from orchestrator.refuse import REFUSE_OPERATION_ENV, refuse_operation_from


def rest_routes_at_root(handler) -> list:
    """The SDK's REST routes without its /{tenant} mount (module docstring)."""
    return [r for r in create_rest_routes(handler) if not isinstance(r, Mount)]


def _grpc_lifespan(port: int):
    """The gRPC binding's server (orchestrator.grpc_ingress), started and
    stopped with the app's lifespan, so uvicorn.run serves the process exactly
    as it did before: the gRPC server starts before uvicorn accepts a request
    and is stopped, with a grace period, in uvicorn's own graceful shutdown on
    SIGTERM, before uvicorn re-raises the signal as it always has. It serves the
    one request handler the app dispatches JSON-RPC and REST through."""
    @contextlib.asynccontextmanager
    async def lifespan(app: Starlette):
        from orchestrator.grpc_ingress import build_grpc_server

        server, _ = build_grpc_server(app.state.a2a_handler, out=app.state.ledger_out,
                                      read_headers=app.state.ledger_headers, address=f"0.0.0.0:{port}")
        await server.start()
        try:
            yield
        finally:
            await server.stop(grace=5)
    return lifespan


def build_app(*, name: str, model: ModelClient | None, forwarder: Forwarder | None, out: TextIO | None,
              public_url: str, plan_model_call: bool = False, refuse: str = "",
              ledger_headers: bool = False, grpc_url: str = "", grpc_port: int | None = None) -> Starlette:
    handler = build_handler(name=name, model=model, forwarder=forwarder, out=out, public_url=public_url,
                            plan_model_call=plan_model_call, refuse=refuse, grpc_url=grpc_url)
    card = handler.card

    async def healthz(_request):
        return PlainTextResponse("ok\n")

    # The control endpoints sit outside the ingress ledger, like the readiness
    # probe, so arming a work item is never counted as a delivery.
    injector = Injector()
    routes = [*create_agent_card_routes(card), *create_jsonrpc_routes(handler, rpc_url="/"),
              Route("/healthz", healthz, methods=["GET"]),
              Route("/control/inject", injector.handle_inject, methods=["POST"]),
              Route("/control/reset", injector.handle_reset, methods=["POST"]),
              *rest_routes_at_root(handler)]
    app = Starlette(routes=routes, lifespan=_grpc_lifespan(grpc_port) if grpc_port is not None else None)
    app.add_middleware(IngressMiddleware, out=out, injector=injector,
                       skip_paths=("/healthz", "/control/inject", "/control/reset"),
                       read_headers=ledger_headers)
    # The one request handler, for the gRPC server main() starts beside the app
    # (orchestrator.grpc_ingress), so all three bindings dispatch through it.
    app.state.a2a_handler = handler
    app.state.ledger_headers = ledger_headers
    app.state.ledger_out = out
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
                     plan_model_call=plan, refuse=refuse, ledger_headers=ledger_headers,
                     grpc_url=os.environ.get("PUBLIC_GRPC_URL", f"{name}.lab.svc.cluster.local:8081"),
                     grpc_port=int(os.environ.get(GRPC_PORT_ENV, "8081")))


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

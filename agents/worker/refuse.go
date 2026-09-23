package main

import (
	"context"
	"fmt"

	"github.com/a2aproject/a2a-go/v2/a2a"
	"github.com/a2aproject/a2a-go/v2/a2asrv"
)

// refuseOperationEnv names the one A2A operation this agent refuses in the
// application, where the SDK already knows the operation (Experiment C, step
// C-10). The name says what it does and takes the operation's canonical A2A
// v1.0 name as its value; the Python orchestrator reads the same name with the
// same values, so one setting reads the same on both receivers.
//
//	unset or empty   off: nothing is refused, and the handler is built with no
//	                 interceptor at all (TestRefuseOperation_DefaultOff)
//	SendMessage,     that operation is refused before the SDK's handler runs,
//	SendStreaming-   with UnsupportedOperationError; every other operation is
//	Message,         served as it is with the setting off
//	SubscribeToTask
//	anything else    the process stops at start (main), so a typo or another
//	                 operation's name cannot leave the agent serving what a run
//	                 meant to refuse
//
// The three are the operations both receivers' execution ledgers record and the
// load client sends. Any other operation name — GetTask, CancelTask and the rest
// — is refused as a value rather than accepted, because the Python receiver's
// refusal sits in the ledger's wrappers of these three and would not refuse it.
const refuseOperationEnv = "REFUSE_OPERATION"

var refusableOperations = []string{"SendMessage", "SendStreamingMessage", "SubscribeToTask"}

// refuseOperationFrom reads the setting's value: "" when off, the operation's
// name when it is one this agent can refuse, an error otherwise. The value is
// matched exactly: no trimming and no case folding, because the operation name
// on the wire is matched exactly too.
func refuseOperationFrom(v string) (string, error) {
	if v == "" {
		return "", nil
	}
	for _, op := range refusableOperations {
		if v == op {
			return op, nil
		}
	}
	return "", fmt.Errorf("%s=%q is not an operation this agent can refuse; want one of %v, or empty for off",
		refuseOperationEnv, v, refusableOperations)
}

// refuseInterceptor refuses one operation from Before. a2a-go v2.5.0 calls
// Before for every operation, after the JSON-RPC request is decoded and before
// the handler; an error from it means "the actual handler will not be called"
// (a2asrv/middleware.go l.93-99), and the SDK sets the method name on the call
// context per operation (a2asrv/intercepted_handler.go l.54-204).
//
// The error is UnsupportedOperationError, -32004 on the JSON-RPC binding (A2A
// specification at 3303592, l.558 and l.1185): the one A2A error with a code of
// its own that both SDKs map alike, and the one the specification already
// requires for SubscribeToTask from an agent that does not serve streaming
// (l.574). The specification's authorization errors (l.511-515) name no JSON-RPC
// code, "JSON-RPC custom error", and a2a-python has no class for one; nor is
// anyone authenticated here to lack a permission.
type refuseInterceptor struct {
	a2asrv.PassthroughCallInterceptor
	op string
}

func (r refuseInterceptor) Before(ctx context.Context, callCtx *a2asrv.CallContext, _ *a2asrv.Request) (context.Context, any, error) {
	if callCtx.Method() == r.op {
		return ctx, nil, fmt.Errorf("%w: %s is refused by this agent (%s)", a2a.ErrUnsupportedOperation, r.op, refuseOperationEnv)
	}
	return ctx, nil, nil
}

// newRequestHandler is the request handler main serves: the SDK's handler, with
// the refusing interceptor only when an operation is named, inside the
// execution ledger. The ledger is outside the interceptor on purpose: a refused
// request is one the SDK decoded and would have dispatched, so it keeps its
// "received" line and gains a "result" line carrying the refusal, and the
// executor, which writes "execute", is never entered.
func newRequestHandler(executor a2asrv.AgentExecutor, lw *lineWriter, refuse string) *executionLedger {
	var opts []a2asrv.RequestHandlerOption
	if refuse != "" {
		opts = append(opts, a2asrv.WithCallInterceptors(refuseInterceptor{op: refuse}))
	}
	return newExecutionLedger(a2asrv.NewHandler(executor, opts...), lw)
}

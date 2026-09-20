| row | repetitions | deliveries | dispatched | distinct_messageIds | tasks | invocations | client_result | second_delivery_layer | trace_spans | spans_by_service |
|---|---|---|---|---|---|---|---|---|---|---|
| A.3 baseline py, Service-addressed (new) | 20 | 1 | 1 | 1 | 1 | 1 | FAILED | none | 67 | `agw-central=6\|loadgen=3\|mockllm=1\|orchestrator=57` |
| A.3 baseline py, through the ingress | 20 | 1 | 1 | 1 | 1 | 1 | FAILED | none | 67 | `agentgateway-ingress=2\|agw-central=4\|loadgen=3\|mockllm=1\|orchestrator=57` |
| A.3 R2 py, Service-addressed (new) | 20 | 2 | 1 | 1 | 1 | 1 | COMPLETED | gateway | 75 | `agw-central=7\|loadgen=3\|mockllm=1\|orchestrator=64` |
| A.3 R2 py, through the ingress, in-cluster stimulus | 20 | 2 | 1 | 1 | 1 | 1 | COMPLETED | gateway | 75 | `agentgateway-ingress=3\|agw-central=4\|loadgen=3\|mockllm=1\|orchestrator=64` |
| A.3 R2 py, through the ingress, stimulus from outside | 20 | 2 | 1 | 1 | 1 | 1 | COMPLETED | gateway | 67 | `agentgateway-ingress=3\|agw-central=2\|mockllm=1\|orchestrator=61` |
| A.3 R4 py, Service-addressed (new) | 20 | 2 | 1 | 1 | 1 | 2 | COMPLETED | gateway | 79 | `agw-central=9\|loadgen=3\|mockllm=2\|orchestrator=65` |
| A.3 R4 py, through the ingress | 20 | 2 | 1 | 1 | 1 | 2 | COMPLETED | gateway | 79 | `agentgateway-ingress=3\|agw-central=6\|loadgen=3\|mockllm=2\|orchestrator=65` |

The ingress ledger's identity fields, per repetition (rule 5; no summary.csv column carries them):
  A.3 baseline py, Service-addressed (new)               2 ingress lines, 1 JSON-RPC id, 1 messageId, 1 body hash in 20 reps
  A.3 baseline py, through the ingress                   2 ingress lines, 1 JSON-RPC id, 1 messageId, 1 body hash in 20 reps
  A.3 R2 py, Service-addressed (new)                     4 ingress lines, 1 JSON-RPC id, 1 messageId, 1 body hash in 20 reps
  A.3 R2 py, through the ingress, in-cluster stimulus    4 ingress lines, 1 JSON-RPC id, 1 messageId, 1 body hash in 20 reps
  A.3 R2 py, through the ingress, stimulus from outside  4 ingress lines, 1 JSON-RPC id, 1 messageId, 1 body hash in 20 reps
  A.3 R4 py, Service-addressed (new)                     4 ingress lines, 1 JSON-RPC id, 1 messageId, 1 body hash in 20 reps
  A.3 R4 py, through the ingress                         4 ingress lines, 1 JSON-RPC id, 1 messageId, 1 body hash in 20 reps

#!/usr/bin/env bash
# kind_validate_subscription_kafka.sh — noetl/ai-meta#90 Phase 1
# Kafka backend live E2E.
#
# Brings the `subscription` tool's Apache Kafka poll backend to the same
# live-validation bar NATS met: deploy single-broker KRaft Kafka (ops
# ci/manifests/kafka/), create a topic, produce N messages, run the
# bounded-drain playbook on the worker, and assert the tool drained N,
# committed offsets, the execution reached COMPLETED, and the event trail
# landed in the event log.
#
# Assertions (all required for PASS):
#   1. Final execution status is COMPLETED.
#   2. The `drain` step's tool result has source=kafka, count=N, acked=true.
#   3. The event log carries the drain trail: call.done(drain) +
#      command.completed(drain) + playbook.completed.
#
# The topic + consumer group are unique per run, so the fresh group reads
# from the earliest offset and drains exactly N (the kafka backend uses
# FetchOffset::Earliest as the fallback for a group with no committed
# offset).
#
# Usage:
#   ./scripts/kind_validate_subscription_kafka.sh
#   ./scripts/kind_validate_subscription_kafka.sh --context kind-noetl --count 5
#
# Exits 0 if PASS; 1 if any assertion fails (dumps server + worker logs).

set -euo pipefail

KIND_CONTEXT="${NOETL_KIND_CONTEXT:-kind-noetl}"
NAMESPACE="${NOETL_K8S_NAMESPACE:-noetl}"
KAFKA_NS="${NOETL_KAFKA_NS:-kafka}"
NOETL_SERVER_DEPLOY="${NOETL_SERVER_DEPLOY:-noetl-server-rust}"
NOETL_WORKER_DEPLOY="${NOETL_WORKER_DEPLOY:-noetl-worker-rust}"
NOETL_SERVER_URL="${NOETL_SERVER_URL:-http://localhost:8082}"
TIMEOUT_SECS="${NOETL_SUB_TIMEOUT_SECS:-180}"
COUNT="${NOETL_SUB_COUNT:-5}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --context)    KIND_CONTEXT="$2"; shift 2 ;;
    --namespace)  NAMESPACE="$2"; shift 2 ;;
    --server-url) NOETL_SERVER_URL="$2"; shift 2 ;;
    --timeout)    TIMEOUT_SECS="$2"; shift 2 ;;
    --count)      COUNT="$2"; shift 2 ;;
    -h|--help)    sed -n '2,/^set -euo/p' "$0" | sed -n '/^#/p'; exit 0 ;;
    *) echo "kind-val: unknown argument: $1" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURE_PATH="$REPO_ROOT/fixtures/playbooks/subscription/subscription_kafka_drain.yaml"
CRED_FILE="$REPO_ROOT/fixtures/credentials/kafka_e2e.json.example"
PLAYBOOK_PATH="tests/fixtures/subscription_kafka_drain"

# Unique per-run topic + consumer group so re-runs drain exactly N.
SUFFIX="$(date +%s)$$"
TOPIC="noetl.e2e.kafka.$SUFFIX"
GROUP="noetl-e2e-kafka-$SUFFIX"

echo "kind-val: context=$KIND_CONTEXT namespace=$NAMESPACE kafka-ns=$KAFKA_NS"
echo "kind-val: server=$NOETL_SERVER_URL fixture=$FIXTURE_PATH"
echo "kind-val: count=$COUNT topic=$TOPIC group=$GROUP"

# ----------------------------------------------------------------------
# Preflight.
# ----------------------------------------------------------------------
for cmd in kubectl noetl python3; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "kind-val: required command not in PATH: $cmd" >&2; exit 2; }
done
[[ -f "$FIXTURE_PATH" ]] || { echo "kind-val: fixture not found: $FIXTURE_PATH" >&2; exit 2; }
[[ -f "$CRED_FILE" ]] || { echo "kind-val: credential not found: $CRED_FILE" >&2; exit 2; }

KCTX=(kubectl --context "$KIND_CONTEXT")
"${KCTX[@]}" -n "$NAMESPACE" get deployment "$NOETL_SERVER_DEPLOY" >/dev/null 2>&1 || {
  echo "kind-val: $NOETL_SERVER_DEPLOY not found in $NAMESPACE." >&2; exit 2; }
"${KCTX[@]}" -n "$KAFKA_NS" rollout status deploy/kafka --timeout=120s >/dev/null 2>&1 || {
  echo "kind-val: kafka not ready in $KAFKA_NS (apply ops ci/manifests/kafka/)." >&2; exit 2; }
curl -fsS "$NOETL_SERVER_URL/api/health" >/dev/null 2>&1 || {
  echo "kind-val: server not reachable at $NOETL_SERVER_URL — start a port-forward first." >&2; exit 2; }

KEXEC=("${KCTX[@]}" -n "$KAFKA_NS" exec deploy/kafka --)
BIN=/opt/kafka/bin

# ----------------------------------------------------------------------
# Create topic + produce N messages (inside the broker pod).
# ----------------------------------------------------------------------
echo "kind-val: create topic $TOPIC"
"${KEXEC[@]}" "$BIN/kafka-topics.sh" --bootstrap-server localhost:9092 \
  --create --topic "$TOPIC" --partitions 1 --replication-factor 1 >/dev/null 2>&1

echo "kind-val: produce $COUNT messages"
PRODUCE_LINES="$(python3 -c "import json; print('\n'.join(json.dumps({'order_id': i}) for i in range(int('$COUNT'))))")"
printf '%s\n' "$PRODUCE_LINES" | "${KCTX[@]}" -n "$KAFKA_NS" exec -i deploy/kafka -- \
  "$BIN/kafka-console-producer.sh" --bootstrap-server localhost:9092 --topic "$TOPIC" >/dev/null 2>&1

# ----------------------------------------------------------------------
# Register credential + playbook, then execute (override topic + group).
# ----------------------------------------------------------------------
echo
echo "================================================================"
echo "kind-val: register + execute subscription_kafka_drain"
echo "================================================================"
noetl register credential -f "$CRED_FILE"
noetl register playbook --file "$FIXTURE_PATH"

EXECUTION_ID="$(noetl exec "$PLAYBOOK_PATH" --runtime distributed \
  --set "topic=$TOPIC" --set "group=$GROUP" --json \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["execution_id"])')"
echo "kind-val: launched execution_id=$EXECUTION_ID"

# ----------------------------------------------------------------------
# Wait for terminal status.
# ----------------------------------------------------------------------
DEADLINE=$(( SECONDS + TIMEOUT_SECS )); FINAL_STATUS=""
while [[ $SECONDS -lt $DEADLINE ]]; do
  FINAL_STATUS="$(noetl status "$EXECUTION_ID" --json 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",""))' || true)"
  case "$FINAL_STATUS" in COMPLETED|FAILED) break ;; esac
  sleep 2
done
echo "kind-val: execution_id=$EXECUTION_ID final_status=$FINAL_STATUS"

# ----------------------------------------------------------------------
# Pull the event log + assertions.
# ----------------------------------------------------------------------
EVENTS_JSON="$(noetl query \
  "SELECT event_id, event_type, node_name, result FROM noetl.event WHERE execution_id = $EXECUTION_ID ORDER BY event_id" \
  --format json 2>/dev/null || echo '{"result": []}')"

OVERALL=0
fail() { echo "kind-val: FAIL — $1" >&2; OVERALL=1; }

[[ "$FINAL_STATUS" == "COMPLETED" ]] || fail "expected COMPLETED, got $FINAL_STATUS"

DRAIN_CHECK="$(printf '%s' "$EVENTS_JSON" | python3 -c '
import json, sys
want = int("'"$COUNT"'")
events = json.loads(sys.stdin.read() or "{}").get("result", [])
def drain_data():
    for e in events:
        if e.get("event_type") == "call.done" and e.get("node_name") == "drain":
            try:
                return e["result"]["context"]["result"]["context"]["data"]
            except (KeyError, TypeError):
                return None
    return None
d = drain_data()
if not d:
    print("MISSING drain call.done result"); sys.exit()
src, cnt, ack = d.get("source"), d.get("count"), d.get("acked")
if src != "kafka": print(f"WRONG source={src}")
elif cnt != want:  print(f"WRONG count={cnt} (want {want})")
elif ack is not True: print(f"NOT-ACKED acked={ack}")
else: print("OK")
')"
[[ "$DRAIN_CHECK" == "OK" ]] || fail "drain result check: $DRAIN_CHECK"

TRAIL_OK="$(printf '%s' "$EVENTS_JSON" | python3 -c '
import json, sys
events = json.loads(sys.stdin.read() or "{}").get("result", [])
have = {(e.get("event_type"), e.get("node_name")) for e in events}
need = [("call.done","drain"), ("command.completed","drain"), ("playbook.completed","playbook")]
missing = [f"{t}:{n}" for (t,n) in need if (t,n) not in have]
print("OK" if not missing else "MISSING " + ",".join(missing))
')"
[[ "$TRAIL_OK" == "OK" ]] || fail "event trail check: $TRAIL_OK"

echo
if [[ "$OVERALL" -eq 0 ]]; then
  echo "================================================================"
  echo "kind-val: PASS — Kafka subscription drain green"
  echo "  - final_status=COMPLETED"
  echo "  - drain: source=kafka count=$COUNT acked=true"
  echo "  - event trail: call.done(drain) + command.completed(drain) + playbook.completed"
  echo "================================================================"
  exit 0
fi
echo "================================================================"
echo "kind-val: FAIL — see assertion errors above"
echo "================================================================"
echo "kind-val: server logs (tail 80):"; "${KCTX[@]}" -n "$NAMESPACE" logs deploy/"$NOETL_SERVER_DEPLOY" --tail=80 || true
echo; echo "kind-val: worker logs (tail 80):"; "${KCTX[@]}" -n "$NAMESPACE" logs deploy/"$NOETL_WORKER_DEPLOY" --tail=80 || true
exit 1

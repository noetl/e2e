#!/usr/bin/env bash
# kind_validate_subscription_pubsub.sh — noetl/ai-meta#90 Phase 1
# Pub/Sub backend live E2E.
#
# Brings the `subscription` tool's Google Pub/Sub pull backend to the same
# live-validation bar NATS met: deploy the Pub/Sub emulator (ops
# ci/manifests/pubsub-emulator/), create a topic + subscription, publish N
# messages, run the bounded-drain playbook on the worker, and assert the
# tool drained exactly N, acked them, the execution reached COMPLETED, and
# the event trail landed in the event log.
#
# Assertions (all required for PASS):
#   1. Final execution status is COMPLETED.
#   2. The `drain` step's tool result has source=pubsub, count=N, acked=true.
#   3. The event log carries the drain trail: call.done(drain) +
#      command.completed(drain) + playbook.completed.
#
# Usage:
#   ./scripts/kind_validate_subscription_pubsub.sh
#   ./scripts/kind_validate_subscription_pubsub.sh --context kind-noetl --count 5
#
# Exits 0 if PASS; 1 if any assertion fails (dumps server + worker logs).

set -euo pipefail

KIND_CONTEXT="${NOETL_KIND_CONTEXT:-kind-noetl}"
NAMESPACE="${NOETL_K8S_NAMESPACE:-noetl}"
PUBSUB_NS="${NOETL_PUBSUB_NS:-pubsub}"
NOETL_SERVER_DEPLOY="${NOETL_SERVER_DEPLOY:-noetl-server-rust}"
NOETL_WORKER_DEPLOY="${NOETL_WORKER_DEPLOY:-noetl-worker-rust}"
NOETL_SERVER_URL="${NOETL_SERVER_URL:-http://localhost:8082}"
TIMEOUT_SECS="${NOETL_SUB_TIMEOUT_SECS:-180}"
COUNT="${NOETL_SUB_COUNT:-5}"
PROJECT="noetl-e2e"
EMULATOR_PORT="${NOETL_PUBSUB_PORT:-8085}"

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
FIXTURE_PATH="$REPO_ROOT/fixtures/playbooks/subscription/subscription_pubsub_drain.yaml"
CRED_FILE="$REPO_ROOT/fixtures/credentials/pubsub_e2e.json.example"
PLAYBOOK_PATH="tests/fixtures/subscription_pubsub_drain"

# Unique per-run topic + subscription so re-runs drain exactly N.
SUFFIX="$(date +%s)$$"
TOPIC="projects/$PROJECT/topics/e2e-$SUFFIX"
SUBSCRIPTION="projects/$PROJECT/subscriptions/e2e-$SUFFIX"

echo "kind-val: context=$KIND_CONTEXT namespace=$NAMESPACE pubsub-ns=$PUBSUB_NS"
echo "kind-val: server=$NOETL_SERVER_URL fixture=$FIXTURE_PATH"
echo "kind-val: count=$COUNT subscription=$SUBSCRIPTION"

# ----------------------------------------------------------------------
# Preflight.
# ----------------------------------------------------------------------
for cmd in kubectl noetl curl python3 base64; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "kind-val: required command not in PATH: $cmd" >&2; exit 2; }
done
[[ -f "$FIXTURE_PATH" ]] || { echo "kind-val: fixture not found: $FIXTURE_PATH" >&2; exit 2; }
[[ -f "$CRED_FILE" ]] || { echo "kind-val: credential not found: $CRED_FILE" >&2; exit 2; }

KCTX=(kubectl --context "$KIND_CONTEXT")
"${KCTX[@]}" -n "$NAMESPACE" get deployment "$NOETL_SERVER_DEPLOY" >/dev/null 2>&1 || {
  echo "kind-val: $NOETL_SERVER_DEPLOY not found in $NAMESPACE." >&2; exit 2; }
"${KCTX[@]}" -n "$PUBSUB_NS" rollout status deploy/pubsub-emulator --timeout=120s >/dev/null 2>&1 || {
  echo "kind-val: pubsub-emulator not ready in $PUBSUB_NS (apply ops ci/manifests/pubsub-emulator/)." >&2; exit 2; }
curl -fsS "$NOETL_SERVER_URL/api/health" >/dev/null 2>&1 || {
  echo "kind-val: server not reachable at $NOETL_SERVER_URL — start a port-forward first." >&2; exit 2; }

# ----------------------------------------------------------------------
# Port-forward the emulator + set up the topic / subscription / messages.
# ----------------------------------------------------------------------
PF_PID=""
cleanup() { [[ -n "$PF_PID" ]] && kill "$PF_PID" >/dev/null 2>&1 || true; }
trap cleanup EXIT

"${KCTX[@]}" -n "$PUBSUB_NS" port-forward svc/pubsub-emulator "$EMULATOR_PORT:8085" >/tmp/pf_pubsub_e2e.log 2>&1 &
PF_PID=$!
BASE="http://localhost:$EMULATOR_PORT"
for _ in $(seq 1 20); do curl -fsS "$BASE/v1/projects/$PROJECT/topics" >/dev/null 2>&1 && break; sleep 0.5; done

echo "kind-val: create topic + subscription on emulator"
curl -fsS -X PUT "$BASE/v1/$TOPIC" >/dev/null
curl -fsS -X PUT "$BASE/v1/$SUBSCRIPTION" -H 'Content-Type: application/json' \
  -d "{\"topic\":\"$TOPIC\",\"ackDeadlineSeconds\":30}" >/dev/null

echo "kind-val: publish $COUNT messages"
MSGS="$(python3 -c "
import base64, json, sys
n = int('$COUNT')
msgs = [{'data': base64.b64encode(json.dumps({'order_id': i}).encode()).decode(),
         'attributes': {'x-seq': str(i)}} for i in range(n)]
print(json.dumps({'messages': msgs}))
")"
curl -fsS -X POST "$BASE/v1/$TOPIC:publish" -H 'Content-Type: application/json' -d "$MSGS" >/dev/null

# ----------------------------------------------------------------------
# Register credential + playbook, then execute (override the subscription).
# ----------------------------------------------------------------------
echo
echo "================================================================"
echo "kind-val: register + execute subscription_pubsub_drain"
echo "================================================================"
noetl register credential -f "$CRED_FILE"
noetl register playbook --file "$FIXTURE_PATH"

EXECUTION_ID="$(noetl exec "$PLAYBOOK_PATH" --runtime distributed \
  --set "subscription=$SUBSCRIPTION" --json \
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
if src != "pubsub": print(f"WRONG source={src}")
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
  echo "kind-val: PASS — Pub/Sub subscription drain green"
  echo "  - final_status=COMPLETED"
  echo "  - drain: source=pubsub count=$COUNT acked=true"
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

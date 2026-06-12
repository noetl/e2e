#!/usr/bin/env bash
# kind_validate_subscription_scale.sh — noetl/ai-meta#90 Phase 7
# Scale-hardening (batch dispatch · opt-in dedup window · per-subscription
# rate limits) live E2E on the local kind cluster.
#
# Three independent sub-tests, each re-points the singleton subscription
# runtime at a dedicated kind: Subscription and drives it against the
# in-cluster NATS broker:
#
#   batch     — publish N messages; the runtime drains them and dispatches
#               via POST /api/execute/batch (server logs "execute batch
#               complete").  Assert: N child executions, all COMPLETED on
#               the subscription pool, per-message traceability intact.
#   dedup     — publish a message and a DUPLICATE (same x-idempotency-key)
#               with dedup on.  Assert: exactly ONE execution + a
#               subscription.message.deduplicated event.  Then a control
#               with two DISTINCT keys → two executions (dedup doesn't
#               over-collapse).
#   ratelimit — publish a burst of N with max_dispatch_per_sec=2.  Assert:
#               a subscription.rate_limited event fires AND all N messages
#               eventually become executions (none lost — they waited in
#               the NATS stream, the durable buffer).
#
# Assumes the Phase-7 server + worker images are built + loaded + rolled
# (build with podman, `kind load docker-image`, kubectl rollout).
#
# Usage:
#   ./scripts/kind_validate_subscription_scale.sh                 # all three
#   ./scripts/kind_validate_subscription_scale.sh --only batch
#   ./scripts/kind_validate_subscription_scale.sh --only dedup
#   ./scripts/kind_validate_subscription_scale.sh --only ratelimit
#
# Exits 0 on PASS; 1 on any failed assertion.  KEEP_RESOURCES=1 leaves the
# runtime + streams in place.

set -euo pipefail

KIND_CONTEXT="${NOETL_KIND_CONTEXT:-kind-noetl}"
NS="${NOETL_K8S_NAMESPACE:-noetl}"
PG_NS="${NOETL_PG_NS:-postgres}"
NATS_NS="${NOETL_NATS_NS:-nats}"
SERVER_URL="${NOETL_SERVER_URL:-http://localhost:8082}"
NATS_LOCAL="${NOETL_NATS_LOCAL:-nats://localhost:4222}"
NATS_PORT="${NOETL_NATS_PORT:-4222}"
TIMEOUT_SECS="${NOETL_SUB_TIMEOUT_SECS:-180}"
ONLY="${NOETL_SUB_ONLY:-all}"
DEFAULT_PB="tests/fixtures/sub_ingest_default"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --context) KIND_CONTEXT="$2"; shift 2 ;;
    --only)    ONLY="$2"; shift 2 ;;
    --timeout) TIMEOUT_SECS="$2"; shift 2 ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed -n '/^#/p'; exit 0 ;;
    *) echo "kind-val: unknown argument: $1" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FIX="$REPO_ROOT/fixtures/subscription"
OPS_MANIFESTS="${NOETL_OPS_MANIFESTS:-$REPO_ROOT/../ops/ci/manifests}"
RUNTIME_MANIFEST="$OPS_MANIFESTS/noetl/subscription-runtime-deployment.yaml"
POOL_MANIFEST="$OPS_MANIFESTS/noetl/worker-rust-subscription-pool-deployment.yaml"

KCTX=(kubectl --context "$KIND_CONTEXT")
PGPOD="$("${KCTX[@]}" -n "$PG_NS" get pod -o name | head -1)"
psql_q() { "${KCTX[@]}" -n "$PG_NS" exec "$PGPOD" -- env PGPASSWORD=noetl psql -U noetl -d noetl -tAc "$1"; }
NATS_CLI=(nats --server "$NATS_LOCAL" --user noetl --password noetl)

FAIL=0
assert_eq() { if [[ "$2" == "$3" ]]; then echo "  PASS: $1 ($2 == $3)"; else echo "  FAIL: $1 ($2 != $3)"; FAIL=1; fi; }
assert_ge() { if [[ "$2" -ge "$3" ]]; then echo "  PASS: $1 ($2 >= $3)"; else echo "  FAIL: $1 ($2 < $3)"; FAIL=1; fi; }

# ----------------------------------------------------------------------
# Preflight + port-forwards.
# ----------------------------------------------------------------------
for cmd in kubectl nats curl python3; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "kind-val: missing command: $cmd" >&2; exit 2; }
done

PF_PIDS=()
cleanup() {
  for pid in "${PF_PIDS[@]:-}"; do kill "$pid" >/dev/null 2>&1 || true; done
  if [[ "${KEEP_RESOURCES:-0}" != "1" ]]; then
    "${KCTX[@]}" -n "$NS" delete -f "$RUNTIME_MANIFEST" --ignore-not-found >/dev/null 2>&1 || true
    for s in BATCH_ORDERS DEDUP_CRITICAL RL_FIREHOSE; do "${NATS_CLI[@]}" stream rm "$s" -f >/dev/null 2>&1 || true; done
  fi
}
trap cleanup EXIT

"${KCTX[@]}" -n "$NS" port-forward svc/noetl 8082:8082 >/tmp/pf_server_scale.log 2>&1 & PF_PIDS+=($!)
"${KCTX[@]}" -n "$NATS_NS" port-forward svc/nats "$NATS_PORT:4222" >/tmp/pf_nats_scale.log 2>&1 & PF_PIDS+=($!)
sleep 4
curl -fsS "$SERVER_URL/api/health" >/dev/null 2>&1 || { echo "kind-val: server not reachable at $SERVER_URL" >&2; exit 2; }

register_catalog() {
  local file="$1" content
  content="$(python3 -c "import json,sys; print(json.dumps(open(sys.argv[1]).read()))" "$file")"
  curl -fsS -X POST "$SERVER_URL/api/catalog/register" -H 'Content-Type: application/json' \
    -d "{\"content\": $content}" >/dev/null
}

echo "kind-val: registering credential + target playbook"
curl -fsS -X POST "$SERVER_URL/api/credentials" -H 'Content-Type: application/json' \
  -d "$(cat "$REPO_ROOT/fixtures/credentials/nats_e2e.json.example")" >/dev/null 2>&1 || true
register_catalog "$FIX/sub_ingest_default.yaml"

# Deploy the dedicated execution pool once (shared by all sub-tests).
"${KCTX[@]}" -n "$NS" apply -f "$POOL_MANIFEST" >/dev/null
"${KCTX[@]}" -n "$NS" rollout status deploy/noetl-worker-rust-subscription-pool --timeout=120s >/dev/null

# Optional image override for local validation of an unreleased build (e.g.
# RUNTIME_IMAGE=localhost/noetl-worker:phase7).  Defaults to the manifest image.
RUNTIME_IMAGE="${RUNTIME_IMAGE:-}"

# Re-point + restart the singleton runtime at a subscription path, wait ACTIVE.
deploy_runtime_for() {
  local sub_path="$1" sid=""
  "${KCTX[@]}" -n "$NS" delete -f "$RUNTIME_MANIFEST" --ignore-not-found >/dev/null 2>&1 || true
  "${KCTX[@]}" -n "$NS" wait --for=delete pod -l app=noetl-subscription-runtime --timeout=60s >/dev/null 2>&1 || true
  local rendered
  rendered="$(sed "s#value: subscriptions/iot_sensor_stream#value: $sub_path#" "$RUNTIME_MANIFEST")"
  if [[ -n "$RUNTIME_IMAGE" ]]; then
    rendered="$(echo "$rendered" | sed "s#image: localhost/noetl-worker:dev#image: $RUNTIME_IMAGE#")"
  fi
  echo "$rendered" | "${KCTX[@]}" -n "$NS" apply -f - >/dev/null
  "${KCTX[@]}" -n "$NS" rollout status deploy/noetl-subscription-runtime --timeout=120s >/dev/null
  for _ in $(seq 1 30); do
    sid="$(psql_q "SELECT execution_id FROM noetl.event WHERE node_name='$sub_path' AND event_type='subscription.activated' ORDER BY event_id DESC LIMIT 1" | tr -d '[:space:]')"
    [[ -n "$sid" ]] && break
    sleep 3
  done
  echo "$sid"
}

stop_runtime() { "${KCTX[@]}" -n "$NS" scale deploy/noetl-subscription-runtime --replicas=0 >/dev/null 2>&1 || true; sleep 4; }

wait_children_completed() {
  local sid="$1" want="$2" deadline completed=0
  deadline=$(( $(date +%s) + TIMEOUT_SECS ))
  local kids="SELECT DISTINCT execution_id FROM noetl.event WHERE parent_execution_id=$sid AND event_type='playbook_started'"
  while (( $(date +%s) < deadline )); do
    completed="$(psql_q "SELECT count(DISTINCT execution_id) FROM noetl.event WHERE execution_id IN ($kids) AND event_type='playbook.completed'" | tr -d '[:space:]')"
    [[ "$completed" -ge "$want" ]] && break
    sleep 4
  done
  echo "$completed"
}

# ======================================================================
# Test: batch dispatch
# ======================================================================
test_batch() {
  echo; echo "=== TEST: batch dispatch ==="
  local SUB="subscriptions/batch_orders_stream" STREAM="BATCH_ORDERS" CONSUMER="batch-drain"
  local SUBJECT="batch.orders.new" COUNT="${NOETL_BATCH_COUNT:-12}"
  register_catalog "$FIX/batch_orders_stream.subscription.yaml"
  "${NATS_CLI[@]}" stream rm "$STREAM" -f >/dev/null 2>&1 || true
  "${NATS_CLI[@]}" stream add "$STREAM" --subjects "batch.orders.>" --storage file --retention limits \
    --discard old --max-msgs=-1 --max-bytes=-1 --max-age=1h --dupe-window=2m --replicas 1 --defaults >/dev/null
  "${NATS_CLI[@]}" consumer add "$STREAM" "$CONSUMER" --pull --deliver all --ack explicit \
    --max-deliver=-1 --wait=5s --replay instant --filter "$SUBJECT" --defaults >/dev/null

  echo "kind-val: publishing $COUNT messages to $STREAM (pre-loading the backlog)"
  for i in $(seq 1 "$COUNT"); do
    "${NATS_CLI[@]}" pub "$SUBJECT" "{\"order_id\":$i,\"amount\":$((RANDOM%500))}" \
      --header "traceparent:00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01" \
      --header "x-idempotency-key:batch-$i" >/dev/null
  done

  local SID; SID="$(deploy_runtime_for "$SUB")"
  [[ -n "$SID" ]] || { echo "  FAIL: batch subscription never activated"; FAIL=1; return; }
  echo "kind-val: subscription_id=$SID ACTIVE"

  local completed; completed="$(wait_children_completed "$SID" "$COUNT")"
  local children pooled traced
  children="$(psql_q "SELECT count(DISTINCT execution_id) FROM noetl.event WHERE parent_execution_id=$SID AND event_type='playbook_started'" | tr -d '[:space:]')"
  pooled="$(psql_q "SELECT count(DISTINCT execution_id) FROM noetl.event WHERE parent_execution_id=$SID AND event_type='playbook_started' AND meta->>'execution_pool'='subscription'" | tr -d '[:space:]')"
  traced="$(psql_q "SELECT count(DISTINCT execution_id) FROM noetl.event WHERE parent_execution_id=$SID AND event_type='playbook_started' AND meta->'trace'->>'traceparent' IS NOT NULL" | tr -d '[:space:]')"
  # The server runs at debug verbosity, so the batch-handler line scrolls
  # out of a small tail — read a deep tail.  The runtime "batch dispatch
  # complete" line is the authoritative proof the runtime used the batch path.
  local batchlog; batchlog="$("${KCTX[@]}" -n "$NS" logs deploy/noetl-server-rust --tail=8000 2>/dev/null | grep -c 'execute batch complete' || true)"
  local rtbatch; rtbatch="$("${KCTX[@]}" -n "$NS" logs deploy/noetl-subscription-runtime --tail=400 2>/dev/null | grep -c 'batch dispatch complete' || true)"

  echo "kind-val: children=$children completed=$completed pooled=$pooled traced=$traced server_batch_calls=$batchlog runtime_batches=$rtbatch"
  assert_eq "one child execution per message"       "$children"  "$COUNT"
  assert_ge "all children COMPLETED"                 "$completed" "$COUNT"
  assert_eq "children on the subscription pool"      "$pooled"    "$COUNT"
  assert_eq "per-message traceparent preserved"      "$traced"    "$COUNT"
  assert_ge "server handled >=1 batch call"          "$batchlog"  1
  assert_ge "runtime issued >=1 batch dispatch"      "$rtbatch"   1
  stop_runtime
}

# ======================================================================
# Test: opt-in dedup window
# ======================================================================
test_dedup() {
  echo; echo "=== TEST: opt-in dedup window ==="
  local SUB="subscriptions/dedup_critical_stream" STREAM="DEDUP_CRITICAL" CONSUMER="dedup-drain"
  local SUBJECT="dedup.critical.evt"
  register_catalog "$FIX/dedup_critical_stream.subscription.yaml"
  "${NATS_CLI[@]}" stream rm "$STREAM" -f >/dev/null 2>&1 || true
  # dupe-window 0 so NATS itself doesn't dedup our identical-key publishes —
  # we are testing the SERVER dedup window, not NATS message dedup.
  "${NATS_CLI[@]}" stream add "$STREAM" --subjects "dedup.critical.>" --storage file --retention limits \
    --discard old --max-msgs=-1 --max-bytes=-1 --max-age=1h --dupe-window=0s --replicas 1 --defaults >/dev/null
  "${NATS_CLI[@]}" consumer add "$STREAM" "$CONSUMER" --pull --deliver all --ack explicit \
    --max-deliver=-1 --wait=5s --replay instant --filter "$SUBJECT" --defaults >/dev/null

  local SID; SID="$(deploy_runtime_for "$SUB")"
  [[ -n "$SID" ]] || { echo "  FAIL: dedup subscription never activated"; FAIL=1; return; }
  echo "kind-val: subscription_id=$SID ACTIVE"

  # Publish the SAME idempotency key twice (a replayed/duplicated delivery)
  # plus one DISTINCT key — expect 2 executions total (the dup collapses).
  echo "kind-val: publishing dup(key=K1) x2 + distinct(key=K2) x1"
  for n in 1 2; do
    "${NATS_CLI[@]}" pub "$SUBJECT" "{\"evt\":\"dup\",\"n\":$n}" --header "x-idempotency-key:K1" >/dev/null
    sleep 1
  done
  "${NATS_CLI[@]}" pub "$SUBJECT" "{\"evt\":\"distinct\"}" --header "x-idempotency-key:K2" >/dev/null

  # Expect 2 children (K1 once + K2 once); wait for both to complete.
  local completed; completed="$(wait_children_completed "$SID" 2)"
  local children dedup_events
  children="$(psql_q "SELECT count(DISTINCT execution_id) FROM noetl.event WHERE parent_execution_id=$SID AND event_type='playbook_started'" | tr -d '[:space:]')"
  dedup_events="$(psql_q "SELECT count(*) FROM noetl.event WHERE execution_id=$SID AND event_type='subscription.message.deduplicated'" | tr -d '[:space:]')"

  echo "kind-val: children=$children completed=$completed deduplicated_events=$dedup_events"
  assert_eq "duplicate collapsed → exactly 2 executions (not 3)" "$children" "2"
  assert_ge "both distinct executions COMPLETED"                 "$completed" "2"
  assert_ge "one subscription.message.deduplicated event logged" "$dedup_events" "1"
  stop_runtime
}

# ======================================================================
# Test: per-subscription rate limit / backpressure (no loss)
# ======================================================================
test_ratelimit() {
  echo; echo "=== TEST: per-subscription rate limit / backpressure ==="
  local SUB="subscriptions/ratelimit_firehose_stream" STREAM="RL_FIREHOSE" CONSUMER="rl-drain"
  local SUBJECT="rl.firehose.evt" COUNT="${NOETL_RL_COUNT:-10}"
  register_catalog "$FIX/ratelimit_firehose_stream.subscription.yaml"
  "${NATS_CLI[@]}" stream rm "$STREAM" -f >/dev/null 2>&1 || true
  "${NATS_CLI[@]}" stream add "$STREAM" --subjects "rl.firehose.>" --storage file --retention limits \
    --discard old --max-msgs=-1 --max-bytes=-1 --max-age=1h --dupe-window=2m --replicas 1 --defaults >/dev/null
  "${NATS_CLI[@]}" consumer add "$STREAM" "$CONSUMER" --pull --deliver all --ack explicit \
    --max-deliver=-1 --wait=5s --replay instant --filter "$SUBJECT" --defaults >/dev/null

  # Pre-load the whole burst so the runtime sees a full backlog at once;
  # at 2/sec the limiter must throttle fetching, not drop.
  echo "kind-val: pre-loading a burst of $COUNT to $STREAM"
  for i in $(seq 1 "$COUNT"); do
    "${NATS_CLI[@]}" pub "$SUBJECT" "{\"evt\":$i}" --header "x-idempotency-key:rl-$i" >/dev/null
  done

  local SID; SID="$(deploy_runtime_for "$SUB")"
  [[ -n "$SID" ]] || { echo "  FAIL: ratelimit subscription never activated"; FAIL=1; return; }
  echo "kind-val: subscription_id=$SID ACTIVE"

  # No loss: every message must eventually become an execution (they wait in
  # NATS while the limiter throttles fetching).
  local completed; completed="$(wait_children_completed "$SID" "$COUNT")"
  local children rl_events
  children="$(psql_q "SELECT count(DISTINCT execution_id) FROM noetl.event WHERE parent_execution_id=$SID AND event_type='playbook_started'" | tr -d '[:space:]')"
  rl_events="$(psql_q "SELECT count(*) FROM noetl.event WHERE execution_id=$SID AND event_type='subscription.rate_limited'" | tr -d '[:space:]')"

  echo "kind-val: children=$children completed=$completed rate_limited_events=$rl_events"
  assert_ge "rate limit engaged (>=1 rate_limited event)"  "$rl_events" 1
  assert_eq "no loss — every message became an execution"  "$children"  "$COUNT"
  assert_ge "all rate-limited executions COMPLETED"        "$completed" "$COUNT"
  stop_runtime
}

# ----------------------------------------------------------------------
# Run.
# ----------------------------------------------------------------------
case "$ONLY" in
  batch)     test_batch ;;
  dedup)     test_dedup ;;
  ratelimit) test_ratelimit ;;
  all)       test_batch; test_dedup; test_ratelimit ;;
  *) echo "kind-val: unknown --only '$ONLY' (batch|dedup|ratelimit|all)" >&2; exit 2 ;;
esac

echo
if [[ "$FAIL" -eq 0 ]]; then
  echo "kind-val: PASS — Phase 7 scale hardening (batch · dedup · rate-limit) validated"
  exit 0
else
  echo "kind-val: FAIL — dumping runtime + server logs"
  "${KCTX[@]}" -n "$NS" logs deploy/noetl-subscription-runtime --tail=60 2>/dev/null || true
  "${KCTX[@]}" -n "$NS" logs deploy/noetl-server-rust --tail=40 2>/dev/null || true
  exit 1
fi

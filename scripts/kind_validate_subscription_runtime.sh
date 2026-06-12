#!/usr/bin/env bash
# kind_validate_subscription_runtime.sh — noetl/ai-meta#90 Phase 2
# Continuous subscription runtime (Mode B) + header-directive engine
# live E2E on the local kind cluster.
#
# Proves, end to end against the in-cluster NATS broker:
#   1. The continuous runtime (WORKER_MODE=subscription) activates a
#      kind: Subscription and turns EACH received message into one
#      execution.
#   2. Those executions land on the DEDICATED pool segment
#      (noetl.commands.subscription.<eid>), drained by
#      noetl-worker-rust-subscription-pool, and reach COMPLETED — isolated
#      from the shared pool.
#   3. A header directive `x-noetl-route` REDIRECTS a message to a
#      different (allowlisted) target playbook (RFC §7.3).
#   4. A W3C `traceparent` header propagates into the child execution's
#      event meta.trace (RFC §7.4).
#   5. The lifecycle is event-logged: subscription.registered/activated,
#      and pause/resume transitions reconcile.
#
# Assumes the server (noetl-server-rust v3.2.0+), the subscription pool,
# and the runtime images are built + loaded + rolled (build with podman,
# `kind load docker-image`, kubectl rollout).  See the PR / wiki for the
# build recipe.
#
# Usage:
#   ./scripts/kind_validate_subscription_runtime.sh
#   ./scripts/kind_validate_subscription_runtime.sh --count 6 --redirect 2
#
# Exits 0 on PASS; 1 on any failed assertion (dumps runtime + pool logs).
# Set KEEP_RESOURCES=1 to leave the deployments + NATS stream in place.

set -euo pipefail

KIND_CONTEXT="${NOETL_KIND_CONTEXT:-kind-noetl}"
NS="${NOETL_K8S_NAMESPACE:-noetl}"
PG_NS="${NOETL_PG_NS:-postgres}"
NATS_NS="${NOETL_NATS_NS:-nats}"
SERVER_URL="${NOETL_SERVER_URL:-http://localhost:8082}"
NATS_LOCAL="${NOETL_NATS_LOCAL:-nats://localhost:4222}"
NATS_PORT="${NOETL_NATS_PORT:-4222}"
COUNT="${NOETL_SUB_COUNT:-6}"
REDIRECT="${NOETL_SUB_REDIRECT:-2}"
TIMEOUT_SECS="${NOETL_SUB_TIMEOUT_SECS:-150}"
SUB_PATH="subscriptions/iot_sensor_stream"
DEFAULT_PB="tests/fixtures/sub_ingest_default"
PRIORITY_PB="tests/fixtures/sub_ingest_priority"
STREAM="IOT_SENSORS"
CONSUMER="iot-drain"
SUBJECT="iot.sensors.readings"
TRACEPARENT="00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --context)  KIND_CONTEXT="$2"; shift 2 ;;
    --count)    COUNT="$2"; shift 2 ;;
    --redirect) REDIRECT="$2"; shift 2 ;;
    --timeout)  TIMEOUT_SECS="$2"; shift 2 ;;
    -h|--help)  sed -n '2,/^set -euo/p' "$0" | sed -n '/^#/p'; exit 0 ;;
    *) echo "kind-val: unknown argument: $1" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FIX="$REPO_ROOT/fixtures/subscription"
OPS_MANIFESTS="${NOETL_OPS_MANIFESTS:-$REPO_ROOT/../ops/ci/manifests}"

KCTX=(kubectl --context "$KIND_CONTEXT")
PGPOD="$("${KCTX[@]}" -n "$PG_NS" get pod -o name | head -1)"
psql_q() { "${KCTX[@]}" -n "$PG_NS" exec "$PGPOD" -- env PGPASSWORD=noetl psql -U noetl -d noetl -tAc "$1"; }
NATS_CLI=(nats --server "$NATS_LOCAL" --user noetl --password noetl)

echo "kind-val: context=$KIND_CONTEXT ns=$NS count=$COUNT redirect=$REDIRECT"

# ----------------------------------------------------------------------
# Preflight.
# ----------------------------------------------------------------------
for cmd in kubectl nats curl python3; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "kind-val: missing command: $cmd" >&2; exit 2; }
done
for f in "$FIX/iot_sensor_stream.subscription.yaml" "$FIX/sub_ingest_default.yaml" "$FIX/sub_ingest_priority.yaml"; do
  [[ -f "$f" ]] || { echo "kind-val: fixture not found: $f" >&2; exit 2; }
done

# ----------------------------------------------------------------------
# Port-forwards (server + NATS).
# ----------------------------------------------------------------------
PF_PIDS=()
cleanup() {
  for pid in "${PF_PIDS[@]:-}"; do kill "$pid" >/dev/null 2>&1 || true; done
  if [[ "${KEEP_RESOURCES:-0}" != "1" ]]; then
    "${KCTX[@]}" -n "$NS" delete -f "$OPS_MANIFESTS/noetl/subscription-runtime-deployment.yaml" --ignore-not-found >/dev/null 2>&1 || true
    "${KCTX[@]}" -n "$NS" delete -f "$OPS_MANIFESTS/noetl/worker-rust-subscription-pool-deployment.yaml" --ignore-not-found >/dev/null 2>&1 || true
    "${NATS_CLI[@]}" stream rm "$STREAM" -f >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

"${KCTX[@]}" -n "$NS" port-forward svc/noetl 8082:8082 >/tmp/pf_server_sub.log 2>&1 & PF_PIDS+=($!)
"${KCTX[@]}" -n "$NATS_NS" port-forward svc/nats "$NATS_PORT:4222" >/tmp/pf_nats_sub.log 2>&1 & PF_PIDS+=($!)
sleep 4
curl -fsS "$SERVER_URL/api/health" >/dev/null 2>&1 || { echo "kind-val: server not reachable at $SERVER_URL" >&2; exit 2; }
"${NATS_CLI[@]}" server check stream --stream NOETL_COMMANDS >/dev/null 2>&1 || true

# ----------------------------------------------------------------------
# Register credential + playbooks + the kind: Subscription.
# ----------------------------------------------------------------------
echo "kind-val: registering credential + catalog entries"
curl -fsS -X POST "$SERVER_URL/api/credentials" -H 'Content-Type: application/json' \
  -d "$(cat "$REPO_ROOT/fixtures/credentials/nats_e2e.json.example")" >/dev/null 2>&1 || \
  echo "kind-val: credential register returned non-2xx (may already exist) — continuing"

register_catalog() {
  local file="$1"
  local content
  content="$(python3 -c "import json,sys; print(json.dumps(open(sys.argv[1]).read()))" "$file")"
  curl -fsS -X POST "$SERVER_URL/api/catalog/register" -H 'Content-Type: application/json' \
    -d "{\"content\": $content}" >/dev/null
}
register_catalog "$FIX/sub_ingest_default.yaml"
register_catalog "$FIX/sub_ingest_priority.yaml"
register_catalog "$FIX/iot_sensor_stream.subscription.yaml"

# ----------------------------------------------------------------------
# Create the NATS source stream + durable pull consumer.
# ----------------------------------------------------------------------
echo "kind-val: creating NATS stream $STREAM + consumer $CONSUMER"
"${NATS_CLI[@]}" stream rm "$STREAM" -f >/dev/null 2>&1 || true
"${NATS_CLI[@]}" stream add "$STREAM" --subjects "iot.sensors.>" \
  --storage file --retention limits --discard old --max-msgs=-1 --max-bytes=-1 \
  --max-age=1h --dupe-window=2m --replicas 1 --defaults >/dev/null
"${NATS_CLI[@]}" consumer add "$STREAM" "$CONSUMER" --pull --deliver all --ack explicit \
  --max-deliver=-1 --wait=5s --replay instant --filter "$SUBJECT" --defaults >/dev/null

# ----------------------------------------------------------------------
# Deploy the dedicated execution pool + the continuous runtime.
# ----------------------------------------------------------------------
echo "kind-val: deploying subscription pool + runtime"
"${KCTX[@]}" -n "$NS" apply -f "$OPS_MANIFESTS/noetl/worker-rust-subscription-pool-deployment.yaml" >/dev/null
# Render the runtime manifest with the target subscription path (avoid a
# post-apply `set env` / `rollout restart` that would churn the singleton
# runtime pod and race its SIGTERM drain — see the Recreate strategy note).
sed "s#value: subscriptions/iot_sensor_stream#value: $SUB_PATH#" \
  "$OPS_MANIFESTS/noetl/subscription-runtime-deployment.yaml" | "${KCTX[@]}" -n "$NS" apply -f - >/dev/null
"${KCTX[@]}" -n "$NS" rollout status deploy/noetl-worker-rust-subscription-pool --timeout=120s >/dev/null
"${KCTX[@]}" -n "$NS" rollout status deploy/noetl-subscription-runtime --timeout=120s >/dev/null

# ----------------------------------------------------------------------
# Wait for the runtime to register + activate the subscription.
# ----------------------------------------------------------------------
echo "kind-val: waiting for subscription ACTIVE"
SUB_ID=""
for _ in $(seq 1 30); do
  SUB_ID="$(psql_q "SELECT execution_id FROM noetl.event WHERE node_name='$SUB_PATH' AND event_type='subscription.activated' ORDER BY event_id DESC LIMIT 1" | tr -d '[:space:]')"
  [[ -n "$SUB_ID" ]] && break
  sleep 3
done
[[ -n "$SUB_ID" ]] || { echo "kind-val: FAIL — subscription never activated"; "${KCTX[@]}" -n "$NS" logs deploy/noetl-subscription-runtime --tail=50 || true; exit 1; }
echo "kind-val: subscription_id=$SUB_ID ACTIVE"

# ----------------------------------------------------------------------
# Publish N messages — REDIRECT of them carry x-noetl-route → priority,
# all carry a traceparent + an idempotency key.
# ----------------------------------------------------------------------
echo "kind-val: publishing $COUNT messages ($REDIRECT redirected)"
for i in $(seq 1 "$COUNT"); do
  body="{\"device_id\":\"dev-$i\",\"reading\":$((RANDOM%100))}"
  hdrs=(--header "traceparent:$TRACEPARENT" --header "x-idempotency-key:idem-$i" --header "content-type:application/json")
  if (( i <= REDIRECT )); then
    hdrs+=(--header "x-noetl-route:$PRIORITY_PB")
  fi
  "${NATS_CLI[@]}" pub "$SUBJECT" "$body" "${hdrs[@]}" >/dev/null
done

# ----------------------------------------------------------------------
# Wait for N child executions to COMPLETE, then assert.
# ----------------------------------------------------------------------
# Child executions are linked via playbook_started.parent_execution_id; their
# TERMINAL events (playbook.completed, emitted by the orchestrator) do NOT carry
# parent_execution_id, so completion is counted by joining on the child
# execution_ids.  The dedicated-pool routing is asserted on the playbook_started
# meta.execution_pool (the per-execution segment), which every command of the run
# then publishes to (noetl.commands.subscription.<eid>) — the subscription pool
# worker draining them to COMPLETED is the end-to-end proof.
KIDS_SQL="SELECT DISTINCT execution_id FROM noetl.event WHERE parent_execution_id=$SUB_ID AND event_type='playbook_started'"
echo "kind-val: waiting for $COUNT child executions to complete"
deadline=$(( $(date +%s) + TIMEOUT_SECS ))
completed=0
while (( $(date +%s) < deadline )); do
  completed="$(psql_q "SELECT count(DISTINCT execution_id) FROM noetl.event WHERE execution_id IN ($KIDS_SQL) AND event_type='playbook.completed'" | tr -d '[:space:]')"
  [[ "$completed" -ge "$COUNT" ]] && break
  sleep 4
done

children="$(psql_q "SELECT count(DISTINCT execution_id) FROM noetl.event WHERE parent_execution_id=$SUB_ID AND event_type='playbook_started'" | tr -d '[:space:]')"
redirected="$(psql_q "SELECT count(DISTINCT execution_id) FROM noetl.event WHERE parent_execution_id=$SUB_ID AND event_type='playbook_started' AND node_name='$PRIORITY_PB'" | tr -d '[:space:]')"
defaulted="$(psql_q "SELECT count(DISTINCT execution_id) FROM noetl.event WHERE parent_execution_id=$SUB_ID AND event_type='playbook_started' AND node_name='$DEFAULT_PB'" | tr -d '[:space:]')"
traced="$(psql_q "SELECT count(DISTINCT execution_id) FROM noetl.event WHERE parent_execution_id=$SUB_ID AND event_type='playbook_started' AND meta->'trace'->>'traceparent'='$TRACEPARENT'" | tr -d '[:space:]')"
pooled="$(psql_q "SELECT count(DISTINCT execution_id) FROM noetl.event WHERE parent_execution_id=$SUB_ID AND event_type='playbook_started' AND meta->>'execution_pool'='subscription'" | tr -d '[:space:]')"
directives="$(psql_q "SELECT count(*) FROM noetl.event WHERE execution_id IN ($KIDS_SQL) AND event_type='subscription.message.directives_applied'" | tr -d '[:space:]')"

echo "kind-val: children=$children completed=$completed redirected=$redirected defaulted=$defaulted traced=$traced pooled=$pooled directives=$directives"

FAIL=0
assert() { if [[ "$2" -ge "$3" ]]; then echo "  PASS: $1 ($2 >= $3)"; else echo "  FAIL: $1 ($2 < $3)"; FAIL=1; fi; }
assert "one child execution per message"            "$children"    "$COUNT"
assert "all children reached COMPLETED"             "$completed"   "$COUNT"
assert "children dispatched on subscription pool"   "$pooled"      "$COUNT"
assert "redirect directive routed to priority pb"   "$redirected"  "$REDIRECT"
assert "default messages ran the default pb"        "$defaulted"   "$(( COUNT - REDIRECT ))"
assert "W3C traceparent propagated into children"   "$traced"      "$COUNT"
assert "directives_applied audit events emitted"    "$directives"  "$REDIRECT"

# ----------------------------------------------------------------------
# Lifecycle: pause → resume, asserting the event trail.
# ----------------------------------------------------------------------
echo "kind-val: testing pause/resume lifecycle"
curl -s -o /dev/null -w "  pause:  HTTP %{http_code}\n"  -X POST "$SERVER_URL/api/subscriptions/$SUB_ID/pause"
sleep 2
curl -s -o /dev/null -w "  resume: HTTP %{http_code}\n" -X POST "$SERVER_URL/api/subscriptions/$SUB_ID/resume"
sleep 2
# Drain + deactivate fire when the runtime shuts down.  Kubernetes sends
# SIGTERM, so scale the runtime to 0 and assert the runtime drained +
# deactivated on the way out (proves SIGTERM-driven graceful shutdown).
echo "kind-val: scaling runtime to 0 (SIGTERM) to test drain/deactivate-on-shutdown"
"${KCTX[@]}" -n "$NS" scale deploy/noetl-subscription-runtime --replicas=0 >/dev/null
for _ in $(seq 1 20); do
  life="$(psql_q "SELECT string_agg(event_type, ',' ORDER BY event_id) FROM noetl.event WHERE execution_id=$SUB_ID AND event_type LIKE 'subscription.%'")"
  [[ "$life" == *"subscription.deactivated"* ]] && break
  sleep 3
done
echo "kind-val: lifecycle trail: $life"
for ev in subscription.registered subscription.activated subscription.paused subscription.resumed subscription.draining subscription.deactivated; do
  if [[ "$life" == *"$ev"* ]]; then echo "  PASS: lifecycle has $ev"; else echo "  FAIL: lifecycle missing $ev"; FAIL=1; fi
done

# ----------------------------------------------------------------------
# Verdict.
# ----------------------------------------------------------------------
if [[ "$FAIL" -eq 0 ]]; then
  echo "kind-val: PASS — continuous runtime + directives + trace + lifecycle validated"
  exit 0
else
  echo "kind-val: FAIL — dumping logs"
  "${KCTX[@]}" -n "$NS" logs deploy/noetl-subscription-runtime --tail=60 || true
  "${KCTX[@]}" -n "$NS" logs deploy/noetl-worker-rust-subscription-pool --tail=60 || true
  exit 1
fi

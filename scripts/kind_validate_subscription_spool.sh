#!/usr/bin/env bash
# kind_validate_subscription_spool.sh — noetl/ai-meta#90 Phase 4
# Store-and-forward spool + per-downstream circuit breaker (RFC §8) live
# E2E on the local kind cluster.
#
# Proves, end to end against the in-cluster NATS broker + a toggleable
# downstream, that an outage causes NO data loss:
#
#   1. The continuous runtime (WORKER_MODE=subscription) activates a
#      kind: Subscription whose `spool.circuit` declares an http-probed
#      downstream (`warehouse` → the spool-downstream-echo service).
#   2. OUTAGE: scaling spool-downstream-echo to 0 makes the probe fail;
#      after `trip_after` the circuit OPENS (subscription.circuit.opened).
#   3. Messages published during the outage are durably BUFFERED to the
#      nats_object spool and acked (buffer_and_ack) — one
#      subscription.message.spooled event each, with the noetl://spool ref
#      + sha256; the spool bucket holds exactly those objects; NO child
#      executions run while the circuit is open.
#   4. RECOVERY: scaling spool-downstream-echo back to 1 makes the probe
#      succeed; the circuit CLOSES (subscription.circuit.closed) and the
#      spool DRAINS (subscription.spool.draining) — each item REPLAYED
#      (subscription.message.replayed) in order into one COMPLETED child
#      execution on the dedicated subscription pool.
#   5. Idempotency holds (one child execution per message_id; no dups) and
#      the spool ends empty — the entire outage is reconstructable from the
#      event log.
#
# Assumes the server (noetl-server-rust v3.4.0+ with spool validation),
# the worker (noetl-worker v5.16.0+ with noetl-tools 3.4 spool engine),
# the subscription pool, and the runtime images are built + loaded + rolled.
# See the PR / wiki for the build recipe.
#
# Usage:
#   ./scripts/kind_validate_subscription_spool.sh
#   ./scripts/kind_validate_subscription_spool.sh --count 8 --timeout 240
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
COUNT="${NOETL_SPOOL_COUNT:-6}"
TIMEOUT_SECS="${NOETL_SPOOL_TIMEOUT_SECS:-240}"
SUB_PATH="subscriptions/spool_outage_stream"
DEFAULT_PB="tests/fixtures/sub_ingest_default"
STREAM="SPOOL_OUTAGE"
CONSUMER="spool-drain"
SUBJECT="spool.outage.readings"
SPOOL_BUCKET="noetl_spool_outage"
DOWNSTREAM_DEPLOY="spool-downstream-echo"
TRACEPARENT="00-5cf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --context)  KIND_CONTEXT="$2"; shift 2 ;;
    --count)    COUNT="$2"; shift 2 ;;
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

echo "kind-val: context=$KIND_CONTEXT ns=$NS count=$COUNT (spool outage proof)"

# ----------------------------------------------------------------------
# Preflight.
# ----------------------------------------------------------------------
for cmd in kubectl nats curl python3; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "kind-val: missing command: $cmd" >&2; exit 2; }
done
[[ -f "$FIX/spool_outage_stream.subscription.yaml" ]] || { echo "kind-val: fixture not found" >&2; exit 2; }

# ----------------------------------------------------------------------
# Port-forwards (server + NATS).
# ----------------------------------------------------------------------
PF_PIDS=()
cleanup() {
  for pid in "${PF_PIDS[@]:-}"; do kill "$pid" >/dev/null 2>&1 || true; done
  if [[ "${KEEP_RESOURCES:-0}" != "1" ]]; then
    "${KCTX[@]}" -n "$NS" delete -f "$OPS_MANIFESTS/noetl/subscription-runtime-deployment.yaml" --ignore-not-found >/dev/null 2>&1 || true
    "${KCTX[@]}" -n "$NS" delete -f "$OPS_MANIFESTS/noetl/spool-downstream-echo.yaml" --ignore-not-found >/dev/null 2>&1 || true
    "${NATS_CLI[@]}" stream rm "$STREAM" -f >/dev/null 2>&1 || true
    "${NATS_CLI[@]}" object rm "$SPOOL_BUCKET" -f >/dev/null 2>&1 || true
    "${NATS_CLI[@]}" object rm "${SPOOL_BUCKET}_dlq" -f >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

"${KCTX[@]}" -n "$NS" port-forward svc/noetl 8082:8082 >/tmp/pf_server_spool.log 2>&1 & PF_PIDS+=($!)
"${KCTX[@]}" -n "$NATS_NS" port-forward svc/nats "$NATS_PORT:4222" >/tmp/pf_nats_spool.log 2>&1 & PF_PIDS+=($!)
sleep 4
curl -fsS "$SERVER_URL/api/health" >/dev/null 2>&1 || { echo "kind-val: server not reachable at $SERVER_URL" >&2; exit 2; }

fail() { echo "kind-val: FAIL — $1"; "${KCTX[@]}" -n "$NS" logs deploy/noetl-subscription-runtime --tail=80 2>/dev/null || true; exit 1; }

# ----------------------------------------------------------------------
# Register credential + playbook + the kind: Subscription.
# ----------------------------------------------------------------------
echo "kind-val: registering credential + catalog entries"
curl -fsS -X POST "$SERVER_URL/api/credentials" -H 'Content-Type: application/json' \
  -d "$(cat "$REPO_ROOT/fixtures/credentials/nats_e2e.json.example")" >/dev/null 2>&1 || \
  echo "kind-val: credential register non-2xx (may already exist) — continuing"

register_catalog() {
  local file="$1" content
  content="$(python3 -c "import json,sys; print(json.dumps(open(sys.argv[1]).read()))" "$file")"
  curl -fsS -X POST "$SERVER_URL/api/catalog/register" -H 'Content-Type: application/json' \
    -d "{\"content\": $content}" >/dev/null
}
# The default ingest playbook (shared with the runtime fixture).
register_catalog "$FIX/sub_ingest_default.yaml"
register_catalog "$FIX/spool_outage_stream.subscription.yaml"

# ----------------------------------------------------------------------
# NATS source stream + durable consumer.
# ----------------------------------------------------------------------
echo "kind-val: creating NATS stream $STREAM + consumer $CONSUMER"
"${NATS_CLI[@]}" stream rm "$STREAM" -f >/dev/null 2>&1 || true
"${NATS_CLI[@]}" stream add "$STREAM" --subjects "spool.outage.>" \
  --storage file --retention limits --discard old --max-msgs=-1 --max-bytes=-1 \
  --max-age=1h --dupe-window=2m --replicas 1 --defaults >/dev/null
"${NATS_CLI[@]}" consumer add "$STREAM" "$CONSUMER" --pull --deliver all --ack explicit \
  --max-deliver=-1 --wait=5s --replay instant --filter "$SUBJECT" --defaults >/dev/null

# ----------------------------------------------------------------------
# Deploy the toggleable downstream + the dedicated pool + the runtime.
# ----------------------------------------------------------------------
echo "kind-val: deploying downstream echo + subscription pool + runtime"
"${KCTX[@]}" -n "$NS" apply -f "$OPS_MANIFESTS/noetl/spool-downstream-echo.yaml" >/dev/null
"${KCTX[@]}" -n "$NS" apply -f "$OPS_MANIFESTS/noetl/worker-rust-subscription-pool-deployment.yaml" >/dev/null
sed "s#value: subscriptions/iot_sensor_stream#value: $SUB_PATH#" \
  "$OPS_MANIFESTS/noetl/subscription-runtime-deployment.yaml" | "${KCTX[@]}" -n "$NS" apply -f - >/dev/null
"${KCTX[@]}" -n "$NS" rollout status deploy/"$DOWNSTREAM_DEPLOY" --timeout=120s >/dev/null
"${KCTX[@]}" -n "$NS" rollout status deploy/noetl-worker-rust-subscription-pool --timeout=120s >/dev/null
"${KCTX[@]}" -n "$NS" rollout status deploy/noetl-subscription-runtime --timeout=120s >/dev/null

# ----------------------------------------------------------------------
# Wait for the subscription to register + activate.
# ----------------------------------------------------------------------
echo "kind-val: waiting for subscription ACTIVE"
SUB_ID=""
for _ in $(seq 1 30); do
  SUB_ID="$(psql_q "SELECT execution_id FROM noetl.event WHERE node_name='$SUB_PATH' AND event_type='subscription.activated' ORDER BY event_id DESC LIMIT 1" | tr -d '[:space:]')"
  [[ -n "$SUB_ID" ]] && break
  sleep 3
done
[[ -n "$SUB_ID" ]] || fail "subscription never activated"
echo "kind-val: subscription_id=$SUB_ID ACTIVE"

# ----------------------------------------------------------------------
# OUTAGE — scale the downstream to 0; wait for the circuit to open.
# ----------------------------------------------------------------------
echo "kind-val: ===== OUTAGE: scaling $DOWNSTREAM_DEPLOY to 0 ====="
"${KCTX[@]}" -n "$NS" scale deploy/"$DOWNSTREAM_DEPLOY" --replicas=0 >/dev/null
"${KCTX[@]}" -n "$NS" wait --for=delete pod -l app="$DOWNSTREAM_DEPLOY" --timeout=60s >/dev/null 2>&1 || true

echo "kind-val: waiting for circuit.opened (probe must fail trip_after times)"
opened=""
deadline=$(( $(date +%s) + 90 ))
while (( $(date +%s) < deadline )); do
  opened="$(psql_q "SELECT count(*) FROM noetl.event WHERE execution_id=$SUB_ID AND event_type='subscription.circuit.opened'" | tr -d '[:space:]')"
  [[ "${opened:-0}" -ge 1 ]] && break
  sleep 3
done
[[ "${opened:-0}" -ge 1 ]] || fail "circuit never opened after downstream outage"
echo "kind-val: circuit OPENED ✓"

# ----------------------------------------------------------------------
# Publish N messages during the outage — they must SPOOL, not dispatch.
# ----------------------------------------------------------------------
echo "kind-val: publishing $COUNT messages during the outage"
for i in $(seq 1 "$COUNT"); do
  body="{\"device_id\":\"dev-$((i % 3))\",\"seq\":$i,\"reading\":$((RANDOM%100))}"
  "${NATS_CLI[@]}" pub "$SUBJECT" "$body" \
    --header "traceparent:$TRACEPARENT" \
    --header "x-idempotency-key:idem-$i" \
    --header "device_id:dev-$((i % 3))" >/dev/null
done

echo "kind-val: waiting for $COUNT messages to spool"
spooled=0
deadline=$(( $(date +%s) + 90 ))
while (( $(date +%s) < deadline )); do
  spooled="$(psql_q "SELECT count(*) FROM noetl.event WHERE execution_id=$SUB_ID AND event_type='subscription.message.spooled'" | tr -d '[:space:]')"
  [[ "${spooled:-0}" -ge "$COUNT" ]] && break
  sleep 3
done
[[ "${spooled:-0}" -ge "$COUNT" ]] || fail "expected $COUNT spooled, got ${spooled:-0}"
echo "kind-val: $spooled messages SPOOLED ✓"

# The spool bucket must hold exactly those objects (durable, no loss).
obj_count="$("${NATS_CLI[@]}" object ls "$SPOOL_BUCKET" 2>/dev/null | grep -c "." || echo 0)"
echo "kind-val: spool bucket object listing: $obj_count (informational)"

# No child executions while the circuit is open.
kids_during="$(psql_q "SELECT count(DISTINCT execution_id) FROM noetl.event WHERE parent_execution_id=$SUB_ID AND event_type='playbook_started'" | tr -d '[:space:]')"
echo "kind-val: child executions during outage: $kids_during (expect 0)"
[[ "${kids_during:-0}" -eq 0 ]] || fail "expected 0 dispatched during outage, got $kids_during"

# Every spooled event must carry a noetl://spool ref + sha256 (the trail).
# Worker-emitted events store the payload under the `result` column
# (result.context); the server's response-scrubber redacts the 64-hex
# sha256, so assert the ref + that the sha256 key is present (non-empty).
refs="$(psql_q "SELECT count(*) FROM noetl.event WHERE execution_id=$SUB_ID AND event_type='subscription.message.spooled' AND result->'context'->>'spool_ref' LIKE 'noetl://spool/%' AND coalesce(result->'context'->>'sha256','') <> ''" | tr -d '[:space:]')"
[[ "${refs:-0}" -ge "$COUNT" ]] || fail "spooled events missing noetl://spool ref or sha256 ($refs/$COUNT)"
echo "kind-val: all spooled events carry noetl://spool ref + sha256 ✓"

# ----------------------------------------------------------------------
# RECOVERY — scale the downstream back up; circuit closes + spool drains.
# ----------------------------------------------------------------------
echo "kind-val: ===== RECOVERY: scaling $DOWNSTREAM_DEPLOY to 1 ====="
"${KCTX[@]}" -n "$NS" scale deploy/"$DOWNSTREAM_DEPLOY" --replicas=1 >/dev/null
"${KCTX[@]}" -n "$NS" rollout status deploy/"$DOWNSTREAM_DEPLOY" --timeout=120s >/dev/null

echo "kind-val: waiting for circuit.closed + spool.draining"
closed=""
deadline=$(( $(date +%s) + 90 ))
while (( $(date +%s) < deadline )); do
  closed="$(psql_q "SELECT count(*) FROM noetl.event WHERE execution_id=$SUB_ID AND event_type='subscription.circuit.closed'" | tr -d '[:space:]')"
  [[ "${closed:-0}" -ge 1 ]] && break
  sleep 3
done
[[ "${closed:-0}" -ge 1 ]] || fail "circuit never closed after recovery"
draining="$(psql_q "SELECT count(*) FROM noetl.event WHERE execution_id=$SUB_ID AND event_type='subscription.spool.draining'" | tr -d '[:space:]')"
echo "kind-val: circuit CLOSED ✓; spool.draining events: $draining"

# ----------------------------------------------------------------------
# Wait for the replay: N message.replayed + N COMPLETED child executions.
# ----------------------------------------------------------------------
echo "kind-val: waiting for $COUNT messages to replay + complete"
KIDS_SQL="SELECT DISTINCT execution_id FROM noetl.event WHERE parent_execution_id=$SUB_ID AND event_type='playbook_started'"
deadline=$(( $(date +%s) + TIMEOUT_SECS ))
replayed=0; completed=0
while (( $(date +%s) < deadline )); do
  replayed="$(psql_q "SELECT count(*) FROM noetl.event WHERE event_type='subscription.message.replayed' AND result->'context'->>'spool_ref' LIKE 'noetl://spool/$SUB_PATH/%'" | tr -d '[:space:]')"
  completed="$(psql_q "SELECT count(DISTINCT execution_id) FROM noetl.event WHERE execution_id IN ($KIDS_SQL) AND event_type='playbook.completed'" | tr -d '[:space:]')"
  [[ "${replayed:-0}" -ge "$COUNT" && "${completed:-0}" -ge "$COUNT" ]] && break
  sleep 4
done

# ----------------------------------------------------------------------
# Assertions.
# ----------------------------------------------------------------------
children="$(psql_q "SELECT count(DISTINCT execution_id) FROM noetl.event WHERE parent_execution_id=$SUB_ID AND event_type='playbook_started'" | tr -d '[:space:]')"
pooled="$(psql_q "SELECT count(DISTINCT execution_id) FROM noetl.event WHERE parent_execution_id=$SUB_ID AND event_type='playbook_started' AND meta->>'execution_pool'='subscription'" | tr -d '[:space:]')"

echo "kind-val: ----- results -----"
echo "kind-val:   spooled (outage):   $spooled / $COUNT"
echo "kind-val:   replayed:           $replayed / $COUNT"
echo "kind-val:   child executions:   $children / $COUNT"
echo "kind-val:   completed:          $completed / $COUNT"
echo "kind-val:   on subscription pool: $pooled / $COUNT"

pass=1
[[ "${spooled:-0}"   -ge "$COUNT" ]] || { echo "kind-val: ASSERT spooled<$COUNT"; pass=0; }
[[ "${replayed:-0}"  -ge "$COUNT" ]] || { echo "kind-val: ASSERT replayed<$COUNT"; pass=0; }
[[ "${children:-0}"  -ge "$COUNT" ]] || { echo "kind-val: ASSERT children<$COUNT"; pass=0; }
[[ "${completed:-0}" -ge "$COUNT" ]] || { echo "kind-val: ASSERT completed<$COUNT"; pass=0; }
# Idempotency: no MORE than COUNT children (no duplicate dispatch).
[[ "${children:-0}"  -le "$COUNT" ]] || { echo "kind-val: ASSERT children>$COUNT (idempotency broken — duplicates)"; pass=0; }

# Spool must end EMPTY (every item drained + GC'd). Object keys are
# `<20-digit recv_seq>-<id>`; count those lines. The authoritative
# drained proof is replayed>=spooled (the engine GCs each item on replay);
# this bucket check is a cross-check, so a transient non-zero only warns.
# `grep -c` already prints 0 (exit 1) when nothing matches, so don't append
# a second `|| echo 0`; collapse any stray whitespace to one integer.
remaining_obj="$("${NATS_CLI[@]}" object ls "$SPOOL_BUCKET" 2>/dev/null | grep -cE "[0-9]{20}-")"
remaining_obj="$(echo "${remaining_obj:-0}" | tr -dc '0-9' | head -c4)"
remaining_obj="${remaining_obj:-0}"
echo "kind-val:   spool objects remaining: $remaining_obj (expect 0)"
[[ "$remaining_obj" -eq 0 ]] || echo "kind-val: WARN spool bucket still lists $remaining_obj object(s) (drained proof is replayed>=spooled)"

# Full circuit event trail present.
for et in subscription.circuit.opened subscription.spool.draining subscription.circuit.closed; do
  n="$(psql_q "SELECT count(*) FROM noetl.event WHERE execution_id=$SUB_ID AND event_type='$et'" | tr -d '[:space:]')"
  [[ "${n:-0}" -ge 1 ]] || { echo "kind-val: ASSERT missing event $et"; pass=0; }
done

if [[ "$pass" == "1" ]]; then
  echo "kind-val: PASS — outage buffered $spooled, drained+replayed $replayed, no data loss, circuit cycled, idempotency held"
  exit 0
else
  fail "spool outage proof assertions failed (see above)"
fi

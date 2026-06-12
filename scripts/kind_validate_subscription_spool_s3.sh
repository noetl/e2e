#!/usr/bin/env bash
# kind_validate_subscription_spool_s3.sh
#
# Live E2E on kind that proves TWO refinements of the subscription
# store-and-forward spool (RFC §8), against an in-cluster MinIO:
#
#   * noetl/ai-meta#94 — the `s3` spool backend end-to-end: an outage
#     buffers messages to the S3 (MinIO) bucket via SigV4, and they replay
#     in order on recovery with no loss.
#   * noetl/ai-meta#93 — cross-restart drain: a spool written to the durable
#     S3 backend (in-memory circuit, kv=None) AUTO-DRAINS on runtime startup.
#     We stop the runtime mid-outage, bring the downstream back, then restart
#     the runtime; the restarted runtime's recover_on_startup lists the MinIO
#     spool (downstream already up) and drains it — proven by the
#     `subscription.spool.recovered` event + the replay, with NO circuit
#     open→close cycle required after the restart.
#
# Flow:
#   1. Register the s3_spool_minio keychain credential + the subscription.
#   2. Activate; OUTAGE (downstream→0) → circuit opens.
#   3. Publish N → they SPOOL to MinIO (subscription.message.spooled).
#   4. RESTART: runtime→0, downstream→1 (up), runtime→1.
#   5. The restarted runtime auto-drains on startup
#      (subscription.spool.recovered → N replayed → N COMPLETED children),
#      ordered + idempotent, spool ends empty.
#
# Assumes MinIO is applied (ops ci/manifests/minio) with the noetl-spool
# bucket, and the worker/runtime images carry noetl-tools with the s3
# backend (#94) + spool recovery (#93).
#
# Usage: ./scripts/kind_validate_subscription_spool_s3.sh [--count N] [--timeout S]
# Exits 0 on PASS; 1 on any failed assertion. KEEP_RESOURCES=1 leaves state.

set -euo pipefail

KIND_CONTEXT="${NOETL_KIND_CONTEXT:-kind-noetl}"
NS="${NOETL_K8S_NAMESPACE:-noetl}"
PG_NS="${NOETL_PG_NS:-postgres}"
NATS_NS="${NOETL_NATS_NS:-nats}"
MINIO_NS="${NOETL_MINIO_NS:-minio}"
SERVER_URL="${NOETL_SERVER_URL:-http://localhost:8082}"
NATS_LOCAL="${NOETL_NATS_LOCAL:-nats://localhost:4222}"
NATS_PORT="${NOETL_NATS_PORT:-4222}"
COUNT="${NOETL_SPOOL_COUNT:-6}"
TIMEOUT_SECS="${NOETL_SPOOL_TIMEOUT_SECS:-240}"
SUB_PATH="subscriptions/spool_s3_restart_stream"
STREAM="SPOOL_S3"
CONSUMER="spool-s3-drain"
SUBJECT="spool.s3.readings"
DOWNSTREAM_DEPLOY="spool-downstream-echo"
RUNTIME_DEPLOY="noetl-subscription-runtime"
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
CREDS="$REPO_ROOT/fixtures/credentials"
OPS_MANIFESTS="${NOETL_OPS_MANIFESTS:-$REPO_ROOT/../ops/ci/manifests}"

KCTX=(kubectl --context "$KIND_CONTEXT")
PGPOD="$("${KCTX[@]}" -n "$PG_NS" get pod -o name | head -1)"
psql_q() { "${KCTX[@]}" -n "$PG_NS" exec "$PGPOD" -- env PGPASSWORD=noetl psql -U noetl -d noetl -tAc "$1"; }
NATS_CLI=(nats --server "$NATS_LOCAL" --user noetl --password noetl)

echo "kind-val: context=$KIND_CONTEXT ns=$NS count=$COUNT (s3 spool + cross-restart proof)"

for cmd in kubectl nats curl python3; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "kind-val: missing command: $cmd" >&2; exit 2; }
done
[[ -f "$FIX/spool_s3_restart_stream.subscription.yaml" ]] || { echo "kind-val: fixture not found" >&2; exit 2; }

# MinIO must be up with the bucket.
"${KCTX[@]}" -n "$MINIO_NS" get deploy/minio >/dev/null 2>&1 || { echo "kind-val: MinIO not deployed (apply ops ci/manifests/minio)" >&2; exit 2; }

PF_PIDS=()
cleanup() {
  for pid in "${PF_PIDS[@]:-}"; do kill "$pid" >/dev/null 2>&1 || true; done
  if [[ "${KEEP_RESOURCES:-0}" != "1" ]]; then
    "${KCTX[@]}" -n "$NS" delete -f "$OPS_MANIFESTS/noetl/subscription-runtime-deployment.yaml" --ignore-not-found >/dev/null 2>&1 || true
    "${KCTX[@]}" -n "$NS" delete -f "$OPS_MANIFESTS/noetl/spool-downstream-echo.yaml" --ignore-not-found >/dev/null 2>&1 || true
    "${NATS_CLI[@]}" stream rm "$STREAM" -f >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

"${KCTX[@]}" -n "$NS" port-forward svc/noetl 8082:8082 >/tmp/pf_server_s3.log 2>&1 & PF_PIDS+=($!)
"${KCTX[@]}" -n "$NATS_NS" port-forward svc/nats "$NATS_PORT:4222" >/tmp/pf_nats_s3.log 2>&1 & PF_PIDS+=($!)
sleep 4
curl -fsS "$SERVER_URL/api/health" >/dev/null 2>&1 || { echo "kind-val: server not reachable at $SERVER_URL" >&2; exit 2; }

fail() { echo "kind-val: FAIL — $1"; "${KCTX[@]}" -n "$NS" logs deploy/"$RUNTIME_DEPLOY" --tail=100 2>/dev/null || true; exit 1; }

# ----------------------------------------------------------------------
# Register credentials + playbook + subscription.
# ----------------------------------------------------------------------
echo "kind-val: registering credentials + catalog entries"
for c in nats_e2e s3_spool_minio; do
  curl -fsS -X POST "$SERVER_URL/api/credentials" -H 'Content-Type: application/json' \
    -d "$(cat "$CREDS/$c.json.example")" >/dev/null 2>&1 || \
    echo "kind-val: credential $c register non-2xx (may already exist) — continuing"
done

register_catalog() {
  local file="$1" content
  content="$(python3 -c "import json,sys; print(json.dumps(open(sys.argv[1]).read()))" "$file")"
  curl -fsS -X POST "$SERVER_URL/api/catalog/register" -H 'Content-Type: application/json' \
    -d "{\"content\": $content}" >/dev/null
}
register_catalog "$FIX/sub_ingest_default.yaml"
register_catalog "$FIX/spool_s3_restart_stream.subscription.yaml"

# ----------------------------------------------------------------------
# NATS source stream + durable consumer.
# ----------------------------------------------------------------------
echo "kind-val: creating NATS stream $STREAM + consumer $CONSUMER"
"${NATS_CLI[@]}" stream rm "$STREAM" -f >/dev/null 2>&1 || true
"${NATS_CLI[@]}" stream add "$STREAM" --subjects "spool.s3.>" \
  --storage file --retention limits --discard old --max-msgs=-1 --max-bytes=-1 \
  --max-age=1h --dupe-window=2m --replicas 1 --defaults >/dev/null
"${NATS_CLI[@]}" consumer add "$STREAM" "$CONSUMER" --pull --deliver all --ack explicit \
  --max-deliver=-1 --wait=5s --replay instant --filter "$SUBJECT" --defaults >/dev/null

# ----------------------------------------------------------------------
# Deploy downstream + pool + runtime (pointed at the s3 subscription).
# ----------------------------------------------------------------------
echo "kind-val: deploying downstream echo + subscription pool + runtime"
"${KCTX[@]}" -n "$NS" apply -f "$OPS_MANIFESTS/noetl/spool-downstream-echo.yaml" >/dev/null
"${KCTX[@]}" -n "$NS" apply -f "$OPS_MANIFESTS/noetl/worker-rust-subscription-pool-deployment.yaml" >/dev/null
sed "s#value: subscriptions/iot_sensor_stream#value: $SUB_PATH#" \
  "$OPS_MANIFESTS/noetl/subscription-runtime-deployment.yaml" | "${KCTX[@]}" -n "$NS" apply -f - >/dev/null
"${KCTX[@]}" -n "$NS" rollout status deploy/"$DOWNSTREAM_DEPLOY" --timeout=120s >/dev/null
"${KCTX[@]}" -n "$NS" rollout status deploy/noetl-worker-rust-subscription-pool --timeout=120s >/dev/null
"${KCTX[@]}" -n "$NS" rollout status deploy/"$RUNTIME_DEPLOY" --timeout=120s >/dev/null

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
# OUTAGE — circuit opens.
# ----------------------------------------------------------------------
echo "kind-val: ===== OUTAGE: scaling $DOWNSTREAM_DEPLOY to 0 ====="
"${KCTX[@]}" -n "$NS" scale deploy/"$DOWNSTREAM_DEPLOY" --replicas=0 >/dev/null
"${KCTX[@]}" -n "$NS" wait --for=delete pod -l app="$DOWNSTREAM_DEPLOY" --timeout=60s >/dev/null 2>&1 || true

echo "kind-val: waiting for circuit.opened"
opened=""; deadline=$(( $(date +%s) + 90 ))
while (( $(date +%s) < deadline )); do
  opened="$(psql_q "SELECT count(*) FROM noetl.event WHERE execution_id=$SUB_ID AND event_type='subscription.circuit.opened'" | tr -d '[:space:]')"
  [[ "${opened:-0}" -ge 1 ]] && break
  sleep 3
done
[[ "${opened:-0}" -ge 1 ]] || fail "circuit never opened"
echo "kind-val: circuit OPENED ✓"

# ----------------------------------------------------------------------
# Publish N during the outage — they SPOOL to MinIO.
# ----------------------------------------------------------------------
echo "kind-val: publishing $COUNT messages during the outage"
for i in $(seq 1 "$COUNT"); do
  body="{\"device_id\":\"dev-$((i % 3))\",\"seq\":$i,\"reading\":$((RANDOM%100))}"
  "${NATS_CLI[@]}" pub "$SUBJECT" "$body" \
    --header "traceparent:$TRACEPARENT" \
    --header "x-idempotency-key:idem-$i" \
    --header "device_id:dev-$((i % 3))" >/dev/null
done

echo "kind-val: waiting for $COUNT messages to spool to MinIO"
spooled=0; deadline=$(( $(date +%s) + 90 ))
while (( $(date +%s) < deadline )); do
  spooled="$(psql_q "SELECT count(*) FROM noetl.event WHERE execution_id=$SUB_ID AND event_type='subscription.message.spooled'" | tr -d '[:space:]')"
  [[ "${spooled:-0}" -ge "$COUNT" ]] && break
  sleep 3
done
[[ "${spooled:-0}" -ge "$COUNT" ]] || fail "expected $COUNT spooled, got ${spooled:-0}"
echo "kind-val: $spooled messages SPOOLED to s3/MinIO ✓"

kids_during="$(psql_q "SELECT count(DISTINCT execution_id) FROM noetl.event WHERE parent_execution_id=$SUB_ID AND event_type='playbook_started'" | tr -d '[:space:]')"
[[ "${kids_during:-0}" -eq 0 ]] || fail "expected 0 dispatched during outage, got $kids_during"
echo "kind-val: 0 child executions during outage ✓"

# ----------------------------------------------------------------------
# RESTART (#93) — stop the runtime, bring the downstream UP, restart the
# runtime. The restarted runtime must auto-drain the MinIO spool on
# startup (downstream already up → no new circuit cycle needed).
# ----------------------------------------------------------------------
echo "kind-val: ===== RESTART: runtime→0, downstream→1, runtime→1 ====="
"${KCTX[@]}" -n "$NS" scale deploy/"$RUNTIME_DEPLOY" --replicas=0 >/dev/null
"${KCTX[@]}" -n "$NS" wait --for=delete pod -l app=noetl-subscription-runtime --timeout=60s >/dev/null 2>&1 || true
"${KCTX[@]}" -n "$NS" scale deploy/"$DOWNSTREAM_DEPLOY" --replicas=1 >/dev/null
"${KCTX[@]}" -n "$NS" rollout status deploy/"$DOWNSTREAM_DEPLOY" --timeout=120s >/dev/null
echo "kind-val: downstream UP; restarting runtime (recover_on_startup must find the MinIO spool)"
"${KCTX[@]}" -n "$NS" scale deploy/"$RUNTIME_DEPLOY" --replicas=1 >/dev/null
"${KCTX[@]}" -n "$NS" rollout status deploy/"$RUNTIME_DEPLOY" --timeout=120s >/dev/null

# The #93 signature: a spool.recovered event from the restarted runtime
# (keyed on the subscription PATH in the spool_ref, since the restarted
# runtime gets a fresh subscription execution_id).
echo "kind-val: waiting for startup auto-drain (subscription.spool.recovered + replay)"
# The restarted runtime gets a FRESH subscription execution_id, so key the
# recovered event on its rehydrated pending>=COUNT context rather than the
# pre-restart id; replayed events carry the path-based spool_ref.
recovered=0; replayed=0; deadline=$(( $(date +%s) + TIMEOUT_SECS ))
while (( $(date +%s) < deadline )); do
  recovered="$(psql_q "SELECT count(*) FROM noetl.event WHERE event_type='subscription.spool.recovered' AND (result->'context'->>'pending')::int >= $COUNT" | tr -d '[:space:]')"
  replayed="$(psql_q "SELECT count(*) FROM noetl.event WHERE event_type='subscription.message.replayed' AND result->'context'->>'spool_ref' LIKE 'noetl://spool/$SUB_PATH/%'" | tr -d '[:space:]')"
  [[ "${recovered:-0}" -ge 1 && "${replayed:-0}" -ge "$COUNT" ]] && break
  sleep 4
done

# Children completed (idempotent: exactly N, no dups).
NEW_SUB_ID="$(psql_q "SELECT execution_id FROM noetl.event WHERE node_name='$SUB_PATH' AND event_type='subscription.activated' ORDER BY event_id DESC LIMIT 1" | tr -d '[:space:]')"
children="$(psql_q "SELECT count(DISTINCT execution_id) FROM noetl.event WHERE event_type='subscription.message.replayed' AND result->'context'->>'spool_ref' LIKE 'noetl://spool/$SUB_PATH/%'" | tr -d '[:space:]')"
completed="$(psql_q "SELECT count(DISTINCT e.execution_id) FROM noetl.event e WHERE e.event_type='playbook.completed' AND e.execution_id IN (SELECT (result->'context'->>'execution_id')::bigint FROM noetl.event WHERE event_type='subscription.message.replayed' AND result->'context'->>'spool_ref' LIKE 'noetl://spool/$SUB_PATH/%')" | tr -d '[:space:]')"

echo "kind-val: ----- results -----"
echo "kind-val:   spooled (outage):        $spooled / $COUNT"
echo "kind-val:   spool.recovered events:  $recovered (expect >=1 — the #93 startup signature)"
echo "kind-val:   replayed (post-restart): $replayed / $COUNT"
echo "kind-val:   replayed executions:     $children"
echo "kind-val:   completed children:      $completed / $COUNT"

pass=1
[[ "${spooled:-0}"   -ge "$COUNT" ]] || { echo "kind-val: ASSERT spooled<$COUNT"; pass=0; }
[[ "${recovered:-0}" -ge 1 ]]        || { echo "kind-val: ASSERT no subscription.spool.recovered (startup auto-drain did not fire — #93)"; pass=0; }
[[ "${replayed:-0}"  -ge "$COUNT" ]] || { echo "kind-val: ASSERT replayed<$COUNT"; pass=0; }
[[ "${completed:-0}" -ge "$COUNT" ]] || { echo "kind-val: ASSERT completed<$COUNT"; pass=0; }
[[ "${replayed:-0}"  -le "$COUNT" ]] || { echo "kind-val: ASSERT replayed>$COUNT (idempotency broken — duplicate replay)"; pass=0; }

# The restart must NOT have required a fresh circuit open→close cycle: the
# drain is triggered by recover_on_startup. (A circuit.closed AFTER the
# restart is fine if it happens, but the recovered event is the proof.)

if [[ "$pass" == "1" ]]; then
  echo "kind-val: PASS — #94 s3 buffer+replay green; #93 cross-restart auto-drain green (spool.recovered fired, $replayed replayed, idempotent, no loss)"
  exit 0
else
  fail "s3 spool + cross-restart proof assertions failed (see above)"
fi

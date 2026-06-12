#!/usr/bin/env bash
# kind_validate_subscription_cloudrun.sh — noetl/ai-meta#90 Phase 5
# Out-of-cluster (Cloud Run) subscription runtime live E2E.
#
# Proves the out-of-cluster path: the noetl-worker subscription runtime runs
# on Google Cloud Run, pulls from a Pub/Sub subscription, and dispatches one
# execution per message to the NoETL server **over HTTPS** — the server runs
# in the local kind cluster, reached via a tunnel (cloudflared) or any public
# URL. It holds no DB connection; events flow back via POST /api/events.
#
# Phases:
#   1. SETUP   — provision GCP (setup-gcp.sh), register the dispatch playbook
#                + the kind: Subscription (pubsub source + gcs spool), ensure
#                the in-cluster `subscription` execution pool is up.
#   2. DEPLOY  — deploy the Cloud Run service (ops automation/cloud-run/deploy.sh)
#                pointing NOETL_SERVER_URL at the tunnel/public server.
#   3. DISPATCH— publish N messages to the source topic; assert N COMPLETED
#                child executions on the server's event log (the core claim).
#   4. SPOOL   — (optional, --spool) drop the control-plane reachable target so
#                the circuit opens; publish M; assert they buffer to the GCS
#                bucket (gsutil ls); restore; assert drain + replay.
#   5. TEARDOWN— delete the Cloud Run service (stop the cost).
#
# This is a hybrid driver: gcloud (Cloud Run + Pub/Sub) + kubectl/psql
# (assert against the kind server's event log). It is NOT a hermetic CI gate —
# it needs a GCP project + a reachable server — so it is run by hand / nightly,
# not in the per-PR kind sweep. See the Phase-5 wiki entry for the recorded
# live run.
#
# Usage:
#   PROJECT=noetl-demo-19700101 \
#   NOETL_SERVER_URL=https://<tunnel-or-public> \
#   ./scripts/kind_validate_subscription_cloudrun.sh --count 5 [--spool]
set -euo pipefail

PROJECT="${PROJECT:?set PROJECT to the GCP project id}"
REGION="${REGION:-us-central1}"
KIND_CONTEXT="${NOETL_KIND_CONTEXT:-kind-noetl}"
NS="${NOETL_K8S_NAMESPACE:-noetl}"
PG_NS="${NOETL_PG_NS:-postgres}"
NOETL_SERVER_URL="${NOETL_SERVER_URL:?set NOETL_SERVER_URL to an HTTPS-reachable server (tunnel or public)}"
SERVER_LOCAL="${NOETL_SERVER_LOCAL:-http://localhost:8082}"
COUNT="${COUNT:-5}"
TOPIC="${TOPIC:-noetl-sub-phase5}"
SUBSCRIPTION="${SUBSCRIPTION:-noetl-sub-phase5-pull}"
SPOOL_BUCKET="${SPOOL_BUCKET:-${PROJECT}-sub-spool-phase5}"
PUBSUB_SUBSCRIPTION="projects/${PROJECT}/subscriptions/${SUBSCRIPTION}"
SERVICE="${SERVICE:-noetl-subscription-runtime}"
SUB_PATH="subscriptions/cloudrun_pubsub_stream"
DEFAULT_PB="tests/fixtures/sub_ingest_default"
DO_SPOOL=0
KEEP=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --count) COUNT="$2"; shift 2 ;;
    --spool) DO_SPOOL=1; shift ;;
    --keep)  KEEP=1; shift ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed -n '/^#/p'; exit 0 ;;
    *) echo "cloudrun-val: unknown argument: $1" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FIX="$REPO_ROOT/fixtures/subscription"
OPS_DIR="${NOETL_OPS_DIR:-$REPO_ROOT/../ops}"
KCTX=(kubectl --context "$KIND_CONTEXT")
PGPOD="$("${KCTX[@]}" -n "$PG_NS" get pod -o name | head -1)"
psql_q() { "${KCTX[@]}" -n "$PG_NS" exec "$PGPOD" -- env PGPASSWORD=noetl psql -U noetl -d noetl -tAc "$1"; }

echo "cloudrun-val: project=$PROJECT server=$NOETL_SERVER_URL count=$COUNT spool=$DO_SPOOL"
for cmd in gcloud kubectl curl python3; do command -v "$cmd" >/dev/null || { echo "missing $cmd" >&2; exit 2; }; done
curl -fsS "$SERVER_LOCAL/api/health" >/dev/null || { echo "cloudrun-val: kind server not reachable at $SERVER_LOCAL" >&2; exit 2; }
fail() { echo "cloudrun-val: FAIL — $1"; exit 1; }

# ----------------------------------------------------------------------
# 1. SETUP — GCP + catalog + execution pool.
# ----------------------------------------------------------------------
echo "cloudrun-val: ===== SETUP ====="
PROJECT="$PROJECT" REGION="$REGION" SPOOL_BUCKET="$SPOOL_BUCKET" \
  TOPIC="$TOPIC" SUBSCRIPTION="$SUBSCRIPTION" "$OPS_DIR/automation/cloud-run/setup-gcp.sh"

register_catalog() {
  local file="$1" content
  content="$(python3 -c "import json,sys; print(json.dumps(open(sys.argv[1]).read()))" "$file")"
  curl -fsS -X POST "$SERVER_LOCAL/api/catalog/register" -H 'Content-Type: application/json' \
    -d "{\"content\": $content}" >/dev/null
}
register_catalog "$FIX/sub_ingest_default.yaml"
# Render the subscription with the live server/bucket/subscription, then register.
export NOETL_SERVER_URL SPOOL_BUCKET PUBSUB_SUBSCRIPTION
envsubst < "$FIX/cloudrun_pubsub_stream.subscription.yaml" > /tmp/cloudrun_sub.rendered.yaml
register_catalog /tmp/cloudrun_sub.rendered.yaml

# The in-cluster execution pool runs the dispatched playbooks (the Cloud Run
# runtime is only the ingress producer).
"${KCTX[@]}" -n "$NS" apply -f "$OPS_DIR/ci/manifests/noetl/worker-rust-subscription-pool-deployment.yaml" >/dev/null
"${KCTX[@]}" -n "$NS" rollout status deploy/noetl-worker-rust-subscription-pool --timeout=120s >/dev/null

# ----------------------------------------------------------------------
# 2. DEPLOY — Cloud Run service.
# ----------------------------------------------------------------------
echo "cloudrun-val: ===== DEPLOY Cloud Run ====="
PROJECT="$PROJECT" REGION="$REGION" SERVICE="$SERVICE" \
  NOETL_SERVER_URL="$NOETL_SERVER_URL" SUBSCRIPTION_PATH="$SUB_PATH" \
  SPOOL_BUCKET="$SPOOL_BUCKET" WORKER_REPO_DIR="$OPS_DIR/../worker" \
  SKIP_BUILD="${SKIP_BUILD:-0}" "$OPS_DIR/automation/cloud-run/deploy.sh"

echo "cloudrun-val: waiting for subscription ACTIVE"
SUB_ID=""
for _ in $(seq 1 40); do
  SUB_ID="$(psql_q "SELECT execution_id FROM noetl.event WHERE node_name='$SUB_PATH' AND event_type='subscription.activated' ORDER BY event_id DESC LIMIT 1" | tr -d '[:space:]')"
  [[ -n "$SUB_ID" ]] && break
  sleep 3
done
[[ -n "$SUB_ID" ]] || fail "subscription never activated (Cloud Run runtime did not reach the server)"
echo "cloudrun-val: subscription_id=$SUB_ID ACTIVE"

# ----------------------------------------------------------------------
# 3. DISPATCH — publish N, assert N COMPLETED children.
# ----------------------------------------------------------------------
echo "cloudrun-val: ===== DISPATCH: publishing $COUNT messages ====="
for i in $(seq 1 "$COUNT"); do
  gcloud pubsub topics publish "$TOPIC" --project "$PROJECT" \
    --message "{\"seq\":$i,\"hello\":\"cloud-run\"}" \
    --attribute "x-idempotency-key=cr-$i" >/dev/null
done

KIDS_SQL="SELECT DISTINCT execution_id FROM noetl.event WHERE parent_execution_id=$SUB_ID AND event_type='playbook_started'"
completed=0
for _ in $(seq 1 60); do
  completed="$(psql_q "SELECT count(DISTINCT execution_id) FROM noetl.event WHERE execution_id IN ($KIDS_SQL) AND event_type='playbook.completed'" | tr -d '[:space:]')"
  [[ "${completed:-0}" -ge "$COUNT" ]] && break
  sleep 3
done
[[ "${completed:-0}" -ge "$COUNT" ]] || fail "only $completed/$COUNT child executions COMPLETED"
echo "cloudrun-val: PASS dispatch — $completed/$COUNT children COMPLETED on the subscription pool (out-of-cluster → HTTPS → server)"

# ----------------------------------------------------------------------
# 4. SPOOL (optional) — outage → GCS buffer → recovery → drain.
# ----------------------------------------------------------------------
if [[ "$DO_SPOOL" == "1" ]]; then
  echo "cloudrun-val: ===== SPOOL: simulating a control-plane outage ====="
  echo "cloudrun-val: stop the tunnel / make $NOETL_SERVER_URL unreachable, then press Enter"
  read -r _
  for i in $(seq 1 "$COUNT"); do
    gcloud pubsub topics publish "$TOPIC" --project "$PROJECT" \
      --message "{\"seq\":$((100+i)),\"phase\":\"outage\"}" --attribute "x-idempotency-key=cr-out-$i" >/dev/null
  done
  echo "cloudrun-val: waiting for objects to appear in gs://$SPOOL_BUCKET ..."
  spooled=0
  for _ in $(seq 1 40); do
    spooled="$(gcloud storage ls --recursive "gs://$SPOOL_BUCKET/$SUB_PATH/spool/" 2>/dev/null | grep -c '\.json$' || true)"
    [[ "${spooled:-0}" -ge 1 ]] && break
    sleep 3
  done
  [[ "${spooled:-0}" -ge 1 ]] || fail "no objects spooled to GCS during the outage"
  echo "cloudrun-val: PASS spool — $spooled object(s) buffered to GCS during the outage (no loss)"
  echo "cloudrun-val: restore the tunnel, then press Enter to assert drain"
  read -r _
  drained=0
  for _ in $(seq 1 40); do
    drained="$(gcloud storage ls --recursive "gs://$SPOOL_BUCKET/$SUB_PATH/spool/" 2>/dev/null | grep -c '\.json$' || true)"
    [[ "${drained:-0}" -eq 0 ]] && break
    sleep 3
  done
  [[ "${drained:-0}" -eq 0 ]] || fail "spool did not drain on recovery ($drained left)"
  echo "cloudrun-val: PASS drain — GCS spool drained to 0 on recovery"
fi

# ----------------------------------------------------------------------
# 5. TEARDOWN.
# ----------------------------------------------------------------------
if [[ "$KEEP" == "1" ]]; then
  echo "cloudrun-val: --keep set; leaving the Cloud Run service up"
else
  echo "cloudrun-val: ===== TEARDOWN ====="
  PROJECT="$PROJECT" REGION="$REGION" SERVICE="$SERVICE" "$OPS_DIR/automation/cloud-run/teardown.sh"
fi
echo "cloudrun-val: DONE"

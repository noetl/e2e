#!/usr/bin/env bash
# kind_validate_result_producer_stage.sh — producer-staged result tier
# (noetl/ai-meta#104 OQ5, Option A) under the off-server gate + a GCS backend.
#
# Option A re-plumbs the OQ5 byte source: the PRODUCING worker stages the
# over-budget result's tier object directly at emit time
# (`PUT /api/internal/objects/{key}`), encoded with the SAME deterministic
# encoder the materializer uses, at the SAME §7 key the resolve-by-URN read path
# reconstructs. This decouples the tier write from `noetl.result_store` — the
# materializer no longer has to read the store to populate the tier — which is
# the prerequisite to RETIRING `result_store`. The `result_store` dual-write
# CONTINUES until that retirement (gated separately on the OQ5 metric/time soak).
#
# This rig proves, under the prod-exact off-server gate (PUBLISH_ONLY +
# off-server drive + event-materializer sole-writer) with a fake-gcs object
# backend:
#
#   PASS 1 (RETIREMENT-READINESS) — producer-stage ON, materializer OFF,
#     resolve ON. The over-budget producer stages the Feather tier itself
#     (server gcs put>0; worker result_producer_stage_total{staged_feather}>0)
#     WITH NO MATERIALIZER RUNNING, so the tier is populated without any
#     result_store read. The consume step RESOLVES it by URN from GCS
#     (resolved_feather>0). The producer-staged tier ALONE serves the resolve.
#     The dual-write still lands (result_store_put_total{ok}>0). exec COMPLETES.
#   PASS 2 (BYTE-IDENTICAL) — producer-stage ON + DR verify-and-repair ON. The
#     materializer re-derives each result from result_store and compares it to
#     the durable (producer-staged) object: result_tier_dr_total{present}>0 and
#     {rederived}==0 proves the producer-staged bytes are byte-identical to what
#     the materializer would write — across the result_store round-trip.
#   PASS 3 (SKIP-ON-EXISTS) — producer-stage ON + materializer ON (normal write
#     mode). The materializer finds the producer-staged object and SKIPS its
#     result_store fetch: result_producer_stage_total{materializer_skip_exists}>0.
#     The materializer needs NO result_store read for a producer-staged result.
#   PASS 4 (FLAG-OFF NO-OP) — producer-stage OFF, materializer OFF, resolve ON.
#     The producer stages nothing (producer_stage_total Δ0); resolve misses and
#     falls back fail-safe to result_store (fallback_object_miss>0). Default-off
#     is byte-identical to today (the Phase C forced-miss behaviour).
#
# Cutover invariants (sole-writer / roots=1 / no scan) hold on every leg.
#
# Preconditions: the gate-ON stack, a SERVER image with the GCS object backend +
# cell registry (#104 Phase C), and a WORKER image carrying producer-staging
# (#104 OQ5 Option A) + resolve-by-URN (#104 Phase C).
#   - server: NOETL_EVENT_INGEST_PUBLISH_ONLY=true AND NOETL_ORCHESTRATE_PLUGIN_DRIVE=true.
#   - system pool: NOETL_MATERIALIZER_ENABLED=true (event-materializer sole writer).
#
# Usage:
#   ./scripts/kind_validate_result_producer_stage.sh
#   ./scripts/kind_validate_result_producer_stage.sh --no-restore
#
# Exits 0 if PASS; 1 if a hard assertion fails (dumps logs); 2 on precondition.

set -euo pipefail

KIND_CONTEXT="${NOETL_KIND_CONTEXT:-kind-noetl}"
NAMESPACE="${NOETL_K8S_NAMESPACE:-noetl}"
NOETL_SERVER_DEPLOY="${NOETL_SERVER_DEPLOY:-noetl-server-rust}"
NOETL_WORKER_POOL_DEPLOY="${NOETL_WORKER_POOL_DEPLOY:-noetl-worker-rust}"
NOETL_SYSTEM_POOL_DEPLOY="${NOETL_SYSTEM_POOL_DEPLOY:-noetl-worker-system-pool}"
NOETL_SERVER_URL="${NOETL_SERVER_URL:-http://localhost:8082}"
TIMEOUT_SECS="${NOETL_ORCH_TIMEOUT_SECS:-240}"
RESTORE=1

GCS_ENDPOINT_IN="http://fake-gcs-server.${NAMESPACE}.svc.cluster.local:4443"
GCS_BUCKET="noetl-results"
CELL="local-0"; CELL_ENV="dev"; CELL_REGION="local"; SHARD_COUNT="256"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --context)    KIND_CONTEXT="$2"; shift 2 ;;
    --namespace)  NAMESPACE="$2"; shift 2 ;;
    --server-url) NOETL_SERVER_URL="$2"; shift 2 ;;
    --timeout)    TIMEOUT_SECS="$2"; shift 2 ;;
    --no-restore) RESTORE=0; shift ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed -n '/^#/p'; exit 0 ;;
    *) echo "kind-val: unknown argument: $1" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FIX="$REPO_ROOT/fixtures/playbooks/test_resolve_by_urn.yaml:tests/resolve_by_urn_test"
MANIFEST="$REPO_ROOT/manifests/fake-gcs-server.yaml"

echo "kind-val: context=$KIND_CONTEXT namespace=$NAMESPACE"
echo "kind-val: #104 OQ5 Option A — producer-staged result tier"

for cmd in kubectl noetl curl python3; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "kind-val: required command not in PATH: $cmd" >&2; exit 2; }
done
[[ -f "${FIX%%:*}" ]] || { echo "kind-val: fixture not found: ${FIX%%:*}" >&2; exit 2; }
[[ -f "$MANIFEST" ]]  || { echo "kind-val: manifest not found: $MANIFEST" >&2; exit 2; }

KCTX=(kubectl --context "$KIND_CONTEXT" -n "$NAMESPACE")

"${KCTX[@]}" get deployment "$NOETL_SERVER_DEPLOY" >/dev/null 2>&1 \
  || { echo "kind-val: $NOETL_SERVER_DEPLOY not found." >&2; exit 2; }
curl -fsS "$NOETL_SERVER_URL/api/health" >/dev/null 2>&1 \
  || { echo "kind-val: server not reachable at $NOETL_SERVER_URL — start a port-forward." >&2; exit 2; }

get_env() { "${KCTX[@]}" get deploy "$1" \
  -o jsonpath="{range .spec.template.spec.containers[0].env[?(@.name==\"$2\")]}{.value}{end}" 2>/dev/null || true; }

GATE_ON="$(get_env "$NOETL_SERVER_DEPLOY" NOETL_EVENT_INGEST_PUBLISH_ONLY)"
DRIVE_ON="$(get_env "$NOETL_SERVER_DEPLOY" NOETL_ORCHESTRATE_PLUGIN_DRIVE)"
MAT_ON="$(get_env "$NOETL_SYSTEM_POOL_DEPLOY" NOETL_MATERIALIZER_ENABLED)"
echo "kind-val: env — PUBLISH_ONLY=$GATE_ON PLUGIN_DRIVE=$DRIVE_ON MATERIALIZER_ENABLED=$MAT_ON"
[[ "$GATE_ON" == "true" ]] || { echo "kind-val: PUBLISH_ONLY not true — gate required." >&2; exit 2; }
[[ "$DRIVE_ON" != "false" ]] || { echo "kind-val: PLUGIN_DRIVE=false — off-server drive required." >&2; exit 2; }
[[ "$MAT_ON" == "true" ]] || { echo "kind-val: MATERIALIZER_ENABLED not true — no sole writer." >&2; exit 2; }

# Save baseline for restore.
ORIG_RM="$(get_env "$NOETL_SYSTEM_POOL_DEPLOY" NOETL_RESULT_MATERIALIZER_ENABLED)"
PF_PID=""

cleanup() {
  [[ -n "$PF_PID" ]] && kill "$PF_PID" >/dev/null 2>&1 || true
  if [[ "$RESTORE" -eq 1 ]]; then
    echo "kind-val: restoring baseline"
    "${KCTX[@]}" set env deploy/"$NOETL_SERVER_DEPLOY" \
      "NOETL_OBJECT_STORE_BACKEND-" "NOETL_OBJECT_STORE_GCS_ENDPOINT-" "NOETL_OBJECT_STORE_GCS_BUCKET-" \
      "NOETL_RESULT_CELL-" "NOETL_RESULT_CELL_ENV-" "NOETL_RESULT_CELL_REGION-" "NOETL_RESULT_SHARD_COUNT-" >/dev/null 2>&1 || true
    "${KCTX[@]}" set env deploy/"$NOETL_WORKER_POOL_DEPLOY" \
      "NOETL_RESULT_URI_RESOLVE-" "NOETL_RESULT_PRODUCER_STAGE-" >/dev/null 2>&1 || true
    "${KCTX[@]}" set env deploy/"$NOETL_SYSTEM_POOL_DEPLOY" \
      "NOETL_RESULT_MATERIALIZER_ENABLED=${ORIG_RM:-false}" \
      "NOETL_RESULT_TIER_DR-" "NOETL_RESULT_PRODUCER_STAGE-" \
      "NOETL_RESULT_CELL-" "NOETL_RESULT_CELL_ENV-" "NOETL_RESULT_CELL_REGION-" "NOETL_RESULT_SHARD_COUNT-" \
      "NOETL_OBJECT_STORE_BACKEND-" >/dev/null 2>&1 || true
    "${KCTX[@]}" delete -f "$MANIFEST" --ignore-not-found >/dev/null 2>&1 || true
    echo "kind-val: baseline restore requested (deployments will roll back)"
  fi
}
trap cleanup EXIT

# ----------------------------------------------------------------------
# Helpers.
# ----------------------------------------------------------------------
count_rows() { { noetl query "$1" --format json 2>/dev/null || true; } \
  | python3 -c 'import json,sys
d=json.loads(sys.stdin.read() or "{}").get("result", [])
print(d[0].get("n", 0) if d else 0)'; }

server_metric() {  # grep_pattern
  { curl -fsS "$NOETL_SERVER_URL/metrics" 2>/dev/null || true; } \
    | { grep -E "$1" || true; } | awk '{s+=$NF} END{printf "%d", s+0}'
}

# Sum a worker-metric series across all pods of a given deployment.
pool_metric() {  # deploy grep_pattern
  local deploy="$1" pat="$2" sel pod total=0 v
  sel="$("${KCTX[@]}" get deploy "$deploy" -o jsonpath='{.spec.selector.matchLabels}' 2>/dev/null \
        | python3 -c 'import json,sys; d=json.load(sys.stdin); print(",".join(f"{k}={v}" for k,v in d.items()))')" || true
  for pod in $("${KCTX[@]}" get pods -l "$sel" -o name 2>/dev/null); do
    v="$("${KCTX[@]}" exec "$pod" -- wget -qO- http://127.0.0.1:9090/metrics 2>/dev/null \
         | { grep -E "$pat" || true; } | awk '{s+=$NF} END{printf "%d", s+0}')" || true
    total=$((total + ${v:-0}))
  done
  echo "$total"
}
worker_metric() { pool_metric "$NOETL_WORKER_POOL_DEPLOY" "$1"; }
system_metric() { pool_metric "$NOETL_SYSTEM_POOL_DEPLOY" "$1"; }

roll() { "${KCTX[@]}" rollout status deploy/"$1" --timeout=150s >/dev/null 2>&1 || true; }

run_leg() {  # label -> sets LEG_EID, LEG_STATUS, LEG_OUT
  noetl register playbook --file "${FIX%%:*}" >/dev/null
  LEG_EID="$(noetl exec "${FIX##*:}" --runtime distributed --json \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["execution_id"])')"
  echo "kind-val: $1 leg launched execution_id=$LEG_EID"
  local deadline=$(( SECONDS + TIMEOUT_SECS ))
  LEG_STATUS=""
  while [[ $SECONDS -lt $deadline ]]; do
    LEG_STATUS="$(noetl status "$LEG_EID" --json 2>/dev/null \
      | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",""))' || true)"
    case "$LEG_STATUS" in COMPLETED|FAILED) break ;; esac
    sleep 3
  done
  sleep 3
  LEG_OUT="$(count_rows "SELECT COUNT(*) AS n FROM noetl.event
             WHERE execution_id = $LEG_EID AND result::text LIKE '%\"test_passed\": true%'")"
}

OVERALL=0
fail() { echo "kind-val: FAIL — $1" >&2; OVERALL=1; }

assert_sole_writer() {  # eid label
  local eid="$1" lbl="$2" rows distinct cat0 orch_ev
  rows="$(count_rows "SELECT COUNT(*) AS n FROM noetl.event WHERE execution_id = $eid")"
  distinct="$(count_rows "SELECT COUNT(DISTINCT event_id) AS n FROM noetl.event WHERE execution_id = $eid")"
  cat0="$(count_rows "SELECT COUNT(*) AS n FROM noetl.event WHERE execution_id = $eid AND catalog_id = 0")"
  orch_ev="$(count_rows "SELECT COUNT(*) AS n FROM noetl.event WHERE execution_id = $eid AND node_name = '__orchestrate__'")"
  echo "kind-val: $lbl db — event_rows=$rows distinct=$distinct catalog0=$cat0 orch_event=$orch_ev"
  [[ "$rows" -gt 0 && "$rows" == "$distinct" ]] || fail "$lbl event rows ($rows) != distinct ($distinct)"
  [[ "$cat0" == "0" ]] || fail "$lbl $cat0 events with catalog_id=0"
  [[ "$orch_ev" == "0" ]] || fail "$lbl expected 0 __orchestrate__ rows, got $orch_ev"
}

# ----------------------------------------------------------------------
# Setup: fake-gcs-server + GCS backend + cell registry.
# ----------------------------------------------------------------------
echo; echo "kind-val: deploying fake-gcs-server emulator"
"${KCTX[@]}" apply -f "$MANIFEST" >/dev/null
"${KCTX[@]}" rollout status deploy/fake-gcs-server --timeout=120s >/dev/null 2>&1 || true

"${KCTX[@]}" port-forward svc/fake-gcs-server 4443:4443 >/dev/null 2>&1 &
PF_PID=$!
sleep 3
curl -fsS -X POST "http://localhost:4443/storage/v1/b?project=noetl-test" \
  -H 'Content-Type: application/json' -d "{\"name\":\"$GCS_BUCKET\"}" >/dev/null 2>&1 \
  || echo "kind-val: bucket create returned non-2xx (may already exist) — continuing"
echo "kind-val: bucket $GCS_BUCKET ready on fake-gcs-server"

echo "kind-val: configuring GCS backend + cell registry on server"
"${KCTX[@]}" set env deploy/"$NOETL_SERVER_DEPLOY" \
  NOETL_OBJECT_STORE_BACKEND=gcs \
  "NOETL_OBJECT_STORE_GCS_ENDPOINT=$GCS_ENDPOINT_IN" \
  "NOETL_OBJECT_STORE_GCS_BUCKET=$GCS_BUCKET" \
  "NOETL_RESULT_CELL=$CELL" "NOETL_RESULT_CELL_ENV=$CELL_ENV" \
  "NOETL_RESULT_CELL_REGION=$CELL_REGION" "NOETL_RESULT_SHARD_COUNT=$SHARD_COUNT" >/dev/null
# System pool seeds the §7 key from its OWN cell env — keep it identical to the
# server registry so the materializer's write keys == the read/producer keys.
"${KCTX[@]}" set env deploy/"$NOETL_SYSTEM_POOL_DEPLOY" \
  "NOETL_RESULT_CELL=$CELL" "NOETL_RESULT_CELL_ENV=$CELL_ENV" \
  "NOETL_RESULT_CELL_REGION=$CELL_REGION" "NOETL_RESULT_SHARD_COUNT=$SHARD_COUNT" >/dev/null
roll "$NOETL_SERVER_DEPLOY"; sleep 5

# ======================================================================
# PASS 1 — retirement-readiness: producer stages, NO materializer, resolve.
# ======================================================================
echo; echo "================================================================"
echo "kind-val: PASS 1 — producer-stage ON, materializer OFF, resolve ON"
echo "          (producer-staged tier ALONE serves the resolve)"
echo "================================================================"
"${KCTX[@]}" set env deploy/"$NOETL_SYSTEM_POOL_DEPLOY" NOETL_RESULT_MATERIALIZER_ENABLED=false NOETL_RESULT_TIER_DR- >/dev/null
"${KCTX[@]}" set env deploy/"$NOETL_WORKER_POOL_DEPLOY" NOETL_RESULT_URI_RESOLVE=true NOETL_RESULT_PRODUCER_STAGE=true >/dev/null
roll "$NOETL_SYSTEM_POOL_DEPLOY"; roll "$NOETL_WORKER_POOL_DEPLOY"; sleep 8

PUT0="$(server_metric 'noetl_object_store_ops_total\{backend="gcs",op="put",outcome="ok"\}')"
GET0="$(server_metric 'noetl_object_store_ops_total\{backend="gcs",op="get",outcome="ok"\}')"
STAGED0="$(worker_metric 'noetl_worker_result_producer_stage_total\{outcome="staged_(feather|json)"\}')"
RF0="$(worker_metric 'noetl_worker_result_resolve_total\{outcome="resolved_(feather|json)"\}')"
RSP0="$(server_metric 'noetl_result_store_put_total\{status="ok"\}')"

run_leg "pass1"
P1_EID="$LEG_EID"; P1_RC="$LEG_OUT"
[[ "$LEG_STATUS" == "COMPLETED" ]] || fail "pass1 leg did not COMPLETE (got $LEG_STATUS)"
[[ "$P1_RC" -ge 1 ]] || fail "pass1 consume did not fully resolve the payload (test_passed!=true)"
assert_sole_writer "$P1_EID" "pass1"

PUT1="$(server_metric 'noetl_object_store_ops_total\{backend="gcs",op="put",outcome="ok"\}')"
GET1="$(server_metric 'noetl_object_store_ops_total\{backend="gcs",op="get",outcome="ok"\}')"
STAGED1="$(worker_metric 'noetl_worker_result_producer_stage_total\{outcome="staged_(feather|json)"\}')"
RF1="$(worker_metric 'noetl_worker_result_resolve_total\{outcome="resolved_(feather|json)"\}')"
RSP1="$(server_metric 'noetl_result_store_put_total\{status="ok"\}')"
echo "kind-val: pass1 — gcs put Δ=$((PUT1-PUT0)) get Δ=$((GET1-GET0)) staged Δ=$((STAGED1-STAGED0)) resolved Δ=$((RF1-RF0)) result_store_put Δ=$((RSP1-RSP0)) passed=$P1_RC"
# The PRODUCER staged the tier (worker counter) AND the server wrote it to GCS,
# WITH NO MATERIALIZER running — so the tier was populated with no result_store read.
[[ $((STAGED1-STAGED0)) -ge 1 ]] || fail "pass1 producer did not stage the tier object (staged Δ0)"
[[ $((PUT1-PUT0)) -ge 1 ]] || fail "pass1 server wrote no object to GCS (put Δ0)"
# The consume step RESOLVED the producer-staged object by URN.
[[ $((GET1-GET0)) -ge 1 ]] || fail "pass1 server served no object from GCS (get Δ0)"
[[ $((RF1-RF0)) -ge 1 ]] || fail "pass1 worker did not resolve the producer-staged object by URN (resolved Δ0)"
# Dual-write to result_store still lands (reversibility preserved until retirement).
[[ $((RSP1-RSP0)) -ge 1 ]] || fail "pass1 result_store dual-write did not land (result_store_put Δ0)"

# ======================================================================
# PASS 2 — byte-identical: DR verify-and-repair finds the producer object PRESENT.
# ======================================================================
echo; echo "================================================================"
echo "kind-val: PASS 2 — producer-stage ON + DR verify (byte-identical proof)"
echo "================================================================"
"${KCTX[@]}" set env deploy/"$NOETL_SYSTEM_POOL_DEPLOY" NOETL_RESULT_TIER_DR=true NOETL_RESULT_MATERIALIZER_ENABLED=false >/dev/null
roll "$NOETL_SYSTEM_POOL_DEPLOY"; sleep 8

DRP0="$(system_metric 'noetl_worker_result_tier_dr_total\{outcome="present"\}')"
DRR0="$(system_metric 'noetl_worker_result_tier_dr_total\{outcome="rederived"\}')"
run_leg "pass2"
P2_EID="$LEG_EID"
[[ "$LEG_STATUS" == "COMPLETED" ]] || fail "pass2 leg did not COMPLETE (got $LEG_STATUS)"
assert_sole_writer "$P2_EID" "pass2"
# Give DR a beat to drain + verify the WAL event for the over-budget result.
sleep 8
DRP1="$(system_metric 'noetl_worker_result_tier_dr_total\{outcome="present"\}')"
DRR1="$(system_metric 'noetl_worker_result_tier_dr_total\{outcome="rederived"\}')"
echo "kind-val: pass2 — dr present Δ=$((DRP1-DRP0)) dr rederived Δ=$((DRR1-DRR0))"
# DR re-derived the result from result_store and found the durable (producer-staged)
# object byte-IDENTICAL -> present. A 'rederived' would mean the producer object
# diverged from the materializer's encode (byte-identity broken).
[[ $((DRP1-DRP0)) -ge 1 ]] || fail "pass2 DR did not confirm a byte-identical present object (present Δ0)"
[[ $((DRR1-DRR0)) -eq 0 ]] || fail "pass2 DR REDERIVED ($((DRR1-DRR0))) — producer object diverged from the materializer encode (NOT byte-identical)"

# ======================================================================
# PASS 3 — skip-on-exists: materializer finds the producer object, skips fetch.
# ======================================================================
echo; echo "================================================================"
echo "kind-val: PASS 3 — producer-stage ON + materializer ON (skip-on-exists)"
echo "================================================================"
"${KCTX[@]}" set env deploy/"$NOETL_SYSTEM_POOL_DEPLOY" NOETL_RESULT_TIER_DR- NOETL_RESULT_MATERIALIZER_ENABLED=true NOETL_RESULT_PRODUCER_STAGE=true >/dev/null
roll "$NOETL_SYSTEM_POOL_DEPLOY"; sleep 8

SKIP0="$(system_metric 'noetl_worker_result_producer_stage_total\{outcome="materializer_skip_exists"\}')"
run_leg "pass3"
P3_EID="$LEG_EID"; P3_RC="$LEG_OUT"
[[ "$LEG_STATUS" == "COMPLETED" ]] || fail "pass3 leg did not COMPLETE (got $LEG_STATUS)"
[[ "$P3_RC" -ge 1 ]] || fail "pass3 consume did not fully resolve the payload (test_passed!=true)"
assert_sole_writer "$P3_EID" "pass3"
sleep 8
SKIP1="$(system_metric 'noetl_worker_result_producer_stage_total\{outcome="materializer_skip_exists"\}')"
echo "kind-val: pass3 — materializer_skip_exists Δ=$((SKIP1-SKIP0)) passed=$P3_RC"
# The materializer found the producer-staged object on its §7 key and skipped the
# result_store fetch entirely -> the "materializer needs no result_store read" proof.
[[ $((SKIP1-SKIP0)) -ge 1 ]] || fail "pass3 materializer did not skip-on-exists (no result_store-read avoided)"

# ======================================================================
# PASS 4 — flag-off no-op: producer stages nothing; resolve falls back.
# ======================================================================
echo; echo "================================================================"
echo "kind-val: PASS 4 — producer-stage OFF (default-off no-op)"
echo "================================================================"
"${KCTX[@]}" set env deploy/"$NOETL_WORKER_POOL_DEPLOY" NOETL_RESULT_PRODUCER_STAGE=false >/dev/null
"${KCTX[@]}" set env deploy/"$NOETL_SYSTEM_POOL_DEPLOY" NOETL_RESULT_MATERIALIZER_ENABLED=false NOETL_RESULT_PRODUCER_STAGE=false >/dev/null
roll "$NOETL_WORKER_POOL_DEPLOY"; roll "$NOETL_SYSTEM_POOL_DEPLOY"; sleep 8

STAGED_OFF0="$(worker_metric 'noetl_worker_result_producer_stage_total\{outcome="staged_(feather|json)"\}')"
FM0="$(worker_metric 'noetl_worker_result_resolve_total\{outcome="fallback_object_miss"\}')"
run_leg "pass4"
P4_EID="$LEG_EID"; P4_RC="$LEG_OUT"
[[ "$LEG_STATUS" == "COMPLETED" ]] || fail "pass4 leg did not COMPLETE (got $LEG_STATUS) — flag-off must not fail"
[[ "$P4_RC" -ge 1 ]] || fail "pass4 fallback did not fully resolve the payload (test_passed!=true)"
assert_sole_writer "$P4_EID" "pass4"
STAGED_OFF1="$(worker_metric 'noetl_worker_result_producer_stage_total\{outcome="staged_(feather|json)"\}')"
FM1="$(worker_metric 'noetl_worker_result_resolve_total\{outcome="fallback_object_miss"\}')"
echo "kind-val: pass4 — staged Δ=$((STAGED_OFF1-STAGED_OFF0)) (want 0) fallback_object_miss Δ=$((FM1-FM0)) passed=$P4_RC"
[[ $((STAGED_OFF1-STAGED_OFF0)) -eq 0 ]] || fail "pass4 (flag-off) producer staged an object (Δ!=0) — not a no-op"
[[ $((FM1-FM0)) -ge 1 ]] || fail "pass4 (flag-off) did not fall back to result_store (no producer object, no materializer)"

echo
if [[ "$OVERALL" -eq 0 ]]; then
  echo "================================================================"
  echo "kind-val: PASS — #104 OQ5 Option A producer-staged result tier"
  echo "  PASS 1 : exec $P1_EID — producer staged the tier (no materializer), the"
  echo "           consume RESOLVED it by URN; result_store dual-write still landed."
  echo "  PASS 2 : exec $P2_EID — DR confirmed the producer object BYTE-IDENTICAL"
  echo "           to the materializer encode (present>0, rederived=0)."
  echo "  PASS 3 : exec $P3_EID — materializer SKIPPED its result_store fetch on the"
  echo "           producer-staged object (materializer_skip_exists>0)."
  echo "  PASS 4 : exec $P4_EID — flag-off no-op: producer staged nothing, resolve"
  echo "           fell back fail-safe to result_store."
  echo "  sole-writer intact every leg; result_store retirement now UNBLOCKED."
  echo "================================================================"
  exit 0
fi

echo "================================================================"
echo "kind-val: FAIL — see assertion errors above"
echo "================================================================"
echo "kind-val: server logs (tail 80):"; "${KCTX[@]}" logs deploy/"$NOETL_SERVER_DEPLOY" --tail=80 || true
echo; echo "kind-val: worker-pool logs (tail 100):"; "${KCTX[@]}" logs deploy/"$NOETL_WORKER_POOL_DEPLOY" --tail=100 || true
echo; echo "kind-val: system-pool logs (tail 80):"; "${KCTX[@]}" logs deploy/"$NOETL_SYSTEM_POOL_DEPLOY" --tail=80 || true
exit 1

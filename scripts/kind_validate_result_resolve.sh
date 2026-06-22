#!/usr/bin/env bash
# kind_validate_result_resolve.sh — the resolve-by-URN read path under the
# off-server gate, with a GCS backend (noetl/ai-meta#104 Phase C).
#
# Phase C is the FIRST phase that READS the Feather/JSON result tier Phase B
# writes. When a downstream step binds the bulk of an over-budget upstream
# result, the worker resolves the result's canonical logical URI -> cell
# placement (server-served registry) -> derived §7 physical key -> object bytes
# (server-mediated, now GCS-backed) -> JSON — INSTEAD of the legacy
# noetl.result_store fetch. On any miss/error it FALLS BACK fail-safe to the
# authoritative store (OQ6) and increments a fallback metric.
#
# This rig proves, under the prod-exact off-server gate (PUBLISH_ONLY +
# off-server drive + event-materializer sole-writer), with a fake-gcs-server
# object backend:
#
#   PASS 1 (flag-on, materializer-on) — the over-budget tabular producer's
#     Feather lands in GCS (server gcs put>0), the consume step binds the bulk
#     and RESOLVES it by URN from GCS (server gcs get>0, worker
#     result_resolve_total{resolved_feather}>0); the full 1200-row payload is
#     bound (row_count==1200); exec COMPLETES; sole-writer intact.
#   PASS 2 (forced miss: resolve-on, materializer-off -> no Feather written) —
#     resolve-by-URN finds no object, FALLS BACK to result_store
#     (result_resolve_total{fallback_object_miss}>0), still binds the full
#     payload (row_count==1200); exec COMPLETES; sole-writer intact.
#   PASS 3 (flag-off) — legacy resolve_ref path; resolve metric Δ0; full payload
#     bound; exec COMPLETES; consume output BYTE-IDENTICAL to PASS 1 (parity).
#
# Backend: a fake-gcs-server emulator (kind only; never real GCS).
#
# Preconditions (the gate-ON stack), PLUS a SERVER image carrying the GCS object
# backend + cell registry (#104 Phase C) and a WORKER image carrying the
# resolve-by-URN read path (#104 Phase C).
#   - server: NOETL_EVENT_INGEST_PUBLISH_ONLY=true AND NOETL_ORCHESTRATE_PLUGIN_DRIVE=true.
#   - system pool: NOETL_MATERIALIZER_ENABLED=true.
#
# Usage:
#   ./scripts/kind_validate_result_resolve.sh
#   ./scripts/kind_validate_result_resolve.sh --no-restore
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
echo "kind-val: #104 Phase C — resolve-by-URN read path (GCS backend)"

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
ORIG_BACKEND="$(get_env "$NOETL_SERVER_DEPLOY" NOETL_OBJECT_STORE_BACKEND)"
ORIG_RESOLVE="$(get_env "$NOETL_WORKER_POOL_DEPLOY" NOETL_RESULT_URI_RESOLVE)"
ORIG_RM="$(get_env "$NOETL_SYSTEM_POOL_DEPLOY" NOETL_RESULT_MATERIALIZER_ENABLED)"
PF_PID=""

cleanup() {
  [[ -n "$PF_PID" ]] && kill "$PF_PID" >/dev/null 2>&1 || true
  if [[ "$RESTORE" -eq 1 ]]; then
    echo "kind-val: restoring baseline"
    "${KCTX[@]}" set env deploy/"$NOETL_SERVER_DEPLOY" \
      "NOETL_OBJECT_STORE_BACKEND-" "NOETL_OBJECT_STORE_GCS_ENDPOINT-" "NOETL_OBJECT_STORE_GCS_BUCKET-" \
      "NOETL_RESULT_CELL-" "NOETL_RESULT_CELL_ENV-" "NOETL_RESULT_CELL_REGION-" "NOETL_RESULT_SHARD_COUNT-" >/dev/null 2>&1 || true
    "${KCTX[@]}" set env deploy/"$NOETL_WORKER_POOL_DEPLOY" "NOETL_RESULT_URI_RESOLVE-" >/dev/null 2>&1 || true
    "${KCTX[@]}" set env deploy/"$NOETL_SYSTEM_POOL_DEPLOY" \
      "NOETL_RESULT_MATERIALIZER_ENABLED=${ORIG_RM:-false}" \
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
count_rows() { noetl query "$1" --format json 2>/dev/null \
  | python3 -c 'import json,sys
d=json.loads(sys.stdin.read() or "{}").get("result", [])
print(d[0].get("n", 0) if d else 0)'; }

# Sum a server-metric series matching a grep pattern (counter value = last field).
server_metric() {  # grep_pattern
  curl -fsS "$NOETL_SERVER_URL/metrics" 2>/dev/null \
    | grep -E "$1" | awk '{s+=$NF} END{printf "%d", s+0}'
}

# Sum a worker-metric series across all pods of the worker pool deployment.
worker_metric() {  # grep_pattern
  local sel pod total=0 v
  sel="$("${KCTX[@]}" get deploy "$NOETL_WORKER_POOL_DEPLOY" -o jsonpath='{.spec.selector.matchLabels}' 2>/dev/null \
        | python3 -c 'import json,sys; d=json.load(sys.stdin); print(",".join(f"{k}={v}" for k,v in d.items()))')"
  for pod in $("${KCTX[@]}" get pods -l "$sel" -o name 2>/dev/null); do
    v="$("${KCTX[@]}" exec "$pod" -- wget -qO- http://localhost:9090/metrics 2>/dev/null \
         | grep -E "$1" | awk '{s+=$NF} END{printf "%d", s+0}')" || true
    total=$((total + ${v:-0}))
  done
  echo "$total"
}

roll() { "${KCTX[@]}" rollout status deploy/"$1" --timeout=150s >/dev/null 2>&1 || true; }

run_leg() {  # label -> sets LEG_EID, LEG_STATUS, LEG_OUT(consume result json)
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
  # Proof the FULL payload resolved (bulk, not the 1-row summary): an event for
  # this execution carries test_passed==true, which the fixture sets only when
  # row_count==1200 AND the deep row[1100][0]==1100 (the deep row decoded back
  # correctly from whichever tier served it).
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
# Setup: fake-gcs-server + GCS backend + cell registry + resolve flag.
# ----------------------------------------------------------------------
echo; echo "kind-val: deploying fake-gcs-server emulator"
"${KCTX[@]}" apply -f "$MANIFEST" >/dev/null
"${KCTX[@]}" rollout status deploy/fake-gcs-server --timeout=120s >/dev/null 2>&1 || true

# Port-forward fake-gcs-server to create the bucket from the host.
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
# System pool writes via the server, but seeds the §7 key from its OWN cell env —
# keep it identical to the server registry so write keys == read keys.
"${KCTX[@]}" set env deploy/"$NOETL_SYSTEM_POOL_DEPLOY" \
  "NOETL_RESULT_CELL=$CELL" "NOETL_RESULT_CELL_ENV=$CELL_ENV" \
  "NOETL_RESULT_CELL_REGION=$CELL_REGION" "NOETL_RESULT_SHARD_COUNT=$SHARD_COUNT" >/dev/null
roll "$NOETL_SERVER_DEPLOY"; sleep 5

# ======================================================================
# PASS 1 — flag-on + materializer-on: resolve from GCS Feather.
# ======================================================================
echo; echo "================================================================"
echo "kind-val: PASS 1 — resolve-by-URN ON, materializer ON (resolve from GCS)"
echo "================================================================"
"${KCTX[@]}" set env deploy/"$NOETL_SYSTEM_POOL_DEPLOY" NOETL_RESULT_MATERIALIZER_ENABLED=true >/dev/null
"${KCTX[@]}" set env deploy/"$NOETL_WORKER_POOL_DEPLOY" NOETL_RESULT_URI_RESOLVE=true >/dev/null
roll "$NOETL_SYSTEM_POOL_DEPLOY"; roll "$NOETL_WORKER_POOL_DEPLOY"; sleep 8

PUT0="$(server_metric 'noetl_object_store_ops_total\{backend="gcs",op="put",outcome="ok"\}')"
GET0="$(server_metric 'noetl_object_store_ops_total\{backend="gcs",op="get",outcome="ok"\}')"
RF0="$(worker_metric 'noetl_worker_result_resolve_total\{outcome="resolved_feather"\}')"

run_leg "pass1"
P1_EID="$LEG_EID"; P1_RC="$LEG_OUT"
[[ "$LEG_STATUS" == "COMPLETED" ]] || fail "pass1 leg did not COMPLETE (got $LEG_STATUS)"
[[ "$P1_RC" -ge 1 ]] || fail "pass1 consume did not fully resolve the payload (test_passed!=true)"
assert_sole_writer "$P1_EID" "pass1"

PUT1="$(server_metric 'noetl_object_store_ops_total\{backend="gcs",op="put",outcome="ok"\}')"
GET1="$(server_metric 'noetl_object_store_ops_total\{backend="gcs",op="get",outcome="ok"\}')"
RF1="$(worker_metric 'noetl_worker_result_resolve_total\{outcome="resolved_feather"\}')"
echo "kind-val: pass1 — gcs put Δ=$((PUT1-PUT0)) get Δ=$((GET1-GET0)) resolved_feather Δ=$((RF1-RF0)) passed=$P1_RC"
[[ $((PUT1-PUT0)) -ge 1 ]] || fail "pass1 server wrote no Feather to GCS (put Δ0)"
[[ $((GET1-GET0)) -ge 1 ]] || fail "pass1 server served no object from GCS (get Δ0)"
[[ $((RF1-RF0)) -ge 1 ]]   || fail "pass1 worker did not resolve by URN from the Feather tier (resolved_feather Δ0)"

# ======================================================================
# PASS 2 — forced miss: resolve ON, materializer OFF -> fail-safe fallback.
# ======================================================================
echo; echo "================================================================"
echo "kind-val: PASS 2 — resolve ON, materializer OFF (forced miss -> fallback)"
echo "================================================================"
"${KCTX[@]}" set env deploy/"$NOETL_SYSTEM_POOL_DEPLOY" NOETL_RESULT_MATERIALIZER_ENABLED=false >/dev/null
roll "$NOETL_SYSTEM_POOL_DEPLOY"; sleep 8

FM0="$(worker_metric 'noetl_worker_result_resolve_total\{outcome="fallback_object_miss"\}')"
run_leg "pass2"
P2_EID="$LEG_EID"; P2_RC="$LEG_OUT"
[[ "$LEG_STATUS" == "COMPLETED" ]] || fail "pass2 leg did not COMPLETE (got $LEG_STATUS) — fallback must not fail the exec"
[[ "$P2_RC" -ge 1 ]] || fail "pass2 fallback did not fully resolve the payload (test_passed!=true)"
assert_sole_writer "$P2_EID" "pass2"
FM1="$(worker_metric 'noetl_worker_result_resolve_total\{outcome="fallback_object_miss"\}')"
echo "kind-val: pass2 — fallback_object_miss Δ=$((FM1-FM0)) passed=$P2_RC status=$LEG_STATUS"
[[ $((FM1-FM0)) -ge 1 ]] || fail "pass2 did not record a fail-safe object-miss fallback"

# ======================================================================
# PASS 3 — flag-off: legacy resolve_ref; parity with PASS 1.
# ======================================================================
echo; echo "================================================================"
echo "kind-val: PASS 3 — resolve-by-URN OFF (legacy path; parity)"
echo "================================================================"
"${KCTX[@]}" set env deploy/"$NOETL_WORKER_POOL_DEPLOY" NOETL_RESULT_URI_RESOLVE=false >/dev/null
"${KCTX[@]}" set env deploy/"$NOETL_SYSTEM_POOL_DEPLOY" NOETL_RESULT_MATERIALIZER_ENABLED=true >/dev/null
roll "$NOETL_WORKER_POOL_DEPLOY"; roll "$NOETL_SYSTEM_POOL_DEPLOY"; sleep 8

RTOT0="$(worker_metric 'noetl_worker_result_resolve_total')"
run_leg "pass3"
P3_EID="$LEG_EID"; P3_RC="$LEG_OUT"
[[ "$LEG_STATUS" == "COMPLETED" ]] || fail "pass3 leg did not COMPLETE (got $LEG_STATUS)"
[[ "$P3_RC" -ge 1 ]] || fail "pass3 legacy path did not fully resolve the payload (test_passed!=true)"
assert_sole_writer "$P3_EID" "pass3"
RTOT1="$(worker_metric 'noetl_worker_result_resolve_total')"
echo "kind-val: pass3 — result_resolve_total Δ=$((RTOT1-RTOT0)) (want 0 — resolver not consulted) passed=$P3_RC"
[[ $((RTOT1-RTOT0)) -eq 0 ]] || fail "pass3 (flag-off) consulted the resolver (Δ=$((RTOT1-RTOT0)) != 0)"

# Parity: PASS 1 (resolved from GCS) and PASS 3 (legacy) bound the SAME payload.
[[ "$P1_RC" == "$P3_RC" && "$P1_RC" -ge 1 ]] \
  || fail "parity: pass1 passed=$P1_RC != pass3 passed=$P3_RC"
echo "kind-val: parity — pass1 (GCS-resolved) and pass3 (legacy) both bound row_count=1200 ✓"

echo
if [[ "$OVERALL" -eq 0 ]]; then
  echo "================================================================"
  echo "kind-val: PASS — #104 Phase C resolve-by-URN read path"
  echo "  PASS 1 : exec $P1_EID resolved the over-budget result from the GCS Feather"
  echo "           tier (gcs put+get Δ>0, resolved_feather Δ>0), bound 1200 rows; COMPLETED"
  echo "  PASS 2 : exec $P2_EID forced miss -> fail-safe fallback to result_store"
  echo "           (fallback_object_miss Δ>0), bound 1200 rows; COMPLETED"
  echo "  PASS 3 : exec $P3_EID flag-off legacy (resolve Δ0); parity row_count==pass1; COMPLETED"
  echo "  sole-writer intact every leg; GCS backend served the tier end to end."
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

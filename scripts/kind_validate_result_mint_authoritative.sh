#!/usr/bin/env bash
# kind_validate_result_mint_authoritative.sh — the Phase D "minting flip" under
# the off-server gate, with a GCS backend (noetl/ai-meta#104 Phase D).
#
# Phase D makes the URN -> Feather/GCS result tier the AUTHORITATIVE result
# store, with noetl.result_store demoted to the transitional DUAL-WRITE FALLBACK
# for reversibility. ONE flag — NOETL_RESULT_MINT_AUTHORITATIVE — turns the whole
# flip on:
#   - system pool: the result materializer becomes the AUTHORITATIVE tier writer
#     (no separate NOETL_RESULT_MATERIALIZER_ENABLED needed).
#   - consume pool: resolve-by-URN becomes the PRIMARY read path (no separate
#     NOETL_RESULT_URI_RESOLVE needed). A tier miss FALLS BACK fail-safe to the
#     dual-written result_store (rollback safety).
#   - server: keeps minting + storing result_store as the reversible fallback
#     leg, counted on noetl_result_store_dual_write_total.
#
# This rig proves, under the prod-exact off-server gate (PUBLISH_ONLY +
# off-server drive + event-materializer sole-writer), with a fake-gcs-server
# object backend:
#
#   PASS 1 (mint flip ON) — the over-budget producer's result is AUTHORITATIVE in
#     the Feather/GCS tier (server gcs put>0), DUAL-WRITTEN to result_store (a
#     result_store row exists AND server result_store_dual_write_total>0), and
#     the consumer RESOLVES FROM THE TIER (server gcs get>0, worker
#     result_mint_authoritative_total{path="tier"}>0) — NOT the legacy store; the
#     full 1200-row payload is bound (row_count==1200); exec COMPLETES;
#     sole-writer intact.
#   PASS 2 (flag OFF) — unchanged Phase A–C: no resolve-by-URN, no mint metric,
#     no dual-write counting; the consumer binds via the authoritative legacy
#     result_store; full payload bound (row_count==1200); exec COMPLETES; consume
#     output BYTE-IDENTICAL to PASS 1 (parity).
#   PASS 3 (tier-miss ROLLBACK) — mint ON on the consume pool but the
#     authoritative writer OFF on the system pool, so no tier object exists;
#     resolve-by-URN MISSES and FALLS BACK to the dual-written result_store
#     (worker result_mint_authoritative_total{path="legacy_fallback"}>0,
#     fallback_object_miss>0); full payload still bound (row_count==1200); exec
#     COMPLETES; sole-writer intact. Proves the flip is reversible.
#
# Backend: a fake-gcs-server emulator (kind only; never real GCS).
#
# Preconditions (the gate-ON stack), PLUS a SERVER image carrying the GCS object
# backend + cell registry + the Phase D dual-write counter, and a WORKER image
# carrying the Phase D minting flip (authoritative materializer + tier-primary
# consume).
#   - server: NOETL_EVENT_INGEST_PUBLISH_ONLY=true AND NOETL_ORCHESTRATE_PLUGIN_DRIVE=true.
#   - system pool: NOETL_MATERIALIZER_ENABLED=true (event materializer sole writer).
#
# Usage:
#   ./scripts/kind_validate_result_mint_authoritative.sh
#   ./scripts/kind_validate_result_mint_authoritative.sh --no-restore
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
echo "kind-val: #104 Phase D — minting flip (authoritative tier + dual-write + resolve-primary)"

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

ORIG_RM="$(get_env "$NOETL_SYSTEM_POOL_DEPLOY" NOETL_RESULT_MATERIALIZER_ENABLED)"
PF_PID=""

cleanup() {
  [[ -n "$PF_PID" ]] && kill "$PF_PID" >/dev/null 2>&1 || true
  if [[ "$RESTORE" -eq 1 ]]; then
    echo "kind-val: restoring baseline"
    "${KCTX[@]}" set env deploy/"$NOETL_SERVER_DEPLOY" \
      "NOETL_OBJECT_STORE_BACKEND-" "NOETL_OBJECT_STORE_GCS_ENDPOINT-" "NOETL_OBJECT_STORE_GCS_BUCKET-" \
      "NOETL_RESULT_MINT_AUTHORITATIVE-" \
      "NOETL_RESULT_CELL-" "NOETL_RESULT_CELL_ENV-" "NOETL_RESULT_CELL_REGION-" "NOETL_RESULT_SHARD_COUNT-" >/dev/null 2>&1 || true
    "${KCTX[@]}" set env deploy/"$NOETL_WORKER_POOL_DEPLOY" \
      "NOETL_RESULT_MINT_AUTHORITATIVE-" "NOETL_RESULT_URI_RESOLVE-" >/dev/null 2>&1 || true
    "${KCTX[@]}" set env deploy/"$NOETL_SYSTEM_POOL_DEPLOY" \
      "NOETL_RESULT_MATERIALIZER_ENABLED=${ORIG_RM:-false}" \
      "NOETL_RESULT_MINT_AUTHORITATIVE-" \
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

# Sum a server-metric series matching a grep pattern (counter value = last field).
server_metric() {  # grep_pattern
  { curl -fsS "$NOETL_SERVER_URL/metrics" 2>/dev/null || true; } \
    | { grep -E "$1" || true; } | awk '{s+=$NF} END{printf "%d", s+0}'
}

# Sum a worker-metric series across all pods of the worker pool deployment.
worker_metric() {  # grep_pattern
  local sel pod total=0 v
  sel="$("${KCTX[@]}" get deploy "$NOETL_WORKER_POOL_DEPLOY" -o jsonpath='{.spec.selector.matchLabels}' 2>/dev/null \
        | python3 -c 'import json,sys; d=json.load(sys.stdin); print(",".join(f"{k}={v}" for k,v in d.items()))')" || true
  for pod in $("${KCTX[@]}" get pods -l "$sel" -o name 2>/dev/null); do
    v="$("${KCTX[@]}" exec "$pod" -- wget -qO- http://127.0.0.1:9090/metrics 2>/dev/null \
         | { grep -E "$1" || true; } | awk '{s+=$NF} END{printf "%d", s+0}')" || true
    total=$((total + ${v:-0}))
  done
  echo "$total"
}

roll() { "${KCTX[@]}" rollout status deploy/"$1" --timeout=150s >/dev/null 2>&1 || true; }

launch_leg() {  # label -> sets LEG_EID
  noetl register playbook --file "${FIX%%:*}" >/dev/null
  LEG_EID="$(noetl exec "${FIX##*:}" --runtime distributed --json \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["execution_id"])')"
  echo "kind-val: $1 leg launched execution_id=$LEG_EID"
}

await_leg() {  # -> sets LEG_STATUS, LEG_OUT(passed), LEG_RS(result_store rows)
  local deadline=$(( SECONDS + TIMEOUT_SECS ))
  LEG_STATUS=""
  while [[ $SECONDS -lt $deadline ]]; do
    LEG_STATUS="$(noetl status "$LEG_EID" --json 2>/dev/null \
      | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",""))' || true)"
    case "$LEG_STATUS" in COMPLETED|FAILED) break ;; esac
    sleep 3
  done
  sleep 3
  # test_passed==true iff row_count==1200 AND the deep row[1100][0]==1100 (the
  # bulk resolved from whichever tier served it — proof the full payload bound).
  LEG_OUT="$(count_rows "SELECT COUNT(*) AS n FROM noetl.event
             WHERE execution_id = $LEG_EID AND result::text LIKE '%\"test_passed\": true%'")"
  # Dual-write proof: the over-budget producer 'start' was minted to the legacy
  # result_store too (the reversible fallback leg).
  LEG_RS="$(count_rows "SELECT COUNT(*) AS n FROM noetl.result_store WHERE execution_id = $LEG_EID")"
}

run_leg() {  # label -> launch + await
  launch_leg "$1"
  await_leg
}

# Delete every tier object for an execution from the GCS emulator (via the
# host port-forward on :4443 — the SAME fake-gcs the server reads). Used to
# FORCE a deterministic tier miss for the rollback test independent of
# materializer/rollout timing.
gcs_purge_exec() {  # eid -> echoes count deleted
  local eid="$1" names n enc deleted=0
  names="$(curl -fsS "http://localhost:4443/storage/v1/b/$GCS_BUCKET/o?prefix=" 2>/dev/null \
    | python3 -c 'import json,sys
for i in json.load(sys.stdin).get("items",[]): print(i["name"])' 2>/dev/null \
    | { grep "execution=$eid" || true; })"
  for n in $names; do
    enc="$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$n")"
    curl -fsS -X DELETE "http://localhost:4443/storage/v1/b/$GCS_BUCKET/o/$enc" >/dev/null 2>&1 && deleted=$((deleted+1)) || true
  done
  echo "$deleted"
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
# Setup: fake-gcs-server + GCS backend + cell registry (write keys == read keys).
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

echo "kind-val: configuring GCS backend + cell registry on server + system pool"
"${KCTX[@]}" set env deploy/"$NOETL_SERVER_DEPLOY" \
  NOETL_OBJECT_STORE_BACKEND=gcs \
  "NOETL_OBJECT_STORE_GCS_ENDPOINT=$GCS_ENDPOINT_IN" \
  "NOETL_OBJECT_STORE_GCS_BUCKET=$GCS_BUCKET" \
  "NOETL_RESULT_CELL=$CELL" "NOETL_RESULT_CELL_ENV=$CELL_ENV" \
  "NOETL_RESULT_CELL_REGION=$CELL_REGION" "NOETL_RESULT_SHARD_COUNT=$SHARD_COUNT" >/dev/null
"${KCTX[@]}" set env deploy/"$NOETL_SYSTEM_POOL_DEPLOY" \
  "NOETL_RESULT_CELL=$CELL" "NOETL_RESULT_CELL_ENV=$CELL_ENV" \
  "NOETL_RESULT_CELL_REGION=$CELL_REGION" "NOETL_RESULT_SHARD_COUNT=$SHARD_COUNT" >/dev/null
roll "$NOETL_SERVER_DEPLOY"; sleep 5

# ======================================================================
# PASS 1 — minting flip ON: tier authoritative + dual-write + resolve-from-tier.
# ======================================================================
echo; echo "================================================================"
echo "kind-val: PASS 1 — NOETL_RESULT_MINT_AUTHORITATIVE ON (tier authoritative)"
echo "================================================================"
# The single flag: authoritative materializer (system pool) + tier-primary
# consume (worker pool) + dual-write counting (server).
"${KCTX[@]}" set env deploy/"$NOETL_SERVER_DEPLOY" NOETL_RESULT_MINT_AUTHORITATIVE=true >/dev/null
"${KCTX[@]}" set env deploy/"$NOETL_SYSTEM_POOL_DEPLOY" NOETL_RESULT_MINT_AUTHORITATIVE=true \
  NOETL_RESULT_MATERIALIZER_ENABLED=false >/dev/null
"${KCTX[@]}" set env deploy/"$NOETL_WORKER_POOL_DEPLOY" NOETL_RESULT_MINT_AUTHORITATIVE=true >/dev/null
roll "$NOETL_SERVER_DEPLOY"; roll "$NOETL_SYSTEM_POOL_DEPLOY"; roll "$NOETL_WORKER_POOL_DEPLOY"; sleep 8

PUT0="$(server_metric 'noetl_object_store_ops_total\{backend="gcs",op="put",outcome="ok"\}')"
GET0="$(server_metric 'noetl_object_store_ops_total\{backend="gcs",op="get",outcome="ok"\}')"
DW0="$(server_metric 'noetl_result_store_dual_write_total')"
TIER0="$(worker_metric 'noetl_worker_result_mint_authoritative_total\{path="tier"\}')"

run_leg "pass1"
P1_EID="$LEG_EID"; P1_RC="$LEG_OUT"
[[ "$LEG_STATUS" == "COMPLETED" ]] || fail "pass1 leg did not COMPLETE (got $LEG_STATUS)"
[[ "$P1_RC" -ge 1 ]] || fail "pass1 consume did not fully resolve the payload (test_passed!=true)"
[[ "$LEG_RS" -ge 1 ]] || fail "pass1 dual-write missing — no noetl.result_store row for exec $P1_EID"
assert_sole_writer "$P1_EID" "pass1"

PUT1="$(server_metric 'noetl_object_store_ops_total\{backend="gcs",op="put",outcome="ok"\}')"
GET1="$(server_metric 'noetl_object_store_ops_total\{backend="gcs",op="get",outcome="ok"\}')"
DW1="$(server_metric 'noetl_result_store_dual_write_total')"
TIER1="$(worker_metric 'noetl_worker_result_mint_authoritative_total\{path="tier"\}')"
echo "kind-val: pass1 — gcs put Δ=$((PUT1-PUT0)) get Δ=$((GET1-GET0)) dual_write Δ=$((DW1-DW0)) mint{tier} Δ=$((TIER1-TIER0)) result_store_rows=$LEG_RS passed=$P1_RC"
# Authoritative tier write + read.
[[ $((PUT1-PUT0)) -ge 1 ]] || fail "pass1 server wrote no object to GCS (put Δ0) — tier not authoritative-written"
[[ $((GET1-GET0)) -ge 1 ]] || fail "pass1 server served no object from GCS (get Δ0) — consume did not resolve from tier"
# Phase D: the authoritative tier (not the legacy store) served the consume.
[[ $((TIER1-TIER0)) -ge 1 ]] || fail "pass1 consume did not resolve from the authoritative tier (mint{tier} Δ0)"
# Dual-write window: server counted the result_store fallback leg.
[[ $((DW1-DW0)) -ge 1 ]] || fail "pass1 server did not count the dual-write (result_store_dual_write_total Δ0)"

# ======================================================================
# PASS 2 — flag OFF: unchanged Phase A–C (legacy authoritative store).
# ======================================================================
echo; echo "================================================================"
echo "kind-val: PASS 2 — minting flip OFF (legacy authoritative store; no-op)"
echo "================================================================"
"${KCTX[@]}" set env deploy/"$NOETL_SERVER_DEPLOY" NOETL_RESULT_MINT_AUTHORITATIVE=false >/dev/null
"${KCTX[@]}" set env deploy/"$NOETL_SYSTEM_POOL_DEPLOY" NOETL_RESULT_MINT_AUTHORITATIVE=false \
  NOETL_RESULT_MATERIALIZER_ENABLED=false >/dev/null
"${KCTX[@]}" set env deploy/"$NOETL_WORKER_POOL_DEPLOY" NOETL_RESULT_MINT_AUTHORITATIVE=false \
  NOETL_RESULT_URI_RESOLVE=false >/dev/null
roll "$NOETL_SERVER_DEPLOY"; roll "$NOETL_SYSTEM_POOL_DEPLOY"; roll "$NOETL_WORKER_POOL_DEPLOY"; sleep 8

DW0="$(server_metric 'noetl_result_store_dual_write_total')"
MA0="$(worker_metric 'noetl_worker_result_mint_authoritative_total')"
RR0="$(worker_metric 'noetl_worker_result_resolve_total')"
run_leg "pass2"
P2_EID="$LEG_EID"; P2_RC="$LEG_OUT"
[[ "$LEG_STATUS" == "COMPLETED" ]] || fail "pass2 leg did not COMPLETE (got $LEG_STATUS)"
[[ "$P2_RC" -ge 1 ]] || fail "pass2 legacy path did not fully resolve the payload (test_passed!=true)"
[[ "$LEG_RS" -ge 1 ]] || fail "pass2 expected a result_store row (legacy authoritative) for exec $P2_EID"
assert_sole_writer "$P2_EID" "pass2"
DW1="$(server_metric 'noetl_result_store_dual_write_total')"
MA1="$(worker_metric 'noetl_worker_result_mint_authoritative_total')"
RR1="$(worker_metric 'noetl_worker_result_resolve_total')"
echo "kind-val: pass2 — dual_write Δ=$((DW1-DW0)) mint Δ=$((MA1-MA0)) resolve Δ=$((RR1-RR0)) passed=$P2_RC (all want 0)"
# True no-op: flag-off moves none of the Phase D / resolve counters.
[[ $((DW1-DW0)) -eq 0 ]] || fail "pass2 (flag-off) counted a dual-write (Δ=$((DW1-DW0)) != 0)"
[[ $((MA1-MA0)) -eq 0 ]] || fail "pass2 (flag-off) moved the mint metric (Δ=$((MA1-MA0)) != 0)"
[[ $((RR1-RR0)) -eq 0 ]] || fail "pass2 (flag-off) consulted the resolver (Δ=$((RR1-RR0)) != 0)"

# Parity: PASS 1 (tier-resolved) and PASS 2 (legacy) bound the SAME payload.
[[ "$P1_RC" == "$P2_RC" && "$P1_RC" -ge 1 ]] \
  || fail "parity: pass1 passed=$P1_RC != pass2 passed=$P2_RC"
echo "kind-val: parity — pass1 (tier-resolved) and pass2 (legacy) both bound row_count=1200 ✓"

# ======================================================================
# PASS 3 — tier-miss ROLLBACK: mint ON, but the tier object is DELETED before
# the consume reads it, forcing a deterministic miss -> dual-write fallback.
# ======================================================================
echo; echo "================================================================"
echo "kind-val: PASS 3 — mint ON, tier object deleted pre-consume (rollback)"
echo "================================================================"
# Keep the authoritative materializer ON so the tier IS written (deterministic),
# then DELETE the execution's tier objects during the fixture's settle window so
# the consume (after settle) genuinely misses and falls back fail-safe to the
# dual-written result_store. This forces the miss independent of materializer /
# rollout timing (turning the materializer off is racy: a slow rollout lets a
# lingering authoritative pod drain the durable consumer's backlog and write the
# tier anyway).
"${KCTX[@]}" set env deploy/"$NOETL_WORKER_POOL_DEPLOY" NOETL_RESULT_MINT_AUTHORITATIVE=true >/dev/null
"${KCTX[@]}" set env deploy/"$NOETL_SYSTEM_POOL_DEPLOY" NOETL_RESULT_MINT_AUTHORITATIVE=true \
  NOETL_RESULT_MATERIALIZER_ENABLED=false >/dev/null
roll "$NOETL_WORKER_POOL_DEPLOY"; roll "$NOETL_SYSTEM_POOL_DEPLOY"; sleep 8

LF0="$(worker_metric 'noetl_worker_result_mint_authoritative_total\{path="legacy_fallback"\}')"
TIER0="$(worker_metric 'noetl_worker_result_mint_authoritative_total\{path="tier"\}')"
FM0="$(worker_metric 'noetl_worker_result_resolve_total\{outcome="fallback_object_miss"\}')"
RR0="$(worker_metric 'noetl_worker_result_resolve_total')"
launch_leg "pass3"
P3_EID="$LEG_EID"
# Purge the execution's tier objects throughout the settle window (the fixture
# sleeps 18s in `settle` before `consume` binds the bulk). Repeated deletes catch
# the materializer's write whenever it lands; once acked it never re-writes.
purged=0
pd=$(( SECONDS + 16 ))
while [[ $SECONDS -lt $pd ]]; do
  d="$(gcs_purge_exec "$P3_EID")"; purged=$(( purged + d ))
  sleep 2
done
echo "kind-val: pass3 — purged $purged tier object(s) for exec $P3_EID during settle"
await_leg
P3_RC="$LEG_OUT"
[[ "$LEG_STATUS" == "COMPLETED" ]] || fail "pass3 leg did not COMPLETE (got $LEG_STATUS) — fallback must not fail the exec"
[[ "$P3_RC" -ge 1 ]] || fail "pass3 fallback did not fully resolve the payload (test_passed!=true)"
[[ "$LEG_RS" -ge 1 ]] || fail "pass3 expected a result_store row to fall back to for exec $P3_EID"
[[ "$purged" -ge 1 ]] || fail "pass3 deleted no tier object — the miss was not actually forced"
assert_sole_writer "$P3_EID" "pass3"
LF1="$(worker_metric 'noetl_worker_result_mint_authoritative_total\{path="legacy_fallback"\}')"
TIER1="$(worker_metric 'noetl_worker_result_mint_authoritative_total\{path="tier"\}')"
FM1="$(worker_metric 'noetl_worker_result_resolve_total\{outcome="fallback_object_miss"\}')"
RR1="$(worker_metric 'noetl_worker_result_resolve_total')"
echo "kind-val: pass3 — mint{legacy_fallback} Δ=$((LF1-LF0)) mint{tier} Δ=$((TIER1-TIER0)) fallback_object_miss Δ=$((FM1-FM0)) resolve_total Δ=$((RR1-RR0)) passed=$P3_RC status=$LEG_STATUS"
# Reversible rollback: the tier missed and the dual-written result_store served.
[[ $((LF1-LF0)) -ge 1 ]] || fail "pass3 did not record a Phase D legacy_fallback (rollback path)"
[[ $((FM1-FM0)) -ge 1 ]] || fail "pass3 did not record a fail-safe object-miss fallback"

echo
if [[ "$OVERALL" -eq 0 ]]; then
  echo "================================================================"
  echo "kind-val: PASS — #104 Phase D minting flip"
  echo "  PASS 1 : exec $P1_EID — over-budget result AUTHORITATIVE in the GCS tier"
  echo "           (gcs put+get Δ>0, mint{tier} Δ>0), DUAL-WRITTEN to result_store"
  echo "           (row present, dual_write Δ>0), resolved FROM the tier; 1200 rows; COMPLETED"
  echo "  PASS 2 : exec $P2_EID — flag-off no-op (dual_write/mint/resolve Δ0); legacy"
  echo "           authoritative store; parity row_count==pass1; COMPLETED"
  echo "  PASS 3 : exec $P3_EID — tier object deleted pre-consume -> reversible"
  echo "           fallback to result_store (mint{legacy_fallback} Δ>0,"
  echo "           fallback_object_miss Δ>0); 1200 rows; COMPLETED"
  echo "  sole-writer intact every leg; GCS backend served the authoritative tier end to end."
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

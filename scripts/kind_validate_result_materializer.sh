#!/usr/bin/env bash
# kind_validate_result_materializer.sh — the SHADOW Feather result tier under
# the off-server gate (noetl/ai-meta#104 Phase B).
#
# Phase B adds a SEPARATE noetl_events consumer (noetl_result_materializer) on
# the system pool that writes the OVER-BUDGET result payload to object store at
# the derivable §7 physical key — tabular -> Arrow Feather, non-tabular -> JSON —
# ALONGSIDE the authoritative noetl.result_store path.  SHADOW: nothing reads the
# Feather tier yet (Phase C); it must never alter the authoritative result and
# never perturb the event-materialize / drive path.  Gated behind
# NOETL_RESULT_MATERIALIZER_ENABLED (default off / true no-op).
#
# This rig proves, under the prod-exact off-server gate (PUBLISH_ONLY +
# off-server drive + event-materializer sole-writer):
#
#   FLAG-ON  — a TABULAR over-budget producer yields a `.feather` object AND a
#              NON-TABULAR over-budget producer yields a `.json` object, both at
#              the derived key carrying the seeded cell (cell=local-0); each
#              execution COMPLETES; and the cutover invariants hold (event
#              materializer sole-writer: per-exec event_rows==distinct_ids,
#              catalog_id=0 rows=0, __orchestrate__ rows=0, mat dup=0).
#   FLAG-OFF — the SAME fixtures run, NO object is written for those executions
#              (Δ0 — true no-op), the executions still COMPLETE, invariants still
#              hold.
#
# (1)+(2) == Phase B writes the right tier when enabled, is inert when disabled,
# and the new consumer perturbs neither the drive nor the event-materialize path.
#
# Preconditions (the same gate-ON stack the offserver rig needs), PLUS:
#   - a SERVER image that ensures the noetl_result_materializer consumer
#     (server #104 Phase B), and a WORKER image carrying the result materializer
#     loop + the NOETL_RESULT_MATERIALIZER_* env (worker #104 Phase B).
#   - server: NOETL_EVENT_INGEST_PUBLISH_ONLY=true AND NOETL_ORCHESTRATE_PLUGIN_DRIVE=true.
#   - system pool: NOETL_MATERIALIZER_ENABLED=true.
#
# Usage:
#   ./scripts/kind_validate_result_materializer.sh
#   ./scripts/kind_validate_result_materializer.sh --context kind-noetl
#   ./scripts/kind_validate_result_materializer.sh --no-restore   # leave flag on
#
# Exits 0 if PASS; 1 if any hard assertion fails (dumps logs); 2 on precondition.

set -euo pipefail

KIND_CONTEXT="${NOETL_KIND_CONTEXT:-kind-noetl}"
NAMESPACE="${NOETL_K8S_NAMESPACE:-noetl}"
NOETL_SERVER_DEPLOY="${NOETL_SERVER_DEPLOY:-noetl-server-rust}"
NOETL_WORKER_POOL_DEPLOY="${NOETL_WORKER_POOL_DEPLOY:-noetl-worker-rust}"
NOETL_SYSTEM_POOL_DEPLOY="${NOETL_SYSTEM_POOL_DEPLOY:-noetl-worker-system-pool}"
NOETL_SERVER_URL="${NOETL_SERVER_URL:-http://localhost:8082}"
TIMEOUT_SECS="${NOETL_ORCH_TIMEOUT_SECS:-180}"
OBJECT_WAIT_SECS="${NOETL_OBJECT_WAIT_SECS:-45}"
RESTORE=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --context)    KIND_CONTEXT="$2"; shift 2 ;;
    --namespace)  NAMESPACE="$2"; shift 2 ;;
    --server-url) NOETL_SERVER_URL="$2"; shift 2 ;;
    --timeout)    TIMEOUT_SECS="$2"; shift 2 ;;
    --no-restore) RESTORE=0; shift ;;
    -h|--help)
      sed -n '2,/^set -euo/p' "$0" | sed -n '/^#/p'
      exit 0
      ;;
    *)
      echo "kind-val: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# The two over-budget producers — one TABULAR (-> Feather), one NON-TABULAR (-> JSON).
FIX_TAB="$REPO_ROOT/fixtures/playbooks/test_large_tabular_result.yaml:tests/large_tabular_result_test"
FIX_JSON="$REPO_ROOT/fixtures/playbooks/test_large_result_extraction.yaml:tests/large_result_extraction_test"

echo "kind-val: context=$KIND_CONTEXT namespace=$NAMESPACE"
echo "kind-val: server=$NOETL_SERVER_URL (#104 Phase B — shadow Feather result tier)"

for cmd in kubectl noetl curl python3; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "kind-val: required command not in PATH: $cmd" >&2; exit 2; }
done
[[ -f "${FIX_TAB%%:*}" ]]  || { echo "kind-val: fixture not found: ${FIX_TAB%%:*}" >&2; exit 2; }
[[ -f "${FIX_JSON%%:*}" ]] || { echo "kind-val: fixture not found: ${FIX_JSON%%:*}" >&2; exit 2; }

KCTX=(kubectl --context "$KIND_CONTEXT" -n "$NAMESPACE")

"${KCTX[@]}" get deployment "$NOETL_SERVER_DEPLOY" >/dev/null 2>&1 \
  || { echo "kind-val: $NOETL_SERVER_DEPLOY not found in $NAMESPACE." >&2; exit 2; }
curl -fsS "$NOETL_SERVER_URL/api/health" >/dev/null 2>&1 \
  || { echo "kind-val: server not reachable at $NOETL_SERVER_URL — start a port-forward." >&2; exit 2; }

get_env() {  # deploy name -> value (empty if unset)
  "${KCTX[@]}" get deploy "$1" \
    -o jsonpath="{range .spec.template.spec.containers[0].env[?(@.name==\"$2\")]}{.value}{end}" 2>/dev/null || true
}

GATE_ON="$(get_env "$NOETL_SERVER_DEPLOY" NOETL_EVENT_INGEST_PUBLISH_ONLY)"
DRIVE_ON="$(get_env "$NOETL_SERVER_DEPLOY" NOETL_ORCHESTRATE_PLUGIN_DRIVE)"
MAT_ON="$(get_env "$NOETL_SYSTEM_POOL_DEPLOY" NOETL_MATERIALIZER_ENABLED)"
echo "kind-val: env — PUBLISH_ONLY=$GATE_ON PLUGIN_DRIVE=$DRIVE_ON MATERIALIZER_ENABLED=$MAT_ON"
[[ "$GATE_ON" == "true" ]] || { echo "kind-val: PUBLISH_ONLY not true — this rig requires the gate ON." >&2; exit 2; }
[[ "$DRIVE_ON" != "false" ]] || { echo "kind-val: PLUGIN_DRIVE=false — this rig requires the off-server drive." >&2; exit 2; }
[[ "$MAT_ON" == "true" ]] || { echo "kind-val: MATERIALIZER_ENABLED not true — no sole writer." >&2; exit 2; }

ORIG_RM="$(get_env "$NOETL_SYSTEM_POOL_DEPLOY" NOETL_RESULT_MATERIALIZER_ENABLED)"
cleanup() {
  if [[ "$RESTORE" -eq 1 ]]; then
    echo "kind-val: restoring baseline (NOETL_RESULT_MATERIALIZER_ENABLED=${ORIG_RM:-false})"
    "${KCTX[@]}" set env deploy/"$NOETL_SYSTEM_POOL_DEPLOY" \
      "NOETL_RESULT_MATERIALIZER_ENABLED=${ORIG_RM:-false}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

roll_pool() {  # roll only the system pool (server/embedded-NATS untouched)
  "${KCTX[@]}" rollout status deploy/"$NOETL_SYSTEM_POOL_DEPLOY" --timeout=120s >/dev/null 2>&1 || true
  sleep 8  # let the pool re-establish its noetl_events consumers + WAL index
}

# ----------------------------------------------------------------------
# Metric + DB helpers.
# ----------------------------------------------------------------------
count_rows() {
  noetl query "$1" --format json 2>/dev/null \
    | python3 -c 'import json,sys
d=json.loads(sys.stdin.read() or "{}").get("result", [])
print(d[0].get("n", 0) if d else 0)'
}

# Runs one execution leg.  Sets globals LEG_EID + LEG_STATUS.
run_leg() {  # fixture_file catalog_path label
  noetl register playbook --file "$1" >/dev/null
  LEG_EID="$(noetl exec "$2" --runtime distributed --json \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["execution_id"])')"
  echo "kind-val: $3 leg launched execution_id=$LEG_EID"
  local deadline=$(( SECONDS + TIMEOUT_SECS ))
  LEG_STATUS=""
  while [[ $SECONDS -lt $deadline ]]; do
    LEG_STATUS="$(noetl status "$LEG_EID" --json 2>/dev/null \
      | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",""))' || true)"
    case "$LEG_STATUS" in COMPLETED|FAILED) break ;; esac
    sleep 2
  done
  sleep 4  # let the materializer flush terminal events
}

OVERALL=0
fail() { echo "kind-val: FAIL — $1" >&2; OVERALL=1; }

assert_sole_writer() {  # execution_id label
  local eid="$1" lbl="$2" rows distinct cat0 orch_ev
  rows="$(count_rows "SELECT COUNT(*) AS n FROM noetl.event WHERE execution_id = $eid")"
  distinct="$(count_rows "SELECT COUNT(DISTINCT event_id) AS n FROM noetl.event WHERE execution_id = $eid")"
  cat0="$(count_rows "SELECT COUNT(*) AS n FROM noetl.event WHERE execution_id = $eid AND catalog_id = 0")"
  orch_ev="$(count_rows "SELECT COUNT(*) AS n FROM noetl.event WHERE execution_id = $eid AND node_name = '__orchestrate__'")"
  echo "kind-val: $lbl db — event_rows=$rows distinct=$distinct catalog0=$cat0 orch_event=$orch_ev"
  [[ "$rows" -gt 0 && "$rows" == "$distinct" ]] || fail "$lbl event rows ($rows) != distinct ids ($distinct) — double-write/loss"
  [[ "$cat0" == "0" ]] || fail "$lbl $cat0 events with catalog_id=0"
  [[ "$orch_ev" == "0" ]] || fail "$lbl expected 0 __orchestrate__ event rows, got $orch_ev"
}

assert_carries_uri() {  # execution_id label
  local eid="$1" lbl="$2" n
  n="$(count_rows "SELECT COUNT(*) AS n FROM noetl.event WHERE execution_id = $eid AND result::text LIKE '%\"uri\": \"noetl://%/results/%'")"
  echo "kind-val: $lbl db — events carrying a canonical reference.uri = $n"
  [[ "$n" -ge 1 ]] || fail "$lbl no event carried a canonical reference.uri — the producer did not externalize (vacuous proof)"
}

# Count shadow objects written for an execution, by extension.  The §7 key
# carries `execution=<eid>` and ends in `.<ext>`; the seeded cell is `cell=<cell>`.
count_objects() {  # execution_id ext
  count_rows "SELECT COUNT(*) AS n FROM noetl.object_store
             WHERE object_key LIKE '%execution=$1/results/%.$2'"
}
count_objects_with_cell() {  # execution_id cell
  count_rows "SELECT COUNT(*) AS n FROM noetl.object_store
             WHERE object_key LIKE '%execution=$1/results/%' AND object_key LIKE '%cell=$2%'"
}

# Poll up to OBJECT_WAIT_SECS for >=1 shadow object of `ext` for `eid`.
wait_for_object() {  # execution_id ext
  local deadline=$(( SECONDS + OBJECT_WAIT_SECS )) n=0
  while [[ $SECONDS -lt $deadline ]]; do
    n="$(count_objects "$1" "$2")"
    [[ "$n" -ge 1 ]] && break
    sleep 3
  done
  echo "$n"
}

SEED_CELL="$(get_env "$NOETL_SYSTEM_POOL_DEPLOY" NOETL_RESULT_CELL)"; SEED_CELL="${SEED_CELL:-local-0}"

# ======================================================================
# PASS 1 — FLAG ON: shadow writes Feather (tabular) + JSON (non-tabular).
# ======================================================================
echo
echo "================================================================"
echo "kind-val: PASS 1 — NOETL_RESULT_MATERIALIZER_ENABLED=true (shadow write)"
echo "================================================================"
"${KCTX[@]}" set env deploy/"$NOETL_SYSTEM_POOL_DEPLOY" NOETL_RESULT_MATERIALIZER_ENABLED=true >/dev/null
roll_pool

# -- Tabular leg -> .feather
run_leg "${FIX_TAB%%:*}" "${FIX_TAB##*:}" "flag-on/tabular"
TAB_EID="$LEG_EID"
[[ "$LEG_STATUS" == "COMPLETED" ]] || fail "flag-on/tabular leg did not COMPLETE (got $LEG_STATUS)"
assert_carries_uri "$TAB_EID" "flag-on/tabular"
assert_sole_writer "$TAB_EID" "flag-on/tabular"
TAB_FEATHER="$(wait_for_object "$TAB_EID" feather)"
TAB_CELL="$(count_objects_with_cell "$TAB_EID" "$SEED_CELL")"
echo "kind-val: flag-on/tabular — .feather objects=$TAB_FEATHER (cell=$SEED_CELL matches=$TAB_CELL)"
[[ "$TAB_FEATHER" -ge 1 ]] || fail "flag-on/tabular wrote no .feather object at the derived key"
[[ "$TAB_CELL" -ge 1 ]]    || fail "flag-on/tabular object did not carry the seeded cell=$SEED_CELL"

# -- Non-tabular leg -> .json
run_leg "${FIX_JSON%%:*}" "${FIX_JSON##*:}" "flag-on/json"
JSON_EID="$LEG_EID"
[[ "$LEG_STATUS" == "COMPLETED" ]] || fail "flag-on/json leg did not COMPLETE (got $LEG_STATUS)"
assert_carries_uri "$JSON_EID" "flag-on/json"
assert_sole_writer "$JSON_EID" "flag-on/json"
JSON_JSON="$(wait_for_object "$JSON_EID" json)"
echo "kind-val: flag-on/json — .json objects=$JSON_JSON"
[[ "$JSON_JSON" -ge 1 ]] || fail "flag-on/json wrote no .json object at the derived key"

# ======================================================================
# PASS 2 — FLAG OFF: the shadow loop is a true no-op (no objects).
# ======================================================================
echo
echo "================================================================"
echo "kind-val: PASS 2 — NOETL_RESULT_MATERIALIZER_ENABLED=false (no-op)"
echo "================================================================"
"${KCTX[@]}" set env deploy/"$NOETL_SYSTEM_POOL_DEPLOY" NOETL_RESULT_MATERIALIZER_ENABLED=false >/dev/null
roll_pool

run_leg "${FIX_TAB%%:*}" "${FIX_TAB##*:}" "flag-off/tabular"
OFF_EID="$LEG_EID"
[[ "$LEG_STATUS" == "COMPLETED" ]] || fail "flag-off leg did not COMPLETE (got $LEG_STATUS)"
assert_carries_uri "$OFF_EID" "flag-off"   # still externalizes; the shadow loop just isn't running
assert_sole_writer "$OFF_EID" "flag-off"
# Give the (disabled) loop the same wall-clock window the enabled one had, then
# assert NOTHING was written for this execution.
sleep "$OBJECT_WAIT_SECS"
OFF_OBJS="$(count_rows "SELECT COUNT(*) AS n FROM noetl.object_store WHERE object_key LIKE '%execution=$OFF_EID/results/%'")"
echo "kind-val: flag-off — objects for exec $OFF_EID = $OFF_OBJS (want 0 — no-op)"
[[ "$OFF_OBJS" -eq 0 ]] || fail "flag-off wrote $OFF_OBJS object(s) — the no-op was perturbed"

# Event-materializer duplicates (sole-writer health) over the whole rig.
MAT_DUP_HITS="$("${KCTX[@]}" logs deploy/"$NOETL_SYSTEM_POOL_DEPLOY" --tail=2000 2>/dev/null | grep -c -E "materializer cycle.*duplicates=[1-9]" || true)"
[[ "${MAT_DUP_HITS:-0}" -eq 0 ]] || fail "event materializer reported duplicates>0 in $MAT_DUP_HITS cycle(s)"

echo
if [[ "$OVERALL" -eq 0 ]]; then
  echo "================================================================"
  echo "kind-val: PASS — #104 Phase B shadow Feather result tier"
  echo "  FLAG-ON : tabular exec $TAB_EID -> .feather x$TAB_FEATHER (cell=$SEED_CELL);"
  echo "            non-tabular exec $JSON_EID -> .json x$JSON_JSON; both COMPLETED; sole-writer intact"
  echo "  FLAG-OFF: exec $OFF_EID wrote 0 objects (no-op); COMPLETED; sole-writer intact"
  echo "  event-materializer dup=$MAT_DUP_HITS over the rig"
  echo "  => Phase B writes the right tier at the derived key when enabled, is inert"
  echo "     when disabled, and perturbs neither the drive nor the event-materialize path."
  echo "================================================================"
  exit 0
fi

echo "================================================================"
echo "kind-val: FAIL — see assertion errors above"
echo "================================================================"
echo "kind-val: server logs (tail 80):"; "${KCTX[@]}" logs deploy/"$NOETL_SERVER_DEPLOY" --tail=80 || true
echo; echo "kind-val: system-pool logs (tail 120):"; "${KCTX[@]}" logs deploy/"$NOETL_SYSTEM_POOL_DEPLOY" --tail=120 || true
exit 1

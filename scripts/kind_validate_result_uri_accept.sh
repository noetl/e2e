#!/usr/bin/env bash
# kind_validate_result_uri_accept.sh — the canonical-result-URI shadow accept
# under the off-server gate (noetl/ai-meta#104 Phase A).
#
# The worker stamps the stable logical Resource Locator additively on
# over-budget references:
#   reference.uri = noetl://<tenant>/<project>/results/<eid>/<step>/<frame>/<row>/<attempt>
# (#104 R02b).  Phase A makes the SERVER *accept* that canonical URI — parse +
# validate it via the shared noetl_tools::locator — WITHOUT resolving by it
# (Phase C) or writing the Feather tier (Phase B).  It is gated behind
# NOETL_RESULT_URI_ACCEPT (default off); flag-off is a byte-identical no-op.
#
# This rig proves, under the prod-exact off-server gate (PUBLISH_ONLY +
# off-server drive + materializer sole-writer):
#
#   FLAG-ON  — an over-budget producer's event carries reference.uri, and the
#              server's noetl_result_uri_accept_total{outcome="canonical"}
#              advances (the URI was accepted + parsed), the execution COMPLETES,
#              and the cutover invariants hold (sole-writer: per-exec
#              event_rows==distinct_ids, catalog_id=0 rows=0, __orchestrate__
#              rows=0, materializer dup=0).
#   FLAG-OFF — the SAME fixture runs, the accept counter does NOT move (Δ0 —
#              true no-op), the execution still COMPLETES, invariants still hold.
#
# (1)+(2) == Phase A records the canonical URI when enabled and is inert when
# disabled, and neither perturbs the live drive/materialize path.
#
# Preconditions (the same gate-ON stack the offserver rig needs), PLUS a server
# image carrying the Phase-A flag (NOETL_RESULT_URI_ACCEPT + the
# noetl_result_uri_accept_total metric):
#   - server: NOETL_EVENT_INGEST_PUBLISH_ONLY=true AND
#     NOETL_ORCHESTRATE_PLUGIN_DRIVE=true.
#   - system pool: NOETL_MATERIALIZER_ENABLED=true.
#   - the over-budget producer fixture (test_large_result_extraction) registered
#     by the rig (500x200B items > the inline budget => durable reference).
#
# Usage:
#   ./scripts/kind_validate_result_uri_accept.sh
#   ./scripts/kind_validate_result_uri_accept.sh --context kind-noetl
#   ./scripts/kind_validate_result_uri_accept.sh --no-restore   # leave flag on
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

# The over-budget producer — 500x200B items exceed the inline budget, so the
# worker stages the result and stamps reference.uri (the canonical locator).
FIX_BIG="$REPO_ROOT/fixtures/playbooks/test_large_result_extraction.yaml:tests/large_result_extraction_test"

echo "kind-val: context=$KIND_CONTEXT namespace=$NAMESPACE"
echo "kind-val: server=$NOETL_SERVER_URL (#104 Phase A — canonical result-URI shadow accept)"

for cmd in kubectl noetl curl python3; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "kind-val: required command not in PATH: $cmd" >&2; exit 2; }
done
[[ -f "${FIX_BIG%%:*}" ]] || { echo "kind-val: fixture not found: ${FIX_BIG%%:*}" >&2; exit 2; }

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

# Record original + restore on exit.
ORIG_ACCEPT="$(get_env "$NOETL_SERVER_DEPLOY" NOETL_RESULT_URI_ACCEPT)"
cleanup() {
  if [[ "$RESTORE" -eq 1 ]]; then
    echo "kind-val: restoring baseline (NOETL_RESULT_URI_ACCEPT=${ORIG_ACCEPT:-false})"
    "${KCTX[@]}" set env deploy/"$NOETL_SERVER_DEPLOY" \
      "NOETL_RESULT_URI_ACCEPT=${ORIG_ACCEPT:-false}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

roll_server() {  # wait for the server to come back healthy after a set env
  "${KCTX[@]}" rollout status deploy/"$NOETL_SERVER_DEPLOY" --timeout=120s >/dev/null
  local hdl=$(( SECONDS + 60 ))
  until curl -fsS "$NOETL_SERVER_URL/api/health" >/dev/null 2>&1; do
    [[ $SECONDS -lt $hdl ]] || { echo "kind-val: server health not ready after rollout" >&2; break; }
    sleep 2
  done
  # On the kind dev topology NATS is EMBEDDED in the server, so a server pod
  # restart (which any `set env` forces) orphans the workers' JetStream
  # consumers — the off-server state_builder consumer then 503s and the drive
  # wedges on an incomplete WAL chain.  Roll the workers so they re-establish
  # their ephemeral `noetl_events` consumers + WAL index against the fresh
  # embedded NATS.  (No-op cost on a prod topology with external NATS, but this
  # rig targets kind.)
  echo "kind-val: rolling workers to re-establish consumers against the fresh embedded NATS"
  "${KCTX[@]}" rollout restart deploy/"$NOETL_WORKER_POOL_DEPLOY" deploy/"$NOETL_SYSTEM_POOL_DEPLOY" >/dev/null 2>&1 || true
  "${KCTX[@]}" rollout status deploy/"$NOETL_SYSTEM_POOL_DEPLOY" --timeout=120s >/dev/null 2>&1 || true
  "${KCTX[@]}" rollout status deploy/"$NOETL_WORKER_POOL_DEPLOY" --timeout=120s >/dev/null 2>&1 || true
  sleep 10  # let the WAL drain warm its index off the retained stream
}

# ----------------------------------------------------------------------
# Metric + DB helpers.
# ----------------------------------------------------------------------
fetch_server_metrics() { curl -fsS "$NOETL_SERVER_URL/metrics" 2>/dev/null || true; }

metric_label() {  # body metric label_value -> int (sum of matching {…="value"…} samples)
  printf '%s' "$1" | python3 -c '
import re, sys
metric, lab = sys.argv[1], sys.argv[2]; total = 0
pat = re.compile(r"^%s\{[^}]*\b\w+=\"%s\"[^}]*\}\s+([0-9.]+)" % (re.escape(metric), re.escape(lab)))
for line in sys.stdin:
    m = pat.match(line)
    if m: total += int(float(m.group(1)))
print(total)
' "$2" "$3"
}

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
  local eid="$1" lbl="$2"
  local rows distinct cat0 orch_ev
  rows="$(count_rows "SELECT COUNT(*) AS n FROM noetl.event WHERE execution_id = $eid")"
  distinct="$(count_rows "SELECT COUNT(DISTINCT event_id) AS n FROM noetl.event WHERE execution_id = $eid")"
  cat0="$(count_rows "SELECT COUNT(*) AS n FROM noetl.event WHERE execution_id = $eid AND catalog_id = 0")"
  orch_ev="$(count_rows "SELECT COUNT(*) AS n FROM noetl.event WHERE execution_id = $eid AND node_name = '__orchestrate__'")"
  echo "kind-val: $lbl db — event_rows=$rows distinct=$distinct catalog0=$cat0 orch_event=$orch_ev"
  [[ "$rows" -gt 0 && "$rows" == "$distinct" ]] || fail "$lbl event rows ($rows) != distinct ids ($distinct) — double-write/loss"
  [[ "$cat0" == "0" ]] || fail "$lbl $cat0 events with catalog_id=0"
  [[ "$orch_ev" == "0" ]] || fail "$lbl expected 0 __orchestrate__ event rows, got $orch_ev"
}

# Confirms the producer actually externalized — the event carries reference.uri.
# (If it did not, the accept proof would be vacuous regardless of the flag.)
assert_carries_uri() {  # execution_id label
  local eid="$1" lbl="$2" n
  n="$(count_rows "SELECT COUNT(*) AS n FROM noetl.event WHERE execution_id = $eid AND result::text LIKE '%\"uri\": \"noetl://%/results/%'")"
  echo "kind-val: $lbl db — events carrying a canonical reference.uri = $n"
  [[ "$n" -ge 1 ]] || fail "$lbl no event carried a canonical reference.uri — the producer did not externalize (vacuous accept proof)"
}

# ======================================================================
# PASS 1 — FLAG ON: the canonical URI is accepted + counted.
# ======================================================================
echo
echo "================================================================"
echo "kind-val: PASS 1 — NOETL_RESULT_URI_ACCEPT=true (accept + count)"
echo "================================================================"
"${KCTX[@]}" set env deploy/"$NOETL_SERVER_DEPLOY" NOETL_RESULT_URI_ACCEPT=true >/dev/null
roll_server

SM_BEFORE="$(fetch_server_metrics)"
ACC_CANON_BEFORE="$(metric_label "$SM_BEFORE" noetl_result_uri_accept_total canonical)"
ACC_LEGACY_BEFORE="$(metric_label "$SM_BEFORE" noetl_result_uri_accept_total legacy)"
ACC_MAL_BEFORE="$(metric_label "$SM_BEFORE" noetl_result_uri_accept_total malformed)"

run_leg "${FIX_BIG%%:*}" "${FIX_BIG##*:}" "flag-on"
ON_EID="$LEG_EID"; ON_STATUS="$LEG_STATUS"
[[ "$ON_STATUS" == "COMPLETED" ]] || fail "flag-on leg did not COMPLETE (got $ON_STATUS)"
assert_carries_uri "$ON_EID" "flag-on"
assert_sole_writer "$ON_EID" "flag-on"

SM_AFTER="$(fetch_server_metrics)"
ACC_CANON_D=$(( $(metric_label "$SM_AFTER" noetl_result_uri_accept_total canonical) - ACC_CANON_BEFORE ))
ACC_LEGACY_D=$(( $(metric_label "$SM_AFTER" noetl_result_uri_accept_total legacy) - ACC_LEGACY_BEFORE ))
ACC_MAL_D=$(( $(metric_label "$SM_AFTER" noetl_result_uri_accept_total malformed) - ACC_MAL_BEFORE ))
echo "kind-val: flag-on accept deltas — canonical=+$ACC_CANON_D legacy=+$ACC_LEGACY_D malformed=+$ACC_MAL_D (want canonical >=1, malformed 0)"
[[ "$ACC_CANON_D" -ge 1 ]] || fail "accept{canonical} did not advance (+$ACC_CANON_D) — the server did not accept the worker-stamped URI"
[[ "$ACC_MAL_D" -eq 0 ]]   || fail "accept{malformed} advanced (+$ACC_MAL_D) — a well-formed URI failed to parse"

# ======================================================================
# PASS 2 — FLAG OFF: the accept hook is a true no-op (Δ0).
# ======================================================================
echo
echo "================================================================"
echo "kind-val: PASS 2 — NOETL_RESULT_URI_ACCEPT=false (no-op)"
echo "================================================================"
"${KCTX[@]}" set env deploy/"$NOETL_SERVER_DEPLOY" NOETL_RESULT_URI_ACCEPT=false >/dev/null
roll_server

SM2_BEFORE="$(fetch_server_metrics)"
ACC2_BEFORE=$(( $(metric_label "$SM2_BEFORE" noetl_result_uri_accept_total canonical) \
              + $(metric_label "$SM2_BEFORE" noetl_result_uri_accept_total legacy) \
              + $(metric_label "$SM2_BEFORE" noetl_result_uri_accept_total malformed) ))

run_leg "${FIX_BIG%%:*}" "${FIX_BIG##*:}" "flag-off"
OFF_EID="$LEG_EID"; OFF_STATUS="$LEG_STATUS"
[[ "$OFF_STATUS" == "COMPLETED" ]] || fail "flag-off leg did not COMPLETE (got $OFF_STATUS)"
assert_carries_uri "$OFF_EID" "flag-off"   # the producer still externalizes; the server just ignores it
assert_sole_writer "$OFF_EID" "flag-off"

SM2_AFTER="$(fetch_server_metrics)"
ACC2_AFTER=$(( $(metric_label "$SM2_AFTER" noetl_result_uri_accept_total canonical) \
             + $(metric_label "$SM2_AFTER" noetl_result_uri_accept_total legacy) \
             + $(metric_label "$SM2_AFTER" noetl_result_uri_accept_total malformed) ))
ACC2_D=$(( ACC2_AFTER - ACC2_BEFORE ))
echo "kind-val: flag-off accept delta (all outcomes) = +$ACC2_D (want 0 — no-op)"
[[ "$ACC2_D" -eq 0 ]] || fail "accept counter advanced (+$ACC2_D) with the flag OFF — the no-op was perturbed"

# Materializer duplicates (sole-writer health) over the whole rig.
MAT_DUP_HITS="$("${KCTX[@]}" logs deploy/"$NOETL_SYSTEM_POOL_DEPLOY" --tail=1500 2>/dev/null | grep -c -E "materializer cycle.*duplicates=[1-9]" || true)"
[[ "${MAT_DUP_HITS:-0}" -eq 0 ]] || fail "materializer reported duplicates>0 in $MAT_DUP_HITS cycle(s)"

echo
if [[ "$OVERALL" -eq 0 ]]; then
  echo "================================================================"
  echo "kind-val: PASS — #104 Phase A canonical-result-URI shadow accept"
  echo "  FLAG-ON : accept{canonical} +$ACC_CANON_D (legacy +$ACC_LEGACY_D, malformed +$ACC_MAL_D); exec $ON_EID COMPLETED; sole-writer intact"
  echo "  FLAG-OFF: accept delta +$ACC2_D (no-op); exec $OFF_EID COMPLETED; sole-writer intact"
  echo "  materializer dup=$MAT_DUP_HITS over the rig"
  echo "  => Phase A records the canonical URI when enabled, is inert when disabled,"
  echo "     and perturbs neither the drive nor the materialize path."
  echo "================================================================"
  exit 0
fi

echo "================================================================"
echo "kind-val: FAIL — see assertion errors above"
echo "================================================================"
echo "kind-val: server logs (tail 80):"; "${KCTX[@]}" logs deploy/"$NOETL_SERVER_DEPLOY" --tail=80 || true
echo; echo "kind-val: system-pool logs (tail 80):"; "${KCTX[@]}" logs deploy/"$NOETL_SYSTEM_POOL_DEPLOY" --tail=80 || true
exit 1

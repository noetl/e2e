#!/usr/bin/env bash
# kind_validate_state_builder_offserver.sh — the OFF-SERVER state builder drive
# cutover under the CQRS PUBLISH_ONLY gate (noetl/ai-meta#115 Phase 4).
#
# Phase 3 (server#245) moved WorkflowState reconstruction onto a chain walk that
# still ran IN the server. Phase 4 moves CONSTRUCTION off the server onto the
# system worker pool: the worker drains the `noetl_events` WAL into a pool-side
# chain index and builds the drive's WorkflowState from the WAL spine via the
# wasm `run` (from_events) entry — instead of the server building state and
# shipping it to the plug-in's `run_state` entry.
#
# This rig proves the cutover is correct + authoritative under the gate
# (PUBLISH_ONLY + off-server drive + materializer sole-writer):
#
#   A. LIVE-DRIVE PARITY — the same fixture, driven once with
#      NOETL_STATE_BUILDER=offserver and once with =server, reaches the SAME
#      terminal status with the SAME completed-real-step fingerprint (the
#      decisions are identical — parity by construction: both feed the same
#      `from_events`).
#   B. WAL-BUILD AUTHORITATIVE — the worker's
#      `noetl_worker_state_builder_drive_builds_total{outcome="served"}` advanced
#      (the WAL spine, not the server-built state, drove the decision), and
#      `noetl_worker_state_builder_event_scans_total` stayed 0 (the spine came
#      from the WAL, zero noetl.event reads on the worker).
#   C. NO SERVER REBUILD/SCAN ON THE DRIVE PATH — with the server in
#      NOETL_STATE_BUILD_MODE=chain_walk, the server's
#      `noetl_state_build_event_scans_total` delta is 0 (no WHERE execution_id
#      scan of noetl.event drove this run).
#   D. CACHE — the builder's `state_builder_builds_total` shows
#      cold_rebuild/incremental advancing (the pool-side cache is exercised under
#      authoritative use).
#   E. SOLE-WRITER + lag-0 + off-server topology — event_rows == distinct_ids,
#      catalog_id=0 rows = 0, __orchestrate__ event rows = 0 (command >= 1),
#      materializer duplicates = 0.
#
# The rig flips NOETL_STATE_BUILDER=offserver (+ NOETL_STATE_BUILD_MODE=chain_walk
# on the server) for its run and RESTORES the prior values on exit (trap), so it
# does not disturb other sessions' baseline.
#
# Preconditions (same gate-ON stack the orchestrate-gate rig needs):
#   - server: NOETL_EVENT_INGEST_PUBLISH_ONLY=true AND
#     NOETL_ORCHESTRATE_PLUGIN_DRIVE=true, with a v3.34.0+ image (the offserver
#     dispatch marker).
#   - system pool: NOETL_MATERIALIZER_ENABLED=true, with a v5.38.0+ worker (the
#     off-server drive-build path + shared WAL index).
#   - a CLEAN cluster (purge noetl_events, truncate execution-state tables).
#
# Usage:
#   ./scripts/kind_validate_state_builder_offserver.sh
#   ./scripts/kind_validate_state_builder_offserver.sh --context kind-noetl
#   ./scripts/kind_validate_state_builder_offserver.sh --no-restore   # leave offserver on
#
# Exits 0 if PASS; 1 if any hard assertion fails (dumps logs); 2 on precondition.

set -euo pipefail

KIND_CONTEXT="${NOETL_KIND_CONTEXT:-kind-noetl}"
NAMESPACE="${NOETL_K8S_NAMESPACE:-noetl}"
NOETL_SERVER_DEPLOY="${NOETL_SERVER_DEPLOY:-noetl-server-rust}"
NOETL_SYSTEM_POOL_DEPLOY="${NOETL_SYSTEM_POOL_DEPLOY:-noetl-worker-system-pool}"
NOETL_SERVER_URL="${NOETL_SERVER_URL:-http://localhost:8082}"
TIMEOUT_SECS="${NOETL_ORCH_TIMEOUT_SECS:-180}"
WORKER_METRICS_LPORT="${NOETL_WORKER_METRICS_LPORT:-19090}"
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
FIXTURE_PATH="$REPO_ROOT/fixtures/playbooks/fanout_reduce/fanout_reduce_phase6.yaml"
PLAYBOOK_PATH="tests/fixtures/fanout_reduce_phase6"

echo "kind-val: context=$KIND_CONTEXT namespace=$NAMESPACE"
echo "kind-val: server=$NOETL_SERVER_URL (gate-on + off-server state builder)"
echo "kind-val: fixture=$FIXTURE_PATH"

for cmd in kubectl noetl curl python3; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "kind-val: required command not in PATH: $cmd" >&2; exit 2; }
done
[[ -f "$FIXTURE_PATH" ]] || { echo "kind-val: fixture not found: $FIXTURE_PATH" >&2; exit 2; }

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

# Record originals + restore on exit.
ORIG_SB="$(get_env "$NOETL_SYSTEM_POOL_DEPLOY" NOETL_STATE_BUILDER)"
ORIG_SM="$(get_env "$NOETL_SERVER_DEPLOY" NOETL_STATE_BUILD_MODE)"
PF_PID=""
cleanup() {
  [[ -n "$PF_PID" ]] && kill "$PF_PID" >/dev/null 2>&1 || true
  if [[ "$RESTORE" -eq 1 ]]; then
    echo "kind-val: restoring baseline (NOETL_STATE_BUILDER=${ORIG_SB:-server}, NOETL_STATE_BUILD_MODE=${ORIG_SM:-event_scan})"
    "${KCTX[@]}" set env deploy/"$NOETL_SYSTEM_POOL_DEPLOY" "NOETL_STATE_BUILDER=${ORIG_SB:-server}" >/dev/null 2>&1 || true
    "${KCTX[@]}" set env deploy/"$NOETL_SERVER_DEPLOY" "NOETL_STATE_BUILD_MODE=${ORIG_SM:-event_scan}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

set_state_builder() {  # offserver|server
  echo "kind-val: setting NOETL_STATE_BUILDER=$1 (system pool) + NOETL_STATE_BUILD_MODE=chain_walk (server)"
  "${KCTX[@]}" set env deploy/"$NOETL_SYSTEM_POOL_DEPLOY" "NOETL_STATE_BUILDER=$1" >/dev/null
  "${KCTX[@]}" set env deploy/"$NOETL_SERVER_DEPLOY" NOETL_STATE_BUILD_MODE=chain_walk >/dev/null
  "${KCTX[@]}" rollout status deploy/"$NOETL_SYSTEM_POOL_DEPLOY" --timeout=120s >/dev/null
  "${KCTX[@]}" rollout status deploy/"$NOETL_SERVER_DEPLOY" --timeout=120s >/dev/null
  # Let the authoritative WAL drain warm its index off the retained stream.
  sleep 6
}

# ----------------------------------------------------------------------
# Metric + DB helpers.
# ----------------------------------------------------------------------

fetch_server_metrics() { curl -fsS "$NOETL_SERVER_URL/metrics" 2>/dev/null || true; }

start_worker_pf() {
  [[ -n "$PF_PID" ]] && return 0
  "${KCTX[@]}" port-forward deploy/"$NOETL_SYSTEM_POOL_DEPLOY" "$WORKER_METRICS_LPORT:9090" >/dev/null 2>&1 &
  PF_PID=$!
  sleep 2
}
fetch_worker_metrics() { curl -fsS "http://localhost:$WORKER_METRICS_LPORT/metrics" 2>/dev/null || true; }

metric_label() {  # body metric label_value -> int (sum of matching {label="value"} samples)
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

metric_simple() {  # body metric -> int (sum across all label sets / bare)
  printf '%s' "$1" | python3 -c '
import re, sys; metric = sys.argv[1]; total = 0
pat = re.compile(r"^%s(\{[^}]*\})?\s+([0-9.]+)" % re.escape(metric))
for line in sys.stdin:
    m = pat.match(line)
    if m: total += int(float(m.group(2)))
print(total)
' "$2"
}

count_rows() {
  noetl query "$1" --format json 2>/dev/null \
    | python3 -c 'import json,sys
d=json.loads(sys.stdin.read() or "{}").get("result", [])
print(d[0].get("n", 0) if d else 0)'
}

# The decision fingerprint: the sorted multiset of completed REAL steps (drops
# the __orchestrate__ / __* infra steps).  Identical fingerprint across the
# offserver + server legs == identical drive decisions.
fingerprint() {  # execution_id -> canonical string
  noetl query "SELECT node_name AS nn, COUNT(*) AS c FROM noetl.event \
    WHERE execution_id = $1 AND event_type = 'command.completed' \
    AND node_name NOT LIKE '\\_\\_%' GROUP BY node_name ORDER BY node_name" --format json 2>/dev/null \
    | python3 -c 'import json,sys
d=json.loads(sys.stdin.read() or "{}").get("result", [])
print(",".join("%s:%s" % (r.get("nn"), r.get("c")) for r in sorted(d, key=lambda r: str(r.get("nn")))))'
}

run_leg() {  # label -> echoes EXECUTION_ID; sets FINAL_STATUS
  local label="$1"
  noetl register playbook --file "$FIXTURE_PATH" >/dev/null
  local eid
  eid="$(noetl exec "$PLAYBOOK_PATH" --runtime distributed --json \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["execution_id"])')"
  local deadline=$(( SECONDS + TIMEOUT_SECS ))
  FINAL_STATUS=""
  while [[ $SECONDS -lt $deadline ]]; do
    FINAL_STATUS="$(noetl status "$eid" --json 2>/dev/null \
      | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",""))' || true)"
    case "$FINAL_STATUS" in COMPLETED|FAILED) break ;; esac
    sleep 2
  done
  sleep 4  # let the materializer flush terminal events
  echo "$eid"
}

OVERALL=0
fail() { echo "kind-val: FAIL — $1" >&2; OVERALL=1; }

# ======================================================================
# LEG 1 — off-server state builder authoritative.
# ======================================================================
echo
echo "================================================================"
echo "kind-val: LEG 1 — NOETL_STATE_BUILDER=offserver"
echo "================================================================"
set_state_builder offserver
start_worker_pf

SB_SCAN_BEFORE="$(metric_simple "$(fetch_server_metrics)" noetl_state_build_event_scans_total)"
WM_BEFORE="$(fetch_worker_metrics)"
W_SERVED_BEFORE="$(metric_label "$WM_BEFORE" noetl_worker_state_builder_drive_builds_total served)"
W_FB_BEFORE="$(metric_label "$WM_BEFORE" noetl_worker_state_builder_drive_builds_total fallback_incomplete)"
W_SCAN_BEFORE="$(metric_simple "$WM_BEFORE" noetl_worker_state_builder_event_scans_total)"
W_WAL_BEFORE="$(metric_simple "$WM_BEFORE" noetl_worker_state_builder_wal_events_total)"
W_COLD_BEFORE="$(metric_label "$WM_BEFORE" noetl_worker_state_builder_builds_total cold_rebuild)"
W_INCR_BEFORE="$(metric_label "$WM_BEFORE" noetl_worker_state_builder_builds_total incremental)"

OFF_EID="$(run_leg offserver)"; OFF_STATUS="$FINAL_STATUS"
echo "kind-val: offserver leg execution_id=$OFF_EID final_status=$OFF_STATUS"

SB_SCAN_AFTER="$(metric_simple "$(fetch_server_metrics)" noetl_state_build_event_scans_total)"
WM_AFTER="$(fetch_worker_metrics)"
W_SERVED_D=$(( $(metric_label "$WM_AFTER" noetl_worker_state_builder_drive_builds_total served) - W_SERVED_BEFORE ))
W_FB_D=$(( $(metric_label "$WM_AFTER" noetl_worker_state_builder_drive_builds_total fallback_incomplete) - W_FB_BEFORE ))
W_SCAN_D=$(( $(metric_simple "$WM_AFTER" noetl_worker_state_builder_event_scans_total) - W_SCAN_BEFORE ))
W_WAL_D=$(( $(metric_simple "$WM_AFTER" noetl_worker_state_builder_wal_events_total) - W_WAL_BEFORE ))
W_COLD_D=$(( $(metric_label "$WM_AFTER" noetl_worker_state_builder_builds_total cold_rebuild) - W_COLD_BEFORE ))
W_INCR_D=$(( $(metric_label "$WM_AFTER" noetl_worker_state_builder_builds_total incremental) - W_INCR_BEFORE ))
SB_SCAN_D=$(( SB_SCAN_AFTER - SB_SCAN_BEFORE ))
echo "kind-val: worker — drive served=+$W_SERVED_D fallback=+$W_FB_D event_scans=+$W_SCAN_D wal_events=+$W_WAL_D cold=+$W_COLD_D incr=+$W_INCR_D"
echo "kind-val: server — state_build_event_scans=+$SB_SCAN_D (want 0, chain_walk)"

EVENT_ROWS="$(count_rows "SELECT COUNT(*) AS n FROM noetl.event WHERE execution_id = $OFF_EID")"
DISTINCT_IDS="$(count_rows "SELECT COUNT(DISTINCT event_id) AS n FROM noetl.event WHERE execution_id = $OFF_EID")"
CATALOG_ZERO="$(count_rows "SELECT COUNT(*) AS n FROM noetl.event WHERE execution_id = $OFF_EID AND catalog_id = 0")"
ORCH_EVENT_ROWS="$(count_rows "SELECT COUNT(*) AS n FROM noetl.event WHERE execution_id = $OFF_EID AND node_name = '__orchestrate__'")"
ORCH_COMMAND_ROWS="$(count_rows "SELECT COUNT(*) AS n FROM noetl.command WHERE execution_id = $OFF_EID AND step_name = '__orchestrate__'")"
MAT_DUP_HITS="$("${KCTX[@]}" logs deploy/"$NOETL_SYSTEM_POOL_DEPLOY" --tail=800 2>/dev/null | grep -c -E "materializer cycle.*duplicates=[1-9]" || true)"
OFF_FP="$(fingerprint "$OFF_EID")"
echo "kind-val: db — event_rows=$EVENT_ROWS distinct=$DISTINCT_IDS catalog0=$CATALOG_ZERO orch_event=$ORCH_EVENT_ROWS orch_cmd=$ORCH_COMMAND_ROWS dup=$MAT_DUP_HITS"
echo "kind-val: offserver fingerprint = [$OFF_FP]"

# ======================================================================
# LEG 2 — server-built baseline (the parity reference).
# ======================================================================
echo
echo "================================================================"
echo "kind-val: LEG 2 — NOETL_STATE_BUILDER=server (parity baseline)"
echo "================================================================"
set_state_builder server
SRV_EID="$(run_leg server)"; SRV_STATUS="$FINAL_STATUS"
SRV_FP="$(fingerprint "$SRV_EID")"
echo "kind-val: server leg execution_id=$SRV_EID final_status=$SRV_STATUS"
echo "kind-val: server fingerprint = [$SRV_FP]"

# ======================================================================
# Assertions.
# ======================================================================
# A. Live-drive parity.
[[ "$OFF_STATUS" == "COMPLETED" ]] || fail "offserver leg did not COMPLETE (got $OFF_STATUS)"
[[ "$SRV_STATUS" == "COMPLETED" ]] || fail "server baseline leg did not COMPLETE (got $SRV_STATUS)"
[[ -n "$OFF_FP" && "$OFF_FP" == "$SRV_FP" ]] \
  || fail "decision fingerprint mismatch — offserver [$OFF_FP] != server [$SRV_FP]"

# B. WAL build was authoritative + scan-free on the worker.
[[ "$W_SERVED_D" -ge 1 ]] || fail "worker drive served from WAL did not advance (+$W_SERVED_D) — the offserver build never served the decision"
[[ "$W_SCAN_D" -eq 0 ]]   || fail "worker state_builder_event_scans advanced (+$W_SCAN_D) — the builder is NOT WAL-only"
[[ "$W_WAL_D" -ge 1 ]]    || fail "worker consumed 0 WAL events (+$W_WAL_D) — the drain is not reading noetl_events"

# C. No server rebuild/scan on the drive path (chain_walk → PK lookups only).
[[ "$SB_SCAN_D" -eq 0 ]]  || fail "server state_build_event_scans advanced (+$SB_SCAN_D) — the drive path scanned noetl.event"

# D. Cache exercised under authoritative use.
[[ $(( W_COLD_D + W_INCR_D )) -ge 1 ]] || fail "no cold_rebuild/incremental cache builds (+$W_COLD_D/+$W_INCR_D) — cache not exercised"

# E. Sole-writer + lag-0 + off-server topology (offserver leg).
[[ "$EVENT_ROWS" -gt 0 && "$EVENT_ROWS" == "$DISTINCT_IDS" ]] || fail "event rows ($EVENT_ROWS) != distinct ids ($DISTINCT_IDS) — double-write/loss"
[[ "$CATALOG_ZERO" == "0" ]] || fail "$CATALOG_ZERO events with catalog_id=0"
[[ "$ORCH_EVENT_ROWS" == "0" ]] || fail "expected 0 __orchestrate__ event rows, got $ORCH_EVENT_ROWS"
[[ "${ORCH_COMMAND_ROWS:-0}" -ge 1 ]] || fail "expected >=1 __orchestrate__ command rows, got $ORCH_COMMAND_ROWS"
[[ "${MAT_DUP_HITS:-0}" -eq 0 ]] || fail "materializer reported duplicates>0 in $MAT_DUP_HITS cycle(s)"

echo
if [[ "$OVERALL" -eq 0 ]]; then
  echo "================================================================"
  echo "kind-val: PASS — off-server state builder drive cutover authoritative under the gate"
  echo "  A. parity: offserver==server fingerprint [$OFF_FP], both COMPLETED"
  echo "  B. WAL-build served the decision: +$W_SERVED_D (fallback +$W_FB_D), worker scans +$W_SCAN_D, WAL events +$W_WAL_D"
  echo "  C. server drive path scan-free (chain_walk): state_build_event_scans +$SB_SCAN_D"
  echo "  D. cache: cold_rebuild +$W_COLD_D / incremental +$W_INCR_D"
  echo "  E. sole-writer $EVENT_ROWS==$DISTINCT_IDS, catalog0=$CATALOG_ZERO, orch_event=0/cmd=$ORCH_COMMAND_ROWS, dup=$MAT_DUP_HITS"
  echo "================================================================"
  exit 0
fi

echo "================================================================"
echo "kind-val: FAIL — see assertion errors above"
echo "================================================================"
echo "kind-val: server logs (tail 80):"; "${KCTX[@]}" logs deploy/"$NOETL_SERVER_DEPLOY" --tail=80 || true
echo; echo "kind-val: system-pool logs (tail 80):"; "${KCTX[@]}" logs deploy/"$NOETL_SYSTEM_POOL_DEPLOY" --tail=80 || true
exit 1

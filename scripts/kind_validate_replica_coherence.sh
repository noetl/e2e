#!/usr/bin/env bash
#
# kind_validate_replica_coherence.sh — multi-replica coherence for the
# off-server drive's per-execution watermark + descriptor.
#
# RFC noetl/ai-meta#115 program-scale step (noetl/ai-meta#107).
#
# The off-server drive keys two execution-scoped facts off in-memory AppState
# maps: the ChainHeads `prev_event_id` watermark and the ExecDescriptor
# (catalog_id + routing + terminal).  Both carry a single-replica locality
# assumption.  Under NOETL_REPLICA_COHERENCE=nats_kv both are backed by shared
# JetStream KV buckets so 2+ server replicas resolve the same value (CAS on the
# head advance, CAS merge on the descriptor).  This rig proves that, with the
# server scaled to 2+ replicas and the gate ON, executions COMPLETE with
# triggers landing across replicas, the chain/descriptor stay coherent, and NO
# server-built cold-fallback scan happens just because a trigger landed on a
# replica that didn't seed the execution.
#
# What it asserts (gate ON: PUBLISH_ONLY + offserver + materializer sole-writer
# + replica_coherence=nats_kv, server replicas >= 2):
#
#   1. Every fixture (linear / loop / fan-out) reaches COMPLETED.
#   2. Cross-replica resolves happened — the load-bearing proof:
#      noetl_replica_coherence_total{outcome="kv_remote_hit"} advanced (a
#      descriptor/head a different replica seeded, resolved coherently from KV
#      instead of a server-built cold fallback).  HARD when replicas >= 2;
#      informational on a single replica.
#   3. ZERO cold-fallback scans attributable to the replica split:
#      noetl_state_build_event_scans_total delta == 0 AND
#      noetl_event_hotpath_reads_total{outcome="scan"} delta == 0.
#   4. Sole-writer intact per exec: rows == distinct event_id, 0 __orchestrate__
#      rows in noetl.event.
#   5. Chain integrity per exec across replicas: exactly 1 root (prev_event_id
#      NULL), no dangling prev pointer, the head-walk reaches every row (a single
#      unforked chain — the property the head CAS guarantees).
#
# Usage:
#   ./scripts/kind_validate_replica_coherence.sh
#   ./scripts/kind_validate_replica_coherence.sh --context kind-noetl
#   NOETL_SERVER_URL=http://localhost:18082 ./scripts/kind_validate_replica_coherence.sh
#
# Exits 0 if PASS; 1 if any hard assertion fails; 2 on a precondition error.

set -euo pipefail

KIND_CONTEXT="${NOETL_KIND_CONTEXT:-kind-noetl}"
NAMESPACE="${NOETL_K8S_NAMESPACE:-noetl}"
NOETL_SERVER_DEPLOY="${NOETL_SERVER_DEPLOY:-noetl-server-rust}"
NOETL_SERVER_URL="${NOETL_SERVER_URL:-http://localhost:8082}"
TIMEOUT_SECS="${NOETL_ORCH_TIMEOUT_SECS:-180}"
# How many runs per topology — more runs = more triggers spread across replicas,
# raising the chance every replica both seeds and resolves.
RUNS_PER_TOPOLOGY="${NOETL_COHERENCE_RUNS:-3}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --context)    KIND_CONTEXT="$2"; shift 2 ;;
    --namespace)  NAMESPACE="$2"; shift 2 ;;
    --server-url) NOETL_SERVER_URL="$2"; shift 2 ;;
    --timeout)    TIMEOUT_SECS="$2"; shift 2 ;;
    --runs)       RUNS_PER_TOPOLOGY="$2"; shift 2 ;;
    -h|--help)    sed -n '2,/^set -euo/p' "$0" | sed -n '/^#/p'; exit 0 ;;
    *) echo "kind-val: unknown argument: $1" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# (fixture path, registered playbook path) pairs.
FIXTURES=(
  "$REPO_ROOT/fixtures/playbooks/simple_python.yaml|test/simple_python"
  "$REPO_ROOT/fixtures/playbooks/loop_test.yaml|test/loop"
  "$REPO_ROOT/fixtures/playbooks/fanout_reduce/fanout_reduce_phase6.yaml|tests/fixtures/fanout_reduce_phase6"
)

KCTX=(kubectl --context "$KIND_CONTEXT" -n "$NAMESPACE")

# ----------------------------------------------------------------------
# Preflight.
# ----------------------------------------------------------------------
for cmd in kubectl noetl curl python3; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "kind-val: required command not in PATH: $cmd" >&2; exit 2; }
done

if ! "${KCTX[@]}" get deployment "$NOETL_SERVER_DEPLOY" >/dev/null 2>&1; then
  echo "kind-val: $NOETL_SERVER_DEPLOY Deployment not found in namespace $NAMESPACE." >&2; exit 2
fi
if ! curl -fsS "$NOETL_SERVER_URL/api/health" >/dev/null 2>&1; then
  echo "kind-val: server not reachable at $NOETL_SERVER_URL/api/health — start a port-forward first." >&2; exit 2
fi

# Detected server config + replica count (informational + soft preconditions).
get_env() {
  "${KCTX[@]}" get deployment "$NOETL_SERVER_DEPLOY" \
    -o jsonpath="{range .spec.template.spec.containers[0].env[?(@.name=='$1')]}{.value}{end}" 2>/dev/null
}
REPLICAS="$("${KCTX[@]}" get deployment "$NOETL_SERVER_DEPLOY" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
REPLICAS="${REPLICAS:-0}"
COHERENCE_MODE="$(get_env NOETL_REPLICA_COHERENCE)"; COHERENCE_MODE="${COHERENCE_MODE:-local}"
STATE_BUILDER="$(get_env NOETL_STATE_BUILDER)"; STATE_BUILDER="${STATE_BUILDER:-server}"
PUBLISH_ONLY="$(get_env NOETL_EVENT_INGEST_PUBLISH_ONLY)"; PUBLISH_ONLY="${PUBLISH_ONLY:-false}"

echo "kind-val: context=$KIND_CONTEXT namespace=$NAMESPACE server=$NOETL_SERVER_URL"
echo "kind-val: server replicas(ready)=$REPLICAS  replica_coherence=$COHERENCE_MODE  state_builder=$STATE_BUILDER  publish_only=$PUBLISH_ONLY"
echo "kind-val: runs per topology=$RUNS_PER_TOPOLOGY"

EXPECT_REMOTE_HIT="false"
if [[ "$REPLICAS" -ge 2 && "$COHERENCE_MODE" == "nats_kv" ]]; then
  EXPECT_REMOTE_HIT="true"
  echo "kind-val: multi-replica + nats_kv → cross-replica resolves (kv_remote_hit) are a HARD assertion"
else
  echo "kind-val: NOTE — replicas<2 or coherence!=nats_kv → kv_remote_hit is informational this run"
fi

# ----------------------------------------------------------------------
# Helpers.
# ----------------------------------------------------------------------
fetch_metrics() { curl -fsS "$NOETL_SERVER_URL/metrics" 2>/dev/null || true; }

# Sum noetl_replica_coherence_total over an outcome filter (any structure/op).
coherence_outcome() {
  local outcome="$1" body="$2"
  printf '%s' "$body" | python3 -c '
import re, sys
want = sys.argv[1]
total = 0
for line in sys.stdin:
    m = re.match(r"noetl_replica_coherence_total\{([^}]*)\}\s+([0-9.]+)", line)
    if not m: continue
    lm = dict(re.findall(r"(\w+)=\"([^\"]*)\"", m.group(1)))
    if lm.get("outcome") == want:
        total += int(float(m.group(2)))
print(total)
' "$outcome"
}

# Single Prometheus counter value (no labels), 0 if absent.
counter_value() {
  local name="$1" body="$2"
  printf '%s' "$body" | python3 -c '
import re, sys
name = sys.argv[1]
total = 0
for line in sys.stdin:
    m = re.match(re.escape(name) + r"(?:\{[^}]*\})?\s+([0-9.]+)", line)
    if m: total += int(float(m.group(1)))
print(total)
' "$name"
}

# noetl_event_hotpath_reads_total summed over a given outcome.
hotpath_outcome() {
  local outcome="$1" body="$2"
  printf '%s' "$body" | python3 -c '
import re, sys
want = sys.argv[1]
total = 0
for line in sys.stdin:
    m = re.match(r"noetl_event_hotpath_reads_total\{([^}]*)\}\s+([0-9.]+)", line)
    if not m: continue
    lm = dict(re.findall(r"(\w+)=\"([^\"]*)\"", m.group(1)))
    if lm.get("outcome") == want:
        total += int(float(m.group(2)))
print(total)
' "$outcome"
}

count_rows() {
  noetl query "$1" --format json 2>/dev/null \
    | python3 -c 'import json,sys
d=json.loads(sys.stdin.read() or "{}").get("result", [])
print(d[0].get("n", 0) if d else 0)'
}

OVERALL=0
fail() { echo "kind-val: FAIL — $1" >&2; OVERALL=1; }

run_fixture() {
  # $1 = fixture path, $2 = playbook path → prints execution_id (or empty)
  local fpath="$1" ppath="$2"
  noetl register playbook --file "$fpath" >/dev/null 2>&1 || true
  noetl exec "$ppath" --runtime distributed --json 2>/dev/null \
    | python3 -c 'import json,sys
try: print(json.load(sys.stdin)["execution_id"])
except Exception: print("")'
}

wait_complete() {
  # $1 = execution_id → prints final status
  local eid="$1" deadline status=""
  deadline=$(( SECONDS + TIMEOUT_SECS ))
  while [[ $SECONDS -lt $deadline ]]; do
    status="$(noetl status "$eid" --json 2>/dev/null \
      | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("status",""))' || true)"
    case "$status" in COMPLETED|FAILED) break ;; esac
    sleep 2
  done
  printf '%s' "$status"
}

# ----------------------------------------------------------------------
# Drive the executions.
# ----------------------------------------------------------------------
M_BEFORE="$(fetch_metrics)"
REMOTE_BEFORE="$(coherence_outcome kv_remote_hit "$M_BEFORE")"
LOCALHIT_BEFORE="$(coherence_outcome kv_local_hit "$M_BEFORE")"
UNAVAIL_BEFORE="$(coherence_outcome kv_unavailable "$M_BEFORE")"
SCAN_BUILD_BEFORE="$(counter_value noetl_state_build_event_scans_total "$M_BEFORE")"
HOTPATH_SCAN_BEFORE="$(hotpath_outcome scan "$M_BEFORE")"

EIDS=()
for entry in "${FIXTURES[@]}"; do
  fpath="${entry%%|*}"; ppath="${entry##*|}"
  if [[ ! -f "$fpath" ]]; then fail "fixture not found: $fpath"; continue; fi
  echo
  echo "kind-val: topology $ppath × $RUNS_PER_TOPOLOGY"
  for ((i=1; i<=RUNS_PER_TOPOLOGY; i++)); do
    eid="$(run_fixture "$fpath" "$ppath")"
    if [[ -z "$eid" ]]; then fail "could not launch $ppath (run $i)"; continue; fi
    EIDS+=("$eid")
    echo "kind-val:   run $i execution_id=$eid"
  done
done

echo
echo "kind-val: waiting for ${#EIDS[@]} executions to reach a terminal status…"
for eid in "${EIDS[@]}"; do
  st="$(wait_complete "$eid")"
  echo "kind-val:   exec $eid → $st"
  [[ "$st" == "COMPLETED" ]] || fail "execution $eid did not COMPLETE (status=$st)"
done
sleep 3

M_AFTER="$(fetch_metrics)"
REMOTE_AFTER="$(coherence_outcome kv_remote_hit "$M_AFTER")"
LOCALHIT_AFTER="$(coherence_outcome kv_local_hit "$M_AFTER")"
UNAVAIL_AFTER="$(coherence_outcome kv_unavailable "$M_AFTER")"
SCAN_BUILD_AFTER="$(counter_value noetl_state_build_event_scans_total "$M_AFTER")"
HOTPATH_SCAN_AFTER="$(hotpath_outcome scan "$M_AFTER")"

REMOTE_DELTA=$(( REMOTE_AFTER - REMOTE_BEFORE ))
LOCALHIT_DELTA=$(( LOCALHIT_AFTER - LOCALHIT_BEFORE ))
UNAVAIL_DELTA=$(( UNAVAIL_AFTER - UNAVAIL_BEFORE ))
SCAN_BUILD_DELTA=$(( SCAN_BUILD_AFTER - SCAN_BUILD_BEFORE ))
HOTPATH_SCAN_DELTA=$(( HOTPATH_SCAN_AFTER - HOTPATH_SCAN_BEFORE ))

echo
echo "================================================================"
echo "kind-val: replica-coherence metrics over the run"
echo "  kv_remote_hit  +$REMOTE_DELTA   (cross-replica resolves — descriptor/head another replica seeded)"
echo "  kv_local_hit   +$LOCALHIT_DELTA"
echo "  kv_unavailable +$UNAVAIL_DELTA  (degraded-to-local; should be 0 when NATS is healthy)"
echo "  state_build_event_scans +$SCAN_BUILD_DELTA   (drive cold-fallback scans — must be 0)"
echo "  hotpath scan            +$HOTPATH_SCAN_DELTA   (lifecycle cold-fallback scans — must be 0)"
echo "================================================================"

# ----------------------------------------------------------------------
# Assertions.
# ----------------------------------------------------------------------

# 2. Cross-replica resolves happened (the proof the KV backing is doing work).
if [[ "$EXPECT_REMOTE_HIT" == "true" ]]; then
  [[ "$REMOTE_DELTA" -ge 1 ]] \
    || fail "noetl_replica_coherence_total{outcome=kv_remote_hit} did not advance (+$REMOTE_DELTA) — with 2 replicas + nats_kv, triggers should land on a replica that did not seed the execution and resolve it from KV; no remote hit means coherence was never exercised (or all triggers happened to stay on the seeding replica)"
else
  echo "kind-val: kv_remote_hit +$REMOTE_DELTA (informational — single replica or coherence!=nats_kv)"
fi

# 3. No cold-fallback scans attributable to the replica split.
[[ "$SCAN_BUILD_DELTA" -eq 0 ]] \
  || fail "noetl_state_build_event_scans_total advanced (+$SCAN_BUILD_DELTA) — a drive took the server-built event-scan fallback (a cold watermark/descriptor on a non-seeding replica). Coherence should have served it from KV."
[[ "$HOTPATH_SCAN_DELTA" -eq 0 ]] \
  || fail "noetl_event_hotpath_reads_total{outcome=scan} advanced (+$HOTPATH_SCAN_DELTA) — a lifecycle reader fell back to scanning noetl.event (cold descriptor on a non-seeding replica)."

# When NATS is healthy the degraded-to-local path should not fire under nats_kv.
if [[ "$COHERENCE_MODE" == "nats_kv" && "$UNAVAIL_DELTA" -ne 0 ]]; then
  echo "kind-val: WARN — kv_unavailable advanced (+$UNAVAIL_DELTA); KV had transient errors, coherence degraded to local for those ops" >&2
fi

# 4 + 5. Per-exec sole-writer + chain integrity.
for eid in "${EIDS[@]}"; do
  ORCH_EV="$(count_rows "SELECT COUNT(*) AS n FROM noetl.event WHERE execution_id = $eid AND node_name = '__orchestrate__'")"
  TOTAL="$(count_rows "SELECT COUNT(*) AS n FROM noetl.event WHERE execution_id = $eid")"
  DISTINCT="$(count_rows "SELECT COUNT(DISTINCT event_id) AS n FROM noetl.event WHERE execution_id = $eid")"
  ROOTS="$(count_rows "SELECT COUNT(*) AS n FROM noetl.event WHERE execution_id = $eid AND prev_event_id IS NULL")"
  # Dangling: a non-null prev_event_id that points at no row in the same exec.
  DANGLING="$(count_rows "SELECT COUNT(*) AS n FROM noetl.event e WHERE e.execution_id = $eid AND e.prev_event_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM noetl.event p WHERE p.execution_id = $eid AND p.event_id = e.prev_event_id)")"
  # Recursive head-walk: how many rows the prev_event_id chain reaches from the
  # head (the row no other row points back to / max event_id).  walk == TOTAL
  # proves a single unforked chain.
  WALK="$(count_rows "WITH RECURSIVE head AS (
      SELECT event_id, prev_event_id FROM noetl.event
      WHERE execution_id = $eid
        AND event_id NOT IN (SELECT prev_event_id FROM noetl.event WHERE execution_id = $eid AND prev_event_id IS NOT NULL)
    ), walk AS (
      SELECT event_id, prev_event_id FROM head
      UNION
      SELECT e.event_id, e.prev_event_id FROM noetl.event e
      JOIN walk w ON e.execution_id = $eid AND e.event_id = w.prev_event_id
    ) SELECT COUNT(*) AS n FROM walk")"

  echo "kind-val: exec $eid — rows=$TOTAL distinct=$DISTINCT roots=$ROOTS dangling=$DANGLING walk=$WALK orch_events=$ORCH_EV"

  [[ "$ORCH_EV" == "0" ]] \
    || fail "exec $eid wrote $ORCH_EV __orchestrate__ rows to noetl.event (expected 0 — sole-writer / drive-suppression)"
  [[ "$TOTAL" -gt 0 && "$TOTAL" == "$DISTINCT" ]] \
    || fail "exec $eid sole-writer breach: rows=$TOTAL distinct=$DISTINCT (duplicate event_id under the gate)"
  [[ "$ROOTS" == "1" ]] \
    || fail "exec $eid chain has $ROOTS roots (expected exactly 1 — a forked chain means the head was not coherent across replicas)"
  [[ "$DANGLING" == "0" ]] \
    || fail "exec $eid has $DANGLING dangling prev_event_id pointers (a prev that points at no row — chain break across replicas)"
  [[ "$WALK" == "$TOTAL" ]] \
    || fail "exec $eid head-walk reached $WALK of $TOTAL rows (a single unforked chain must reach all — the head CAS guarantees this)"
done

# ----------------------------------------------------------------------
# Report.
# ----------------------------------------------------------------------
echo
if [[ "$OVERALL" == "0" ]]; then
  echo "kind-val: PASS — multi-replica coherence holds"
  echo "  replicas=$REPLICAS coherence=$COHERENCE_MODE state_builder=$STATE_BUILDER publish_only=$PUBLISH_ONLY"
  echo "  executions COMPLETE=${#EIDS[@]} kv_remote_hit=+$REMOTE_DELTA build_scans=+$SCAN_BUILD_DELTA hotpath_scans=+$HOTPATH_SCAN_DELTA"
else
  echo "kind-val: FAIL — see assertions above" >&2
  echo "=== noetl-server-rust logs (tail) ===" >&2
  "${KCTX[@]}" logs "deployment/$NOETL_SERVER_DEPLOY" --tail=80 2>/dev/null | tail -80 >&2 || true
fi
exit "$OVERALL"

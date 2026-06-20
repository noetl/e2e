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
# TWO LAYERS, both now shipped:
#   1. KV data-coherence (head + descriptor) — NOETL_REPLICA_COHERENCE=nats_kv
#      (noetl/server#251, v3.38.0).  Makes any replica resolve the same
#      watermark/descriptor.  Necessary but not sufficient.
#   2. Execution-affinity write-ordering — NOETL_EXECUTION_AFFINITY=true
#      (RFC noetl/ai-meta#116).  Routes every trigger for an execution to the
#      single replica that owns shard_for(execution_id), so the off-server
#      chain head's read→advance is atomic per execution and the chain never
#      forks across replicas.  This is what makes executions COMPLETE reliably
#      on 2+ replicas.
#
# Until affinity landed, the COMPLETION + chain-integrity checks were reported
# (not hard-failed) on 2+ replicas.  With it shipped, flip
# NOETL_COHERENCE_DRIVE_AFFINITY=shipped to make them HARD again (and to assert
# the forwarded_ok proof series advanced).
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
# noetl/ai-meta#117 — the off-server spine is replayed in prev_event_id CHAIN
# order (walked from the server's ChainHeads tip = expected_head), not event_id
# order, so a high-concurrency fan-out whose branch completions arrive id-inverted
# still completes (pre-#117 the max-id walk missed the inverted tip and the reduce
# never fired).  Set NOETL_COHERENCE_FANOUT_BURST=N to launch an extra burst of N
# concurrent fanout_reduce executions that concentrates the inversion.
#
# Usage:
#   ./scripts/kind_validate_replica_coherence.sh
#   ./scripts/kind_validate_replica_coherence.sh --context kind-noetl
#   NOETL_SERVER_URL=http://localhost:18082 ./scripts/kind_validate_replica_coherence.sh
#   NOETL_COHERENCE_DRIVE_AFFINITY=shipped NOETL_COHERENCE_FANOUT_BURST=9 \
#     ./scripts/kind_validate_replica_coherence.sh   # #117 high-concurrency stress
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

# The server workload is a Deployment for the single-replica topology and a
# StatefulSet for the multi-replica execution-affinity topology (RFC
# noetl/ai-meta#116 — stable ordinal hostnames give each pod a distinct
# NOETL_SHARD_INDEX via NOETL_SHARD_INDEX_FROM_HOSTNAME, and the headless service
# lets a non-owner forward to the owner).  Auto-detect; override with
# NOETL_SERVER_WORKLOAD_KIND=deployment|statefulset.
ready_replicas_of() {
  # $1 = deployment|statefulset → prints readyReplicas (0 if absent/none).
  local kind="$1" n
  n="$("${KCTX[@]}" get "$kind" "$NOETL_SERVER_DEPLOY" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
  echo "${n:-0}"
}
SERVER_WORKLOAD_KIND="${NOETL_SERVER_WORKLOAD_KIND:-}"
if [[ -z "$SERVER_WORKLOAD_KIND" ]]; then
  # The affinity topology runs the StatefulSet while the baseline Deployment of
  # the same name is scaled to 0 (the topology helper doesn't delete it). Prefer
  # whichever workload actually has ready replicas so we don't read the dormant
  # one's metadata; fall back to existence (StatefulSet first, since that's the
  # multi-replica topology this rig targets).
  DEP_READY="$(ready_replicas_of deployment)"
  STS_READY="$(ready_replicas_of statefulset)"
  if [[ "$STS_READY" -gt 0 ]]; then
    SERVER_WORKLOAD_KIND="statefulset"
  elif [[ "$DEP_READY" -gt 0 ]]; then
    SERVER_WORKLOAD_KIND="deployment"
  elif "${KCTX[@]}" get statefulset "$NOETL_SERVER_DEPLOY" >/dev/null 2>&1; then
    SERVER_WORKLOAD_KIND="statefulset"
  elif "${KCTX[@]}" get deployment "$NOETL_SERVER_DEPLOY" >/dev/null 2>&1; then
    SERVER_WORKLOAD_KIND="deployment"
  fi
fi
if [[ -z "$SERVER_WORKLOAD_KIND" ]]; then
  echo "kind-val: $NOETL_SERVER_DEPLOY not found as a Deployment or StatefulSet in namespace $NAMESPACE." >&2; exit 2
fi
SERVER_WORKLOAD="$SERVER_WORKLOAD_KIND/$NOETL_SERVER_DEPLOY"
if ! curl -fsS "$NOETL_SERVER_URL/api/health" >/dev/null 2>&1; then
  echo "kind-val: server not reachable at $NOETL_SERVER_URL/api/health — start a port-forward first." >&2; exit 2
fi

# Detected server config + replica count (informational + soft preconditions).
get_env() {
  "${KCTX[@]}" get "$SERVER_WORKLOAD" \
    -o jsonpath="{range .spec.template.spec.containers[0].env[?(@.name=='$1')]}{.value}{end}" 2>/dev/null
}
REPLICAS="$("${KCTX[@]}" get "$SERVER_WORKLOAD" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
REPLICAS="${REPLICAS:-0}"
COHERENCE_MODE="$(get_env NOETL_REPLICA_COHERENCE)"; COHERENCE_MODE="${COHERENCE_MODE:-local}"
AFFINITY_MODE="$(get_env NOETL_EXECUTION_AFFINITY)"; AFFINITY_MODE="${AFFINITY_MODE:-false}"
STATE_BUILDER="$(get_env NOETL_STATE_BUILDER)"; STATE_BUILDER="${STATE_BUILDER:-server}"
PUBLISH_ONLY="$(get_env NOETL_EVENT_INGEST_PUBLISH_ONLY)"; PUBLISH_ONLY="${PUBLISH_ONLY:-false}"

echo "kind-val: context=$KIND_CONTEXT namespace=$NAMESPACE server=$NOETL_SERVER_URL"
echo "kind-val: server workload=$SERVER_WORKLOAD replicas(ready)=$REPLICAS  replica_coherence=$COHERENCE_MODE  execution_affinity=$AFFINITY_MODE  state_builder=$STATE_BUILDER  publish_only=$PUBLISH_ONLY"
echo "kind-val: runs per topology=$RUNS_PER_TOPOLOGY"

# The KV data-coherence layer (head + descriptor) is SHIPPED.  The multi-replica
# WRITE-ORDERING piece — execution-affinity (a given execution's drive + chain
# write owned by a single replica) — is STAGED: without it, two replicas driving
# / emitting for one execution concurrently fork the chain, so executions do not
# reliably COMPLETE on 2+ replicas yet.  Until it lands, on 2+ replicas the
# COMPLETION + chain-integrity checks are reported but NOT hard failures (the
# coherence-resolve proof below stays HARD); set NOETL_COHERENCE_DRIVE_AFFINITY=
# shipped once execution-affinity is in to flip them back to HARD.
AFFINITY_SHIPPED="${NOETL_COHERENCE_DRIVE_AFFINITY:-staged}"

AFFINITY_ACTIVE="false"
if [[ "$REPLICAS" -ge 2 && "$AFFINITY_MODE" == "true" && "$AFFINITY_SHIPPED" == "shipped" ]]; then
  AFFINITY_ACTIVE="true"
fi

EXPECT_REMOTE_HIT="false"
COMPLETION_HARD="true"
if [[ "$REPLICAS" -ge 2 && "$COHERENCE_MODE" == "nats_kv" ]]; then
  if [[ "$AFFINITY_ACTIVE" == "true" ]]; then
    # Execution-affinity (RFC noetl/ai-meta#116) routes EVERY trigger for an
    # execution to its owner, which resolves the head/descriptor from its LOCAL
    # in-process write-through cache — so cross-replica KV resolves
    # (kv_remote_hit) trend to ZERO BY DESIGN (KV becomes the handoff-only
    # vehicle on ownership change).  The multi-replica proof under affinity is
    # `forwarded_ok` (non-owner→owner forwards), asserted HARD below; so
    # kv_remote_hit is informational here, not a hard failure.
    EXPECT_REMOTE_HIT="false"
    echo "kind-val: execution-affinity ACTIVE → owner resolves LOCAL; kv_remote_hit is informational (forwarded_ok is the HARD multi-replica proof, RFC #116)"
  else
    # DATA-layer-only coherence run (no affinity): triggers land on non-seeding
    # replicas and MUST resolve from KV → kv_remote_hit is the HARD proof.
    EXPECT_REMOTE_HIT="true"
    echo "kind-val: multi-replica + nats_kv (no affinity) → cross-replica resolves (kv_remote_hit) are a HARD assertion"
    if [[ "$AFFINITY_SHIPPED" != "shipped" ]]; then
      COMPLETION_HARD="false"
      echo "kind-val: NOTE — execution-affinity STAGED → multi-replica COMPLETION + chain-integrity are reported, not hard-failed (set NOETL_COHERENCE_DRIVE_AFFINITY=shipped once it lands)"
    fi
  fi
else
  echo "kind-val: NOTE — replicas<2 or coherence!=nats_kv → kv_remote_hit is informational this run"
fi

# Hard fail when the guarantee is in force (single-replica parity, or
# multi-replica once affinity ships); otherwise a staged report.
note_or_fail() {
  if [[ "$COMPLETION_HARD" == "true" ]]; then
    fail "$1"
  else
    echo "kind-val: STAGED (multi-replica completion needs execution-affinity) — $1" >&2
  fi
}

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

# noetl_execution_affinity_total summed over a given outcome (RFC #116).
affinity_outcome() {
  local outcome="$1" body="$2"
  printf '%s' "$body" | python3 -c '
import re, sys
want = sys.argv[1]
total = 0
for line in sys.stdin:
    m = re.match(r"noetl_execution_affinity_total\{([^}]*)\}\s+([0-9.]+)", line)
    if not m: continue
    lm = dict(re.findall(r"(\w+)=\"([^\"]*)\"", m.group(1)))
    if lm.get("outcome") == want:
        total += int(float(m.group(2)))
print(total)
' "$outcome"
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
FORWARD_BEFORE="$(affinity_outcome forwarded_ok "$M_BEFORE")"
AFF_DEGRADE_BEFORE="$(( $(affinity_outcome forward_unavailable "$M_BEFORE") + $(affinity_outcome forward_http_err "$M_BEFORE") + $(affinity_outcome forward_decode_err "$M_BEFORE") ))"

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

# Higher-concurrency fan-out stress (noetl/ai-meta#117).  The off-server spine is
# replayed in prev_event_id CHAIN order (walked from the server's ChainHeads tip),
# not event_id order, so a fan-out whose concurrent branch completions arrive at
# the owner id-inverted (a higher-id event linked as the predecessor of a
# lower-id one) still completes — pre-#117 such an execution wedged because the
# max-id walk missed the inverted tip and the reduce never fired.  Launch an extra
# BURST of fanout_reduce executions all at once to concentrate that
# concurrent-branch-arrival reordering.  Default 0 (off); set e.g. 9 to stress.
FANOUT_BURST="${NOETL_COHERENCE_FANOUT_BURST:-0}"
if [[ "$FANOUT_BURST" -gt 0 ]]; then
  FO_FIXTURE="$REPO_ROOT/fixtures/playbooks/fanout_reduce/fanout_reduce_phase6.yaml"
  FO_PATH="tests/fixtures/fanout_reduce_phase6"
  echo
  echo "kind-val: #117 fan-out burst × $FANOUT_BURST (concurrent fanout_reduce — id-inversion stress)"
  noetl register playbook --file "$FO_FIXTURE" >/dev/null 2>&1 || true
  for ((b=1; b<=FANOUT_BURST; b++)); do
    eid="$(noetl exec "$FO_PATH" --runtime distributed --json 2>/dev/null \
      | python3 -c 'import json,sys
try: print(json.load(sys.stdin)["execution_id"])
except Exception: print("")')"
    if [[ -z "$eid" ]]; then fail "could not launch fan-out burst $b"; continue; fi
    EIDS+=("$eid")
    echo "kind-val:   burst $b execution_id=$eid"
  done
fi

echo
echo "kind-val: waiting for ${#EIDS[@]} executions to reach a terminal status…"
for eid in "${EIDS[@]}"; do
  st="$(wait_complete "$eid")"
  echo "kind-val:   exec $eid → $st"
  [[ "$st" == "COMPLETED" ]] || note_or_fail "execution $eid did not COMPLETE (status=$st)"
done
sleep 3

M_AFTER="$(fetch_metrics)"
REMOTE_AFTER="$(coherence_outcome kv_remote_hit "$M_AFTER")"
LOCALHIT_AFTER="$(coherence_outcome kv_local_hit "$M_AFTER")"
UNAVAIL_AFTER="$(coherence_outcome kv_unavailable "$M_AFTER")"
SCAN_BUILD_AFTER="$(counter_value noetl_state_build_event_scans_total "$M_AFTER")"
HOTPATH_SCAN_AFTER="$(hotpath_outcome scan "$M_AFTER")"
FORWARD_AFTER="$(affinity_outcome forwarded_ok "$M_AFTER")"
AFF_DEGRADE_AFTER="$(( $(affinity_outcome forward_unavailable "$M_AFTER") + $(affinity_outcome forward_http_err "$M_AFTER") + $(affinity_outcome forward_decode_err "$M_AFTER") ))"

REMOTE_DELTA=$(( REMOTE_AFTER - REMOTE_BEFORE ))
LOCALHIT_DELTA=$(( LOCALHIT_AFTER - LOCALHIT_BEFORE ))
UNAVAIL_DELTA=$(( UNAVAIL_AFTER - UNAVAIL_BEFORE ))
SCAN_BUILD_DELTA=$(( SCAN_BUILD_AFTER - SCAN_BUILD_BEFORE ))
HOTPATH_SCAN_DELTA=$(( HOTPATH_SCAN_AFTER - HOTPATH_SCAN_BEFORE ))
FORWARD_DELTA=$(( FORWARD_AFTER - FORWARD_BEFORE ))
AFF_DEGRADE_DELTA=$(( AFF_DEGRADE_AFTER - AFF_DEGRADE_BEFORE ))

echo
echo "================================================================"
echo "kind-val: replica-coherence metrics over the run"
echo "  kv_remote_hit  +$REMOTE_DELTA   (cross-replica resolves — descriptor/head another replica seeded)"
echo "  kv_local_hit   +$LOCALHIT_DELTA"
echo "  kv_unavailable +$UNAVAIL_DELTA  (degraded-to-local; should be 0 when NATS is healthy)"
echo "  state_build_event_scans +$SCAN_BUILD_DELTA   (drive cold-fallback scans — must be 0)"
echo "  hotpath scan            +$HOTPATH_SCAN_DELTA   (lifecycle cold-fallback scans — must be 0)"
echo "  affinity forwarded_ok   +$FORWARD_DELTA   (RFC #116 — non-owner→owner forwards; >0 proves write-ordering routing)"
echo "  affinity degraded       +$AFF_DEGRADE_DELTA   (forward failures → local fallback; should be 0 when healthy)"
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

# 2b. Execution-affinity forwarding happened (RFC noetl/ai-meta#116) — the
# write-ordering proof.  With affinity shipped + 2 replicas, a trigger landing on
# a non-owner must forward to the owner; no forward across the whole run means
# affinity routing never engaged (the single-owner property is what keeps the
# chain from forking).
if [[ "$AFFINITY_ACTIVE" == "true" ]]; then
  [[ "$FORWARD_DELTA" -ge 1 ]] \
    || fail "noetl_execution_affinity_total{outcome=forwarded_ok} did not advance (+$FORWARD_DELTA) — with 2 replicas + execution-affinity ON, triggers landing on a non-owner should forward to the owner; no forward means affinity routing never engaged (executions would fork without it)"
  [[ "$AFF_DEGRADE_DELTA" -eq 0 ]] \
    || echo "kind-val: WARN — affinity degraded to local +$AFF_DEGRADE_DELTA times (owner unreachable / non-success forward); write ordering held via KV but the owner path had transient failures" >&2
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

  # Sole-writer invariants hold regardless of replica count (materializer +
  # drive suppression) → always HARD.
  [[ "$ORCH_EV" == "0" ]] \
    || fail "exec $eid wrote $ORCH_EV __orchestrate__ rows to noetl.event (expected 0 — sole-writer / drive-suppression)"
  [[ "$TOTAL" -gt 0 && "$TOTAL" == "$DISTINCT" ]] \
    || fail "exec $eid sole-writer breach: rows=$TOTAL distinct=$DISTINCT (duplicate event_id under the gate)"
  # Chain-ordering integrity is the write-ordering property execution-affinity
  # owns → HARD single-replica / affinity-shipped, STAGED on 2+ replicas without
  # it (concurrent cross-replica emits fork the chain).
  [[ "$ROOTS" == "1" ]] \
    || note_or_fail "exec $eid chain has $ROOTS roots (expected exactly 1 — a forked chain means concurrent cross-replica emits; needs execution-affinity)"
  [[ "$DANGLING" == "0" ]] \
    || note_or_fail "exec $eid has $DANGLING dangling prev_event_id pointers (a prev that points at no row — chain break across replicas; needs execution-affinity)"
  [[ "$WALK" == "$TOTAL" ]] \
    || note_or_fail "exec $eid head-walk reached $WALK of $TOTAL rows (a single unforked chain must reach all — needs execution-affinity)"
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
  echo "=== $SERVER_WORKLOAD logs (tail) ===" >&2
  "${KCTX[@]}" logs "$SERVER_WORKLOAD" --tail=80 2>/dev/null | tail -80 >&2 || true
fi
exit "$OVERALL"

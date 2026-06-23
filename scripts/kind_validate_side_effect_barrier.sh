#!/usr/bin/env bash
# kind_validate_side_effect_barrier.sh — the Phase E side-effect durability
# barrier under the prod-exact off-server gate, with a GCS backend
# (noetl/ai-meta#104 Phase E).
#
# Phase E adds a tool-registry `side_effecting` attribute + a barrier in the
# worker: before (re-)dispatching a SIDE-EFFECTING tool for a cycle
# `(execution_id, step, frame, row, attempt)`, if the cycle's derived result URN
# already resolves to a durable result (Phase C read path), the worker SKIPS
# re-execution and adopts the recorded result — so an external side effect fires
# exactly ONCE across a crash-resume / re-drive. Non-side-effecting cycles are
# never blocked. ONE flag — NOETL_SIDE_EFFECT_BARRIER — arms it; default-off is a
# true no-op (dispatch byte-identical to today).
#
# DETERMINISTIC SIDE-EFFECT COUNTER. The fixture's `charge` step (python,
# side-effecting) creates a uniquely-named marker object in the `se-markers`
# fake-gcs bucket on every EXECUTION of the step, AND returns an over-budget
# rowset so the result tiers to the URN the barrier checks. The marker count is
# the side-effect counter (one object per real execution); it is robust to any
# downstream re-drive cascade because only `charge` writes markers.
#
# DETERMINISTIC RE-DRIVE. The worker acks a command BEFORE dispatch, so a crash
# never redelivers; and re-publishing the SAME command_id is rejected by the
# claim's terminal guard. So the rig forges a SECOND, non-terminal command for
# the same `(execution_id, step)`: it copies the original command row with a
# fresh event_id/command_id (meta stripped of command_id), then publishes the
# matching NATS notification. The worker claims the fresh command (the terminal
# guard never matches a fresh id), and derives the SAME cycle URN from the copied
# render_context — exactly the "drive re-issues the same step" crash-resume shape.
#
# This rig proves, under the gate-ON stack (PUBLISH_ONLY + off-server drive +
# event-materializer sole-writer) with a fake-gcs object backend + the result
# materializer writing the tier:
#
#   PASS A (barrier ON, side-effecting re-drive) — primary run executes `charge`
#     once (marker_count==1, barrier{outcome=executed,tool=python}); the re-drive
#     of `charge` SKIPS (marker_count STAYS 1,
#     barrier{outcome=skipped,tool=python}+1). The side effect fired exactly
#     once across the re-drive.
#   PASS B (barrier OFF, side-effecting re-drive) — primary run executes once
#     (marker_count==1); the re-drive RE-EXECUTES (marker_count==2); the barrier
#     metric never moves (true no-op).
#   PASS C (barrier ON, NON-side-effecting re-drive) — a re-drive of `pure`
#     (noop) re-runs and the barrier never checks it (no
#     barrier{tool=noop} series; marker_count unchanged) — idempotent recompute
#     is never blocked.
#
# Cutover invariants (sole-writer, roots=1, dangling=0, walk==total, terminal==1)
# are asserted on each PRIMARY execution's NATURAL completion (before any forge —
# the forge deliberately injects an out-of-band command, so chain invariants are
# checked on the un-forged path).
#
# Backend: a fake-gcs-server emulator (kind only; never real GCS).
#
# Usage:
#   ./scripts/kind_validate_side_effect_barrier.sh
#   ./scripts/kind_validate_side_effect_barrier.sh --no-restore
#
# Exits 0 if PASS; 1 if a hard assertion fails (dumps logs); 2 on precondition.

set -euo pipefail

KIND_CONTEXT="${NOETL_KIND_CONTEXT:-kind-noetl}"
NAMESPACE="${NOETL_K8S_NAMESPACE:-noetl}"
NATS_NAMESPACE="${NOETL_NATS_NAMESPACE:-nats}"
NOETL_SERVER_DEPLOY="${NOETL_SERVER_DEPLOY:-noetl-server-rust}"
NOETL_WORKER_POOL_DEPLOY="${NOETL_WORKER_POOL_DEPLOY:-noetl-worker-rust}"
NOETL_SYSTEM_POOL_DEPLOY="${NOETL_SYSTEM_POOL_DEPLOY:-noetl-worker-system-pool}"
NOETL_SERVER_URL="${NOETL_SERVER_URL:-http://localhost:8082}"
# The in-cluster server URL the worker uses to route a forged command's
# lifecycle events (matches the worker's NOETL_SERVER_URL env).
SERVER_URL_INCLUSTER="${NOETL_SERVER_URL_INCLUSTER:-http://noetl.${NAMESPACE}.svc.cluster.local:8082}"
TIMEOUT_SECS="${NOETL_ORCH_TIMEOUT_SECS:-240}"
RESTORE=1

GCS_ENDPOINT_IN="http://fake-gcs-server.${NAMESPACE}.svc.cluster.local:4443"
GCS_BUCKET="noetl-results"
MARKER_BUCKET="se-markers"
CELL="local-0"; CELL_ENV="dev"; CELL_REGION="local"; SHARD_COUNT="256"
REDRIVE_SUBJECT="noetl.commands.shared.phase_e_redrive"

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
FIX="$REPO_ROOT/fixtures/playbooks/test_side_effect_barrier.yaml:tests/side_effect_barrier"
MANIFEST="$REPO_ROOT/manifests/fake-gcs-server.yaml"

echo "kind-val: context=$KIND_CONTEXT namespace=$NAMESPACE"
echo "kind-val: #104 Phase E — side-effect durability barrier"

for cmd in kubectl noetl curl python3 nats; do
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
PF_PID=""; NATS_PF_PID=""
NATS_LOCAL="nats://noetl:noetl@localhost:4222"

cleanup() {
  [[ -n "$PF_PID" ]] && kill "$PF_PID" >/dev/null 2>&1 || true
  [[ -n "$NATS_PF_PID" ]] && kill "$NATS_PF_PID" >/dev/null 2>&1 || true
  if [[ "$RESTORE" -eq 1 ]]; then
    echo "kind-val: restoring baseline"
    "${KCTX[@]}" set env deploy/"$NOETL_SERVER_DEPLOY" \
      "NOETL_OBJECT_STORE_BACKEND-" "NOETL_OBJECT_STORE_GCS_ENDPOINT-" "NOETL_OBJECT_STORE_GCS_BUCKET-" \
      "NOETL_RESULT_CELL-" "NOETL_RESULT_CELL_ENV-" "NOETL_RESULT_CELL_REGION-" "NOETL_RESULT_SHARD_COUNT-" >/dev/null 2>&1 || true
    "${KCTX[@]}" set env deploy/"$NOETL_WORKER_POOL_DEPLOY" \
      "NOETL_SIDE_EFFECT_BARRIER-" "NOETL_RESULT_URI_RESOLVE-" \
      "NOETL_RESULT_CELL-" "NOETL_RESULT_CELL_ENV-" "NOETL_RESULT_CELL_REGION-" "NOETL_RESULT_SHARD_COUNT-" \
      "NOETL_OBJECT_STORE_BACKEND-" >/dev/null 2>&1 || true
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
count_rows() { { noetl query "$1" --format json 2>/dev/null || true; } \
  | python3 -c 'import json,sys
d=json.loads(sys.stdin.read() or "{}").get("result", [])
print(d[0].get("n", 0) if d else 0)'; }

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

# Count marker objects in se-markers for a given execution (the side-effect counter).
marker_count() {  # eid
  curl -fsS "http://localhost:4443/storage/v1/b/$MARKER_BUCKET/o?prefix=marker/$1_" 2>/dev/null \
    | python3 -c 'import json,sys
try: print(len(json.load(sys.stdin).get("items", [])))
except Exception: print(0)'
}

# True (echo 1) once charge's tier object exists for the execution.
tier_written() {  # eid -> echoes count of charge tier objects
  curl -fsS "http://localhost:4443/storage/v1/b/$GCS_BUCKET/o?prefix=" 2>/dev/null \
    | python3 -c 'import json,sys
items=json.load(sys.stdin).get("items", [])
print(sum(1 for i in items if ("execution='"$1"'/results/start/" in i.get("name",""))))' 2>/dev/null || echo 0
}

await_tier() {  # eid — block until charge's tier object is written (or timeout)
  local deadline=$(( SECONDS + 90 )) n=0
  while [[ $SECONDS -lt $deadline ]]; do
    n="$(tier_written "$1")"
    [[ "$n" -ge 1 ]] && { echo "kind-val: charge tier object present for exec $1 (n=$n)"; return 0; }
    sleep 3
  done
  echo "kind-val: WARN — charge tier object not observed for exec $1 within 90s" >&2
  return 1
}

launch_leg() {  # -> sets LEG_EID
  noetl register playbook --file "${FIX%%:*}" >/dev/null
  LEG_EID="$(noetl exec "${FIX##*:}" --runtime distributed --json \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["execution_id"])')"
  echo "kind-val: leg launched execution_id=$LEG_EID"
}

await_leg() {  # -> sets LEG_STATUS, LEG_PASS
  local deadline=$(( SECONDS + TIMEOUT_SECS ))
  LEG_STATUS=""
  while [[ $SECONDS -lt $deadline ]]; do
    LEG_STATUS="$(noetl status "$LEG_EID" --json 2>/dev/null \
      | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",""))' || true)"
    case "$LEG_STATUS" in COMPLETED|FAILED) break ;; esac
    sleep 3
  done
  sleep 2
  LEG_PASS="$(count_rows "SELECT COUNT(*) AS n FROM noetl.event
              WHERE execution_id = $LEG_EID AND result::text LIKE '%\"test_passed\": true%'")"
}

# Forge a SECOND, non-terminal command for the same (execution_id, step) and
# publish its NATS notification -> the worker dispatches it (re-drive). Echoes
# the fresh event_id.
forge_redrive() {  # eid step
  local eid="$1" step="$2" new_eid note
  new_eid="$(noetl query "SELECT (floor(random()*9000000000000000)::bigint + 1000000000000000) AS n" --format json 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"][0]["n"])')"
  noetl query "INSERT INTO noetl.command
      (event_id, command_id, execution_id, catalog_id, step_name, tool_kind, status, context, meta, attempt, created_at, updated_at)
      SELECT ${new_eid}, ${new_eid}, execution_id, catalog_id, step_name, tool_kind, 'issued', context,
             (COALESCE(meta,'{}'::jsonb) - 'command_id'), 1, now(), now()
      FROM noetl.command WHERE execution_id = ${eid} AND step_name = '${step}'
      ORDER BY created_at DESC LIMIT 1" >/dev/null 2>&1 || true
  note="$(python3 -c 'import json,sys
print(json.dumps({"execution_id": int(sys.argv[1]), "event_id": int(sys.argv[2]),
  "command_id": "%s:%s:%s" % (sys.argv[1], sys.argv[3], sys.argv[2]),
  "step": sys.argv[3], "server_url": sys.argv[4]}))' "$eid" "$new_eid" "$step" "$SERVER_URL_INCLUSTER")"
  nats --server "$NATS_LOCAL" pub "$REDRIVE_SUBJECT" "$note" >/dev/null 2>&1 || true
  echo "kind-val: forged re-drive of ($eid,$step) event_id=$new_eid -> $REDRIVE_SUBJECT" >&2
  echo "$new_eid"
}

OVERALL=0
fail() { echo "kind-val: FAIL — $1" >&2; OVERALL=1; }

assert_invariants() {  # eid label — sole-writer + chain integrity on the natural path
  local eid="$1" lbl="$2" rows distinct cat0 orch roots dangling walk terms
  rows="$(count_rows "SELECT COUNT(*) AS n FROM noetl.event WHERE execution_id = $eid")"
  distinct="$(count_rows "SELECT COUNT(DISTINCT event_id) AS n FROM noetl.event WHERE execution_id = $eid")"
  cat0="$(count_rows "SELECT COUNT(*) AS n FROM noetl.event WHERE execution_id = $eid AND catalog_id = 0")"
  orch="$(count_rows "SELECT COUNT(*) AS n FROM noetl.event WHERE execution_id = $eid AND node_name = '__orchestrate__'")"
  roots="$(count_rows "SELECT COUNT(*) AS n FROM noetl.event WHERE execution_id = $eid AND prev_event_id IS NULL")"
  dangling="$(count_rows "SELECT COUNT(*) AS n FROM noetl.event e WHERE e.execution_id = $eid AND e.prev_event_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM noetl.event p WHERE p.execution_id = $eid AND p.event_id = e.prev_event_id)")"
  walk="$(count_rows "WITH RECURSIVE head AS (
      SELECT event_id, prev_event_id FROM noetl.event
      WHERE execution_id = $eid
        AND event_id NOT IN (SELECT prev_event_id FROM noetl.event WHERE execution_id = $eid AND prev_event_id IS NOT NULL)
    ), walk AS (
      SELECT event_id, prev_event_id FROM head
      UNION
      SELECT e.event_id, e.prev_event_id FROM noetl.event e
      JOIN walk w ON e.execution_id = $eid AND e.event_id = w.prev_event_id
    ) SELECT COUNT(*) AS n FROM walk")"
  terms="$(count_rows "SELECT COUNT(*) AS n FROM noetl.event WHERE execution_id = $eid AND event_type IN ('playbook.completed','playbook_completed','playbook.failed','playbook_failed')")"
  echo "kind-val: $lbl invariants — rows=$rows distinct=$distinct catalog0=$cat0 orch=$orch roots=$roots dangling=$dangling walk=$walk terminals=$terms"
  [[ "$rows" -gt 0 && "$rows" == "$distinct" ]] || fail "$lbl sole-writer breach rows=$rows distinct=$distinct"
  [[ "$cat0" == "0" ]] || fail "$lbl $cat0 events with catalog_id=0"
  [[ "$orch" == "0" ]] || fail "$lbl $orch __orchestrate__ rows (sole-writer)"
  [[ "$roots" == "1" ]] || fail "$lbl chain has $roots roots (expected 1)"
  [[ "$dangling" == "0" ]] || fail "$lbl $dangling dangling prev_event_id pointers"
  [[ "$walk" == "$rows" ]] || fail "$lbl head-walk reached $walk of $rows rows (forked chain)"
  [[ "$terms" == "1" ]] || fail "$lbl has $terms terminal events (expected 1)"
}

# ----------------------------------------------------------------------
# Setup: fake-gcs-server + both buckets + GCS backend + cell registry.
# ----------------------------------------------------------------------
echo; echo "kind-val: deploying fake-gcs-server emulator"
"${KCTX[@]}" apply -f "$MANIFEST" >/dev/null
"${KCTX[@]}" rollout status deploy/fake-gcs-server --timeout=120s >/dev/null 2>&1 || true

"${KCTX[@]}" port-forward svc/fake-gcs-server 4443:4443 >/dev/null 2>&1 &
PF_PID=$!
sleep 3
for b in "$GCS_BUCKET" "$MARKER_BUCKET"; do
  curl -fsS -X POST "http://localhost:4443/storage/v1/b?project=noetl-test" \
    -H 'Content-Type: application/json' -d "{\"name\":\"$b\"}" >/dev/null 2>&1 \
    || echo "kind-val: bucket $b create returned non-2xx (may already exist) — continuing"
done
echo "kind-val: buckets ready: $GCS_BUCKET (tier) + $MARKER_BUCKET (side-effect markers)"

echo "kind-val: NATS port-forward (for forged re-drive notifications)"
kubectl --context "$KIND_CONTEXT" -n "$NATS_NAMESPACE" port-forward svc/nats 4222:4222 >/dev/null 2>&1 &
NATS_PF_PID=$!
sleep 3
nats --server "$NATS_LOCAL" stream info NOETL_COMMANDS >/dev/null 2>&1 \
  || { echo "kind-val: cannot reach NATS at $NATS_LOCAL — re-drive impossible." >&2; exit 2; }

echo "kind-val: configuring GCS backend + cell registry + result materializer"
"${KCTX[@]}" set env deploy/"$NOETL_SERVER_DEPLOY" \
  NOETL_OBJECT_STORE_BACKEND=gcs \
  "NOETL_OBJECT_STORE_GCS_ENDPOINT=$GCS_ENDPOINT_IN" \
  "NOETL_OBJECT_STORE_GCS_BUCKET=$GCS_BUCKET" \
  "NOETL_RESULT_CELL=$CELL" "NOETL_RESULT_CELL_ENV=$CELL_ENV" \
  "NOETL_RESULT_CELL_REGION=$CELL_REGION" "NOETL_RESULT_SHARD_COUNT=$SHARD_COUNT" >/dev/null
"${KCTX[@]}" set env deploy/"$NOETL_SYSTEM_POOL_DEPLOY" \
  NOETL_RESULT_MATERIALIZER_ENABLED=true \
  NOETL_OBJECT_STORE_BACKEND=gcs \
  "NOETL_OBJECT_STORE_GCS_ENDPOINT=$GCS_ENDPOINT_IN" \
  "NOETL_OBJECT_STORE_GCS_BUCKET=$GCS_BUCKET" \
  "NOETL_RESULT_CELL=$CELL" "NOETL_RESULT_CELL_ENV=$CELL_ENV" \
  "NOETL_RESULT_CELL_REGION=$CELL_REGION" "NOETL_RESULT_SHARD_COUNT=$SHARD_COUNT" >/dev/null
"${KCTX[@]}" set env deploy/"$NOETL_WORKER_POOL_DEPLOY" \
  "NOETL_RESULT_CELL=$CELL" "NOETL_RESULT_CELL_ENV=$CELL_ENV" \
  "NOETL_RESULT_CELL_REGION=$CELL_REGION" "NOETL_RESULT_SHARD_COUNT=$SHARD_COUNT" \
  NOETL_OBJECT_STORE_BACKEND=gcs >/dev/null
roll "$NOETL_SERVER_DEPLOY"; roll "$NOETL_SYSTEM_POOL_DEPLOY"; sleep 5

# ======================================================================
# PASS A — barrier ON: side-effecting re-drive is SKIPPED (fires once).
# ======================================================================
echo; echo "================================================================"
echo "kind-val: PASS A — NOETL_SIDE_EFFECT_BARRIER ON (side-effecting re-drive skipped)"
echo "================================================================"
"${KCTX[@]}" set env deploy/"$NOETL_WORKER_POOL_DEPLOY" NOETL_SIDE_EFFECT_BARRIER=true >/dev/null
roll "$NOETL_WORKER_POOL_DEPLOY"; sleep 8

# The orchestrator wraps every step's tool(s) in a `task_sequence` command, so
# the dispatched command kind — and thus the barrier metric's `tool` label — is
# `task_sequence`; the gate classifies by the INNER tool (start's python is
# side-effecting; pure's noop is not).
SK0="$(worker_metric 'noetl_worker_side_effect_barrier_total\{outcome="skipped",tool="task_sequence"\}')"
launch_leg; A_EID="$LEG_EID"; await_leg
[[ "$LEG_STATUS" == "COMPLETED" ]] || fail "PASS A primary leg did not COMPLETE (got $LEG_STATUS)"
[[ "$LEG_PASS" -ge 1 ]] || fail "PASS A primary leg did not bind the bulk (test_passed!=true)"
A_M1="$(marker_count "$A_EID")"
echo "kind-val: PASS A primary — marker_count=$A_M1 (want 1) status=$LEG_STATUS test_passed=$LEG_PASS"
[[ "$A_M1" == "1" ]] || fail "PASS A primary side effect did not fire exactly once (marker_count=$A_M1)"
assert_invariants "$A_EID" "PASS A primary"
await_tier "$A_EID" || fail "PASS A charge tier object never appeared — barrier cannot resolve it"

# Re-drive `charge`: the barrier must SKIP (URN exists) — marker stays 1.
forge_redrive "$A_EID" "start" >/dev/null
echo "kind-val: PASS A — awaiting re-drive settle"; sleep 20
A_M2="$(marker_count "$A_EID")"
SK1="$(worker_metric 'noetl_worker_side_effect_barrier_total\{outcome="skipped",tool="task_sequence"\}')"
echo "kind-val: PASS A re-drive — marker_count=$A_M2 (want 1) barrier{skipped} Δ=$((SK1-SK0))"
[[ "$A_M2" == "1" ]] || fail "PASS A barrier did NOT skip — side effect re-fired (marker_count=$A_M2, expected 1)"
[[ $((SK1-SK0)) -ge 1 ]] || fail "PASS A barrier did not record a skip (skipped Δ0)"

# ======================================================================
# PASS B — barrier OFF: side-effecting re-drive RE-EXECUTES (fires twice).
# ======================================================================
echo; echo "================================================================"
echo "kind-val: PASS B — barrier OFF (re-drive re-executes; true no-op)"
echo "================================================================"
"${KCTX[@]}" set env deploy/"$NOETL_WORKER_POOL_DEPLOY" NOETL_SIDE_EFFECT_BARRIER=false >/dev/null
roll "$NOETL_WORKER_POOL_DEPLOY"; sleep 8

BAR0="$(worker_metric 'noetl_worker_side_effect_barrier_total')"
launch_leg; B_EID="$LEG_EID"; await_leg
[[ "$LEG_STATUS" == "COMPLETED" ]] || fail "PASS B primary leg did not COMPLETE (got $LEG_STATUS)"
B_M1="$(marker_count "$B_EID")"
echo "kind-val: PASS B primary — marker_count=$B_M1 (want 1) status=$LEG_STATUS"
[[ "$B_M1" == "1" ]] || fail "PASS B primary side effect did not fire exactly once (marker_count=$B_M1)"
assert_invariants "$B_EID" "PASS B primary"
await_tier "$B_EID" || true

forge_redrive "$B_EID" "start" >/dev/null
echo "kind-val: PASS B — awaiting re-drive settle"; sleep 20
B_M2="$(marker_count "$B_EID")"
BAR1="$(worker_metric 'noetl_worker_side_effect_barrier_total')"
echo "kind-val: PASS B re-drive — marker_count=$B_M2 (want 2) barrier_total Δ=$((BAR1-BAR0))"
[[ "$B_M2" == "2" ]] || fail "PASS B (barrier off) re-drive did not re-execute (marker_count=$B_M2, expected 2)"
[[ $((BAR1-BAR0)) -eq 0 ]] || fail "PASS B (flag off) moved the barrier metric (Δ=$((BAR1-BAR0)) != 0) — not a no-op"

# ======================================================================
# PASS C — barrier ON: NON-side-effecting (noop) re-drive is never blocked.
# ======================================================================
echo; echo "================================================================"
echo "kind-val: PASS C — barrier ON, re-drive a NON-side-effecting (noop) step"
echo "================================================================"
"${KCTX[@]}" set env deploy/"$NOETL_WORKER_POOL_DEPLOY" NOETL_SIDE_EFFECT_BARRIER=true >/dev/null
roll "$NOETL_WORKER_POOL_DEPLOY"; sleep 8

launch_leg; C_EID="$LEG_EID"; await_leg
[[ "$LEG_STATUS" == "COMPLETED" ]] || fail "PASS C primary leg did not COMPLETE (got $LEG_STATUS)"
C_M1="$(marker_count "$C_EID")"
assert_invariants "$C_EID" "PASS C primary"
# `pure` is the TERMINAL noop step — a re-drive of it dispatches noop (the gate
# short-circuits: a task_sequence wrapping only noop is non-side-effecting) and,
# being terminal, cascades nothing. So the WHOLE barrier counter must not move.
BAR_C0="$(worker_metric 'noetl_worker_side_effect_barrier_total')"
forge_redrive "$C_EID" "pure" >/dev/null
echo "kind-val: PASS C — awaiting noop re-drive settle"; sleep 18
C_M2="$(marker_count "$C_EID")"
BAR_C1="$(worker_metric 'noetl_worker_side_effect_barrier_total')"
echo "kind-val: PASS C — marker_count primary=$C_M1 after-redrive=$C_M2 (unchanged) barrier_total Δ=$((BAR_C1-BAR_C0))"
[[ "$C_M2" == "$C_M1" ]] || fail "PASS C noop re-drive changed the side-effect counter ($C_M1 -> $C_M2)"
[[ $((BAR_C1-BAR_C0)) -eq 0 ]] || fail "PASS C barrier CHECKED a non-side-effecting (noop) cycle (Δ=$((BAR_C1-BAR_C0)) != 0) — gate should short-circuit"

# ----------------------------------------------------------------------
# Report.
# ----------------------------------------------------------------------
echo
if [[ "$OVERALL" -eq 0 ]]; then
  echo "================================================================"
  echo "kind-val: PASS — #104 Phase E side-effect durability barrier"
  echo "  PASS A : exec $A_EID — barrier ON; primary fired once (marker=1), re-drive of"
  echo "           charge SKIPPED (marker stayed 1, barrier{skipped,python} Δ>0). Fired exactly once."
  echo "  PASS B : exec $B_EID — barrier OFF; re-drive RE-EXECUTED (marker 1->2),"
  echo "           barrier metric Δ0 (true no-op)."
  echo "  PASS C : exec $C_EID — barrier ON; noop re-drive never checked (barrier{noop} Δ0),"
  echo "           side-effect counter unchanged — non-side-effecting cycles unaffected."
  echo "  invariants (sole-writer, roots=1, dangling=0, walk==rows, terminal==1) intact on every primary."
  echo "================================================================"
  exit 0
fi

echo "================================================================"
echo "kind-val: FAIL — see assertion errors above"
echo "================================================================"
echo "kind-val: server logs (tail 60):"; "${KCTX[@]}" logs deploy/"$NOETL_SERVER_DEPLOY" --tail=60 || true
echo; echo "kind-val: worker-pool logs (tail 120):"; "${KCTX[@]}" logs deploy/"$NOETL_WORKER_POOL_DEPLOY" --tail=120 || true
echo; echo "kind-val: system-pool logs (tail 60):"; "${KCTX[@]}" logs deploy/"$NOETL_SYSTEM_POOL_DEPLOY" --tail=60 || true
exit 1

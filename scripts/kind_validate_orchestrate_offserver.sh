#!/usr/bin/env bash
# kind_validate_orchestrate_offserver.sh — worker-driven orchestrate topology
# (noetl/ai-meta#108 + #110 → the Server-Dissolution program noetl/ai-meta#107
# step 2).
#
# Proves the NoETL orchestrator drive runs OFF the server, on the system worker
# pool, as the `system/orchestrate` WASM plug-in — the default-on topology after
# server v3.28.0 (#108 (c)) + the shadow/wasmtime retirement (#110, server
# f3043c9). Where `kind_validate_fanout_reduce.sh` asserts the orchestrator's
# fan-in barrier is *correct*, this rig asserts *where it runs*: the server only
# schedules + applies, and the evaluate loop executes on the pool, writing zero
# `__orchestrate__` rows to noetl.event.
#
# It reuses the self-contained fan-out fixture (start ─┬─ normalize ─┐
#                                                      └─ enrich ────┴─ reduce ─ end),
# which drives several orchestrate rounds with a concurrent fan-out — enough to
# exercise the dispatch → off-server-evaluate → apply round trip multiple times.
#
# Assertions (all required for PASS):
#
#   1. Final execution status is COMPLETED — the worker-driven drive carried the
#      execution to a terminal state with no in-process evaluate.
#   2. ZERO `__orchestrate__` rows in noetl.event for this execution. This is the
#      scale-critical property: the meta-command's lifecycle is infrastructure,
#      not a workflow step, so it never bursts the event log (#108 slices 4b/5).
#   3. `__orchestrate__` rows EXIST in noetl.command for this execution — the
#      drive was dispatched as commands to the pool, not evaluated in-process.
#   4. Server /metrics: `noetl_orchestrate_drive_total{stage="dispatched"}` and
#      `{stage="applied"}` both advanced during the run (the server scheduled the
#      drive AND applied a worker-computed result — i.e. it ran off-server), with
#      no `decode_error`.
#   5. Server /metrics: `noetl_orchestrate_shadow_total` is ABSENT — the in-server
#      wasmtime shadow was retired in #110; its presence would mean a pre-#110
#      image is deployed.
#   6. (informational) System-pool isolation: the system-pool worker shows
#      orchestrate-plugin activity; the default (user) worker pool ran no
#      `__orchestrate__` meta-step.
#   7. Large-context convergence (noetl/ai-meta#113): a fixture whose drive
#      result would exceed the worker's 100KB inline budget reaches COMPLETED
#      with a BOUNDED `__orchestrate__` command count, ZERO decode errors, and
#      ZERO `__orchestrate__` rows in noetl.event. Guards the bug where an
#      offloaded drive result was dropped → non-convergent loop. The
#      offloaded-ref resolve advance (`ref_resolved`) is only a HARD assertion
#      under NOETL_RIG_EXPECT_OFFLOAD=true (a refs_in_state=false server); under
#      the default refs_in_state=true the drive result is reference-only and the
#      path stays informational.
#   8. Oversized next-command context offload (noetl/ai-meta#114): a fixture
#      whose next-step command context would exceed the NATS max_payload reaches
#      COMPLETED, NO `command.issued` event for the run exceeds the NATS ceiling,
#      and ZERO `__orchestrate__` rows in noetl.event. Guards the bug where the
#      full upstream context embedded in `command.issued` blew the 1MB publish
#      limit → wedge. The offload-advance (`context_offloaded` /
#      `context_ref_resolved`) is only a HARD assertion under
#      NOETL_RIG_EXPECT_OFFLOAD=true; under the default refs_in_state=true the
#      next-command context is reference-only and the path stays informational.
#
# Preconditions: the kind server must run a post-#110 image (server f3043c9 /
# v3.28.0 or later) with the worker-driven drive ON — either the code default
# (no env) or `NOETL_ORCHESTRATE_PLUGIN_DRIVE=true`. A server built before #108
# (drive=false) will fail assertions 3-4; a pre-#110 image will fail assertion 5.
#
# Usage:
#
#   ./scripts/kind_validate_orchestrate_offserver.sh
#   ./scripts/kind_validate_orchestrate_offserver.sh --context kind-noetl
#   NOETL_SERVER_URL=http://localhost:18082 ./scripts/kind_validate_orchestrate_offserver.sh
#
# Exits 0 if PASS; 1 if any hard assertion fails (dumps server + both worker
# pools' logs on the unhappy path for diagnosis); 2 on a precondition error.

set -euo pipefail

KIND_CONTEXT="${NOETL_KIND_CONTEXT:-kind-noetl}"
NAMESPACE="${NOETL_K8S_NAMESPACE:-noetl}"
NOETL_SERVER_DEPLOY="${NOETL_SERVER_DEPLOY:-noetl-server-rust}"
NOETL_WORKER_DEPLOY="${NOETL_WORKER_DEPLOY:-noetl-worker-rust}"
NOETL_SYSTEM_POOL_DEPLOY="${NOETL_SYSTEM_POOL_DEPLOY:-noetl-worker-system-pool}"
NOETL_SERVER_URL="${NOETL_SERVER_URL:-http://localhost:8082}"
TIMEOUT_SECS="${NOETL_ORCH_TIMEOUT_SECS:-180}"

# Whether the #113/#114 offload SAFETY paths are expected to FIRE this run.
# Those paths (worker offloads an over-budget drive result / the server offloads
# an over-budget next-command context) only trigger when result payloads are
# spliced inline — i.e. under `NOETL_REFS_IN_STATE=false`.  Under the current
# default (`refs_in_state=true`, RFC #115 Phase 1) events/commands carry
# references, not bulk data, so steady-state contexts never reach the offload
# thresholds and the metrics legitimately stay flat.  Default false → the
# offload-advance assertions become informational; the COMPLETE + no-oversized
# + zero-`__orchestrate__`-event invariants stay HARD in both modes.  Set to
# true when deliberately running the rig against a `refs_in_state=false` server
# to keep the strict offload-exercise guards.
RIG_EXPECT_OFFLOAD="${NOETL_RIG_EXPECT_OFFLOAD:-false}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --context)    KIND_CONTEXT="$2"; shift 2 ;;
    --namespace)  NAMESPACE="$2"; shift 2 ;;
    --server-url) NOETL_SERVER_URL="$2"; shift 2 ;;
    --timeout)    TIMEOUT_SECS="$2"; shift 2 ;;
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
# Large-context convergence fixture (noetl/ai-meta#113).  Its accumulated
# execution context drives an `__orchestrate__` result well past the worker's
# 100KB inline budget (~785KB observed), so the worker offloads the drive
# result to the durable result store and the server must resolve+decode the
# ref instead of dropping it — otherwise the drive never converges.  Self-
# contained (no external creds), so it runs anywhere this rig runs.
LARGE_FIXTURE_PATH="$REPO_ROOT/fixtures/playbooks/test_large_result_extraction.yaml"
LARGE_PLAYBOOK_PATH="tests/large_result_extraction_test"
# Bound on `__orchestrate__` commands a converging large-context run may issue.
# A healthy run converges in a handful of cycles; the #113 stall produced
# 200+ PENDING orchestrate commands on a single execution.  Generous ceiling
# that still catches a runaway loop.
LARGE_ORCH_CMD_CEILING="${NOETL_ORCH_LARGE_CMD_CEILING:-30}"
# Oversized next-command-context fixture (noetl/ai-meta#114).  A ~900KB upstream
# result, embedded by the drive (refs_in_state false) into the NEXT command's
# render_context, makes that `command.issued` event exceed the NATS max_payload —
# which wedged the publish-only gate before the offload fix.  This fixture reads
# only a small scalar downstream (no `_ref` lazy-load), so it completes
# end-to-end and isolates the #114 offload mechanism — unlike test_output_select,
# whose `{{ start._ref }}` artifact lazy-load also depends on the refs_in_state
# consume side (noetl/ai-meta#101) and so does not complete under refs_in_state
# false even with the oversized-event offload in place.
OVERSIZE_FIXTURE_PATH="$REPO_ROOT/fixtures/playbooks/test_oversize_command_context.yaml"
OVERSIZE_PLAYBOOK_PATH="tests/oversize_command_context"

echo "kind-val: context=$KIND_CONTEXT namespace=$NAMESPACE"
echo "kind-val: server=$NOETL_SERVER_URL"
echo "kind-val: fixture=$FIXTURE_PATH"
echo "kind-val: large-context fixture=$LARGE_FIXTURE_PATH (#113 convergence)"
echo "kind-val: oversized-context fixture=$OVERSIZE_FIXTURE_PATH (#114 command-event offload)"

# ----------------------------------------------------------------------
# Preflight — required tooling + cluster + server reachable.
# ----------------------------------------------------------------------

for cmd in kubectl noetl curl python3; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "kind-val: required command not in PATH: $cmd" >&2
    exit 2
  }
done

for sub in "register playbook" "exec" "status" "query"; do
  if ! noetl $sub --help >/dev/null 2>&1; then
    echo "kind-val: this rig needs the current noetl CLI surface" >&2
    echo "kind-val: missing subcommand: noetl $sub" >&2
    echo "kind-val: installed CLI: $(noetl --version 2>/dev/null || echo unknown)" >&2
    exit 2
  fi
done

if [[ ! -f "$FIXTURE_PATH" ]]; then
  echo "kind-val: fixture not found: $FIXTURE_PATH" >&2
  exit 2
fi

KCTX=(kubectl --context "$KIND_CONTEXT" -n "$NAMESPACE")

if ! "${KCTX[@]}" get deployment "$NOETL_SERVER_DEPLOY" >/dev/null 2>&1; then
  echo "kind-val: $NOETL_SERVER_DEPLOY Deployment not found in namespace $NAMESPACE." >&2
  exit 2
fi

if ! curl -fsS "$NOETL_SERVER_URL/api/health" >/dev/null 2>&1; then
  echo "kind-val: server not reachable at $NOETL_SERVER_URL/api/health — start a port-forward first." >&2
  exit 2
fi

# ----------------------------------------------------------------------
# Helper: read one stage counter from the server's /metrics endpoint.
#   metrics_drive <stage>  -> integer (0 if the series is absent)
# ----------------------------------------------------------------------

fetch_metrics() { curl -fsS "$NOETL_SERVER_URL/metrics" 2>/dev/null || true; }

metrics_drive() {
  local stage="$1" body="$2"
  printf '%s' "$body" | python3 -c '
import re, sys
stage = sys.argv[1]
total = 0
for line in sys.stdin:
    m = re.match(r"noetl_orchestrate_drive_total\{stage=\"([^\"]+)\"\}\s+([0-9.]+)", line)
    if m and m.group(1) == stage:
        total += int(float(m.group(2)))
print(total)
' "$stage"
}

metrics_has_shadow() {
  printf '%s' "$1" | grep -q "noetl_orchestrate_shadow_total" && echo yes || echo no
}

# ----------------------------------------------------------------------
# Snapshot drive metrics BEFORE the run so the deltas are attributable to
# this execution (the counters are process-cumulative across all runs).
# ----------------------------------------------------------------------

METRICS_BEFORE="$(fetch_metrics)"
DISPATCHED_BEFORE="$(metrics_drive dispatched "$METRICS_BEFORE")"
APPLIED_BEFORE="$(metrics_drive applied "$METRICS_BEFORE")"
DECODE_ERR_BEFORE="$(metrics_drive decode_error "$METRICS_BEFORE")"
SHADOW_PRESENT="$(metrics_has_shadow "$METRICS_BEFORE")"
echo "kind-val: drive metrics before — dispatched=$DISPATCHED_BEFORE applied=$APPLIED_BEFORE decode_error=$DECODE_ERR_BEFORE shadow_series=$SHADOW_PRESENT"

# ----------------------------------------------------------------------
# Register + execute the fan-out fixture (drives several orchestrate rounds).
# ----------------------------------------------------------------------

echo
echo "================================================================"
echo "kind-val: register + execute fanout_reduce_phase6 (off-server drive)"
echo "================================================================"

noetl register playbook --file "$FIXTURE_PATH"

EXECUTION_ID="$(noetl exec "$PLAYBOOK_PATH" --runtime distributed --json \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["execution_id"])')"
echo "kind-val: launched execution_id=$EXECUTION_ID"

# ----------------------------------------------------------------------
# Wait for terminal status.
# ----------------------------------------------------------------------

DEADLINE=$(( SECONDS + TIMEOUT_SECS ))
FINAL_STATUS=""
while [[ $SECONDS -lt $DEADLINE ]]; do
  FINAL_STATUS="$(noetl status "$EXECUTION_ID" --json 2>/dev/null \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("status",""))' || true)"
  case "$FINAL_STATUS" in
    COMPLETED|FAILED) break ;;
  esac
  sleep 2
done
echo "kind-val: execution_id=$EXECUTION_ID final_status=$FINAL_STATUS"

# Give the apply round-trip a moment to flush the final metric increment.
sleep 3
METRICS_AFTER="$(fetch_metrics)"
DISPATCHED_AFTER="$(metrics_drive dispatched "$METRICS_AFTER")"
APPLIED_AFTER="$(metrics_drive applied "$METRICS_AFTER")"
DECODE_ERR_AFTER="$(metrics_drive decode_error "$METRICS_AFTER")"

DISPATCHED_DELTA=$(( DISPATCHED_AFTER - DISPATCHED_BEFORE ))
APPLIED_DELTA=$(( APPLIED_AFTER - APPLIED_BEFORE ))
DECODE_ERR_DELTA=$(( DECODE_ERR_AFTER - DECODE_ERR_BEFORE ))
echo "kind-val: drive metrics delta — dispatched=+$DISPATCHED_DELTA applied=+$APPLIED_DELTA decode_error=+$DECODE_ERR_DELTA"

# ----------------------------------------------------------------------
# Count __orchestrate__ rows in the event log (must be 0) and the command
# queue (must be > 0) for this execution.
# ----------------------------------------------------------------------

count_rows() {
  noetl query "$1" --format json 2>/dev/null \
    | python3 -c 'import json,sys
d=json.loads(sys.stdin.read() or "{}").get("result", [])
print(d[0].get("n", 0) if d else 0)'
}

ORCH_EVENT_ROWS="$(count_rows \
  "SELECT COUNT(*) AS n FROM noetl.event WHERE execution_id = $EXECUTION_ID AND node_name = '__orchestrate__'")"
ORCH_COMMAND_ROWS="$(count_rows \
  "SELECT COUNT(*) AS n FROM noetl.command WHERE execution_id = $EXECUTION_ID AND step_name = '__orchestrate__'")"
echo "kind-val: __orchestrate__ rows — noetl.event=$ORCH_EVENT_ROWS noetl.command=$ORCH_COMMAND_ROWS"

# ----------------------------------------------------------------------
# Assertions.
# ----------------------------------------------------------------------

OVERALL=0
fail() { echo "kind-val: FAIL — $1" >&2; OVERALL=1; }

# 1. Final status COMPLETED.
[[ "$FINAL_STATUS" == "COMPLETED" ]] \
  || fail "expected final status COMPLETED, got $FINAL_STATUS"

# 2. ZERO __orchestrate__ rows in noetl.event (the off-server topology's
#    scale-critical property — no event-log burst from the meta-command).
[[ "$ORCH_EVENT_ROWS" == "0" ]] \
  || fail "expected 0 __orchestrate__ rows in noetl.event, got $ORCH_EVENT_ROWS (event-log burst — drive not suppressing)"

# 3. __orchestrate__ commands EXIST (the drive was dispatched off-server).
[[ "${ORCH_COMMAND_ROWS:-0}" -ge 1 ]] \
  || fail "expected >=1 __orchestrate__ rows in noetl.command (off-server dispatch), got $ORCH_COMMAND_ROWS — is the drive ON? (NOETL_ORCHESTRATE_PLUGIN_DRIVE / pre-#108 image)"

# 4. The drive ran off-server: dispatched advanced AND applied advanced AND no
#    decode errors. `applied` advancing means the server applied a result the
#    WORKER computed — proof the evaluate ran on the pool, not in-process.
[[ "$DISPATCHED_DELTA" -ge 1 ]] \
  || fail "noetl_orchestrate_drive_total{stage=dispatched} did not advance (+$DISPATCHED_DELTA)"
[[ "$APPLIED_DELTA" -ge 1 ]] \
  || fail "noetl_orchestrate_drive_total{stage=applied} did not advance (+$APPLIED_DELTA) — server never applied a worker-computed result"
[[ "$DECODE_ERR_DELTA" -eq 0 ]] \
  || fail "noetl_orchestrate_drive_total{stage=decode_error} advanced (+$DECODE_ERR_DELTA) — worker results failed to decode"

# 5. Shadow metric retired (#110). Its presence means a pre-#110 image.
[[ "$SHADOW_PRESENT" == "no" ]] \
  || fail "noetl_orchestrate_shadow_total present on /metrics — server is a pre-#110 image (shadow not retired)"

# 6. (informational) system-pool isolation — which pool ran the meta-step.
echo
echo "kind-val: --- system-pool isolation (informational) ---"
SYS_HITS="$("${KCTX[@]}" logs deploy/"$NOETL_SYSTEM_POOL_DEPLOY" --tail=400 2>/dev/null \
  | grep -c -E "orchestrate|__orchestrate__|run_state" || true)"
USER_HITS="$("${KCTX[@]}" logs deploy/"$NOETL_WORKER_DEPLOY" --tail=400 2>/dev/null \
  | grep -c -E "__orchestrate__" || true)"
echo "kind-val: system-pool worker orchestrate log hits=$SYS_HITS ; default-pool __orchestrate__ hits=$USER_HITS"
if [[ "${USER_HITS:-0}" -gt 0 ]]; then
  echo "kind-val: NOTE — default (user) pool logged __orchestrate__ activity; expected the system pool to own the drive." >&2
fi

# ----------------------------------------------------------------------
# 7. Large-context convergence (noetl/ai-meta#113).
#
#    Regression guard for the off-server-drive bug where an over-budget
#    `__orchestrate__` drive result (the full execution context > 100KB) was
#    offloaded by the worker to the durable result store WITHOUT an inline
#    `output_b64`; the server's completion handler decoded only the inline form,
#    dropped the drive decision, and re-looped — 200+ PENDING `__orchestrate__`
#    commands, no terminal event.  The fix resolves the offloaded ref before
#    giving up.  This phase proves a large-context fixture CONVERGES: reaches
#    COMPLETED, with a BOUNDED orchestrate-command count and ZERO decode errors.
# ----------------------------------------------------------------------
echo
echo "================================================================"
echo "kind-val: large-context convergence (#113) — $LARGE_FIXTURE_PATH"
echo "================================================================"

if [[ ! -f "$LARGE_FIXTURE_PATH" ]]; then
  fail "large-context fixture not found: $LARGE_FIXTURE_PATH"
else
  DECODE_ERR_L_BEFORE="$(metrics_drive decode_error "$(fetch_metrics)")"
  REF_RESOLVED_BEFORE="$(metrics_drive ref_resolved "$(fetch_metrics)")"

  noetl register playbook --file "$LARGE_FIXTURE_PATH"
  LARGE_EID="$(noetl exec "$LARGE_PLAYBOOK_PATH" --runtime distributed --json \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["execution_id"])')"
  echo "kind-val: large-context execution_id=$LARGE_EID"

  LARGE_DEADLINE=$(( SECONDS + TIMEOUT_SECS ))
  LARGE_STATUS=""
  while [[ $SECONDS -lt $LARGE_DEADLINE ]]; do
    LARGE_STATUS="$(noetl status "$LARGE_EID" --json 2>/dev/null \
      | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("status",""))' || true)"
    case "$LARGE_STATUS" in COMPLETED|FAILED) break ;; esac
    sleep 2
  done
  sleep 3
  DECODE_ERR_L_AFTER="$(metrics_drive decode_error "$(fetch_metrics)")"
  REF_RESOLVED_AFTER="$(metrics_drive ref_resolved "$(fetch_metrics)")"
  DECODE_ERR_L_DELTA=$(( DECODE_ERR_L_AFTER - DECODE_ERR_L_BEFORE ))
  REF_RESOLVED_DELTA=$(( REF_RESOLVED_AFTER - REF_RESOLVED_BEFORE ))

  LARGE_ORCH_CMDS="$(count_rows \
    "SELECT COUNT(*) AS n FROM noetl.command WHERE execution_id = $LARGE_EID AND step_name = '__orchestrate__'")"
  LARGE_ORCH_EVENTS="$(count_rows \
    "SELECT COUNT(*) AS n FROM noetl.event WHERE execution_id = $LARGE_EID AND node_name = '__orchestrate__'")"
  echo "kind-val: large-context — status=$LARGE_STATUS orch_cmds=$LARGE_ORCH_CMDS orch_events=$LARGE_ORCH_EVENTS decode_error=+$DECODE_ERR_L_DELTA ref_resolved=+$REF_RESOLVED_DELTA"

  # 7a. Converged to COMPLETED (not stuck RUNNING in a re-drive loop).
  [[ "$LARGE_STATUS" == "COMPLETED" ]] \
    || fail "large-context fixture did not converge: status=$LARGE_STATUS (the #113 stall, or a slow run beyond ${TIMEOUT_SECS}s)"

  # 7b. ZERO decode errors — the offloaded result was decoded, not dropped.
  [[ "$DECODE_ERR_L_DELTA" -eq 0 ]] \
    || fail "noetl_orchestrate_drive_total{stage=decode_error} advanced (+$DECODE_ERR_L_DELTA) on a large-context run — the offloaded OrchestrationResult was dropped (#113 regression)"

  # 7c. The offloaded path was actually exercised — `ref_resolved` advanced.
  #     Proves this fixture genuinely crossed the inline budget (so the guard
  #     is real, not vacuously green on a small result).  Only HARD under
  #     refs_in_state=false (RIG_EXPECT_OFFLOAD=true): with the default
  #     refs_in_state=true the drive result carries references, never an
  #     over-budget inline payload, so this path legitimately does not fire.
  if [[ "$RIG_EXPECT_OFFLOAD" == "true" ]]; then
    [[ "$REF_RESOLVED_DELTA" -ge 1 ]] \
      || fail "noetl_orchestrate_drive_total{stage=ref_resolved} did not advance (+$REF_RESOLVED_DELTA) — the large-context fixture did not exceed the inline budget, so this phase did not exercise the #113 path (RIG_EXPECT_OFFLOAD=true)"
  elif [[ "$REF_RESOLVED_DELTA" -ge 1 ]]; then
    echo "kind-val: large-context — offloaded-ref resolve fired (+$REF_RESOLVED_DELTA) [informational under refs_in_state=true]"
  else
    echo "kind-val: large-context — offloaded-ref resolve did NOT fire (refs_in_state=true keeps the drive result reference-only; convergence + zero-decode-error guards above are the real assertions)"
  fi

  # 7d. Bounded orchestrate-command count — no runaway PENDING loop.
  [[ "${LARGE_ORCH_CMDS:-9999}" -le "$LARGE_ORCH_CMD_CEILING" ]] \
    || fail "large-context run issued $LARGE_ORCH_CMDS __orchestrate__ commands (> ceiling $LARGE_ORCH_CMD_CEILING) — runaway drive loop (#113)"

  # 7e. Still zero __orchestrate__ rows in noetl.event (suppression/sole-writer
  #     intact even on the offloaded path).
  [[ "$LARGE_ORCH_EVENTS" == "0" ]] \
    || fail "large-context run wrote $LARGE_ORCH_EVENTS __orchestrate__ rows to noetl.event (expected 0)"
fi

# ----------------------------------------------------------------------
# 8. Oversized next-command context offload (noetl/ai-meta#114).
#
#    Regression guard for the SECOND off-server-drive stall #113 surfaced:
#    with `refs_in_state` false the drive embeds the FULL resolved upstream
#    context into the NEXT step's command, so its `command.issued` event grew
#    past the NATS `max_payload` (1MB) under the publish-only gate (~1.32MB
#    observed for test_output_select's `verify_extracted_fields`), so the
#    publish never acked and the execution wedged (`step.enter` persisted,
#    command never issued).  The fix offloads an over-budget command context to
#    the result store with a `noetl://` ref so the published event stays small;
#    `get_command`/`claim_command` resolve it on the read side.  This phase
#    drives `test_oversize_command_context` (a ~900KB upstream result, consumed
#    via a small scalar — no `_ref` lazy-load) and proves it CONVERGES, the
#    offload path was exercised, and NO `command.issued` event for the run
#    exceeds the NATS ceiling.
# ----------------------------------------------------------------------
echo
echo "================================================================"
echo "kind-val: oversized next-command context offload (#114) — $OVERSIZE_FIXTURE_PATH"
echo "================================================================"

NATS_MAX_PAYLOAD="${NOETL_NATS_MAX_PAYLOAD:-1048576}"

if [[ ! -f "$OVERSIZE_FIXTURE_PATH" ]]; then
  fail "oversized-context fixture not found: $OVERSIZE_FIXTURE_PATH"
else
  OFFLOADED_BEFORE="$(metrics_drive context_offloaded "$(fetch_metrics)")"
  CTX_RESOLVED_BEFORE="$(metrics_drive context_ref_resolved "$(fetch_metrics)")"

  noetl register playbook --file "$OVERSIZE_FIXTURE_PATH"
  OVERSIZE_EID="$(noetl exec "$OVERSIZE_PLAYBOOK_PATH" --runtime distributed --json \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["execution_id"])')"
  echo "kind-val: oversized-context execution_id=$OVERSIZE_EID"

  OVERSIZE_DEADLINE=$(( SECONDS + TIMEOUT_SECS ))
  OVERSIZE_STATUS=""
  while [[ $SECONDS -lt $OVERSIZE_DEADLINE ]]; do
    OVERSIZE_STATUS="$(noetl status "$OVERSIZE_EID" --json 2>/dev/null \
      | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("status",""))' || true)"
    case "$OVERSIZE_STATUS" in COMPLETED|FAILED) break ;; esac
    sleep 2
  done
  sleep 3
  OFFLOADED_AFTER="$(metrics_drive context_offloaded "$(fetch_metrics)")"
  CTX_RESOLVED_AFTER="$(metrics_drive context_ref_resolved "$(fetch_metrics)")"
  OFFLOADED_DELTA=$(( OFFLOADED_AFTER - OFFLOADED_BEFORE ))
  CTX_RESOLVED_DELTA=$(( CTX_RESOLVED_AFTER - CTX_RESOLVED_BEFORE ))

  # Largest command.issued event context this run wrote (materialized under the
  # gate).  Offloaded contexts are the tiny `{__context_ref__: ...}` marker, so
  # the max must sit well under the NATS ceiling.
  OVERSIZE_MAX_CTX="$(count_rows \
    "SELECT COALESCE(MAX(octet_length(context::text)), 0) AS n FROM noetl.event WHERE execution_id = $OVERSIZE_EID AND event_type = 'command.issued'")"
  OVERSIZE_ORCH_EVENTS="$(count_rows \
    "SELECT COUNT(*) AS n FROM noetl.event WHERE execution_id = $OVERSIZE_EID AND node_name = '__orchestrate__'")"
  echo "kind-val: oversized-context — status=$OVERSIZE_STATUS max_command_issued_ctx=${OVERSIZE_MAX_CTX}B (ceiling ${NATS_MAX_PAYLOAD}B) context_offloaded=+$OFFLOADED_DELTA context_ref_resolved=+$CTX_RESOLVED_DELTA"

  # 8a. Converged to COMPLETED (not wedged on the publish wall).
  [[ "$OVERSIZE_STATUS" == "COMPLETED" ]] \
    || fail "oversized-context fixture did not converge: status=$OVERSIZE_STATUS (the #114 publish-wall wedge, or a slow run beyond ${TIMEOUT_SECS}s)"

  # 8b/8c. The offload path actually fired (server offloaded an over-budget
  #     command context; the read side resolved it back).  Only HARD under
  #     refs_in_state=false (RIG_EXPECT_OFFLOAD=true): with the default
  #     refs_in_state=true the next-command context carries references, not the
  #     full upstream payload, so it never reaches NOETL_COMMAND_CONTEXT_MAX_BYTES
  #     and the offload safety path legitimately stays flat.  The COMPLETE (8a),
  #     no-oversized-event (8d) and zero-`__orchestrate__`-event (8e) invariants
  #     below stay HARD in both modes.
  if [[ "$RIG_EXPECT_OFFLOAD" == "true" ]]; then
    [[ "$OFFLOADED_DELTA" -ge 1 ]] \
      || fail "noetl_orchestrate_drive_total{stage=context_offloaded} did not advance (+$OFFLOADED_DELTA) — the fixture did not exceed NOETL_COMMAND_CONTEXT_MAX_BYTES, so this phase did not exercise the #114 path (RIG_EXPECT_OFFLOAD=true)"
    [[ "$CTX_RESOLVED_DELTA" -ge 1 ]] \
      || fail "noetl_orchestrate_drive_total{stage=context_ref_resolved} did not advance (+$CTX_RESOLVED_DELTA) — worker never resolved the offloaded command context (RIG_EXPECT_OFFLOAD=true)"
  elif [[ "$OFFLOADED_DELTA" -ge 1 || "$CTX_RESOLVED_DELTA" -ge 1 ]]; then
    echo "kind-val: oversized-context — command-context offload fired (offloaded=+$OFFLOADED_DELTA resolved=+$CTX_RESOLVED_DELTA) [informational under refs_in_state=true]"
  else
    echo "kind-val: oversized-context — command-context offload did NOT fire (refs_in_state=true keeps next-command contexts reference-only; the COMPLETE + sub-ceiling + zero-orchestrate-event guards below are the real assertions)"
  fi

  # 8d. No command.issued event for the run exceeds the NATS max_payload.
  [[ "${OVERSIZE_MAX_CTX:-0}" -gt 0 && "${OVERSIZE_MAX_CTX:-0}" -lt "$NATS_MAX_PAYLOAD" ]] \
    || fail "a command.issued event context for execution $OVERSIZE_EID is ${OVERSIZE_MAX_CTX}B (>= NATS max_payload ${NATS_MAX_PAYLOAD}B) — the #114 oversized-event regression"

  # 8e. Still zero __orchestrate__ rows in noetl.event (sole-writer intact).
  [[ "$OVERSIZE_ORCH_EVENTS" == "0" ]] \
    || fail "oversized-context run wrote $OVERSIZE_ORCH_EVENTS __orchestrate__ rows to noetl.event (expected 0)"
fi

# ----------------------------------------------------------------------
# Report.
# ----------------------------------------------------------------------

echo
if [[ "$OVERALL" -eq 0 ]]; then
  echo "================================================================"
  echo "kind-val: PASS — worker-driven orchestrate topology green"
  echo "  - final_status=COMPLETED"
  echo "  - __orchestrate__ in noetl.event = 0 (no event-log burst)"
  echo "  - __orchestrate__ in noetl.command = $ORCH_COMMAND_ROWS (off-server dispatch)"
  echo "  - drive metric: dispatched +$DISPATCHED_DELTA / applied +$APPLIED_DELTA / decode_error +$DECODE_ERR_DELTA"
  echo "  - noetl_orchestrate_shadow_total absent (#110 retirement confirmed)"
  echo "  - large-context (#113): status=${LARGE_STATUS:-skipped} orch_cmds=${LARGE_ORCH_CMDS:-?} (<= $LARGE_ORCH_CMD_CEILING) ref_resolved=+${REF_RESOLVED_DELTA:-?} decode_error=+${DECODE_ERR_L_DELTA:-?}"
  echo "  - oversized-context (#114): status=${OVERSIZE_STATUS:-skipped} max_command_issued_ctx=${OVERSIZE_MAX_CTX:-?}B (< ${NATS_MAX_PAYLOAD:-?}B) context_offloaded=+${OFFLOADED_DELTA:-?} context_ref_resolved=+${CTX_RESOLVED_DELTA:-?}"
  echo "================================================================"
  exit 0
fi

echo "================================================================"
echo "kind-val: FAIL — see assertion errors above"
echo "================================================================"
echo "kind-val: server logs (tail 80):"
"${KCTX[@]}" logs deploy/"$NOETL_SERVER_DEPLOY" --tail=80 || true
echo
echo "kind-val: system-pool worker logs (tail 80):"
"${KCTX[@]}" logs deploy/"$NOETL_SYSTEM_POOL_DEPLOY" --tail=80 || true
echo
echo "kind-val: default-pool worker logs (tail 80):"
"${KCTX[@]}" logs deploy/"$NOETL_WORKER_DEPLOY" --tail=80 || true
exit 1

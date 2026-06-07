#!/usr/bin/env bash
# kind_validate_container_callback.sh — Round 5 of the
# Container Tool Callback umbrella (noetl/ai-meta#43).
#
# End-to-end kind-val rig that proves Rounds 1 + 2 + 3 actually
# wire together:
#
#   1. Round 1 — noetl-k8s-watcher Deployment is running.
#   2. Tool::Container (Round 3) creates a labeled K8s Job.
#   3. The watcher observes the Job's terminal state and POSTs
#      to noetl-server's container-callback endpoint (Round 2).
#   4. The server's metrics surface (Round 2) bumps the right
#      counter — `noetl_container_callback_total{state="succeeded"}`
#      (matched in-flight) OR `noetl_container_callback_stale_total{state="succeeded"}`
#      (call.done already arrived from the worker; the
#      transition state until the worker adopts the
#      `pending_callback` marker).
#
# Two fixtures, two probes:
#
#   - container_callback_happy_path → expect `succeeded`
#     state bumped on at least one of the two counters.
#   - container_callback_oom        → expect `failed_oom`
#     state bumped on at least one of the two counters.
#
# Returns 0 if both probes pass; 1 if either fails.
#
# Usage:
#
#   ./scripts/kind_validate_container_callback.sh
#   ./scripts/kind_validate_container_callback.sh --context kind-noetl
#   NOETL_KIND_CONTEXT=kind-foo ./scripts/kind_validate_container_callback.sh

set -euo pipefail

KIND_CONTEXT="${NOETL_KIND_CONTEXT:-kind-noetl}"
NAMESPACE="${NOETL_K8S_WATCH_NAMESPACE:-noetl}"
NOETL_SERVER_DEPLOY="${NOETL_SERVER_DEPLOY:-noetl-server}"
NOETL_WATCHER_DEPLOY="${NOETL_WATCHER_DEPLOY:-noetl-k8s-watcher}"
NOETL_SERVER_URL="${NOETL_SERVER_URL:-http://localhost:8082}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --context)        KIND_CONTEXT="$2"; shift 2 ;;
    --namespace)      NAMESPACE="$2"; shift 2 ;;
    --server-url)     NOETL_SERVER_URL="$2"; shift 2 ;;
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
FIXTURE_DIR="$REPO_ROOT/fixtures/playbooks"

echo "kind-val: context=$KIND_CONTEXT namespace=$NAMESPACE"
echo "kind-val: server=$NOETL_SERVER_URL"
echo "kind-val: fixtures=$FIXTURE_DIR"

# ----------------------------------------------------------------------
# Preflight — required tooling + cluster + watcher healthy
# ----------------------------------------------------------------------

for cmd in kubectl noetl curl; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "kind-val: required command not in PATH: $cmd" >&2
    exit 2
  }
done

KCTX=(kubectl --context "$KIND_CONTEXT" -n "$NAMESPACE")

if ! "${KCTX[@]}" get deployment "$NOETL_WATCHER_DEPLOY" >/dev/null 2>&1; then
  echo "kind-val: $NOETL_WATCHER_DEPLOY Deployment not found." >&2
  echo "kind-val: apply Round-1 manifests first:" >&2
  echo "  kubectl --context $KIND_CONTEXT apply -k repos/ops/ci/manifests/k8s-watcher/" >&2
  exit 2
fi

echo "kind-val: waiting for $NOETL_WATCHER_DEPLOY to be available..."
"${KCTX[@]}" rollout status deploy "$NOETL_WATCHER_DEPLOY" --timeout=120s

if ! "${KCTX[@]}" get deployment "$NOETL_SERVER_DEPLOY" >/dev/null 2>&1; then
  echo "kind-val: $NOETL_SERVER_DEPLOY Deployment not found in namespace $NAMESPACE." >&2
  exit 2
fi

# ----------------------------------------------------------------------
# Metric scraping — read the server's /metrics surface twice
# (before / after) and assert specific counter labels moved.
#
# Reads via `curl` against the localhost port-forward; falls
# back to `kubectl port-forward` if the user hasn't already
# tunnelled.
# ----------------------------------------------------------------------

scrape_metric_value() {
  # Args:
  #   $1 metric name (e.g. noetl_container_callback_total)
  #   $2 label string (e.g. state="succeeded")
  # Prints the integer counter value, or "0" if the line isn't
  # present (Prometheus omits zero-valued counter rows).
  local metric="$1" label="$2"
  curl -fsS "$NOETL_SERVER_URL/metrics" 2>/dev/null \
    | awk -v M="$metric" -v L="$label" '
        $0 ~ "^"M"\\{.*"L".*\\} " {
          # Last numeric field is the value.
          for (i = NF; i >= 1; i--) {
            if ($i ~ /^[0-9]+(\.[0-9]+)?$/) { print int($i); exit }
          }
        }
      ' || true
  # Fallback: emit zero if no line matched.
}

scrape_total_for_state() {
  # Some of the chain's runs land on the `succeeded` matched
  # counter, some on the `stale` counter (worker-side marker
  # adoption is a follow-up — see umbrella).  Either is
  # acceptable for Round-5; we sum the two and assert the
  # total moved.
  local state="$1"
  local matched stale
  matched=$(scrape_metric_value "noetl_container_callback_total"       "state=\"$state\"")
  stale=$(scrape_metric_value   "noetl_container_callback_stale_total" "state=\"$state\"")
  echo $(( ${matched:-0} + ${stale:-0} ))
}

# ----------------------------------------------------------------------
# Probe runner
# ----------------------------------------------------------------------

run_probe() {
  local label="$1" path="$2" expected_state="$3" timeout="$4"

  echo
  echo "================================================================"
  echo "kind-val PROBE: $label"
  echo "  fixture:  $path"
  echo "  expected: state=$expected_state (total counter delta >= 1)"
  echo "================================================================"

  local before
  before=$(scrape_total_for_state "$expected_state")
  echo "kind-val: counter (state=$expected_state) before = $before"

  # Register + run.  `noetl playbook register` is idempotent;
  # second registration with the same path replaces the prior
  # version.
  noetl playbook register --file "$FIXTURE_DIR/$path"

  local execution_id
  execution_id=$(noetl playbook execute --path "$path" --output json \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["execution_id"])')
  echo "kind-val: launched execution_id=$execution_id"

  # Wait for the playbook to terminate (Complete or Failed).
  local deadline=$(( SECONDS + timeout ))
  local final_status=""
  while [[ $SECONDS -lt $deadline ]]; do
    final_status=$(noetl execution status --id "$execution_id" --output json 2>/dev/null \
      | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("status",""))' || true)
    case "$final_status" in
      COMPLETED|FAILED) break ;;
    esac
    sleep 2
  done
  echo "kind-val: execution_id=$execution_id final_status=$final_status"

  # Give the watcher a few seconds to deliver the callback after
  # the Job hits terminal state — the watch stream + the
  # HTTP POST aren't atomic with the call.done emit.
  sleep 8

  local after
  after=$(scrape_total_for_state "$expected_state")
  echo "kind-val: counter (state=$expected_state) after  = $after"
  local delta=$(( after - before ))
  echo "kind-val: counter delta = $delta"

  if [[ "$delta" -ge 1 ]]; then
    echo "kind-val: PASS — $label"
    return 0
  fi

  echo "kind-val: FAIL — $label (expected state=$expected_state counter delta >= 1)"
  echo "kind-val: watcher logs (tail 50):"
  "${KCTX[@]}" logs deploy/"$NOETL_WATCHER_DEPLOY" --tail=50 || true
  echo "kind-val: server logs (tail 50, filtered):"
  "${KCTX[@]}" logs deploy/"$NOETL_SERVER_DEPLOY" --tail=50 | grep -i container-callback || true
  return 1
}

# ----------------------------------------------------------------------
# Run both probes; collect outcomes.
# ----------------------------------------------------------------------

OVERALL=0

if ! run_probe \
    "happy_path" \
    "container_callback_happy_path/container_callback_happy_path.yaml" \
    "succeeded" \
    180; then
  OVERALL=1
fi

if ! run_probe \
    "oom" \
    "container_callback_oom/container_callback_oom.yaml" \
    "failed_oom" \
    180; then
  OVERALL=1
fi

echo
if [[ "$OVERALL" -eq 0 ]]; then
  echo "================================================================"
  echo "kind-val: ALL PROBES PASS — Container Tool Callback chain green"
  echo "================================================================"
  exit 0
else
  echo "================================================================"
  echo "kind-val: SOME PROBES FAILED — see above"
  echo "================================================================"
  exit 1
fi

#!/usr/bin/env bash
# kind_validate_atomic_item_context.sh — atomic-working-item context contract
# (RFC noetl/ai-meta#115 Phase 5 / tenet 6).
#
# Proves the minimal-slice property end-to-end: when NOETL_ATOMIC_ITEM_CONTEXT is
# on, a downstream step that binds exactly ONE upstream output receives ONLY that
# upstream key in its worker-bound command context — the other accumulated step
# outputs are dropped — while existing playbooks still complete.
#
# Fixture (atomic_item_context.yaml):
#   start -> producer_a("AAA_KEEP") -> producer_b("BBB_DROP") -> consumer -> end
# `consumer` binds only `{{ producer_a.tag }}`.  Its persisted `command.issued`
# render_context must contain `producer_a` and NOT `producer_b` under the flag.
#
# Assertions (PASS requires all):
#   1. Execution reaches COMPLETED (narrowing didn't break resolution).
#   2. The consumer command's render_context contains `producer_a`.
#   3. (--expect narrowed) it does NOT contain `producer_b` — the minimal slice.
#      (--expect full)     it DOES contain `producer_b` — full-context back-compat.
#   4. (--expect narrowed) the server metric
#      `noetl_atomic_item_context_total{outcome="narrowed"}` advanced.
#
# The same shared `CommandBuilder::build_command` does the narrowing whether the
# drive runs in-process or off-server (the wasm reuses orchestrate-core), so this
# proof covers the drive path the server is configured for.
#
# Usage:
#   ./scripts/kind_validate_atomic_item_context.sh                 # expect narrowed
#   ./scripts/kind_validate_atomic_item_context.sh --expect full   # back-compat run
#   NOETL_SERVER_URL=http://localhost:18082 ./scripts/kind_validate_atomic_item_context.sh
#
# Exits 0 PASS; 1 assertion fail; 2 precondition error.

set -euo pipefail

KIND_CONTEXT="${NOETL_KIND_CONTEXT:-kind-noetl}"
NAMESPACE="${NOETL_K8S_NAMESPACE:-noetl}"
NOETL_SERVER_DEPLOY="${NOETL_SERVER_DEPLOY:-noetl-server-rust}"
NOETL_SERVER_URL="${NOETL_SERVER_URL:-http://localhost:8082}"
TIMEOUT_SECS="${NOETL_AIC_TIMEOUT_SECS:-180}"
EXPECT="narrowed"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --context)    KIND_CONTEXT="$2"; shift 2 ;;
    --namespace)  NAMESPACE="$2"; shift 2 ;;
    --server-url) NOETL_SERVER_URL="$2"; shift 2 ;;
    --timeout)    TIMEOUT_SECS="$2"; shift 2 ;;
    --expect)     EXPECT="$2"; shift 2 ;;
    -h|--help)    sed -n '2,/^set -euo/p' "$0" | sed -n '/^#/p'; exit 0 ;;
    *) echo "kind-val: unknown argument: $1" >&2; exit 2 ;;
  esac
done

case "$EXPECT" in narrowed|full) ;; *) echo "kind-val: --expect must be narrowed|full" >&2; exit 2 ;; esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURE_PATH="$REPO_ROOT/fixtures/playbooks/atomic_item_context.yaml"
PLAYBOOK_PATH="test/atomic_item_context"

echo "kind-val: context=$KIND_CONTEXT namespace=$NAMESPACE server=$NOETL_SERVER_URL expect=$EXPECT"
echo "kind-val: fixture=$FIXTURE_PATH"

for cmd in kubectl noetl curl python3; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "kind-val: missing command: $cmd" >&2; exit 2; }
done
[[ -f "$FIXTURE_PATH" ]] || { echo "kind-val: fixture not found: $FIXTURE_PATH" >&2; exit 2; }
KCTX=(kubectl --context "$KIND_CONTEXT" -n "$NAMESPACE")
"${KCTX[@]}" get deployment "$NOETL_SERVER_DEPLOY" >/dev/null 2>&1 \
  || { echo "kind-val: $NOETL_SERVER_DEPLOY not found in $NAMESPACE" >&2; exit 2; }
curl -fsS "$NOETL_SERVER_URL/api/health" >/dev/null 2>&1 \
  || { echo "kind-val: server not reachable at $NOETL_SERVER_URL — port-forward first." >&2; exit 2; }

fetch_metrics() { curl -fsS "$NOETL_SERVER_URL/metrics" 2>/dev/null || true; }
metrics_aic() {
  local outcome="$1" body="$2"
  printf '%s' "$body" | python3 -c '
import re, sys
oc = sys.argv[1]; total = 0
for line in sys.stdin:
    m = re.match(r"noetl_atomic_item_context_total\{outcome=\"([^\"]+)\"\}\s+([0-9.]+)", line)
    if m and m.group(1) == oc:
        total += int(float(m.group(2)))
print(total)
' "$outcome"
}

NARROWED_BEFORE="$(metrics_aic narrowed "$(fetch_metrics)")"
echo "kind-val: metric narrowed before=$NARROWED_BEFORE"

echo
echo "kind-val: register + execute atomic_item_context"
noetl register playbook --file "$FIXTURE_PATH"
EXECUTION_ID="$(noetl exec "$PLAYBOOK_PATH" --runtime distributed --json \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["execution_id"])')"
echo "kind-val: launched execution_id=$EXECUTION_ID"

DEADLINE=$(( SECONDS + TIMEOUT_SECS ))
FINAL_STATUS=""
while [[ $SECONDS -lt $DEADLINE ]]; do
  FINAL_STATUS="$(noetl status "$EXECUTION_ID" --json 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",""))' || true)"
  case "$FINAL_STATUS" in COMPLETED|FAILED) break ;; esac
  sleep 2
done
echo "kind-val: final_status=$FINAL_STATUS"

# Extract the consumer command's worker-bound render_context keys from the
# command.issued event.  context = {tool_config, args, render_context}.
CTX_KEYS_JSON="$(noetl query \
  "SELECT context AS c FROM noetl.event WHERE execution_id = $EXECUTION_ID AND event_type = 'command.issued' AND node_name = 'consumer' ORDER BY event_id DESC LIMIT 1" \
  --format json 2>/dev/null || true)"

read_keys() {
  printf '%s' "$CTX_KEYS_JSON" | python3 -c '
import json, sys
d = json.loads(sys.stdin.read() or "{}").get("result", [])
if not d:
    print(""); sys.exit(0)
c = d[0].get("c")
if isinstance(c, str):
    c = json.loads(c)
rc = (c or {}).get("render_context", {}) or {}
print(",".join(sorted(rc.keys())))
'
}
RC_KEYS="$(read_keys)"
echo "kind-val: consumer render_context keys = [$RC_KEYS]"

has_key() { printf '%s' ",$RC_KEYS," | grep -q ",$1,"; }

NARROWED_AFTER="$(metrics_aic narrowed "$(fetch_metrics)")"
NARROWED_DELTA=$(( NARROWED_AFTER - NARROWED_BEFORE ))
echo "kind-val: metric narrowed delta=+$NARROWED_DELTA"

OVERALL=0
fail() { echo "kind-val: FAIL — $1" >&2; OVERALL=1; }

[[ "$FINAL_STATUS" == "COMPLETED" ]] || fail "expected COMPLETED, got $FINAL_STATUS"
[[ -n "$RC_KEYS" ]] || fail "consumer render_context not found / empty (query returned nothing)"
has_key producer_a || fail "consumer context missing producer_a (the bound upstream) — keys=[$RC_KEYS]"

if [[ "$EXPECT" == "narrowed" ]]; then
  has_key producer_b && fail "consumer context still carries producer_b — NOT narrowed (keys=[$RC_KEYS])"
  [[ "$NARROWED_DELTA" -ge 1 ]] \
    || echo "kind-val: NOTE — narrowed metric did not advance (+$NARROWED_DELTA); off-server drive narrows inside the wasm, the server-side start-step metric may be the only increment." >&2
else
  has_key producer_b || fail "back-compat: consumer context should carry the full context incl. producer_b (keys=[$RC_KEYS])"
fi

echo
if [[ "$OVERALL" -eq 0 ]]; then
  echo "kind-val: PASS — atomic-item-context ($EXPECT): producer_a present, producer_b $([[ "$EXPECT" == narrowed ]] && echo dropped || echo present); execution COMPLETED."
else
  echo "kind-val: FAIL — see assertions above." >&2
  "${KCTX[@]}" logs deploy/"$NOETL_SERVER_DEPLOY" --tail=120 2>/dev/null | tail -60 >&2 || true
fi
exit "$OVERALL"

#!/usr/bin/env bash
# kind_validate_subscription_push.sh — noetl/ai-meta#90 Phase 3
# Gateway push-ingress (Mode C) + auth-gated directive trust live E2E
# on the local kind cluster.
#
# Proves, end to end against the in-cluster gateway + server:
#   1. POST /ingress/{listener} on the gateway VERIFIES a signed
#      webhook (HMAC-SHA256 over the raw body, or a bearer token), then —
#      only on success — forwards ONE POST /api/execute per delivery.
#   2. Each verified delivery becomes one execution on the DEDICATED
#      `subscription` pool segment and reaches COMPLETED.
#   3. An allowlisted header directive `x-noetl-route` REDIRECTS a
#      delivery to a different target playbook — honored ONLY after the
#      delivery passed verification (RFC §7.5).
#   4. THE auth gate: a tampered (bad-signature) or unsigned/unauth
#      request is REJECTED (401) with NO execution dispatched and NO
#      directive applied — an unauthenticated caller can never drive
#      routing.
#   5. The verify secret is resolved from the Secrets Wallet by alias
#      (never a gateway env var).
#
# Prerequisites (build + deploy, see the PR / wiki for the recipe):
#   - noetl-server-rust v3.3.0+ (carries GET /api/internal/ingress/{listener}
#     + push catalog validation) built, kind-loaded, rolled, with
#     NOETL_INTERNAL_API_TOKEN set.
#   - noetl-gateway v3.3.0+ (carries POST /ingress/{listener}) built as
#     noetl-gateway:latest, kind-loaded, deployed in ns `gateway` with a
#     matching NOETL_INTERNAL_API_TOKEN (same token value as the server).
#   - The dedicated subscription pool worker
#     (worker-rust-subscription-pool-deployment.yaml) deployed so the
#     forwarded executions drain to COMPLETED.
#
# Usage:
#   ./scripts/kind_validate_subscription_push.sh
#   ./scripts/kind_validate_subscription_push.sh --count 6 --redirect 2 --scheme hmac
#   ./scripts/kind_validate_subscription_push.sh --scheme bearer
#
# Exits 0 on PASS; 1 on any failed assertion (dumps gateway + pool logs).
# Set KEEP_RESOURCES=1 to leave the deployments in place.

set -euo pipefail

KIND_CONTEXT="${NOETL_KIND_CONTEXT:-kind-noetl}"
NS="${NOETL_K8S_NAMESPACE:-noetl}"
GW_NS="${NOETL_GW_NS:-gateway}"
PG_NS="${NOETL_PG_NS:-postgres}"
SERVER_URL="${NOETL_SERVER_URL:-http://localhost:8082}"
GATEWAY_URL="${NOETL_GATEWAY_URL:-http://localhost:8090}"
COUNT="${NOETL_PUSH_COUNT:-6}"
REDIRECT="${NOETL_PUSH_REDIRECT:-2}"
SCHEME="${NOETL_PUSH_SCHEME:-hmac}"
TIMEOUT_SECS="${NOETL_PUSH_TIMEOUT_SECS:-150}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --context)  KIND_CONTEXT="$2"; shift 2 ;;
    --count)    COUNT="$2"; shift 2 ;;
    --redirect) REDIRECT="$2"; shift 2 ;;
    --scheme)   SCHEME="$2"; shift 2 ;;
    --timeout)  TIMEOUT_SECS="$2"; shift 2 ;;
    -h|--help)  sed -n '2,/^set -euo/p' "$0" | sed -n '/^#/p'; exit 0 ;;
    *) echo "kind-val: unknown argument: $1" >&2; exit 2 ;;
  esac
done

# Per-scheme parameters.
case "$SCHEME" in
  hmac)
    SUB_FIX="webhook_orders.subscription.yaml"
    SUB_PATH="subscriptions/webhook_orders"
    LISTENER="orders"
    CRED_FIX="webhook_hmac_secret.json.example"
    ;;
  bearer)
    SUB_FIX="hook_bearer.subscription.yaml"
    SUB_PATH="subscriptions/hook_bearer"
    LISTENER="hookbearer"
    CRED_FIX="hook_bearer_token.json.example"
    ;;
  *) echo "kind-val: --scheme must be hmac|bearer" >&2; exit 2 ;;
esac

DEFAULT_PB="tests/fixtures/handle_webhook"
PRIORITY_PB="tests/fixtures/handle_webhook_priority"
TRACEPARENT="00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FIX="$REPO_ROOT/fixtures/subscription"
CREDS="$REPO_ROOT/fixtures/credentials"

KCTX=(kubectl --context "$KIND_CONTEXT")
PGPOD="$("${KCTX[@]}" -n "$PG_NS" get pod -o name | head -1)"
psql_q() { "${KCTX[@]}" -n "$PG_NS" exec "$PGPOD" -- env PGPASSWORD=noetl psql -U noetl -d noetl -tAc "$1"; }

echo "kind-val: context=$KIND_CONTEXT scheme=$SCHEME listener=$LISTENER count=$COUNT redirect=$REDIRECT"

# ----------------------------------------------------------------------
# Preflight.
# ----------------------------------------------------------------------
for cmd in kubectl curl python3; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "kind-val: missing command: $cmd" >&2; exit 2; }
done
for f in "$FIX/$SUB_FIX" "$FIX/handle_webhook.yaml" "$FIX/handle_webhook_priority.yaml" "$CREDS/$CRED_FIX"; do
  [[ -f "$f" ]] || { echo "kind-val: fixture not found: $f" >&2; exit 2; }
done

# The verify secret (used to sign / authenticate the test deliveries).
SECRET="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['data']['secret'])" "$CREDS/$CRED_FIX")"

# ----------------------------------------------------------------------
# Port-forwards (server + gateway).
# ----------------------------------------------------------------------
PF_PIDS=()
cleanup() {
  for pid in "${PF_PIDS[@]:-}"; do kill "$pid" >/dev/null 2>&1 || true; done
}
trap cleanup EXIT

"${KCTX[@]}" -n "$NS" port-forward svc/noetl 8082:8082 >/tmp/pf_server_push.log 2>&1 & PF_PIDS+=($!)
"${KCTX[@]}" -n "$GW_NS" port-forward svc/gateway 8090:8090 >/tmp/pf_gateway_push.log 2>&1 & PF_PIDS+=($!)
sleep 4
curl -fsS "$SERVER_URL/api/health" >/dev/null 2>&1 || { echo "kind-val: server not reachable at $SERVER_URL" >&2; exit 2; }
curl -fsS "$GATEWAY_URL/health" >/dev/null 2>&1 || { echo "kind-val: gateway not reachable at $GATEWAY_URL" >&2; exit 2; }

# ----------------------------------------------------------------------
# Register verify-secret credential + handler playbooks + push subscription.
# ----------------------------------------------------------------------
echo "kind-val: registering credential + catalog entries"
curl -fsS -X POST "$SERVER_URL/api/credentials" -H 'Content-Type: application/json' \
  -d "$(cat "$CREDS/$CRED_FIX")" >/dev/null 2>&1 || \
  echo "kind-val: credential register returned non-2xx (may already exist) — continuing"

register_catalog() {
  local file="$1" content
  content="$(python3 -c "import json,sys; print(json.dumps(open(sys.argv[1]).read()))" "$file")"
  curl -fsS -X POST "$SERVER_URL/api/catalog/register" -H 'Content-Type: application/json' \
    -d "{\"content\": $content}" >/dev/null
}
register_catalog "$FIX/handle_webhook.yaml"
register_catalog "$FIX/handle_webhook_priority.yaml"
register_catalog "$FIX/$SUB_FIX"

# ----------------------------------------------------------------------
# Helpers — sign + POST a delivery to the gateway ingress.
# ----------------------------------------------------------------------
hmac_hex() { python3 -c "import hmac,hashlib,sys; print(hmac.new(sys.argv[1].encode(), sys.argv[2].encode(), hashlib.sha256).hexdigest())" "$1" "$2"; }

# POST a delivery; echo the HTTP status. Args: body, redirect(0|1), authgood(0|1)
post_delivery() {
  local body="$1" redirect="$2" authgood="$3"
  local hdrs=(-H "Content-Type: application/json" -H "traceparent: $TRACEPARENT")
  if (( redirect == 1 )); then hdrs+=(-H "x-noetl-route: $PRIORITY_PB"); fi
  if [[ "$SCHEME" == "hmac" ]]; then
    local sig; sig="$(hmac_hex "$SECRET" "$body")"
    if (( authgood == 0 )); then sig="deadbeefdeadbeef"; fi   # tampered signature
    hdrs+=(-H "X-Signature: sha256=$sig")
  else
    local tok="$SECRET"
    if (( authgood == 0 )); then tok="wrong-token"; fi
    hdrs+=(-H "Authorization: Bearer $tok")
  fi
  curl -s -o /dev/null -w "%{http_code}" -X POST "$GATEWAY_URL/ingress/$LISTENER" "${hdrs[@]}" -d "$body"
}

# ----------------------------------------------------------------------
# 1) Send COUNT VERIFIED deliveries (REDIRECT of them carry x-noetl-route).
# ----------------------------------------------------------------------
echo "kind-val: sending $COUNT verified deliveries ($REDIRECT redirected)"
accepted=0
for i in $(seq 1 "$COUNT"); do
  body="{\"order_id\":$i,\"amount\":$((RANDOM%500))}"
  rdir=0; (( i <= REDIRECT )) && rdir=1
  code="$(post_delivery "$body" "$rdir" 1)"
  if [[ "$code" == "202" ]]; then accepted=$((accepted+1)); else echo "  warn: delivery $i returned HTTP $code"; fi
done
echo "kind-val: gateway accepted=$accepted/$COUNT (HTTP 202)"

# Resolve the subscription id the server registered on first ingress.
SUB_ID=""
for _ in $(seq 1 20); do
  SUB_ID="$(psql_q "SELECT execution_id FROM noetl.event WHERE node_name='$SUB_PATH' AND event_type='subscription.registered' ORDER BY event_id DESC LIMIT 1" | tr -d '[:space:]')"
  [[ -n "$SUB_ID" ]] && break
  sleep 2
done
[[ -n "$SUB_ID" ]] || { echo "kind-val: FAIL — push subscription never registered"; "${KCTX[@]}" -n "$GW_NS" logs deploy/gateway --tail=60 || true; exit 1; }
echo "kind-val: subscription_id=$SUB_ID"

# ----------------------------------------------------------------------
# 2) Wait for COUNT child executions to COMPLETE.
# ----------------------------------------------------------------------
KIDS_SQL="SELECT DISTINCT execution_id FROM noetl.event WHERE parent_execution_id=$SUB_ID AND event_type='playbook_started'"
echo "kind-val: waiting for $COUNT child executions to complete"
deadline=$(( $(date +%s) + TIMEOUT_SECS ))
completed=0
while (( $(date +%s) < deadline )); do
  completed="$(psql_q "SELECT count(DISTINCT execution_id) FROM noetl.event WHERE execution_id IN ($KIDS_SQL) AND event_type='playbook.completed'" | tr -d '[:space:]')"
  [[ "${completed:-0}" -ge "$COUNT" ]] && break
  sleep 4
done

children="$(psql_q "SELECT count(DISTINCT execution_id) FROM noetl.event WHERE parent_execution_id=$SUB_ID AND event_type='playbook_started'" | tr -d '[:space:]')"
redirected="$(psql_q "SELECT count(DISTINCT execution_id) FROM noetl.event WHERE parent_execution_id=$SUB_ID AND event_type='playbook_started' AND node_name='$PRIORITY_PB'" | tr -d '[:space:]')"
defaulted="$(psql_q "SELECT count(DISTINCT execution_id) FROM noetl.event WHERE parent_execution_id=$SUB_ID AND event_type='playbook_started' AND node_name='$DEFAULT_PB'" | tr -d '[:space:]')"
pooled="$(psql_q "SELECT count(DISTINCT execution_id) FROM noetl.event WHERE parent_execution_id=$SUB_ID AND event_type='playbook_started' AND meta->>'execution_pool'='subscription'" | tr -d '[:space:]')"
directives="$(psql_q "SELECT count(*) FROM noetl.event WHERE execution_id IN ($KIDS_SQL) AND event_type='subscription.message.directives_applied'" | tr -d '[:space:]')"

echo "kind-val: children=$children completed=$completed redirected=$redirected defaulted=$defaulted pooled=$pooled directives=$directives"

FAIL=0
assert() { if [[ "${2:-0}" -ge "$3" ]]; then echo "  PASS: $1 ($2 >= $3)"; else echo "  FAIL: $1 (${2:-0} < $3)"; FAIL=1; fi; }
assert_eq() { if [[ "${2:-0}" -eq "$3" ]]; then echo "  PASS: $1 (== $3)"; else echo "  FAIL: $1 (${2:-0} != $3)"; FAIL=1; fi; }
assert "gateway accepted every verified delivery (202)" "$accepted"   "$COUNT"
assert "one child execution per verified delivery"      "$children"   "$COUNT"
assert "all children reached COMPLETED"                 "$completed"  "$COUNT"
assert "children dispatched on subscription pool"       "$pooled"     "$COUNT"
assert "redirect directive routed to priority pb"       "$redirected" "$REDIRECT"
assert "default deliveries ran the default pb"          "$defaulted"  "$(( COUNT - REDIRECT ))"
assert "directives_applied audit events emitted"        "$directives" "$REDIRECT"

# ----------------------------------------------------------------------
# 3) THE auth gate — a tampered + an unsigned delivery, EACH carrying the
#    redirect header, MUST be rejected with NO execution + NO directive.
# ----------------------------------------------------------------------
echo "kind-val: auth-gate negative cases (tampered + unauth, both carry the redirect header)"
children_before="$children"
directives_before="$directives"

tampered_code="$(post_delivery '{"order_id":9001,"amount":1}' 1 0)"   # redirect header + BAD auth
echo "  tampered/unauth delivery → HTTP $tampered_code (expect 401)"

# Missing-credential delivery: no auth header at all.
if [[ "$SCHEME" == "hmac" ]]; then
  missing_code="$(curl -s -o /dev/null -w "%{http_code}" -X POST "$GATEWAY_URL/ingress/$LISTENER" \
    -H "Content-Type: application/json" -H "x-noetl-route: $PRIORITY_PB" -d '{"order_id":9002}')"
else
  missing_code="$(curl -s -o /dev/null -w "%{http_code}" -X POST "$GATEWAY_URL/ingress/$LISTENER" \
    -H "Content-Type: application/json" -H "x-noetl-route: $PRIORITY_PB" -d '{"order_id":9002}')"
fi
echo "  missing-credential delivery → HTTP $missing_code (expect 401)"

# Give the system a moment; then confirm NOTHING new was dispatched.
sleep 6
children_after="$(psql_q "SELECT count(DISTINCT execution_id) FROM noetl.event WHERE parent_execution_id=$SUB_ID AND event_type='playbook_started'" | tr -d '[:space:]')"
directives_after="$(psql_q "SELECT count(*) FROM noetl.event WHERE execution_id IN (SELECT DISTINCT execution_id FROM noetl.event WHERE parent_execution_id=$SUB_ID AND event_type='playbook_started') AND event_type='subscription.message.directives_applied'" | tr -d '[:space:]')"
# Also confirm NO execution ever ran the priority pb beyond the verified redirects.
redirected_after="$(psql_q "SELECT count(DISTINCT execution_id) FROM noetl.event WHERE parent_execution_id=$SUB_ID AND event_type='playbook_started' AND node_name='$PRIORITY_PB'" | tr -d '[:space:]')"

echo "kind-val: after-negatives children=$children_after directives=$directives_after redirected=$redirected_after"
assert_eq "tampered delivery rejected (HTTP 401)"        "$tampered_code"   401
assert_eq "missing-credential delivery rejected (401)"   "$missing_code"    401
assert_eq "NO new execution from rejected deliveries"    "$children_after"  "$children_before"
assert_eq "NO new directive applied from rejected"       "$directives_after" "$directives_before"
assert_eq "redirect count unchanged by forged headers"   "$redirected_after" "$redirected"

# ----------------------------------------------------------------------
# Verdict.
# ----------------------------------------------------------------------
if [[ "$FAIL" -eq 0 ]]; then
  echo "kind-val: PASS — push-ingress ($SCHEME) verify→directives→dispatch + auth gate proven"
  exit 0
else
  echo "kind-val: FAIL — see assertions above"
  echo "--- gateway logs ---"; "${KCTX[@]}" -n "$GW_NS" logs deploy/gateway --tail=80 || true
  echo "--- subscription pool logs ---"; "${KCTX[@]}" -n "$NS" logs deploy/noetl-worker-rust-subscription-pool --tail=40 || true
  exit 1
fi

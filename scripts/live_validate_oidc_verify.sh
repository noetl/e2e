#!/usr/bin/env bash
# live_validate_oidc_verify.sh — noetl/ai-meta#91
# LIVE Google OIDC signature validation for the gateway push-ingress.
#
# Phase 3 (noetl/ai-meta#90) shipped the gateway's Pub/Sub-push OIDC verifier
# (RS256 vs Google JWKS, aud + push service-account email + email_verified +
# exp).  Every negative case was unit-proven, but the POSITIVE signature path
# was never validated against a *real* Google-signed token — the unit tests
# sign with a self-minted RSA key + an in-memory JWKS.  This script closes that
# gap: it mints a genuinely Google-signed OIDC identity token and runs the
# gateway's verifier against Google's LIVE JWKS endpoint.
#
# What is LIVE here:
#   - The token: a real RS256 JWT signed by Google, minted by impersonating the
#     least-privilege subscription runtime service account (#90 Phase 5) with a
#     custom audience + --include-email, so it carries exactly the claims a
#     Pub/Sub push subscription with OIDC auth sends (iss=accounts.google.com,
#     aud=<push URL>, email=<push SA>, email_verified=true).
#   - The keys: fetched from https://www.googleapis.com/oauth2/v3/certs through
#     the gateway's own `fetch_google_jwks`.
#   - The verifier: the gateway crate's `validate_oidc_jwt`, exercised via the
#     `#[ignore]`d `oidc_live_google_token_against_real_jwks` test.
#
# It proves, against the real keys:
#   1. valid real token (correct aud + SA)        → verified
#   2. wrong audience                              → oidc_wrong_audience
#   3. wrong service-account email                 → oidc_wrong_sa
#   4. tampered signature                          → oidc_bad_signature
#
# NO secret is printed or committed — the token lives only in this process's
# environment and is never echoed.
#
# Prerequisites:
#   - gcloud authenticated (`gcloud auth list`) with
#     roles/iam.serviceAccountTokenCreator on $SA (a scoped, removable binding).
#   - A Rust toolchain to build + run the gateway crate test.
#
# Usage:
#   ./scripts/live_validate_oidc_verify.sh
#   GATEWAY_DIR=/path/to/gateway ./scripts/live_validate_oidc_verify.sh
#
# Exits 0 on PASS (the test asserts every case), non-zero on any failure.
#
# ---------------------------------------------------------------------------
# Full HTTP gold-standard run (manual, beyond this script's scope)
# ---------------------------------------------------------------------------
# To additionally prove "valid token → /ingress/{listener} → one execution
# dispatched", run the gateway binary against the kind server and POST the
# minted token in a Pub/Sub-push body.  Validated 2026-06-12 on kind-noetl:
# 4 deliveries received, 1 dispatched (valid), 3 rejected (tampered=401,
# wrong-aud=403, missing=401), one COMPLETED child execution on the
# `subscription` pool.  Recipe:
#   1. Register a `pubsub_oidc` subscription whose verify.audience == $AUD and
#      verify.service_account == $SA (no secret — Google JWKS is public).
#   2. Port-forward the kind server (8082) + NATS (4222, creds noetl:noetl);
#      run the gateway with NOETL_BASE_URL, NOETL_INTERNAL_API_TOKEN (== the
#      server's), NATS_URL.
#   3. POST {"message":{"data":<base64>,"messageId":..,"attributes":{}}} with
#      `Authorization: Bearer <token>` → expect 202 + execution_id; flip a char
#      / drop the header → expect 401/403 + no execution.

set -euo pipefail

SA="${NOETL_OIDC_SA:-noetl-subscription-runtime@noetl-demo-19700101.iam.gserviceaccount.com}"
AUD="${NOETL_OIDC_AUD:-https://gw.noetl.example/ingress/billing}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GATEWAY_DIR="${GATEWAY_DIR:-$(cd "$REPO_ROOT/../gateway" 2>/dev/null && pwd || true)}"

echo "oidc-live: SA=$SA"
echo "oidc-live: AUD=$AUD"
echo "oidc-live: gateway crate=$GATEWAY_DIR"

for cmd in gcloud cargo; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "oidc-live: missing command: $cmd" >&2; exit 2; }
done
[[ -n "$GATEWAY_DIR" && -f "$GATEWAY_DIR/Cargo.toml" ]] || {
  echo "oidc-live: gateway crate not found — set GATEWAY_DIR=/path/to/gateway" >&2; exit 2; }

# ----------------------------------------------------------------------
# Mint a real Google-signed OIDC token (NEVER printed).
# ----------------------------------------------------------------------
echo "oidc-live: minting real Google-signed OIDC token (impersonating $SA)"
TOKEN="$(gcloud auth print-identity-token \
  --impersonate-service-account="$SA" \
  --audiences="$AUD" \
  --include-email 2>/dev/null || true)"

if [[ -z "$TOKEN" || "$TOKEN" != ey* ]]; then
  echo "oidc-live: FAILED to mint a token." >&2
  echo "  Ensure your account has roles/iam.serviceAccountTokenCreator on $SA:" >&2
  echo "    gcloud iam service-accounts add-iam-policy-binding $SA \\" >&2
  echo "      --member=\"user:\$(gcloud config get-value account)\" \\" >&2
  echo "      --role=\"roles/iam.serviceAccountTokenCreator\"" >&2
  exit 1
fi
echo "oidc-live: token minted (len ${#TOKEN}) — not printed"

# ----------------------------------------------------------------------
# Run the gateway's LIVE verifier test against Google's real JWKS.
# ----------------------------------------------------------------------
echo "oidc-live: running validate_oidc_jwt against LIVE Google JWKS"
(
  cd "$GATEWAY_DIR"
  NOETL_LIVE_OIDC_TOKEN="$TOKEN" \
  NOETL_LIVE_OIDC_AUD="$AUD" \
  NOETL_LIVE_OIDC_SA="$SA" \
  cargo test --bin noetl-gateway ingress::verify::tests::oidc_live \
    -- --ignored --nocapture
)

echo "oidc-live: PASS — real Google-signed token verified + every negative rejected against the live JWKS"

#!/usr/bin/env bash
# kind_validate_result_tier_gc_dr.sh — result-tier GC + DR under the off-server
# gate, with a GCS backend (noetl/ai-meta#104 Phase F).
#
# Phase F adds the garbage-collection + disaster-recovery story for the
# Feather/GCS result tier:
#
#   GC (server)  — a conservative, dry-run-first sweeper
#     (POST /api/internal/result-tier/gc, gated NOETL_RESULT_TIER_GC) that
#     reclaims ONLY provably-dead objects: an object whose execution has aged
#     out of the event log (no surviving noetl.event row) past a grace window.
#     It NEVER deletes a live-referenced object.
#   DR (worker)  — the result materializer's verify-and-repair mode
#     (NOETL_RESULT_TIER_DR): the tier is derivable from the WAL, so a missing /
#     corrupt tier object is rebuilt from its source by re-running the
#     materialization for its URN, BYTE-IDENTICALLY (deterministic encode).
#
# This rig proves, under the prod-exact off-server gate (PUBLISH_ONLY +
# off-server drive + event-materializer sole-writer), with a fake-gcs-server
# object backend:
#
#   GC-1 (dry-run)   — with the GC flag ON, a dry-run sweep LISTS the dead
#     (orphan) object as a candidate and the LIVE object as skipped_live, and
#     DELETES NOTHING (both objects still present afterwards).
#   GC-2 (delete)    — a delete sweep removes ONLY the dead object; the
#     live-referenced object SURVIVES and still serves via the server object
#     read path (the resolve-by-URN fetch path).
#   GC-3 (flag-off)  — with the GC flag OFF the endpoint is a no-op
#     (enabled=false, deleted=0); nothing is touched.
#   DR-1 (re-derive) — a referenced tier object deleted from GCS is rebuilt by
#     the DR materializer from its WAL-derivable source; the rebuilt object is
#     BYTE-IDENTICAL to the original (same sha256) and the server object read
#     path serves it again.
#   DR-2 (flag-off)  — with the DR flag OFF (materializer not spawned) the same
#     re-feed does NOT rebuild the object (it stays missing); DR metric Δ0.
#
# Cutover invariants (sole-writer, roots=1, dangling=0, terminal=1) are checked
# on every real execution; baseline is restored on exit.
#
# Backend: a fake-gcs-server emulator (kind only; never real GCS).
#
# Preconditions (the gate-ON stack), PLUS a SERVER image carrying the Phase F GC
# endpoint + object list/delete backend, and a WORKER image carrying the Phase F
# DR verify-and-repair materializer.
#   - server: NOETL_EVENT_INGEST_PUBLISH_ONLY=true AND NOETL_ORCHESTRATE_PLUGIN_DRIVE=true.
#   - system pool: NOETL_MATERIALIZER_ENABLED=true (event materializer sole writer).
#
# Usage:
#   ./scripts/kind_validate_result_tier_gc_dr.sh
#   ./scripts/kind_validate_result_tier_gc_dr.sh --no-restore
#
# Exits 0 if PASS; 1 if a hard assertion fails (dumps logs); 2 on precondition.

set -euo pipefail

KIND_CONTEXT="${NOETL_KIND_CONTEXT:-kind-noetl}"
NAMESPACE="${NOETL_K8S_NAMESPACE:-noetl}"
NOETL_SERVER_DEPLOY="${NOETL_SERVER_DEPLOY:-noetl-server-rust}"
NOETL_WORKER_POOL_DEPLOY="${NOETL_WORKER_POOL_DEPLOY:-noetl-worker-rust}"
NOETL_SYSTEM_POOL_DEPLOY="${NOETL_SYSTEM_POOL_DEPLOY:-noetl-worker-system-pool}"
NOETL_SERVER_URL="${NOETL_SERVER_URL:-http://localhost:8082}"
NATS_NAMESPACE="${NOETL_NATS_NAMESPACE:-nats}"
NATS_LOCAL="nats://noetl:noetl@localhost:4222"
TIMEOUT_SECS="${NOETL_ORCH_TIMEOUT_SECS:-240}"
RESTORE=1

GCS_ENDPOINT_IN="http://fake-gcs-server.${NAMESPACE}.svc.cluster.local:4443"
GCS_BUCKET="noetl-results"
CELL="local-0"; CELL_ENV="dev"; CELL_REGION="local"; SHARD_COUNT="256"

# A fabricated DEAD execution id: a tiny snowflake decodes to ~the 2024-01-01
# epoch (well in the past → past any grace), and no real execution ever mints an
# id this small (real ids are ~10^18). So its synthetic orphan object is
# unreferenced + aged-out → a GC candidate.
DEAD_EID="1000000"

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
FIX="$REPO_ROOT/fixtures/playbooks/test_resolve_by_urn.yaml:tests/resolve_by_urn_test"
MANIFEST="$REPO_ROOT/manifests/fake-gcs-server.yaml"

echo "kind-val: context=$KIND_CONTEXT namespace=$NAMESPACE"
echo "kind-val: #104 Phase F — result-tier GC (safe sweeper) + DR (byte-identical re-derive)"

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

# Internal API token for the GC endpoint (service-account gated). Read from the
# k8s Secret; NEVER echoed.
TOKEN="$("${KCTX[@]}" get secret noetl-internal-api-token -o jsonpath='{.data.token}' 2>/dev/null | base64 -d 2>/dev/null || true)"
[[ -n "$TOKEN" ]] || { echo "kind-val: noetl-internal-api-token secret unavailable — cannot call GC endpoint." >&2; exit 2; }

ORIG_RM="$(get_env "$NOETL_SYSTEM_POOL_DEPLOY" NOETL_RESULT_MATERIALIZER_ENABLED)"
PF_PID=""; NATS_PF_PID=""

cleanup() {
  [[ -n "$PF_PID" ]] && kill "$PF_PID" >/dev/null 2>&1 || true
  [[ -n "$NATS_PF_PID" ]] && kill "$NATS_PF_PID" >/dev/null 2>&1 || true
  if [[ "$RESTORE" -eq 1 ]]; then
    echo "kind-val: restoring baseline"
    "${KCTX[@]}" set env deploy/"$NOETL_SERVER_DEPLOY" \
      "NOETL_OBJECT_STORE_BACKEND-" "NOETL_OBJECT_STORE_GCS_ENDPOINT-" "NOETL_OBJECT_STORE_GCS_BUCKET-" \
      "NOETL_RESULT_TIER_GC-" \
      "NOETL_RESULT_CELL-" "NOETL_RESULT_CELL_ENV-" "NOETL_RESULT_CELL_REGION-" "NOETL_RESULT_SHARD_COUNT-" >/dev/null 2>&1 || true
    "${KCTX[@]}" set env deploy/"$NOETL_WORKER_POOL_DEPLOY" \
      "NOETL_RESULT_CELL-" "NOETL_RESULT_CELL_ENV-" "NOETL_RESULT_CELL_REGION-" "NOETL_RESULT_SHARD_COUNT-" \
      "NOETL_OBJECT_STORE_BACKEND-" >/dev/null 2>&1 || true
    "${KCTX[@]}" set env deploy/"$NOETL_SYSTEM_POOL_DEPLOY" \
      "NOETL_RESULT_MATERIALIZER_ENABLED=${ORIG_RM:-false}" \
      "NOETL_RESULT_TIER_DR-" \
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

# Sum a worker/system-pool metric series across all pods of a deployment.
pool_metric() {  # deploy grep_pattern
  local deploy="$1" pat="$2" sel pod total=0 v
  sel="$("${KCTX[@]}" get deploy "$deploy" -o jsonpath='{.spec.selector.matchLabels}' 2>/dev/null \
        | python3 -c 'import json,sys; d=json.load(sys.stdin); print(",".join(f"{k}={v}" for k,v in d.items()))')" || true
  for pod in $("${KCTX[@]}" get pods -l "$sel" -o name 2>/dev/null); do
    v="$("${KCTX[@]}" exec "$pod" -- wget -qO- http://127.0.0.1:9090/metrics 2>/dev/null \
         | { grep -E "$pat" || true; } | awk '{s+=$NF} END{printf "%d", s+0}')" || true
    total=$((total + ${v:-0}))
  done
  echo "$total"
}
system_metric() { pool_metric "$NOETL_SYSTEM_POOL_DEPLOY" "$1"; }

roll() { "${KCTX[@]}" rollout status deploy/"$1" --timeout=150s >/dev/null 2>&1 || true; }

urlenc() { python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"; }

# fake-gcs object ops over the host :4443 port-forward (the SAME emulator the
# server reads/writes).
gcs_list_prefix() {  # prefix -> object names (one per line)
  curl -fsS "http://localhost:4443/storage/v1/b/$GCS_BUCKET/o?prefix=$(urlenc "$1")" 2>/dev/null \
    | python3 -c 'import json,sys
for i in json.load(sys.stdin).get("items",[]): print(i["name"])' 2>/dev/null || true
}
gcs_first_key_for_eid() {  # eid -> first object key under execution=<eid>
  gcs_list_prefix "noetl/" | { grep "execution=$1" || true; } | head -1
}
gcs_get_sha() {  # key -> sha256 of the object bytes ('' if missing)
  local enc; enc="$(urlenc "$1")"
  curl -fsS "http://localhost:4443/storage/v1/b/$GCS_BUCKET/o/$enc?alt=media" 2>/dev/null \
    | shasum -a 256 2>/dev/null | awk '{print $1}'
}
gcs_exists() {  # key -> "yes"/"no"
  local enc; enc="$(urlenc "$1")"
  if curl -fsS -o /dev/null "http://localhost:4443/storage/v1/b/$GCS_BUCKET/o/$enc?alt=media" 2>/dev/null; then
    echo yes; else echo no; fi
}
gcs_delete() {  # key
  local enc; enc="$(urlenc "$1")"
  curl -fsS -X DELETE "http://localhost:4443/storage/v1/b/$GCS_BUCKET/o/$enc" >/dev/null 2>&1 || true
}
gcs_put_orphan() {  # key -> PUT a small json object directly (no execution, no events)
  curl -fsS -X POST "http://localhost:4443/upload/storage/v1/b/$GCS_BUCKET/o?uploadType=media&name=$(urlenc "$1")" \
    -H 'Content-Type: application/json' --data '{"orphan":true,"phase":"F"}' >/dev/null 2>&1 || true
}

# Server-mediated object read (the resolve-by-URN fetch path) — returns the
# object's sha256 via the SAME GET the read path uses ('' if 404).
server_object_sha() {  # key
  curl -fsS -H "Authorization: Bearer $TOKEN" "$NOETL_SERVER_URL/api/internal/objects/$1" 2>/dev/null \
    | shasum -a 256 2>/dev/null | awk '{print $1}'
}

# POST the GC sweep; echoes the raw JSON report.
gc_call() {  # dry_run grace
  curl -fsS -X POST "$NOETL_SERVER_URL/api/internal/result-tier/gc" \
    -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
    -d "{\"dry_run\":$1,\"grace_seconds\":$2,\"prefix\":\"noetl/\",\"limit\":2000}" 2>/dev/null || echo '{}'
}
gc_field() { python3 -c 'import json,sys; print(json.loads(sys.stdin.read() or "{}").get(sys.argv[1], ""))' "$1"; }
# Count candidates whose execution_id matches, optionally filtered by deleted flag.
gc_candidate_eid() {  # json eid [deleted_true|deleted_false]
  python3 -c '
import json,sys
rep=json.loads(sys.argv[1] or "{}"); eid=int(sys.argv[2]); flt=sys.argv[3] if len(sys.argv)>3 else ""
n=0
for c in rep.get("candidates",[]):
    if int(c.get("execution_id",-1))==eid:
        if flt=="deleted_true" and not c.get("deleted"): continue
        if flt=="deleted_false" and c.get("deleted"): continue
        n+=1
print(n)' "$1" "$2" "${3:-}"; }

launch_leg() {  # label -> sets LEG_EID
  noetl register playbook --file "${FIX%%:*}" >/dev/null
  LEG_EID="$(noetl exec "${FIX##*:}" --runtime distributed --json \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["execution_id"])')"
  echo "kind-val: $1 leg launched execution_id=$LEG_EID"
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
  sleep 3
  LEG_PASS="$(count_rows "SELECT COUNT(*) AS n FROM noetl.event
             WHERE execution_id = $LEG_EID AND result::text LIKE '%\"test_passed\": true%'")"
}

# Wait until a tier object for an execution appears (materializer wrote it).
await_tier() {  # eid
  local d=$(( SECONDS + 60 ))
  while [[ $SECONDS -lt $d ]]; do
    [[ -n "$(gcs_first_key_for_eid "$1")" ]] && return 0
    sleep 3
  done
  return 1
}

# Extract the over-budget result reference (ref + uri) for an execution from the
# event log, and publish a minimal DR-replay event to the noetl_events stream.
# The replay carries ONLY the reference (no event_id) so the EVENT materializer
# drops+acks it cleanly (no noetl.event pollution, no projection), while the
# RESULT materializer (DR mode) classifies it by the result_ref and re-derives
# the object for its URN.
dr_replay() {  # eid -> 0 if published, 1 if no reference found
  local refjson
  refjson="$(noetl query "SELECT result AS r FROM noetl.event
      WHERE execution_id = $1 AND result::text LIKE '%result_ref%'
      ORDER BY event_id DESC LIMIT 1" --format json 2>/dev/null || true)"
  local payload
  payload="$(printf '%s' "$refjson" | python3 -c '
import json,sys
d=json.loads(sys.stdin.read() or "{}").get("result",[])
if not d: sys.exit(3)
res=d[0].get("r")
if isinstance(res,str): res=json.loads(res)
def find(v):
    if isinstance(v,dict):
        if v.get("kind")=="result_ref": return v
        for x in v.values():
            r=find(x)
            if r: return r
    elif isinstance(v,list):
        for x in v:
            r=find(x)
            if r: return r
    return None
rr=find(res)
if not rr or not rr.get("ref") or not rr.get("uri"): sys.exit(3)
print(json.dumps({"result":{"reference":{"kind":"result_ref","ref":rr["ref"],"uri":rr["uri"]}}}))
' 2>/dev/null || true)"
  [[ -n "$payload" ]] || return 1
  nats --server "$NATS_LOCAL" pub "noetl.events.dr_replay" "$payload" >/dev/null 2>&1 || true
  return 0
}

OVERALL=0
fail() { echo "kind-val: FAIL — $1" >&2; OVERALL=1; }

assert_invariants() {  # eid label
  local eid="$1" lbl="$2" rows distinct cat0 orch roots dangling walk terms
  rows="$(count_rows "SELECT COUNT(*) AS n FROM noetl.event WHERE execution_id = $eid")"
  distinct="$(count_rows "SELECT COUNT(DISTINCT event_id) AS n FROM noetl.event WHERE execution_id = $eid")"
  cat0="$(count_rows "SELECT COUNT(*) AS n FROM noetl.event WHERE execution_id = $eid AND catalog_id = 0")"
  orch="$(count_rows "SELECT COUNT(*) AS n FROM noetl.event WHERE execution_id = $eid AND node_name = '__orchestrate__'")"
  roots="$(count_rows "SELECT COUNT(*) AS n FROM noetl.event WHERE execution_id = $eid AND prev_event_id IS NULL")"
  dangling="$(count_rows "SELECT COUNT(*) AS n FROM noetl.event e WHERE e.execution_id = $eid AND e.prev_event_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM noetl.event p WHERE p.execution_id = $eid AND p.event_id = e.prev_event_id)")"
  terms="$(count_rows "SELECT COUNT(*) AS n FROM noetl.event WHERE execution_id = $eid AND event_type IN ('playbook.completed','playbook_completed','playbook.failed','playbook_failed')")"
  echo "kind-val: $lbl invariants — rows=$rows distinct=$distinct catalog0=$cat0 orch=$orch roots=$roots dangling=$dangling terminals=$terms"
  [[ "$rows" -gt 0 && "$rows" == "$distinct" ]] || fail "$lbl sole-writer breach rows=$rows distinct=$distinct"
  [[ "$cat0" == "0" ]] || fail "$lbl $cat0 events with catalog_id=0"
  [[ "$orch" == "0" ]] || fail "$lbl $orch __orchestrate__ rows (sole-writer)"
  [[ "$roots" == "1" ]] || fail "$lbl chain has $roots roots (expected 1)"
  [[ "$dangling" == "0" ]] || fail "$lbl $dangling dangling prev_event_id pointers"
  [[ "$terms" == "1" ]] || fail "$lbl has $terms terminal events (expected 1)"
}

# ----------------------------------------------------------------------
# Setup: fake-gcs-server + GCS backend + cell registry + materializer.
# ----------------------------------------------------------------------
echo; echo "kind-val: deploying fake-gcs-server emulator"
"${KCTX[@]}" apply -f "$MANIFEST" >/dev/null
"${KCTX[@]}" rollout status deploy/fake-gcs-server --timeout=120s >/dev/null 2>&1 || true

"${KCTX[@]}" port-forward svc/fake-gcs-server 4443:4443 >/dev/null 2>&1 &
PF_PID=$!
sleep 3
curl -fsS -X POST "http://localhost:4443/storage/v1/b?project=noetl-test" \
  -H 'Content-Type: application/json' -d "{\"name\":\"$GCS_BUCKET\"}" >/dev/null 2>&1 \
  || echo "kind-val: bucket create returned non-2xx (may already exist) — continuing"
echo "kind-val: bucket $GCS_BUCKET ready on fake-gcs-server"

echo "kind-val: NATS port-forward (for DR re-feed)"
kubectl --context "$KIND_CONTEXT" -n "$NATS_NAMESPACE" port-forward svc/nats 4222:4222 >/dev/null 2>&1 &
NATS_PF_PID=$!
sleep 3
nats --server "$NATS_LOCAL" stream info noetl_events >/dev/null 2>&1 \
  || { echo "kind-val: cannot reach noetl_events stream at $NATS_LOCAL — DR re-feed impossible." >&2; exit 2; }

echo "kind-val: configuring GCS backend + cell registry + shadow materializer"
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
roll "$NOETL_SERVER_DEPLOY"; roll "$NOETL_SYSTEM_POOL_DEPLOY"; sleep 6

# ======================================================================
# Produce a LIVE tier object (a real execution: object + surviving events).
# ======================================================================
echo; echo "kind-val: producing a LIVE tier object (real execution)"
launch_leg "live"; LIVE_EID="$LEG_EID"; await_leg
[[ "$LEG_STATUS" == "COMPLETED" ]] || fail "live leg did not COMPLETE (got $LEG_STATUS)"
assert_invariants "$LIVE_EID" "live"
await_tier "$LIVE_EID" || fail "live tier object never appeared"
LIVE_KEY="$(gcs_first_key_for_eid "$LIVE_EID")"
[[ -n "$LIVE_KEY" ]] || fail "could not find the live tier object key for exec $LIVE_EID"
echo "kind-val: live tier object — $LIVE_KEY"

# Plant a synthetic ORPHAN object: an aged-out, unreferenced execution id.
ORPHAN_KEY="noetl/env=$CELL_ENV/region=$CELL_REGION/cell=$CELL/shard=s0001/tenant=default/project=default/date=2024-01-01/execution=$DEAD_EID/results/orphan/0/0/1.json"
gcs_put_orphan "$ORPHAN_KEY"
[[ "$(gcs_exists "$ORPHAN_KEY")" == "yes" ]] || fail "could not plant the orphan object"
echo "kind-val: planted orphan tier object — execution=$DEAD_EID"

# ======================================================================
# GC-1 — dry-run: lists the dead orphan, skips the live object, deletes nothing.
# ======================================================================
echo; echo "================================================================"
echo "kind-val: GC-1 — NOETL_RESULT_TIER_GC ON, dry-run (list dead, keep live)"
echo "================================================================"
"${KCTX[@]}" set env deploy/"$NOETL_SERVER_DEPLOY" NOETL_RESULT_TIER_GC=true >/dev/null
roll "$NOETL_SERVER_DEPLOY"; sleep 5

REP="$(gc_call true 0)"
GC1_ENABLED="$(printf '%s' "$REP" | gc_field enabled)"
GC1_DELETED="$(printf '%s' "$REP" | gc_field deleted)"
GC1_SKIPLIVE="$(printf '%s' "$REP" | gc_field skipped_live)"
GC1_DEADCAND="$(gc_candidate_eid "$REP" "$DEAD_EID")"
GC1_LIVECAND="$(gc_candidate_eid "$REP" "$LIVE_EID")"
echo "kind-val: GC-1 — enabled=$GC1_ENABLED deleted=$GC1_DELETED skipped_live=$GC1_SKIPLIVE dead_candidates=$GC1_DEADCAND live_candidates=$GC1_LIVECAND"
[[ "$GC1_ENABLED" == "True" ]] || fail "GC-1 endpoint not enabled (flag should be on)"
[[ "$GC1_DELETED" == "0" ]] || fail "GC-1 dry-run deleted $GC1_DELETED objects (must be 0)"
[[ "$GC1_DEADCAND" -ge 1 ]] || fail "GC-1 did not list the dead orphan (execution=$DEAD_EID) as a candidate"
[[ "$GC1_LIVECAND" == "0" ]] || fail "GC-1 listed the LIVE object (execution=$LIVE_EID) as a candidate — safety breach"
[[ "$GC1_SKIPLIVE" -ge 1 ]] || fail "GC-1 did not skip any live object (skipped_live=0)"
[[ "$(gcs_exists "$ORPHAN_KEY")" == "yes" ]] || fail "GC-1 dry-run deleted the orphan (must not)"
[[ "$(gcs_exists "$LIVE_KEY")" == "yes" ]] || fail "GC-1 dry-run deleted the live object (must not)"
echo "kind-val: GC-1 ✓ — dry-run listed the orphan, skipped the live object, deleted nothing"

# ======================================================================
# GC-2 — delete: removes ONLY the dead orphan; the live object SURVIVES.
# ======================================================================
echo; echo "================================================================"
echo "kind-val: GC-2 — delete sweep (reclaim dead only; live survives)"
echo "================================================================"
REP="$(gc_call false 0)"
GC2_DELETED="$(printf '%s' "$REP" | gc_field deleted)"
GC2_SKIPLIVE="$(printf '%s' "$REP" | gc_field skipped_live)"
GC2_DEADDEL="$(gc_candidate_eid "$REP" "$DEAD_EID" deleted_true)"
echo "kind-val: GC-2 — deleted=$GC2_DELETED skipped_live=$GC2_SKIPLIVE dead_deleted=$GC2_DEADDEL"
[[ "$GC2_DELETED" -ge 1 ]] || fail "GC-2 deleted nothing (expected the orphan)"
[[ "$GC2_DEADDEL" -ge 1 ]] || fail "GC-2 did not delete the orphan (execution=$DEAD_EID)"
[[ "$GC2_SKIPLIVE" -ge 1 ]] || fail "GC-2 did not skip the live object (skipped_live=0)"
[[ "$(gcs_exists "$ORPHAN_KEY")" == "no" ]] || fail "GC-2 left the orphan in place (delete failed)"
[[ "$(gcs_exists "$LIVE_KEY")" == "yes" ]] || fail "GC-2 deleted the LIVE object — SAFETY BREACH"
# The live object still serves via the server object read path (resolve fetch).
[[ -n "$(server_object_sha "$LIVE_KEY")" ]] || fail "GC-2: live object no longer served by the read path"
echo "kind-val: GC-2 ✓ — orphan reclaimed; live-referenced object survived and still serves"

# ======================================================================
# GC-3 — flag OFF: the endpoint is a no-op (deletes nothing).
# ======================================================================
echo; echo "================================================================"
echo "kind-val: GC-3 — NOETL_RESULT_TIER_GC OFF (no-op)"
echo "================================================================"
gcs_put_orphan "$ORPHAN_KEY"  # re-plant a dead object
"${KCTX[@]}" set env deploy/"$NOETL_SERVER_DEPLOY" NOETL_RESULT_TIER_GC=false >/dev/null
roll "$NOETL_SERVER_DEPLOY"; sleep 5
REP="$(gc_call false 0)"
GC3_ENABLED="$(printf '%s' "$REP" | gc_field enabled)"
GC3_DELETED="$(printf '%s' "$REP" | gc_field deleted)"
echo "kind-val: GC-3 — enabled=$GC3_ENABLED deleted=$GC3_DELETED (both want False/0)"
[[ "$GC3_ENABLED" == "False" ]] || fail "GC-3 endpoint enabled with flag off (Δ no-op breach)"
[[ "$GC3_DELETED" == "0" ]] || fail "GC-3 deleted $GC3_DELETED with flag off (must be 0)"
[[ "$(gcs_exists "$ORPHAN_KEY")" == "yes" ]] || fail "GC-3 (flag off) deleted the orphan — no-op breach"
gcs_delete "$ORPHAN_KEY"  # tidy the re-planted orphan ourselves
echo "kind-val: GC-3 ✓ — flag-off sweep was a true no-op"

# ======================================================================
# DR-1 — re-derive: a deleted referenced object is rebuilt BYTE-IDENTICALLY.
# ======================================================================
echo; echo "================================================================"
echo "kind-val: DR-1 — NOETL_RESULT_TIER_DR ON, re-derive a deleted object"
echo "================================================================"
launch_leg "dr"; DR_EID="$LEG_EID"; await_leg
[[ "$LEG_STATUS" == "COMPLETED" ]] || fail "dr leg did not COMPLETE (got $LEG_STATUS)"
assert_invariants "$DR_EID" "dr"
await_tier "$DR_EID" || fail "dr tier object never appeared"
DR_KEY="$(gcs_first_key_for_eid "$DR_EID")"
[[ -n "$DR_KEY" ]] || fail "could not find the dr tier object key for exec $DR_EID"
DR_SHA_ORIG="$(gcs_get_sha "$DR_KEY")"
[[ -n "$DR_SHA_ORIG" ]] || fail "could not read the original dr object bytes"
echo "kind-val: dr tier object — $DR_KEY sha256=${DR_SHA_ORIG:0:16}…"

# Simulate loss: delete the referenced tier object.
gcs_delete "$DR_KEY"
[[ "$(gcs_exists "$DR_KEY")" == "no" ]] || fail "DR-1 could not delete the object to simulate loss"
echo "kind-val: DR-1 — deleted the referenced object (simulated loss)"

# Turn the materializer into DR verify-and-repair mode (DR flag ALONE spawns it).
"${KCTX[@]}" set env deploy/"$NOETL_SYSTEM_POOL_DEPLOY" \
  NOETL_RESULT_MATERIALIZER_ENABLED=false NOETL_RESULT_TIER_DR=true >/dev/null
roll "$NOETL_SYSTEM_POOL_DEPLOY"; sleep 8
RD0="$(system_metric 'noetl_worker_result_tier_dr_total\{outcome="rederived"\}')"

dr_replay "$DR_EID" || fail "DR-1 found no over-budget reference to re-feed for exec $DR_EID"
echo "kind-val: DR-1 — re-fed the WAL reference; awaiting re-derive"
sleep 20
RD1="$(system_metric 'noetl_worker_result_tier_dr_total\{outcome="rederived"\}')"
DR_SHA_NEW="$(gcs_get_sha "$DR_KEY")"
SRV_SHA="$(server_object_sha "$DR_KEY")"
echo "kind-val: DR-1 — rederived Δ=$((RD1-RD0)) object_exists=$(gcs_exists "$DR_KEY") sha_new=${DR_SHA_NEW:0:16}… srv_sha=${SRV_SHA:0:16}…"
[[ $((RD1-RD0)) -ge 1 ]] || fail "DR-1 did not record a re-derive (rederived Δ0)"
[[ "$(gcs_exists "$DR_KEY")" == "yes" ]] || fail "DR-1 did not rebuild the missing object"
[[ "$DR_SHA_NEW" == "$DR_SHA_ORIG" ]] || fail "DR-1 rebuilt object is NOT byte-identical ($DR_SHA_NEW != $DR_SHA_ORIG)"
[[ "$SRV_SHA" == "$DR_SHA_ORIG" ]] || fail "DR-1 resolve-by-URN read path did not serve the byte-identical object"
echo "kind-val: DR-1 ✓ — missing object re-derived BYTE-IDENTICALLY; read path serves it"

# ======================================================================
# DR-2 — flag OFF: the same re-feed does NOT rebuild the object (no-op).
# ======================================================================
echo; echo "================================================================"
echo "kind-val: DR-2 — NOETL_RESULT_TIER_DR OFF (re-feed is a no-op)"
echo "================================================================"
gcs_delete "$DR_KEY"
[[ "$(gcs_exists "$DR_KEY")" == "no" ]] || fail "DR-2 could not delete the object"
# All result-materializer flags off → not spawned → nothing processes the re-feed.
"${KCTX[@]}" set env deploy/"$NOETL_SYSTEM_POOL_DEPLOY" \
  NOETL_RESULT_MATERIALIZER_ENABLED=false NOETL_RESULT_TIER_DR=false >/dev/null
roll "$NOETL_SYSTEM_POOL_DEPLOY"; sleep 8
RD0="$(system_metric 'noetl_worker_result_tier_dr_total')"
dr_replay "$DR_EID" || true
echo "kind-val: DR-2 — re-fed the reference with DR off; awaiting (expect no rebuild)"
sleep 20
RD1="$(system_metric 'noetl_worker_result_tier_dr_total')"
echo "kind-val: DR-2 — dr_total Δ=$((RD1-RD0)) object_exists=$(gcs_exists "$DR_KEY") (want Δ0/no)"
[[ $((RD1-RD0)) -eq 0 ]] || fail "DR-2 (flag off) moved the DR metric (Δ=$((RD1-RD0)) != 0)"
[[ "$(gcs_exists "$DR_KEY")" == "no" ]] || fail "DR-2 (flag off) rebuilt the object — no-op breach"
echo "kind-val: DR-2 ✓ — flag-off re-feed was a true no-op (object stayed missing)"

echo
if [[ "$OVERALL" -eq 0 ]]; then
  echo "================================================================"
  echo "kind-val: PASS — #104 Phase F result-tier GC + DR"
  echo "  GC-1 : dry-run listed the dead orphan (execution=$DEAD_EID), skipped the"
  echo "         live object (execution=$LIVE_EID), deleted nothing"
  echo "  GC-2 : delete reclaimed ONLY the orphan; the live-referenced object"
  echo "         (exec $LIVE_EID) survived and still serves via the read path"
  echo "  GC-3 : flag-off sweep was a true no-op (enabled=false, deleted=0)"
  echo "  DR-1 : exec $DR_EID — a deleted referenced object was re-derived"
  echo "         BYTE-IDENTICALLY (sha256 match) and the read path serves it"
  echo "  DR-2 : flag-off re-feed was a true no-op (object stayed missing, Δ0)"
  echo "  cutover invariants intact on every real execution."
  echo "================================================================"
  exit 0
fi

echo "================================================================"
echo "kind-val: FAIL — see assertion errors above"
echo "================================================================"
echo "kind-val: server logs (tail 80):"; "${KCTX[@]}" logs deploy/"$NOETL_SERVER_DEPLOY" --tail=80 || true
echo; echo "kind-val: system-pool logs (tail 100):"; "${KCTX[@]}" logs deploy/"$NOETL_SYSTEM_POOL_DEPLOY" --tail=100 || true
exit 1

#!/usr/bin/env bash
#
# deploy_replica_affinity_topology.sh — stand up / tear down the 2-replica
# execution-affinity server topology for kind_validate_replica_coherence.sh
# (RFC noetl/ai-meta#116).
#
# `up`   — scale the baseline noetl-server-rust Deployment to 0, apply the
#          StatefulSet (2 replicas, distinct shard index per pod via hostname
#          ordinal) + its headless service, wait for both pods Ready.
# `down` — delete the StatefulSet + headless service, scale the baseline
#          Deployment back to 1, wait Ready.  Restores the clean kind baseline.
#
# The image must already be loaded into the kind node (kind load image-archive).
#
# Usage:
#   NOETL_SERVER_IMAGE=localhost/noetl-server:affinity-116 \
#     ./scripts/deploy_replica_affinity_topology.sh up
#   ./scripts/deploy_replica_affinity_topology.sh down
#
# Exits 0 on success; 2 on a precondition error.

set -euo pipefail

KIND_CONTEXT="${NOETL_KIND_CONTEXT:-kind-noetl}"
NAMESPACE="${NOETL_K8S_NAMESPACE:-noetl}"
DEPLOY="${NOETL_SERVER_DEPLOY:-noetl-server-rust}"
IMAGE="${NOETL_SERVER_IMAGE:-localhost/noetl-server:affinity-116}"
WAIT_SECS="${NOETL_TOPOLOGY_WAIT_SECS:-180}"
# The off-server drive (NOETL_STATE_BUILDER=offserver) on the server pods needs
# the matching builder on the system-pool worker that runs the WAL drive —
# without it the worker's WAL index is never populated, every drive reports
# "WAL chain incomplete", and executions stall.  `up` flips it; `down` restores.
SYSTEM_POOL_DEPLOY="${NOETL_SYSTEM_POOL_DEPLOY:-noetl-worker-system-pool}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="$SCRIPT_DIR/../manifests/replica-affinity/statefulset.yaml"

KCTX=(kubectl --context "$KIND_CONTEXT" -n "$NAMESPACE")

ACTION="${1:-}"
[[ "$ACTION" == "up" || "$ACTION" == "down" ]] || {
  echo "usage: $0 up|down" >&2; exit 2;
}

command -v kubectl >/dev/null 2>&1 || { echo "topology: kubectl not in PATH" >&2; exit 2; }
[[ -f "$MANIFEST" ]] || { echo "topology: manifest not found: $MANIFEST" >&2; exit 2; }

up() {
  echo "topology: scaling baseline Deployment/$DEPLOY to 0…"
  "${KCTX[@]}" scale "deployment/$DEPLOY" --replicas=0 >/dev/null 2>&1 || true
  "${KCTX[@]}" rollout status "deployment/$DEPLOY" --timeout=60s >/dev/null 2>&1 || true
  # Wait for the Deployment's pods to actually disappear so the StatefulSet of
  # the same name + label doesn't briefly double-serve under the `noetl` Service.
  for _ in $(seq 1 30); do
    local n
    n="$("${KCTX[@]}" get pods -l app=noetl-server-rust \
        -o jsonpath='{range .items[*]}{.metadata.ownerReferences[0].kind}{"\n"}{end}' 2>/dev/null \
        | grep -c ReplicaSet || true)"
    [[ "${n:-0}" -eq 0 ]] && break
    sleep 2
  done

  echo "topology: flipping system-pool worker $SYSTEM_POOL_DEPLOY to NOETL_STATE_BUILDER=offserver…"
  "${KCTX[@]}" set env "deployment/$SYSTEM_POOL_DEPLOY" NOETL_STATE_BUILDER=offserver >/dev/null 2>&1 || true

  echo "topology: applying StatefulSet (2 replicas, image=$IMAGE)…"
  sed "s|__IMAGE__|$IMAGE|g" "$MANIFEST" | "${KCTX[@]}" apply -f - >/dev/null

  echo "topology: waiting for StatefulSet/$DEPLOY rollout (≤${WAIT_SECS}s)…"
  "${KCTX[@]}" rollout status "statefulset/$DEPLOY" --timeout="${WAIT_SECS}s"
  "${KCTX[@]}" rollout status "deployment/$SYSTEM_POOL_DEPLOY" --timeout="${WAIT_SECS}s" >/dev/null 2>&1 || true
  "${KCTX[@]}" get pods -l app=noetl-server-rust -o wide
  echo "topology: UP — 2-replica execution-affinity topology ready (server offserver+audit_only+nats_kv+affinity, worker offserver)."
}

down() {
  echo "topology: deleting StatefulSet + headless service…"
  "${KCTX[@]}" delete statefulset "$DEPLOY" --ignore-not-found >/dev/null 2>&1 || true
  "${KCTX[@]}" delete service noetl-server-rust-headless --ignore-not-found >/dev/null 2>&1 || true
  # Wait for the StatefulSet pods to clear before restoring the Deployment.
  for _ in $(seq 1 30); do
    local n
    n="$("${KCTX[@]}" get pods -l app=noetl-server-rust \
        -o jsonpath='{range .items[*]}{.metadata.ownerReferences[0].kind}{"\n"}{end}' 2>/dev/null \
        | grep -c StatefulSet || true)"
    [[ "${n:-0}" -eq 0 ]] && break
    sleep 2
  done
  echo "topology: restoring system-pool worker $SYSTEM_POOL_DEPLOY to NOETL_STATE_BUILDER=server…"
  "${KCTX[@]}" set env "deployment/$SYSTEM_POOL_DEPLOY" NOETL_STATE_BUILDER=server >/dev/null 2>&1 || true
  echo "topology: scaling baseline Deployment/$DEPLOY back to 1…"
  "${KCTX[@]}" scale "deployment/$DEPLOY" --replicas=1 >/dev/null
  "${KCTX[@]}" rollout status "deployment/$DEPLOY" --timeout="${WAIT_SECS}s"
  echo "topology: DOWN — clean single-replica baseline restored."
}

"$ACTION"

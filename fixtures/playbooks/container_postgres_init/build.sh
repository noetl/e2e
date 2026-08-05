#!/bin/bash
set -euo pipefail

# build.sh - Build and load the container test image into the Kind cluster.
# Usage: ./build.sh [kind-cluster-name]
#
# Runtime-agnostic: uses whichever of docker / podman is on PATH.  When the
# runtime is podman, `kind` is told to use its podman provider via
# KIND_EXPERIMENTAL_PROVIDER so `kind load` targets the podman-backed node.

CLUSTER_NAME="${1:-noetl}"
# Non-`latest` tag so Kubernetes defaults imagePullPolicy to IfNotPresent and
# uses the kind-loaded image without attempting a registry pull (ai-meta#180).
IMAGE_NAME="noetl/postgres-container-test:e2e"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Detect container runtime (docker preferred, podman fallback).
if command -v docker >/dev/null 2>&1; then
    RUNTIME="docker"
elif command -v podman >/dev/null 2>&1; then
    RUNTIME="podman"
    export KIND_EXPERIMENTAL_PROVIDER=podman
else
    echo "ERROR: neither docker nor podman found on PATH"
    exit 1
fi

echo "==================================================="
echo "Container Test Image Build and Load"
echo "==================================================="
echo "Image:   $IMAGE_NAME"
echo "Cluster: $CLUSTER_NAME"
echo "Runtime: $RUNTIME"
echo "Context: $SCRIPT_DIR"
echo "==================================================="
echo ""

# Step 1: Build image
echo "Step 1: Building image..."
"$RUNTIME" build -t "$IMAGE_NAME" "$SCRIPT_DIR"
echo "✓ Image built successfully"
echo ""

# Step 2: Verify image exists
echo "Step 2: Verifying local image..."
if "$RUNTIME" images "$IMAGE_NAME" | grep -q postgres-container-test; then
    "$RUNTIME" images "$IMAGE_NAME"
    echo "✓ Image verified locally"
else
    echo "ERROR: Image not found locally"
    exit 1
fi
echo ""

# Step 3: Check if Kind cluster exists
echo "Step 3: Checking Kind cluster..."
if ! kind get clusters | grep -q "^${CLUSTER_NAME}$"; then
    echo "ERROR: Kind cluster '$CLUSTER_NAME' not found"
    echo "Available clusters:"
    kind get clusters
    echo ""
    echo "Create cluster with: noetl run automation/boot.yaml"
    exit 1
fi
echo "✓ Cluster exists"
echo ""

# Step 4: Load image into Kind
echo "Step 4: Loading image into Kind cluster..."
kind load docker-image "$IMAGE_NAME" --name "$CLUSTER_NAME"
echo "✓ Image loaded into cluster"
echo ""

# Step 5: Verify image in cluster
echo "Step 5: Verifying image in cluster..."
if "$RUNTIME" exec -t "${CLUSTER_NAME}-control-plane" crictl images 2>/dev/null | grep -q postgres-container-test; then
    echo "✓ Image available in cluster"
    "$RUNTIME" exec -t "${CLUSTER_NAME}-control-plane" crictl images | grep postgres-container-test
else
    echo "WARNING: Could not verify image in cluster (may require admin permissions)"
fi
echo ""

echo "==================================================="
echo "Build and load completed successfully!"
echo "==================================================="
echo ""
echo "Next steps:"
echo "  1. Register + run via the regression runner:"
echo "     scripts/rust_regression_run.sh <server-url> \\"
echo "       <(echo fixtures/playbooks/container_postgres_init/container_postgres_init.yaml)"
echo "  2. Or register: noetl register playbook fixtures/playbooks/container_postgres_init/"
echo ""

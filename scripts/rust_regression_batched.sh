#!/usr/bin/env bash
# Batched wrapper around rust_regression_run.sh that restarts the kubectl
# port-forward per chunk, so long full-suite sweeps don't fail when a single
# port-forward drops.  Aggregates a final pass/fail tally.
#
# Usage: scripts/rust_regression_batched.sh <list-file> [context] [chunk]
set -u
LIST="${1:?fixture list file required}"
CTX="${2:-kind-noetl}"
CHUNK="${3:-12}"
PORT=18082
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 2

mapfile_compat() { FILES=(); while IFS= read -r l; do [ -z "$l" ] && continue; case "$l" in \#*) continue;; esac; FILES+=("$l"); done < "$1"; }
mapfile_compat "$LIST"
total=${#FILES[@]}
echo "batched sweep: $total fixtures, chunk=$CHUNK, ctx=$CTX"
: > /tmp/batched_results.txt

i=0
while [ "$i" -lt "$total" ]; do
  # fresh port-forward per chunk
  pkill -f "port-forward svc/noetl-server-rust ${PORT}:8082" 2>/dev/null
  kubectl --context "$CTX" -n noetl port-forward "svc/noetl-server-rust" "${PORT}:8082" >/tmp/pf-batch.log 2>&1 &
  PFPID=$!
  sleep 4
  # write this chunk to a temp list
  : > /tmp/batch_chunk.txt
  j=0
  while [ "$j" -lt "$CHUNK" ] && [ "$((i+j))" -lt "$total" ]; do
    echo "${FILES[$((i+j))]}" >> /tmp/batch_chunk.txt
    j=$((j+1))
  done
  bash scripts/rust_regression_run.sh "http://localhost:${PORT}" /tmp/batch_chunk.txt 2>/dev/null \
    | grep -vE "^PLAYBOOK|^---|^Non-green|^$" >> /tmp/batched_results.txt
  kill "$PFPID" 2>/dev/null
  i=$((i+CHUNK))
  echo "  ...$i/$total done"
done

echo ""
echo "=== AGGREGATE ==="
for s in COMPLETED FAILED EXEC_FAIL REG_FAIL MISSING; do
  echo "$s: $(grep -cE " $s( |$)" /tmp/batched_results.txt 2>/dev/null)"
done
echo "results: /tmp/batched_results.txt"

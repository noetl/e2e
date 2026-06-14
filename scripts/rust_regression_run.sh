#!/usr/bin/env bash
# Rust-stack regression runner (noetl/ai-meta#49 follow-up).
#
# Registers + executes a curated set of fixture playbooks against a running
# NoETL Rust server and reports a pass/fail matrix.  Unlike the Python-era
# master_regression_test.yaml (which orchestrates sub-playbooks and assumes
# Python-engine semantics), this drives the server's HTTP API directly so it
# works against the Rust control plane and is easy to point at kind or prod.
#
# Usage:
#   scripts/rust_regression_run.sh [BASE_URL] [SET]
#     BASE_URL  default http://localhost:18082  (port-forward to noetl-server-rust)
#     SET       'core' (default) | path to a newline-list file of fixture yaml paths
#
# Each fixture is registered (POST /api/catalog/register), executed
# (POST /api/execute), and polled to a terminal status.  Exit code is the
# number of non-COMPLETED fixtures (0 = all green).
set -u

BASE="${1:-http://localhost:18082}"
SET="${2:-core}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 2

# Curated 'core' set — self-contained, Rust-convention fixtures (no external
# APIs / cloud creds / Python-era `libs:` blocks).  Every entry is verified
# green against the Rust control plane (kind, 2026-06-14): basic python, loops,
# control-flow routing, fanout/parallelism, sub-playbook composition,
# large-result extraction, output selection.  Extend deliberately as more
# fixtures are migrated to Rust conventions (see noetl/ai-meta#98).
CORE_FIXTURES=(
  # basic python + args + large results
  "fixtures/playbooks/hello_world/hello_world.yaml"
  "fixtures/playbooks/simple_python.yaml"
  "fixtures/playbooks/actions_test.yaml"
  "fixtures/playbooks/comprehensive_test.yaml"
  "fixtures/playbooks/test_args_passing.yaml"
  "fixtures/playbooks/test_large_result_extraction.yaml"
  "fixtures/playbooks/test_output_select.yaml"
  # loops + iteration isolation
  "fixtures/playbooks/loop_test.yaml"
  "fixtures/playbooks/root_scripts/test_simple_loop.yaml"
  "fixtures/playbooks/test_loop_instance_isolation/playbook.yaml"
  "fixtures/playbooks/load_test/heavy_loop_aggregation/heavy_loop_aggregation.yaml"
  # control-flow routing
  "fixtures/playbooks/root_scripts/test_implicit_end_routing.yaml"
  "fixtures/playbooks/root_scripts/test_script_loading.yaml"
  "fixtures/playbooks/test_start_with_action.yaml"
  "fixtures/playbooks/test_end_with_action.yaml"
  "fixtures/playbooks/control_flow_workbook/control_flow_workbook.yaml"
  # vars / templating / transient
  "fixtures/playbooks/vars_test/test_vars_simple.yaml"
  "fixtures/playbooks/vars_test/test_vars_template_access.yaml"
  "fixtures/playbooks/vars_test/test_vars_block.yaml"
  "fixtures/playbooks/vars_test/test_vars_api.yaml"
  "fixtures/playbooks/vars_test/test_transient.yaml"
  # retry, fanout/parallelism, sub-playbook composition
  "fixtures/playbooks/retry_test/python_retry_exception.yaml"
  "fixtures/playbooks/fanout_reduce/fanout_reduce_phase6.yaml"
  "fixtures/playbooks/playbook_composition/user_profile_scorer.yaml"
  # migrated to Rust conventions (entry step renamed to 'start' — #98)
  "fixtures/playbooks/gui/widget_all_types/widget_all_types.yaml"
  "fixtures/playbooks/pft_flow_test/pft_queue_db_maintenance.yaml"
)

if [ "$SET" = "core" ]; then
  FILES=("${CORE_FIXTURES[@]}")
else
  # Portable (bash 3.2 / macOS) read of a newline list, skipping blanks/comments.
  FILES=()
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    case "$line" in \#*) continue ;; esac
    FILES+=("$line")
  done < "$SET"
fi

reg_path() { # echo the registered path or empty
  python3 -c "import json,sys
try: print(json.load(sys.stdin).get('path',''))
except Exception: print('')"
}
exec_eid() {
  python3 -c "import json,sys
try: print(json.load(sys.stdin).get('execution_id',''))
except Exception: print('')"
}
exec_status() {
  python3 -c "import json,sys
try: print(json.load(sys.stdin)['status'])
except Exception: print('ERR')"
}
first_error() {
  python3 -c "import json,sys
d=json.load(sys.stdin)
for e in d.get('events',[]):
    r=e.get('result') or {}
    er=(r.get('context') or {}).get('error') if isinstance(r,dict) else None
    if er:
        print(str(er)[:80]); break"
}

printf '%-50s %-11s %s\n' "PLAYBOOK" "RESULT" "NOTE"
printf '%-50s %-11s %s\n' "--------" "------" "----"
fails=0
for f in "${FILES[@]}"; do
  if [ ! -f "$f" ]; then printf '%-50s %-11s %s\n' "$f" "MISSING" ""; fails=$((fails+1)); continue; fi
  reg=$(curl -s -m 25 -X POST "$BASE/api/catalog/register" -H "Content-Type: application/json" \
        -d "$(python3 -c "import json; print(json.dumps({'content': open('$f').read()}))")")
  path=$(printf '%s' "$reg" | reg_path)
  if [ -z "$path" ]; then printf '%-50s %-11s %s\n' "$(basename "$f")" "REG_FAIL" "$(printf '%s' "$reg" | head -c 50)"; fails=$((fails+1)); continue; fi
  eid=$(curl -s -m 25 -X POST "$BASE/api/execute" -H "Content-Type: application/json" -d "{\"path\": \"$path\"}" | exec_eid)
  if [ -z "$eid" ]; then printf '%-50s %-11s %s\n' "$path" "EXEC_FAIL" ""; fails=$((fails+1)); continue; fi
  st="RUNNING"
  for _ in $(seq 1 16); do
    j=$(curl -s -m 8 "$BASE/api/executions/$eid")
    st=$(printf '%s' "$j" | exec_status)
    [ "$st" = "COMPLETED" ] && break
    [ "$st" = "FAILED" ] && break
    sleep 3
  done
  note=""
  if [ "$st" != "COMPLETED" ]; then
    note=$(curl -s -m 8 "$BASE/api/executions/$eid" | first_error)
    fails=$((fails+1))
  fi
  printf '%-50s %-11s %s\n' "$path" "$st" "$note"
done
echo ""
echo "Non-green: $fails / ${#FILES[@]}"
exit "$fails"

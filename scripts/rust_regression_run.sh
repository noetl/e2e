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
  "fixtures/playbooks/actions_test.yaml"
  "fixtures/playbooks/api_integration/auth0/auth0_login.yaml"
  "fixtures/playbooks/batch_execution/heavy_payload_pipeline_chunk_worker/heavy_payload_pipeline_chunk_worker.yaml"
  "fixtures/playbooks/batch_execution/heavy_payload_pipeline_in_step/heavy_payload_pipeline_in_step.yaml"
  "fixtures/playbooks/batch_execution/kind_playbook_lease_expiry/kind_playbook_lease_expiry.yaml"
  "fixtures/playbooks/batch_execution/server_oom_stress_chunk_worker/server_oom_stress_chunk_worker.yaml"
  "fixtures/playbooks/batch_execution/server_oom_stress_chunk_worker_v2/server_oom_stress_chunk_worker_v2.yaml"
  "fixtures/playbooks/comprehensive_test.yaml"
  "fixtures/playbooks/control_flow_workbook/control_flow_workbook.yaml"
  "fixtures/playbooks/data_transfer/http_iterator_save_postgres/http_iterator_save_postgres.yaml"
  "fixtures/playbooks/data_transfer/http_to_postgres_direct/http_to_postgres_direct.yaml"
  "fixtures/playbooks/data_transfer/http_to_postgres_simple/http_to_postgres_simple.yaml"
  "fixtures/playbooks/data_transfer/postgres_jsonb_test/postgres_jsonb_test.yaml"
  "fixtures/playbooks/duckdb_test.yaml"
  "fixtures/playbooks/fanout_reduce/fanout_reduce_phase6.yaml"
  "fixtures/playbooks/gui/widget_all_types/widget_all_types.yaml"
  "fixtures/playbooks/hello_world/hello_world.yaml"
  "fixtures/playbooks/http_test.yaml"
  "fixtures/playbooks/iterator_save_test/iterator_save_test.yaml"
  "fixtures/playbooks/json_serialization_save.yaml"
  "fixtures/playbooks/json_serialization_save/json_serialization_save.yaml"
  "fixtures/playbooks/keychain/google_id_token/google_id_token_comparison_test.yaml"
  "fixtures/playbooks/keychain/google_id_token/google_id_token_test.yaml"
  "fixtures/playbooks/load_test/heavy_loop_aggregation/heavy_loop_aggregation.yaml"
  "fixtures/playbooks/loop_test.yaml"
  "fixtures/playbooks/pagination/basic/test_pagination_basic.yaml"
  "fixtures/playbooks/pagination/cursor/test_pagination_cursor.yaml"
  "fixtures/playbooks/pagination/max_iterations/test_pagination_max_iterations.yaml"
  "fixtures/playbooks/pagination/offset/test_pagination_offset.yaml"
  "fixtures/playbooks/pagination/pipeline/test_pipeline_error_handling.yaml"
  "fixtures/playbooks/pagination/pipeline/test_pipeline_heavy_payload.yaml"
  "fixtures/playbooks/pagination/pipeline/test_pipeline_simple.yaml"
  "fixtures/playbooks/pagination/retry/test_pagination_retry.yaml"
  "fixtures/playbooks/pft_flow_test/pft_queue_db_maintenance.yaml"
  "fixtures/playbooks/playbook_composition/playbook_composition.yaml"
  "fixtures/playbooks/playbook_composition/user_profile_scorer.yaml"
  "fixtures/playbooks/postgres_test.yaml"
  "fixtures/playbooks/python_psycopg/http_to_postgres_bulk/http_to_postgres_bulk_python.yaml"
  "fixtures/playbooks/regression_test/create_test_schema.yaml"
  "fixtures/playbooks/retry_test/duckdb_retry_query.yaml"
  "fixtures/playbooks/retry_test/http_retry_status_code.yaml"
  "fixtures/playbooks/retry_test/http_retry_with_stop.yaml"
  "fixtures/playbooks/retry_test/postgres_retry_connection.yaml"
  "fixtures/playbooks/retry_test/python_retry_exception.yaml"
  "fixtures/playbooks/retry_test/retry_simple_config.yaml"
  "fixtures/playbooks/root_scripts/test_implicit_end_routing.yaml"
  "fixtures/playbooks/root_scripts/test_script_loading.yaml"
  "fixtures/playbooks/root_scripts/test_simple_loop.yaml"
  "fixtures/playbooks/save_storage_test/create_tables.yaml"
  "fixtures/playbooks/save_storage_test/save_all_storage_types.yaml"
  "fixtures/playbooks/save_storage_test/save_delegation_test.yaml"
  "fixtures/playbooks/save_storage_test/save_edge_cases.yaml"
  "fixtures/playbooks/save_storage_test/save_simple_test.yaml"
  "fixtures/playbooks/simple_python.yaml"
  "fixtures/playbooks/test_args_passing.yaml"
  "fixtures/playbooks/test_end_with_action.yaml"
  "fixtures/playbooks/test_large_result_extraction.yaml"
  "fixtures/playbooks/test_loop_instance_isolation/playbook.yaml"
  "fixtures/playbooks/test_output_select.yaml"
  "fixtures/playbooks/test_start_with_action.yaml"
  "fixtures/playbooks/test_storage_tiers.yaml"
  "fixtures/playbooks/vars_test/test_transient.yaml"
  "fixtures/playbooks/vars_test/test_vars_api.yaml"
  "fixtures/playbooks/vars_test/test_vars_block.yaml"
  "fixtures/playbooks/vars_test/test_vars_simple.yaml"
)

# Integration tier — external-service fixtures that need REAL credentials and
# have SIDE EFFECTS / cost (LLM API calls, real GCS/Snowflake, brokerage
# gateways).  NOT part of the exit-0 `core` gate; run deliberately with creds
# registered.  Verified green on kind 2026-06-14 with real creds.  See
# scripts/RUST_REGRESSION.md for the per-fixture credential + side-effect notes.
INTEGRATION_FIXTURES=(
  # Amadeus travel API (test env, read-only GET searches)
  "fixtures/playbooks/api_integration/amadeus_ai_api/amadeus_ai_api.yaml"
  "fixtures/playbooks/api_integration/amadeus_ai_api/amadeus_ai_api_test.yaml"
  "fixtures/playbooks/api_integration/amadeus_ai_chat_request_query/amadeus_ai_chat_request_query.yaml"
  "fixtures/playbooks/api_integration/amadeus_ai_token_smoke/amadeus_ai_token_smoke.yaml"
  # OpenAI / Anthropic LLM (real API calls — $ per run)
  "fixtures/playbooks/ops/execution_ai_analyze/execution_ai_analyze.yaml"
  "fixtures/playbooks/ops/playbook_ai_explain/playbook_ai_explain.yaml"
  "fixtures/playbooks/ops/playbook_ai_generate/playbook_ai_generate.yaml"
  # external HTTP (open-meteo) + non-blocking tooling load
  "fixtures/playbooks/control_flow/weather_control_flow/weather_control_flow.yaml"
  "fixtures/playbooks/load_test/tooling_non_blocking/tooling_non_blocking.yaml"
  # Interactive Brokers connection-checks (gracefully handle no gateway)
  "fixtures/playbooks/interactive_brokers/ibkr_gateway_maintain.yaml"
  "fixtures/playbooks/interactive_brokers/ibkr_gateway_verify.yaml"
)

if [ "$SET" = "core" ]; then
  FILES=("${CORE_FIXTURES[@]}")
elif [ "$SET" = "integration" ]; then
  FILES=("${INTEGRATION_FIXTURES[@]}")
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

---
id: root
title: Root
---

Playbooks in `root`.

| Catalog path | Fixture file | Description | Tools |
| --- | --- | --- | --- |
| `fixtures/playbooks/broken_sql` | `fixtures/playbooks/broken_sql.yaml` | - | postgres, python |
| `fixtures/playbooks/json_serialization_save` | `fixtures/playbooks/json_serialization_save.yaml` | - | postgres, python |
| `test/actions` | `fixtures/playbooks/actions_test.yaml` | - | - |
| `test/comprehensive` | `fixtures/playbooks/comprehensive_test.yaml` | Comprehensive test with multiple steps, conditionals, and data flow | python |
| `test/duckdb` | `fixtures/playbooks/duckdb_test.yaml` | - | - |
| `test/http` | `fixtures/playbooks/http_test.yaml` | - | http, python |
| `test/loop` | `fixtures/playbooks/loop_test.yaml` | - | python |
| `test/postgres` | `fixtures/playbooks/postgres_test.yaml` | - | - |
| `test/simple_python` | `fixtures/playbooks/simple_python.yaml` | Simple Python test for the worker | python |
| `test_nats_kv` | `fixtures/playbooks/test_nats_kv.yaml` | Test NATS K/V Store operations | - |
| `tests/control-flow/end_with_action` | `fixtures/playbooks/test_end_with_action.yaml` | Test end step with action type that aggregates and executes cleanup | - |
| `tests/control-flow/start_with_action` | `fixtures/playbooks/test_start_with_action.yaml` | Test start step with action type that executes then routes | - |
| `tests/gcs_storage_test` | `fixtures/playbooks/test_gcs_storage.yaml` | Test GCS storage tier for large results. Explicitly configures storage to use GCS.  | - |
| `tests/iterator_save_test` | `fixtures/playbooks/iterator_save_test.yaml` | - | postgres, python |
| `tests/large_result_extraction_test` | `fixtures/playbooks/test_large_result_extraction.yaml` | Simple test for large result externalization and field extraction.  Verifies that: 1. Results &gt; 64KB are stored externally 2. Extracted fields are available in templates 3. _ref pointer is available for lazy loading  | - |
| `tests/output_select_test` | `fixtures/playbooks/test_output_select.yaml` | Test playbook for output_select pattern with large results.  This demonstrates: 1. Large result externalization to NATS storage 2. output_select extraction of small fields 3. Lazy loading via artifact.get 4. Template access to extracted fields  | - |
| `tests/storage_tiers_test` | `fixtures/playbooks/test_storage_tiers.yaml` | Test storage tier auto-selection based on result size.  Storage Tiers (RisingWave-aligned, phase 0): - Inline: &lt; 64KB (no externalization) - NATS KV: 64KB - 1MB - DISK: &gt;= 1MB (local SSD cache + async cloud spill; phase 0 spills   directly to the configured cloud tier) - S3/GCS: explicit durable  The previous `NATS Object Store` probe has been replaced by a `DISK` probe that exercises the new large-payload routing path.  | - |
| `tests/test_args_passing` | `fixtures/playbooks/test_args_passing.yaml` | - | - |
| `v10_canonical_example` | `fixtures/playbooks/v10_canonical_example.yaml` | Demonstrates all canonical v10 DSL patterns | http, postgres, python |

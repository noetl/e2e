---
id: retry-test
title: Retry Test
---

Playbooks in `retry_test`.

| Catalog path | Fixture file | Description | Tools |
| --- | --- | --- | --- |
| `tests/retry/duckdb_query` | `fixtures/playbooks/retry_test/duckdb_retry_query.yaml` | Test DuckDB retry on query failures | duckdb, python |
| `tests/retry/http_status_code` | `fixtures/playbooks/retry_test/http_retry_status_code.yaml` | Test HTTP retry based on status code condition | http, python |
| `tests/retry/http_stop_condition` | `fixtures/playbooks/retry_test/http_retry_with_stop.yaml` | Test HTTP retry with stop condition when successful | http, python |
| `tests/retry/postgres_connection` | `fixtures/playbooks/retry_test/postgres_retry_connection.yaml` | Test Postgres retry on connection or query errors | postgres, python |
| `tests/retry/python_exception` | `fixtures/playbooks/retry_test/python_retry_exception.yaml` | Test Python task retry on exception | python |
| `tests/retry/simple_config` | `fixtures/playbooks/retry_test/retry_simple_config.yaml` | Test simplified retry configuration using tool.spec.policy.rules | http, python |

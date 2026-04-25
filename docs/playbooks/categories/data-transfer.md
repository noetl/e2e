---
id: data-transfer
title: Data Transfer
---

Playbooks in `data_transfer`.

| Catalog path | Fixture file | Description | Tools |
| --- | --- | --- | --- |
| `examples/data_transfer/http_to_postgres_iterator` | `fixtures/playbooks/data_transfer/http_to_postgres_iterator/http_to_postgres_iterator.yaml` | - | http, postgres, python |
| `fixtures/playbooks/data_transfer/http_iterator_save_postgres` | `fixtures/playbooks/data_transfer/http_iterator_save_postgres/http_iterator_save_postgres.yaml` | Test HTTP calls in iterator with save to Postgres - validates loop execution with storage | postgres, python |
| `fixtures/playbooks/data_transfer/http_to_databases` | `fixtures/playbooks/data_transfer/http_to_databases/http_to_databases.yaml` | - | duckdb, ducklake, http, postgres, python, snowflake |
| `fixtures/playbooks/data_transfer/http_to_postgres_direct` | `fixtures/playbooks/data_transfer/http_to_postgres_direct/http_to_postgres_direct.yaml` | - | postgres, python |
| `fixtures/playbooks/data_transfer/http_to_postgres_simple` | `fixtures/playbooks/data_transfer/http_to_postgres_simple/http_to_postgres_simple.yaml` | - | http, postgres, python |
| `fixtures/playbooks/data_transfer/http_to_postgres_transfer` | `fixtures/playbooks/data_transfer/http_to_postgres_transfer/http_to_postgres_transfer.yaml` | - | postgres, python, transfer |
| `fixtures/playbooks/data_transfer/postgres_jsonb_test` | `fixtures/playbooks/data_transfer/postgres_jsonb_test/postgres_jsonb_test.yaml` | Test PostgreSQL JSONB datatype operations and TRUNCATE command | postgres, python |
| `fixtures/playbooks/data_transfer/snowflake_postgres` | `fixtures/playbooks/data_transfer/snowflake_postgres/snowflake_postgres.yaml` | - | postgres, python, snowflake, transfer |

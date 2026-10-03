---
id: tutorials
title: Tutorials
---

Playbooks in `tutorials`.

| Catalog path | Fixture file | Description | Tools |
| --- | --- | --- | --- |
| `fixtures/playbooks/tutorials/internet_postgres_gcs/hmac` | `fixtures/playbooks/tutorials/internet_postgres_gcs/internet_postgres_gcs_hmac.yaml` | Download public JSON, store it in Postgres, then export Postgres rows to GCS using HMAC credentials. | duckdb, postgres, python |
| `fixtures/playbooks/tutorials/internet_postgres_gcs/workload_identity` | `fixtures/playbooks/tutorials/internet_postgres_gcs/internet_postgres_gcs_workload_identity.yaml` | Download public JSON, store it in Postgres, then export Postgres rows to GCS using GKE Workload Identity. | postgres, python |

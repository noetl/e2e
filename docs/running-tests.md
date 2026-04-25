---
id: running-tests
title: Running Tests
---

Start with smoke playbooks before running longer regression or stress suites.

## Smoke Set

```bash
noetl --host localhost --port 8082 exec fixtures/playbooks/hello_world --runtime distributed --json
noetl --host localhost --port 8082 exec test/http --runtime distributed --json
noetl --host localhost --port 8082 exec test/postgres --runtime distributed --json
```

Use the returned `execution_id` with:

```bash
noetl --host localhost --port 8082 status <execution_id> --json
```

## Regression Suites

Regression and batch fixtures can be longer-running and may assume local services, seeded credentials, or storage buckets. Register all fixtures first, then run the smallest relevant catalog path before using umbrella playbooks such as `fixtures/playbooks/regression_test/master_regression_test`.

## Local Kind Notes

The local kind stack should include NoETL server, workers, Postgres, NATS, GUI, and the paginated test server. Prefer ops playbooks from `repos/ops` for rebuilds and redeploys so cluster behavior matches project automation.

---
id: regression-test
title: Regression Test
---

Playbooks in `regression_test`.

| Catalog path | Fixture file | Description | Tools |
| --- | --- | --- | --- |
| `fixtures/playbooks/regression_test/create_test_schema` | `fixtures/playbooks/regression_test/create_test_schema.yaml` | - | postgres, python |
| `fixtures/playbooks/regression_test/master_regression_test` | `fixtures/playbooks/regression_test/master_regression_test.yaml` | - | playbook, python |
| `fixtures/playbooks/regression_test/master_regression_test_parallel` | `fixtures/playbooks/regression_test/master_regression_test_parallel.yaml` | Parallel regression test suite - runs 51 playbooks concurrently (4 skipped) | playbook, postgres, python |

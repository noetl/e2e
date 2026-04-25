---
id: vars-test
title: Vars Test
---

Playbooks in `vars_test`.

| Catalog path | Fixture file | Description | Tools |
| --- | --- | --- | --- |
| `/vars_test/api_test` | `fixtures/playbooks/vars_test/test_vars_api.yaml` | Test variable management API endpoints | - |
| `test/transient` | `fixtures/playbooks/vars_test/test_transient.yaml` | Test variable functionality using declarative patterns (no await, no internal APIs) | - |
| `test/vars_simple` | `fixtures/playbooks/vars_test/test_vars_simple.yaml` | - | - |
| `vars_test/test_vars_block` | `fixtures/playbooks/vars_test/test_vars_block.yaml` | Test vars block for extracting variables from step results | - |
| `vars_test/test_vars_template_access` | `fixtures/playbooks/vars_test/test_vars_template_access.yaml` | Test \{\{ ctx.var_name \}\} template access in Jinja2 | - |

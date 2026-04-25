---
id: registration
title: Register Fixtures
---

Register credentials and playbooks against a running NoETL server. For local kind development, the usual endpoint is `localhost:8082`.

## Credentials

```bash
noetl --host localhost --port 8082 register credential --directory fixtures/credentials
```

The command loads local JSON credential files from `fixtures/credentials/`. Those files must stay untracked.

## Playbooks

```bash
NOETL_HOST=localhost NOETL_PORT=8082 ./fixtures/register_test_playbooks.sh localhost 8082
```

The helper walks `fixtures/playbooks/**/*.yaml` and registers each playbook using its `metadata.path`.

## Quick Verification

```bash
noetl --host localhost --port 8082 exec fixtures/playbooks/hello_world --runtime distributed --json
noetl --host localhost --port 8082 status <execution_id> --json
```

The hello-world smoke should complete with `start`, `test_step`, and `end`.

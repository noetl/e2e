# NoETL E2E Fixtures

This repository holds NoETL end-to-end integration fixtures that were split out
from `noetl/noetl`.

## Layout

- `fixtures/playbooks/` - integration and regression playbooks.
- `fixtures/credentials/` - credential templates and local credential examples.
- `fixtures/payloads/` - small non-secret payload files used by fixtures.
- `fixtures/register_test_playbooks.sh` - helper for registering fixture
  playbooks against a running NoETL endpoint.

## Credential Hygiene

Do not commit real credential JSON files under `fixtures/credentials/`.
Only template/reference files such as `.json.template` and `.json.example`
belong in git.

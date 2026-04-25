---
id: intro
title: NoETL E2E Fixtures
slug: /
---

The `noetl/e2e` repository keeps NoETL end-to-end integration fixtures separate from product code while preserving the catalog paths used by existing tests.

Use this repository for:

- registering local kind credentials and playbooks
- running smoke, integration, regression, and stress playbooks
- documenting fixture ownership, prerequisites, and expected behavior
- maintaining deployment-ready documentation for `https://e2e.noetl.dev`

## Repository Layout

| Path | Purpose |
| --- | --- |
| `fixtures/playbooks/` | NoETL playbooks used for integration and regression coverage. |
| `fixtures/credentials/` | Local credential JSON files and committed templates/examples. |
| `fixtures/payloads/` | Small non-secret payloads used by playbooks. |
| `fixtures/register_test_playbooks.sh` | Helper for registering all fixture playbooks into a running NoETL endpoint. |
| `docs/` | Docusaurus source for this site. |

## Credential Rule

Real `fixtures/credentials/*.json` files are local-only and ignored by git. Commit only `.json.template` and `.json.example` files.

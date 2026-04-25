---
id: credentials
title: Credentials
---

Credential templates live in `fixtures/credentials/`. Real local credential JSON files are intentionally ignored by git.

## Commit Policy

Commit:

- `*.json.template`
- `*.json.example`
- README and setup docs

Do not commit:

- real `*.json` credential payloads
- private keys
- tokens, client secrets, passwords, or service account material

## Registration

```bash
noetl --host localhost --port 8082 register credential --directory fixtures/credentials
```

Review any new credential template before committing it. Templates should use placeholders and document required fields without exposing live values.

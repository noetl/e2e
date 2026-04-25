---
id: ops
title: Ops
---

Playbooks in `ops`.

| Catalog path | Fixture file | Description | Tools |
| --- | --- | --- | --- |
| `ops/execution_ai_analyze` | `fixtures/playbooks/ops/execution_ai_analyze/execution_ai_analyze.yaml` | AI-assisted execution triage playbook. Inputs include execution timeline, playbook YAML, event rows, and optional metrics. Output is a structured root-cause report with remediation and optional patch diff.  | http, noop, python |
| `ops/playbook_ai_explain` | `fixtures/playbooks/ops/playbook_ai_explain/playbook_ai_explain.yaml` | Explain a playbook in plain language with architecture, risks, and test guidance. Input is a target playbook content + payload, output is ai_report JSON.  | http, noop, python |
| `ops/playbook_ai_generate` | `fixtures/playbooks/ops/playbook_ai_generate/playbook_ai_generate.yaml` | Generate a NoETL playbook draft from a natural-language prompt. Returns generated_playbook_yaml plus ai_report metadata.  | http, noop, python |

---
id: spike
title: Spike
---

Playbooks in `spike`.

| Catalog path | Fixture file | Description | Tools |
| --- | --- | --- | --- |
| `tests/spike/spike_e2e_test` | `fixtures/playbooks/spike/spike_e2e_test.yaml` | End-to-end smoke for the NoETL-as-AI-OS spike. Exercises all five gaps in a single execution:  - **Gap 1** (`tool: agent framework=noetl`) — dispatches a peer   sub-playbook as the agent runtime - **Gap 4.1** (auto-dispatch on failure) — `on_failure.troubleshoot:   true` on the agent step, so when the sub-playbook fails the   executor automatically invokes the troubleshoot agent against   the failed sub-execution_id - **Gap 4** (self-troubleshoot agent) — the troubleshoot playbook   itself runs, fetching the failed execution's events and   classifying via Ollama - **Gap 5** (mcp/ollama bridge) — the troubleshoot agent's   ollama_triage step calls the local Ollama bridge for first-pass   classification - **Gap 3** (typed metadata) — `exposes_as_mcp: true` is validated   at register time as the typed Pydantic field  Gap 2 (playbook-as-MCP-server) is tested separately via curl in the runbook playbook (since it's an external-protocol surface, not a sub-flow callable).  Returns the agent envelope from the failed sub-call. The diagnosis appears in `error.diagnosis` per the Gap 4.1 contract.  | agent, python |
| `tests/spike/spike_failing_subflow` | `fixtures/playbooks/spike/spike_failing_subflow.yaml` | Deliberately-failing sub-playbook used by spike_e2e_test. Hits a non-routable URL with no retry so the failure is fast and deterministic — the smoke wants the failure path to be consistent across runs, not a flaky upstream.  Not exposed as an MCP tool (no caller would invoke this on purpose); kept private to the test suite via `exposes_as_mcp: false`.  | http |

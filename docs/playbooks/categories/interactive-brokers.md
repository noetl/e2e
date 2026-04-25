---
id: interactive-brokers
title: Interactive Brokers
---

Playbooks in `interactive_brokers`.

| Catalog path | Fixture file | Description | Tools |
| --- | --- | --- | --- |
| `automation/ibkr/api` | `fixtures/playbooks/interactive_brokers/ibkr_api.yaml` | IBKR Client Portal API operations (server/worker execution) | http, python |
| `automation/ibkr/history` | `fixtures/playbooks/interactive_brokers/ibkr_history.yaml` | Fetch historical market data for a futures contract | http, python |
| `automation/ibkr/maintain` | `fixtures/playbooks/interactive_brokers/ibkr_gateway_maintain.yaml` | Keep IBKR Client Portal Gateway session authenticated | python |
| `automation/ibkr/verify` | `fixtures/playbooks/interactive_brokers/ibkr_gateway_verify.yaml` | Verify IBKR Gateway is reachable and authenticated (distributed) | python |
| `fixtures/playbooks/interactive_brokers/gateway_test` | `fixtures/playbooks/interactive_brokers/ib_gateway_test.yaml` | - | http, python |

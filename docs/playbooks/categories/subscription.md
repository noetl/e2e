---
id: subscription
title: Subscription
---

Playbooks in `subscription`.

| Catalog path | Fixture file | Description | Tools |
| --- | --- | --- | --- |
| `tests/fixtures/subscription_kafka_drain` | `fixtures/playbooks/subscription/subscription_kafka_drain.yaml` | Bounded Apache Kafka subscription drain — consumer-group poll up to `batch` messages, commit offsets, and fan out over the batch.  Phase 1 live-validation fixture for the subscription tool (noetl/ai-meta#90).  | python, subscription |
| `tests/fixtures/subscription_pubsub_drain` | `fixtures/playbooks/subscription/subscription_pubsub_drain.yaml` | Bounded Google Pub/Sub subscription drain — pull up to `batch` messages from the emulator subscription, ack them, and fan out over the batch.  Phase 1 live-validation fixture for the subscription tool (noetl/ai-meta#90).  | python, subscription |

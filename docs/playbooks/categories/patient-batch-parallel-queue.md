---
id: patient-batch-parallel-queue
title: Patient Batch Parallel Queue
---

Playbooks in `patient_batch_parallel_queue`.

| Catalog path | Fixture file | Description | Tools |
| --- | --- | --- | --- |
| `fixtures/playbooks/patient_batch_parallel_queue/patient_batch_parallel_queue` | `fixtures/playbooks/patient_batch_parallel_queue/patient_batch_parallel_queue.yaml` | Queue/claim implementation of parallel patient HTTP processing.  Architecture: - Sequential producer discovers patients in pages of 100. - Producer materializes page into patient_work_queue. - Parallel workers claim one patient at a time via FOR UPDATE SKIP LOCKED. - Each worker performs HTTP call, upserts result idempotently, and updates queue status. - Retries are tracked with attempt_count and next_retry_at.  | postgres, python |

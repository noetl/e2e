---
id: pft-flow-test
title: Pft Flow Test
---

Playbooks in `pft_flow_test`.

| Catalog path | Fixture file | Description | Tools |
| --- | --- | --- | --- |
| `fixtures/playbooks/pft_flow_test/pft_queue_db_maintenance` | `fixtures/playbooks/pft_flow_test/pft_queue_db_maintenance.yaml` | One-time maintenance for the PFT queue table in demo_noetl.  Use this against an already-used database when you want to add the reclaim index concurrently, re-apply table-level autovacuum settings, and vacuum the queue immediately before the next benchmark slice.  | python |
| `fixtures/playbooks/pft_flow_test/test_mds_batch_worker` | `fixtures/playbooks/pft_flow_test/test_mds_batch_worker.yaml` | Sub-playbook for MDS assessment batch fetching in the PFT flow test. Processes one OFFSET/LIMIT slice of pft_test_mds_assessment_ids_work: fetches detail for each assessment ID from the test API and saves to pft_test_mds_assessment_details.  Called by test_pft_flow.yaml run_mds_batch_workers loop.  | postgres, python |
| `fixtures/playbooks/pft_flow_test/test_pft_flow` | `fixtures/playbooks/pft_flow_test/test_pft_flow.yaml` | Full-pipeline PFT flow test — mirrors state_report_generation_prod_v13 without Snowflake.  Tests queue-based patient batching with execution-scoped claim state. If all patients across all facilities are processed, NoETL is stable and the production playbook should work.  Setup: - 10 facilities, 1000 patients each = 10 000 patients total - Each facility requires 10 batches of 100 per data type - 4 paginated fetch steps (assessments 2-4p, conditions 1-3p, medications 2-3p,   vital_signs 1p always) + 1 non-paginated (demographics) - MDS sub-playbook batching (test_mds_batch_worker) for assessments - All test tables are prefixed pft_test_* in public schema  Go/no-go criterion: validate_facility_results shows 1000/1000 per facility for all 5 data types.  Any shortfall indicates the patient-loss bug is still present.  | playbook, postgres, python |

# PFT Flow Test Playbook

End-to-end integration test that reproduces the full patient-data fetch
pipeline from `state_report_generation_prod_v13`, without Snowflake. The main
flow is intentionally action-controlled: NoETL `http` actions fetch fixture
data, NoETL `postgres` actions claim and persist rows, and task-sequence
policies own retry and jump behavior.

## Files

| File | Purpose |
|---|---|
| `test_pft_flow.yaml` | Main playbook: action-controlled batch queue, fixture HTTP fetches, Postgres persistence, validation |
| `test_mds_batch_worker.yaml` | Legacy focused MDS worker fixture; the main flow processes MDS through the same action-controlled batch queue |
| `pft_queue_db_maintenance.yaml` | Optional operator maintenance for already-bloated queue tables |

## What It Tests

The critical code path is execution-scoped DB batch claiming plus declared
NoETL tool actions. Each worker slot claims one bounded batch from
`pft_test_work_batch_queue`, fetches a normalized fixture batch through the
`http` tool, persists explicit rows through the `postgres` tool, and uses
task-sequence `jump` control to claim more work until the queue drains.

This keeps the benchmark under the NoETL tool/action control plane. The main
flow does not hand database credentials to Python and does not hide the patient
loop inside an arbitrary script.

Pass criterion: every facility shows `1000/1000` patients in all five result
tables, and MDS expected/detail counts match. Any shortfall means the workflow
lost patients or skipped detail rows.

## Test Parameters

| Parameter | Value |
|---|---|
| Facilities | 10 |
| Patients per facility | 1,000 |
| Total patients | 10,000 |
| Batch size | 100 patients (`pft_batch_size`) |
| Batch concurrency | 16 action slots (`pft_batch_concurrency`) |
| Batches per data type | 100 for 10k patients |
| Page size | 10 records/page |

## Data Flow

```text
start
  -> setup_facility_work
       seed patients
       seed pft_test_patient_work_queue
       seed pft_test_work_batch_queue
  -> process_pft_action_batches
       16 parallel slots:
         claim_batch  (postgres, SKIP LOCKED)
         fetch_batch  (http, /api/v1/pft/batch/{data_type})
         save_batch   (postgres, jsonb_to_recordset upserts)
         jump claim_batch until no pending batches
  -> validate_all_results
  -> check_results
  -> end
```

The older per-patient cursor steps remain lower in `test_pft_flow.yaml` as
historical fixtures, but the main route enters `process_pft_action_batches`.

## Action-Batch Pattern

`process_pft_action_batches` is a task-sequence loop over a bounded set of
worker slots:

1. `claim_batch` (`postgres`): atomically claims the next pending
   `(data_type, batch_id)` using `FOR UPDATE SKIP LOCKED`.
2. `fetch_batch` (`http`): calls `/api/v1/pft/batch/{data_type}` with the
   claimed patient IDs. The fixture server normalizes paginated domains,
   demographics, and MDS into explicit row arrays.
3. `save_batch` (`postgres`): persists rows using `jsonb_to_recordset`, marks
   patient queue rows done for the five patient domains, and marks the batch
   done.
4. `jump claim_batch`: keeps the slot draining work until `claim_batch` returns
   no rows and breaks.

The fixture server endpoint caps a single HTTP batch at 500 patient IDs. The
playbook default uses 100 to keep Postgres upserts and response payloads
bounded.

## Validation

`validate_all_results` counts `DISTINCT pcc_patient_id` from each result table
and compares the assessment queue-done count for the current execution:

```sql
SELECT COUNT(DISTINCT pcc_patient_id)
FROM public.pft_test_patient_assessments;

SELECT COUNT(DISTINCT patient_id)
FROM public.pft_test_patient_work_queue
WHERE execution_id = '<execution_id>'
  AND data_type = 'assessments'
  AND status = 'done';
```

For each facility, all five patient domains must have exactly 1,000 distinct
patients. MDS expected/detail counts must match.

## Infrastructure Requirements

- NoETL server/worker with task-sequence `jump` and Postgres/HTTP tools enabled.
- PostgreSQL via `pg_k8s` credential.
- Test API server in the `test-server` namespace on port 5555, serving
  `/api/v1/pft/batch/{data_type}`.
- On GKE, use a public, versioned `ghcr.io/noetl/test-server:<tag>` image.

## Running The Test

Use the catalog path without the `.yaml` extension:

```bash
noetl exec fixtures/playbooks/pft_flow_test/test_pft_flow --runtime distributed
```

For smaller smoke runs, override workload values:

```bash
noetl exec fixtures/playbooks/pft_flow_test/test_pft_flow \
  --runtime distributed \
  --payload '{"num_facilities":1,"patients_per_facility":100,"pft_batch_size":25,"pft_batch_concurrency":4}'
```

Check results after completion:

```sql
SELECT facility_mapping_id,
       assessments_done,
       conditions_done,
       medications_done,
       vital_signs_done,
       demographics_done,
       mds_expected,
       mds_details_done
FROM public.pft_test_validation_log
WHERE execution_id = '<execution_id>'
ORDER BY facility_mapping_id;
```

## Optional Queue Maintenance

If the demo database has already seen a long-running or cancelled PFT workload
and you want to clean up queue-table bloat before the next benchmark slice, run
the companion maintenance playbook first. It uses Python + `psycopg` with
autocommit so it can safely execute `CREATE INDEX CONCURRENTLY` and `VACUUM`,
which are not a good fit for the main reset-heavy fixture setup step.

This is an explicit operator maintenance action; it is not part of the PFT
processing path.

# PFT Flow Speedup Explanation

This note explains why the PFT fixture moved from local runs that could take
30+ minutes for 10,000 patients to the current GKE validation run of 1m 53s.

The important point is that the final speedup was not achieved by giving an
uncontrolled Python script database access. The final shape keeps the work
inside declared NoETL tools:

- `postgres` actions claim and persist work.
- `http` actions fetch fixture data.
- `task_sequence` policy controls retry and loop behavior.
- The final validation reads aggregate table state through a `postgres` action.

## Latest Proven Run

- e2e commit: `b0ae122ae119be8bcc71f8dea9be76db0d179675`
- Catalog path: `fixtures/playbooks/pft_flow_test/test_pft_flow`
- Catalog version: `24`
- Execution: `621993877326528945`
- Duration: `112.98s` (`1m 53s`)
- Result: `COMPLETED`
- Result tables: all 5 patient domains at `10000`
- MDS: `10000/10000`
- Validation log: `10` facility rows, each `1000/1000`

## What Was Slow Before

The old playbook used cursor loops at the patient/page level. A worker claimed
one patient, fetched one or more pages, saved one page result, updated queue
state, and then repeated.

Example from the pre-speedup cursor shape:

```yaml
workload:
  api_url: http://paginated-api.test-server.svc.cluster.local:5555
  page_size: 10
  num_facilities: 10
  patients_per_facility: 1000
  claim_batch_size: 1000
  batch_slots: [1, 2, 3, ..., 100]

- step: fetch_assessments
  desc: |
    Cursor-driven per-patient fetch/save for assessments. Each worker
    slot atomically claims the next pending patient row via SQL, fetches
    the assessment pages, persists them, and marks the queue row done.
  loop:
    cursor:
      kind: postgres
      auth: pg_k8s
      claim: |
        WITH candidate AS (
          SELECT patient_id, facility_mapping_id
          FROM public.pft_test_patient_work_queue
          WHERE execution_id = '{{ execution_id }}'
            AND data_type = 'assessments'
            AND status = 'pending'
          ORDER BY patient_id
          FOR UPDATE SKIP LOCKED
          LIMIT 1
        )
        UPDATE public.pft_test_patient_work_queue q
        SET status = 'claimed',
            attempt_count = q.attempt_count + 1,
            worker_id = 'cursor:assessments',
            claimed_at = NOW(),
            updated_at = NOW()
        FROM candidate c
        WHERE q.execution_id = '{{ execution_id }}'
          AND q.data_type = 'assessments'
          AND q.patient_id = c.patient_id
        RETURNING q.patient_id, q.facility_mapping_id;
    iterator: patient
    spec:
      mode: cursor
      max_in_flight: 10
  tool:
    - name: fetch_page
      kind: http
      method: GET
      url: '{{ api_url }}/api/v1/patient/assessments'
      params:
        patientId: '{{ iter.patient.patient_id }}'
        page: '{{ iter.page }}'
        pageSize: '{{ page_size }}'
    - name: save_page
      kind: postgres
      auth: pg_k8s
      command: |
        INSERT INTO public.pft_test_patient_assessments (...)
        SELECT ...
```

That is logically correct, but expensive at 10,000 patients:

- assessments require 2-4 pages per patient;
- conditions require 1-3 pages per patient;
- medications require 2-3 pages per patient;
- vital signs and demographics also have per-patient work;
- MDS detail work adds another domain;
- each tiny item creates NoETL scheduling, claim, HTTP, save, and event overhead.

So the bottleneck was not the fixture data itself. The bottleneck was the number
of NoETL control-plane round trips and tiny database writes.

## The Intermediate Fast Version We Did Not Keep

One intermediate change proved that the fixture itself could run fast by using
one bulk Python processor. That run was around 4m 42s on GKE.

That was useful as a performance experiment, but it was not the desired final
architecture because the Python code had broad database access. The user
requirement was to control the process by NoETL `actions`, not by an arbitrary
script with direct database access.

The final version keeps the speedup idea, but moves the batch boundary into
declared NoETL actions.

## What Changed Now

### 1. Bounded batch queue

The current playbook creates an execution-scoped batch queue:

```yaml
-- Execution-scoped batch queue. The hot path claims bounded batches
-- with postgres actions, fetches them with http actions, and persists
-- result rows with postgres actions. No Python worker receives direct
-- database credentials.
CREATE TABLE IF NOT EXISTS public.pft_test_work_batch_queue (
  execution_id  TEXT        NOT NULL,
  data_type     TEXT        NOT NULL,
  batch_id      INTEGER     NOT NULL,
  patient_ids   INTEGER[]   NOT NULL,
  status        TEXT        NOT NULL DEFAULT 'pending',
  attempt_count INTEGER     NOT NULL DEFAULT 0,
  worker_id     TEXT,
  claimed_at    TIMESTAMPTZ,
  done_at       TIMESTAMPTZ,
  last_error    TEXT,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (execution_id, data_type, batch_id)
);
```

The current workload knobs are:

```yaml
workload:
  pft_batch_size: 25
  pft_batch_concurrency: 16
  batch_slots: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]
```

For 10,000 patients, that means about 400 patient batches per data type. Instead
of controlling every patient/page as a separate orchestration item, NoETL
controls bounded chunks.

### 2. Action-controlled batch processor

The hot path is now one `task_sequence` loop with 16 slots:

```yaml
- step: process_pft_action_batches
  desc: |
    End-to-end high-throughput PFT processor using declared NoETL actions.
    Each slot repeatedly claims one bounded batch, fetches a fixture batch
    over HTTP, persists the explicit rows through the postgres tool, and
    jumps back to claim more work until the batch queue drains.
  loop:
    in: '{{ workload.batch_slots }}'
    iterator: slot
    spec:
      mode: parallel
      max_in_flight: 16
  tool:
    - name: claim_batch
      kind: postgres
      auth: pg_k8s
      command: |
        WITH candidate AS (
          SELECT data_type, batch_id, patient_ids
          FROM public.pft_test_work_batch_queue
          WHERE execution_id = '{{ execution_id }}'
            AND status = 'pending'
          ORDER BY batch_id, data_type
          FOR UPDATE SKIP LOCKED
          LIMIT 1
        )
        UPDATE public.pft_test_work_batch_queue q
        SET status = 'claimed',
            attempt_count = q.attempt_count + 1,
            worker_id = 'action-batch:{{ slot }}',
            claimed_at = NOW(),
            updated_at = NOW(),
            last_error = NULL
        FROM candidate c
        WHERE q.execution_id = '{{ execution_id }}'
          AND q.data_type = c.data_type
          AND q.batch_id = c.batch_id
        RETURNING
          q.data_type,
          q.batch_id,
          ARRAY_TO_STRING(q.patient_ids, ',') AS patient_ids_csv,
          CARDINALITY(q.patient_ids) AS patient_count;

    - name: fetch_batch
      kind: http
      method: GET
      url: '{{ api_url }}/api/v1/pft/batch/{{ iter.data_type }}'
      params:
        patientIds: '{{ iter.patient_ids_csv }}'
        pageSize: '{{ page_size }}'
        patientsPerFacility: '{{ workload.patients_per_facility }}'

    - name: save_batch
      kind: postgres
      auth: pg_k8s
      command: |
        -- Uses JSONB_TO_RECORDSET(...) to persist all rows returned by
        -- the batch HTTP action, then marks the patient queue and batch
        -- queue done in the same action-controlled SQL command.
```

This is the core speedup. NoETL still controls every side effect, but the unit
of work is now a batch rather than a single patient/page.

### 3. Fixture HTTP batch endpoint

The test server gained a fixture-scoped batch endpoint:

```python
@app.get('/api/v1/pft/batch/{data_type}')
def get_pft_batch(
    data_type: str,
    patientIds: str = Query(..., description="Comma-separated patient IDs"),
    pageSize: int = Query(default=10, ge=1),
    patientsPerFacility: int = Query(default=1000, ge=1),
):
    """Return normalized PFT rows for a bounded batch of patient IDs.

    This endpoint is intentionally fixture-scoped. It lets NoETL playbooks keep
    high-throughput orchestration inside declared `http` + `postgres` actions
    instead of handing broad database credentials to arbitrary Python code.
    """
```

For paginated domains, the endpoint expands all expected pages for each patient
inside the fixture server response:

```python
if data_type in {"assessments", "conditions", "medications", "vital_signs"}:
    page_bounds = {
        "assessments": (2, 4),
        "conditions": (1, 3),
        "medications": (2, 3),
        "vital_signs": (1, 1),
    }
    min_pages, max_pages = page_bounds[data_type]
    for patient_id in patient_ids:
        total_pages = _pft_page_count(str(patient_id), data_type, min_pages, max_pages)
        facility_mapping_id = _pft_facility_mapping_id(patient_id, patientsPerFacility)
        for page in range(1, total_pages + 1):
            rows.append({
                "patient_id": patient_id,
                "facility_mapping_id": facility_mapping_id,
                "page_number": page,
                "payload": {
                    "data": _pft_records(str(patient_id), data_type, page, pageSize),
                    "paging": {"hasMore": page < total_pages},
                },
                "is_last_page": page == total_pages,
            })
```

This preserves the fixture semantics while reducing orchestration overhead.

### 4. Bulk SQL insert per batch

The current save path uses `JSONB_TO_RECORDSET` to persist a whole batch of rows:

```yaml
WITH src AS (
  SELECT *
  FROM JSONB_TO_RECORDSET('{{ iter.batch_rows | tojson | replace("'", "''") }}'::jsonb)
    AS r(patient_id INTEGER, facility_mapping_id INTEGER, page_number INTEGER, payload JSONB, is_last_page BOOLEAN)
),
save_rows AS (
  INSERT INTO public.pft_test_patient_assessments
    (pcc_patient_id, facility_mapping_id, page_number, payload, is_last_page)
  SELECT patient_id, facility_mapping_id, page_number, payload, is_last_page
  FROM src
  ON CONFLICT (pcc_patient_id, facility_mapping_id, page_number) DO UPDATE SET
    payload = EXCLUDED.payload,
    is_last_page = EXCLUDED.is_last_page
  RETURNING 1
),
mark_queue AS (
  UPDATE public.pft_test_patient_work_queue q
  SET status = 'done',
      done_at = NOW(),
      worker_id = NULL,
      claimed_at = NULL,
      updated_at = NOW()
  FROM (SELECT DISTINCT patient_id, facility_mapping_id FROM src) s
  WHERE q.execution_id = '{{ execution_id }}'
    AND q.data_type = 'assessments'
    AND q.patient_id = s.patient_id
    AND q.facility_mapping_id = s.facility_mapping_id
  RETURNING 1
),
mark_batch AS (
  UPDATE public.pft_test_work_batch_queue
  SET status = 'done',
      done_at = NOW(),
      worker_id = NULL,
      claimed_at = NULL,
      updated_at = NOW()
  WHERE execution_id = '{{ execution_id }}'
    AND data_type = '{{ iter.data_type }}'
    AND batch_id = {{ iter.batch_id | int }}
  RETURNING 1
)
SELECT (SELECT COUNT(*) FROM save_rows) AS rows_saved,
       (SELECT COUNT(*) FROM mark_queue) AS queue_done,
       (SELECT COUNT(*) FROM mark_batch) AS batch_done;
```

The same pattern exists for conditions, medications, vital signs,
demographics, and MDS.

### 5. Final validation reads real table state

The final check now validates aggregate table state directly. It does not trust
intermediate templated JSON as the source of truth:

```yaml
- step: check_results
  desc: |
    Assert all 10 facilities have 1000/1000 patients with ACTUAL data in result tables.
  tool:
    kind: postgres
    auth: pg_k8s
    command: |
      DO $$
      DECLARE
        failure_count INTEGER;
        facility_count INTEGER;
      BEGIN
        WITH facilities AS (...),
        assessments AS (...),
        conditions AS (...),
        medications AS (...),
        vital_signs AS (...),
        demographics AS (...),
        queue_assessments AS (...),
        mds_expected AS (...),
        mds_done AS (...),
        validation AS (...)
        SELECT COUNT(*), COUNT(*) FILTER (WHERE NOT (...))
        INTO facility_count, failure_count
        FROM validation;

        IF facility_count <> {{ workload.num_facilities | int }} THEN
          RAISE EXCEPTION 'Expected % facilities, got %',
            {{ workload.num_facilities | int }}, facility_count;
        END IF;

        IF failure_count > 0 THEN
          RAISE EXCEPTION 'Patient loss detected in % facility result(s)', failure_count;
        END IF;
      END $$;
```

PR #17 also writes the final aggregate results into
`public.pft_test_validation_log`, so the successful run leaves an auditable
per-facility record.

## Why The Speed Changed So Much

The old execution shape made NoETL orchestrate very small units:

```text
claim one patient
fetch one page
save one page
mark queue state
repeat for next page
repeat for next patient
repeat for each domain
```

The current execution shape makes NoETL orchestrate bounded batches:

```text
claim 25 patients for one data type
fetch all fixture rows for that batch through one HTTP action
save all returned rows through one postgres action
mark patient queue + batch queue done
repeat with 16 slots until empty
```

This reduces:

- NoETL command dispatch count;
- event volume;
- queue claim/update churn;
- HTTP round trips;
- small SQL insert/update statements;
- worker slot time spent waiting on sub-playbook or cursor bookkeeping.

The speedup is therefore expected and structural. It is not just a faster GKE
machine. Local kind was slow because the playbook shape forced a high number of
tiny orchestration steps, and local Podman/kind makes that overhead especially
visible. GKE is faster, but the drastic change came from changing the unit of
work.

## Commit Chain

The relevant e2e commits were:

- `23aa4c6` - reduced cursor fan-out to avoid PgBouncer/Cloud SQL pressure.
- `c14f8d6` - gated validation on MDS completeness.
- `b20bea2` - proved bulk processing could be fast, but used a Python bulk worker.
- `3b7dde6` - replaced the Python bulk worker with action-controlled batch HTTP + postgres flow.
- `ed0acc8` - made batch concurrency catalog-valid with static `max_in_flight: 16`.
- `28121ee` - made final validation read directly from result tables.
- `b0ae122` - wrote final validation rows into `pft_test_validation_log`.

## Remaining Caveat

The current 1m 53s result was measured on GKE. Local kind may still be slower
because Podman, local disk, local CPU allocation, and local PostgreSQL/worker
resources are smaller than the GKE setup. But the current playbook should no
longer have the old 30-minute structural bottleneck because the inner loop is
batch-oriented and action-controlled.

## Local Kind Re-Test After Documentation Commit

After this explanation was first committed, the same current playbook was
deployed and tested on the local `kind-noetl` cluster.

Local deploy state:

- Podman machine: `noetl-dev`
- kind cluster: `kind-noetl`
- NoETL server image: `ghcr.io/noetl/noetl:v2.37.1`
- NoETL worker image: `ghcr.io/noetl/noetl:v2.37.1`
- Fixture server image loaded into kind: `localhost/local/test-server:e2e-6970342`
- Fixture server endpoint checked locally:
  `http://127.0.0.1:32555/api/v1/pft/batch/demographics`

Local catalog/execution:

- Catalog path: `fixtures/playbooks/pft_flow_test/test_pft_flow`
- Local catalog version: `1`
- Execution: `622010462971888356`
- Status: `COMPLETED`
- Started: `2026-05-08T05:03:45.456852Z`
- Finished: `2026-05-08T05:04:39.915434Z`
- Duration: `54.459s` (`54s`)
- Final `check_results`: `passed`

Local table verification was run through a NoETL `postgres` action probe:

- Probe execution: `622011140586864733`
- Facilities: `10`
- Assessments: `10000`
- Conditions: `10000`
- Medications: `10000`
- Vital signs: `10000`
- Demographics: `10000`
- MDS expected: `10000`
- MDS details done: `10000`
- Queue done counts for all five data types: `10000`
- `pft_test_validation_log` rows: `10`
- Per-facility validation-log min/max counts: `1000/1000`
- `actual_tables_pass`: `true`
- `queue_tables_pass`: `true`
- `validation_log_pass`: `true`

This local result removes the earlier caveat for the current environment. The
same local setup that previously exposed 30-minute behavior now completes the
10,000-patient action-controlled playbook in under one minute. The improvement
therefore comes from the playbook execution shape, not merely from GKE being
faster than local kind.

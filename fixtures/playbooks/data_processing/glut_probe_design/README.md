# GLUT Probe Design Data Processing

Tenant project fixture playbooks for GLUT Probe Design.

## Structure Registry

`structure_registry.yaml` registers under:

```text
tenants/glut-probe-design/projects/glut-probe-design/data/structures/registry
```

It runs the tenant project collector at:

```text
/Volumes/X10/projects/noetl/ai-meta/repos/glut-probe-design/scripts/collect_glut_structures.py
```

The playbook writes a metadata index, uploads raw structure artifacts to:

```text
gs://glut-probe-design/data/structures/
```

Then it cleans generated raw PDB files and generated manifests from the tenant
project Git worktree.

Postgres should store metadata, object URIs, checksums, and run state only. Raw
PDB byte content remains in object storage.

## Validation

From `repos/noetl`:

```bash
python scripts/validate_playbooks.py \
  ../e2e/fixtures/playbooks/data_processing/glut_probe_design
```

## Dry Run

Set these workload values for a local inspection run:

```bash
--set upload_to_gcs=false --set cleanup_local_raw=false
```

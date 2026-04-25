---
id: local-kind
title: Local Kind Cluster
---

Use the local `kind-noetl` cluster for distributed e2e runs.

## Health Check

```bash
kubectl config current-context
kubectl get pods --all-namespaces
curl http://localhost:8082/health
```

The NoETL endpoint used by the fixture commands is usually `localhost:8082`.

## Redeploy

When refreshing NoETL images and Kubernetes resources, prefer the ops automation playbook from `repos/ops`:

```bash
cd ../ops
noetl run automation/development/noetl.yaml --runtime local --set action=redeploy --set noetl_repo_dir=../noetl
```

This keeps local validation aligned with project automation defaults.

---
id: deployment
title: Deployment
---

Playbooks in `deployment`.

| Catalog path | Fixture file | Description | Tools |
| --- | --- | --- | --- |
| `deployment/deploy_gateway_kind` | `fixtures/playbooks/deployment/deploy_gateway_kind.yaml` | Build and deploy the Gateway to Kind Kubernetes cluster.  Steps: 1. Check prerequisites (Docker, Kind, kubectl) 2. Validate disk space and auto-cleanup if needed 3. Build Docker image for gateway 4. Load image into Kind cluster 5. Restart gateway deployment 6. Wait for rollout to complete 7. Verify gateway health  Prerequisites: - Docker running - Kind cluster 'noetl' running - kubectl configured for Kind context  | shell |
| `deployment/docker_cleanup` | `fixtures/playbooks/deployment/docker_cleanup.yaml` | Clean up Docker resources to free disk space.  Steps: 1. Show current disk usage 2. Remove unused containers 3. Remove unused images 4. Remove build cache 5. Show freed space  Use with caution - this removes unused Docker resources.  | shell |

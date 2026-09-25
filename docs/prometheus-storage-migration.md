# Prometheus storage migration: read-only preflight

The existing `apps/monitoring.yaml` requests a 10Gi Prometheus PVC from `local-path`. The local-path provisioner is configured for the mergerfs-backed `/mnt/storage`. We want to determine the actual live StatefulSet/PVC/PV identities and mount paths before designing a separate ext4/NVMe Local PV migration.

## 1. Run the inventory on HomeServer

```bash
cd ~/HomeLab/homelab-k8s-infra
git pull --ff-only
bash scripts/prometheus_storage_preflight.sh
```

The script performs only `kubectl get`, `findmnt`, and `df` reads. It prints the monitoring StatefulSets and PVCs, bound PV reclaim policies and backing paths, host mount information, and Argo CD monitoring status. It does not scale workloads, patch claims, create directories, change permissions, or copy data. It does not print Kubernetes Secret values.

Share the output to confirm the existing Prometheus PV and filesystem. Check whether there is one Prometheus replica, whether its PVC is Bound, and whether the intended new directory would be on the NVMe's ext4 filesystem. Verify sufficient free space before choosing PV capacity.

## 2. Migration safety requirements

Do not modify the storage class or `volumeClaimTemplate` of the live bound PVC in place. Avoid a GitOps change to `apps/monitoring.yaml` until the live StatefulSet and volume have been inventoried, and the old PV reclaim policy is set to `Retain` before any deletion. A real move requires planned downtime, a consistent copy or an intentionally fresh TSDB, correct ownership, new static PV/PVC binding, and rollback validation.

If historical monitoring data are disposable, a new empty Prometheus TSDB may be simpler than copying old data, but explicitly choose that option rather than silently losing data. Grafana's separate PVC is not part of this migration. Changes to Prometheus storage must not touch the Immich library or PostgreSQL volumes.

## 3. Why this is a separate PR

This PR adds diagnostic tooling and guidance only. A later implementation PR should be based on the preflight output; it must contain exact verified resource names, safe synchronization sequencing, and a rollback plan. No live deployment or disk changes occur when this diagnostic PR is merged.

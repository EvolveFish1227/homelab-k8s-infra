# Prometheus storage migration: staged NVMe preparation

The live inventory was collected on 2026-09-25. **This PR stages only a new StorageClass and an unclaimed Local PV; it does not migrate the database or change the Helm chart.**

## Verified source and destination

| Resource | Current state |
| --- | --- |
| Prometheus CR | `monitoring/kube-prometheus-stack-prometheus`, 1 replica, 10d retention |
| StatefulSet | `monitoring/prometheus-kube-prometheus-stack-prometheus`, 1/1 ready |
| Existing PVC | `prometheus-kube-prometheus-stack-prometheus-db-prometheus-kube-prometheus-stack-prometheus-0`, 10Gi, `local-path` |
| Existing PV | `pvc-48745d94-d2f2-4903-aba8-b046376fafb3`, **Delete** reclaim policy at preflight |
| Existing data directory | `/mnt/storage/pvc-48745d94-d2f2-4903-aba8-b046376fafb3_monitoring_prometheus-kube-prometheus-stack-prometheus-db-prometheus-kube-prometheus-stack-prometheus-0` |
| New destination | `/srv/prometheus` on root ext4/NVMe |
| Staged new resources | StorageClass `prometheus-direct`; Local PV `prometheus-direct-pv` (20Gi, Retain) |
| Grafana PVC | `kube-prometheus-stack-grafana`; **out of scope**, leave on existing HDD |

The recorded root ext4 filesystem had approximately 379G free at preflight. Verify space again immediately before any copy. The local PV capacity is a Kubernetes declaration; it is **not** a 20Gi filesystem quota on the NVMe.

## Phase 1: safe preparation (this PR)

The root Argo CD Application discovers `apps/prometheus-storage.yaml` and will create the unused StorageClass and PV after merge. The existing Prometheus Application, StatefulSet, PVC, and chart values remain unchanged. The new PV has `Retain` and Argo CD `Prune=false,Delete=false` protection.

On HomeServer, verify the node's **Kubernetes hostname label**, not just the OS hostname:

```bash
kubectl get nodes -L kubernetes.io/hostname
findmnt -T /srv -o TARGET,SOURCE,FSTYPE
df -hT /srv
```

The new PV's node affinity is `homeserver`, matching the existing Immich NVMe Local PV. If the actual Kubernetes hostname label differs, do **not** begin cutover; correct the PV manifest first.

Protect the *existing dynamically provisioned* PV **before any PVC deletion**. Its original reclaim policy is `Delete`, and the local-path teardown helper recursively removes a released volume directory under that policy. Check the bound PV identity again before changing anything:

```bash
OLD_PVC=prometheus-kube-prometheus-stack-prometheus-db-prometheus-kube-prometheus-stack-prometheus-0
OLD_PV=pvc-48745d94-d2f2-4903-aba8-b046376fafb3
ACTUAL_PV="$(kubectl -n monitoring get pvc "$OLD_PVC" -o jsonpath='{.spec.volumeName}')"
test "$ACTUAL_PV" = "$OLD_PV" || { echo "PV changed; stop and re-inventory"; exit 1; }
kubectl patch pv "$OLD_PV" --type merge \
  -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'
kubectl get pv "$OLD_PV" -o jsonpath='{.spec.persistentVolumeReclaimPolicy}{"\n"}'
```

Expected: `Retain`. This operation does **not** delete, detach, or move the existing PVC/data. Keep the old directory/PV throughout the migration and rollback period.

Prepare a **new empty** directory on the NVMe (do not put this under `/mnt/storage`). The actual Prometheus data ownership will be preserved during the later offline copy:

```bash
test "$(findmnt -n -T /srv -o FSTYPE)" = ext4 || { echo "Destination not ext4"; exit 1; }
sudo install -d -m 0750 /srv/prometheus
```

After merging this PR, verify that Argo CD created only the staged resources:

```bash
kubectl get storageclass prometheus-direct
kubectl get pv prometheus-direct-pv \
  -o custom-columns=NAME:.metadata.name,STATUS:.status.phase,CLASS:.spec.storageClassName,RECLAIM:.spec.persistentVolumeReclaimPolicy,PATH:.spec.local.path
```

Expected new PV: `Available` (no claim yet), `prometheus-direct`, `Retain`, `/srv/prometheus`. An unused PV does **not** move any live data.

Also collect these **read-only** details for the cutover plan:

```bash
kubectl -n monitoring get statefulset prometheus-kube-prometheus-stack-prometheus \
  -o jsonpath='{.spec.volumeClaimTemplates[0].metadata.name}{"\n"}{.spec.template.spec.securityContext}{"\n"}{.spec.persistentVolumeClaimRetentionPolicy}{"\n"}'
sudo du -sh /mnt/storage/pvc-48745d94-d2f2-4903-aba8-b046376fafb3_monitoring_prometheus-kube-prometheus-stack-prometheus-db-prometheus-kube-prometheus-stack-prometheus-0
```

**STOP HERE. Do not delete either PVC or PV, do not change the monitoring Helm chart, and do not point a second running Prometheus at either data directory.** Share the final command output for a separate cutover PR and planned maintenance window.

## Phase 2: planned cutover (NOT performed by this PR)

To preserve the ten days of existing metrics, the eventual runbook must coordinate both Argo CD Applications (root and monitoring) and the Prometheus Operator so that they cannot immediately undo a manual stop. It will stop the single Prometheus replica cleanly, wait for the Pod to terminate, copy the offline TSDB (including WAL/head files) to `/srv/prometheus` with ownership preserved, validate the copy, and prepare the replacement pre-bound PVC. The replacement PVC has to use the **same StatefulSet ordinal claim name**, refer explicitly to `prometheus-direct-pv`, and match the new `prometheus-direct` class. The Helm chart's `volumeClaimTemplate` must be updated in coordination with the operator's StatefulSet recreation because that field is immutable on an existing StatefulSet.

The old PV must remain Retain and the old directory must remain intact until Prometheus is healthy on the new volume and its TSDB queries are validated. Restore GitOps reconciliation only after the new claim and StatefulSet have been checked. Explicitly confirm whether historical metrics are to be preserved; if they are disposable, a fresh empty TSDB is a different and shorter migration plan.

Prometheus TSDB contains WAL and head data; copying it while Prometheus writes is not a consistent offline migration. Grafana, Alertmanager, and the Immich photo library/PostgreSQL volumes are outside scope.

## Phase 3: rollback and cleanup

If the new TSDB fails to start, stop the new Prometheus before considering rollback, preserve its data for diagnosis, and reattach the retained **old** volume using its known claim mapping. Do not delete either old data directory or old PV until rollback has been explicitly retired. Reclaiming a Retain PV for another PVC requires deliberate release/rebinding; never assume an old Released PV will bind automatically.

A future PR may add actual cutover commands only after reviewing the live state collected in Phase 1. This stage-one PR deliberately contains no destructive steps or changes to running workloads.

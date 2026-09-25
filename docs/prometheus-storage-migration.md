# Prometheus NVMe cutover: maintenance runbook

**Do not merge the cutover PR just to stage it.** The root Argo CD Application auto-syncs files in `apps/`. This PR introduces a replacement PVC with the **same name** as the currently bound claim, and changes the Prometheus Helm claim template. Merging it while the old Prometheus is running can cause a failed or partially reconciled migration. First complete the maintenance steps below and merge only at the explicit checkpoint.

The preflight output was supplied on 2026-09-25. It confirms the old TSDB contains approximately **2.9G** of data; the StatefulSet is one replica; container user/group are `1000:2000`, with `fsGroup: 2000`; and StatefulSet claim retention is `Retain` on both scale and deletion. **StatefulSet claim retention is separate from PV reclaim policy**. Verify the PV itself is `Retain` before deleting the claim.

## Verified resource names

| Item | Value |
| --- | --- |
| Prometheus resource | `monitoring/kube-prometheus-stack-prometheus` |
| StatefulSet | `monitoring/prometheus-kube-prometheus-stack-prometheus` |
| Ordinal-0 PVC (old and replacement name) | `prometheus-kube-prometheus-stack-prometheus-db-prometheus-kube-prometheus-stack-prometheus-0` |
| Old PV | `pvc-48745d94-d2f2-4903-aba8-b046376fafb3` |
| Source directory on physical HDD | `/mnt/disk1/pvc-48745d94-d2f2-4903-aba8-b046376fafb3_monitoring_prometheus-kube-prometheus-stack-prometheus-db-prometheus-kube-prometheus-stack-prometheus-0` |
| Staged new PV | `prometheus-direct-pv`, `20Gi`, `Retain` |
| Target directory | `/srv/prometheus` on NVMe ext4 |
| StorageClass | `prometheus-direct` |

Grafana's `kube-prometheus-stack-grafana` PVC and the Immich volumes are **out of scope**.

## 0. Confirm stage 1 and old-volume protection

Run on HomeServer. All checks must pass before proceeding:

```bash
cd ~/HomeLab/homelab-k8s-infra
OLD_PVC=prometheus-kube-prometheus-stack-prometheus-db-prometheus-kube-prometheus-stack-prometheus-0
OLD_PV=pvc-48745d94-d2f2-4903-aba8-b046376fafb3
NEW_PV=prometheus-direct-pv
SRC=/mnt/disk1/pvc-48745d94-d2f2-4903-aba8-b046376fafb3_monitoring_prometheus-kube-prometheus-stack-prometheus-db-prometheus-kube-prometheus-stack-prometheus-0
DST=/srv/prometheus

test "$(kubectl -n monitoring get pvc "$OLD_PVC" -o jsonpath='{.spec.volumeName}')" = "$OLD_PV" || { echo "Old claim changed; STOP"; exit 1; }
test "$(kubectl get pv "$OLD_PV" -o jsonpath='{.spec.persistentVolumeReclaimPolicy}')" = Retain || { echo "Old PV is NOT Retain; STOP"; exit 1; }
test "$(kubectl get pv "$NEW_PV" -o jsonpath='{.status.phase}')" = Available || { echo "New PV not Available; STOP"; exit 1; }
test "$(kubectl get pv "$NEW_PV" -o jsonpath='{.spec.local.path}')" = "$DST" || { echo "New PV path changed; STOP"; exit 1; }
test "$(kubectl get pv "$NEW_PV" -o jsonpath='{.spec.persistentVolumeReclaimPolicy}')" = Retain || { echo "New PV not Retain; STOP"; exit 1; }
test "$(kubectl get node homeserver -o jsonpath='{.metadata.labels.kubernetes\.io/hostname}')" = homeserver || { echo "Node label mismatch; STOP"; exit 1; }
test "$(findmnt -n -M /mnt/disk1 -o FSTYPE)" = ext4 || { echo "HDD not mounted as ext4; STOP"; exit 1; }
test "$(findmnt -n -T /srv -o FSTYPE)" = ext4 || { echo "NVMe target not ext4; STOP"; exit 1; }
sudo test -d "$SRC" || { echo "Original TSDB missing; STOP"; exit 1; }
sudo test -d "$DST" || { echo "New directory missing; STOP"; exit 1; }
test -z "$(sudo find "$DST" -mindepth 1 -maxdepth 1 -print -quit)" || { echo "New directory not empty; STOP"; exit 1; }

kubectl -n monitoring get pvc "$OLD_PVC"
kubectl get pv "$OLD_PV" "$NEW_PV"
df -hT /srv
```

If the old PV is still `Delete`, STOP and perform the guarded `Retain` patch documented in the stage-one PR before any further step. Verify that the new PV is `Available` and the new directory is genuinely empty. Do not format any filesystem or modify the Immich PV.

Before downtime, confirm a recent working Immich database backup separately; this migration should never touch it.

## 1. Pause BOTH Argo CD Applications before editing live resources

The root App manages `apps/monitoring.yaml`. Disabling only the child App is insufficient: its parent may reapply the child Application and reenable automated sync. Temporarily remove automatic sync from the root **first**, then from the monitoring child:

```bash
kubectl -n argocd patch application root-application --type=json \
  -p='[{"op":"remove","path":"/spec/syncPolicy/automated"}]'
kubectl -n argocd patch application kube-prometheus-stack --type=json \
  -p='[{"op":"remove","path":"/spec/syncPolicy/automated"}]'

kubectl -n argocd get application root-application \
  -o jsonpath='{.spec.syncPolicy.automated}{"\n"}'
kubectl -n argocd get application kube-prometheus-stack \
  -o jsonpath='{.spec.syncPolicy.automated}{"\n"}'
```

Both final commands must print an empty line. If either is still automated, STOP. Do not manually sync either Application during downtime. These commands do not edit Git; they temporarily suspend automatic sync until restored below.

## 2. Stop Prometheus cleanly, then take the offline copy

```bash
kubectl -n monitoring patch prometheus kube-prometheus-stack-prometheus \
  --type=merge -p '{"spec":{"paused":true}}'
test "$(kubectl -n monitoring get prometheus kube-prometheus-stack-prometheus -o jsonpath='{.spec.paused}')" = true || { echo "Operator not paused; STOP"; exit 1; }

kubectl -n monitoring scale statefulset/prometheus-kube-prometheus-stack-prometheus --replicas=0
kubectl -n monitoring rollout status statefulset/prometheus-kube-prometheus-stack-prometheus --timeout=5m
kubectl -n monitoring get pods
```

**Do not copy until the `prometheus-kube-prometheus-stack-prometheus-0` Pod is fully absent.** If the pod still exists or recreates, STOP; the Prometheus Operator or Argo CD may still be reconciling.

With the pod stopped, copy the complete TSDB, including WAL/head data, directly from the HDD filesystem (not through mergerfs):

```bash
sudo rsync -aHAX --numeric-ids --info=progress2 "$SRC"/ "$DST"/
sudo rsync -aHAX --numeric-ids --checksum --delete --dry-run --itemize-changes "$SRC"/ "$DST"/
sudo stat -c '%u:%g %a %n' "$SRC" "$DST"
sudo du -sh "$SRC" "$DST"
```

The checksum dry run should report no differences. Inspect ownership; the Prometheus process runs as UID `1000` / GID `2000` and has `fsGroup 2000`. Do not proceed if the copy is incomplete or permissions are wrong. The old source remains untouched.

## 3. Remove the OLD controller and claim, retaining the original HDD data

Keep the Prometheus CR paused and both Argo CD Applications' automated sync off. Repeat these checks immediately before deletion:

```bash
test "$(kubectl get pv "$OLD_PV" -o jsonpath='{.spec.persistentVolumeReclaimPolicy}')" = Retain || { echo "Old PV not Retain; STOP"; exit 1; }
test "$(kubectl -n monitoring get pvc "$OLD_PVC" -o jsonpath='{.spec.volumeName}')" = "$OLD_PV" || { echo "Old claim changed; STOP"; exit 1; }
test "$(kubectl -n monitoring get prometheus kube-prometheus-stack-prometheus -o jsonpath='{.spec.paused}')" = true || { echo "Operator not paused; STOP"; exit 1; }
kubectl -n monitoring get pod prometheus-kube-prometheus-stack-prometheus-0
```

The final command must return `NotFound`. If it returns a Pod, STOP.

```bash
kubectl -n monitoring delete statefulset prometheus-kube-prometheus-stack-prometheus --cascade=orphan
kubectl -n monitoring delete pvc "$OLD_PVC" --wait=true
kubectl get pv "$OLD_PV"
sudo test -d "$SRC" && echo "Original HDD data still present"
```

The old PV should be `Released`, with `Retain` reclaim policy. If the PV disappears or the directory is missing, STOP and investigate. **Never delete the old PV or data directory as part of this migration.**

## 4. Merge the cutover PR ONLY NOW and bind the replacement PVC

The root and child Argo CD Applications must still have automated sync disabled. Merge this PR, then pull the updated repository on HomeServer:

```bash
git switch main
git pull --ff-only
kubectl apply -f apps/prometheus-direct-pvc.yaml
kubectl -n monitoring get pvc "$OLD_PVC" -o wide
kubectl get pv "$NEW_PV"
```

Verify that the replacement claim is `Bound` to `prometheus-direct-pv`, with class `prometheus-direct` and request `20Gi`. If not, STOP; do not unpause the operator.

## 5. Update the Prometheus CR while paused and resume it

The Prometheus Operator creates the StatefulSet from the Prometheus CR, not directly from the local Git file. Since the old StatefulSet has been deleted, it can now create the replacement with the new immutable claim template. See the upstream operator's storage-change guidance.

```bash
kubectl -n monitoring patch prometheus kube-prometheus-stack-prometheus \
  --type=merge \
  -p '{"spec":{"storage":{"volumeClaimTemplate":{"spec":{"storageClassName":"prometheus-direct","resources":{"requests":{"storage":"20Gi"}}}}}}}'

kubectl -n monitoring get prometheus kube-prometheus-stack-prometheus \
  -o jsonpath='{.spec.storage.volumeClaimTemplate.spec.storageClassName}{" "}{.spec.storage.volumeClaimTemplate.spec.resources.requests.storage}{" "}{.spec.paused}{"\n"}'
```

Expected: `prometheus-direct 20Gi true`. Only then:

```bash
kubectl -n monitoring patch prometheus kube-prometheus-stack-prometheus \
  --type=merge -p '{"spec":{"paused":false}}'
kubectl -n monitoring rollout status statefulset/prometheus-kube-prometheus-stack-prometheus --timeout=10m
kubectl -n monitoring get pvc "$OLD_PVC" -o wide
kubectl -n monitoring get statefulset prometheus-kube-prometheus-stack-prometheus \
  -o jsonpath='{.spec.volumeClaimTemplates[0].spec.storageClassName}{" "}{.spec.volumeClaimTemplates[0].spec.resources.requests.storage}{"\n"}'
```

Expected: one healthy Prometheus replica, replacement PVC bound to `prometheus-direct-pv`, and StatefulSet claim template `prometheus-direct 20Gi`. Check Grafana Prometheus data source and query some historical metrics from before the copy. Do not reenable GitOps until the TSDB and claim mapping have been validated.

## 6. Resume GitOps using the merged desired state

The merged `apps/monitoring.yaml` specifies `prometheus-direct` and `20Gi`, while `apps/prometheus-direct-pvc.yaml` declares the exact prebound claim. Reenable the root Application so it reconciles both resources and the child Application:

```bash
kubectl -n argocd patch application root-application --type=merge \
  -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
kubectl -n argocd get application root-application kube-prometheus-stack \
  -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status
```

Wait for both to become `Synced` and `Healthy`. Verify the child Application has its original automated policy restored by the root's sync; if it remains absent, confirm the root is synced to the merged revision and then restore the child using the same merge-patch policy. Do not leave both Applications paused indefinitely.

Recheck both old/new PVs and the full metric history before retiring rollback. Keep the old HDD directory and old Retain PV for a separate, later cleanup decision.

## Rollback / STOP conditions

If a check fails **before deleting the old PVC**, keep the old volume and undo temporary pauses; do not merge this PR.

If a failure occurs **after deleting the old PVC**, leave both Argo CD Applications paused and the Prometheus CR paused. Preserve the copied NVMe TSDB. The retained HDD PV is `Released` and still has the old claimRef UID: rebinding it requires deliberate removal of that stale claimRef and creation of a prebound PVC with the old `local-path` class and original claim name. Restore the old Prometheus CR storage template and recreate its StatefulSet via the operator. Revert the GitOps cutover change before resuming automatic sync; otherwise GitOps will try to reapply the new mapping. Do not improvise PVC/PV deletions. Ask for a state-specific rollback command sequence if you hit this point.

Neither this procedure nor the staged PV protects against NVMe failure without backups. Prometheus metrics are separate from Immich; avoid touching Immich or Grafana storage.

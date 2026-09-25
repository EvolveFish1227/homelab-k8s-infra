#!/usr/bin/env bash
# Read-only Prometheus storage inventory. Does not change Kubernetes or host data.
set -Eeuo pipefail

for tool in kubectl findmnt df; do
  command -v "$tool" >/dev/null 2>&1 || {
    printf 'Missing required command: %s\n' "$tool" >&2
    exit 1
  }
done

echo '=== Kubernetes context and host ==='
kubectl config current-context
hostname

echo '=== Prometheus custom resource (if installed) ==='
kubectl -n monitoring get prometheuses.monitoring.coreos.com \
  -o custom-columns=NAME:.metadata.name,REPLICAS:.spec.replicas,RETENTION:.spec.retention \
  || true

echo '=== Monitoring StatefulSets ==='
kubectl -n monitoring get statefulsets \
  -o custom-columns=NAME:.metadata.name,REPLICAS:.spec.replicas,READY:.status.readyReplicas

echo '=== Monitoring PVCs ==='
kubectl -n monitoring get pvc \
  -o custom-columns=NAME:.metadata.name,STATUS:.status.phase,VOLUME:.spec.volumeName,CLASS:.spec.storageClassName,REQUEST:.spec.resources.requests.storage

echo '=== Bound monitoring PV details ==='
while IFS=$'\t' read -r pvc_name pv_name; do
  [[ -n "$pv_name" ]] || continue
  echo "--- PVC: $pvc_name / PV: $pv_name"
  kubectl get pv "$pv_name" \
    -o custom-columns=NAME:.metadata.name,RECLAIM:.spec.persistentVolumeReclaimPolicy,CLASS:.spec.storageClassName,CAPACITY:.spec.capacity.storage,STATUS:.status.phase --no-headers
  host_path="$(kubectl get pv "$pv_name" -o jsonpath='{.spec.hostPath.path}')"
  local_path="$(kubectl get pv "$pv_name" -o jsonpath='{.spec.local.path}')"
  echo "hostPath: ${host_path:-<none>}"
  echo "local.path: ${local_path:-<none>}"
  path="${host_path:-$local_path}"
  if [[ -n "$path" && -e "$path" ]]; then
    findmnt -T "$path" -o TARGET,SOURCE,FSTYPE
  fi
done < <(kubectl -n monitoring get pvc -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.volumeName}{"\n"}{end}')

echo '=== Host mounts and available space ==='
findmnt -M /mnt/disk1 -o TARGET,SOURCE,FSTYPE || true
findmnt -M /mnt/storage -o TARGET,SOURCE,FSTYPE || true
findmnt -T /srv -o TARGET,SOURCE,FSTYPE
df -hT /srv /mnt/disk1 /mnt/storage

echo '=== Argo CD monitoring Application state ==='
kubectl -n argocd get application kube-prometheus-stack \
  -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status \
  || true

echo 'Preflight completed. No resource or filesystem was changed.'

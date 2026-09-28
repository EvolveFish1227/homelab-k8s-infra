#!/usr/bin/env bash
# Capture non-secret host metadata needed to rebuild HomeServer after root-NVMe loss.
# This is not a k3s datastore, application-data, or media backup.
set -Eeuo pipefail
umask 077

MOUNT=/mnt/disk1
BACKUP_ROOT="$MOUNT/homelab-backups/host"
KEEP_COUNT=8
K3S_ENCRYPTION_DROPIN=/etc/rancher/k3s/config.yaml.d/20-secrets-encryption.yaml

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

staging=""

cleanup() {
  rc=$?
  if [[ -n "$staging" && -d "$staging" ]]; then
    rm -rf -- "$staging"
  fi
  exit "$rc"
}
trap cleanup EXIT

[[ "$EUID" -eq 0 ]] || fail "Run this snapshot as root"

for tool in findmnt lsblk hostnamectl k3s systemctl install flock find sort sha256sum python3 ip stat grep cp date awk chmod rm mv; do
  command -v "$tool" >/dev/null 2>&1 || fail "Missing required command: $tool"
done

# Never mistake an unmounted /mnt/disk1 directory on the NVMe for the backup HDD.
[[ "$(findmnt -n -M "$MOUNT" -o FSTYPE)" == "ext4" ]] \
  || fail "$MOUNT is not an ext4 mount. Check the physical HDD before writing a host snapshot."
source_device="$(findmnt -n -M "$MOUNT" -o SOURCE)"
[[ -n "$source_device" ]] || fail "Cannot determine the HDD source device"

# fstab is useful during recovery, but refuse to copy obvious inline/network credentials.
# If this trips in the future, move credentials to a protected external file and review
# the recovery design instead of silently archiving them here.
if grep -Eiq '(^|[[:space:],])(password|passwd|credentials|username)=' /etc/fstab; then
  fail "/etc/fstab appears to contain credential-bearing mount options; refusing to archive it"
fi

# The only k3s config copied by this script is the non-secret encryption enablement
# drop-in. Do not broaden this to copy arbitrary files from /etc/rancher/k3s.
[[ -f "$K3S_ENCRYPTION_DROPIN" ]] \
  || fail "Missing expected k3s encryption drop-in: $K3S_ENCRYPTION_DROPIN"

non_comment_lines="$(awk 'NF && $1 !~ /^#/ {count++} END {print count+0}' "$K3S_ENCRYPTION_DROPIN")"
[[ "$non_comment_lines" -eq 1 ]] \
  || fail "$K3S_ENCRYPTION_DROPIN contains unexpected additional settings; review manually"
grep -Eq '^[[:space:]]*secrets-encryption:[[:space:]]*true[[:space:]]*$' "$K3S_ENCRYPTION_DROPIN" \
  || fail "$K3S_ENCRYPTION_DROPIN does not contain the expected secrets-encryption: true setting"

install -d -m 700 "$BACKUP_ROOT"
exec 9>"$BACKUP_ROOT/.backup.lock"
flock -n 9 || fail "Another host recovery snapshot is running"

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
staging="$BACKUP_ROOT/.incomplete-$timestamp"
final="$BACKUP_ROOT/$timestamp"
[[ ! -e "$final" ]] || fail "Snapshot directory already exists: $final"
install -d -m 700 "$staging/k3s-config"

hostnamectl --static >"$staging/hostname.txt"
k3s --version >"$staging/k3s-version.txt"
uname -a >"$staging/kernel.txt"
cp -- /etc/os-release "$staging/os-release"
cp -- /etc/fstab "$staging/fstab"

lsblk -o NAME,PATH,SIZE,FSTYPE,FSVER,LABEL,UUID,PARTUUID,MOUNTPOINTS,MODEL \
  >"$staging/lsblk.txt"
findmnt -r -o TARGET,SOURCE,FSTYPE,OPTIONS >"$staging/findmnt.txt"

{
  printf 'Backup target: %s\n' "$source_device"
  printf '\nPersistent-path metadata (numeric uid/gid):\n'
  for path in /mnt/disk1 /mnt/storage /srv/immich-postgres /srv/prometheus; do
    printf '\n=== %s ===\n' "$path"
    if [[ -e "$path" ]]; then
      stat -c 'mode=%a uid=%u gid=%g type=%F path=%n' "$path"
      findmnt -T "$path" -o TARGET,SOURCE,FSTYPE,OPTIONS || true
    else
      printf 'MISSING\n'
    fi
  done
} >"$staging/storage-paths.txt"

{
  ip -brief address
  printf '\nRoutes:\n'
  ip route
} >"$staging/network.txt"

if command -v resolvectl >/dev/null 2>&1; then
  resolvectl status >"$staging/dns.txt" || true
fi

systemctl show k3s -p FragmentPath -p LoadState -p UnitFileState \
  >"$staging/k3s-service.txt"

cp -- "$K3S_ENCRYPTION_DROPIN" "$staging/k3s-config/20-secrets-encryption.yaml"
k3s secrets-encrypt status >"$staging/k3s-secrets-encryption-status.txt"

# Record only a whitelisted, non-secret subset of the running k3s server arguments.
# Token, datastore endpoint, kubeconfig, credential, and arbitrary environment values
# are intentionally never captured.
python3 - <<'PY' >"$staging/k3s-runtime-args.txt"
import subprocess

pid = subprocess.check_output(
    ["systemctl", "show", "k3s", "-p", "MainPID", "--value"],
    text=True,
).strip()
if not pid or pid == "0":
    raise SystemExit("k3s has no running MainPID")

args = [
    part.decode(errors="replace")
    for part in open(f"/proc/{pid}/cmdline", "rb").read().split(b"\0")
    if part
]

value_flags = {
    "--disable",
    "--data-dir",
    "--secrets-encryption-provider",
    "--cluster-cidr",
    "--service-cidr",
    "--cluster-dns",
    "--cluster-domain",
    "--flannel-backend",
    "--node-name",
    "--node-ip",
    "--node-external-ip",
    "--tls-san",
    "--write-kubeconfig-mode",
}
flag_only = {
    "--secrets-encryption",
    "--cluster-init",
    "--disable-network-policy",
    "--disable-kube-proxy",
    "--disable-helm-controller",
}

safe = []
i = 0
while i < len(args):
    token = args[i]
    if token == "server":
        safe.append(token)
    elif token in flag_only:
        safe.append(token)
    elif any(token.startswith(flag + "=") for flag in flag_only):
        safe.append(token)
    elif token in value_flags:
        if i + 1 < len(args):
            safe.extend([token, args[i + 1]])
            i += 1
    else:
        for flag in value_flags:
            if token.startswith(flag + "="):
                safe.append(token)
                break
    i += 1

print(" ".join(safe))
PY

# Kubernetes storage identity is useful during recovery and does not contain Secret data.
if KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl get nodes >/dev/null 2>&1; then
  KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl get nodes -o wide \
    >"$staging/kubernetes-nodes.txt"
  KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl get pv \
    -o custom-columns='NAME:.metadata.name,CAPACITY:.spec.capacity.storage,RECLAIM:.spec.persistentVolumeReclaimPolicy,STORAGECLASS:.spec.storageClassName,CLAIM:.spec.claimRef.namespace/.spec.claimRef.name,LOCAL:.spec.local.path,HOSTPATH:.spec.hostPath.path' \
    >"$staging/kubernetes-pv.txt"
  KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl get pvc -A \
    -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,STATUS:.status.phase,VOLUME:.spec.volumeName,STORAGECLASS:.spec.storageClassName,CAPACITY:.status.capacity.storage' \
    >"$staging/kubernetes-pvc.txt"
fi

# Restrict the snapshot, then checksum every captured file.
find "$staging" -type d -exec chmod 700 {} +
find "$staging" -type f -exec chmod 600 {} +
(
  cd "$staging"
  while IFS= read -r -d '' file; do
    sha256sum "${file#./}"
  done < <(find . -type f ! -name SHA256SUMS -print0 | sort -z)
) >"$staging/SHA256SUMS"
chmod 600 "$staging/SHA256SUMS"

mv -- "$staging" "$final"
staging=""

mapfile -t snapshots < <(
  find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d \
    -name '????????T??????Z' -printf '%f\n' | sort
)
while (( ${#snapshots[@]} > KEEP_COUNT )); do
  oldest="${snapshots[0]}"
  echo "Pruning old host recovery snapshot: $oldest"
  rm -rf -- "$BACKUP_ROOT/$oldest"
  snapshots=("${snapshots[@]:1}")
done

echo "Host recovery snapshot completed: $final"
echo "Retention: latest $KEEP_COUNT snapshots."
echo "This bundle intentionally excludes Kubernetes Secrets, kubeconfig, k3s server token, and encryption key material."

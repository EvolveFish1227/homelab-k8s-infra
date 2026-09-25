#!/usr/bin/env bash
# Online PostgreSQL 18 backup from the live Immich pod to the mounted HDD.
# Does not stop, alter, restore, or delete any database or Kubernetes resource.
set -Eeuo pipefail
umask 077

MOUNT=/mnt/disk1
BACKUP_DIR="$MOUNT/homelab-backups/postgres"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
cleanup() {
  if [[ -n "${tmp:-}" ]]; then rm -f -- "$tmp"; fi
  if [[ -n "${checksum_tmp:-}" ]]; then rm -f -- "$checksum_tmp"; fi
}
trap cleanup EXIT

for tool in kubectl findmnt mktemp flock sha256sum; do
  command -v "$tool" >/dev/null 2>&1 || fail "Missing required command: $tool"
done

# An unmounted /mnt/disk1 is an ordinary directory on the NVMe; never write there.
[[ "$(findmnt -n -M "$MOUNT" -o FSTYPE)" == "ext4" ]] \
  || fail "$MOUNT is not an ext4 mount. Check the physical HDD before backing up."
source_device="$(findmnt -n -M "$MOUNT" -o SOURCE)"
[[ -n "$source_device" ]] || fail "Cannot determine the HDD source device"

[[ ! -L "$MOUNT/homelab-backups" ]] || fail "Refusing symlinked backup parent"
[[ ! -L "$BACKUP_DIR" ]] || fail "Refusing symlinked backup directory"
mkdir -p -m 700 -- "$BACKUP_DIR"
chmod 700 -- "$BACKUP_DIR"

# Prevent overlap between a manual invocation and the optional daily timer.
exec 9>"$BACKUP_DIR/.backup.lock"
flock -n 9 || fail "Another Immich PostgreSQL backup is running"

phase="$(kubectl -n immich get pvc immich-postgres-direct-pvc \
  -o jsonpath='{.status.phase}')"
[[ "$phase" == "Bound" ]] || fail "Immich PostgreSQL PVC is not Bound ($phase)"
kubectl -n immich rollout status deployment/immich-postgresql --timeout=90s >/dev/null

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
final="$BACKUP_DIR/immich-$timestamp.dump"
checksum="$final.sha256"
[[ ! -e "$final" && ! -e "$checksum" ]] || fail "Backup filename already exists: $final"

tmp="$(mktemp "$BACKUP_DIR/.immich-XXXXXXXX")"
checksum_tmp="$(mktemp "$BACKUP_DIR/.checksum-XXXXXXXX")"

echo "Backing up Immich PostgreSQL to $BACKUP_DIR (HDD $source_device)"
# No TTY: preserve binary pg_dump custom-format output exactly.
kubectl -n immich exec deployment/immich-postgresql -- \
  pg_dump --username=immich --dbname=immich --format=custom >"$tmp"

[[ -s "$tmp" ]] || fail "pg_dump produced an empty archive"

# pg_restore runs inside the matching PostgreSQL 18 image. This reads and
# decompresses the archive but does not connect to, or modify, a database.
kubectl -n immich exec -i deployment/immich-postgresql -- \
  pg_restore --file=/dev/null <"$tmp" \
  || fail "pg_restore could not read the entire archive; not publishing backup"

digest="$(sha256sum "$tmp" | cut -d ' ' -f 1)"
printf '%s  %s\n' "$digest" "$(basename "$final")" >"$checksum_tmp"
mv -- "$tmp" "$final"
tmp=""
mv -- "$checksum_tmp" "$checksum"
checksum_tmp=""
chmod 600 -- "$final" "$checksum"
(cd "$BACKUP_DIR" && sha256sum --check -- "$(basename "$checksum")")

echo "Backup completed: $final"
echo "No backups were deleted. This does NOT back up the photo library."

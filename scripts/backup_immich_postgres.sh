#!/usr/bin/env bash
# Online PostgreSQL 18 backup from the live Immich pod to the mounted HDD.
# Publishes only validated archives, then applies bounded retention.
set -Eeuo pipefail
umask 077

MOUNT=/mnt/disk1
BACKUP_DIR="$MOUNT/homelab-backups/postgres"
KEEP_COUNT=14
MAX_BACKUP_BYTES=$((100 * 1024 * 1024 * 1024))
MIN_FREE_BYTES=$((100 * 1024 * 1024 * 1024))

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

cleanup() {
  if [[ -n "${tmp:-}" ]]; then rm -f -- "$tmp"; fi
  if [[ -n "${checksum_tmp:-}" ]]; then rm -f -- "$checksum_tmp"; fi
}
trap cleanup EXIT

for tool in kubectl findmnt mktemp flock sha256sum df du find sort awk; do
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

# Prevent overlap between a manual invocation and the daily timer.
exec 9>"$BACKUP_DIR/.backup.lock"
flock -n 9 || fail "Another Immich PostgreSQL backup is running"

available_bytes="$(df -B1 --output=avail "$MOUNT" | awk 'NR==2 {print $1}')"
[[ "$available_bytes" =~ ^[0-9]+$ ]] || fail "Could not determine free space on $MOUNT"
(( available_bytes >= MIN_FREE_BYTES )) \
  || fail "$MOUNT has less than 100 GiB free; refusing to start a new database backup"

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
kubectl -n immich exec deployment/immich-postgresql -- \
  pg_dump --username=immich --dbname=immich --format=custom >"$tmp"

[[ -s "$tmp" ]] || fail "pg_dump produced an empty archive"

# Read/decompress the entire custom archive without modifying any database.
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

# Retention runs only after the new backup has been fully validated and published.
mapfile -t dumps < <(
  find "$BACKUP_DIR" -maxdepth 1 -type f -name 'immich-*.dump' -printf '%f\n' | sort
)

while (( ${#dumps[@]} > KEEP_COUNT )); do
  oldest="${dumps[0]}"
  echo "Pruning old PostgreSQL backup: $oldest"
  rm -f -- "$BACKUP_DIR/$oldest" "$BACKUP_DIR/$oldest.sha256"
  dumps=("${dumps[@]:1}")
done

while (( ${#dumps[@]} > 1 )); do
  backup_bytes="$(du -sb "$BACKUP_DIR" | awk '{print $1}')"
  (( backup_bytes <= MAX_BACKUP_BYTES )) && break
  oldest="${dumps[0]}"
  echo "Pruning old PostgreSQL backup to keep directory under 100 GiB: $oldest"
  rm -f -- "$BACKUP_DIR/$oldest" "$BACKUP_DIR/$oldest.sha256"
  dumps=("${dumps[@]:1}")
done

backup_bytes="$(du -sb "$BACKUP_DIR" | awk '{print $1}')"
if (( backup_bytes > MAX_BACKUP_BYTES )); then
  echo "WARNING: newest backup alone leaves $BACKUP_DIR above the 100 GiB target; it was retained."
fi

echo "Backup completed: $final"
echo "Retention: keep at most $KEEP_COUNT dumps and target <=100 GiB; minimum free-space guard is 100 GiB."
echo "This does NOT back up the photo library."

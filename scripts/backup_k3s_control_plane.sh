#!/usr/bin/env bash
# Offline backup of the single-node k3s SQLite datastore and server token.
# The k3s service is stopped only while the archive is being created.
set -Eeuo pipefail
umask 077

MOUNT=/mnt/disk1
BACKUP_ROOT="$MOUNT/homelab-backups/k3s"
DATA_DIR=/var/lib/rancher/k3s
KEEP_COUNT=8

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

staging=""
k3s_stopped=false

cleanup() {
  rc=$?
  if [[ "$k3s_stopped" == true ]]; then
    echo "Attempting to restart k3s after backup failure..."
    systemctl start k3s || true
  fi
  if [[ -n "$staging" && -d "$staging" ]]; then
    rm -rf -- "$staging"
  fi
  exit "$rc"
}
trap cleanup EXIT

[[ "$EUID" -eq 0 ]] || fail "Run this backup as root"

for tool in systemctl findmnt tar sha256sum flock find sort grep install rm mv date; do
  command -v "$tool" >/dev/null 2>&1 || fail "Missing required command: $tool"
done

[[ "$(findmnt -n -M "$MOUNT" -o FSTYPE)" == "ext4" ]] \
  || fail "$MOUNT is not an ext4 mount. Check the physical HDD before backing up."
source_device="$(findmnt -n -M "$MOUNT" -o SOURCE)"
[[ -n "$source_device" ]] || fail "Cannot determine the HDD source device"

[[ -f "$DATA_DIR/server/db/state.db" ]] \
  || fail "SQLite datastore not found at $DATA_DIR/server/db/state.db"
[[ -f "$DATA_DIR/server/token" ]] \
  || fail "k3s server token not found at $DATA_DIR/server/token"
systemctl is-active --quiet k3s || fail "k3s is not active; refusing automated backup"

install -d -m 700 "$BACKUP_ROOT"
exec 9>"$BACKUP_ROOT/.backup.lock"
flock -n 9 || fail "Another k3s control-plane backup is running"

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
staging="$BACKUP_ROOT/.incomplete-$timestamp"
final="$BACKUP_ROOT/$timestamp"
[[ ! -e "$final" ]] || fail "Backup directory already exists: $final"
install -d -m 700 "$staging"

archive="$staging/k3s-control-plane.tar"
checksum="$staging/k3s-control-plane.tar.sha256"

echo "Stopping k3s for an offline SQLite backup..."
systemctl stop k3s
k3s_stopped=true

tar --acls --xattrs \
  -C / \
  -cpf "$archive" \
  var/lib/rancher/k3s/server/db \
  var/lib/rancher/k3s/server/token

echo "Archive complete; restarting k3s..."
systemctl start k3s
k3s_stopped=false
systemctl is-active --quiet k3s || fail "k3s did not return to active state"

(
  cd "$staging"
  sha256sum k3s-control-plane.tar > k3s-control-plane.tar.sha256
  sha256sum --check k3s-control-plane.tar.sha256
)

tar -tf "$archive" | grep -qx 'var/lib/rancher/k3s/server/db/state.db' \
  || fail "Backup archive is missing server/db/state.db"
tar -tf "$archive" | grep -qx 'var/lib/rancher/k3s/server/token' \
  || fail "Backup archive is missing server/token"

chmod 600 "$archive" "$checksum"
mv -- "$staging" "$final"
staging=""

mapfile -t backups < <(
  find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d \
    -name '????????T??????Z' -printf '%f\n' | sort
)

while (( ${#backups[@]} > KEEP_COUNT )); do
  oldest="${backups[0]}"
  echo "Pruning old k3s backup: $oldest"
  rm -rf -- "$BACKUP_ROOT/$oldest"
  backups=("${backups[@]:1}")
done

echo "k3s backup completed: $final"
echo "Retention: latest $KEEP_COUNT successful control-plane backups."

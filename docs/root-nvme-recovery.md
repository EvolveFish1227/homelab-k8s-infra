# Root NVMe disaster recovery

This runbook covers catastrophic loss of the HomeServer **root NVMe** while the 12 TB HDD remains intact. It complements, rather than replaces, the k3s control-plane backup, Immich PostgreSQL dump, HomeLab CA backup, and Git repository.

Current design assumptions:

- single-node k3s on host `homeserver`
- embedded SQLite datastore
- k3s Secrets encryption enabled
- control-plane backups under `/mnt/disk1/homelab-backups/k3s`
- host-recovery snapshots under `/mnt/disk1/homelab-backups/host`
- Immich PostgreSQL dumps under `/mnt/disk1/homelab-backups/postgres`
- Immich media remains on the surviving HDD/storage pool
- live PostgreSQL data at `/srv/immich-postgres` and Prometheus TSDB at `/srv/prometheus` are lost with the root NVMe

K3s upstream requires the SQLite `server/db` contents and the **matching original server token** for control-plane recovery. The token protects confidential bootstrap data in the datastore, so a database backup without its corresponding token is not a usable full restore. See: https://docs.k3s.io/datastore/backup-restore

## 1. Prepare a host-recovery snapshot now

The host snapshot is intentionally limited to rebuild metadata. It does **not** copy Kubernetes Secrets, the admin kubeconfig, the k3s server token, or `encryption-config.json`.

Run:

```bash
cd ~/HomeLab/homelab-k8s-infra
sudo bash scripts/backup_host_recovery.sh
```

Find and verify the newest snapshot:

```bash
HOST_BACKUP=$(
  sudo find /mnt/disk1/homelab-backups/host \
    -mindepth 1 -maxdepth 1 -type d \
    -name '????????T??????Z' -printf '%p\n' |
  sort |
  tail -1
)

echo "$HOST_BACKUP"

sudo env HOST_BACKUP="$HOST_BACKUP" sh -c '
  cd "$HOST_BACKUP" &&
  sha256sum --check SHA256SUMS
'
```

The bundle records:

- hostname and OS/kernel information
- exact k3s version
- a whitelisted non-secret subset of the k3s systemd `ExecStart` arguments
- `/etc/fstab` as a **reference copy**
- block-device UUIDs and current mount layout
- persistent-path modes/owners for `/mnt/disk1`, `/mnt/storage`, `/srv/immich-postgres`, and `/srv/prometheus`
- network/DNS observations
- current PV/PVC identities when the Kubernetes API is available
- `secrets-encryption: true` from the dedicated non-secret k3s config drop-in
- the read-only `k3s secrets-encrypt status`

Run this snapshot again after meaningful host changes such as disk/mount changes, k3s configuration changes, hostname/network changes, or an OS reinstall.

## 2. Before rebuilding after an NVMe failure

Do not initialize, format, or repurpose the surviving 12 TB HDD.

From another Linux environment or the newly installed OS, inspect the surviving disk and compare it with the latest host bundle:

```bash
lsblk -f
sudo cat "$HOST_BACKUP/lsblk.txt"
sudo cat "$HOST_BACKUP/findmnt.txt"
```

Confirm the filesystem UUID and expected mount layout before editing mounts.

Also select the newest verified k3s backup and PostgreSQL dump. Do not choose by filename alone; verify checksums.

```bash
K3S_BACKUP=$(
  sudo find /mnt/disk1/homelab-backups/k3s \
    -mindepth 1 -maxdepth 1 -type d \
    -name '????????T??????Z' -printf '%p\n' |
  sort |
  tail -1
)

sudo env K3S_BACKUP="$K3S_BACKUP" sh -c '
  cd "$K3S_BACKUP" &&
  sha256sum --check k3s-control-plane.tar.sha256
'
```

The archive must contain both:

```text
var/lib/rancher/k3s/server/db/state.db
var/lib/rancher/k3s/server/token
```

## 3. Reinstall Ubuntu and restore the host identity

Install Ubuntu on the replacement NVMe. Use the saved `os-release`, `kernel.txt`, and disk metadata as references.

Set the hostname before restoring k3s:

```bash
sudo hostnamectl set-hostname homeserver
```

### Restore mounts carefully

**Do not copy the old `fstab` over the fresh OS wholesale.** The new NVMe will have different root/swap UUIDs. Use the saved file only as a reference and merge back the surviving data-disk and mergerfs/storage entries that still apply.

```bash
sudo cat "$HOST_BACKUP/fstab"
lsblk -f
```

After editing the new `/etc/fstab`:

```bash
sudo mount -a
findmnt -M /mnt/disk1
findmnt -M /mnt/storage
```

Do not continue until the surviving storage paths resolve to the expected physical HDD/storage pool. Starting Kubernetes against an unmounted `/mnt/storage` can cause writes to land on the replacement root filesystem instead of the media disk.

Recreate root-NVMe local-PV directories using the numeric mode/uid/gid values recorded in `storage-paths.txt`:

```bash
sudo cat "$HOST_BACKUP/storage-paths.txt"
```

At minimum, `/srv/immich-postgres` and `/srv/prometheus` must exist before their Local PVs can be used. PostgreSQL data itself will be restored from a logical dump later; Prometheus historical TSDB data is not currently backed up and may be reinitialized.

## 4. Install the exact k3s version without starting it

Read the recorded version:

```bash
cat "$HOST_BACKUP/k3s-version.txt"
cat "$HOST_BACKUP/k3s-runtime-args.txt"
```

Install the same k3s version with auto-start and auto-enable disabled. Extract the version string from the saved output:

```bash
K3S_VERSION="$(awk '/^k3s version / {print $3; exit}' "$HOST_BACKUP/k3s-version.txt")"
echo "$K3S_VERSION"
```

Use the saved non-secret runtime arguments, captured from the k3s systemd `ExecStart`, to reproduce design-critical server options. The repository's current bootstrap design disables the built-in Traefik and local-storage components because those are managed separately through GitOps. Do not add a token or datastore endpoint from memory.

Example for the current design:

```bash
curl -sfL https://get.k3s.io |
  INSTALL_K3S_VERSION="$K3S_VERSION" \
  INSTALL_K3S_EXEC="server --disable traefik --disable local-storage" \
  INSTALL_K3S_SKIP_START=true \
  INSTALL_K3S_SKIP_ENABLE=true \
  sh -
```

K3s documents `INSTALL_K3S_SKIP_START=true` / `INSTALL_K3S_SKIP_ENABLE=true` for installing without launching the service: https://docs.k3s.io/advanced

Do not start k3s yet.

## 5. Restore the non-secret encryption enablement

Restore only the dedicated config drop-in:

```bash
sudo install -d -m 0755 /etc/rancher/k3s/config.yaml.d

sudo install -m 0644 \
  "$HOST_BACKUP/k3s-config/20-secrets-encryption.yaml" \
  /etc/rancher/k3s/config.yaml.d/20-secrets-encryption.yaml

sudo cat /etc/rancher/k3s/config.yaml.d/20-secrets-encryption.yaml
```

Expected:

```yaml
secrets-encryption: true
```

Do **not** restore or invent `encryption-config.json` from Git. K3s stores generated encryption key material under `/var/lib/rancher/k3s/server/cred/encryption-config.json`; it is confidential and is intentionally excluded from the host bundle. The matching datastore plus original server token are the documented recovery inputs.

## 6. Restore the k3s SQLite datastore and matching server token

Verify k3s is stopped:

```bash
sudo systemctl stop k3s 2>/dev/null || true
```

A fresh never-started installation should not already have a live SQLite datastore:

```bash
if sudo test -e /var/lib/rancher/k3s/server/db/state.db; then
  echo "STOP: a datastore already exists. Do not overwrite it until you confirm it is disposable fresh state."
  exit 1
fi
```

Recheck the selected archive before extraction:

```bash
sudo env K3S_BACKUP="$K3S_BACKUP" sh -c '
  cd "$K3S_BACKUP" &&
  sha256sum --check k3s-control-plane.tar.sha256
'
```

Restore it:

```bash
sudo tar --acls --xattrs -C / -xpf "$K3S_BACKUP/k3s-control-plane.tar"
```

Confirm both critical files now exist without printing the token:

```bash
sudo test -f /var/lib/rancher/k3s/server/db/state.db && echo "state.db restored"
sudo test -f /var/lib/rancher/k3s/server/token && echo "server token restored"
```

The server token is highly sensitive. Never print it, commit it, or paste it into a ticket/chat.

## 7. Start and validate the recovered control plane

Enable and start k3s:

```bash
sudo systemctl enable k3s
sudo systemctl start k3s
```

Wait for the API and node:

```bash
sudo systemctl is-active k3s
sudo k3s kubectl get nodes
```

Verify Secrets encryption:

```bash
sudo k3s secrets-encrypt status
```

For the current cluster, the expected stable state is:

```text
Encryption Status: Enabled
Current Rotation Stage: reencrypt_finished
Server Encryption Hashes: All hashes match
```

Verify the important Secret objects exist without decoding them:

```bash
sudo k3s kubectl -n samba get secret samba-runtime-config
sudo k3s kubectl -n immich get secret immich-db-credentials
sudo k3s kubectl -n cert-manager get secret homelab-root-ca-secret
```

Verify the restored storage identities against the saved snapshot:

```bash
sudo k3s kubectl get pv
sudo k3s kubectl get pvc -A
```

## 8. Restore application data lost with the NVMe

Restoring the Kubernetes control plane does not restore files that physically lived on the failed NVMe.

### Immich PostgreSQL

The authoritative NVMe-loss recovery source is the latest verified PostgreSQL custom-format dump under:

```text
/mnt/disk1/homelab-backups/postgres/
```

Do not resume normal Immich use until the database restore is complete and validated. Follow `docs/immich-postgres-backup.md` and prepare an empty compatible PostgreSQL 18 / VectorChord database before restoring. Keep Immich application writes stopped during the restore.

### Prometheus

The live TSDB at `/srv/prometheus` is not currently backed up independently. After root-NVMe loss, expect to initialize a fresh Prometheus TSDB and lose the historical retention window.

### Immich media

The media library remains on the surviving HDD/storage pool. Confirm its existing PV backing path and mount are correct **before** allowing Immich to write.

## 9. GitOps and final validation

Once the control plane and persistent data are correct:

1. clone/pull this repository on the rebuilt host;
2. confirm Argo CD applications return `Synced/Healthy`;
3. verify Traefik, cert-manager, Immich, monitoring, and Samba;
4. verify `photos.homelab.com`, `grafana.homelab.com`, and `argocd.homelab.com`;
5. verify the renewed HomeLab CA fingerprint/client trust;
6. run a new k3s backup and host-recovery snapshot on the replacement NVMe.

Do not use GitOps reconciliation as a substitute for restoring cluster-local Secrets or application data. Git intentionally does not contain the current runtime passwords or CA private key.

## 10. Scope limits

This recovery design protects against **root NVMe loss when the 12 TB HDD survives**.

It does not protect against:

- failure or loss of the 12 TB HDD containing the media and local backups;
- theft, fire, water damage, or other whole-machine loss;
- simultaneous corruption/loss of both disks.

Those risks require an independent physical or off-host copy, which is outside the current hardware available to this HomeLab.

# Immich PostgreSQL backup to the existing 12 TB HDD

The live database is PostgreSQL 18 on the NVMe at `/srv/immich-postgres`. The physical HDD is the ext4 filesystem mounted at `/mnt/disk1`, which is also the underlying disk for the mergerfs media pool. This backup protects against an NVMe failure **if the HDD remains healthy**; it does not protect against failure of the HDD or loss of the entire HomeServer.

This script performs an online, custom-format `pg_dump` of the live `immich` database. It checks that the destination is a mounted ext4 filesystem, avoids concurrent backup jobs, reads/decompresses the archive using `pg_restore --file=/dev/null` inside the matching PostgreSQL container, and writes a SHA-256 checksum. It does not overwrite or automatically delete existing backups. It does not change the running database or Kubernetes resources.

The generated SQL validation is **not** a test restore into a database. Periodically perform a separate restore to an isolated test database.

## 1. Run one manual backup and verify it

Run these commands on HomeServer as the user whose `kubectl` configuration accesses the cluster:

```bash
cd ~/HomeLab/homelab-k8s-infra
git pull --ff-only
findmnt -M /mnt/disk1
sudo install -d -m 700 -o "$USER" -g "$(id -gn)" /mnt/disk1/homelab-backups/postgres
bash scripts/backup_immich_postgres.sh
```

Check that you see the successful checksum result and a nonempty `.dump` file. The backup directory is:

```text
/mnt/disk1/homelab-backups/postgres/immich-YYYYMMDDTHHMMSSZ.dump
/mnt/disk1/homelab-backups/postgres/immich-YYYYMMDDTHHMMSSZ.dump.sha256
```

Recheck the latest checksum from its own directory:

```bash
cd /mnt/disk1/homelab-backups/postgres
sha256sum --check immich-YYYYMMDDTHHMMSSZ.dump.sha256
```

The script does not export Kubernetes Secrets or record database credentials in a backup log. Nevertheless, database archives contain personal metadata; keep their permissions restricted and encrypt copies held outside the machine.

## 2. Optional daily automation

After a **successful manual run**, copy the optional systemd user units:

```bash
mkdir -p ~/.config/systemd/user
cp systemd/homelab-immich-postgres-backup.* ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now homelab-immich-postgres-backup.timer
systemctl --user list-timers --all | grep homelab-immich-postgres-backup
```

The timer runs daily (with up to 15 minutes of randomized delay) and catches up after a missed run when the user's systemd manager next starts. If this user must have timers running even when logged out, check `loginctl show-user "$USER" -p Linger` and, if appropriate, run `sudo loginctl enable-linger "$USER"`.

The service expects the checked-out repository at `~/HomeLab/homelab-k8s-infra` and the same user's working Kubernetes context. Change `ExecStart` in the copied service file if your checkout is elsewhere. View output and diagnose failures with:

```bash
systemctl --user status homelab-immich-postgres-backup.timer
journalctl --user -u homelab-immich-postgres-backup.service -n 80 --no-pager
```

If the backup script changes in a future commit, pull those changes. If the unit files change, copy them again and reload systemd.

## 3. Restore considerations

Do not restore into the live Immich database just to test a backup. Stop relevant services and use a documented restore plan only when recovery is necessary; confirm PostgreSQL 18 and VectorChord compatibility, database state, and matching media files first. The archive can be inspected with PostgreSQL 18 `pg_restore`; for a real recovery, restore into an empty, separately prepared compatible database and validate users/assets/albums before making Immich available.

**The Immich media library is not included in this database backup.** It lives on the same physical HDD under `immich-library-pvc`. Copy the entire library to independent storage (another disk or a trusted offsite destination), and keep both database and media copies. Database and media backups taken at widely different times may not represent an identical application state.

See [disaster recovery](disaster-recovery.md) for the CA and application recovery ordering.

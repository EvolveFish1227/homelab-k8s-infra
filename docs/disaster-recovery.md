# HomeLab disaster recovery: internal CA and Immich data

This runbook documents the actual resources in this repository. It does not back up your running cluster by itself. The public `homelab-ca.crt` in Git is **not** the CA private key and cannot replace it.

## 1. Export the existing internal CA (run on HomeServer)

Choose a location **outside the Git checkout** and, ideally, on a separate removable or remote disk. Verify the destination is really mounted before writing:

```bash
findmnt -T /path/to/independent-backup-drive
python3 scripts/backup_homelab_ca.py \
  --output-dir /path/to/independent-backup-drive/homelab-ca
```

The script reads `cert-manager/homelab-root-ca-secret` without changing it. It creates a private, timestamp-independent unique directory containing `tls.crt` and `tls.key`, checks that the public keys match, and prints the SHA-256 certificate fingerprint. The directory is mode 0700 and both files are mode 0600. If the command fails, investigate before treating the export as a backup.

Compare the exported certificate with the trust anchor in the repo:

```bash
openssl x509 -in homelab-ca.crt -noout -fingerprint -sha256
openssl x509 -in /path/to/exported-directory/tls.crt -noout -fingerprint -sha256
```

If fingerprints differ, identify which certificate clients currently trust. Do not replace the live CA or overwrite the trusted certificate merely to make them match. Preserve a separate copy of any older CA that clients still trust.

**Never** commit `tls.key`, the Secret YAML, or backup archives to GitHub. Do not paste the key into chats, issues, logs, or pull requests. Encrypt the offline copy and test that it can be decrypted.

## 2. Restoring the CA on a fresh cluster

Use this only for a new/recovered cluster **before** Argo CD deploys the Certificate resource and cert-manager could create a different CA. Confirm that the target cluster does not already have an active `homelab-root-ca-secret`. Do not overwrite a live CA.

```bash
kubectl create namespace cert-manager --dry-run=client -o yaml | kubectl apply -f -
kubectl -n cert-manager get secret homelab-root-ca-secret
# Expect NotFound. If a Secret exists, STOP and investigate; do not overwrite it.

BACKUP_DIR=/path/to/exported-directory
openssl x509 -in "$BACKUP_DIR/tls.crt" -noout -fingerprint -sha256
openssl pkey -in "$BACKUP_DIR/tls.key" -noout

kubectl -n cert-manager create secret tls homelab-root-ca-secret \
  --cert="$BACKUP_DIR/tls.crt" --key="$BACKUP_DIR/tls.key"
```

Then bootstrap the cert-manager Application and issuer/Certificate manifests through the normal GitOps procedure. Verify the live Secret's certificate fingerprint against the backup and confirm `homelab-ca-issuer` is Ready before relying on issued TLS certificates. The root Certificate's status should be checked to ensure cert-manager has not reissued a different CA.

## 3. Immich restore inputs

A database-only dump is insufficient: photos and videos reside in `immich-library-pvc` on the mergerfs pool, whereas PostgreSQL uses `immich-postgres-direct-pvc` at `/srv/immich-postgres` on the NVMe ext4 filesystem.

Determine the current backing directory and reclaim policy from the **live PV** (never assume a PVC's UUID/path):

```bash
LIBRARY_PV=$(kubectl -n immich get pvc immich-library-pvc -o jsonpath='{.spec.volumeName}')
kubectl get pv "$LIBRARY_PV" -o jsonpath='{.spec.hostPath.path}{"\n"}{.spec.local.path}{"\n"}'
kubectl get pv "$LIBRARY_PV" -o jsonpath='{.spec.persistentVolumeReclaimPolicy}{"\n"}'
```

Retain separate, tested copies of both the full media directory and a PostgreSQL dump. A backup copied only to the same physical disk is not independent. Before a cluster rebuild, record the PV/PVC bindings and the host mount layout, then restore both data stores without pointing a fresh PostgreSQL process at an empty directory.

The legacy `immich-postgres-pvc` is a historical rollback copy, not a continuously updated backup.

## 4. Additional recovery material

Record the k3s version, host mount definitions, DNS settings, and Argo CD bootstrap procedure outside the cluster. Preserve k3s datastore backup and the server token when doing a full control-plane restoration; this is a different procedure from restoring application data.

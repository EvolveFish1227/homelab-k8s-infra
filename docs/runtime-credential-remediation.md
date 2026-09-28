# Runtime credential remediation (manual cutover)

This draft change removes passwords from current Git manifests. It does **not** rotate
existing credentials, remove them from Git history, or create the necessary runtime
Secrets. Do not merge before completing the preparation below. The draft PR's
deleted lines can still expose the previous values; treat all existing credentials
as compromised and rotate them after the safe cutover.

The cluster uses Argo CD auto-sync, so apply the following on **HomeServer** in
a controlled maintenance window. Never paste credentials into GitHub, terminal
command arguments, chat, screenshots, or shell history. Disable shell tracing
(set +x). Kubernetes Secrets are base64 encoded, not encrypted by default.

## 1. Preflight and backup (no Kubernetes resource deletion)

Run and verify a new online database backup:

    cd ~/HomeLab/homelab-k8s-infra
    bash scripts/backup_immich_postgres.sh
    kubectl -n immich get deployment immich-postgresql
    kubectl -n samba get deployment samba
    kubectl -n argocd get application root-application immich samba-gateway

The database dump covers **only** the database, not the separate media library.
Verify that the current Immich application and Samba share work before changing
anything. The original credentials may already be in Git history.

## 2. Precreate cluster-local Secrets containing the CURRENT credentials

This is a compatibility stage, **not** a rotation. It ensures the existing
applications do not lose authentication when their manifests switch to Secret
references. These commands stream values locally; they do not print passwords.

    set +x
    set -o pipefail
    kubectl -n immich get secret immich-db-credentials --ignore-not-found -o name
    kubectl -n samba get secret samba-runtime-config --ignore-not-found -o name

Both should be absent. If either exists, stop and inspect it; do not overwrite it
blindly. Extract the existing PostgreSQL environment value, and use the actual
Samba ConfigMap (not the old, unused samba-secret) as the source:

    kubectl -n immich exec deployment/immich-postgresql -c postgres -- sh -c 'printf %s "$POSTGRES_PASSWORD"' |
      kubectl -n immich create secret generic immich-db-credentials --from-file=password=/dev/stdin

    kubectl -n samba get configmap samba-config -o jsonpath='{.data.config\.yml}' |
      kubectl -n samba create secret generic samba-runtime-config --from-file=config.yml=/dev/stdin

Check presence and nonzero lengths without displaying secret contents:

    kubectl -n immich get secret immich-db-credentials -o jsonpath='{.data.password}' | base64 -d | wc -c
    kubectl -n samba get secret samba-runtime-config -o jsonpath='{.data.config\.yml}' | base64 -d | wc -c

If a command failed, stop. Never create an empty password. Preserve the old
Samba ConfigMap until the new Deployment is healthy; do not manually delete the
Immich PVC or the database.

## 3. Merge only after Secret preflight, then confirm rollout

The PR is draft by design. Once both runtime Secrets are ready and the backup is
verified, approve/merge it during maintenance. Argo CD will reconcile the
Immich/PostgreSQL environments and the Samba Secret volume. Check:

    kubectl -n immich rollout status deployment/immich-postgresql --timeout=10m
    kubectl -n samba rollout status deployment/samba --timeout=10m
    kubectl -n immich get pods
    kubectl -n samba get pods
    kubectl -n argocd get application root-application immich samba-gateway

Confirm Immich login, existing photos, and Samba authentication with the
CURRENT credentials. The prior passwords are still compromised until step 4.

If an Argo app is OutOfSync or Degraded, examine the sync error and Pod events;
do not delete the database, media PVC, or the old storage volumes.

## 4. Rotate PostgreSQL password, then update the runtime Secret

Generate a distinct random password locally and store it in a password manager.
To change the existing PostgreSQL role (changing POSTGRES_PASSWORD alone does
NOT update an initialized database), use interactive psql:

    kubectl -n immich exec -it deployment/immich-postgresql -c postgres -- psql -U immich -d immich

At the psql prompt, enter:

    \password immich
    \q

Enter the new password twice when prompted. Do not place it in a SQL command.
Expect a short Immich authentication interruption until its Pod is restarted.

Update the local Secret using standard input, not --from-literal (which exposes
the value through process arguments). Run with shell tracing disabled:

    set +x
    read -r -s -p 'Enter the SAME new PostgreSQL password: ' NEW_DB_PASSWORD
    printf '\n'
    if [ -z "$NEW_DB_PASSWORD" ]; then
      echo 'Empty password; stop here without modifying the Secret'
      unset NEW_DB_PASSWORD
    else
      printf '%s' "$NEW_DB_PASSWORD" |
        kubectl -n immich create secret generic immich-db-credentials --from-file=password=/dev/stdin --dry-run=client -o yaml |
        kubectl -n immich apply -f -
      unset NEW_DB_PASSWORD
    fi

Then restart PostgreSQL to refresh its declared environment, and restart the
Immich SERVER deployment to refresh its DB_PASSWORD environment variable.
Inspect actual deployment names before restarting; do not assume the Helm name.

    kubectl -n immich rollout restart deployment/immich-postgresql
    kubectl -n immich rollout status deployment/immich-postgresql --timeout=10m
    kubectl -n immich get deployments

    # Replace with the actual Immich server Deployment shown above:
    kubectl -n immich rollout restart deployment/<IMMICH_SERVER_DEPLOYMENT>
    kubectl -n immich rollout status deployment/<IMMICH_SERVER_DEPLOYMENT> --timeout=10m

Test Immich login, existing assets and database connectivity. Do not run a
database initialization or recreate its persistent volume to resolve auth errors.

## 5. Rotate Samba password in the config Secret

Generate a DIFFERENT password and save it in a password manager. This command
prompts without echoing and streams valid YAML directly into the Kubernetes
Secret; it does not put the password in a CLI argument or a working-tree file:

    set +x
    python3 - <<'PY' |
      kubectl -n samba create secret generic samba-runtime-config --from-file=config.yml=/dev/stdin --dry-run=client -o yaml |
      kubectl -n samba apply -f -
    import getpass
    import json
    from pathlib import Path
    import sys

    password = getpass.getpass('New Samba password: ')
    if len(password) < 24 or '\n' in password or '\r' in password:
        raise SystemExit('Choose a password of at least 24 characters without line breaks')
    template = Path('infrastructure/samba/samba-config.yml.example').read_text()
    sys.stdout.write(template.replace('__SAMBA_PASSWORD_JSON__', json.dumps(password)))
    PY

    kubectl -n samba rollout restart deployment/samba
    kubectl -n samba rollout status deployment/samba --timeout=10m

Confirm a NEW SMB login succeeds and the old password no longer authenticates.
Disconnect cached SMB sessions or saved client credentials as needed.

## 6. Final security review

    git grep -n -E 'DB_PASSWORD:|POSTGRES_PASSWORD|SAMBA_PASSWORD|password:' -- apps infrastructure README.md
    kubectl -n argocd get application root-application immich samba-gateway
    kubectl -n immich get pods
    kubectl -n samba get pods

The grep should show **Secret references** and the intentionally inert .example
template, not real credentials. Inspect any unexpected hits; do not paste output
containing secrets in public issues. Check GitHub secret-scanning alerts and
rotate any additional credential found. Old values remain reachable from prior
Git commits and PR diffs; rotation is what invalidates them. Consider a
coordinated history rewrite only AFTER rotation and after considering forks,
clones, branch protections and collaborators; it is not a substitute for rotation.

The new runtime Secrets are created outside Git and will need to be restored on
a fresh cluster before enabling the dependent Argo CD Applications. Back up
Secret material encrypted in an independent, access-controlled location.

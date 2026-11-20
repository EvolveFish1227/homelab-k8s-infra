# Immediate Argo CD refresh from GitHub Actions

This repository normally relies on Argo CD's reconciliation polling. A self-hosted GitHub Actions runner on the HomeLab network can request an immediate refresh of the root App-of-Apps after every push to `main`.

## Security model

The workflow does not use the normal k3s admin kubeconfig.

A dedicated ServiceAccount named `github-actions-argocd-refresh` is restricted by namespaced RBAC to only:

- `get` the Argo CD `Application/root-application`;
- `patch` the Argo CD `Application/root-application`.

It cannot read Kubernetes Secrets or modify Deployments, Pods, PVCs, or other Applications.

The workflow runs only on `push` to `main`, not on pull requests.

## One-time setup

1. Add a self-hosted GitHub Actions runner on the HomeServer under repository **Settings → Actions → Runners → New self-hosted runner**.
2. Run the runner under a dedicated unprivileged Linux account.
3. Add the custom runner label `homelab`.
4. Clone/pull this repository as that same runner account.
5. From the repository checkout, bootstrap the restricted kubeconfig using an existing administrator kubectl context:

```bash
bash scripts/bootstrap_argocd_refresh_runner.sh
```

If the runner is on another LAN machine and the administrator kubeconfig points to `127.0.0.1`, override the Kubernetes API address:

```bash
KUBE_SERVER=https://<homeserver-lan-ip>:6443 \
  bash scripts/bootstrap_argocd_refresh_runner.sh
```

The script writes `$HOME/.kube/argocd-refresh` with mode 0600. It creates a dedicated long-lived ServiceAccount token Secret in the cluster; the token is not stored in GitHub or in this repository.

## Runtime flow

After a merge lands on `main`:

1. GitHub starts `.github/workflows/refresh-argocd.yaml`.
2. The HomeLab self-hosted runner uses the restricted kubeconfig.
3. The workflow patches `root-application` with `argocd.argoproj.io/refresh=hard`.
4. Argo CD refreshes the root App-of-Apps immediately.
5. Existing automated sync policies apply the Git change to child Applications and workloads.

The annotation requests a refresh; Argo CD's existing `syncPolicy.automated` remains responsible for applying changes.

## Revocation

To immediately revoke the runner credential:

```bash
kubectl -n argocd delete secret github-actions-argocd-refresh-token
```

To disable the integration entirely, also remove or disable the self-hosted GitHub Actions runner.

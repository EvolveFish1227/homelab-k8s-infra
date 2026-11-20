#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="argocd"
SERVICE_ACCOUNT="github-actions-argocd-refresh"
TOKEN_SECRET="github-actions-argocd-refresh-token"
KUBECONFIG_OUT="${KUBECONFIG_OUT:-$HOME/.kube/argocd-refresh}"
KUBECTL="${KUBECTL:-kubectl}"

if ! command -v "$KUBECTL" >/dev/null 2>&1; then
  echo "kubectl command not found: $KUBECTL" >&2
  exit 1
fi

echo "Applying restricted Argo CD refresh RBAC..."
"$KUBECTL" apply -f "$REPO_ROOT/infrastructure/argocd-ci/rbac.yaml"

if ! "$KUBECTL" -n "$NAMESPACE" get secret "$TOKEN_SECRET" >/dev/null 2>&1; then
  echo "Creating a dedicated service-account token Secret..."
  cat <<EOF | "$KUBECTL" apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: $TOKEN_SECRET
  namespace: $NAMESPACE
  annotations:
    kubernetes.io/service-account.name: $SERVICE_ACCOUNT
type: kubernetes.io/service-account-token
EOF
fi

echo "Waiting for Kubernetes to populate the service-account token..."
for _ in $(seq 1 30); do
  if "$KUBECTL" -n "$NAMESPACE" get secret "$TOKEN_SECRET"       -o jsonpath='{.data.token}' 2>/dev/null | grep -q .; then
    break
  fi
  sleep 1
done

TOKEN_B64="$("$KUBECTL" -n "$NAMESPACE" get secret "$TOKEN_SECRET" -o jsonpath='{.data.token}')"
CA_B64="$("$KUBECTL" -n "$NAMESPACE" get secret "$TOKEN_SECRET" -o jsonpath='{.data.ca\.crt}')"
SERVER="${KUBE_SERVER:-$("$KUBECTL" config view --minify -o jsonpath='{.clusters[0].cluster.server}')}"

if [[ -z "$TOKEN_B64" || -z "$CA_B64" || -z "$SERVER" ]]; then
  echo "Could not build restricted kubeconfig." >&2
  exit 1
fi

TOKEN="$(printf '%s' "$TOKEN_B64" | base64 -d)"

install -d -m 700 "$(dirname "$KUBECONFIG_OUT")"
umask 077
cat >"$KUBECONFIG_OUT" <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: homelab
    cluster:
      server: $SERVER
      certificate-authority-data: $CA_B64
contexts:
  - name: argocd-refresh
    context:
      cluster: homelab
      namespace: $NAMESPACE
      user: github-actions-argocd-refresh
current-context: argocd-refresh
users:
  - name: github-actions-argocd-refresh
    user:
      token: $TOKEN
EOF
chmod 600 "$KUBECONFIG_OUT"

echo "Verifying restricted access..."
KUBECONFIG="$KUBECONFIG_OUT" "$KUBECTL" -n "$NAMESPACE" get application root-application >/dev/null

echo
echo "Restricted kubeconfig created at:"
echo "  $KUBECONFIG_OUT"
echo
echo "This credential can only get/patch the Argo CD Application named root-application."
echo "Do not commit or copy this kubeconfig into the repository."

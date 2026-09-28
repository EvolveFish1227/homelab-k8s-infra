# homelab-k8s-infra
This repository drives declarative cluster state synchronization, automated deployments, storage configuration, and observability stack provisioning without manual kubectl intervention.

# HomeLab Infrastructure & Storage Engine (Samba/SMB & GitOps)

A bare-metal Kubernetes cluster running on home hardware, engineered as a centralized **Home Storage Server & Media Engine**. This repository serves as the single declarative source of truth for all infrastructure, storage configurations, and network shares, managed end-to-end via **GitOps (Argo CD)**.

---

## 🏗️ Architecture Overview

This project implements enterprise-grade Infrastructure-as-Code (IaC) and GitOps practices to transform bare-metal home hardware into a reliable, high-performance local storage pool, shared via SMB/CIFS to your home network, and running a self-hosted photo/media platform.

```
┌────────────────────────────────────────────────────────────────────────┐
│                              GitHub Repo                               │
│                     (homelab-k8s-infra / main)                         │
└───────────────────────────────────┬────────────────────────────────────┘
│
│ (GitOps Auto-Sync)
▼
┌────────────────────────────────────────────────────────────────────────┐
│                              k3s Cluster                               │
│                                                                        │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │                     Argo CD (Control Plane)                      │  │
│  │                      [Root Application]                          │  │
│  └──────┬─────────────────────────┬─────────────────────────┬───────┘  │
│         │                         │                         │          │
│         ▼                         ▼                         ▼          │
│  ┌──────────────┐         ┌──────────────┐         ┌──────────────┐    │
│  │  Networking  │         │Local Dynamic │         │ Home Media & │    │
│  │  (Traefik /  │         │   Storage    │         │ Photo Hub    │    │
│  │ cert-manager)│         │ (local-path) │         │ (SMB/Immich) │    │
│  └──────────────┘         └──────────────┘         └──────────────┘    │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │
                                    (Local Network Traffic)
                                    │
          ┌─────────────────────────┼─────────────────────────┐
          ▼                         ▼                         ▼
          📺 Smart TVs              💻 Laptops / PCs          📱 Mobile Devices
          (Plex/Jellyfin)            (Samba/SMB Shares)        (Immich Auto-Sync)
```

---

## 🛠️ Tech Stack & Key Components

- **Cluster Engine:** `k3s` (Lightweight Kubernetes running on bare-metal Linux)
- **Continuous Delivery & GitOps:** Argo CD (App-of-Apps Pattern)
- **Ingress Controller:** Traefik v3 (`traefik-ingress` class, managed via Helm & Argo CD)
- **Certificate Management:** `cert-manager` (Automated internal CA and TLS termination via custom self-signed Root CA and `homelab-ca-issuer` ClusterIssuer)
- **Observability:** Prometheus Operator (`kube-prometheus-stack`) + Custom Grafana Dashboards
- **Storage Subsystems:**
  - **Local Dynamic Engine:** Rancher `local-path-provisioner` mapped to host storage pools (`/mnt/storage`)
  - **LAN Gateways:** In-cluster Samba (SMB) gateway to share the host storage pool with home devices
- **Network Protocols:** SMB/CIFS (`Port 445`) and HTTPS (`Port 443`)

---

## 📂 Repository Structure

```text
homelab-k8s-infra/
├── README.md                       # System documentation & architectural guide
├── .github/workflows/validate-manifests.yaml # GitHub Actions validation
├── scripts/validate_manifests.py   # YAML and nested Helm values validation
├── bootstrap/                      # One-time cluster setup (Manual initialization)
│   └── root-app.yaml               # App-of-Apps master entrypoint
├── apps/                           # Argo CD Application manifests
│   ├── argocd-ingress.yaml         # Ingress rules for argocd.homelab.com
│   ├── argocd-ghcr-registry-secret.yaml # Public GHCR Helm registry configuration
│   ├── traefik.yaml                # Traefik v3 Ingress controller configuration
│   ├── cert-manager.yaml           # cert-manager Helm chart deployment app
│   ├── cert-manager-resources.yaml # cert-manager cluster issuers and certificates app
│   ├── local-path-provisioner.yaml # Local path provisioner storage app
│   ├── monitoring.yaml             # Prometheus & Grafana monitoring stack app
│   ├── monitoring-resources.yaml   # Custom Grafana dashboards & alerts app
│   ├── immich.yaml                 # Immich Helm app, server, Valkey, ML & Ingress
│   ├── immich-postgres.yaml        # PostgreSQL 18 Deployment, Service, legacy PVC
│   ├── immich-postgres-storage.yaml # Dedicated NVMe StorageClass, PV and PVC
│   ├── prometheus-storage.yaml      # Retained NVMe Local PV for Prometheus
│   ├── prometheus-direct-pvc.yaml   # Replacement prebound Prometheus claim (cutover only)
│   ├── immich-resources.yaml       # Immich library PVC app
│   └── samba.yaml                  # Samba SMB/CIFS LAN file sharing app
└── infrastructure/                 # Manifests, Helm values & storage specs
    ├── storage/                    # Kubernetes storage engine configurations
    │   ├── local-path-config.yaml  # ConfigMap containing host paths & helper pod specs
    │   └── local-path-provisioner.yaml # RBAC, Deployment, and StorageClass manifests
    ├── monitoring/                 # Custom Grafana dashboards and alert rules
    │   └── custom-dashboard-cluster.yaml # ConfigMap containing customized Grafana dashboard JSON
    ├── cert-manager/               # Kubernetes cert-manager cluster-level resources
    │   └── cluster-issuer.yaml     # Self-signed and CA cluster issuers, root CA certificate
    ├── immich/                     # Custom Immich infrastructure resources
    │   └── library-pvc.yaml        # 500Gi local-path PVC for Immich library storage
    └── samba/                      # Custom Samba server infrastructure resources
        ├── samba-config.yml.example # Non-secret config template (not deployed by Argo CD)
        ├── samba-deployment.yaml   # Container specification mounting /mnt/storage
        └── samba-service.yaml      # ClusterIP service for port 445
```

---

## 💾 Storage Architecture & Design Decisions

### 1. High-Performance Host-Path Storage (`local-path-provisioner`)
Standard cloud-based Kubernetes relies on network-attached block storage (like AWS EBS), which introduces network latency and limits I/O.
* **Design Choice:** Utilized Rancher's **local-path-provisioner** mapped directly to the bare-metal host's physical storage pools (e.g., `/mnt/storage`).
* **Engineering Impact:** Provides host-local storage for media and general workloads. The Immich PostgreSQL database uses a separate direct ext4 local PV on the NVMe, not the mergerfs-backed `/mnt/storage` pool.

### 2. Dual-Layer Storage Interfaces (In-Cluster vs. LAN Gateways)
To unify Kubernetes persistent storage with standard home network file sharing:
* **Cluster Workloads:** Media and general workloads use dynamic PVCs. PostgreSQL uses a static Local PersistentVolume on a direct ext4 filesystem.
* **Local LAN Clients:** Non-containerized devices (macOS Finder and Windows File Explorer) access the storage pool through the Samba gateway on port `445`.

### 3. Decoupled Compute & Storage (Stateful Isolation)
To keep persistent data separate from ordinary pod lifecycles, while recognizing that cluster or disk failure still requires tested backups:
* **Host Layer:** All physical storage drives are managed at the OS level and mounted to dedicated paths (e.g., `/mnt/storage`).
* **K8s Abstraction:** Kubernetes workloads interact strictly through persistent volume abstractions layered on top of host mounts. 
* **Engineering Impact:** Retained PVs and independently verified database and media backups are required before teardown or re-initialization. PVC deletion, a `Delete` reclaim policy, or a storage teardown helper can remove data. Do not assume a cluster rebuild is lossless.

---

## Immich backup and storage recovery

See the [disaster recovery runbook](docs/disaster-recovery.md) for the offline CA key export, certificate verification, recovery ordering, and separate Immich database/media backup requirements.

For online PostgreSQL backups to the existing HDD, see [Immich database backups](docs/immich-postgres-backup.md). This does not replace independent media backups.

Before moving Prometheus to NVMe, run the [read-only monitoring storage preflight](docs/prometheus-storage-migration.md).

The Immich library and PostgreSQL database are separate data stores; back up both before migration, PVC removal, or cluster teardown. PostgreSQL runs directly on the NVMe ext4 filesystem at `/srv/immich-postgres`, while media remains on `immich-library-pvc` in the storage pool. Keep an independent copy of database dumps and media outside the same underlying disk.

The statically provisioned PostgreSQL PV uses `Retain`. The library uses a dynamically provisioned PV: verify the *existing PV's* reclaim policy independently, since changing a StorageClass does not retroactively change an existing volume. The library PVC uses Argo CD `Prune=false,Delete=false` for GitOps deletion protection; this is not a substitute for a backup. The legacy PostgreSQL PVC is retained for rollback but is not a current backup once new database writes occur.

---

## 🚀 Quick Start & Bootstrap Procedure

This guide walks through initializing a bare-metal node, deploying the k3s control plane, and bootstrapping GitOps with Argo CD.

### 1. Host Preparation & Storage Mounts
Prepare the dedicated local storage mount point on the host operating system before initializing Kubernetes:

```bash
# Create local storage mount directory
sudo mkdir -p /mnt/storage
sudo chmod 777 /mnt/storage
```

### 2. Provision k3s Control Plane

Install k3s while disabling its built-in Traefik v2 and default local storage. This allows us to manage Traefik v3 and storage declaratively via Argo CD:

```bash
# Install k3s disabling built-in Traefik and local storage
curl -sfL https://get.k3s.io | sh -s - --disable traefik --disable local-storage

# Configure kubeconfig permissions for the local user
mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown $(id -u):$(id -g) ~/.kube/config

# Verify that the node is healthy:
kubectl get nodes
```

### 3. Deploy Argo CD Control Plane

Install the Argo CD engine into the `argocd` namespace:

```bash
# Create namespace and apply core manifests
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Wait for Argo CD components to reach Running state
kubectl rollout status deployment argocd-server -n argocd
```

### 4. Bootstrap Root GitOps Application (Deploys Traefik v3 & Storage Engine)

Hand over cluster management to Argo CD by applying the master App-of-Apps manifest. This will automatically deploy Traefik v3, the local-path-provisioner dynamic storage engine, and the Argo CD Ingress rules from your repository:

```bash
# Point Argo CD to this GitHub repository
kubectl apply -f bootstrap/root-app.yaml
```

*Once applied, Argo CD automatically reconciles `apps/traefik.yaml` and `apps/local-path-provisioner.yaml` to spin up Traefik v3 as your primary cluster Ingress Controller and the dynamic local storage engine, alongside all other applications declared in `apps/`.*

### 5. Access Argo CD Dashboard

Retrieve the auto-generated initial password:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo
```

Once DNS or `/etc/hosts` resolves `argocd.homelab.com` to your node's IP, navigate directly to:

```text
Argo CD: https://argocd.homelab.com

Immich: https://photos.homelab.com

Grafana: https://grafana.homelab.com
```

*(Alternatively, port-forward using `kubectl port-forward svc/argocd-server -n argocd 8080:443` and visit `https://localhost:8080`).*

---

## 📱 Deployed Applications

The following primary web services are deployed and managed under GitOps:

### 📸 Immich (Self-Hosted Photo Backup Engine)
* **URL:** [https://photos.homelab.com](https://photos.homelab.com)
* **Configuration:** Manifest declared in `apps/immich.yaml`.
* **Database Backend:** PostgreSQL 18 with VectorChord 1.1.1 (`ghcr.io/immich-app/postgres:18-vectorchord1.1.1`) in `apps/immich-postgres.yaml`.
* **Storage Engine:** The 500Gi media PVC (`immich-library-pvc`) uses the existing local-path storage pool. PostgreSQL uses `immich-postgres-direct-pvc`, a statically provisioned local PV at `/srv/immich-postgres` on the NVMe ext4 filesystem, with `Retain` reclaim policy.
* **Resiliency Engineering:** Configured with an optimized `probes.startup` grace period of **20 minutes** (120 attempts × 10s) to permit seamless, uninterrupted geodata map indexing and database migrations on startup.

### 📁 Samba (SMB/CIFS LAN File-Sharing Gateway)
* **Configuration:** Manifest declared in `apps/samba.yaml` pointing to `infrastructure/samba/`.
* **Exposed Port:** `445` on the host LAN interface using `hostNetwork: true`; the Kubernetes Service is `ClusterIP`.
* **Protocol Details:** High-performance, lightweight SMB daemon based on `crazymax/samba`. Fully supports Windows Service Discovery (WSDD2) to seamlessly populate in your local network browsers.
* **Access Credentials:** 
  - **Username:** `homelab`
  - **Password:** Supplied through the cluster-local `samba-runtime-config` Kubernetes Secret; no credentials are committed to Git.
* **Storage Mounting:** Maps the physical storage pool `/mnt/storage` from the host directly into the container filesystem at `/samba/storage`. Provides local bare-metal disk read/write speeds for your LAN clients (PCs, Macs, Smart TVs).

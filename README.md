# homelab-k8s-infra
This repository drives declarative cluster state synchronization, automated deployments, secret encapsulation, and observability stack provisioning without manual kubectl intervention.

# HomeLab Infrastructure & Storage Engine (NFS/SMB & GitOps)

A bare-metal Kubernetes cluster running on home hardware, engineered as a centralized **Home Storage Server & Media Engine**. This repository serves as the single declarative source of truth for all infrastructure, storage configurations, and network shares, managed end-to-end via **GitOps (Argo CD)**.

---

## 🏗️ Architecture Overview

This project implements enterprise-grade Infrastructure-as-Code (IaC) and GitOps practices to transform bare-metal home hardware into a reliable, high-performance Network File System (NFS), SMB/CIFS storage cluster, and self-hosted photo/media platform.

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
│  │  Networking  │         │ Dynamic NFS  │         │ Home Media & │    │
│  │  (Traefik /  │         │ Provisioner  │         │ Photo Hub    │    │
│  │ cert-manager)│         │ (RWX Mode)   │         │ (SMB/Immich) │    │
│  └──────────────┘         └──────────────┘         └──────────────┘    │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │
                                    (Local Network Traffic)
                                    │
          ┌─────────────────────────┼─────────────────────────┐
          ▼                         ▼                         ▼
          📺 Smart TVs              💻 Laptops / PCs          📱 Mobile Devices
          (Plex/Jellyfin)            (NFS/SMB Shares)          (Immich Auto-Sync)
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
  - **Network Shares:** NFS Subdir External Provisioner (`ReadWriteMany` / RWX volume support)
- **Network Protocols:** SMB/CIFS (`Port 445`), NFS (`Port 2049`), and HTTPS (`Port 443`)

---

## 📂 Repository Structure

```text
homelab-k8s-infra/
├── README.md                       # System documentation & architectural guide
├── bootstrap/                      # One-time cluster setup (Manual initialization)
│   └── root-app.yaml               # App-of-Apps master entrypoint
├── apps/                           # Argo CD Application manifests
│   ├── argocd/                     # Argo CD ingress & service bindings
│   │   └── ingress.yaml            # Ingress rules for argocd.homelab.com
│   ├── traefik.yaml                # Traefik v3 Ingress controller configuration
│   ├── cert-manager.yaml           # cert-manager Helm chart deployment app
│   ├── cert-manager-resources.yaml # cert-manager cluster issuers and certificates app
│   ├── local-path-provisioner.yaml # Local path provisioner storage app
│   ├── monitoring.yaml             # Prometheus & Grafana monitoring stack app
│   ├── monitoring-resources.yaml   # Custom Grafana dashboards & alerts app
│   ├── immich.yaml                 # Immich photo suite, DB, Redis, ML & Ingress
│   └── immich-resources.yaml       # Immich persistent volume claim app
└── infrastructure/                 # Manifests, Helm values & storage specs
    ├── storage/                    # Kubernetes storage engine configurations
    │   ├── local-path-config.yaml  # ConfigMap containing host paths & helper pod specs
    │   └── local-path-provisioner.yaml # RBAC, Deployment, and StorageClass manifests
    ├── monitoring/                 # Custom Grafana dashboards and alert rules
    │   └── custom-dashboard-cluster.yaml # ConfigMap containing customized Grafana dashboard JSON
    ├── cert-manager/               # Kubernetes cert-manager cluster-level resources
    │   └── cluster-issuer.yaml     # Self-signed and CA cluster issuers, root CA certificate
    └── immich/                     # Custom Immich infrastructure resources
        └── library-pvc.yaml        # 500Gi local-path PVC for Immich library storage
```

---

## 💾 Storage Architecture & Design Decisions

### 1. Multi-Read / Multi-Write (`ReadWriteMany`) Access Mode
Standard Kubernetes persistent volumes default to `ReadWriteOnce` (RWO), locking storage access to a single node or pod at a time. 
* **Design Choice:** Implemented an **NFS Subdir External Provisioner** to supply `ReadWriteMany` (RWX) volumes across the cluster.
* **Engineering Impact:** Enables concurrent file access for decoupled workloads—allowing media ingest services, torrent engines, and streaming platforms (Plex/Jellyfin) to attach and write to the same storage paths simultaneously without file-lock deadlocks.

### 2. Dual-Layer Storage Interfaces (In-Cluster vs. LAN Gateways)
To unify Kubernetes persistent storage with standard home network file sharing:
* **Cluster Workloads:** Applications consume dynamic Persistent Volume Claims (PVCs) provisioned directly through Kubernetes StorageClasses.
* **Local LAN Clients:** Non-containerized devices (macOS Finder, Windows File Explorer, Smart TVs) access the identical physical storage pools via in-cluster Samba (SMB) and NFS server gateways exposed on dedicated LAN ports (`445` / `2049`).

### 3. Decoupled Compute & Storage (Stateful Isolation)
To guarantee zero data loss during node rebuilds, cluster upgrades, or pod failures:
* **Host Layer:** All physical storage drives are managed at the OS level and mounted to dedicated paths (e.g., `/mnt/storage`).
* **K8s Abstraction:** Kubernetes workloads interact strictly through persistent volume abstractions layered on top of host mounts. 
* **Engineering Impact:** Total cluster teardown or re-initialization does not alter underlying datasets, preserving all media and configuration states.

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
* **Database Backend:** Implemented with `postgresql` using `tensorchord/pgvecto-rs` for vector-enabled AI search. Managed cleanly via a custom `immich` superuser credential.
* **Storage Engine:** High-capacity 500Gi Persistent Volume Claim (`immich-library-pvc`) dynamic local-path mount, declared in `infrastructure/immich/library-pvc.yaml` and deployed via the `immich-resources` Argo CD application.
* **Resiliency Engineering:** Configured with an optimized `probes.startup` grace period of **20 minutes** (120 attempts × 10s) to permit seamless, uninterrupted geodata map indexing and database migrations on startup.

# homelab-k8s-infra
This repository drives declarative cluster state synchronization, automated deployments, secret encapsulation, and observability stack provisioning without manual kubectl intervention.

# HomeLab Infrastructure & Storage Engine (NFS/SMB & GitOps)

A bare-metal Kubernetes cluster running on home hardware, engineered as a centralized **Home Storage Server & Media Engine**. This repository serves as the single declarative source of truth for all infrastructure, storage configurations, and network shares, managed end-to-end via **GitOps (Argo CD)**.

---

## 🏗️ Architecture Overview

This project implements enterprise-grade Infrastructure-as-Code (IaC) and GitOps practices to transform bare-metal home hardware into a reliable, high-performance Network File System (NFS) and SMB/CIFS storage cluster.
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
│  │  Networking  │         │ Dynamic NFS  │         │ Home Shares  │    │
│  │  (Traefik /  │         │ Provisioner  │         │ & Media      │    │
│  │ cert-manager)│         │ (RWX Mode)   │         │ (SMB / Plex) │    │
│  └──────────────┘         └──────────────┘         └──────────────┘    │
└───────────────────────────────────┬────────────────────────────────────┘
│
(Local Network Traffic)
│
┌─────────────────────────┼─────────────────────────┐
▼                         ▼                         ▼
📺 Smart TVs              💻 Laptops / PCs          📱 Mobile Devices
(Plex/Jellyfin)            (NFS/SMB Shares)           (File Backups)

---

## 🛠️ Tech Stack & Key Components

- **Cluster Engine:** `k3s` (Lightweight Kubernetes running on bare-metal Linux)
- **Continuous Delivery & GitOps:** Argo CD (App-of-Apps Pattern)
- **Storage Subsystem:** NFS Subdir External Provisioner (`ReadWriteMany` / RWX volume support)
- **Network Sharing Protocols:** Samba/CIFS (`Port 445`) and NFS (`Port 2049`) for direct LAN access
- **Ingress & Networking:** Traefik Ingress Controller + `cert-manager`

---

## 📂 Repository Structure

```text
homelab-k8s-infra/
├── README.md                       # System documentation & architectural guide
├── bootstrap/                      # One-time cluster setup (Manual initialization)
│   ├── argocd/                     # Argo CD manifests
│   └── root-app.yaml               # App-of-Apps master entrypoint
├── apps/                           # Argo CD Application CRDs
│   ├── nfs-provisioner.yaml        # Automatic NFS volume provisioner app
│   ├── smb-share.yaml              # Local network share application
│   └── media-server.yaml           # Media streaming stack (Plex/Jellyfin)
└── infrastructure/                 # Manifests, Helm values & storage specs
    ├── storage/
    │   ├── nfs-provisioner/        # StorageClass & provisioner configs
    │   └── smb-share/              # Samba deployment & PVC definitions
    └── media/
        └── jellyfin/               # Media server mounting shared NFS drives
```
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

## 🚀 Quick Start & Bootstrap Procedure

This guide walks through initializing a bare-metal node, deploying the k3s control plane, and bootstrapping GitOps with Argo CD.

### 1. Host Preparation & Storage Mounts
Prepare the dedicated local storage mount point on the host operating system before initializing Kubernetes:

```bash
# Create local storage mount directory
sudo mkdir -p /mnt/storage
sudo chmod 777 /mnt/storage
```
### 2. Provisions k3s Control Plane

Install k3s, disabling default Traefik and local-path storage to allow full GitOps lifecycle management:

```bash

# Install k3s with custom feature flags
curl -sfL [https://get.k3s.io](https://get.k3s.io) | sh -s - --disable traefik --disable local-storage

# Configure kubeconfig permissions for the local user
mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown $(id -u):$(id -g) ~/.kube/config

# Verify that the node is healthy:
kubectl get nodes
```

### 3. Deploy Argo CD Control Plane

Install the Argo CD engine into the argocd namespace:

```bash

# Create namespace and apply core manifests
kubectl create namespace argocd
kubectl apply -n argocd -f [https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml](https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml)

# Wait for Argo CD components to reach Running state
kubectl rollout status deployment argocd-server -n argocd
```

### 4. Bootstrap Root GitOps Application

Hand over cluster management to Argo CD by applying the master App-of-Apps manifest:

```bash

# Point Argo CD to this GitHub repository
kubectl apply -f bootstrap/root-app.yaml
```
Once applied, Argo CD will automatically discover, deploy, and continuously reconcile all workloads declared inside the apps/ directory.

### 5. Access Argo CD Dashboard

Retrieve the initial admin password to log into the Argo CD UI:

```bash
# Port-forward the Argo CD server to local port 8080
kubectl port-forward svc/argocd-server -n argocd 8080:443

# Fetch the auto-generated initial password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo
```
Navigate to https://localhost:8080 in your browser (Username: admin).

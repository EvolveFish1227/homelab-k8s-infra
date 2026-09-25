#!/usr/bin/env python3
"""Fail CI when runtime passwords reappear in GitOps-managed manifests."""

from pathlib import Path
import yaml

ROOT = Path(__file__).resolve().parents[1]
SECRET_NAME = "immich-db-credentials"
SECRET_KEY = "password"


def require_secret_ref(env_item, description):
    expected = {
        "valueFrom": {
            "secretKeyRef": {
                "name": SECRET_NAME,
                "key": SECRET_KEY,
            }
        }
    }
    if env_item != expected:
        raise SystemExit(f"{description} must reference the external Kubernetes Secret")


def main():
    immich_app = yaml.safe_load((ROOT / "apps/immich.yaml").read_text())
    helm_values = yaml.safe_load(immich_app["spec"]["source"]["helm"]["values"])
    immich_env = helm_values["server"]["controllers"]["main"]["containers"]["main"]["env"]
    require_secret_ref(immich_env["DB_PASSWORD"], "Immich DB_PASSWORD")

    postgres_docs = list(yaml.safe_load_all((ROOT / "apps/immich-postgres.yaml").read_text()))
    postgres = next(doc for doc in postgres_docs if doc.get("kind") == "Deployment")
    env = postgres["spec"]["template"]["spec"]["containers"][0]["env"]
    db_password = next(item for item in env if item["name"] == "POSTGRES_PASSWORD")
    require_secret_ref({k: v for k, v in db_password.items() if k != "name"},
                       "PostgreSQL POSTGRES_PASSWORD")

    samba = yaml.safe_load((ROOT / "infrastructure/samba/samba-deployment.yaml").read_text())
    config = next(volume for volume in samba["spec"]["template"]["spec"]["volumes"]
                  if volume["name"] == "config")
    expected_volume = {
        "secret": {
            "secretName": "samba-runtime-config",
            "items": [{"key": "config.yml", "path": "config.yml"}],
        }
    }
    if {k: v for k, v in config.items() if k != "name"} != expected_volume:
        raise SystemExit("Samba must mount the external runtime Secret")

    for path in ("infrastructure/samba/samba-configmap.yaml",
                 "infrastructure/samba/samba-secret.yaml"):
        if (ROOT / path).exists():
            raise SystemExit(f"Remove committed Samba credential manifest: {path}")
    if "**Password:**" in (ROOT / "README.md").read_text():
        # Documentation may describe runtime Secret storage, but not a password literal.
        for line in (ROOT / "README.md").read_text().splitlines():
            if "**Password:**" in line and "samba-runtime-config" not in line:
                raise SystemExit("README must not publish the SMB password")
    print("Runtime credentials are sourced from cluster-local Secrets.")


if __name__ == "__main__":
    main()

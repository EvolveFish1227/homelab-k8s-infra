#!/usr/bin/env python3
"""Export the existing homelab CA certificate/key to a private OFF-REPOSITORY path.

This script does not create a new CA or modify Kubernetes resources.
"""

import argparse
import base64
import binascii
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


NAMESPACE = "cert-manager"
SECRET = "homelab-root-ca-secret"


def command(*args, input_bytes=None):
    result = subprocess.run(
        args,
        input=input_bytes,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(f"{args[0]} command failed: {result.stderr.decode(errors='replace').strip()}")
    return result.stdout


def public_der(pem):
    return command("openssl", "pkey", "-pubin", "-outform", "DER", input_bytes=pem)


def export(output_dir):
    repo_root = Path(__file__).resolve().parent.parent
    dest = Path(output_dir).expanduser().resolve()
    if dest == repo_root or repo_root in dest.parents:
        raise ValueError("Backup location must be outside the Git repository")

    # Restrict all newly created files and folders, regardless of the user's umask.
    os.umask(0o077)
    dest.mkdir(parents=True, exist_ok=True, mode=0o700)
    if dest.is_symlink():
        raise ValueError("Refusing symlink output directory")
    dest.chmod(0o700)

    payload = json.loads(
        command("kubectl", "-n", NAMESPACE, "get", "secret", SECRET, "-o", "json")
    )
    if payload.get("type") != "kubernetes.io/tls":
        raise ValueError("Unexpected Secret type; expected kubernetes.io/tls")
    encoded = payload.get("data") or {}
    try:
        cert = base64.b64decode(encoded["tls.crt"], validate=True)
        key = base64.b64decode(encoded["tls.key"], validate=True)
    except (KeyError, TypeError, binascii.Error) as exc:
        raise ValueError("CA Secret is missing valid TLS certificate or key data") from exc

    staging = Path(tempfile.mkdtemp(prefix="homelab-ca-", dir=dest))
    try:
        cert_file = staging / "tls.crt"
        key_file = staging / "tls.key"
        for name, blob in ((cert_file, cert), (key_file, key)):
            with name.open("xb") as f:
                f.write(blob)
                f.flush()
                os.fsync(f.fileno())
            name.chmod(0o600)

        # Parse both files and check they form a matching certificate/key pair.
        cert_public = command("openssl", "x509", "-in", str(cert_file), "-pubkey", "-noout")
        key_public = command("openssl", "pkey", "-in", str(key_file), "-pubout")
        if public_der(cert_public) != public_der(key_public):
            raise ValueError("CA certificate and private key do not match")

        fingerprint = command(
            "openssl", "x509", "-in", str(cert_file), "-noout", "-fingerprint", "-sha256"
        ).decode().strip()
        print(f"Saved CA certificate and matching private key under: {staging}")
        print(fingerprint)
        print("Keep this directory private; copy it to an independent offline backup.")
        return 0
    except Exception:
        shutil.rmtree(staging)
        raise


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output-dir", required=True,
        help="Directory OUTSIDE this repository, preferably on an independent backup disk",
    )
    args = parser.parse_args()
    try:
        sys.exit(export(args.output_dir))
    except (ValueError, RuntimeError, OSError, json.JSONDecodeError) as error:
        print(f"Backup failed: {error}", file=sys.stderr)
        sys.exit(1)

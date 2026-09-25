#!/usr/bin/env python3
"""Validate GitOps YAML, nested Helm values, and the non-recursive apps layout."""

import os
from pathlib import Path

import yaml
from yaml.constructor import ConstructorError


class UniqueKeyLoader(yaml.SafeLoader):
    """Reject duplicate YAML keys rather than silently overwriting values."""


def construct_mapping(loader, node, deep=False):
    mapping = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        try:
            present = key in mapping
        except TypeError as exc:
            raise ConstructorError(None, None, "unhashable mapping key", key_node.start_mark) from exc
        if present:
            raise ConstructorError(None, None, f"duplicate key: {key!r}", key_node.start_mark)
        mapping[key] = loader.construct_object(value_node, deep=deep)
    return mapping


UniqueKeyLoader.add_constructor(
    yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, construct_mapping
)


def parse_yaml(text, description):
    try:
        documents = list(yaml.load_all(text, Loader=UniqueKeyLoader))
    except yaml.YAMLError as exc:
        raise ValueError(f"{description}: invalid YAML: {exc}") from exc
    if not documents or any(not isinstance(doc, dict) for doc in documents):
        raise ValueError(f"{description}: expected one or more YAML mapping documents")
    return documents


def main():
    root = Path(__file__).resolve().parents[1]
    files = sorted(
        path
        for base in ("apps", "bootstrap", "infrastructure")
        for path in (root / base).rglob("*")
        if path.suffix in {".yaml", ".yml"} and path.is_file()
    )
    if not files:
        raise ValueError("No Kubernetes manifests found")

    resources = {}
    for path in files:
        relative = path.relative_to(root)
        docs = parse_yaml(path.read_text(encoding="utf-8"), str(relative))
        for doc in docs:
            for field in ("apiVersion", "kind", "metadata"):
                if field not in doc:
                    raise ValueError(f"{relative}: missing {field}")
            metadata = doc["metadata"]
            if not isinstance(metadata, dict) or not metadata.get("name"):
                raise ValueError(f"{relative}: missing metadata.name")
            resources.setdefault(str(relative), []).append(doc)
            if doc["kind"] == "Application":
                source = doc.get("spec", {}).get("source", {})
                helm_values = source.get("helm", {}).get("values")
                if helm_values is not None:
                    parse_yaml(helm_values, f"{relative} embedded Helm values")

    nested = [
        str(path.relative_to(root))
        for path in files
        if path.relative_to(root).parts[0] == "apps"
        and len(path.relative_to(root).parts) > 2
    ]
    if nested:
        raise ValueError(
            "The root Application targets apps/ without recurse=true; nested "
            f"manifests are not discovered: {nested}"
        )

    immich = next(
        (doc for doc in resources.get("apps/immich.yaml", [])
         if doc.get("kind") == "Application" and doc["metadata"]["name"] == "immich"),
        None,
    )
    if immich is None:
        raise ValueError("apps/immich.yaml: missing Immich Application")

    source = immich["spec"]["source"]
    helm_values = source["helm"]["values"]
    parsed_values = parse_yaml(helm_values, "Immich embedded Helm values")
    output_dir = Path(os.environ.get("RUNNER_TEMP", "/tmp"))
    output_dir.mkdir(parents=True, exist_ok=True)
    (output_dir / "immich-values.yaml").write_text(helm_values, encoding="utf-8")
    (output_dir / "immich-chart-uri.txt").write_text(
        f"oci://{source['repoURL'].removeprefix('oci://').rstrip('/')}/{source['chart']}",
        encoding="utf-8",
    )
    (output_dir / "immich-chart-version.txt").write_text(
        str(source["targetRevision"]), encoding="utf-8"
    )
    if not isinstance(parsed_values[0], dict):
        raise ValueError("Immich Helm values must be a mapping")

    print(f"Validated {len(files)} manifest files and embedded Helm values.")
    print("Root apps/ directory contains no undiscovered nested YAML manifests.")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Generate CloudronVersions.json (the community install channel) from the repo files.

Usage:
    tools/make-cloudron-versions.py <dockerImage@sha256:...>

It reads CloudronManifest.json, sets the digest-pinned dockerImage in BOTH the manifest and the
generated versions file, expands the file:// fields (description, changelog, postInstallMessage) to
their content, and writes a schema-valid CloudronVersions.json. Using Python's json module keeps the
escaping correct (the versions schema is stricter than the manifest: it needs a valid contactEmail, a
non-empty iconUrl, at least one mediaLinks entry, and a bracket-format changelog).

No third-party dependencies; uses only the standard library.
"""
import json
import os
import re
import sys
import time
from datetime import datetime, timezone

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def read(path):
    with open(os.path.join(ROOT, path), "r", encoding="utf-8") as f:
        return f.read()


def expand_file_fields(manifest):
    """Replace 'file://X' values with the content of X for the inlined manifest."""
    inlined = dict(manifest)
    for key in ("description", "changelog", "postInstallMessage"):
        val = inlined.get(key)
        if isinstance(val, str) and val.startswith("file://"):
            inlined[key] = read(val[len("file://"):])
    # icon stays as file://logo.png per the channel convention; iconUrl is the store-facing image.
    return inlined


def validate(inlined):
    errs = []
    if not inlined.get("contactEmail"):
        errs.append("contactEmail is required")
    if not inlined.get("iconUrl"):
        errs.append("iconUrl must be non-empty")
    if not inlined.get("mediaLinks"):
        errs.append("at least one mediaLinks entry is required")
    changelog = inlined.get("changelog", "")
    if not re.search(r"(?m)^\[\d+\.\d+\.\d+\]", changelog):
        errs.append("changelog must use bracket format, e.g. [1.0.0] at line start")
    if not str(inlined.get("dockerImage", "")).count("@sha256:"):
        errs.append("dockerImage must be pinned by @sha256 digest")
    if errs:
        sys.exit("CloudronVersions validation failed:\n  - " + "\n  - ".join(errs))


def main():
    if len(sys.argv) != 2 or "@sha256:" not in sys.argv[1]:
        sys.exit("usage: make-cloudron-versions.py <image@sha256:...>")
    docker_image = sys.argv[1]

    manifest = json.loads(read("CloudronManifest.json"))
    manifest["dockerImage"] = docker_image
    # Persist the digest into the manifest too (pin it in both places).
    with open(os.path.join(ROOT, "CloudronManifest.json"), "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2, ensure_ascii=False)
        f.write("\n")

    inlined = expand_file_fields(manifest)
    validate(inlined)

    now = datetime.now(timezone.utc)
    ts = int(now.timestamp() * 1000)
    version = manifest["version"]
    out = {
        "stable": True,
        "versions": {
            version: {
                "manifest": inlined,
                "creationDate": now.strftime("%Y-%m-%dT%H:%M:%S.") + f"{now.microsecond // 1000:03d}Z",
                "ts": ts,
                "publishState": "published",
            }
        },
    }
    with open(os.path.join(ROOT, "CloudronVersions.json"), "w", encoding="utf-8") as f:
        json.dump(out, f, indent=2, ensure_ascii=False)
        f.write("\n")
    print(f"wrote CloudronVersions.json for {version}")
    print(f"  dockerImage: {docker_image}")
    print(f"  manifest dockerImage pinned too")


if __name__ == "__main__":
    main()

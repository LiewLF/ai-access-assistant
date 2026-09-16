#!/usr/bin/env python3
"""Embed only CPA binaries built from the currently pinned evidence patches."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    runtime, destination, repository = map(Path, sys.argv[1:])
    vendor = repository / "ThirdParty/CPACollector"
    pinned = json.loads((vendor / "upstreams.json").read_text())
    receipt = json.loads((runtime / "build-receipt.json").read_text())
    expected = [{"name": item["name"], "commit": item["commit"],
                 "archiveSHA256": item["sourceArchiveSHA256"],
                 "patchSHA256": digest(vendor / item["patch"])} for item in pinned["components"]]
    if receipt.get("complete") is not True or receipt.get("components") != expected:
        raise RuntimeError("CPA runtime does not match pinned sources and current patches")
    artifacts = ["bin/cli-proxy-api", "plugins/cpa-quota-estimator.dylib"]
    for name in artifacts:
        source = runtime / name
        if source.is_symlink() or digest(source) != receipt["artifacts"].get(name):
            raise RuntimeError("CPA artifact identity changed: " + name)
        if subprocess.check_output(["lipo", "-archs", str(source)], text=True).strip() != "arm64":
            raise RuntimeError("CPA collector requires arm64")
    destination.mkdir(parents=True, exist_ok=False)
    for name in artifacts:
        target = destination / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(runtime / name, target)
        target.chmod(0o755)
        subprocess.run(["codesign", "--force", "--sign", "-", str(target)], check=True)
        subprocess.run(["codesign", "--verify", "--strict", str(target)], check=True)
    shutil.copy2(runtime / "build-receipt.json", destination / "build-receipt.json")
    for source in vendor.iterdir():
        if source.is_file():
            shutil.copy2(source, destination / source.name)
    print("CPA_COLLECTOR_EMBED=PASS sources=current_pinned_patches architecture=arm64 signature=ad-hoc")


if __name__ == "__main__":
    main()

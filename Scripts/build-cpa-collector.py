#!/usr/bin/env python3
"""Build pinned CPA archives plus local evidence patches; never downloads or logs in."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tarfile
import time


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--go", type=Path, required=True)
    parser.add_argument("--cpa-archive", type=Path, required=True)
    parser.add_argument("--quota-archive", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--cache-root", type=Path, required=True)
    args = parser.parse_args()
    vendor = Path(__file__).resolve().parent.parent / "ThirdParty/CPACollector"
    pinned = json.loads((vendor / "upstreams.json").read_text())
    version = subprocess.check_output([args.go, "version"], text=True).strip()
    if version != "go version " + pinned["go"]["version"] + " darwin/arm64":
        raise RuntimeError("pinned Go darwin/arm64 toolchain required")
    args.output.mkdir(parents=True, exist_ok=False)
    for name in ("bin", "plugins", "logs", "sources"):
        (args.output / name).mkdir()
    environment = dict(os.environ, GOTOOLCHAIN="local", GOMAXPROCS="2", CGO_ENABLED="1",
                       GOCACHE=str(args.cache_root / "build-cache"),
                       GOMODCACHE=str(args.cache_root / "module-cache"),
                       GOPATH=str(args.cache_root / "gopath"))
    receipt = {"schemaVersion": 1, "complete": False, "go": version, "components": [], "stages": []}

    def save():
        (args.output / "build-receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")

    def run(name, command, cwd):
        start = time.monotonic()
        with (args.output / "logs" / (name + ".log")).open("xb") as log:
            result = subprocess.run(command, cwd=cwd, env=environment,
                                    stdout=log, stderr=subprocess.STDOUT)
        stage = {"name": name, "exitCode": result.returncode,
                 "elapsedSeconds": round(time.monotonic() - start, 2)}
        receipt["stages"].append(stage)
        save()
        print(json.dumps(stage), flush=True)
        if result.returncode:
            raise RuntimeError("first failed stage: " + name + "; raw log retained")

    for component, archive in zip(pinned["components"], [args.cpa_archive, args.quota_archive]):
        if digest(archive) != component["sourceArchiveSHA256"]:
            raise RuntimeError("source archive identity mismatch: " + component["name"])
        source = args.output / "sources" / component["name"]
        source.mkdir()
        with tarfile.open(archive) as bundle:
            for member in bundle.getmembers():
                parts = Path(member.name).parts[1:]
                if not parts:
                    continue
                if member.name.startswith("/") or ".." in parts or member.issym() or member.islnk():
                    raise RuntimeError("unsafe archive member")
                destination = source.joinpath(*parts)
                if member.isdir():
                    destination.mkdir(parents=True, exist_ok=True)
                elif member.isfile():
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    destination.write_bytes(bundle.extractfile(member).read())
        patch = vendor / component["patch"]
        receipt["components"].append({"name": component["name"], "commit": component["commit"],
                                      "archiveSHA256": digest(archive), "patchSHA256": digest(patch)})
        run("patch-" + component["name"], ["/usr/bin/patch", "--batch", "-p1", "-i", str(patch)], source)
        common = [str(args.go), "build", "-p=2", "-mod=readonly", "-trimpath", "-buildvcs=false"]
        if component["name"] == "CLIProxyAPI":
            run("build-cpa", common + ["-ldflags=-s -w -X main.Version=7.2.151-cpa-evidence2"
                " -X main.Commit=5208aec7+metadata", "-o", str(args.output / "bin/cli-proxy-api"),
                "./cmd/server"], source)
        else:
            run("build-quota", common + ["-buildmode=c-shared",
                "-ldflags=-s -w -X main.pluginVersion=0.8.0-cpa-evidence2", "-o",
                str(args.output / "plugins/cpa-quota-estimator.dylib"), "."], source)
    receipt["artifacts"] = {name: digest(args.output / name) for name in
                            ["bin/cli-proxy-api", "plugins/cpa-quota-estimator.dylib"]}
    receipt["complete"] = True
    save()
    print("CPA_COLLECTOR_BUILD=PASS", flush=True)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import pathlib
import platform
import plistlib
import re
import stat
import subprocess
import sys
from typing import Any


ROOT = pathlib.Path(__file__).resolve().parent.parent
BUILD_ROOT = ROOT / "build"
LATEST_RECEIPT = BUILD_ROOT / "source-build-verification.json"
EXPECTED_FAST_STATUS = "FAST_UNVERIFIED"


class VerificationError(Exception):
    def __init__(self, stage: str, reason: str, exit_code: int = 1, unsupported: bool = False) -> None:
        super().__init__(reason)
        self.stage = stage
        self.reason = reason
        self.exit_code = exit_code
        self.unsupported = unsupported


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def relative(path: pathlib.Path) -> str:
    return path.relative_to(ROOT).as_posix()


def atomic_json(path: pathlib.Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.tmp-{os.getpid()}")
    temporary.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    os.replace(temporary, path)


def source_fingerprint() -> tuple[int, str]:
    digest = hashlib.sha256()
    count = 0
    for path in sorted(ROOT.rglob("*")):
        rel = path.relative_to(ROOT)
        if not rel.parts or rel.parts[0] in {".git", "build"}:
            continue
        if path.is_symlink():
            raise VerificationError("preflight", f"source-symlink-forbidden:{rel.as_posix()}")
        if not path.is_file():
            continue
        entry = {
            "mode": format(stat.S_IMODE(path.stat().st_mode), "04o"),
            "path": rel.as_posix(),
            "sha256": sha256_file(path),
            "size": path.stat().st_size,
        }
        digest.update(json.dumps(entry, sort_keys=True, separators=(",", ":")).encode("utf-8"))
        digest.update(b"\n")
        count += 1
    return count, digest.hexdigest()


def capture(command: list[str], environment: dict[str, str] | None = None, stage: str = "preflight") -> str:
    result = subprocess.run(
        command,
        cwd=ROOT,
        env=environment,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        errors="replace",
        check=False,
    )
    if result.returncode != 0:
        raise VerificationError(stage, f"command-failed:{pathlib.Path(command[0]).name}", result.returncode)
    return result.stdout.strip()


def require(condition: bool, stage: str, reason: str, unsupported: bool = False) -> None:
    if not condition:
        raise VerificationError(stage, reason, 2 if unsupported else 1, unsupported)


def parse_version(value: str) -> tuple[int, ...]:
    match = re.match(r"^(\d+(?:\.\d+)*)", value)
    require(match is not None, "preflight", f"version-invalid:{value}")
    return tuple(int(part) for part in match.group(1).split("."))


def locked_rust_version() -> str:
    text = (ROOT / "SessionCore" / "rust-toolchain.toml").read_text(encoding="utf-8")
    match = re.search(r'^channel\s*=\s*"([^"]+)"', text, re.MULTILINE)
    require(match is not None, "preflight", "rust-toolchain-channel-missing")
    return match.group(1)


def initial_receipt(run_id: str, started_at: str, offline: bool) -> dict[str, Any]:
    return {
        "schema_version": 1,
        "verification": "public-source-build",
        "run_id": run_id,
        "started_at": started_at,
        "finished_at": None,
        "result": "running",
        "failure": None,
        "source": {},
        "environment": {},
        "build": {
            "target_architecture": "arm64",
            "dependency_mode": "offline-locked" if offline else "online-locked",
            "command": "AI_ACCESS_TARGET_ARCH=arm64 AI_ACCESS_BUILD_ROOT=<run-root> ./build.sh",
        },
        "artifacts": None,
        "platforms": {
            "macos_arm64_source_build": "not_run",
            "macos_x86_64_source_build": "unverified",
            "windows_11_x64_source_build": "unverified",
            "package": "not_run",
            "install": "not_run",
            "launch": "not_run",
            "gatekeeper": "not_run",
            "fast_status": EXPECTED_FAST_STATUS,
        },
    }


def record_log(receipt: dict[str, Any], log_path: pathlib.Path) -> None:
    if log_path.is_file():
        receipt["build"]["log"] = relative(log_path)
        receipt["build"]["log_bytes"] = log_path.stat().st_size
        receipt["build"]["log_sha256"] = sha256_file(log_path)


def write_receipts(run_receipt: pathlib.Path, receipt: dict[str, Any]) -> None:
    atomic_json(run_receipt, receipt)
    atomic_json(LATEST_RECEIPT, receipt)


def run_build(command: list[str], environment: dict[str, str], log_path: pathlib.Path) -> int:
    with log_path.open("w", encoding="utf-8") as log:
        process = subprocess.Popen(
            command,
            cwd=ROOT,
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            errors="replace",
        )
        assert process.stdout is not None
        for line in process.stdout:
            log.write(line)
            log.flush()
            sys.stdout.write(line)
            sys.stdout.flush()
        return process.wait()


def verify_artifacts(app: pathlib.Path, public_bundle_id: str, environment: dict[str, str]) -> dict[str, Any]:
    info_path = app / "Contents" / "Info.plist"
    executable = app / "Contents" / "MacOS" / "ConfigAdvisor"
    helper = app / "Contents" / "Helpers" / "ai-access-session-core"
    for path in (info_path, executable, helper):
        require(path.is_file(), "artifact_audit", f"artifact-missing:{path.relative_to(app).as_posix()}")
    info = plistlib.loads(info_path.read_bytes())
    require(info.get("CFBundleIdentifier") == public_bundle_id, "artifact_audit", "artifact-public-identity-mismatch")
    main_arches = capture(["/usr/bin/lipo", "-archs", str(executable)], environment, "artifact_audit").split()
    helper_arches = capture(["/usr/bin/lipo", "-archs", str(helper)], environment, "artifact_audit").split()
    require(main_arches == ["arm64"], "artifact_audit", f"artifact-main-architectures:{main_arches}")
    require(helper_arches == ["arm64"], "artifact_audit", f"artifact-helper-architectures:{helper_arches}")
    capture(["/usr/bin/codesign", "--verify", "--strict", str(helper)], environment, "artifact_audit")
    capture(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], environment, "artifact_audit")
    signature = capture(["/usr/bin/codesign", "-dv", "--verbose=4", str(app)], environment, "artifact_audit")
    require("Signature=adhoc" in signature, "artifact_audit", "artifact-signature-not-adhoc")
    return {
        "app": relative(app),
        "bundle_id": public_bundle_id,
        "main_architectures": main_arches,
        "session_core_architectures": helper_arches,
        "main_sha256": sha256_file(executable),
        "session_core_sha256": sha256_file(helper),
        "codesign": "adhoc_verified",
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Build macOS arm64 public source and write an auditable receipt.")
    parser.add_argument("--offline", action="store_true", help="Require Cargo to use its existing local cache.")
    args = parser.parse_args()
    started_at = utc_now()
    run_id = started_at.replace(":", "").replace("-", "") + f"-{os.getpid()}"
    run_root = BUILD_ROOT / "source-build-runs" / run_id
    run_root.mkdir(parents=True, exist_ok=False)
    log_path = run_root / "build.log"
    stage_path = run_root / "stage.txt"
    run_receipt = run_root / "receipt.json"
    receipt = initial_receipt(run_id, started_at, args.offline)
    try:
        require(platform.system() == "Darwin", "platform", "supported-platform-required:macOS", unsupported=True)
        require(platform.machine() == "arm64", "platform", "supported-architecture-required:arm64", unsupported=True)
        status = json.loads((ROOT / "PUBLIC-RELEASE-STATUS.json").read_text(encoding="utf-8"))
        info = plistlib.loads((ROOT / "Info.plist").read_bytes())
        require(status.get("fast_status") == EXPECTED_FAST_STATUS, "preflight", "fast-status-requires-observable-receipt")
        minimum_macos = str(info["LSMinimumSystemVersion"])
        macos_version = capture(["/usr/bin/sw_vers", "-productVersion"])
        require(parse_version(macos_version) >= parse_version(minimum_macos), "platform", f"macos-version-required:{minimum_macos}", unsupported=True)
        file_count, tree_sha256 = source_fingerprint()
        receipt["source"] = {
            "release": status["release"],
            "product_version": str(info["CFBundleShortVersionString"]),
            "product_build": str(info["CFBundleVersion"]),
            "bundle_id": str(info["CFBundleIdentifier"]),
            "input_file_count": file_count,
            "input_tree_sha256": tree_sha256,
        }
        receipt["environment"] = {
            "platform": "macOS",
            "os_version": macos_version,
            "architecture": platform.machine(),
            "python": platform.python_version(),
        }
        rust_version = locked_rust_version()
        cargo_home = pathlib.Path(os.environ.get("AI_ACCESS_CARGO_HOME", BUILD_ROOT / "cargo"))
        rustup_home = pathlib.Path(os.environ.get("AI_ACCESS_RUSTUP_HOME", BUILD_ROOT / "rustup"))
        cargo = pathlib.Path(os.environ.get("AI_ACCESS_CARGO", cargo_home / "bin" / "cargo"))
        rustc = pathlib.Path(os.environ.get("AI_ACCESS_RUSTC", cargo.parent / "rustc"))
        require(os.access(cargo, os.X_OK) and os.access(rustc, os.X_OK), "preflight", "locked-rust-toolchain-missing:run-Scripts/bootstrap-rust-toolchain.sh")
        environment = os.environ.copy()
        environment.update(
            {
                "AI_ACCESS_BUILD_ROOT": str(run_root),
                "AI_ACCESS_BUILD_STAGE_FILE": str(stage_path),
                "AI_ACCESS_CARGO": str(cargo),
                "AI_ACCESS_CARGO_HOME": str(cargo_home),
                "AI_ACCESS_RUSTUP_HOME": str(rustup_home),
                "AI_ACCESS_RUST_TARGET_DIR": str(run_root / "rust-target"),
                "AI_ACCESS_TARGET_ARCH": "arm64",
                "AI_ACCESS_TEMP_PACKAGE": "0",
                "CARGO_HOME": str(cargo_home),
                "RUSTUP_HOME": str(rustup_home),
            }
        )
        if args.offline:
            environment["CARGO_NET_OFFLINE"] = "true"
        else:
            environment.pop("CARGO_NET_OFFLINE", None)
        cargo_output = capture([str(cargo), "--version"], environment).splitlines()[0]
        rustc_output = capture([str(rustc), "--version"], environment).splitlines()[0]
        require(cargo_output.startswith(f"cargo {rust_version} "), "preflight", f"cargo-version-mismatch:expected={rust_version}:actual={cargo_output}")
        require(rustc_output.startswith(f"rustc {rust_version} "), "preflight", f"rustc-version-mismatch:expected={rust_version}:actual={rustc_output}")
        swiftc = capture(["/usr/bin/xcrun", "--find", "swiftc"], environment)
        swift_version = capture([swiftc, "--version"], environment).splitlines()[0]
        receipt["environment"].update({"swift": swift_version, "cargo": cargo_output, "rustc": rustc_output})
        receipt["build"]["run_root"] = relative(run_root)
        exit_code = run_build([str(ROOT / "build.sh")], environment, log_path)
        receipt["build"]["exit_code"] = exit_code
        record_log(receipt, log_path)
        if exit_code != 0:
            stage = stage_path.read_text(encoding="utf-8").strip() if stage_path.is_file() else "build"
            raise VerificationError(stage or "build", f"build.sh-exit:{exit_code}", exit_code)
        receipt["artifacts"] = verify_artifacts(run_root / "AI接入助手.app", str(info["CFBundleIdentifier"]), environment)
        receipt["result"] = "passed"
        receipt["platforms"]["macos_arm64_source_build"] = "passed"
        receipt["finished_at"] = utc_now()
        write_receipts(run_receipt, receipt)
        print(f"PUBLIC_SOURCE_BUILD=PASS receipt={relative(LATEST_RECEIPT)} macos_arm64=passed windows_11_x64=unverified fast={EXPECTED_FAST_STATUS}")
        return 0
    except (OSError, KeyError, ValueError, json.JSONDecodeError, plistlib.InvalidFileException, VerificationError) as error:
        failure = error if isinstance(error, VerificationError) else VerificationError("internal", f"{type(error).__name__}:{error}")
        record_log(receipt, log_path)
        receipt["result"] = "unsupported" if failure.unsupported else "failed"
        receipt["failure"] = {"stage": failure.stage, "reason": failure.reason, "exit_code": failure.exit_code}
        if platform.system() == "Darwin" and platform.machine() == "arm64" and not failure.unsupported:
            receipt["platforms"]["macos_arm64_source_build"] = "failed"
        receipt["finished_at"] = utc_now()
        write_receipts(run_receipt, receipt)
        label = "UNSUPPORTED" if failure.unsupported else "FAIL"
        print(f"PUBLIC_SOURCE_BUILD={label} stage={failure.stage} reason={failure.reason} receipt={relative(LATEST_RECEIPT)}", file=sys.stderr)
        return failure.exit_code if 0 < failure.exit_code < 256 else 1


if __name__ == "__main__":
    raise SystemExit(main())

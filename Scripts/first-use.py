#!/usr/bin/env python3
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import pathlib
import platform
import plistlib
import re
import subprocess
import sys
from typing import Any


ROOT = pathlib.Path(__file__).resolve().parent.parent
BUILD_ROOT = ROOT / "build"
DIAGNOSTIC = BUILD_ROOT / "first-use-diagnostic.json"
VERIFIER_RECEIPT = BUILD_ROOT / "source-build-verification.json"

ACTIONS: dict[str, dict[str, str | None]] = {
    "install-command-line-tools": {
        "code": "install-command-line-tools",
        "title": "安装 Apple Command Line Tools，然后重新运行本入口",
        "command": "xcode-select --install",
    },
    "use-supported-mac": {
        "code": "use-supported-mac",
        "title": "改用 macOS 15 或更高版本的 Apple Silicon Mac",
        "command": None,
    },
    "prepare-dependencies": {
        "code": "prepare-dependencies",
        "title": "联网后重新运行本入口以获取锁定依赖",
        "command": "python3 Scripts/first-use.py",
    },
    "share-diagnostic": {
        "code": "share-diagnostic",
        "title": "把 build/first-use-diagnostic.json 交给维护者",
        "command": None,
    },
}


class FirstUseError(Exception):
    def __init__(self, stage: str, reason_code: str, action: str) -> None:
        super().__init__(reason_code)
        self.stage = stage
        self.reason_code = reason_code
        self.action = action


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def atomic_json(path: pathlib.Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.tmp-{os.getpid()}")
    temporary.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    os.replace(temporary, path)


def relative(path: pathlib.Path) -> str:
    return path.resolve().relative_to(ROOT.resolve()).as_posix()


def parse_version(value: str) -> tuple[int, ...]:
    match = re.match(r"^(\d+(?:\.\d+)*)", value)
    if match is None:
        raise FirstUseError("version_incompatible", "macos-version-unreadable", "use-supported-mac")
    return tuple(int(part) for part in match.group(1).split("."))


def output(command: list[str], environment: dict[str, str] | None = None) -> str:
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
        raise FirstUseError("missing_tools", "apple-command-line-tools-unavailable", "install-command-line-tools")
    return result.stdout.strip()


def run_logged(command: list[str], log_path: pathlib.Path, environment: dict[str, str]) -> int:
    with log_path.open("w", encoding="utf-8") as log:
        return subprocess.run(
            command,
            cwd=ROOT,
            env=environment,
            stdout=log,
            stderr=subprocess.STDOUT,
            check=False,
        ).returncode


def locked_rust_version() -> str:
    text = (ROOT / "SessionCore" / "rust-toolchain.toml").read_text(encoding="utf-8")
    match = re.search(r'^channel\s*=\s*"([^"]+)"', text, re.MULTILINE)
    if match is None:
        raise FirstUseError("version_incompatible", "locked-rust-version-missing", "share-diagnostic")
    return match.group(1)


def rust_paths(environment: dict[str, str]) -> tuple[pathlib.Path, pathlib.Path]:
    cargo_home = pathlib.Path(environment.get("AI_ACCESS_CARGO_HOME", BUILD_ROOT / "cargo"))
    cargo = pathlib.Path(environment.get("AI_ACCESS_CARGO", cargo_home / "bin" / "cargo"))
    rustc = pathlib.Path(environment.get("AI_ACCESS_RUSTC", cargo.parent / "rustc"))
    return cargo, rustc


def rust_matches(version: str, environment: dict[str, str]) -> bool:
    cargo, rustc = rust_paths(environment)
    if not os.access(cargo, os.X_OK) or not os.access(rustc, os.X_OK):
        return False
    checks = ((cargo, f"cargo {version} "), (rustc, f"rustc {version} "))
    for executable, prefix in checks:
        result = subprocess.run(
            [str(executable), "--version"],
            cwd=ROOT,
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            check=False,
        )
        if result.returncode != 0 or not result.stdout.startswith(prefix):
            return False
    return True


def preflight(offline: bool, run_root: pathlib.Path, environment: dict[str, str]) -> dict[str, Any]:
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise FirstUseError("version_incompatible", "macos-arm64-required", "use-supported-mac")
    info = plistlib.loads((ROOT / "Info.plist").read_bytes())
    minimum_macos = str(info["LSMinimumSystemVersion"])
    macos_version = output(["/usr/bin/sw_vers", "-productVersion"], environment)
    if parse_version(macos_version) < parse_version(minimum_macos):
        raise FirstUseError("version_incompatible", "minimum-macos-not-met", "use-supported-mac")
    for executable in ("/usr/bin/xcrun", "/usr/bin/codesign", "/usr/bin/lipo", "/bin/zsh"):
        if not os.access(executable, os.X_OK):
            raise FirstUseError("missing_tools", "apple-command-line-tools-unavailable", "install-command-line-tools")
    swiftc = output(["/usr/bin/xcrun", "--find", "swiftc"], environment)
    output([swiftc, "--version"], environment)
    cargo_home = pathlib.Path(environment.get("AI_ACCESS_CARGO_HOME", BUILD_ROOT / "cargo"))
    rustup_home = pathlib.Path(environment.get("AI_ACCESS_RUSTUP_HOME", BUILD_ROOT / "rustup"))
    environment["CARGO_HOME"] = str(cargo_home)
    environment["RUSTUP_HOME"] = str(rustup_home)
    version = locked_rust_version()
    if not rust_matches(version, environment):
        if offline:
            raise FirstUseError("dependency_acquisition", "locked-rust-toolchain-not-cached", "prepare-dependencies")
        dependency_log = run_root / "dependency-acquisition.log"
        exit_code = run_logged([str(ROOT / "Scripts" / "bootstrap-rust-toolchain.sh")], dependency_log, environment)
        if exit_code != 0:
            raise FirstUseError("dependency_acquisition", "locked-rust-toolchain-download-failed", "prepare-dependencies")
        if not rust_matches(version, environment):
            raise FirstUseError("version_incompatible", "locked-rust-version-mismatch", "share-diagnostic")
    return {
        "platform": "macOS",
        "architecture": "arm64",
        "os_version": macos_version,
        "minimum_macos": minimum_macos,
        "rust_toolchain": version,
        "swift": output([swiftc, "--version"], environment).splitlines()[0],
        "dependency_mode": "offline-locked" if offline else "online-locked",
    }


def dependency_failure(log_path: pathlib.Path) -> bool:
    text = log_path.read_text(encoding="utf-8", errors="replace").lower()
    markers = (
        "failed to download",
        "failed to fetch",
        "failed to get",
        "could not resolve host",
        "network failure",
        "timeout was reached",
        "no matching package named",
    )
    return any(marker in text for marker in markers)


def mapped_failure(raw: dict[str, Any], log_path: pathlib.Path) -> FirstUseError:
    failure = raw.get("failure") if isinstance(raw, dict) else None
    raw_stage = failure.get("stage") if isinstance(failure, dict) else None
    if raw_stage == "rust_session_core" and dependency_failure(log_path):
        return FirstUseError("dependency_acquisition", "locked-dependency-fetch-failed", "prepare-dependencies")
    mapping = {
        "platform": ("version_incompatible", "supported-host-required", "use-supported-mac"),
        "preflight": ("version_incompatible", "source-or-tool-version-mismatch", "share-diagnostic"),
        "assemble_app": ("artifact_location", "app-assembly-failed", "share-diagnostic"),
        "rust_session_core": ("rust_build", "rust-build-failed", "share-diagnostic"),
        "swift_compile": ("swift_build", "swift-build-failed", "share-diagnostic"),
        "codesign": ("signing", "ad-hoc-signing-failed", "share-diagnostic"),
        "finalize_app": ("artifact_location", "app-finalization-failed", "share-diagnostic"),
        "artifact_audit": ("artifact_location", "built-app-audit-failed", "share-diagnostic"),
    }
    stage, reason, action = mapping.get(str(raw_stage), ("source_build", "source-build-failed", "share-diagnostic"))
    return FirstUseError(stage, reason, action)


def first_use_steps(app: str) -> dict[str, Any]:
    return {
        "app": app,
        "automatic_install": False,
        "automatic_launch": False,
        "gatekeeper": "若 macOS 阻止启动，停止；不要运行 xattr、不要关闭或降低系统安全设置。ad-hoc 不等于 Developer ID 或公证。",
        "steps": [
            "在 Finder 定位 receipt 记录的 App，并由你决定是否首次打开。",
            "首页“首次使用”先点“读取当前状态”；该步不改 Codex 配置、不联网。",
            "按首页唯一主动作确认基础连接；需要联网时 App 会再次确认。",
            "只有需要时再确认“验证真实任务”；可能计入官方额度或中转费用。",
            "失败时进入“高级诊断 > Codex诊断”；结果只给一个首要动作，也可导出脱敏求助包。",
        ],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Preflight, build, locate, and explain first use for macOS arm64 source users.")
    parser.add_argument("--offline", action="store_true", help="Use only cached locked Rust dependencies.")
    args = parser.parse_args()
    started_at = utc_now()
    run_id = started_at.replace(":", "").replace("-", "") + f"-{os.getpid()}"
    run_root = BUILD_ROOT / "first-use-runs" / run_id
    run_root.mkdir(parents=True, exist_ok=False)
    verifier_log = run_root / "source-build.log"
    environment = os.environ.copy()
    receipt: dict[str, Any] = {
        "schema_version": 1,
        "workflow": "public-source-first-use",
        "started_at": started_at,
        "finished_at": None,
        "result": "running",
        "preflight": None,
        "failure": None,
        "primary_action": None,
        "build": {"engine": "Scripts/verify-source-build.py", "raw_log": relative(verifier_log), "raw_log_shareable": False},
        "artifact": None,
        "first_use": None,
        "redaction": {
            "shareable": True,
            "excludes": ["username", "absolute_home_path", "token", "endpoint", "configuration_value", "prompt", "response", "project_content", "raw_log"],
        },
        "boundaries": {"config_write": False, "automatic_network_validation": False, "install": False, "launch": False, "ui_acceptance": False, "real_task": False, "public_binary": False},
    }
    try:
        receipt["preflight"] = preflight(args.offline, run_root, environment)
        command = [sys.executable, str(ROOT / "Scripts" / "verify-source-build.py")]
        if args.offline:
            command.append("--offline")
        exit_code = run_logged(command, verifier_log, environment)
        raw = json.loads(VERIFIER_RECEIPT.read_text(encoding="utf-8")) if VERIFIER_RECEIPT.is_file() else {}
        if exit_code != 0 or raw.get("result") != "passed":
            raise mapped_failure(raw, verifier_log)
        artifacts = raw.get("artifacts")
        if not isinstance(artifacts, dict) or not isinstance(artifacts.get("app"), str):
            raise FirstUseError("artifact_location", "built-app-location-missing", "share-diagnostic")
        app = ROOT / artifacts["app"]
        if not app.is_dir() or ROOT.resolve() not in app.resolve().parents:
            raise FirstUseError("artifact_location", "built-app-location-invalid", "share-diagnostic")
        app_relative = relative(app)
        receipt["artifact"] = {
            "app": app_relative,
            "bundle_id": artifacts.get("bundle_id"),
            "architectures": artifacts.get("main_architectures"),
            "codesign": artifacts.get("codesign"),
        }
        receipt["first_use"] = first_use_steps(app_relative)
        receipt["result"] = "passed"
    except FirstUseError as error:
        receipt["result"] = "failed"
        receipt["failure"] = {"stage": error.stage, "reason_code": error.reason_code}
        receipt["primary_action"] = ACTIONS[error.action]
    except (OSError, KeyError, ValueError, json.JSONDecodeError, plistlib.InvalidFileException):
        receipt["result"] = "failed"
        receipt["failure"] = {"stage": "internal", "reason_code": "unexpected-local-error"}
        receipt["primary_action"] = ACTIONS["share-diagnostic"]
    receipt["finished_at"] = utc_now()
    atomic_json(DIAGNOSTIC, receipt)
    if receipt["result"] == "passed":
        print(f"PUBLIC_SOURCE_FIRST_USE=PASS app={receipt['artifact']['app']} receipt={relative(DIAGNOSTIC)}")
        print("NEXT=在 Finder 定位 App；启动后按首页‘首次使用’唯一主动作继续。")
        return 0
    failure = receipt["failure"]
    action = receipt["primary_action"]
    print(
        f"PUBLIC_SOURCE_FIRST_USE=FAIL stage={failure['stage']} reason={failure['reason_code']} "
        f"action={action['code']} receipt={relative(DIAGNOSTIC)}",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    raise SystemExit(main())

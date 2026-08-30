#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
TARGET_ARCH="${AI_ACCESS_TARGET_ARCH:-native}"
RUSTUP_HOME="${AI_ACCESS_RUSTUP_HOME:-$ROOT/build/rustup}"
CARGO_HOME="${AI_ACCESS_CARGO_HOME:-$ROOT/build/cargo}"
CARGO="${AI_ACCESS_CARGO:-$CARGO_HOME/bin/cargo}"
TARGET_ROOT="${AI_ACCESS_RUST_TARGET_DIR:-$ROOT/build/rust-target}"
SYSTEM_CC=/usr/bin/clang
SYSTEM_CXX=/usr/bin/clang++

if [[ ! -x "$SYSTEM_CC" || ! -x "$SYSTEM_CXX" ]]; then
  echo "Apple system compiler is unavailable" >&2
  exit 1
fi

if [[ ! -x "$CARGO" ]]; then
  "$ROOT/Scripts/bootstrap-rust-toolchain.sh" >/dev/null
fi

case "$TARGET_ARCH" in
  native)
    rust_target=""
    ;;
  arm64)
    rust_target="aarch64-apple-darwin"
    ;;
  x86_64)
    rust_target="x86_64-apple-darwin"
    ;;
  *)
    echo "unsupported SessionCore architecture: $TARGET_ARCH" >&2
    exit 1
    ;;
esac

arguments=(
  build
  --release
  --locked
  --manifest-path
  "$ROOT/SessionCore/Cargo.toml"
)
if [[ -n "$rust_target" ]]; then
  arguments+=(--target "$rust_target")
fi

RUSTUP_HOME="$RUSTUP_HOME" \
  CARGO_HOME="$CARGO_HOME" \
  CARGO_TARGET_DIR="$TARGET_ROOT" \
  CC="$SYSTEM_CC" \
  CXX="$SYSTEM_CXX" \
  CARGO_TARGET_AARCH64_APPLE_DARWIN_LINKER="$SYSTEM_CC" \
  CARGO_TARGET_X86_64_APPLE_DARWIN_LINKER="$SYSTEM_CC" \
  "$CARGO" "${arguments[@]}"

if [[ -n "$rust_target" ]]; then
  binary="$TARGET_ROOT/$rust_target/release/ai-access-session-core"
else
  binary="$TARGET_ROOT/release/ai-access-session-core"
fi

[[ -x "$binary" ]]
echo "$binary"

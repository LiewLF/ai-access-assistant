#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
TOOLCHAIN_VERSION=$(
  awk -F'"' '/^channel[[:space:]]*=/{print $2; exit}' \
    "$ROOT/SessionCore/rust-toolchain.toml"
)
RUSTUP_HOME="${AI_ACCESS_RUSTUP_HOME:-$ROOT/build/rustup}"
CARGO_HOME="${AI_ACCESS_CARGO_HOME:-$ROOT/build/cargo}"
CARGO="$CARGO_HOME/bin/cargo"
RUSTUP="$CARGO_HOME/bin/rustup"

if [[ -x "$CARGO" && -x "$RUSTUP" ]]; then
  installed=$(
    RUSTUP_HOME="$RUSTUP_HOME" \
      CARGO_HOME="$CARGO_HOME" \
      "$RUSTUP" run "$TOOLCHAIN_VERSION" rustc --version 2>/dev/null \
      || true
  )
  if [[ "$installed" == *"rustc $TOOLCHAIN_VERSION"* ]]; then
    RUSTUP_HOME="$RUSTUP_HOME" \
      CARGO_HOME="$CARGO_HOME" \
      "$RUSTUP" component add \
        --toolchain "$TOOLCHAIN_VERSION" \
        rustfmt \
        clippy >/dev/null
    echo "$CARGO"
    exit 0
  fi
fi

mkdir -p "$RUSTUP_HOME" "$CARGO_HOME" "$ROOT/build"
installer=$(mktemp /private/tmp/ai-access-rustup-init.XXXXXX)
cleanup() {
  rm -f "$installer"
}
trap cleanup EXIT

curl \
  --fail \
  --show-error \
  --silent \
  --location \
  --proto '=https' \
  --tlsv1.2 \
  https://sh.rustup.rs \
  --output "$installer"

RUSTUP_HOME="$RUSTUP_HOME" \
  CARGO_HOME="$CARGO_HOME" \
  sh "$installer" \
    -y \
    --no-modify-path \
    --profile minimal \
    --component rustfmt \
    --component clippy \
    --default-toolchain "$TOOLCHAIN_VERSION"

RUSTUP_HOME="$RUSTUP_HOME" \
  CARGO_HOME="$CARGO_HOME" \
  "$RUSTUP" run "$TOOLCHAIN_VERSION" rustc --version
echo "$CARGO"

#!/usr/bin/env bash
# Verify host GLIBC/GLIBCXX/CXXABI and target GLIBC symbol versions.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PREFIX=""
MODE=""
HOST_GLIBC_MAX="2.28"
HOST_GLIBCXX_MAX="3.4.25"
HOST_CXXABI_MAX="1.3.11"
TARGET_GLIBC_MAX="2.36"
TARGET_ABI_TMPDIR=""

cleanup_target_abi_tmpdir() {
  if [[ -n "${TARGET_ABI_TMPDIR:-}" ]]; then
    rm -rf "$TARGET_ABI_TMPDIR"
  fi
}

trap cleanup_target_abi_tmpdir EXIT

usage() {
  cat <<'EOT'
用法: scripts/check-toolchain-abi.sh --prefix DIR --mode newlib|linux|musl [选项]

  --host-glibc-max V    宿主 ELF 允许的最高 GLIBC 版本（默认 2.28）
  --host-glibcxx-max V  宿主 ELF 允许的最高 GLIBCXX 版本（默认 3.4.25）
  --host-cxxabi-max V   宿主 ELF 允许的最高 CXXABI 版本（默认 1.3.11）
  --target-glibc-max V  linux 目标 ELF 允许的最高 GLIBC 版本（默认 2.36）
EOT
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix) PREFIX="$2"; shift 2 ;;
    --mode) MODE="$2"; shift 2 ;;
    --host-glibc-max) HOST_GLIBC_MAX="$2"; shift 2 ;;
    --host-glibcxx-max) HOST_GLIBCXX_MAX="$2"; shift 2 ;;
    --host-cxxabi-max) HOST_CXXABI_MAX="$2"; shift 2 ;;
    --target-glibc-max) TARGET_GLIBC_MAX="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数: $1" >&2; usage; exit 1 ;;
  esac
done

[[ -n "$PREFIX" ]] || { usage; exit 1; }
[[ -d "$PREFIX/bin" ]] || { echo "找不到 $PREFIX/bin" >&2; exit 1; }

version_le() { # $1 <= $2
  [[ "$1" == "$2" ]] && return 0
  [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n 1)" == "$1" ]]
}

check_host_abi() {
  bash "$SCRIPT_DIR/check-host-abi.sh" \
    --prefix "$PREFIX" \
    --glibc-max "$HOST_GLIBC_MAX" \
    --glibcxx-max "$HOST_GLIBCXX_MAX" \
    --cxxabi-max "$HOST_CXXABI_MAX"
}

check_target_linux() {
  local triple="loongarch64-unknown-linux-gnu"
  local cc="$PREFIX/bin/${triple}-gcc"
  local target_readelf="$PREFIX/bin/${triple}-readelf"
  local tmpdir version

  [[ -x "$cc" ]] || { echo "缺少目标编译器: $cc" >&2; exit 1; }
  [[ -x "$target_readelf" ]] || { echo "缺少目标 readelf: $target_readelf" >&2; exit 1; }

  tmpdir="$(mktemp -d)"
  TARGET_ABI_TMPDIR="$tmpdir"
  printf 'int main(void) { return 0; }\n' > "$tmpdir/abi.c"
  "$cc" "$tmpdir/abi.c" -o "$tmpdir/abi"

  version="$("$target_readelf" --version-info "$tmpdir/abi" 2>/dev/null \
    | grep -oE 'GLIBC_[0-9]+(\.[0-9]+)*' \
    | sed 's/^GLIBC_//' \
    | sort -Vu \
    | tail -n 1 || true)"
  [[ -n "$version" ]] || { echo "ABI 失败: 目标程序没有 GLIBC 版本信息" >&2; exit 1; }
  if ! version_le "$version" "$TARGET_GLIBC_MAX"; then
    echo "ABI 失败: 目标程序需要 GLIBC_$version，高于目标上限 $TARGET_GLIBC_MAX" >&2
    exit 1
  fi
  echo "目标 ABI 检查通过: 最高 GLIBC <= $TARGET_GLIBC_MAX"
}

check_host_abi
if [[ "$MODE" == "linux" ]]; then
  check_target_linux
else
  echo "目标 ABI 检查跳过: $MODE 不使用 glibc"
fi

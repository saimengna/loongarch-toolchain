#!/usr/bin/env bash
# Verify the host and target GLIBC symbol versions used by a toolchain.
set -euo pipefail

PREFIX=""
MODE=""
HOST_GLIBC_MAX="2.28"
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
  --target-glibc-max V  linux 目标 ELF 允许的最高 GLIBC 版本（默认 2.36）
EOT
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix) PREFIX="$2"; shift 2 ;;
    --mode) MODE="$2"; shift 2 ;;
    --host-glibc-max) HOST_GLIBC_MAX="$2"; shift 2 ;;
    --target-glibc-max) TARGET_GLIBC_MAX="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数: $1" >&2; usage; exit 1 ;;
  esac
done

[[ -n "$PREFIX" ]] || { usage; exit 1; }
[[ -d "$PREFIX/bin" ]] || { echo "找不到 $PREFIX/bin" >&2; exit 1; }

readelf_bin="$(command -v readelf || true)"
[[ -n "$readelf_bin" ]] || { echo "找不到 readelf" >&2; exit 1; }

version_le() { # $1 <= $2
  [[ "$1" == "$2" ]] && return 0
  [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n 1)" == "$1" ]]
}

max_glibc_version() { # $1 = ELF file; prints highest GLIBC_x.y
  "$readelf_bin" --version-info "$1" 2>/dev/null \
    | grep -oE 'GLIBC_[0-9]+(\.[0-9]+)*' \
    | sed 's/^GLIBC_//' \
    | sort -Vu \
    | tail -n 1 || true
}

check_host_files() {
  local seen=0 file version
  while IFS= read -r -d '' file; do
    file -L "$file" 2>/dev/null | grep -q 'ELF' || continue
    seen=$((seen + 1))
    version="$(max_glibc_version "$file")"
    [[ -n "$version" ]] || continue
    if ! version_le "$version" "$HOST_GLIBC_MAX"; then
      echo "ABI 失败: $file 需要 GLIBC_$version，高于宿主上限 $HOST_GLIBC_MAX" >&2
      exit 1
    fi
  done < <(
    find "$PREFIX/bin" -maxdepth 1 \( -type f -o -type l \) -print0
    find "$PREFIX/libexec/gcc" -mindepth 3 -maxdepth 3 -type f -print0 2>/dev/null
    find "$PREFIX/lib" -maxdepth 1 -type f \
      \( -name 'libmpfr.so.4*' -o -name 'libmpc.so.3*' -o -name 'libgmp.so.10*' \) -print0 2>/dev/null
  )
  (( seen > 0 )) || { echo "ABI 失败: 工具链中没有找到宿主 ELF" >&2; exit 1; }
  echo "宿主 ABI 检查通过: 最高 GLIBC <= $HOST_GLIBC_MAX"
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

check_host_files
if [[ "$MODE" == "linux" ]]; then
  check_target_linux
else
  echo "目标 ABI 检查跳过: $MODE 不使用 glibc"
fi

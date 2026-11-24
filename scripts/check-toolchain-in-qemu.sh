#!/usr/bin/env bash
# Run a small target smoke test under QEMU user-mode.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

PREFIX=""
MODE=""
COMPILER="gcc"
TRIPLE=""
QEMU_USER="${QEMU_USER:-qemu-loongarch64}"
TIMEOUT=30
C_SOURCE="$SCRIPT_DIR/../tests/qemu/smoke.c"
CXX_SOURCE="$SCRIPT_DIR/../tests/qemu/smoke.cpp"
NEWLIB_SOURCE="$SCRIPT_DIR/../tests/qemu/newlib-smoke.c"
RUN_STATIC=auto

usage() {
  cat <<'EOT'
用法: scripts/check-toolchain-in-qemu.sh --prefix DIR --mode MODE [选项]

在 QEMU user-mode 中验证已打包的工具链：
  * glibc/musl 编译并运行静态、动态 C 程序
  * 编译 C++ 测试程序
  * newlib 只做编译和目标 ELF 检查

  --prefix DIR       工具链安装目录
  --mode MODE        newlib、linux 或 musl
  --compiler C       gcc 或 llvm（默认 gcc）
  --triple TRIPLE    目标三元组；不指定时按 mode 推导
  --qemu-user PATH   qemu-loongarch64 可执行文件（默认 qemu-loongarch64）
  --timeout SECONDS  单个 QEMU 执行超时（默认 30）
  --c-source PATH    C 测试源文件
  --cxx-source PATH  C++ 测试源文件
  --newlib-source PATH newlib 编译测试源文件
  --static           强制测试静态链接
  --no-static        跳过静态链接测试
  -h, --help         显示帮助
EOT
}

die() {
  echo "错误: $*" >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix) [[ $# -ge 2 ]] || die "$1 缺少参数"; PREFIX="$2"; shift 2 ;;
    --mode) [[ $# -ge 2 ]] || die "$1 缺少参数"; MODE="$2"; shift 2 ;;
    --compiler) [[ $# -ge 2 ]] || die "$1 缺少参数"; COMPILER="$2"; shift 2 ;;
    --triple) [[ $# -ge 2 ]] || die "$1 缺少参数"; TRIPLE="$2"; shift 2 ;;
    --qemu-user) [[ $# -ge 2 ]] || die "$1 缺少参数"; QEMU_USER="$2"; shift 2 ;;
    --timeout) [[ $# -ge 2 ]] || die "$1 缺少参数"; TIMEOUT="$2"; shift 2 ;;
    --c-source) [[ $# -ge 2 ]] || die "$1 缺少参数"; C_SOURCE="$2"; shift 2 ;;
    --cxx-source) [[ $# -ge 2 ]] || die "$1 缺少参数"; CXX_SOURCE="$2"; shift 2 ;;
    --newlib-source) [[ $# -ge 2 ]] || die "$1 缺少参数"; NEWLIB_SOURCE="$2"; shift 2 ;;
    --static) RUN_STATIC=1; shift ;;
    --no-static) RUN_STATIC=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知参数: $1" ;;
  esac
done

[[ -n "$PREFIX" ]] || { usage; exit 1; }
[[ -d "$PREFIX/bin" ]] || die "找不到 $PREFIX/bin"
PREFIX="$(cd "$PREFIX" && pwd)"

case "$MODE" in
  newlib)
    DEFAULT_TRIPLE="loongarch64-unknown-elf"
    ;;
  linux)
    DEFAULT_TRIPLE="loongarch64-unknown-linux-gnu"
    ;;
  musl)
    DEFAULT_TRIPLE="loongarch64-unknown-linux-musl"
    ;;
  *) die "mode 必须是 newlib、linux 或 musl" ;;
esac
TRIPLE="${TRIPLE:-$DEFAULT_TRIPLE}"

case "$COMPILER" in
  gcc|llvm) ;;
  *) die "compiler 必须是 gcc 或 llvm" ;;
esac

[[ "$TIMEOUT" =~ ^[0-9]+$ ]] || die "timeout 必须是整数: $TIMEOUT"
[[ "$TIMEOUT" -gt 0 ]] || die "timeout 必须大于 0"
[[ -f "$C_SOURCE" ]] || die "找不到 C 测试源文件: $C_SOURCE"

if [[ "$COMPILER" == llvm ]]; then
  cc="$PREFIX/bin/${TRIPLE}-clang"
  cxx="$PREFIX/bin/${TRIPLE}-clang++"
  common_flags=(--target="$TRIPLE" -mabi=lp64d --gcc-toolchain="$PREFIX")
else
  cc="$PREFIX/bin/${TRIPLE}-gcc"
  cxx="$PREFIX/bin/${TRIPLE}-g++"
  common_flags=()
fi

[[ -x "$cc" ]] || die "缺少编译器: $cc"

target_readelf="$PREFIX/bin/${TRIPLE}-readelf"
target_is_loongarch() {
  local file="$1"
  if [[ -x "$target_readelf" ]]; then
    "$target_readelf" -h "$file" | grep -q 'Machine:.*LoongArch'
  else
    file "$file" | grep -qi loongarch
  fi
}

run_qemu() {
  local label="$1"
  local binary="$2"
  shift 2

  local output status
  set +e
  output="$(timeout "$TIMEOUT" "$QEMU_USER" "$@" "$binary" 2>&1)"
  status=$?
  set -e

  printf '%s\n' "$output"
  if [[ "$status" -ne 0 ]]; then
    die "$label 执行失败，退出码 $status"
  fi
  grep -qx 'qemu-smoke-ok' <<< "$output" ||
    die "$label 没有输出 qemu-smoke-ok"
}

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

echo "==> QEMU smoke: ${MODE}/${COMPILER}"
echo "prefix:  $PREFIX"
echo "triple:  $TRIPLE"
if [[ "$MODE" == newlib ]]; then
  echo "source:  $NEWLIB_SOURCE"
else
  echo "source:  $C_SOURCE"
fi

if [[ "$MODE" == newlib ]]; then
  [[ -f "$NEWLIB_SOURCE" ]] || die "找不到 newlib 测试源文件: $NEWLIB_SOURCE"
  env -u LD_LIBRARY_PATH "$cc" "${common_flags[@]}" -O2 -c "$NEWLIB_SOURCE" -o "$tmpdir/smoke.o"
  target_is_loongarch "$tmpdir/smoke.o" || die "C 目标文件不是 LoongArch"
  echo "PASS: newlib 编译 smoke 通过；运行测试需要单独提供裸机 BSP"
  exit 0
fi

[[ -d "$PREFIX/sysroot" ]] || die "缺少目标 sysroot: $PREFIX/sysroot"
command -v "$QEMU_USER" >/dev/null 2>&1 || die "找不到 QEMU: $QEMU_USER"

env -u LD_LIBRARY_PATH "$cc" "${common_flags[@]}" -O2 "$C_SOURCE" -o "$tmpdir/smoke-dynamic"
target_is_loongarch "$tmpdir/smoke-dynamic" || die "动态 C 程序不是 LoongArch"
run_qemu "动态 C 程序" "$tmpdir/smoke-dynamic" -L "$PREFIX/sysroot"

if [[ "$RUN_STATIC" == auto ]]; then
  [[ "$COMPILER" == gcc ]] && RUN_STATIC=1 || RUN_STATIC=0
fi

if [[ "$RUN_STATIC" == 1 ]]; then
  env -u LD_LIBRARY_PATH "$cc" "${common_flags[@]}" -O2 -static "$C_SOURCE" -o "$tmpdir/smoke-static"
  target_is_loongarch "$tmpdir/smoke-static" || die "静态 C 程序不是 LoongArch"
  run_qemu "静态 C 程序" "$tmpdir/smoke-static"
fi

if [[ -f "$CXX_SOURCE" && -x "$cxx" ]]; then
  env -u LD_LIBRARY_PATH "$cxx" "${common_flags[@]}" -O2 -c "$CXX_SOURCE" -o "$tmpdir/smoke-cpp.o"
  target_is_loongarch "$tmpdir/smoke-cpp.o" || die "C++ 目标文件不是 LoongArch"
else
  echo "跳过 C++ 编译：缺少 C++ 测试源文件或编译器"
fi

echo "PASS: QEMU smoke 通过"

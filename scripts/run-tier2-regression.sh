#!/usr/bin/env bash
# Run the Tier 2 P0 compiler/regression checks against a built toolchain.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE=""
SUITE="p0"
PREFIX="/mnt/loongarch"
REPORT_DIR=""
BASELINE_DIR="$ROOT/.github/regression-baseline"
UPDATE_BASELINE=0
FULL_BINUTILS=0

usage() {
  cat <<'EOT'
用法: scripts/run-tier2-regression.sh --mode linux|musl [选项]

  --mode MODE         linux 或 musl
  --suite SUITE       当前支持 p0
  --prefix DIR        工具链安装目录（默认 /mnt/loongarch）
  --report-dir DIR    保存回归摘要和运行日志
  --baseline-dir DIR  已知失败基线目录
  --update-baseline   把当前失败写入基线（人工审查后使用）
  --full-binutils     额外跑完整的 binutils/ld 套件（只报告，不拦截，耗时很长）
  -h, --help
EOT
}

die() {
  echo "错误: $*" >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) [[ $# -ge 2 ]] || die "$1 缺少参数"; MODE="$2"; shift 2 ;;
    --suite) [[ $# -ge 2 ]] || die "$1 缺少参数"; SUITE="$2"; shift 2 ;;
    --prefix) [[ $# -ge 2 ]] || die "$1 缺少参数"; PREFIX="$2"; shift 2 ;;
    --report-dir) [[ $# -ge 2 ]] || die "$1 缺少参数"; REPORT_DIR="$2"; shift 2 ;;
    --baseline-dir) [[ $# -ge 2 ]] || die "$1 缺少参数"; BASELINE_DIR="$2"; shift 2 ;;
    --update-baseline) UPDATE_BASELINE=1; shift ;;
    --full-binutils) FULL_BINUTILS=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知参数: $1" ;;
  esac
done

case "$MODE" in
  linux) triple="loongarch64-unknown-linux-gnu"; baseline_label="glibc" ;;
  musl)  triple="loongarch64-unknown-linux-musl"; baseline_label="musl" ;;
  *) die "--mode 必须是 linux 或 musl" ;;
esac

[[ "$SUITE" == p0 ]] || die "当前只实现 p0 回归集"
[[ -d "$PREFIX" ]] || die "工具链目录不存在: $PREFIX"
[[ -x "$PREFIX/bin/$triple-gcc" ]] || die "缺少编译器: $PREFIX/bin/$triple-gcc"
[[ -d "$PREFIX/sysroot" ]] || die "缺少 sysroot: $PREFIX/sysroot"

build_dir="$ROOT/build-gcc-${MODE}-stage2"
[[ -d "$build_dir" ]] || die "缺少 GCC 构建目录: $build_dir（请先运行 make ${MODE}）"
[[ -f "$build_dir/gcc/Makefile" ]] || die "GCC 尚未配置: $build_dir/gcc/Makefile"

qemu="$PREFIX/bin/qemu-loongarch64"
[[ -x "$qemu" ]] || qemu="$(command -v qemu-loongarch64 || true)"
[[ -n "$qemu" && -x "$qemu" ]] || die "找不到 qemu-loongarch64"

# When QEMU is not built from source (for example a glibc-2.28 container build
# tested on the runner with the distro qemu-user-static package) there is no
# stamps/build-qemu.  Drop the prerequisite so make does not try to rebuild it.
sim_args=()
if [[ ! -f "$ROOT/stamps/build-qemu" ]]; then
  sim_args=("SIM_STAMP=")
fi

[[ -n "$REPORT_DIR" ]] || REPORT_DIR="$ROOT/tier2-results"
mkdir -p "$REPORT_DIR"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

failed=0

run_make() {
  local target="$1"
  shift
  local rc

  echo "==> make $target"
  set +e
  make -j"$(nproc)" "$target" "${sim_args[@]}" "$@"
  rc=$?
  set -e
  if [[ "$rc" -ne 0 ]]; then
    echo "make $target 返回 $rc，继续汇总测试结果" >&2
    failed=1
  fi
}

run_summary() {
  local label="$1"
  local baseline="$2"
  local strict="$3"
  shift 3
  local safe_label="${label//\//-}"
  local output="$REPORT_DIR/${safe_label}.txt"
  local rc
  local summary_args=(--label "$label" --baseline "$baseline")

  [[ "$strict" == 1 ]] && summary_args+=(--strict)

  [[ "$UPDATE_BASELINE" == 1 ]] && summary_args+=(--update-baseline)

  echo "==> summarize $label"
  set +e
  python3 "$ROOT/scripts/testsuite-summary" \
    "${summary_args[@]}" \
    "$@" 2>&1 | tee "$output"
  rc=${PIPESTATUS[0]}
  set -e
  if [[ "$rc" -ne 0 ]]; then
    echo "回归检查失败: $label" >&2
    failed=1
  fi
}

remove_stamp() {
  rm -f "$ROOT/stamps/$1"
}

remove_stamp "check-gcc-${MODE}"
rm -f "$build_dir"/gcc/testsuite/*/*.sum
run_make "check-gcc-${MODE}" \
  "GCC_CHECK_TARGET=check-gcc-c" \
  "RUNTESTFLAGS=gcc.target/loongarch/*.exp"
run_summary \
  "gcc/${MODE}/p0" \
  "$BASELINE_DIR/${baseline_label}-gcc-p0-gcc.txt" \
  1 \
  "$build_dir/gcc/testsuite"

if [[ "$MODE" == linux ]]; then
  binutils_build="$ROOT/build-binutils-linux"

  # Upstream check-ld/check-binutils contain many run tests that depend on a
  # fully functional target loader and shared-library environment.  Gate on
  # the LoongArch-specific assembler and objdump tests, which are meaningful
  # in a cross + QEMU setup, and keep the full suites as a report only.
  remove_stamp check-binutils-linux
  rm -f "$binutils_build/binutils/binutils.sum" \
        "$binutils_build/gas/testsuite/gas.sum" \
        "$binutils_build/ld/ld.sum"
  run_make check-binutils-linux \
    "BINUTILS_CHECK_TARGETS=check-binutils check-gas" \
    "RUNTESTFLAGS=binutils-all/loongarch64/*.exp gas/loongarch/*.exp"
  run_summary \
    "binutils/linux/p0" \
    "$BASELINE_DIR/glibc-gcc-p0-binutils.txt" \
    1 \
    "$binutils_build"

  # The full suites are report-only and cost 20-40 minutes under QEMU, so they
  # stay opt-in instead of running on every build.
  if [[ "$FULL_BINUTILS" == 1 ]]; then
    remove_stamp check-binutils-linux
    run_make check-binutils-linux
    run_summary \
      "binutils/linux/full" \
      "$BASELINE_DIR/glibc-gcc-p0-binutils.txt" \
      0 \
      "$binutils_build"
  fi
fi

echo "==> P0 runtime checks"
for opt in -O0 -O2 -Os; do
  binary="$tmpdir/p0-execute${opt}"
  output="$REPORT_DIR/p0-execute${opt}.txt"
  # Keep LD_LIBRARY_PATH for the host compiler: a toolchain built inside the
  # glibc-2.28 container links against the bundled libmpfr.so.4.
  if ! "$PREFIX/bin/$triple-gcc" \
      "$opt" "$ROOT/tests/tier2/p0-execute.c" -o "$binary"; then
    echo "编译失败: $opt" >&2
    failed=1
    continue
  fi
  # Do not leak the host library path into the guest loader search path.
  if ! env -u LD_LIBRARY_PATH QEMU_CPU=la464 QEMU_LD_PREFIX="$PREFIX/sysroot" \
      timeout 30 "$qemu" -L "$PREFIX/sysroot" "$binary" >"$output" 2>&1; then
    echo "运行失败: $opt" >&2
    cat "$output" >&2 || true
    failed=1
    continue
  fi
  if ! grep -qx 'tier2-ok' "$output"; then
    echo "输出不符合预期: $opt" >&2
    cat "$output" >&2 || true
    failed=1
  fi
done

if [[ "$failed" -ne 0 ]]; then
  echo "FAIL: Tier 2 ${MODE}/${SUITE} 回归失败" | tee "$REPORT_DIR/result.txt" >&2
  exit 1
fi

echo "PASS: Tier 2 ${MODE}/${SUITE} 回归通过" | tee "$REPORT_DIR/result.txt"

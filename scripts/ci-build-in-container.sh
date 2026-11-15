#!/usr/bin/env bash
# Build, verify, and package one GCC or GCC+LLVM toolchain inside the
# glibc-2.28 image.
set -euo pipefail

MODE=""
COMPILER="${CI_COMPILER:-gcc}"
TARGET="loongarch64-lp64d"
PREFIX=""
OUTDIR=""
UNSTRIPPED_NAME=""
STRIPPED_NAME=""
STRIP_MODE="unstripped"
HOST_GLIBC_MAX="2.28"
TARGET_GLIBC_MAX="2.36"
JOBS="${JOBS:-$(nproc)}"
PREBUILT_GNU="${CI_PREBUILT_GNU:-0}"

usage() {
  cat <<'EOT'
用法: scripts/ci-build-in-container.sh --mode MODE --prefix DIR --outdir DIR --unstripped-name NAME [选项]

  --compiler gcc|llvm  构建 GCC 或 LLVM（默认 gcc）
  --prebuilt-gnu       使用 --prefix 中已有的 GCC 工具链，只构建 LLVM
EOT
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE="$2"; shift 2 ;;
    --compiler) COMPILER="$2"; shift 2 ;;
    --target) TARGET="$2"; shift 2 ;;
    --prefix) PREFIX="$2"; shift 2 ;;
    --outdir) OUTDIR="$2"; shift 2 ;;
    --unstripped-name) UNSTRIPPED_NAME="$2"; shift 2 ;;
    --stripped-name) STRIPPED_NAME="$2"; shift 2 ;;
    --strip-mode) STRIP_MODE="$2"; shift 2 ;;
    --host-glibc-max) HOST_GLIBC_MAX="$2"; shift 2 ;;
    --target-glibc-max) TARGET_GLIBC_MAX="$2"; shift 2 ;;
    --prebuilt-gnu) PREBUILT_GNU=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数: $1" >&2; usage; exit 1 ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

case "$MODE" in
  newlib|linux|musl) ;;
  *) echo "mode 必须是 newlib/linux/musl" >&2; exit 1 ;;
esac
case "$COMPILER" in
  gcc|llvm) ;;
  *) echo "compiler 必须是 gcc/llvm" >&2; exit 1 ;;
esac
case "$PREBUILT_GNU" in
  1|true|yes) PREBUILT_GNU=1 ;;
  *) PREBUILT_GNU=0 ;;
esac
if [[ "$PREBUILT_GNU" == 1 && "$COMPILER" != llvm ]]; then
  echo "--prebuilt-gnu 只能和 --compiler llvm 一起使用" >&2
  exit 1
fi
case "$STRIP_MODE" in
  unstripped|stripped|both) ;;
  *) echo "strip-mode 必须是 unstripped/stripped/both" >&2; exit 1 ;;
esac
[[ -n "$PREFIX" ]] || { echo "缺少 --prefix" >&2; exit 1; }
[[ -n "$OUTDIR" ]] || { echo "缺少 --outdir" >&2; exit 1; }
[[ -n "$UNSTRIPPED_NAME" || -n "$STRIPPED_NAME" ]] || { echo "缺少输出包名" >&2; exit 1; }

if [[ "$MODE" == "linux" && "$PREBUILT_GNU" != 1 ]]; then
  glibc_version="$(awk '/^#define VERSION / { gsub(/"/, "", $3); print $3; exit }' glibc/version.h 2>/dev/null || true)"
  [[ "$glibc_version" == "2.36" ]] || {
    echo "Linux 工具链要求 glibc 2.36，当前源码是 ${glibc_version:-未知}" >&2
    exit 1
  }
elif [[ "$MODE" == "linux" ]]; then
  glibc_version="prebuilt"
fi

IFS=- read -r ARCH ABI <<< "$TARGET"
[[ -n "$ARCH" && -n "$ABI" ]] || { echo "无法解析 target: $TARGET" >&2; exit 1; }

# A shallow checkout can make git distrust the bind-mounted workspace.
git config --global --add safe.directory "$REPO_ROOT" 2>/dev/null || true

if [[ "$PREBUILT_GNU" == 1 ]]; then
  [[ -d "$PREFIX/bin" ]] || {
    echo "--prebuilt-gnu 指定的目录没有 bin/: $PREFIX" >&2
    exit 1
  }
  compgen -G "$PREFIX/bin/*-gcc" >/dev/null || {
    echo "--prebuilt-gnu 指定的目录没有交叉 GCC: $PREFIX" >&2
    exit 1
  }
else
  rm -rf "$PREFIX"
fi
rm -rf "$REPO_ROOT"/build-* "$REPO_ROOT"/stamps "$REPO_ROOT"/install-host-gcc \
       "$REPO_ROOT"/install-newlib-nano

args=(--prefix="$PREFIX" --with-arch="$ARCH" --with-abi="$ABI" --disable-gdb)
case "$MODE" in
  linux)
    args+=(--enable-linux)
    ;;
  musl)
    args+=(--enable-musl)
    ;;
esac
[[ "$COMPILER" == llvm ]] && args+=(--enable-llvm)

./configure "${args[@]}"

llvm_python="${LLVM_PYTHON:-}"
if [[ "$COMPILER" == llvm && -z "$llvm_python" ]]; then
  for candidate in python3.12 python3.11 python3.10 python3.9 python3.8 python3; do
    if command -v "$candidate" >/dev/null 2>&1 &&
       "$candidate" -c 'import sys; raise SystemExit(sys.version_info < (3, 8))'; then
      llvm_python="$candidate"
      break
    fi
  done
  if [[ -z "$llvm_python" ]]; then
    for candidate in /opt/python/*/bin/python3 /opt/python/*/bin/python3.*; do
      [[ -x "$candidate" ]] || continue
      if "$candidate" -c 'import sys; raise SystemExit(sys.version_info < (3, 8))'; then
        llvm_python="$candidate"
        break
      fi
    done
  fi
  [[ -n "$llvm_python" ]] || {
    echo "LLVM 需要 Python >= 3.8，可用 LLVM_PYTHON 指定解释器" >&2
    exit 1
  }
  echo "LLVM Python: $llvm_python"
fi

llvm_generator="${LLVM_GENERATOR:-}"
if [[ "$COMPILER" == llvm && -z "$llvm_generator" ]] && ! command -v ninja >/dev/null 2>&1; then
  llvm_generator="Unix Makefiles"
  echo "ninja 不可用，LLVM 改用 Unix Makefiles"
fi

make_opts=(-j"$JOBS")
make_vars=()
[[ -n "$llvm_python" ]] && make_vars+=("LLVM_PYTHON=$llvm_python")
[[ -n "$llvm_generator" ]] && make_vars+=("LLVM_GENERATOR=$llvm_generator")

if [[ "$PREBUILT_GNU" == 1 ]]; then
  make "${make_opts[@]}" \
    -o "stamps/build-gcc-${MODE}-stage2" \
    "stamps/build-llvm-${MODE}" \
    "${make_vars[@]}"
else
  make "${make_opts[@]}" "$MODE" "${make_vars[@]}"
fi

case "$MODE" in
  newlib) triple="loongarch64-unknown-elf" ;;
  linux)  triple="loongarch64-unknown-linux-gnu" ;;
  musl)   triple="loongarch64-unknown-linux-musl" ;;
esac

if [[ "$COMPILER" == llvm ]]; then
  cc="$PREFIX/bin/${triple}-clang"
  cxx="$PREFIX/bin/${triple}-clang++"
  [[ -x "$cc" ]] || { echo "构建后缺少 clang: $cc" >&2; exit 1; }
  [[ -x "$cxx" ]] || { echo "构建后缺少 clang++: $cxx" >&2; exit 1; }
else
  cc="$PREFIX/bin/${triple}-gcc"
  [[ -x "$cc" ]] || { echo "构建后缺少编译器: $cc" >&2; exit 1; }
fi
[[ -x "$cc" ]] || { echo "构建后缺少编译器: $cc" >&2; exit 1; }
"$cc" --version
printf 'int smoke(void) { return 42; }\n' > /tmp/loongarch-smoke.c
if [[ "$COMPILER" == llvm ]]; then
  "$cc" -mabi="$ABI" -c /tmp/loongarch-smoke.c -o /tmp/loongarch-smoke.o
else
  "$cc" -c /tmp/loongarch-smoke.c -o /tmp/loongarch-smoke.o
fi
file /tmp/loongarch-smoke.o | grep -qi loongarch

make versions
cp versions.txt "$PREFIX/VERSIONS.txt"
[[ -f sources.lock ]] && cp sources.lock "$PREFIX/SOURCES.lock"
cat > "$PREFIX/BUILD-INFO.txt" <<EOF
host_arch=$(uname -m)
host_glibc=$(ldd --version | head -n 1 | awk '{print $NF}')
host_glibc_max=$HOST_GLIBC_MAX
target=$triple
target_abi=$ABI
mode=$MODE
target_glibc_version=${glibc_version:-none}
target_glibc_max=$TARGET_GLIBC_MAX
compiler=$COMPILER
builder_image=${BUILDER_IMAGE:-unknown}
source_lock=SOURCES.lock
EOF

bash scripts/check-toolchain-abi.sh \
  --prefix "$PREFIX" \
  --mode "$MODE" \
  --host-glibc-max "$HOST_GLIBC_MAX" \
  --target-glibc-max "$TARGET_GLIBC_MAX"

mkdir -p "$OUTDIR"
if [[ "$STRIP_MODE" == "unstripped" || "$STRIP_MODE" == "both" ]]; then
  bash scripts/package-toolchain.sh \
    --prefix "$PREFIX" --mode "$MODE" --outdir "$OUTDIR" \
    --name "$UNSTRIPPED_NAME"
fi
if [[ "$STRIP_MODE" == "stripped" || "$STRIP_MODE" == "both" ]]; then
  bash scripts/package-toolchain.sh \
    --prefix "$PREFIX" --mode "$MODE" --outdir "$OUTDIR" \
    --name "$STRIPPED_NAME" --strip
fi

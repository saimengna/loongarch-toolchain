#!/usr/bin/env bash
# Build, verify, and package one GCC toolchain inside the glibc-2.28 image.
set -euo pipefail

MODE=""
TARGET="loongarch64-lp64d"
PREFIX=""
OUTDIR=""
UNSTRIPPED_NAME=""
STRIPPED_NAME=""
STRIP_MODE="unstripped"
HOST_GLIBC_MAX="2.28"
TARGET_GLIBC_MAX="2.36"
JOBS="${JOBS:-$(nproc)}"

usage() {
  cat <<'EOT'
用法: scripts/ci-build-in-container.sh --mode MODE --prefix DIR --outdir DIR --unstripped-name NAME [选项]
EOT
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE="$2"; shift 2 ;;
    --target) TARGET="$2"; shift 2 ;;
    --prefix) PREFIX="$2"; shift 2 ;;
    --outdir) OUTDIR="$2"; shift 2 ;;
    --unstripped-name) UNSTRIPPED_NAME="$2"; shift 2 ;;
    --stripped-name) STRIPPED_NAME="$2"; shift 2 ;;
    --strip-mode) STRIP_MODE="$2"; shift 2 ;;
    --host-glibc-max) HOST_GLIBC_MAX="$2"; shift 2 ;;
    --target-glibc-max) TARGET_GLIBC_MAX="$2"; shift 2 ;;
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
case "$STRIP_MODE" in
  unstripped|stripped|both) ;;
  *) echo "strip-mode 必须是 unstripped/stripped/both" >&2; exit 1 ;;
esac
[[ -n "$PREFIX" ]] || { echo "缺少 --prefix" >&2; exit 1; }
[[ -n "$OUTDIR" ]] || { echo "缺少 --outdir" >&2; exit 1; }
[[ -n "$UNSTRIPPED_NAME" || -n "$STRIPPED_NAME" ]] || { echo "缺少输出包名" >&2; exit 1; }

if [[ "$MODE" == "linux" ]]; then
  glibc_version="$(awk '/^#define VERSION / { gsub(/"/, "", $3); print $3; exit }' glibc/version.h 2>/dev/null || true)"
  [[ "$glibc_version" == "2.36" ]] || {
    echo "Linux 工具链要求 glibc 2.36，当前源码是 ${glibc_version:-未知}" >&2
    exit 1
  }
fi

IFS=- read -r ARCH ABI <<< "$TARGET"
[[ -n "$ARCH" && -n "$ABI" ]] || { echo "无法解析 target: $TARGET" >&2; exit 1; }

# A shallow checkout can make git distrust the bind-mounted workspace.
git config --global --add safe.directory "$REPO_ROOT" 2>/dev/null || true

rm -rf "$REPO_ROOT"/build-* "$REPO_ROOT"/stamps "$REPO_ROOT"/install-host-gcc \
       "$REPO_ROOT"/install-newlib-nano "$PREFIX"

args=(--prefix="$PREFIX" --with-arch="$ARCH" --with-abi="$ABI" --disable-gdb)
case "$MODE" in
  linux)
    args+=(--enable-linux)
    ;;
  musl)
    args+=(--enable-musl)
    ;;
esac

./configure "${args[@]}"
make -j"$JOBS" "$MODE"

case "$MODE" in
  newlib) triple="loongarch64-unknown-elf" ;;
  linux)  triple="loongarch64-unknown-linux-gnu" ;;
  musl)   triple="loongarch64-unknown-linux-musl" ;;
esac

cc="$PREFIX/bin/${triple}-gcc"
[[ -x "$cc" ]] || { echo "构建后缺少编译器: $cc" >&2; exit 1; }
"$cc" --version
"$cc" -dumpmachine | grep -qx "$triple"
printf 'int smoke(void) { return 42; }\n' > /tmp/loongarch-smoke.c
"$cc" -c /tmp/loongarch-smoke.c -o /tmp/loongarch-smoke.o
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

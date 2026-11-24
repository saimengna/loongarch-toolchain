#!/usr/bin/env bash
# Verify a packaged toolchain starts and compiles inside the glibc 2.28 image.
set -euo pipefail

PREFIX=""
TRIPLE=""
COMPILER=""
IMAGE=""
DOCKER="${DOCKER:-docker}"

usage() {
  cat <<'EOT'
用法: scripts/check-in-glibc228.sh --prefix DIR --triple TRIPLE \
       --compiler gcc|llvm --image IMAGE

在 glibc 2.28 容器中验证工具链：
  * 编译器可以启动
  * 可以编译 C/C++ 目标文件
  * 目标文件是 LoongArch
  * 宿主程序没有缺失动态库，且带有相对 RPATH

  --prefix DIR   工具链安装目录
  --triple T     目标三元组，例如 loongarch64-unknown-linux-gnu
  --compiler C   gcc 或 llvm
  --image IMAGE  glibc 2.28 容器镜像

环境变量 DOCKER 可覆盖 docker 命令，默认 docker。
EOT
}

die() {
  echo "错误: $*" >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix) [[ $# -ge 2 ]] || die "$1 缺少参数"; PREFIX="$2"; shift 2 ;;
    --triple) [[ $# -ge 2 ]] || die "$1 缺少参数"; TRIPLE="$2"; shift 2 ;;
    --compiler) [[ $# -ge 2 ]] || die "$1 缺少参数"; COMPILER="$2"; shift 2 ;;
    --image) [[ $# -ge 2 ]] || die "$1 缺少参数"; IMAGE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知参数: $1" ;;
  esac
done

[[ -n "$PREFIX" ]] || { usage; exit 1; }
[[ -d "$PREFIX/bin" ]] || die "找不到 $PREFIX/bin"
PREFIX="$(cd "$PREFIX" && pwd)"

case "$COMPILER" in
  gcc|llvm) ;;
  *) die "compiler 必须是 gcc 或 llvm" ;;
esac
[[ -n "$TRIPLE" ]] || die "缺少 --triple"
[[ -n "$IMAGE" ]] || die "缺少 --image"

command -v "$DOCKER" >/dev/null 2>&1 || die "找不到 $DOCKER"
command -v mktemp >/dev/null 2>&1 || die "找不到 mktemp"

container_script="$(mktemp)"
trap 'rm -f "$container_script"' EXIT

cat > "$container_script" <<'EOT'
set -euo pipefail

triple="${TRIPLE:?}"
compiler="${COMPILER:?}"
prefix=/toolchain

case "$compiler" in
  gcc)
    cc="$prefix/bin/${triple}-gcc"
    cxx="$prefix/bin/${triple}-g++"
    ;;
  llvm)
    cc="$prefix/bin/${triple}-clang"
    cxx="$prefix/bin/${triple}-clang++"
    ;;
esac

test -x "$cc" || { echo "缺少编译器: $cc" >&2; exit 1; }
test -x "$cxx" || { echo "缺少编译器: $cxx" >&2; exit 1; }

env -u LD_LIBRARY_PATH "$cc" --version
env -u LD_LIBRARY_PATH "$cxx" --version

if [[ "$compiler" == gcc ]]; then
  env -u LD_LIBRARY_PATH "$cc" -dumpmachine | grep -qx "$triple"
fi

printf 'int main(void) { return 0; }\n' > /tmp/abi-smoke.c
printf 'int smoke_cpp(void) { return 0; }\n' > /tmp/abi-smoke.cpp

if [[ "$compiler" == llvm ]]; then
  env -u LD_LIBRARY_PATH "$cc" \
    --target="$triple" -mabi=lp64d \
    -c /tmp/abi-smoke.c -o /tmp/abi-smoke.o
  env -u LD_LIBRARY_PATH "$cxx" \
    --target="$triple" -mabi=lp64d \
    -c /tmp/abi-smoke.cpp -o /tmp/abi-smoke-cpp.o
else
  env -u LD_LIBRARY_PATH "$cc" \
    -c /tmp/abi-smoke.c -o /tmp/abi-smoke.o
  env -u LD_LIBRARY_PATH "$cxx" \
    -c /tmp/abi-smoke.cpp -o /tmp/abi-smoke-cpp.o
fi

target_readelf="$prefix/bin/${triple}-readelf"
if [[ -x "$target_readelf" ]]; then
  "$target_readelf" -h /tmp/abi-smoke.o | grep -q 'Machine:.*LoongArch'
  "$target_readelf" -h /tmp/abi-smoke-cpp.o | grep -q 'Machine:.*LoongArch'
else
  file /tmp/abi-smoke.o | grep -qi loongarch
  file /tmp/abi-smoke-cpp.o | grep -qi loongarch
fi

for binary in "$cc" "$cxx"; do
  if env -u LD_LIBRARY_PATH ldd "$binary" 2>&1 | grep -q 'not found'; then
    echo "缺少动态库: $binary" >&2
    env -u LD_LIBRARY_PATH ldd "$binary" >&2
    exit 1
  fi
  if ! readelf -d "$binary" | grep -Fq '$ORIGIN'; then
    echo "缺少相对 RPATH: $binary" >&2
    exit 1
  fi
done

echo "PASS: glibc 2.28 容器验证通过"
EOT

"$DOCKER" run --rm \
  -e TRIPLE="$TRIPLE" \
  -e COMPILER="$COMPILER" \
  -v "$PREFIX:/toolchain:ro" \
  -v "$container_script:/check-in-glibc228.sh:ro" \
  "$IMAGE" \
  bash --noprofile --norc /check-in-glibc228.sh

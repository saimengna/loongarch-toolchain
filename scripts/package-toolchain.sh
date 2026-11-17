#!/usr/bin/env bash
# Package an installed toolchain as a reproducible tar.xz.
set -euo pipefail

PREFIX=""
MODE=""
OUTDIR="."
NAME=""
STRIP=0

usage() {
  cat <<'EOT'
用法: scripts/package-toolchain.sh --prefix DIR --mode newlib|linux|musl [选项]

  --prefix DIR   工具链安装目录
  --mode MODE    newlib / linux / musl / uclibc
  --outdir DIR   输出目录(默认当前目录)
  --name NAME    输出文件名(不含 .tar.xz)
  --strip        生成 stripped 包
  -h, --help
EOT
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix) PREFIX="$2"; shift 2 ;;
    --mode)   MODE="$2";   shift 2 ;;
    --outdir) OUTDIR="$2"; shift 2 ;;
    --name)   NAME="$2";   shift 2 ;;
    --strip)  STRIP=1;     shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数: $1" >&2; usage; exit 1 ;;
  esac
done

[[ -n "$PREFIX" ]] || { usage; exit 1; }
[[ -d "$PREFIX" ]] || { echo "安装目录不存在: $PREFIX" >&2; exit 1; }
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

case "$MODE" in
  newlib) LABEL="elf" ;;
  linux)  LABEL="glibc" ;;
  musl)   LABEL="musl" ;;
  uclibc) LABEL="uclibc-ng" ;;
  *) echo "mode 必须是 newlib/linux/musl/uclibc" >&2; exit 1 ;;
esac

HOST_ARCH="$(uname -m)"
HOST_OS="$(. /etc/os-release 2>/dev/null; echo "${ID:-linux}${VERSION_ID:-}")"
SUFFIX=""
[[ "$STRIP" == 1 ]] && SUFFIX="-stripped"
[[ -n "$NAME" ]] || NAME="loongarch64-${LABEL}-${HOST_OS}-${HOST_ARCH}${SUFFIX}"

if [[ "$STRIP" == 1 ]]; then
  host_strip="$(command -v strip || true)"
  cross_strip=""
  for triple in \
      loongarch64-unknown-linux-gnu \
      loongarch64-unknown-linux-musl \
      loongarch64-unknown-elf; do
    if [[ -x "$PREFIX/bin/$triple-strip" ]]; then
      cross_strip="$PREFIX/bin/$triple-strip"
      break
    fi
  done
  [[ -n "$host_strip" ]] || { echo "找不到宿主的 strip" >&2; exit 1; }

  strip_one() {
    local file="$1" kind
    kind="$(file -b "$file")"
    case "$kind" in
      *ELF*executable*|*ELF*shared\ object*)
        if [[ "$kind" == *LoongArch* ]]; then
          [[ -n "$cross_strip" ]] || {
            echo "缺少 LoongArch strip，无法处理: $file" >&2
            return 1
          }
          "$cross_strip" --strip-unneeded "$file"
        else
          "$host_strip" --strip-unneeded "$file"
        fi
        ;;
    esac
  }
  export -f strip_one
  export host_strip cross_strip
  find "$PREFIX" -type f -exec bash -c 'strip_one "$1"' _ {} \;
fi

# Legal notices and source revision information must travel with the binaries.
for notice in LICENSE THIRD_PARTY_NOTICES.md; do
  [[ -f "$REPO_ROOT/$notice" ]] && cp "$REPO_ROOT/$notice" "$PREFIX/$notice"
done
rm -f "$PREFIX/SOURCES.lock"

if [[ -x "$(dirname "$0")/../.github/dedup-dir.sh" ]]; then
  "$(dirname "$0")/../.github/dedup-dir.sh" "$PREFIX" || true
fi

mkdir -p "$OUTDIR"
XZ_OPT="-e -T0" tar cJf "$OUTDIR/${NAME}.tar.xz" \
  -C "$(dirname "$PREFIX")" "$(basename "$PREFIX")"
echo "==> 产物: $OUTDIR/${NAME}.tar.xz"
du -h "$OUTDIR/${NAME}.tar.xz"

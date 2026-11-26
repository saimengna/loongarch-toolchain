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
  --mode MODE    newlib / linux / musl
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
PREFIX="$(cd "$PREFIX" && pwd -P)"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

normalize_internal_symlinks() {
  local link target resolved

  while IFS= read -r -d '' link; do
    target="$(readlink "$link")"
    if [[ "$target" == /* ]]; then
      case "$target" in
        "$PREFIX"/*)
          resolved="$(realpath -m --relative-to="$(dirname "$link")" "$target")"
          ln -sfn "$resolved" "$link"
          target="$resolved"
          ;;
        *)
          echo "包内绝对符号链接指向安装目录之外: $link -> $target" >&2
          return 1
          ;;
      esac
    fi

    [[ -e "$link" ]] || {
      echo "包内存在悬空符号链接: $link -> $target" >&2
      return 1
    }

    resolved="$(realpath -m "$link")"
    case "$resolved" in
      "$PREFIX/"*) ;;
      *)
        echo "包内符号链接解析到安装目录之外: $link -> $resolved" >&2
        return 1
        ;;
    esac
  done < <(find "$PREFIX" -type l -print0)
}

case "$MODE" in
  newlib) LABEL="elf" ;;
  linux)  LABEL="glibc" ;;
  musl)   LABEL="musl" ;;
  *) echo "mode 必须是 newlib/linux/musl" >&2; exit 1 ;;
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
bash "$REPO_ROOT/scripts/gen-source-offer.sh" \
  --prefix "$PREFIX" --mode "$MODE" --output "$PREFIX/SOURCE-OFFER.txt"

for notice in LICENSE LICENSE.LGPL-2.1 LICENSE.GPL-2.0 THIRD_PARTY_NOTICES.md; do
  [[ -f "$REPO_ROOT/$notice" ]] && cp "$REPO_ROOT/$notice" "$PREFIX/$notice"
done
rm -f "$PREFIX/SOURCES.lock"

if [[ -x "$(dirname "$0")/../.github/dedup-dir.sh" ]]; then
  "$(dirname "$0")/../.github/dedup-dir.sh" "$PREFIX" ||
    echo "警告: dedup-dir 返回非零，归档可能没有去重" >&2
fi

normalize_internal_symlinks

mkdir -p "$OUTDIR"
XZ_OPT="-e -T0" tar cJf "$OUTDIR/${NAME}.tar.xz" \
  -C "$(dirname "$PREFIX")" "$(basename "$PREFIX")"
echo "==> 产物: $OUTDIR/${NAME}.tar.xz"
du -h "$OUTDIR/${NAME}.tar.xz"

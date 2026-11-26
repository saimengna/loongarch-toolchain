#!/usr/bin/env bash
# Render SOURCE-OFFER.txt for one packaged toolchain.
set -euo pipefail

PREFIX=""
MODE=""
OUTPUT=""

usage() {
  cat <<'EOT'
用法: scripts/gen-source-offer.sh --prefix DIR --mode MODE --output FILE

  --prefix DIR   工具链安装目录
  --mode MODE    newlib / linux / musl
  --output FILE  生成的源码提供声明

环境变量（可选）:
  SOURCE_TAG      构建所用的 tag 或 ref 名称
  SOURCE_COMMIT   构建所用的本仓库 commit
  SOURCE_REPO     owner/repo，例如 saimengna/loongarch-toolchain
  SOURCE_URL      构建脚本源码的完整 URL
EOT
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix) PREFIX="$2"; shift 2 ;;
    --mode)   MODE="$2";   shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数: $1" >&2; usage; exit 1 ;;
  esac
done

[[ -n "$PREFIX" && -d "$PREFIX" ]] || { echo "安装目录不存在: $PREFIX" >&2; exit 1; }
[[ -n "$MODE" ]] || { echo "缺少 --mode" >&2; exit 1; }
[[ -n "$OUTPUT" ]] || { echo "缺少 --output" >&2; exit 1; }

PREFIX="$(cd "$PREFIX" && pwd -P)"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSIONS="$PREFIX/VERSIONS.txt"

repo_commit="${SOURCE_COMMIT:-}"
if [[ -z "$repo_commit" ]]; then
  repo_commit="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || true)"
fi
[[ -n "$repo_commit" ]] || {
  echo "无法确定本仓库 commit；请在 git checkout 中运行，或设置 SOURCE_COMMIT" >&2
  exit 1
}

repo_tag="${SOURCE_TAG:-${TAG:-}}"
if [[ -z "$repo_tag" ]]; then
  repo_tag="$(git -C "$REPO_ROOT" describe --tags --always 2>/dev/null || true)"
fi
repo_tag="${repo_tag:-unknown}"

repo_slug="${SOURCE_REPO:-}"
if [[ -z "$repo_slug" ]]; then
  origin="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || true)"
  case "$origin" in
    https://github.com/*)       repo_slug="${origin#https://github.com/}" ;;
    git@github.com:*)           repo_slug="${origin#git@github.com:}" ;;
    ssh://git@github.com/*)     repo_slug="${origin#ssh://git@github.com/}" ;;
  esac
  repo_slug="${repo_slug%.git}"
fi

source_url="${SOURCE_URL:-}"
if [[ -z "$source_url" && -n "$repo_slug" ]]; then
  source_url="https://github.com/${repo_slug}/tree/${repo_commit}"
fi
[[ -n "$source_url" ]] || {
  echo "无法确定源码 URL；请设置 SOURCE_REPO 或 SOURCE_URL" >&2
  exit 1
}
source_url="${source_url%/}"

sha_of() {
  local component="$1" sha=""
  if [[ -e "$REPO_ROOT/$component/.git" ]]; then
    sha="$(git -C "$REPO_ROOT/$component" rev-parse HEAD 2>/dev/null || true)"
  fi
  if [[ -z "$sha" ]]; then
    sha="$(git -C "$REPO_ROOT" ls-tree HEAD -- "$component" 2>/dev/null \
      | awk '$1 == "160000" { print $3; exit }')"
  fi
  if [[ -z "$sha" && -f "$VERSIONS" ]]; then
    sha="$(awk -v c="$component" '$1 == c { print $2; exit }' "$VERSIONS")"
  fi
  printf '%s' "$sha"
}

require_sha() {
  local component="$1" sha
  sha="$(sha_of "$component")"
  [[ -n "$sha" ]] || {
    echo "无法确定 $component 的源码 commit" >&2
    exit 1
  }
  printf '%s' "$sha"
}

has_bin() {
  find "$PREFIX/bin" -maxdepth 1 \( -type f -o -type l \) -name "$1" -print -quit 2>/dev/null \
    | grep -q .
}

component_license() {
  case "$1" in
    gcc)      echo "GPL-3.0-or-later with GCC Runtime Library Exception 3.1" ;;
    binutils) echo "GPL-3.0-or-later" ;;
    gdb)      echo "GPL-3.0-or-later" ;;
    glibc)    echo "LGPL-2.1-or-later; some programs are GPL-2.0-or-later" ;;
    musl)     echo "MIT" ;;
    newlib)   echo "BSD-style and other permissive notices" ;;
    llvm)     echo "Apache-2.0 WITH LLVM-exception" ;;
    *)        echo "see THIRD_PARTY_NOTICES.md" ;;
  esac
}

component_url() {
  local component="$1" sha="$2"
  case "$component" in
    gcc)
      echo "https://github.com/gcc-mirror/gcc/tree/${sha}" ;;
    binutils|gdb)
      echo "https://sourceware.org/git/?p=binutils-gdb.git;a=tree;h=${sha};hb=${sha}" ;;
    glibc)
      echo "https://github.com/bminor/glibc/tree/${sha}" ;;
    musl)
      echo "https://github.com/kraj/musl/tree/${sha}" ;;
    newlib)
      echo "https://github.com/loongson/newlib/tree/${sha}" ;;
    llvm)
      echo "https://github.com/llvm/llvm-project/tree/${sha}" ;;
    *)
      echo "$source_url" ;;
  esac
}

emit_component() {
  local component="$1" sha license url
  sha="$(require_sha "$component")"
  license="$(component_license "$component")"
  url="$(component_url "$component" "$sha")"
  printf '  %-9s %s\n' "$component" "$sha"
  printf '             License: %s\n' "$license"
  printf '             Source:  %s\n' "$url"
}

gpl_components=()
lgpl_components=()
other_components=()

if has_bin '*-gcc' || [[ -d "$PREFIX/libexec/gcc" ]]; then
  gpl_components+=(gcc)
fi
if has_bin '*-ld' || has_bin '*-as'; then
  gpl_components+=(binutils)
fi
if has_bin '*-gdb'; then
  gpl_components+=(gdb)
fi

case "$MODE" in
  linux)  lgpl_components+=(glibc) ;;
  musl)   other_components+=(musl) ;;
  newlib) other_components+=(newlib) ;;
esac

if has_bin '*-clang'; then
  other_components+=(llvm)
fi

mkdir -p "$(dirname "$OUTPUT")"
{
  cat <<EOT
CORRESPONDING SOURCE FOR THIS TOOLCHAIN ARCHIVE

This archive contains object code from the components listed below.
The exact revisions are also recorded in VERSIONS.txt inside this archive.

EOT

  if ((${#gpl_components[@]})); then
    cat <<'EOT'
GNU GPL v3 components (Corresponding Source required):
EOT
    for component in "${gpl_components[@]}"; do
      emit_component "$component"
    done
    echo
  fi

  if ((${#lgpl_components[@]})); then
    cat <<'EOT'
GNU LGPL components (Corresponding Source required):
EOT
    for component in "${lgpl_components[@]}"; do
      emit_component "$component"
    done
    echo
  fi

  if ((${#other_components[@]})); then
    cat <<'EOT'
Other components (license notice only; the listed source URL is provided
for convenience):
EOT
    for component in "${other_components[@]}"; do
      emit_component "$component"
    done
    echo
  fi

  cat <<EOT
BUILD SCRIPTS

Corresponding Source also includes the scripts used to control compilation
and installation. Those scripts are this repository at commit ${repo_commit}
(tag/ref: ${repo_tag}); they are licensed under GPL-3.0 (see LICENSE):

  ${source_url}

SOURCE AVAILABILITY

The Corresponding Source is available at the URLs listed above. It will
remain available for as long as these binaries are distributed.

LICENSE TEXTS

  LICENSE             GNU GPL v3
  LICENSE.LGPL-2.1    GNU LGPL v2.1 (glibc)
  LICENSE.GPL-2.0     GNU GPL v2 (GPL-2.0 parts of glibc)
  THIRD_PARTY_NOTICES.md

BUNDLED HOST RUNTIME LIBRARIES

If BUILD-INFO.txt lists bundled_host_libs, this archive also contains
GMP, MPFR, and MPC shared libraries from the glibc 2.28 builder image.
Their upstream projects are:

  GMP   https://gmplib.org/
  MPFR  https://www.mpfr.org/
  MPC   https://www.multiprecision.org/mpc/
EOT
} > "$OUTPUT"

if grep -q '@[A-Z_]*@' "$OUTPUT"; then
  echo "源码提供声明中仍有未替换的占位符:" >&2
  grep -n '@[A-Z_]*@' "$OUTPUT" >&2
  exit 1
fi

echo "==> 源码提供声明: $OUTPUT"

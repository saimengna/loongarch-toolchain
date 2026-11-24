#!/usr/bin/env bash
# 检查工具链包内宿主 ELF 使用的 GLIBC / GLIBCXX / CXXABI 符号版本。
set -euo pipefail
export LC_ALL=C

PREFIX=""
GLIBC_MAX="2.28"
GLIBCXX_MAX="3.4.25"
CXXABI_MAX="1.3.11"
ARCH="auto"
VERBOSE=0

usage() {
    cat <<'EOT'
用法: check-host-abi.sh --prefix DIR [选项]

  --prefix DIR        工具链安装目录（包含 bin/、lib/、lib64/、libexec/）
  --glibc-max V       宿主 GLIBC 上限（默认 2.28）
  --glibcxx-max V     宿主 GLIBCXX 上限（默认 3.4.25）
  --cxxabi-max V      宿主 CXXABI 上限（默认 1.3.11）
  --arch ARCH         宿主架构：auto、x86_64、aarch64、loongarch64
  --verbose           打印每个宿主 ELF 的检查结果
  -h, --help          显示帮助

示例:
  ./check-host-abi.sh --prefix /path/to/install-toolchain
  ./check-host-abi.sh --prefix /path/to/install-toolchain --arch x86_64
EOT
}

die() {
    echo "错误: $*" >&2
    exit 2
}

version_ok() {
    [[ "$1" =~ ^[0-9]+(\.[0-9]+)*$ ]] ||
        die "版本号格式不正确: $1"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --prefix)
            [[ $# -ge 2 ]] || die "$1 缺少参数"
            PREFIX="$2"; shift 2 ;;
        --glibc-max)
            [[ $# -ge 2 ]] || die "$1 缺少参数"
            GLIBC_MAX="$2"; shift 2 ;;
        --glibcxx-max)
            [[ $# -ge 2 ]] || die "$1 缺少参数"
            GLIBCXX_MAX="$2"; shift 2 ;;
        --cxxabi-max)
            [[ $# -ge 2 ]] || die "$1 缺少参数"
            CXXABI_MAX="$2"; shift 2 ;;
        --arch)
            [[ $# -ge 2 ]] || die "$1 缺少参数"
            ARCH="$2"; shift 2 ;;
        --verbose) VERBOSE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "未知参数: $1" ;;
    esac
done

[[ -n "$PREFIX" ]] || { usage; exit 1; }
[[ -d "$PREFIX" ]] || die "目录不存在: $PREFIX"
PREFIX="$(cd "$PREFIX" && pwd)"

version_ok "$GLIBC_MAX"
version_ok "$GLIBCXX_MAX"
version_ok "$CXXABI_MAX"

[[ "$ARCH" == "auto" ]] && ARCH="$(uname -m)"
case "$ARCH" in
    x86_64|aarch64|loongarch64) ;;
    *) die "不支持的宿主架构: $ARCH（可用: x86_64、aarch64、loongarch64）" ;;
esac

READELF_BIN="$(command -v readelf || true)"
[[ -n "$READELF_BIN" ]] || die "找不到 readelf"
command -v file >/dev/null 2>&1 || die "找不到 file"
command -v sort >/dev/null 2>&1 || die "找不到 sort"

version_le() { # $1 <= $2
    [[ "$1" == "$2" ]] && return 0
    [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n 1)" == "$1" ]]
}

max_version() { # $1=GLIBC|GLIBCXX|CXXABI $2=ELF
    local kind="$1" file="$2"
    "$READELF_BIN" --version-info "$file" 2>/dev/null \
        | grep -oE "${kind}_[0-9]+(\.[0-9]+)*" \
        | sed "s/^${kind}_//" \
        | sort -Vu \
        | tail -n 1 || true
}

limit_for() {
    case "$1" in
        GLIBC) echo "$GLIBC_MAX" ;;
        GLIBCXX) echo "$GLIBCXX_MAX" ;;
        CXXABI) echo "$CXXABI_MAX" ;;
    esac
}

elf_machine() {
    "$READELF_BIN" -h "$1" 2>/dev/null \
        | awk -F: '/Machine:/ { sub(/^[ \t]+/, "", $2); print $2; exit }'
}

is_host_elf() {
    local file="$1" machine
    [[ "$(file -Lb "$file" 2>/dev/null || true)" == ELF* ]] || return 1
    machine="$(elf_machine "$file")"
    case "$ARCH:$machine" in
        x86_64:*X86-64*) return 0 ;;
        aarch64:*AArch64*) return 0 ;;
        loongarch64:*LoongArch*) return 0 ;;
        *) return 1 ;;
    esac
}

dirs=()
for subdir in bin lib lib64 libexec; do
    [[ -d "$PREFIX/$subdir" ]] && dirs+=("$PREFIX/$subdir")
done
(( ${#dirs[@]} > 0 )) || die "$PREFIX 下没有 bin/、lib/、lib64/ 或 libexec/"

kinds=(GLIBC GLIBCXX CXXABI)
declare -A max_seen=()
declare -A max_file=()
for kind in "${kinds[@]}"; do
    max_seen[$kind]=""
    max_file[$kind]=""
done

echo "检查目录: $PREFIX"
echo "宿主架构: $ARCH"
echo "版本上限: GLIBC<=$GLIBC_MAX GLIBCXX<=$GLIBCXX_MAX CXXABI<=$CXXABI_MAX"
echo

seen=0
failed=0

while IFS= read -r -d '' file_path; do
    is_host_elf "$file_path" || continue
    seen=$((seen + 1))

    declare -A versions=()
    file_failed=0
    for kind in "${kinds[@]}"; do
        versions[$kind]="$(max_version "$kind" "$file_path")"
        version="${versions[$kind]}"
        [[ -n "$version" ]] || continue

        if [[ -z "${max_seen[$kind]}" ]] || ! version_le "$version" "${max_seen[$kind]}"; then
            max_seen[$kind]="$version"
            max_file[$kind]="$file_path"
        fi

        limit="$(limit_for "$kind")"
        if ! version_le "$version" "$limit"; then
            echo "FAIL: $file_path 需要 ${kind}_${version}，高于上限 ${kind}_${limit}"
            file_failed=1
            failed=1
        fi
    done

    if [[ "$VERBOSE" == "1" && "$file_failed" == "0" ]]; then
        echo "OK: $file_path"
        for kind in "${kinds[@]}"; do
            [[ -n "${versions[$kind]}" ]] &&
                printf '    %-8s %s\n' "$kind" "${versions[$kind]}"
        done
    fi
    unset versions
done < <(find "${dirs[@]}" -type f -print0 2>/dev/null)

(( seen > 0 )) || die "没有找到 $ARCH 宿主 ELF"

echo
echo "检查宿主 ELF: $seen 个"
for kind in "${kinds[@]}"; do
    if [[ -n "${max_seen[$kind]}" ]]; then
        printf '  %-8s 最高 %-10s %s\n' \
            "$kind" "${max_seen[$kind]}" "${max_file[$kind]}"
    else
        printf '  %-8s 未发现版本符号\n' "$kind"
    fi
done

if [[ "$failed" == "0" ]]; then
    echo "PASS: 宿主 ABI 检查通过"
else
    echo "FAIL: 存在超过上限的宿主 ABI 依赖" >&2
    exit 1
fi

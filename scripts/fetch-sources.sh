#!/usr/bin/env bash
#
# fetch-sources.sh —— 拉取/更新各源码组件，并输出拉取情况汇总
#
# 用法:
#   scripts/fetch-sources.sh                拉取全部（已有源码的跳过），最后打印汇总表
#   scripts/fetch-sources.sh gcc            只处理 gcc（Makefile 内部按需调用）
#   scripts/fetch-sources.sh -f             强制重新拉取（会先删除对应目录！）
#   scripts/fetch-sources.sh -n             只演示，不真的拉取
#
# 行为:
#   1) 目录里已有源码（除 .git 外还有内容）  -> 跳过，不动它
#   2) 目录为空 / 只剩一个 .git 空壳        -> 先试方案 B:
#         git submodule update --init --remote --depth 1 <path>
#      失败后 -> 依次尝试 SOURCES 表里的备用镜像，直接 git clone
#   3) 结束后打印每个项目的状态；有失败则退出码非 0（可用 FETCH_STRICT=0 关掉）
#
# 换源: 直接改下面 SOURCES 表里每个项目的 URL 顺序，把能连上的放最前面。
# 关掉方案 B、只走直连镜像:  FETCH_USE_SUBMODULE=0 scripts/fetch-sources.sh
#

set -u

srcdir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$srcdir"

force=0
dry=0
only=""
for arg in "$@"; do
    case "$arg" in
        -f|--force)   force=1 ;;
        -n|--dry-run) dry=1 ;;
        -h|--help)    sed -n '2,20p' "$0"; exit 0 ;;
        -*) echo "未知参数: $arg" >&2; exit 2 ;;
        *)  only="$arg" ;;
    esac
done

use_submodule="${FETCH_USE_SUBMODULE:-1}"
strict="${FETCH_STRICT:-1}"

# ---------------------------------------------------------------------------
# 源码表:  名字 | 目录 | 分支 | 备用 URL(空格分隔，按顺序尝试)
# 把本地能连上的源放到该项目 URL 列表的最前面。
# ---------------------------------------------------------------------------
SOURCES=$(cat <<'EOF'
gcc|gcc|master|https://gcc.gnu.org/git/gcc.git https://mirrors.tuna.tsinghua.edu.cn/git/gcc.git https://github.com/gcc-mirror/gcc.git
binutils|binutils|master|https://sourceware.org/git/binutils-gdb.git https://github.com/bminor/binutils-gdb.git
gdb|gdb|master|https://sourceware.org/git/binutils-gdb.git https://github.com/bminor/binutils-gdb.git
glibc|glibc|master|https://sourceware.org/git/glibc.git https://github.com/bminor/glibc.git
newlib|newlib|loongarch_v4.5.0|https://github.com/loongson/newlib.git git@github.com:loongson/newlib.git
musl|musl|master|https://git.musl-libc.org/git/musl https://github.com/kraj/musl.git git@github.com:kraj/musl.git
qemu|qemu|master|https://mirrors.tuna.tsinghua.edu.cn/git/qemu.git https://gitlab.com/qemu-project/qemu.git https://github.com/qemu/qemu.git git@github.com:qemu/qemu.git
llvm|llvm|main|https://github.com/llvm/llvm-project.git git@github.com:llvm/llvm-project.git
EOF
)

# 串行化，避免 make -j 时多个进程同时拉同一个目录
if command -v flock >/dev/null 2>&1; then
    exec 9>"/tmp/loongarch-fetch.lock"
    flock 9
fi

if ! command -v git >/dev/null 2>&1; then
    echo "错误: 找不到 git" >&2
    exit 127
fi

names=(); states=(); details=()

has_sources() {   # $1 = 目录    除 .git 外还有内容?
    [ -d "$1" ] && [ -n "$(ls -A "$1" 2>/dev/null | grep -vx '\.git')" ]
}

run() {           # 统一处理 dry-run
    if [ "$dry" = 1 ]; then
        printf '       [dry-run] %s\n' "$*"
        return 0
    fi
    "$@"
}

clean_dir() {     # 安全删除：dry-run 不删；有真实源码且未 --force 时拒绝删
    local p="$1"
    [ -e "$p" ] || return 0
    if [ "$force" = 0 ] && has_sources "$p"; then
        echo "!! 拒绝删除非空目录 $p（要强制请加 --force）" >&2
        return 1
    fi
    if [ "$dry" = 1 ]; then
        printf '       [dry-run] rm -rf %s\n' "$p"
        return 0
    fi
    rm -rf "$p"
}

try_submodule() { # $1 = 目录
    [ "$use_submodule" = 1 ] || return 1
    [ -d "$srcdir/.git" ] || return 1
    [ -f "$srcdir/.gitmodules" ] || return 1
    run git submodule update --init --remote --depth 1 "$1"
}

try_mirrors() {   # $1=目录 $2=分支 $3.. = URL
    local path="$1" branch="$2"; shift 2
    local u
    for u in "$@"; do
        printf '    尝试源: %s\n' "$u"
        clean_dir "$path"
        if [ -n "$branch" ]; then
            run git clone --depth 1 --branch "$branch" "$u" "$path" && return 0
        else
            run git clone --depth 1 "$u" "$path" && return 0
        fi
    done
    return 1
}

while IFS='|' read -r name path branch urls; do
    [ -z "$name" ] && continue
    [ -n "$only" ] && [ "$only" != "$name" ] && continue

    if [ "$force" = 0 ] && has_sources "$path"; then
        # 已有源码：不动它，只补一个 .git 以满足 Makefile 的前置条件
        if [ ! -e "$path/.git" ]; then
            run git -C "$path" init -q
        fi
        printf '%-12s 跳过（已有源码）\n' "$name"
        names+=("$name"); states+=("跳过"); details+=("已有源码，未改动")
        continue
    fi

    printf '%-12s 拉取中...\n' "$name"
    clean_dir "$path"
    state=""; detail=""

    if try_submodule "$path"; then
        state="成功"; detail="方案B: git submodule --remote (${branch:-默认分支})"
    elif try_mirrors "$path" "$branch" $urls; then
        state="成功"; detail="备用镜像 clone (${branch:-默认分支})"
    else
        state="失败"; detail="所有源都连不上，请手动换源"
    fi

    printf '%-12s %s\n' "$name" "$state"
    names+=("$name"); states+=("$state"); details+=("$detail")
done <<< "$SOURCES"

# ------------------------------- 汇总 -------------------------------
fail=0
if [ -z "$only" ]; then
    echo
    echo "==================== 源码拉取情况 ===================="
    printf '%-12s %-6s %s\n' "项目" "状态" "说明"
    printf '%-12s %-6s %s\n' "------------" "------" "------------------------------------"
    ok=0; skip=0
    i=0
    while [ "$i" -lt "${#names[@]}" ]; do
        printf '%-12s %-6s %s\n' "${names[$i]}" "${states[$i]}" "${details[$i]}"
        case "${states[$i]}" in
            成功) ok=$((ok+1)) ;;
            跳过) skip=$((skip+1)) ;;
            失败) fail=$((fail+1)) ;;
        esac
        i=$((i+1))
    done
    echo "-----------------------------------------------------"
    printf '共 %d 项：成功 %d，跳过 %d，失败 %d\n' "${#names[@]}" "$ok" "$skip" "$fail"
    if [ "$fail" -gt 0 ]; then
        echo
        echo "有项目拉取失败，手动换源后重试："
        echo "  1) 编辑本脚本顶部的 SOURCES 表，把能连上的 URL 放到该项目最前面"
        echo "  2) 单独重试：   $0 <项目名>"
        echo "  3) 或在别的机器 clone 好，直接拷到对应目录（有内容就会被跳过）"
    fi
else
    for s in "${states[@]}"; do [ "$s" = "失败" ] && fail=1; done
fi

[ "$strict" = 1 ] && [ "$fail" -gt 0 ] && exit 1
exit 0

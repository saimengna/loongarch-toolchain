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
#   1) gitlink 目录按主仓库记录的 commit 初始化/更新。
#   2) 已有源码默认不覆盖；有 gitlink 时会核对 HEAD，版本不一致则失败。
#   3) 空目录先尝试子模块，失败后按镜像表依次尝试备用源。
#      有 gitlink 时，备用源也必须拉取该 gitlink SHA；默认不退回分支最新提交。
#   4) 结束后打印每个项目的状态；有失败则退出码非 0
#      （可用 FETCH_STRICT=0 关掉）。
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
        -h|--help)    sed -n '2,/^$/p' "$0"; exit 0 ;;
        -*) echo "未知参数: $arg" >&2; exit 2 ;;
        *)  only="$arg" ;;
    esac
done

use_submodule="${FETCH_USE_SUBMODULE:-1}"
strict="${FETCH_STRICT:-1}"
allow_branch_fallback="${FETCH_ALLOW_BRANCH_FALLBACK:-0}"

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

is_submodule() {  # $1 = 目录
    git -C "$srcdir" ls-files -s -- "$1" 2>/dev/null \
        | awk '$1 == 160000 { found = 1 } END { exit found ? 0 : 1 }'
}

gitlink_sha() {   # $1 = 目录；输出主仓库记录的 submodule commit
    git -C "$srcdir" ls-tree HEAD -- "$1" 2>/dev/null \
        | awk '$1 == 160000 { print $3; exit }'
}

check_existing_source() { # $1=目录 $2=gitlink SHA；已有源码是否就是固定 commit
    local path="$1" sha="$2" head

    [ -n "$sha" ] || return 0
    head="$(git -C "$path" rev-parse --verify HEAD 2>/dev/null)" || head=""

    if [ -z "$head" ]; then
        echo "!! 已有源码 $path 无法核对版本（没有可用的 git HEAD）" >&2
        echo "   期望 gitlink: $sha" >&2
        echo "   如需按固定 commit 重新拉取，请运行: make fetch FETCH_ARGS=-f" >&2
        return 1
    fi

    if [ "$head" != "$sha" ]; then
        echo "!! 已有源码 $path 版本不匹配" >&2
        echo "   当前 HEAD: $head" >&2
        echo "   期望 gitlink: $sha" >&2
        echo "   如需丢弃现有源码并按 gitlink 重新拉取，请运行: make fetch FETCH_ARGS=-f" >&2
        return 1
    fi
    return 0
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
    git -C "$srcdir" rev-parse --git-dir >/dev/null 2>&1 || return 1
    [ -f "$srcdir/.gitmodules" ] || return 1
    run git -C "$srcdir" submodule update --init --depth 1 "$1"
}

fetch_exact_sha() { # $1=目录 $2=URL $3=SHA
    local path="$1" url="$2" sha="$3"

    if [ "$dry" = 1 ]; then
        printf '       [dry-run] git init %s && git fetch %s %s && git checkout FETCH_HEAD\n' \
            "$path" "$url" "$sha"
        return 0
    fi

    git init -q "$path" || return 1
    git -C "$path" remote add origin "$url" || return 1

    # Some servers reject fetching an unadvertised SHA in shallow mode.  Try a
    # shallow fetch first, then a normal fetch for mirrors that require it.
    if git -C "$path" fetch --depth 1 origin "$sha" 2>/dev/null; then
        git -C "$path" checkout --detach FETCH_HEAD
        return $?
    fi
    if git -C "$path" fetch origin "$sha" 2>/dev/null; then
        git -C "$path" checkout --detach FETCH_HEAD
        return $?
    fi
    return 1
}

try_mirrors() {   # $1=目录 $2=分支 $3=gitlink SHA $4.. = URL
    local path="$1" branch="$2" sha="$3"; shift 3
    local u

    MIRROR_MODE=""

    if [ -n "$sha" ]; then
        for u in "$@"; do
            printf '    尝试源: %s（gitlink %s）\n' "$u" "$sha"
            clean_dir "$path" || return 1
            if fetch_exact_sha "$path" "$u" "$sha"; then
                MIRROR_MODE="gitlink"
                return 0
            fi
            echo "    !! 该源无法提供 gitlink commit，继续尝试下一个源" >&2
        done

        if [ "$allow_branch_fallback" != 1 ]; then
            echo "    !! 无法获取 gitlink commit，拒绝退回分支最新提交" >&2
            return 1
        fi
        echo "    !! 警告: 将退回分支最新提交，源码可能不再与 gitlink 一致" >&2
    fi

    for u in "$@"; do
        printf '    尝试源: %s\n' "$u"
        clean_dir "$path"
        if [ -n "$branch" ]; then
            run git clone --depth 1 --branch "$branch" "$u" "$path" && {
                MIRROR_MODE="branch"
                return 0
            }
        else
            run git clone --depth 1 "$u" "$path" && {
                MIRROR_MODE="branch"
                return 0
            }
        fi
    done
    return 1
}

while IFS='|' read -r name path branch urls; do
    [ -z "$name" ] && continue
    [ -n "$only" ] && [ "$only" != "$name" ] && continue

    if [ "$force" = 0 ] && is_submodule "$path"; then
        if try_submodule "$path"; then
            printf '%-12s 跳过（已按 gitlink 更新）\n' "$name"
            names+=("$name"); states+=("跳过"); details+=("gitlink 已同步")
            continue
        fi
    fi

    if [ "$force" = 0 ] && has_sources "$path"; then
        sha="$(gitlink_sha "$path")"
        if ! check_existing_source "$path" "$sha"; then
            names+=("$name"); states+=("失败"); details+=("已有源码与 gitlink 不一致")
            continue
        fi

        # 已有源码：不动它，只补一个 .git 以满足 Makefile 的前置条件
        if [ ! -e "$path/.git" ]; then
            run git -C "$path" init -q
        fi
        printf '%-12s 跳过（已有源码）\n' "$name"
        if [ -n "$sha" ]; then
            names+=("$name"); states+=("跳过"); details+=("已有源码，gitlink 已匹配")
        else
            names+=("$name"); states+=("跳过"); details+=("已有源码，未改动")
        fi
        continue
    fi

    printf '%-12s 拉取中...\n' "$name"
    clean_dir "$path"
    state=""; detail=""
    sha="$(gitlink_sha "$path")"

    if try_submodule "$path"; then
        state="成功"; detail="git submodule (gitlink commit)"
    elif try_mirrors "$path" "$branch" "$sha" $urls; then
        if [ "$MIRROR_MODE" = "gitlink" ]; then
            state="成功"; detail="备用镜像 clone (gitlink ${sha:0:12})"
        else
            state="成功"; detail="备用镜像 clone (分支 ${branch:-默认分支}，未固定)"
        fi
    else
        if [ -n "$sha" ]; then
            state="失败"; detail="无法按 gitlink ${sha:0:12} 拉取，未退回分支"
        else
            state="失败"; detail="所有源都连不上，请手动换源"
        fi
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

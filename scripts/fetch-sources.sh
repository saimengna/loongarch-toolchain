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
# 固定版本模式:
#   FETCH_LOCKED=1 scripts/fetch-sources.sh gcc
#   SOURCE_LOCK=/path/to/sources.lock FETCH_LOCKED=1 ...
#
# 行为:
#   1) 普通模式：已有源码跳过；空目录优先走 git submodule --remote，再尝试镜像。
#   2) 锁定模式：从 sources.lock 读取 commit，已经存在则校验 HEAD，不一致则
#      从当前组件的镜像列表拉取该 commit；不会使用 --remote。
#   3) 结束后打印每个项目的状态；有失败则退出码非 0
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
        -h|--help)    sed -n '2,23p' "$0"; exit 0 ;;
        -*) echo "未知参数: $arg" >&2; exit 2 ;;
        *)  only="$arg" ;;
    esac
done

use_submodule="${FETCH_USE_SUBMODULE:-1}"
strict="${FETCH_STRICT:-1}"
lock_file="${SOURCE_LOCK:-$srcdir/sources.lock}"
locked="${FETCH_LOCKED:-0}"

is_locked() {
    case "$locked" in
        1|true|yes|TRUE|YES) return 0 ;;
        *) return 1 ;;
    esac
}

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

if is_locked && [ ! -f "$lock_file" ]; then
    echo "错误: 锁定模式需要 $lock_file" >&2
    exit 2
fi

names=(); states=(); details=()

has_sources() {   # $1 = 目录    除 .git 外还有内容?
    [ -d "$1" ] && [ -n "$(ls -A "$1" 2>/dev/null | grep -vx '\.git')" ]
}

has_git() {       # $1 = 目录
    [ -d "$1/.git" ] || [ -f "$1/.git" ]
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

lock_sha_for() { # $1 = component
    awk -v n="$1" '$1 == n && $2 !~ /^#/ { print $2; exit }' "$lock_file" 2>/dev/null
}

fetch_locked() { # $1=目录 $2=sha $3..=URL
    local path="$1" sha="$2"; shift 2
    local u head=""

    if has_git "$path"; then
        head="$(git -C "$path" rev-parse HEAD 2>/dev/null || true)"
        if [ "$head" = "$sha" ]; then
            return 0
        fi
        # 处理缓存里留下的残缺 .git 目录。
        if ! git -C "$path" rev-parse --git-dir >/dev/null 2>&1; then
            run rm -rf "$path/.git"
            run git -C "$path" init -q
        fi
    elif has_sources "$path"; then
        echo "!! $path 有源码但没有 git 历史，无法校验锁定 commit；请用 -f 重新拉取" >&2
        return 1
    else
        run mkdir -p "$path"
        run git -C "$path" init -q
    fi

    if ! git -C "$path" remote get-url origin >/dev/null 2>&1; then
        run git -C "$path" remote add origin "$1"
    fi

    for u in "$@"; do
        printf '    尝试锁定源: %s\n' "$u"
        if run git -C "$path" fetch --depth 1 "$u" "$sha"; then
            if run git -C "$path" checkout --detach --force "$sha"; then
                return 0
            fi
        fi
    done
    return 1
}

while IFS='|' read -r name path branch urls; do
    [ -z "$name" ] && continue
    [ -n "$only" ] && [ "$only" != "$name" ] && continue

    if is_locked; then
        sha="$(lock_sha_for "$name")"
        if [ -z "$sha" ]; then
            printf '%-12s 失败（sources.lock 中没有 %s）\n' "$name" "$name"
            names+=("$name"); states+=("失败"); details+=("sources.lock 缺少该组件")
            continue
        fi

        if [ "$force" = 0 ] && has_git "$path" \
            && [ "$(git -C "$path" rev-parse HEAD 2>/dev/null || true)" = "$sha" ]; then
            printf '%-12s 跳过（已锁定 %s）\n' "$name" "${sha:0:12}"
            names+=("$name"); states+=("跳过"); details+=("已锁定 ${sha:0:12}")
            continue
        fi

        printf '%-12s 锁定拉取 %s...\n' "$name" "${sha:0:12}"
        if [ "$force" = 1 ]; then
            clean_dir "$path" || true
        fi
        if fetch_locked "$path" "$sha" $urls; then
            state="成功"; detail="锁定 ${sha:0:12}"
        else
            state="失败"; detail="无法拉取锁定 commit ${sha:0:12}"
        fi
        printf '%-12s %s\n' "$name" "$state"
        names+=("$name"); states+=("$state"); details+=("$detail")
        continue
    fi

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

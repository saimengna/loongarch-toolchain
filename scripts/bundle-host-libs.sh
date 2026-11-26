#!/usr/bin/env bash
# Bundle the host runtime libraries used by the glibc-2.28 builder and make
# the installed toolchain independent of LD_LIBRARY_PATH.
set -euo pipefail

PREFIX=""
COPY_ONLY=0
PATCH_ONLY=0
SOURCE_DIRS=()
LIB_PATTERNS=(libmpfr.so.4 libmpc.so.3 libgmp.so.10)
PATCHED_FILES=()

usage() {
  cat <<'EOT'
用法: scripts/bundle-host-libs.sh --prefix DIR [选项]

  --prefix DIR       工具链安装目录
  --copy-only        只复制构建镜像中的宿主运行库
  --patch-only       只给已有工具链写 RPATH
  --source-dir DIR   运行库搜索目录，可重复指定

不带 --copy-only/--patch-only 时，先复制运行库再写 RPATH。复制步骤应在
glibc-2.28 构建容器内运行；写 RPATH 步骤应在最终宿主机上运行，并确保
patchelf 可用。
EOT
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix) PREFIX="$2"; shift 2 ;;
    --copy-only) COPY_ONLY=1; shift ;;
    --patch-only) PATCH_ONLY=1; shift ;;
    --source-dir) SOURCE_DIRS+=("$2"); shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数: $1" >&2; usage; exit 1 ;;
  esac
done

[[ -n "$PREFIX" ]] || { usage; exit 1; }
[[ -d "$PREFIX" ]] || { echo "工具链目录不存在: $PREFIX" >&2; exit 1; }
if [[ "$COPY_ONLY" == 1 && "$PATCH_ONLY" == 1 ]]; then
  echo "--copy-only 和 --patch-only 不能同时使用" >&2
  exit 1
fi

if [[ "$COPY_ONLY" == 0 && "$PATCH_ONLY" == 0 ]]; then
  COPY_ONLY=1
  PATCH_ONLY=1
fi

if [[ ${#SOURCE_DIRS[@]} -eq 0 ]]; then
  SOURCE_DIRS=(/usr/lib64 /usr/lib /lib64 /lib)
fi

copy_runtime_libs() {
  local pattern src name dest target copied
  local -A seen=()

  mkdir -p "$PREFIX/lib"
  for pattern in "${LIB_PATTERNS[@]}"; do
    copied=0
    while IFS= read -r -d '' src; do
      name="$(basename "$src")"
      [[ -n "${seen[$name]:-}" ]] && continue
      seen[$name]=1

      dest="$PREFIX/lib/$name"
      if [[ -L "$src" ]]; then
        target="$(readlink "$src")"
        # Keep the symlink inside the package even if the image used an
        # absolute or cross-directory target.
        [[ "$target" == */* ]] && target="$(basename "$target")"
        ln -sfn "$target" "$dest"
        copied=1
      elif [[ -f "$src" ]]; then
        install -m 0755 "$src" "$dest"
        copied=1
      fi
    done < <(find "${SOURCE_DIRS[@]}" -maxdepth 1 -name "${pattern}*" -print0 2>/dev/null)

    if [[ "$copied" == 0 ]]; then
      echo "找不到宿主运行库: ${pattern}* (搜索: ${SOURCE_DIRS[*]})" >&2
      return 1
    fi
  done

  echo "已复制宿主运行库到 $PREFIX/lib: ${LIB_PATTERNS[*]}"
}

host_elf() {
  local file="$1" kind
  [[ -f "$file" && ! -L "$file" ]] || return 1
  kind="$(file -b "$file" 2>/dev/null || true)"
  [[ "$kind" == *ELF* ]] || return 1
  [[ "$kind" != *"statically linked"* && "$kind" != *"static-pie linked"* ]] || return 1

  case "$(uname -m)" in
    x86_64|amd64) [[ "$kind" == *x86-64* ]] ;;
    aarch64|arm64) [[ "$kind" == *aarch64* || "$kind" == *ARM64* ]] ;;
    loongarch64|loongarch64*) [[ "$kind" == *LoongArch* ]] ;;
    *) return 1 ;;
  esac
}

patch_one() {
  local file="$1" rpath="$2" actual
  "$PATCHELF" --force-rpath --set-rpath "$rpath" "$file"
  actual="$("$PATCHELF" --print-rpath "$file")"
  if [[ "$actual" != "$rpath" ]]; then
    echo "RPATH 写入失败: $file (期望 $rpath, 实际 $actual)" >&2
    return 1
  fi
  PATCHED_FILES+=("$file")
}

patch_host_rpaths() {
  local file count

  for pattern in "${LIB_PATTERNS[@]}"; do
    compgen -G "$PREFIX/lib/${pattern}*" >/dev/null || {
      echo "缺少需要打包的宿主运行库: $PREFIX/lib/${pattern}*" >&2
      return 1
    }
  done

  count=0
  while IFS= read -r -d '' file; do
    host_elf "$file" || continue
    patch_one "$file" '$ORIGIN/../lib'
    count=$((count + 1))
  done < <(find "$PREFIX/bin" -maxdepth 1 -type f -print0)
  (( count > 0 )) || { echo "没有在 $PREFIX/bin 找到宿主 ELF" >&2; return 1; }

  count=0
  while IFS= read -r -d '' file; do
    host_elf "$file" || continue
    patch_one "$file" '$ORIGIN/../../../../lib'
    count=$((count + 1))
  done < <(find "$PREFIX/libexec/gcc" -mindepth 3 -maxdepth 3 -type f -print0 2>/dev/null)
  (( count > 0 )) || { echo "没有在 $PREFIX/libexec/gcc 找到宿主 ELF" >&2; return 1; }

  # Do not rewrite the bundled runtime libraries themselves.  patchelf
  # 0.18 corrupts some inputs (for example libmpc.so.3 on x86_64, which
  # then fails with "ELF load command address/offset not properly
  # aligned").  The DT_RPATH set on bin/ and libexec/gcc/ programs is
  # inherited by their dependencies, so the libraries are still found
  # without carrying an RPATH of their own.

  echo "已为 ${#PATCHED_FILES[@]} 个宿主 ELF 写入相对 RPATH"
}

verify_no_missing_libraries() {
  local file output failed=0
  for file in "${PATCHED_FILES[@]}"; do
    if ! output="$(env -u LD_LIBRARY_PATH ldd "$file" 2>&1)"; then
      case "$output" in
        *"not a dynamic executable"*|*"statically linked"*) continue ;;
      esac
      echo "ldd 失败: $file" >&2
      printf '%s\n' "$output" >&2
      failed=1
      continue
    fi
    if grep -q 'not found' <<< "$output"; then
      echo "存在未满足的动态库依赖: $file" >&2
      printf '%s\n' "$output" >&2
      failed=1
    fi
  done
  (( failed == 0 )) || return 1
  echo "动态库依赖检查通过（未使用 LD_LIBRARY_PATH）"
}

if [[ "$COPY_ONLY" == 1 ]]; then
  copy_runtime_libs
fi

if [[ "$PATCH_ONLY" == 1 ]]; then
  PATCHELF="$(command -v patchelf || true)"
  [[ -n "$PATCHELF" ]] || { echo "找不到 patchelf" >&2; exit 1; }
  patch_host_rpaths
  verify_no_missing_libraries
fi

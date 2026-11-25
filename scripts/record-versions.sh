#!/usr/bin/env bash
# Record the exact upstream commit used by every component.
set -euo pipefail

srcdir="$(cd "$(dirname "$0")/.." && pwd)"
out="${1:-$PWD/versions.txt}"
components=(binutils gcc gdb glibc newlib musl uclibc-ng qemu llvm)

declare -A dirs=(
  [binutils]="${BINUTILS_SRCDIR:-$srcdir/binutils}"
  [gcc]="${GCC_SRCDIR:-$srcdir/gcc}"
  [gdb]="${GDB_SRCDIR:-$srcdir/gdb}"
  [glibc]="${GLIBC_SRCDIR:-$srcdir/glibc}"
  [newlib]="${NEWLIB_SRCDIR:-$srcdir/newlib}"
  [musl]="${MUSL_SRCDIR:-$srcdir/musl}"
  [uclibc-ng]="${UCLIBC_SRCDIR:-$srcdir/uclibc-ng}"
  [qemu]="${QEMU_SRCDIR:-$srcdir/qemu}"
  [llvm]="${LLVM_SRCDIR:-$srcdir/llvm}"
)

declare -A existing_sha=()
declare -A existing_date=()
if [[ -f "$out" ]]; then
  while read -r name sha date _; do
    [[ -n "${name:-}" && "$name" != "component" ]] || continue
    existing_sha["$name"]="$sha"
    existing_date["$name"]="${date:-}"
  done < "$out"
fi

: > "$out"
printf '%-10s %-40s %s\n' component commit date > "$out"
for c in "${components[@]}"; do
  dir="${dirs[$c]}"
  if [[ -d "$dir/.git" || -f "$dir/.git" ]]; then
    sha="$(git -C "$dir" rev-parse HEAD 2>/dev/null)" || sha=""
    if [[ -n "$sha" ]]; then
      date="$(git -C "$dir" log -1 --format=%cI 2>/dev/null)" || date=""
      printf '%-10s %-40s %s\n' "$c" "$sha" "$date" >> "$out"
      continue
    fi
  fi
  if [[ -n "${existing_sha[$c]:-}" ]]; then
    printf '%-10s %-40s %s\n' "$c" "${existing_sha[$c]}" "${existing_date[$c]:-}" >> "$out"
  fi
done

repo_sha="$(git -C "$srcdir" rev-parse HEAD 2>/dev/null || true)"
if [[ -n "$repo_sha" ]]; then
  repo_date="$(git -C "$srcdir" log -1 --format=%cI 2>/dev/null || true)"
  repo_tag="${TAG:-${SOURCE_TAG:-}}"
  if [[ -z "$repo_tag" ]]; then
    repo_tag="$(git -C "$srcdir" describe --tags --always 2>/dev/null || true)"
  fi
  printf '%-10s %-40s %s\n' toolchain "$repo_sha" "$repo_date" >> "$out"
  printf '%-10s %-40s %s\n' tag "${repo_tag:-unknown}" "" >> "$out"
fi

if [[ -n "${BUILDER_IMAGE:-}" ]]; then
  printf '%-10s %-40s %s\n' builder-image "$BUILDER_IMAGE" "" >> "$out"
elif [[ -n "${existing_sha[builder-image]:-}" ]]; then
  printf '%-10s %-40s %s\n' builder-image "${existing_sha[builder-image]}" "" >> "$out"
fi

echo "==> 版本记录: $out"
cat "$out"

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

: > "$out"
printf '%-10s %-40s %s\n' component commit date > "$out"
for c in "${components[@]}"; do
  dir="${dirs[$c]}"
  [[ -d "$dir/.git" || -f "$dir/.git" ]] || continue
  sha="$(git -C "$dir" rev-parse HEAD 2>/dev/null)" || continue
  date="$(git -C "$dir" log -1 --format=%cI 2>/dev/null)" || date=""
  printf '%-10s %-40s %s\n' "$c" "$sha" "$date" >> "$out"
done

echo "==> 版本记录: $out"
cat "$out"

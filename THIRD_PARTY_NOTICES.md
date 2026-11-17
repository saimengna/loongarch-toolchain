# Third-Party Notices

This repository contains its own build system and CI scripts, which are
licensed under the GNU General Public License, version 3. See `LICENSE`.

It also contains or consumes third-party material. The license and copyright
notices in the original files and upstream repositories control those files.
This document is a summary, not a replacement for those notices.
It is copied into each packaged toolchain together with `LICENSE` and the
corresponding `VERSIONS.txt`.

## Linux UAPI headers

The files under `linux-headers/include/` are Linux kernel UAPI headers. Their
copyright and license notices are kept in the individual files. The tree
contains several SPDX license expressions, including:

- `GPL-2.0 WITH Linux-syscall-note`
- `GPL-2.0+ WITH Linux-syscall-note`
- `GPL-2.0-only WITH Linux-syscall-note`
- `LGPL-2.0+ WITH Linux-syscall-note`
- `LGPL-2.1+ WITH Linux-syscall-note`
- `MIT`
- `BSD-2-Clause`
- `BSD-3-Clause`
- `CDDL-1.0`
- `Linux-OpenIB`
- combinations of the above

Some files are public domain or have other permissive notices instead of an
SPDX identifier. Do not assume that the root `LICENSE` applies to every header;
read the notice in the relevant file. To list the SPDX identifiers currently
present:

```bash
rg --no-filename -o 'SPDX-License-Identifier:[^\r\n]*' linux-headers/include \
  | sort -u
```

## Upstream components

The following components are fetched from their upstream repositories as Git
submodules. Their source code is not copied into this repository's Git history;
only the submodule gitlinks are recorded here.

| Component | Upstream | License family |
|---|---|---|
| GCC | https://github.com/gcc-mirror/gcc | GPLv3 or later, with GCC runtime exceptions |
| binutils / GDB | https://sourceware.org/git/binutils-gdb.git | GPLv3 or later |
| glibc | https://github.com/bminor/glibc | LGPLv2.1 or later, with some GPL components |
| newlib | https://github.com/loongson/newlib | BSD-style and other permissive notices |
| musl | https://github.com/kraj/musl | MIT |
| QEMU | https://gitlab.com/qemu-project/qemu | GPLv2 and other component-specific licenses |
| LLVM | https://github.com/llvm/llvm-project | Apache-2.0 WITH LLVM-exception |

Some optional components, such as uClibc-ng and Picolibc, are not currently
part of the supported release matrix. If they are added later, their own
licenses must be included in this notice.

Always check the license files in the exact upstream revision recorded by the
submodule gitlinks and by `VERSIONS.txt`, and in each component's source tree,
before distributing source or binary artifacts.

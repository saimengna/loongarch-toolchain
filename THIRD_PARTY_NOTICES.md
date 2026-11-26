# Third-Party Notices

This repository contains its own build system and CI scripts, which are
licensed under the GNU General Public License, version 3. See `LICENSE`.

It also contains or consumes third-party material. The license and copyright
notices in the original files and upstream repositories control those files.
This document is a summary, not a replacement for those notices.
It is copied into each packaged toolchain together with `LICENSE`,
`LICENSE.LGPL-2.1`, `LICENSE.GPL-2.0`, `SOURCE-OFFER.txt`, and the
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
| GMP | https://gmplib.org/ | LGPLv3+ or GPLv2+ |
| MPFR | https://www.mpfr.org/ | LGPLv3+ |
| MPC | https://www.multiprecision.org/mpc/ | LGPLv3+ |

The CI-produced toolchain archives also include runtime copies of GMP, MPFR,
and MPC shared libraries from the glibc-2.28 builder image. Their copyright and
license notices remain with the upstream projects.

## Source availability

Every packaged toolchain contains `SOURCE-OFFER.txt`. It records the exact
upstream revisions, the build scripts revision, and the URL where the
Corresponding Source can be obtained. `VERSIONS.txt` records the same
revisions together with the toolchain repository commit and tag.

The current release matrix does not include GDB. If GDB is added to a future
package, it is covered by the same GPLv3 source-availability statement.

Some optional components, such as Picolibc, are not currently
part of the supported release matrix. If they are added later, their own
licenses must be included in this notice.

The exact upstream revision is recorded by the submodule gitlinks, by
`VERSIONS.txt`, and by `SOURCE-OFFER.txt`. When distributing source or binary
artifacts, check the license files in that exact revision and in each
component's source tree. The GPLv3 and LGPLv2.1 texts are included in the
package so recipients do not need to fetch them separately.

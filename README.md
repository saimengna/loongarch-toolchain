# loongarch-toolchain

面向 LoongArch 的交叉工具链超级工程，结构参考
[riscv-gnu-toolchain](https://github.com/riscv-collab/riscv-gnu-toolchain)。

本仓库包含顶层 `configure`、`Makefile.in`、测试脚本、QEMU/DejaGNU
封装，以及 LoongArch Linux UAPI 头文件。gcc、binutils、glibc、newlib、
musl、qemu 和 llvm 从各自的上游仓库获取，不在本仓库重复存放源码。

## 支持的工具链

| target | 三元组 | C 库 |
|--------|--------|------|
| `newlib` | `loongarch64-unknown-elf` | newlib（裸机） |
| `linux` | `loongarch64-unknown-linux-gnu` | glibc |
| `musl` | `loongarch64-unknown-linux-musl` | musl |

`uclibc` 目标仍保留在 Makefile 中，但当前 LoongArch GCC 不支持
`loongarch64-unknown-linux-uclibc`，因此暂不作为发布目标。Picolibc
尚未接入。

## 快速开始

首次克隆时初始化子模块：

```bash
git clone --recursive git@github.com:YOU/loongarch-toolchain.git
cd loongarch-toolchain
```

配置并构建 glibc 工具链：

```bash
./configure --prefix="$HOME/loongarch64" --enable-linux
make -j"$(nproc)" linux
```

构建裸机 newlib 工具链：

```bash
./configure --prefix="$HOME/loongarch64-elf"
make -j"$(nproc)" newlib
```

构建 musl 工具链：

```bash
./configure --prefix="$HOME/loongarch64-musl" --enable-musl
make -j"$(nproc)" musl
```

需要 LLVM/Clang 时在 configure 阶段加 `--enable-llvm`：

```bash
./configure --prefix="$HOME/loongarch64" --enable-linux --enable-llvm
make -j"$(nproc)" linux
```

构建 QEMU user-mode 模拟器：

```bash
make -j"$(nproc)" build-qemu
```

## 获取或更新源码

子模块没有初始化，或者某个组件目录为空时：

```bash
./configure --prefix="$HOME/loongarch64" --enable-linux
make fetch
```

如果还没有生成 Makefile，也可以直接运行
`bash scripts/fetch-sources.sh`。

`make fetch` 会优先尝试子模块，失败后按
`scripts/fetch-sources.sh` 顶部的镜像表逐个尝试备用源。已有源码默认
不覆盖；强制重新拉取使用：

```bash
make fetch FETCH_ARGS=-f
```

本机连不上 GitHub HTTPS、但 SSH 可用时，可以跳过子模块直接走镜像/SSH：

```bash
FETCH_USE_SUBMODULE=0 make fetch
```

正式 CI 按根目录的 `sources.lock` 固定每个组件的 commit。手动复现锁定版本：

```bash
FETCH_LOCKED=1 scripts/fetch-sources.sh gcc
```

锁定模式会校验已有源码的 `HEAD`；不一致时会从镜像表拉取锁定的 SHA。只改
`sources.lock` 才会改变正式构建的源码版本，`--remote` 不会参与锁定模式。

## 构建目标

| 目标 | 作用 |
|------|------|
| `all` | 构建 configure 选中的默认目标 |
| `newlib` | newlib 裸机工具链 |
| `linux` | glibc GNU/Linux 工具链 |
| `musl` | musl GNU/Linux 工具链 |
| `build-binutils` | 单独构建 binutils |
| `build-gcc1` / `build-gcc2` | 单独构建 GCC 第一阶段/第二阶段 |
| `build-libc` | 单独构建当前目标的 C 库 |
| `build-gdb` | 单独构建 GDB |
| `build-qemu` / `build-sim` | 构建 QEMU user-mode 模拟器 |
| `build-llvm` | 构建 LLVM/Clang 工具链 |
| `check` | 运行当前目标的 GCC 测试 |
| `check-glibc-linux` | 运行 glibc 自身测试 |
| `check-gcc-linux` / `check-gcc-newlib` / `check-gcc-musl` | 分别运行三种 C 库的 GCC 测试 |
| `check-newlib-nano` | 运行 newlib-nano 测试 |
| `check-binutils-linux` / `check-binutils-newlib` | 运行 binutils/GAS/LD 测试 |
| `check-gdb-linux` / `check-gdb-newlib` | 运行 GDB 测试 |
| `report` | 汇总当前目标的测试结果 |
| `report-linux` / `report-newlib` / `report-musl` | 汇总对应目标的测试结果 |
| `report-binutils` / `report-gdb` | 单独汇总 binutils 或 GDB 结果 |
| `package` | 把安装目录打成 `.tar.xz` |
| `versions` | 记录各组件当前 commit 到 `versions.txt` |
| `fetch` | 拉取或更新所有组件源码 |
| `clean` | 删除 `build-*`、`install-*` 和 `stamps` |

打包示例：

```bash
make package PACKAGE_MODE=linux PACKAGE_OUTDIR="$PWD/artifacts"
```

生成的压缩包会包含 `VERSIONS.txt`，记录 gcc、binutils、glibc 等组件的
实际 commit。

测试报告默认只打印统计信息。需要“有意外失败就退出非零”时：

```bash
make report-linux REPORT_STRICT=1
```

## 目录结构

```text
.
├── configure / configure.ac      顶层 autoconf 配置
├── Makefile.in                   顶层构建规则
├── sources.lock                  正式构建使用的源码 commit
├── linux-headers/include/        vendored LoongArch UAPI 头文件
├── scripts/                      源码拉取、DejaGNU board、QEMU/awk/sed wrapper
├── .github/containers/          glibc 2.28 构建容器
├── .github/                      CI 与 runner 辅助脚本
├── build-*/                      各组件 out-of-tree 构建目录
├── stamps/                       已完成步骤的 stamp 文件
├── install-*/                    分阶段安装目录
└── gcc/ binutils/ gdb/ glibc/ newlib/ musl/ qemu/ llvm/   子模块
```

## CI 与发布

GitHub Actions 使用与本地相同的 `configure` 和 `make` 流程，但没有
nightly/定时任务：

- `.github/workflows/release.yml`：正式发布链路。推送 `v*` tag 时在
  glibc 2.28 容器中按 `sources.lock` 构建六个 GCC 包：
  x86_64/aarch64 × newlib/glibc/musl。发布包会上传 `SHA256SUMS`，并在发布前
  重新解压并检查每个编译器。
- `.github/workflows/build.yml`：仅供手动开发验证，保留 Ubuntu 22.04/24.04
  的普通宿主构建、LLVM 和 QEMU/testsuite 能力；不参与正式发布。
- `.github/workflows/smoke-release.yml`：手动 smoke 构建，用于快速验证
  Ubuntu 22.04 + newlib 链路；它产生草稿预发布，不是正式发布。
- `.github/workflows/builder-image.yml`：仅手动触发，分别在
  `ubuntu-24.04` 和 `ubuntu-24.04-arm` 上构建
  `ghcr.io/OWNER/loongarch-builder:glibc228-amd64` 与
  `ghcr.io/OWNER/loongarch-builder:glibc228-arm64`。镜像基于
  `manylinux_2_28`，所以编出来的宿主编译器只要求 glibc 2.28+。
- `.github/workflows/matrix-release.yml`：手动矩阵验证，使用上面的构建镜像
  生成单个或全部六个 GCC 工具链，并创建草稿预发布。`scope` 可用
  `single-{x86|arm}-{newlib|glibc|musl}` 单独验证，或用 `x86-all`、
  `arm-all`、`full`。正式发布请推送 `v*` tag，不要使用这个 workflow。

正式发布矩阵会自动设置 `FETCH_LOCKED=1`，从 `sources.lock` 读取固定
commit；源码缓存 key 也包含锁文件哈希。构建在 `manylinux_2_28` 容器内完成，
因此用户不需要安装 AlmaLinux 或 `manylinux`，容器只是构建环境。
中间构建产物作为 Actions Artifact 只保留 1 天；长期保存以 GitHub Release
附件为准。

第一次使用请按顺序操作：

1. 在 Actions 里手动运行 `Build glibc 2.28 builder images`。
2. 运行 `GCC Matrix Test`，先选 `single-x86-newlib` 或
   `single-arm-newlib` 验证链路。
3. 再选 `single-x86-glibc`、`single-arm-glibc`，最后选 `full`。
4. 推送 `v0.1.0` 这类 tag，由正式的 `Release` workflow 构建并发布六个
   glibc 2.28 GCC 包。

构建出来的宿主二进制只要求 glibc 2.28+；`newlib` 和 `musl` 目标本身不使用
glibc。所有归档里的 `VERSIONS.txt` 会记录实际源码 commit，`SOURCES.lock`
记录本次构建的锁文件，`BUILD-INFO.txt` 记录宿主架构、glibc 上限和目标库。
正式 Release 还会提供 `SHA256SUMS`，下载后可在同一目录执行
`sha256sum -c SHA256SUMS`。

产物命名格式：

```text
loongarch64-{elf|glibc|musl}-{x86_64|aarch64}-host-glibc228[-target-glibc236][-release].tar.xz
```

## 注意

- 当前没有加入 Picolibc。
- uClibc 构建暂不可用，原因是 GCC 没有对应的 LoongArch target triplet。
- LoongArch 没有 RISC-V 的 Spike/PK，CI 模拟器统一使用 QEMU user-mode。
- 目前没有搬入 RISC-V 的 Dhrystone 基准和 GDB allowlist；测试报告默认
  打印汇总，可用 `REPORT_STRICT=1` 对意外失败做强校验。
- `--enable-llvm` 会显著增加构建时间和磁盘占用；时间紧张时先只构建 GCC。
- LLVM 需要 Python ≥3.8；系统 `python3` 太旧时用
  `make LLVM_PYTHON=/path/to/python3 QEMU_PYTHON=/path/to/python3`。
- 当前正式 Release 只构建 GCC，不包含 GDB、LLVM、QEMU 和 testsuite；
  Ubuntu 22.04/24.04 的普通构建仅用于手动验证。`x86_64` 和 `aarch64`
  产物不能混用。
- 子模块提交和 CI 发布流程还需要在第一次真实推送后做一次端到端验证。

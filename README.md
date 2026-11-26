# loongarch-toolchain

面向 LoongArch 的 GCC / LLVM 交叉工具链，提供 newlib（裸机）、glibc 和 musl
三种 C 库，每种都有 GCC 版和 GCC+LLVM 版。

| 项目 | 说明 |
|------|------|
| 目标架构 | `loongarch64-lp64d` |
| 宿主机 | Linux `x86_64` 或 `aarch64` |
| 宿主 glibc | 2.28 及以上 |
| 目标 C 库 | newlib（裸机）/ glibc 2.36 / musl |
| 编译器 | GCC，或 GCC + LLVM（clang / clang++ / lld） |

宿主编译器依赖的 glibc 符号版本最高为 2.28，因此在 Ubuntu 20.04、Debian 10、
AlmaLinux 8 及更新的系统上可以直接运行，不需要设置 `LD_LIBRARY_PATH`。

## 下载

在 [Releases](https://github.com/saimengna/loongarch-toolchain/releases) 页面
下载对应归档。文件名格式：

```text
loongarch64-{glibc|musl|elf}-{x86_64|aarch64}-host-glibc228[-target-glibc236][-llvm]-release.tar.xz
```

- `glibc` → 三元组 `loongarch64-unknown-linux-gnu`
- `musl` → 三元组 `loongarch64-unknown-linux-musl`
- `elf` → 三元组 `loongarch64-unknown-elf`（newlib，裸机）
- `x86_64` / `aarch64` 是宿主架构，必须与你运行编译器的机器一致
- `-llvm` 表示在 GCC 工具链基础上增加 clang、clang++ 和 lld
- 发布类型后缀：`-release` 正式版，`-nightly` 每日构建，`-ci` 为 CI 产物

校验并解压：

```bash
sha256sum -c SHA256SUMS

mkdir -p ~/loongarch64
tar xJf loongarch64-glibc-x86_64-host-glibc228-target-glibc236-release.tar.xz \
  -C ~/loongarch64 --strip-components=1
export PATH="$HOME/loongarch64/bin:$PATH"
```

`--strip-components=1` 用于去掉归档内的 `install-toolchain` 顶层目录。

## 使用

### C / C++（GCC）

```bash
cat > hello.c <<'EOF'
#include <stdio.h>

int main(void) {
    puts("hello loongarch");
    return 0;
}
EOF

loongarch64-unknown-linux-gnu-gcc hello.c -o hello
loongarch64-unknown-linux-gnu-gcc -static hello.c -o hello-static
loongarch64-unknown-linux-gnu-g++ hello.cc -o hello-cpp

loongarch64-unknown-linux-gnu-readelf -h hello | grep Machine
```

`Machine` 一行应当是 `LoongArch`。

在 `x86_64` 或 `aarch64` 上运行生成的程序需要 QEMU user-mode：

```bash
sudo apt-get install -y qemu-user
qemu-loongarch64 -L ~/loongarch64/sysroot ./hello
```

### LLVM / clang

带 `-llvm` 的包同时提供 `clang`、`clang++`、`lld` 和 LLVM 工具，既有不带前缀
的名字，也有 `<三元组>-clang` 形式的别名：

```bash
loongarch64-unknown-linux-gnu-clang -mabi=lp64d hello.c -o hello
loongarch64-unknown-linux-gnu-clang++ -mabi=lp64d hello.cc -o hello-cpp
llvm-objdump -d hello
```

### newlib（裸机）

`elf` 包的编译器是 `loongarch64-unknown-elf-gcc`。目标没有操作系统，生成的程序
需要自己提供启动代码、链接脚本和目标板支持代码才能运行；工具链本身只保证编译和
链接阶段可用。

### musl

`musl` 包生成静态可执行文件最省事：

```bash
loongarch64-unknown-linux-musl-gcc -static hello.c -o hello-musl
```

动态链接的程序要求目标系统上存在 `/lib/ld-musl-loongarch64.so.1`。

## 系统要求

- 宿主：Linux `x86_64` 或 `aarch64`，glibc 2.28 及以上。MPFR / MPC / GMP 已经
  捆绑在归档的 `lib/` 目录中，无需自行安装。
- glibc 目标：目标运行时为 glibc 2.36，要求目标内核为 Linux 5.19 或更高
  （LoongArch 进入主线内核的起始版本）。要在更老的厂商内核（例如 4.19）上运行，
  需要自行调整 `--enable-kernel` 后重新构建。
- musl 目标：不依赖 glibc。
- newlib 目标：裸机，不依赖操作系统。

## 归档内容

```text
bin/                     编译器、binutils、QEMU 之外的宿主工具
lib/                     目标库、GCC 运行时，以及捆绑的 MPFR/MPC/GMP
libexec/gcc/             cc1、cc1plus、lto1 等编译器后端
sysroot/                 glibc / musl 目标 sysroot（含 libc 和启动文件）
LICENSE                  GPL-3.0
LICENSE.LGPL-2.1         部分组件使用的 LGPL-2.1
LICENSE.GPL-2.0          部分组件使用的 GPL-2.0
THIRD_PARTY_NOTICES.md   第三方组件版权与许可说明
VERSIONS.txt             各上游组件的实际 commit
SOURCE-OFFER.txt         各组件的源码获取地址与本仓库 revision
BUILD-INFO.txt           宿主架构、glibc 上限、目标和构建镜像信息
```

## 从源码构建

本仓库只包含顶层 `configure`、`Makefile.in`、测试脚本和 LoongArch UAPI 头文件，
gcc、binutils、glibc、newlib、musl、qemu、llvm 通过 submodule 按记录的 commit
拉取，不需要 `--recursive`。

```bash
git clone https://github.com/saimengna/loongarch-toolchain.git
cd loongarch-toolchain

./configure --prefix="$HOME/loongarch64" --enable-linux
make -j"$(nproc)" linux
```

其他目标：`make newlib`（`--enable-linux` 换成不传或 `--disable-linux`）、
`make musl`（`--enable-musl`）、`make build-qemu`。需要 LLVM 时在 configure
阶段加 `--enable-llvm`。子模块缺失时执行 `make fetch`。

## 许可证与源码

本仓库以 GPL-3.0 发布，详见 `LICENSE`。各上游组件保留自己的许可证，汇总在
`THIRD_PARTY_NOTICES.md` 中。每个归档的 `VERSIONS.txt` 和 `SOURCE-OFFER.txt`
记录了构建时使用的精确 revision 和源码地址。

本项目的工程结构参考了
[riscv-gnu-toolchain](https://github.com/riscv-collab/riscv-gnu-toolchain)。

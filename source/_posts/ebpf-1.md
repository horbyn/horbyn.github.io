---
title: 通过 libbpf-bootstrap 创建 CO-RE eBPF 项目
date: 2025-06-14 18:10:40
excerpt: 介绍了如何使用 libbpf-bootstrap 工具快速创建一个 CO-RE（Compile Once, Run Everywhere） eBPF 项目。通过分析 libbpf-bootstrap CMake 文件，分析其是如何自动生成所需的 eBPF 项目结构，包括必要的源代码文件、编译配置和依赖项。并列举一个例子，阐述如何利用该工具创建支持 CO-RE 的 eBPF 程序，以便在不同版本的内核上进行编译和运行
tags: eBPF
---

# 环境

参考 [libbpf-bootstrap 安装依赖](https://github.com/libbpf/libbpf-bootstrap?tab=readme-ov-file#install-dependencies) 和 [LLVM 版本问题](https://github.com/libbpf/libbpf-bootstrap/issues/340)，以 ubuntu 为例，由于官方测试过 llvm-11 至 llvm-20，因此至少需要 ubuntu:jammy 以上。依赖如下：

```shell
apt install clang libelf1 libelf-dev zlib1g-dev
```

下面是根据这些依赖创建的 C/C++ 环境容器镜像：

```dockerfile
FROM ubuntu:noble

# 禁止交互式时区设置参考：https://serverfault.com/a/1016972
ARG DEBIAN_FRONTEND=noninteractive
ENV TZ=Asia/Shanghai

# x86_64 或 aarch64
ARG ARCH

# 设置语言
ENV LC_ALL=en_US.UTF-8
ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US.UTF-8

RUN apt-get update && apt install -y --no-install-recommends ca-certificates && \
    cp /etc/apt/sources.list.d/ubuntu.sources /etc/apt/sources.list.d/ubuntu.sources.bak && \
    if [ "$ARCH" = "aarch64" ]; then \
        sed -i 's@//ports.ubuntu.com@//mirrors.ustc.edu.cn@g' /etc/apt/sources.list.d/ubuntu.sources; \
    elif [ "$ARCH" = "x86_64" ]; then \
        sed -i 's@//.*archive.ubuntu.com@//mirrors.ustc.edu.cn@g' /etc/apt/sources.list.d/ubuntu.sources; \
        sed -i 's/security.ubuntu.com/mirrors.ustc.edu.cn/g' /etc/apt/sources.list.d/ubuntu.sources; \
        sed -i 's/http:/https:/g' /etc/apt/sources.list.d/ubuntu.sources; \
    else \
        echo "未知架构，无法设置 apt 代理"; \
        exit 1; \
    fi && \
    apt-get update && apt install -y --no-install-recommends \
        build-essential make gdb sudo vim wget git cmake \
        pkg-config clang libelf1 libelf-dev zlib1g-dev \
        systemd init plocate language-pack-en tree zsh && \
    rm -rf /var/lib/apt/lists/* && \
    apt-get clean && \
    # 中文
    sed -i -e 's/# zh_CN.UTF-8 UTF-8/zh_CN.UTF-8 UTF-8/' /etc/locale.gen && \
    dpkg-reconfigure --frontend=noninteractive locales && \
    # 安装 zsh
    git clone https://github.com/ohmyzsh/ohmyzsh.git /root/.oh-my-zsh && \
    cp /root/.oh-my-zsh/templates/zshrc.zsh-template /root/.zshrc && \
    git clone https://github.com/zsh-users/zsh-syntax-highlighting.git ~/.oh-my-zsh/plugins/zsh-syntax-highlighting && \
    git clone https://github.com/zsh-users/zsh-autosuggestions ~/.oh-my-zsh/plugins/zsh-autosuggestions && \
    chsh -s $(which zsh) && \
    sed -i 's/^plugins=(git)$/plugins=(git wd zsh-syntax-highlighting zsh-autosuggestions)/' ~/.zshrc && \
    # 创建调试版 gdb
    printf '#!/bin/bash\n\nsudo /usr/bin/gdb $@' > /usr/bin/gdb_sudo && \
    chmod +x /usr/bin/gdb_sudo && \
    # mac 全局忽略 .DS_Store 配置文件
    # ref to: https://orianna-zzo.github.io/sci-tech/2018-01/mac%E4%B8%ADgit%E5%BF%BD%E7%95%A5.ds_store%E6%96%87%E4%BB%B6/
    echo "# Mac OS specified" > ~/.gitignore_global && \
    echo "**/.DS_Store" > ~/.gitignore_global && \
    git config --global core.excludesfile ~/.gitignore_global

CMD ["/sbin/init"]
```

入口设置为 `/sbin/init` 以及安装 `systemd` 和 `ini` 的原因是，这样创建的容器才能运行 `systemctl` 命令

创建镜像：

```shell
# x86 环境
docker buildx build --load --platform linux/amd64 --build-arg ARCH=x86_64 -t ebpf:latest D:\Dockerfile_dirs\ebpf

# arm 环境
docker buildx build --load --platform linux/arm64 --build-arg ARCH=aarch64 -t ebpf:latest /Users/horbyn/dockerfile.d/ebpf
```

创建容器：

```shell
# x86 环境
docker run -it -d --privileged --platform linux/amd64 --name ebpf -v D:\Repositories\my-project:/my-project -w /my-project ebpf:latest /sbin/init

# arm 环境
docker run -it -d --privileged --platform linux/amd64 --name ebpf -v /Users/horbyn/repositories/my-project:/my-project -w /my-project ebpf:latest /sbin/init
```

运行容器：

```shell
docker exec -it ebpf /bin/bash
```

如果你的 eBPF 项目会调用 `bpf_printk()` 那么就需要挂载内核 debug 文件系统：

```shell
# 挂载
mount -t debugfs none /sys/kernel/debug

# 查看
mount | grep debugfs
```

# bootstrap 是怎么编译 eBPF 程序的

可以通过 CMake 配置阶段展开的命令来分析：

```shell
# 克隆 libbpf-bootstrap 项目
git clone https://github.com/libbpf/libbpf-bootstrap
git submodule update --init --recursive
cmake -S examples/c -B build --trace-expand 2&> cmake.log
```

`--trace-expand` 参数会展开 CMake 执行的命令，并重定向输出到 cmake.log 文件中

## 引入外部项目

```cmake
ExternalProject_Add(libbpf
  PREFIX libbpf
  ...
)

ExternalProject_Add(bpftool
  PREFIX bpftool
  ...
)
```

用 `ExternalProject_add()` 引入外部项目，并在此阶段通过 `add_custom_command()` 导出了 `libbpf-build` 和 `bpftool-build` 两个 target

```shell
# cmake.log 节选
/usr/share/cmake-3.28/Modules/ExternalProject.cmake(2238):  add_custom_target(libbpf-build DEPENDS /my-project/libbpf-bootstrap/build/libbpf/src/libbpf-stamp/libbpf-build )
/usr/share/cmake-3.28/Modules/ExternalProject.cmake(2238):  add_custom_target(bpftool-build DEPENDS /my-project/libbpf-bootstrap/build/bpftool/src/bpftool-stamp/bpftool-build )
```

## 导出变量

```cmake
set(BPFOBJECT_BPFTOOL_EXE ${CMAKE_CURRENT_BINARY_DIR}/bpftool/bootstrap/bpftool)
set(BPFOBJECT_VMLINUX_H ${CMAKE_CURRENT_SOURCE_DIR}/../../vmlinux.h/include/${ARCH}/vmlinux.h)
set(LIBBPF_INCLUDE_DIRS ${CMAKE_CURRENT_BINARY_DIR}/libbpf)
set(LIBBPF_LIBRARIES ${CMAKE_CURRENT_BINARY_DIR}/libbpf/libbpf.a)
```

这些变量展开之后，如下：

```shell
# cmake.log 节选
/my-project/libbpf-bootstrap/examples/c/CMakeLists.txt(70):  set(BPFOBJECT_BPFTOOL_EXE /my-project/libbpf-bootstrap/build/bpftool/bootstrap/bpftool )
/my-project/libbpf-bootstrap/examples/c/CMakeLists.txt(71):  set(BPFOBJECT_VMLINUX_H /my-project/libbpf-bootstrap/examples/c/../../vmlinux.h/include/x86/vmlinux.h )
/my-project/libbpf-bootstrap/examples/c/CMakeLists.txt(72):  set(LIBBPF_INCLUDE_DIRS /my-project/libbpf-bootstrap/build/libbpf )
/my-project/libbpf-bootstrap/examples/c/CMakeLists.txt(73):  set(LIBBPF_LIBRARIES /my-project/libbpf-bootstrap/build/libbpf/libbpf.a )
```

这些变量会在 `bpf_object()` 宏定义中被使用，而这个宏是通过下面两个 cmake 命令被引入：

```cmake
list(APPEND CMAKE_MODULE_PATH ${CMAKE_CURRENT_SOURCE_DIR}/../../tools/cmake)
find_package(BpfObject REQUIRED)
```

这个宏定义会完成最终的编译 eBPF 用户态和内核态程序的工作

## 编译 eBPF 程序

```cmake
file(GLOB apps *.bpf.c)
foreach(app ${apps})
  get_filename_component(app_stem ${app} NAME_WE)

  bpf_object(${app_stem} ${app_stem}.bpf.c)

  add_dependencies(${app_stem}_skel libbpf-build bpftool-build)
  add_executable(${app_stem} ${app_stem}.c)
  target_link_libraries(${app_stem} ${app_stem}_skel)
endforeach()
```

先通过 `file()` 找到所有的 `bpf.c` 后缀的文件，然后调用 `bpf_object()` 宏：

```cmake
# FindBpfObject.cmake 节选
macro(bpf_object name input)
  set(BPF_C_FILE ${CMAKE_CURRENT_SOURCE_DIR}/${input})
  set(BPF_O_FILE ${CMAKE_CURRENT_BINARY_DIR}/${name}.bpf.o)
  set(BPF_SKEL_FILE ${CMAKE_CURRENT_BINARY_DIR}/${name}.skel.h)
  set(OUTPUT_TARGET ${name}_skel)

  add_custom_command(OUTPUT ${BPF_O_FILE}
    COMMAND ${BPFOBJECT_CLANG_EXE} -g -O2 -target bpf -D__TARGET_ARCH_${ARCH}
            ${CLANG_SYSTEM_INCLUDES} -I${GENERATED_VMLINUX_DIR}
            -isystem ${LIBBPF_INCLUDE_DIRS} -c ${BPF_C_FILE} -o ${BPF_O_FILE}
    DEPENDS ${BPF_C_FILE} ${BPF_H_FILES})

  add_custom_command(OUTPUT ${BPF_SKEL_FILE}
    COMMAND bash -c "${BPFOBJECT_BPFTOOL_EXE} gen skeleton ${BPF_O_FILE} > ${BPF_SKEL_FILE}"
    DEPENDS ${BPF_O_FILE})

  add_library(${OUTPUT_TARGET} INTERFACE)
  target_sources(${OUTPUT_TARGET} INTERFACE ${BPF_SKEL_FILE})
  target_include_directories(${OUTPUT_TARGET} INTERFACE ${CMAKE_CURRENT_BINARY_DIR})
  target_include_directories(${OUTPUT_TARGET} SYSTEM INTERFACE ${LIBBPF_INCLUDE_DIRS})
  target_link_libraries(${OUTPUT_TARGET} INTERFACE ${LIBBPF_LIBRARIES} -lelf -lz)
endmacro()
```

这个宏中先是定义了一些内部使用的 cmake 变量：

- `BPF_C_FILE`：`bpf.c` 文件，也即 eBPF 内核态文件，如 `bootstrap.bpf.c`
- `BPF_O_FILE`：内核态文件对应的二进制文件，如 `bootstrap.bpf.o`
- `BPF_SKEL_FILE`：bpftool 生成的可供 eBPF 用户态程序调用的接口（接口内封装了内核态功能），如 `bootstrap.skel.h`
- `OUTPUT_TARGET`：导出给外部使用的 target 的名字，如 `bootstrap_skel`

第一个 `add_custom_command` 是调用 `clang` 编译 `bpf.c` 文件，生成内核态文件 `bootstrap.bpf.o` 的过程，这个过程会引用外部定义的 `libbpf` 头文件的位置，即 `LIBBPF_INCLUDE_DIRS` 变量

第二个 `add_custom_command` 是调用 `bpftool` 生成 `bootstrap.skel.h` 的过程，这个过程会引用外部定义的 `bpftool` 工具的位置，即 `BPFOBJECT_BPFTOOL_EXE` 变量

最后就是 `add_library()` 导出一个 target，`target_sources()` 将源文件与 target 关联起来，使其他依赖于这个 target 的也会包含这个源文件，`target_include_directories()` 来指定 target 的头文件搜索路径，`target_link_libraries()` 指定 target 要链接的库

整理一下这个过程，也即是将内核态文件编译为 `bpf.o` 的二进制，进而通过 `bpftool` 生成 `skel.h`，这便是用户态可调用的 "内核态" 接口，最终将 `skel.h` 与导出的 `bootstrap_skel` 关联起来

最后的三行 cmake 调用则是常规的用户态程序的编译，这里要注意 `add_dependencies()` 的两个依赖 `libbpf-build` 和 `bpftool-build` 是在前面 `ExternalProject_Add()` 过程中生成的，如果你不想用 `ExternalProject_Add()`，就需要自己通过 `add_custom_command()` 导出这两个 target：

```cmake
add_dependencies(${app_stem}_skel libbpf-build bpftool-build)
add_executable(${app_stem} ${app_stem}.c)
target_link_libraries(${app_stem} ${app_stem}_skel)
```

换句话来说，通过 `bpf_object()` 宏最终将内核态程序导出到 `_skel` 后缀的 target 中，最后只需要在编译内核态程序后将这个 target 链接进去就完成了一个 CO-RE eBPF 程序的编译（CO-RE 简单来说就是开发环境编译出来的 eBPF 程序，在迁移到执行环境中运行时，不需要理会 eBPF 程序执行时的依赖，如内核版本、内核头文件等等，更多内容可以参考 [[译] BPF 可移植性和 CO-RE（一次编译，到处运行）](https://arthurchiao.art/blog/bpf-portability-and-co-re-zh/)）

# 创建一个 CO-RE 的 eBPF 项目

现在从零开始，假设刚执行完 `git init`，那么创建一个 CO-RE 项目，第一步便是引入 `libbpf-bootstrap`，这里就不讨论 `FetchContent_Declare()` 和 `git submodule` 引入第三方库的优劣，直接用后者：

```shell
git submodule add https://github.com/libbpf/libbpf-bootstrap.git libs/libbpf-bootstrap
git submodule update --init --recursive
```

这里使用一个很简单的 eBPF 内核态程序：

```c
// hello.bpf.c
#include "vmlinux.h"
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_tracing.h>

SEC("tracepoint/syscalls/sys_enter_execve")
int handle_execve(struct trace_event_raw_sys_enter *ctx)
{
  char msg[] = "Hello from eBPF! Process executed: ";
  bpf_printk("%s", msg);
  return 0;
}

char _license[] SEC("license") = "GPL";

```

只要调用了 `execve` 系统调用，就会触发 `handle_execve` 函数，打印出一条消息。换句话说，`ls`、`cat` 等命令都会切换执行流，所以会触发这个 eBPF 程序

对应的用户态程序如下：

```c
// hello.c
#include "hello.skel.h" // 由 libbpf-bootstrap 自动生成
#include <stdio.h>
#include <unistd.h>

int main()
{
  struct hello_bpf *skel = hello_bpf__open();
  if (!skel)
  {
    perror("Failed to open BPF skeleton");
    return 1;
  }

  if (hello_bpf__load(skel))
  { // 加载并验证 BPF 程序
    fprintf(stderr, "Failed to load BPF skeleton\n");
    hello_bpf__destroy(skel);
    return 1;
  }

  if (hello_bpf__attach(skel))
  { // 附加到挂载点
    fprintf(stderr, "Failed to attach BPF program\n");
    hello_bpf__destroy(skel);
    return 1;
  }

  printf("eBPF program running! Run `sudo cat /sys/kernel/debug/tracing/trace_pipe` to view logs.\n");
  while (1)
    sleep(1); // 保持程序运行

  hello_bpf__destroy(skel);
  return 0;
}
```

现在目录结构如下：

```shell
➜  /my-project git:(main) ✗ tree -a -L 1 .
.
├── .git
├── .gitmodules
├── hello.bpf.c
├── hello.c
└── libs

3 directories, 3 files
```

使用的 CMakeLists.txt 如下：

```cmake
cmake_minimum_required(VERSION 3.10)
project("hello")

list(APPEND CMAKE_MODULE_PATH ${CMAKE_CURRENT_SOURCE_DIR}/libs/libbpf-bootstrap/tools/cmake)
set(LIBBPF_BOOTSTRAP_PATH ${CMAKE_SOURCE_DIR}/libs/libbpf-bootstrap)

include(ExternalProject)
ExternalProject_Add(libbpf
  PREFIX libbpf
  SOURCE_DIR ${LIBBPF_BOOTSTRAP_PATH}/libbpf/src
  CONFIGURE_COMMAND ""
  BUILD_COMMAND make
    BUILD_STATIC_ONLY=1
    OBJDIR=${CMAKE_BINARY_DIR}/libbpf/libbpf
    DESTDIR=${CMAKE_BINARY_DIR}/libbpf
    INCLUDEDIR=
    LIBDIR=
    UAPIDIR=
    install install_uapi_headers
  BUILD_IN_SOURCE TRUE
  INSTALL_COMMAND ""
  STEP_TARGETS build
)

ExternalProject_Add(bpftool
  PREFIX bpftool
  SOURCE_DIR ${LIBBPF_BOOTSTRAP_PATH}/bpftool/src
  CONFIGURE_COMMAND ""
  BUILD_COMMAND make bootstrap
    OUTPUT=${CMAKE_BINARY_DIR}/bpftool/
  BUILD_IN_SOURCE TRUE
  INSTALL_COMMAND ""
  STEP_TARGETS build
)

if(${CMAKE_SYSTEM_PROCESSOR} MATCHES "x86_64")
  set(ARCH "x86")
elseif(${CMAKE_SYSTEM_PROCESSOR} MATCHES "arm")
  set(ARCH "arm")
elseif(${CMAKE_SYSTEM_PROCESSOR} MATCHES "aarch64")
  set(ARCH "arm64")
elseif(${CMAKE_SYSTEM_PROCESSOR} MATCHES "ppc64le")
  set(ARCH "powerpc")
elseif(${CMAKE_SYSTEM_PROCESSOR} MATCHES "mips")
  set(ARCH "mips")
elseif(${CMAKE_SYSTEM_PROCESSOR} MATCHES "riscv64")
  set(ARCH "riscv")
elseif(${CMAKE_SYSTEM_PROCESSOR} MATCHES "loongarch64")
  set(ARCH "loongarch")
endif()

set(BPFOBJECT_BPFTOOL_EXE ${CMAKE_BINARY_DIR}/bpftool/bootstrap/bpftool)
set(BPFOBJECT_VMLINUX_H ${LIBBPF_BOOTSTRAP_PATH}/vmlinux.h/include/${ARCH}/vmlinux.h)
set(LIBBPF_INCLUDE_DIRS ${CMAKE_BINARY_DIR}/libbpf)
set(LIBBPF_LIBRARIES ${CMAKE_BINARY_DIR}/libbpf/libbpf.a)

find_package(BpfObject REQUIRED)
file(GLOB apps *.bpf.c)
foreach(app ${apps})
  get_filename_component(app_stem ${app} NAME_WE)

  bpf_object(${app_stem} ${app_stem}.bpf.c)
  add_dependencies(${app_stem}_skel libbpf-build bpftool-build)

  add_executable(${app_stem} ${app_stem}.c)
  target_link_libraries(${app_stem} ${app_stem}_skel)
endforeach()
```

现在可以编译整个 eBPF 项目了：

```shell
➜  /my-project git:(main) ✗ cmake -S . -B build --trace-expand 2&> cmake.log
Put cmake in trace mode, but with variables expanded.
-- The C compiler identification is GNU 13.3.0
-- The CXX compiler identification is GNU 13.3.0
-- Detecting C compiler ABI info
-- Detecting C compiler ABI info - done
-- Check for working C compiler: /usr/bin/cc - skipped
-- Detecting C compile features
-- Detecting C compile features - done
-- Detecting CXX compiler ABI info
-- Detecting CXX compiler ABI info - done
-- Check for working CXX compiler: /usr/bin/c++ - skipped
-- Detecting CXX compile features
-- Detecting CXX compile features - done
-- Found clang version: 18.1.3 (1ubuntu1)
-- Found BpfObject: /my-project/build/bpftool/bootstrap/bpftool  
-- BPF system include flags: -idirafter;/usr/lib/llvm-18/lib/clang/18/include;-idirafter;/usr/local/include;-idirafter;/usr/include/x86_64-linux-gnu;-idirafter;/usr/include
-- BPF target arch: x86
-- Configuring done (1.5s)
-- Generating done (0.2s)
-- Build files have been written to: /my-project/build

➜  /my-project git:(main) ✗ cmake --build build                             
[  3%] Creating directories for 'libbpf'
[  6%] No download step for 'libbpf'
[  9%] No update step for 'libbpf'
[ 12%] No patch step for 'libbpf'
[ 15%] No configure step for 'libbpf'
[ 18%] Performing build step for 'libbpf'
  MKDIR    /my-project/build/libbpf/libbpf/staticobjs
  CC       /my-project/build/libbpf/libbpf/staticobjs/bpf.o
  CC       /my-project/build/libbpf/libbpf/staticobjs/btf.o
  CC       /my-project/build/libbpf/libbpf/staticobjs/libbpf.o
  CC       /my-project/build/libbpf/libbpf/staticobjs/libbpf_errno.o
  CC       /my-project/build/libbpf/libbpf/staticobjs/netlink.o
  CC       /my-project/build/libbpf/libbpf/staticobjs/nlattr.o
  CC       /my-project/build/libbpf/libbpf/staticobjs/str_error.o
  CC       /my-project/build/libbpf/libbpf/staticobjs/libbpf_probes.o
  CC       /my-project/build/libbpf/libbpf/staticobjs/bpf_prog_linfo.o
  CC       /my-project/build/libbpf/libbpf/staticobjs/btf_dump.o
  CC       /my-project/build/libbpf/libbpf/staticobjs/hashmap.o
  CC       /my-project/build/libbpf/libbpf/staticobjs/ringbuf.o
  CC       /my-project/build/libbpf/libbpf/staticobjs/strset.o
  CC       /my-project/build/libbpf/libbpf/staticobjs/linker.o
  CC       /my-project/build/libbpf/libbpf/staticobjs/gen_loader.o
  CC       /my-project/build/libbpf/libbpf/staticobjs/relo_core.o
  CC       /my-project/build/libbpf/libbpf/staticobjs/usdt.o
  CC       /my-project/build/libbpf/libbpf/staticobjs/zip.o
  CC       /my-project/build/libbpf/libbpf/staticobjs/elf.o
  CC       /my-project/build/libbpf/libbpf/staticobjs/features.o
  CC       /my-project/build/libbpf/libbpf/staticobjs/btf_iter.o
  CC       /my-project/build/libbpf/libbpf/staticobjs/btf_relocate.o
  AR       /my-project/build/libbpf/libbpf/libbpf.a
  INSTALL  bpf.h libbpf.h btf.h libbpf_common.h libbpf_legacy.h bpf_helpers.h bpf_helper_defs.h bpf_tracing.h bpf_endian.h bpf_core_read.h skel_internal.h libbpf_version.h usdt.bpf.h
  INSTALL  /my-project/build/libbpf/libbpf/libbpf.pc
  INSTALL  /my-project/build/libbpf/libbpf/libbpf.a 
  INSTALL  ../include/uapi/linux/bpf.h ../include/uapi/linux/bpf_common.h ../include/uapi/linux/btf.h
[ 21%] No install step for 'libbpf'
[ 25%] Completed 'libbpf'
[ 25%] Built target libbpf
[ 28%] Creating directories for 'bpftool'
[ 31%] No download step for 'bpftool'
[ 34%] No update step for 'bpftool'
[ 37%] No patch step for 'bpftool'
[ 40%] No configure step for 'bpftool'
[ 43%] Performing build step for 'bpftool'
...                        libbfd: [ OFF ]
...               clang-bpf-co-re: [ on  ]
...                          llvm: [ OFF ]
...                        libcap: [ OFF ]
  MKDIR    /my-project/build/bpftool/bootstrap/libbpf/staticobjs
  CC       /my-project/build/bpftool/bootstrap/libbpf/staticobjs/bpf.o
  CC       /my-project/build/bpftool/bootstrap/libbpf/staticobjs/btf.o
  CC       /my-project/build/bpftool/bootstrap/libbpf/staticobjs/libbpf.o
  CC       /my-project/build/bpftool/bootstrap/libbpf/staticobjs/libbpf_errno.o
  CC       /my-project/build/bpftool/bootstrap/libbpf/staticobjs/netlink.o
  CC       /my-project/build/bpftool/bootstrap/libbpf/staticobjs/nlattr.o
  CC       /my-project/build/bpftool/bootstrap/libbpf/staticobjs/str_error.o
  CC       /my-project/build/bpftool/bootstrap/libbpf/staticobjs/libbpf_probes.o
  CC       /my-project/build/bpftool/bootstrap/libbpf/staticobjs/bpf_prog_linfo.o
  CC       /my-project/build/bpftool/bootstrap/libbpf/staticobjs/btf_dump.o
  CC       /my-project/build/bpftool/bootstrap/libbpf/staticobjs/hashmap.o
  CC       /my-project/build/bpftool/bootstrap/libbpf/staticobjs/ringbuf.o
  CC       /my-project/build/bpftool/bootstrap/libbpf/staticobjs/strset.o
  CC       /my-project/build/bpftool/bootstrap/libbpf/staticobjs/linker.o
  CC       /my-project/build/bpftool/bootstrap/libbpf/staticobjs/gen_loader.o
  CC       /my-project/build/bpftool/bootstrap/libbpf/staticobjs/relo_core.o
  CC       /my-project/build/bpftool/bootstrap/libbpf/staticobjs/usdt.o
  CC       /my-project/build/bpftool/bootstrap/libbpf/staticobjs/zip.o
  CC       /my-project/build/bpftool/bootstrap/libbpf/staticobjs/elf.o
  AR       /my-project/build/bpftool/bootstrap/libbpf/libbpf.a
  INSTALL  bpf.h libbpf.h btf.h libbpf_common.h libbpf_legacy.h bpf_helpers.h bpf_helper_defs.h bpf_tracing.h bpf_endian.h bpf_core_read.h skel_internal.h libbpf_version.h usdt.bpf.h
[ 46%] No install step for 'bpftool'
[ 50%] Completed 'bpftool'
[ 50%] Built target bpftool
[ 68%] Built target bpftool-build
[ 87%] Built target libbpf-build
[ 90%] [clang] Building BPF object: hello
[ 93%] [skel]  Building BPF skeleton: hello
[ 96%] Building C object CMakeFiles/hello.dir/hello.c.o
[100%] Linking C executable hello
[100%] Built target hello
```

需要注意的是在执行 `ExternalProject_Add()` 过程中支持 `cmake -j 8` 这种并行编译，详见 [External project does not use parallel jobs](https://discourse.cmake.org/t/external-project-does-not-use-parallel-jobs/3359)

然后挂载 debug 文件系统，就可以运行这个 eBPF 程序了：

```shell
mount -t debugfs none /sys/kernel/debug
➜  /my-project git:(main) ✗ build/hello
eBPF program running! Run `sudo cat /sys/kernel/debug/tracing/trace_pipe` to view logs.

```

在另一个终端中运行 `sudo cat /sys/kernel/debug/tracing/trace_pipe` 就可以看到 eBPF 程序的输出了：

```shell
➜  /my-project git:(main) ✗ sudo cat /sys/kernel/debug/tracing/trace_pipe
              ls-341634  [010] ...21 22722.835020: bpf_trace_printk: Hello from eBPF! Process executed: 
              ls-341636  [004] ...21 22722.835088: bpf_trace_printk: Hello from eBPF! Process executed: 
            expr-341637  [002] ...21 22722.836163: bpf_trace_printk: Hello from eBPF! Process executed: 
            expr-341638  [009] ...21 22722.836296: bpf_trace_printk: Hello from eBPF! Process executed: 
           sleep-341639  [010] ...21 22722.836981: bpf_trace_printk: Hello from eBPF! Process executed: 
           sleep-341640  [004] ...21 22722.837055: bpf_trace_printk: Hello from eBPF! Process executed: 
       systemctl-341641  [002] ...21 22722.843927: bpf_trace_printk: Hello from eBPF! Process executed: 
       systemctl-341641  [002] ...21 22722.843962: bpf_trace_printk: Hello from eBPF! Process executed: 
       systemctl-341642  [010] ...21 22723.097366: bpf_trace_printk: Hello from eBPF! Process executed: 
       systemctl-341642  [010] ...21 22723.097378: bpf_trace_printk: Hello from eBPF! Process executed: 
             sed-341643  [008] ...21 22723.109197: bpf_trace_printk: Hello from eBPF! Process executed: 
             cat-341644  [003] ...21 22723.110647: bpf_trace_printk: Hello from eBPF! Process executed: 
              sh-341646  [004] ...21 22723.193747: bpf_trace_printk: Hello from eBPF! Process executed: 
           which-341647  [010] ...21 22723.194626: bpf_trace_printk: Hello from eBPF! Process executed: 
              sh-341648  [003] ...21 22723.197012: bpf_trace_printk: Hello from eBPF! Process executed: 
              ps-341649  [010] ...21 22723.197964: bpf_trace_printk: Hello from eBPF! Process executed: 
              sh-341650  [005] ...21 22723.202623: bpf_trace_printk: Hello from eBPF! Process executed: 
     cpuUsage.sh-341651  [007] ...21 22723.203390: bpf_trace_printk: Hello from eBPF! Process executed: 
             sed-341652  [008] ...21 22723.204677: bpf_trace_printk: Hello from eBPF! Process executed: 
             cat-341653  [010] ...21 22723.206450: bpf_trace_printk: Hello from eBPF! Process executed: 
           sleep-341654  [002] ...21 22723.207342: bpf_trace_printk: Hello from eBPF! Process executed: 
          bridge-341655  [011] ...21 22723.288592: bpf_trace_printk: Hello from eBPF! Process executed: 
         portmap-341661  [008] ...21 22723.290862: bpf_trace_printk: Hello from eBPF! Process executed:
```

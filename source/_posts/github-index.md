---
title: 美化 Github 主页
date: 2025-03-02 21:08:35
excerpt: 记录一些前端项目的使用
tags: Blogs
---

## 创建 Github 主页

参考 [如何打造一个优雅的个人GitHub主页？](https://zhuanlan.zhihu.com/p/593714446)，本文分两步：

- 创建「个人信息」
- 创建「WataTime 耗时统计」

注：[WataTime](https://wakatime.com/) 用来统计你写代码用了多长时间，可以使用官方提供的 API 接口输出到 Github 主页上

效果可以参考 [我的主页](https://github.com/horbyn)

## 部署环境

下面这份 Dockerfile 实际上是 `Ubuntu 24.04` 的 `C/C++` 开发环境（base 镜像），这里仅供参考

```Dockerfile
FROM ubuntu:noble

# 禁止交互式时区设置参考：https://serverfault.com/a/1016972
ARG DEBIAN_FRONTEND=noninteractive
ENV TZ=Asia/Shanghai

# 设置语言
ENV LC_ALL=zh_CN.UTF-8
ENV LANG=zh_CN.UTF-8
ENV LANGUAGE=zh_CN.UTF-8

# 定义架构参数: aarch64 和 x86_64
# 构建时通过 `--build-arg` 传入：docker build --build-arg ARCH=aarch64 ...）
ARG ARCH

RUN apt-get update && \
    apt-get install -yqq --no-install-recommends ca-certificates sudo && \
    cp /etc/apt/sources.list /etc/apt/sources.list.bak && \
    if [ "$ARCH" = "aarch64" ]; then \
        sed -i -e 's@//ports.ubuntu.com/\? @//ports.ubuntu.com/ubuntu-ports @g' \
                -e 's@//ports.ubuntu.com@//mirrors.ustc.edu.cn@g' \
                /etc/apt/sources.list; \
    elif [ "$ARCH" = "x86_64" ]; then \
        sed -i 's@//.*archive.ubuntu.com@//mirrors.ustc.edu.cn@g' /etc/apt/sources.list; \
        sed -i 's/security.ubuntu.com/mirrors.ustc.edu.cn/g' /etc/apt/sources.list; \
        sed -i 's/http:/https:/g' /etc/apt/sources.list; \
    else \
        echo "未知架构，无法设置 apt 代理"; \
        exit 1; \
    fi && \
    apt-get update && apt-get install -yqq --no-install-recommends \
    ca-certificates sudo vim wget autoconf pkg-config libtool bison flex build-essential \
    check tzdata lsb-release file tree lcov git language-pack-en zip unzip make libpcap-dev \
    iputils-ping iproute2 net-tools lsof tcpdump iptables openssh-client openssh-server \
    libelf-dev uuid-dev automake libssl-dev kmod jq bash-completion libpcre3-dev m4 plocate \
    traceroute curl libcurl4-openssl-dev libfl-dev software-properties-common locales \
    locales-all gdb gdbserver valgrind zsh && \
    rm -rf /var/lib/apt/lists/* && \
    apt-get clean && \
    ldconfig && \
    # 中文
    sed -i -e 's/# zh_CN.UTF-8 UTF-8/zh_CN.UTF-8 UTF-8/' /etc/locale.gen && \
    dpkg-reconfigure --frontend=noninteractive locales && \
    # 安装 cmake
    cd /home && \
    export CMAKE_V=3.31.6 && \
    wget "https://github.com/Kitware/CMake/releases/download/v$CMAKE_V/cmake-$CMAKE_V-linux-$ARCH.tar.gz" && \
    tar -xzf "cmake-$CMAKE_V-linux-$ARCH.tar.gz" && \
    cd "cmake-$CMAKE_V-linux-$ARCH" && \
    ln -s `pwd`/bin/cmake /usr/bin/ && \
    ln -s `pwd`/bin/ctest /usr/bin/ && \
    cd .. && \
    rm -rf "cmake-$CMAKE_V-linux-$ARCH.tar.gz" && \
    # 安装 zsh
    git clone https://github.com/ohmyzsh/ohmyzsh.git /root/.oh-my-zsh && \
    cp /root/.oh-my-zsh/templates/zshrc.zsh-template /root/.zshrc && \
    git clone https://github.com/zsh-users/zsh-syntax-highlighting.git ~/.oh-my-zsh/plugins/zsh-syntax-highlighting && \
    git clone https://github.com/zsh-users/zsh-autosuggestions ~/.oh-my-zsh/plugins/zsh-autosuggestions && \
    chsh -s $(which zsh) && \
    sed -i 's/^plugins=(git)$/plugins=(git wd zsh-syntax-highlighting zsh-autosuggestions)/' ~/.zshrc && \
    # 创建调试版 gdb
    echo -e '#!/bin/bash\n\nsudo /usr/bin/gdb $@' > /usr/bin/gdb_sudo && \
    chmod +x /usr/bin/gdb_sudo && \
    # mac 全局忽略 .DS_Store 配置文件
    # ref to: https://orianna-zzo.github.io/sci-tech/2018-01/mac%E4%B8%ADgit%E5%BF%BD%E7%95%A5.ds_store%E6%96%87%E4%BB%B6/
    echo "# Mac OS specified" > ~/.gitignore_global && \
    echo "**/.DS_Store" > ~/.gitignore_global && \
    git config --global core.excludesfile ~/.gitignore_global

CMD ["/usr/bin/zsh"]

```

执行

```shell
docker buildx build --load --build-arg ARCH=x86_64 -t me:latest .
```

创建镜像，然后执行

```shell
docker run -it -v D:\Repositories\username:/me -w /me --name me me:latest /usr/bin/zsh
```

创建容器

## 个人信息

参考 [可视化的Github状态卡片生成器](https://github.com/AZCodingAccount/github-readme-stats-plus) 项目，生成 Github 状态卡片

作者介绍在 [让你的Github主页更有极客范儿](https://www.bilibili.com/video/BV1DM4m1f7H2/?vd_source=bfa0dadd9476ea4dc18addc67dbc9b83)

除了 `WataTime` 没有使用这个项目生成的链接，因为它会暴露 API Key，所以 `WataTime` 部分用后一节的方法处理

## WataTime 耗时统计

参考 [GitHub主页面美化，第三章 Wakatime](https://juejin.cn/post/7256314289072980023#heading-16) 的步骤

使用了 [waka-readme-stats](https://github.com/anmol098/waka-readme-stats) 项目来自动化生成 WakaTime 数据

---
title: 安装 Ubuntu
date: 2025-07-15 23:17:53
excerpt: 记录了官网安装 ubuntu desktop 的过程，从制作启动盘开始，到引导系统安装完成后常用的操作
tags: env
---

## 下载 Ubuntu ISO

进入 [Ubuntu 官网](https://ubuntu.com/)

现在是 2025-07，最新的 LTS 是 24.04，Desktop 是带图形化界面的，Server 是纯命令行的，这里安装的是 Desktop

![](https://pic1.imgdb.cn/item/687b570358cb8da5c8c6c4d0.png)

下载完成后点击 [安装教程](https://ubuntu.com/tutorials/install-ubuntu-desktop#1-overview)

![](https://pic1.imgdb.cn/item/687b576d58cb8da5c8c6c564.png)

## 制作 Ubuntu 启动盘

用 [balenaEtcher](https://etcher.balena.io/) 创建 U 盘启动盘

这里也有一个问题，有时候启动盘制作多了，U 盘会出问题，比如容量变小，参考 [U盘内存发现变小了，怎么办？？？？](https://www.bilibili.com/video/BV1f5411x7mo/?vd_source=bfa0dadd9476ea4dc18addc67dbc9b83)：

- 右键 "我的电脑"，选择 "管理"，选择 "磁盘管理"。这里就可以看到 U 盘的容量了，如果 U 盘容量变小，大概率这里显示的磁盘容量是分段的
- 快捷键 "Win + R"，输入 `diskpart`
    - `list disk`，查看所有磁盘
    - `select disk 1`，选择 U 盘（不一定是 disk 1，要看 `list disk` 的输出）
    - `clean`，清除磁盘分区
- 回到 "管理" -> "磁盘管理"，右键 U 盘，选择新建卷（new volume），根据实际情况选择向导提示的内容（制作 Ubuntu 启动盘，U 盘格式不要选 NTFS，选 *FAT）

现在打开 balenaEtcher，三个选项从左到右各设置一次就行

![](https://pic1.imgdb.cn/item/687b5c0b58cb8da5c8c6d619.png)

第二个选项选择刚才插入的 U 盘

![](https://pic1.imgdb.cn/item/687b5c0b58cb8da5c8c6d617.png)

最后等待完成即可

![](https://pic1.imgdb.cn/item/687b5c6258cb8da5c8c6d865.png)

## 安装 Ubuntu

网上很多教程了，这里就不再重复，只是安装完成后，我通常会：

- [更新国内源](https://mirrors.ustc.edu.cn/help/ubuntu.html)
- 修改 root 用户密码 `sudo passwd root`
- 安装 `openssh-serveer` 再修改 `/etc/ssh/sshd_config`，将 `PermitRootLogin` 改为 `yes`，然后重启 ssh 服务 `systemctl restart ssh`（**24.04 是重启 `ssh` 而不是 `sshd`**）
- 笔记本电脑合上盖子后保持工作，参考 [Ubuntu桌面笔记本电脑合盖挂起解决教程](https://www.bilibili.com/video/BV1rV411N7eX/?vd_source=bfa0dadd9476ea4dc18addc67dbc9b83)，将 `/etc/systemd/logind.conf` 中所有 `HandleLid*` 前缀的注释放开，并修改为 ignore，然后重启 `systemctl restart systemd-logind`
- 修正时区 `timedatectl set-timezone Asia/Shanghai`

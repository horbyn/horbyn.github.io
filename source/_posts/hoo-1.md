---
title: 「从零到一」实现一个 x86 的内核
date: 2025-01-02 13:22:48
excerpt: 经历过从入门到放弃，从放弃到入门，终于完成了这个项目
categories: KERNEL
tag: hoo
sticky: 100
---

## 内核与操作系统

在开始之前，我需要先定义下内核要做什么东西。比如说，内核和操作系统是同一个概念吗？我的观点，内核是最基础的功能，操作系统囊括了内核。那内核负责什么功能？什么功能可以称得上最基础？答案是管理任务，也即内核等同于任务管理器

广义上，我们需要一个操作系统，除了是想借助计算机去做一些计算以外，另一个关键的需求是任务管理，我们希望可以一边在浏览器上网上冲浪，另一边还挂着网易云来听音乐。按这个思路出发，当我们实现了一个软件，这个软件可以记录当前系统有多少个任务、可以完成任务的调度，那么就可以称得上是内核了

在此之后，加入协议栈、交互接口、设备驱动等等，就可以称得上是操作系统了

## 内核需要实现的模块

从机器通电启动，到内核最终运行起来，中间存在很重要的一个阶段：

- [引导和加载](https://horbyn.github.io/2025/01/07/hoo-2/)

最后内核运行起来，其最终目标是管理任务。围绕这一点，需要设计一种机制来将某个确切任务记录下来，记录的地方必定是内存，因此，需要实现内存管理模块。其次，还要考虑任务的调度，即怎样中断与怎样继续执行，这便是中断模块和调度模块。在这个过程中，像中断模块是软件硬件结合的，还会涉及设备驱动的实现。完成这些事情之后，后续要考虑的就是将任务保存下来，并提供一些接口来访问任务，即实现文件系统与内置命令，至此内核的模块便划分为如下六个模块：

- [内存管理](https://horbyn.github.io/2025/01/30/hoo-3/)
- [中断机制](https://horbyn.github.io/2025/02/01/hoo-4/)
- [调度机制](https://horbyn.github.io/2025/02/04/hoo-5/)
- [设备驱动](https://horbyn.github.io/2025/02/05/hoo-6/)
- [文件系统](https://horbyn.github.io/2025/02/07/hoo-7/)
- [内置命令](https://horbyn.github.io/2025/02/10/hoo-8/)

因此，这个系列将会分为 7 篇文章

## hoo

当知道了内核要做些什么东西后，这个 [项目](https://github.com/horbyn/hoo) 就诞生了，我给它取了一个名字：hoo。但是也要指出，这个项目的初衷只是学习，内核里的每一个东西想要深究，都可以挖得很深。比如磁盘驱动，一开始只需要实现磁盘读写就够了，但往后可以去考虑对磁盘信息（ATA IDENTIFY DATA）的读取、对磁盘设备类型的兼容（ATA 标准）等等；又比如任务的调度一开始只需要实现 FIFO 就够了，但往后可以考虑任务优先级的抢占式调度等等。这是一个 0-1 和 1-100 的过程，这个系列命名为从零到一，用意也是在这里

![](https://pic1.imgdb.cn/item/67c11732d0e0a243d4078e8f.gif)

## 参考资料

- [书籍：《汇编语言》，王爽](https://book.douban.com/subject/25726019//)
- [书籍：《汇编语言：从实模式都保护模式》，李忠 / 王晓波 / 余洁](https://book.douban.com/subject/20492528//)
- [书籍：《操作系统真象还原》，郑钢](https://book.douban.com/subject/26745156/)
- [书籍：《一个64位操作系统的设计与实现》，田宇](https://book.douban.com/subject/30222325/)
- [书籍：《Linux 0.11》，赵炯](https://mirror.math.princeton.edu/pub/oldlinux/download/clk011.pdf)
- [论坛：OSDev](https://wiki.osdev.org/Expanded_Main_Page)
- [开源项目：Skelix](http://skelix.net/skelixos/index_zh.html)
- [开源项目：hurlex](https://www.zhihu.com/question/22463820/answer/22394667)
- [开源项目：xv6, Fall 2018](https://pdos.csail.mit.edu/6.828/2018/schedule.html)
- [手册：Intel® 64 and IA-32 Architectures Software Developer's Manual, V3](https://www.intel.com/content/dam/www/public/us/en/documents/manuals/64-ia-32-architectures-software-developer-vol-3a-part-1-manual.pdf)

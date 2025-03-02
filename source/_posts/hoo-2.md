---
title: 「从零到一」内核引导与加载
date: 2025-01-07 13:13:41
excerpt: 整个 x86 内核故事的序幕，引导与加载被称为 bootloader，用于初始化内核执行环境、加载内核到内存并将控制权交给内核
categories: KERNEL
tag: hoo
---

# 引导这个阶段会发生什么

x86 的故事开始于 `0x7c00`，即 `%cs` 和 `%ip` 两个寄存器的组合指向了这个地址，从这里执行第一条指令。因此，OS 开发者就要想办法在内存 `0x7c00` 处安排上自己的软件。最简单的做法是将自己软件的纯二进制文件写入到磁盘的 0 面 0 道 1 扇区，这个扇区被称为 MBR，BIOS 会负责将这个位置的扇区读入内存 `0x7c00`，这就是引导阶段发生的事情

# 引导阶段

传统上，不会直接把内核放在 MBR，也即内核不会一开始就送上 `0x7c00`。因为：

- MBR 的空间太小，一般只有 `512` 字节，不足够实现太多复杂功能
- 即使 MBR 空间足够，但 x86 内核由于兼容性需要切换保护模式，切换需要一些额外工作（可以称为初始化工作），这些工作需要在真正进入内核之前完成

因此，在内核真正运行在内存之前，会先运行另一个程序 —— `bootloader`。实际上这里有两个步骤，第一步引导（`boot`），第二步加载（`loader`），前者负责加载 MBR；后者负责把内核从磁盘加载到内存中，以及设置内核运行的环境

大致上，引导和加载需要完成以下事情：

- 借助 `BIOS` 获取内存信息
- 借助 `BIOS` 从磁盘中将内核读取到内存
- 设置 `gdt`
- 开启分页机制
- 跳入保护模式

在进入保护模式之前（实模式阶段），只能使用可怜的 `1MB` 寻址空间，这个阶段由于需要读取到硬件信息（从 `BIOS` 中获取信息），以供后续进入内核使用。所以这个阶段需要规划一个内存布局，规定硬件信息应该写入哪个内存地址

在规划之前先来看看实模式的 `1MB` 布局：

```cpp
/*
 * 0      0x500            0x80000   0xa0000        0xc0000          0x100000
 * ├──────┼────────────────┼─────────┼──────────────┼────────────────┤
 * │IVT   │                │EBIOS    │VIDEO MEMORY  │ROM & MAPPING   │
 * ├──────┼────────────────┼─────────┼──────────────┼────────────────┤
 */
```

其中 IVT 是 BIOS 安装的，一是保护模式内核不需要使用 BIOS，二是中断例程内核自己会实现，所以这块空间在引导阶段结束就可以覆盖。再往后从 `0x8_0000` 开始都是硬件保留的，这里也不动它，所以内核可以覆盖的就是前面 `0x8_0000` 的空间

`hoo` 的规划如下：

![](https://pic1.imgdb.cn/item/67763757d0e0a243d4edc38f.png)

整体来看，内核占用 `[0, 0x7_8000)` 内存空间，内核栈占用 `[0x7_a000, 0x8_0000)`。其中，内核的 `0x7_7fc` 地址处放置了一条 `DIED` 指令（其实就是 `jmp .`），在引导阶段跳入内核之前设置，当内核返回的时候，这条指令会从栈中弹出，防止内核返回时去到未知的地方。其次，`hoo` 在引导阶段产生或获取到的所有数据都放在内核栈增长的方向，后面结束引导阶段就可以随便覆盖掉了

# 具体实现

完整代码详见 [boot/bootsect.S](https://github.com/horbyn/hoo/blob/master/boot/bootsect.S)

![](https://pic1.imgdb.cn/item/67740b61d0e0a243d4ed3e79.png)

这里参考 `Linux 0.11` 的思路，内核未来放在内存 `0` 地址往上，所以位于 `0x7c00` 的 MBR 自然需要先挪位置到高地址。挪到高地址后，调用 BIOS 读磁盘功能，将内核读到 `0x1000`，这是因为此时不能覆盖 BIOS 的 IVT。当完全使用完 BIOS 功能后，再将内核移动到 `0` 地址处，最后跳入内核

需要注意的是，在进入保护模式之前，x86 机器字长都是 `16-bit` 的，意味着保护模式之前使用的栈、或者执行一些既可以用 `%eax`，又可以用 `%ax` 的指令（如乘法指令），长度是 `16-bit`。但是使用寄存器没有这个限制，实模式下是可以使用 `32-bit` 寄存器的（比如 `mov` 一个数据到 `%eax`）

## MBR 移动到高地址

```assembly
    .set SEG_MBR,       0x7240
    cld                     # 地址递增
    xorw %ax,           %ax
    movw %ax,           %ds
    movw $0x7c00,       %si
    movw $SEG_MBR,      %ax
    movw %ax,           %es
    movw $0x7c00,       %di
    movw $1<<7,         %cx
    rep movsd               # 0:0x7c00 -> 0x7240:0x7c00

    jmp $SEG_MBR,       $still
still:
```

移动使用 `rep movsd` 指令进行，`ds:si` 指向源地址，`es:di` 指向目标地址，`cx` 指向移动的次数。这里将 `0x7c00` 处的 `512` 字节（一个扇区）移动到 `0x7_a000`，所以目的地址的段寄存器拆成了 `0x7240`。最后执行长跳转刷新 `%cs` 和 `%ip`

## 获取内存容量

直接借助 [BIOS 的功能](https://wiki.osdev.org/Detecting_Memory_(x86)#BIOS_Function:_INT_0x15,_EAX_=_0xE820)，`int $0x15, %eax = 0xe820` 来获取内存容量

这个功能会返回一个数组，数组元素是一个 20 字节的结构体（ARDS 结构体），如前面内存布局所示，将会保存到内存 `0x7_a204` 处；另外还会把数组大小保存到内存 `0x7_a200` 处

## 读取磁盘的内核，并移动到内存地址 0

读取磁盘也是直接借助 BIOS 功能，`int $0x13, %ah = 2`。当读取完成后，也是执行 `rep movsd` 来移动数据

该 BIOS 功能中，`%es:%bx` 是目的地址。需要注意的一点是，`%bx` 是 `16-bit` 的，最大值 `0xffff` 即 `64KB`，当读取的磁盘扇区累计超过 `64KB` 时，就需要增加 `%es` 的值

```assembly
    # 常规情况下每次增加一个扇区
    addw $0x200,        %bx
    # 但是当增加之后 %bx 回滚为 0
    cmpw $0,            %bx
    jnz  4f
    # 就需要为 %es 增加 64KB
    movw %es,           %bx
    addw $0x1000,       %bx
    movw %bx,           %es
    xorw %bx,           %bx
4:
    jmp  continue_read
```

## 进入保护模式

```assembly
    cli
    movw %cs,           %ax
    movw %ax,           %ds
    inb  $0x92,         %al     # open A20
    orb  $2,            %al
    outb %al,           $0x92

    lgdt gdt_48

    movl %cr0,          %eax    # enable p.m.
    orl  $1,            %eax
    movl %eax,          %cr0

    ...

boot_gdt:
	.quad 0x0000000000000000
	.quad 0x00cf9a000000ffff # exe, no-readable, no-conform
	.quad 0x00cf92000000ffff # no-exe, no-writable, down
gdt_48:
	.word .-boot_gdt
	.long SEG_MBR<<4 + 0x7c00 + (boot_gdt - _start)
```

具体来说分三步：

- 启用 `A20` 地址线
- 加载 `GDT`
- 设置 `CR0` 的 `PE` 位

`GDB` 的格式参考 [OSDev GDT](https://wiki.osdev.org/Global_Descriptor_Table)，`hoo` 将引导阶段和内核阶段使用的 `GDT` 分开维护了。在这个阶段，`GDT` 是写死的，代码段和数据段各自临时使用一个 `GDT` 来进入保护模式而已

`lgdt` 指令的操作数是一个 `48-bit` 的内存地址，前 `16-bit` 通过将当前地址减去 `boot_gdt` 标号，得到的是 `GDT` 的长度。后 `32-bit` 表示的是内存中放置 `GDT` 的地址，由于 `MBR` 一开始就移动到了高地址 `0x7_a000`，所以这边的计算是围绕高地址进行的，`_start` 标号放在 `MBR` 最开头，最终表达式得到的是高地址的 `GDT`

## 启用分页机制

一个页目录表可以表示 `4GB`，所以整个内核线性空间使用一个页目录表就够了。一个页表可以表示 `4MB`，所以整个内核线性空间需要使用 1024 个页表

![](https://pic1.imgdb.cn/item/67763996d0e0a243d4edc445.png)

上面是内核进程的线性空间，每个 `PDE` 各指示 `4MB` 并依次递增，但实际上最后一个 `PDE` 不会使用，这使得内核（其实所有进程也是这个设计思路）的线性空间会损失最高的 `[0xffc0_0000, 0xffff_ffff]` 这 `4MB` 空间。但最后一个 `PDE` 通过指向页目录表自身，使得内核（每个进程）通过虚拟地址访问自己的页目录表成为可能。比如，进程通过访问 `0xffff_f000` 可以访问页目录表的 `PDE #0`；通过访问 `0xffc0_0000` 可以访问第一个页表的 `PTE #0`

`hoo` 的规划是将页目录表放置在 `0x7_8000`，第一个页表放置在 `0x7_9000`

![](https://pic1.imgdb.cn/item/677953c4d0e0a243d4ef0582.png)

上面给出是页目录表和第一个页表的具体数值：

引导阶段页目录表会使用三个 `PDE`：

- `PDE #0`：指向第一个页表，表示 `[0x0, 0x40_0000)`，主要是为了包含最开始实模式的线性空间
- `PDE #512`：也是指向第一个页表，但因为使用了更高地址的 `PDE`，表示 `[0x8000_0000, 0x8040_0000)`，所以可以通过这部分线性地址访问实模式的线性空间 —— 也即内核。`hoo` 的规划中，会把 `[0x8000_0000, 0xffff_ffff]` 这部分高地址映射到内核，这使得所有进程都可以共享内核 —— 换句话说，普通进程能够使用的只有低地址 `[0, 0x8000_0000)`
- `PDE #1023`：指向页目录，一个后门用于通过线性地址访问页目录表

第一个页表初始化是为了做实模式 `1MB` 的映射，这部分映射可以通过顺序映射的方式完成 —— 即上面给出的方式。这里只包含了实模式的 `1MB`，但直接做整个 `4MB` 映射也是没问题

下面是赋值页目录表的代码，准确的说是赋值三个 PDE：

```assembly
    .set SEG_PDTABLE,     0x7800
    .set SEG_PGTABLE,     0x7900
    .set KERN_MAPPING,    0x80000000
    .set PDE_HIGH_OFF,    (KERN_MAPPING >> 20)
    .set PDE_LAST_OFF,    (0xffc - PDE_HIGH_OFF)

    movl $SEG_PGTABLE<<4, %eax
    orl  $7,              %eax
    movl pdtable_addr,    %ebx
    movl %eax,            (%ebx)
    addl $PDE_HIGH_OFF,   %ebx
    movl %eax,            (%ebx)
    movl $SEG_PDTABLE<<4, %eax
    orl  $7,              %eax
    addl $PDE_LAST_OFF,   %ebx
    movl %eax,            (%ebx)

pdtable_addr:
    # .long 移动 MBR 到高地址后，%ds 会改变，访问页目录表的内存地址要重新计算
```

`%eax` 保存 PDE 的值，`%ebx` 保存 PDE 的内存地址。`PDE#0` 通过标号 `pdtable_addr` 计算，在此基础上加上 `PDE_HIGH_OFF` 就是 `PDE#512`，再加上 `PDE_LAST_OFF` 就是 `PDE#1023`

下面是赋值第一个页表的代码：

```assembly
    movl $0x100,        %ecx
    movl $0,            %eax
    movl pgtable_addr,  %ebx
pgtable:
    movl %eax,          %edx
    orl  $7,            %edx
    movl %edx,          (%ebx)
    addl $0x1000,       %eax
    addl $4,            %ebx
    loop pgtable

pgtable_addr:
    # .long 移动 MBR 到高地址后，%ds 会改变，访问第一个页表的内存地址要重新计算
```

借助 x86 `loop` 指令，循环次数 `%ecx` 设置为 256，每次循环通过 `%eax` 和 `%edx` 计算出 PTE 的值，然后写入第一个页表所在的内存地址。这个内存地址通过 `movl pgtable_addr, %ebx` 得到，`AT&T` 语法将标号移动到寄存器是指将标号处定义的数值移动到寄存器；另一种相似的语法是 `movl $symbol, %ebx`，多了 `$` 表示将标号处的内存地址移动到寄存器，是两种不一样的语法

## 跳入保护模式

```assembly
    .set SEG_PDTABLE,     0x7800

    movl $SEG_PDTABLE<<4, %eax
    movl %eax,            %cr3
    movl %cr0,            %eax
    orl  $0x80000000,     %eax
    movl %eax,            %cr0

    ljmp $0x08,           $0
```

跳入保护模式是很简单的一件事，将控制寄存器 `%cr3` 赋值页目录表地址，将 `%cr0` 开启 `PE`（Protected Mode Enable）标识位就够了。最后执行长跳转刷新段寄存器，刷新 CPU 流水线，并将执行流重定向到内存 0 地址处。在这个地方，MBR 前面的逻辑已经把内核放在这里了。换句话说，跳转到内存地址 0，即是跳入了内核

# 内核入口

完整代码详见 [kern/entry.c](https://github.com/horbyn/hoo/blob/master/kern/entry.c)

内核入口这部分代码编译得到的二进制会通过链接脚本 [kernel.ld](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kernel.ld#L9) 放在整个内核二进制的最前面，也即最后会被加载到内存 0 处

```ld
. = 0x80000000;
.text : AT(ADDR(.text) - 0x80000000) /*1*/ { 
    kern/entry.o(.text)              /*2*/
    *(.text)                         /*3*/
}
```

关于链接脚本更详细的内容这里略过，上面代码片段的几处注释解释如下：

- 链接脚本分为 VMA（Virtual Memory Address）和 LMA（Load Memory Address），前者是二进制文件编译、链接之后得到的地址；后者是最终加载到内存的地址
- 注释 1 处是规定 `.text` 段的 VMA 为 `0x8000_0000`（通过 `. = 0x80000000;` 设定），LMA 为 0（通过 `AT(0)` 设定，其中的 0 是通过 `ADDR(.text) - 0x80000000` 计算得到的）
- 注释 2 处是将 `kern/entry.o` 二进制文件放在 `.text` 段第一位
- 注释 3 处是将剩余的 `.text` 节放在 `.text` 段后面（段 Segments 和节 Sections 的区别略）

在 `entry()` 最开始，有一段内联汇编代码：

```assembly
# 1. 重置上下文
movw $0x10,    %ax
movw %ax,      %ds
movw %ax,      %es
movw %ax,      %fs
movw %ax,      %gs
movw %ax,      %ss
movl $0x80000, %esp

# 2. 伪造调用约定
pushl $0x77ffc
pushl $0
movl %esp,     %ebp

# 3. 跳入高地址
pushl $go
ret
go:
```

解释如下：

1. 重置上下文。此处 `hoo` 刚从引导阶段的临时上下文进入内核，重新设置一个上下文环境。其实主要是重置栈，因为对于 C 语言来说，设置了栈就可以使用了
2. 伪造调用约定。由前面内存布局可以知道，内存 `0x7_7ffc` 放置了一条 `jmp .` 指令，所以第一个指令就是把指令地址入栈。第二个指令是入栈 0，第三个指令是将 `%ebp` 赋值为与 `%esp` 一样。这三条指令就对应于 x86 调用约定的（1）入栈返回地址；（2）入栈上一个栈帧的 `%ebp`；（3）调用 `call` 指令切换指令流（当然这里没有）；（4）切换执行流后将当前栈帧的栈底重置
3. 跳入高地址。在引导阶段最后一条指令 `ljmp $0x08, $0` 执行后，`%eip` 会变成 0。但是逻辑上，执行流在内核的时候，应该是高地址。对于 `entry.c` 源文件来说，链接脚本可以保证其对应的二进制的符号都是 `0x8000_0000` 以上，自然标号 go 也会是高地址。x86 有两条可以改变 `%eip` 的指令：`call` 和 `ret`，都是从栈顶取出数值，前者会改变 `%cs` 和 `%eip`，后者只会改变 `%eip`

后面的代码

```c
void entry(void) {
    kern_init();
    kern_exec();
}
```

会进行内核的初始化，然后进行内核自己的事件循环

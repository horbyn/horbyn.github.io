---
title: 「从零到一」内存管理
date: 2025-01-30 10:37:23
excerpt: x86 内核的内存管理机制负责分配和管理系统内存，包括虚拟内存管理和物理内存管理。物理内存管理负责统筹整个系统的内存空间，暴露分配和释放接口供上层使用；虚拟内存管理需要启用页表机制，它为每个进程设置了一个独立的线性空间，确保进程之间的隔离。同时，虚拟内存管理还是内存动态分配的基础
categories: KERNEL
tag: hoo
---

# 获取物理内存容量

在引导阶段通过 `int $0x15, %eax = 0xe820` 获取的 ARDS 结构体数组保存在内存 `0x7_a204` 处，解析代码如下，详见 [kern/module/mem.c](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/module/mem.c#L14)，逻辑很简单，直接在代码处注释了：

```c
// ARDS 结构体
typedef struct {
    uint32_t base_low_;
    uint32_t base_hig_;
    uint32_t length_low_;
    uint32_t length_hig_;
    uint32_t type_;
} ards_t;

// 内存信息结构体
static struct mem_info {
    uint32_t base_;
    uint32_t length_;
} __mminfo = { 0x100000, 0 }; // 初始化为从 0x10_0000 开始

// 从内存 0x7_a200 处获取相关信息
uint32_t *ards_num = (uint32_t *)0x7a200;
ards_t *ards = (ards_t *)0x7a204;

for (uint32_t i = 0; i < *ards_num; ++i) {
	if ((ards[i].type_ == 1) // 类型为 1 表示软件可用，其他值表示保留给硬件使用
	&& (ards[i].base_low_ == __mminfo.base_ + __mminfo.length_)) {
		// 仅记录连续的内存区域作为可用内存
		__mminfo.length_ += ards[i].length_low_;
	}
}
```

# 物理内存管理

对于 `32-bit` 内核来说，物理内存最大支持 `4GB`（`2^32`），`hoo` 直接用位图作管理的数据结构。一个物理页对应一个比特位，所以 `4GB` 对应的位图结构的大小是 `128KB`

这 `128KB` 大小是静态的，即在代码中定义一个这么大的数组，当需要访问物理内存管理结构时，直接从内核中取得。理由是物理内存管理模块是使用内存的基础，其管理结构必须预先确定，否则当物理内存管理模块自身需要使用管理结构时，去哪里取得呢？

## 分配与释放

主要就是操作位图，比特位清位表示可以分配的，置位表示不可分配。由于一个比特位对应一个物理页，所以得到空闲的比特位下标后可以像下面这样转化：

```C
/*
 * 0x0000_0000
 *             0x0000_0001
 *                         0x0000_0002
 *                                           0x000f_fffe
 *                                                       0x000f_ffff
 * ┌───────────┬───────────┬───────────┬─────┬───────────┬───────────┐
 * │           │           │           │ ... │           │           │
 * └───────────┴───────────┴───────────┴─────┴───────────┴───────────┘
 * 0x0000_0000
 *             0x0000_1000
 *                         0x0000_2000
 *                                           0xffff_e000
 *                                                       0xffff_f000
 */
```

上方是位图索引，下方是物理页地址，可以发现一个规律就是将位图索引左移 `12` 位就是物理页地址了。需要注意的是，物理内存中 `hoo` 不管理最低端的 `1MB`，所以最终的物理地址还需要加上 `0x10_0000`

因此，分配物理地址就是找出空闲的比特位，然后置位；释放就是找出对应的比特位，清位

```c
#define MM_BASE    0x100000    // 可用内存地址起址
static bitmap_t __bm_phymm;    // 物理内存管理模块的位图结构

// 分配物理地址
void *
phy_alloc_page() {
    int i = bitmap_scan_empty(&__bm_phymm);
    bitmap_set(&__bm_phymm, i);
    return (void *)((i <<= 12) + MM_BASE);
}

// 释放物理地址
void
phy_release_page(void *phy_addr) {
    if (phy_addr == null)    return;
    if ((uint32_t)phy_addr < MM_BASE)
        panic("phy_release_page(): cannot release kernel physical memory");

    int i = ((uint32_t)phy_addr - MM_BASE) >> 12;
    bitmap_clear(&__bm_phymm, i);
}
```

`bitmap_t` 是一个统一封装的位图结构，详见 [kern/utilities/bitmap.h](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/utilities/bitmap.h#L10)

- 分配
	- `bitmap_scan_empty()` 在给定位图结构里面寻找一个为 0 的比特位，返回位图数组的索引
	- `bitmap_set()` 将给定位图数组的元素置位
	- 最后将索引左移 12 位并加上 `1MB` 即可用的物理地址
- 释放
	- `null` 是一个 `void *` 指针，并不是 0，否则虚拟地址 0 就不能被使用了。本质上 `null` 是一个符号，对于内核，它的定义详见 [kern/x86.c](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/x86.c#L3)；对于用户态应用，它的定义详见 [user/null.c](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/user/null.c#L2)
	- `panic()` 函数的作用是向显卡写入字符串，然后执行 `hlt` 指令，更多细节详见 [kern/panic.c](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/panic.c#L47)
	- 释放物理地址的时候，先计算出位图数组的索引，然后调用 `bitmap_clear()` 将位图数组指定元素清位

# 页表机制

虚拟内存管理的基础设施是页表机制，可以参考其他资源。`hoo` 将每个页目录表的最后一项指向页目录表自己，利用这个窍门可以实现通过线性地址访问页目录表和页表，下面来详细说下这个窍门

![](https://pic1.imgdb.cn/item/67763996d0e0a243d4edc445.png)

如图所示是线程的线性空间，每个 PDE 代表了 `4MB` 的线性空间，所有 1024 个 PDE 就可以表示整个 `4GB` 空间

换句话来说，当线程访问的线性地址是 `0x3f_1000` 就是在访问 PDE 0、当访问 `0xa0_3000` 就是在访问 PDE 2，通过上面这个图从逻辑上可以很快找到答案。在真实的访存场景下，x86 MMU（Memory Management Unit，内存管理单元）会自动将线性地址转换为物理地址，不需要 OS 开发者关心

在启用了分页后，访问每个线性地址总是确定的，即 PDE 是固定的，不同的是 PDE 的值，这个值就是一个物理地址。可以在不同时刻为 PDE 填入不同的值，此时便说，同一个线性地址可以映射不同的物理地址

MMU 的逻辑详见 [IA32 手册 volume 3A，4.3 章图片 4-2](https://www.intel.com/content/dam/www/public/us/en/documents/manuals/64-ia-32-architectures-software-developer-vol-3a-part-1-manual.pdf)，如下

![](https://pic1.imgdb.cn/item/67c14763d0e0a243d407d43b.png)

可以视为 3 次计算，第一次计算 PDE，第二次计算 PTE，第三次计算物理页

借助这个规则，当 OS 开发者想要访问页目录表时，那就要让第一次计算 PDE、第二次也是计算 PDE、第三次也是计算 PDE，则计算完毕就是访问页目录表自身了。所以，当最后一项 PDE 指向页目录表自身时：

- 线性地址最高 10 位给出 `0x3ff`，则第一次计算会找到 PDE 1023
- 线性地址中间 10 位给出 `0x3ff`，则第二次计算依然会找到 PDE 1023
- 线性地址最低 12 位就可以指定任意索引了，比如给出 `0x1` 时，第三次计算会找到 PDE 1；给出 `0x123` 时，第三次计算会找到 PDE 291

当把上述线性地址组合起来，高 10 位、中间 10 位全部填 1，就是区间 `[0xffff_f000, 0xffff_ffff)`，用来访问页目录表本身

同样的道理，当需要访问页表本身时，需要第一次计算 PDE、第二次计算 PDE、第三次计算 PTE。其中，第二次需要指定 PDE 索引，所以组合起来就是区间 `[0xffc0_0000, 0xffff_f000)`

根据这个规则，定义以下宏用来操作页目录表和页表，详见 [kern/paga/page_stuff.h](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/page/page_stuff.h#L13)：

```c
#define PGDOWN(x, align)    (((uint32_t)(x)) & ~((align) - 1))
#define PGUP(x, align)      (PGDOWN(((uint32_t)(x) + (align) - 1), (align)))
#define PD_INDEX(x)         (((x)>>22) & 0x3ff)
#define PT_INDEX(x)         ((((uint32_t)(x))>>12) & 0x3ff)
#define PG_DIR_VA           0xfffff000
#define GET_PDE(va)         \
    (PG_DIR_VA | (PD_INDEX(PGDOWN((va), PGSIZE)) * sizeof(uint32_t)))
#define GET_PTE(va)         \
    (0xffc00000 | ((PD_INDEX(PGDOWN((va), PGSIZE)) << 12) \
    | (PT_INDEX(PGDOWN((va), PGSIZE)) * sizeof(uint32_t))))
```

- `PGDOWN()`：线性地址向下取整，即 `0xc000_5124` 会输出 `0xc000_5000`，物理页需要对齐 `4KB`
- `PGUP()`：线性地址向上取整，即 `0xc000_5124` 会输出 `0xc000_6000`
- `PD_INDEX()`：线性地址转换为页目录表索引，即 `0xc000_5124` 会输出 `0xc00`，表示 PDE 768
- `PT_INDEX()`：线性地址转换为页表索引，即 `0xc000_5124` 会输出 `5`，表示 PTE 5
- `GET_PDE()`：线性地址转换为对应页目录表的线性地址，原理就是上面的窍门，定义较为繁琐
- `GET_PTE()`：线性地址转换为对应页表的线性地址，原理也是上面的窍门

借助这些宏定义，可以实现创建映射的接口，具体代码详见 [kern/mem/pm.c](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/mem/pm.c#L83)，以下代码有删减：

```c
void
set_mapping(void *va, void *pa, pgelem_t flags) {

    __asm__ ("invlpg (%0)" : : "a" (va));

	// 取出 PDE
    pgelem_t *pgdir_va = (pgelem_t *)GET_PDE(va);
    const pgelem_t FLAGS = PGFLAG_US | PGFLAG_RW | PGFLAG_PS;
    pgelem_t pde_flags = (*pgdir_va & ~PG_MASK) & FLAGS;
    if (pde_flags != FLAGS) {
        // 缺乏页表
        void *pgtbl = phy_alloc_page();
        *pgdir_va = (pgelem_t)pgtbl | FLAGS;
    }

    // 取出 PTE
    pgelem_t *pgtbl_va = (pgelem_t *)GET_PTE(va);
    *pgtbl_va = (pgelem_t)pa | flags;
}
```

上面代码片段有一条 `x86` 指令 `invlpg`，详见 [《IA32 Architectures Software Developer's Manual, Volume 3A》，Sections 4.10.4 关于 TLB 的解释](https://www.intel.com/content/dam/www/public/us/en/documents/manuals/64-ia-32-architectures-software-developer-vol-3a-part-1-manual.pdf)，该指令用于：

- 当修改了 PDE 映射时，应该为使用这个 PDE 的线性地址使用 `invlpg`
- 当修改了 PTE 映射时，应该重新赋值 `%cr3`
- 如果一个多用途的 paging-structure（比如既用作 PTE 又用作 PDE）被修改，则需要多次为使用这个表项的线性地址使用 `invlpg`（比如先对 PTE 线性地址 `invlpg` 后对 PDE 线性地址 `invlpg`）

上面代码总体逻辑是：

- 首先取消 MMU 的映射缓存，通过 `invlpg` 指令完成
- 然后取出 PDE，通过 `GET_PDE()` 宏获得一个线性地址，通过这个线性地址就可以访问到页目录表。访问页目录表对应项，查看 [页目录表标识位](https://wiki.osdev.org/Paging#Page_Directory) 判断是否已写入页表（`hoo` 写入页表是总是将用户可访问的 US 标识、可读可写的 RW 标识、存在位 PS 标识置位）。如果没有页表，则重新分配一个物理页作为页表
- 最后取出 PTE，通过 `GET_PTE()` 宏获得一个线性地址，通过这个线性地址访问页表，最后将形参指定的物理地址写入页表

`hoo` 没有提供取消映射的接口，一是每次创建映射的时候，直接覆盖就可以了；二是取消映射换一个角度来看，只要能保证线程未来不使用这个线性地址，那就不会有问题，相当于这个映射就被取消了。而这一点可以交给后一章要实现的虚拟内存管理模块来保证

# 虚拟内存管理

虚拟内存也是需要管理的，毕竟在进程的线性空间里，地址也是需要唯一的

线性空间有两种类型：内核空间和用户空间。内核线性空间只有真正的内核线程（`hoo` 进程和线程概念是等同的，因为进程就是单线程进程，后文统一称为线程）`hoo` 一个，用户线性空间则适用于其余剩下的所有线程

线性空间有个前提，高端地址 `[3GB, 4GB)` 是共享的，所以无论内核还是用户，实际上都只能使用 `[0, 3GB)` 空间

![](https://pic1.imgdb.cn/item/679c64e7d0e0a243d4f8beda.png)

对于内核来说：

- 开头 `1GB` 不仅自己使用，还会暴露出去（共享给所有进程）
- 紧接着的 `2GB` 也是自己使用，不会暴露出去
- 最后的 `1GB` 不可以使用，这是重复开头的 `1GB` 映射，用于共享

对于用户线程来说：

- 开头 `3GB` 可以自己使用，不会暴露出去
- 最后 `1GB` 不可以使用，这是内核的映射

## 管理方式

总体来说有位图结构和链表结构两种管理方式，前者逻辑和物理内存管理模块一样，后者就是分配了多少内存就用链表结点记录下来

`hoo` 的管理结构是两者都有。理由是，申请线性地址时会涉及连续的分配，位图结构没有额外信息可以在释放地址时知道 "连续" 的概念，链表则可以在数据域想填充什么数据就填充什么数据。而位图则是用来分配管理结构，因为管理结构也需要使用线性地址，而链表是动态结构，没办法在事前知道需要使用多少结点

管理结构的分配释放和物理内存管理一样，详见 [kern/mem/vm_kern.c 分配函数](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/mem/vm_kern.c#L34) 和 [kern/mem/vm_kern.c 释放函数](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/mem/vm_kern.c#L49)

下图是链表结构的简化视图，具体定义详见 [kern/mem/vspace.h](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/mem/vspace.h#L19)：

![](https://pic1.imgdb.cn/item/679c7cddd0e0a243d4f8c025.png)

这是一个双重链表。单链表负责管理虚拟地址（虚线箭头矩形），每个单链表结点总是有序的，高地址总是放在链头，目的是分配地址时尽可能保证 `O(1)` 复杂度。引入双重链表的理由是，释放可能会破坏单链表有序的结构，比如从有序的链表中间释放一个线性地址，那么必须将链表后面的结点重新组织为另一个链表，详见后文释放一节

## 分配

分配存在两种情况，分别是在空链表上分配、在非空链表上分配

### 单链表为空

![](https://pic1.imgdb.cn/item/679c8449d0e0a243d4f8c067.png)

考虑虚拟内存管理模块（本章简称为虚拟模块）最开始的时候，某线程请求分配 `8KB` 内存。虚拟模块搜索空闲地址时，总是从 `0x0000_0000` 开始，这个时候虚拟模块中的双重链表也为空，所以锁定空闲地址为 `0x0000_0000`

`8KB` 即两个物理页，因此结点记录 `0x0000_0000` 这个线性地址以及 `2`。因此，**单链表为空时，新建一个单链表，新建管理结构**

具体代码详见 [kern/mem/vm.c](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/mem/vm.c#L66)，以下是简化片段：

```c
// 新建单链表
vspace_t *cur = prev;
if (list_isempty(&prev->list_)) {
	cur = vspace_alloc();
}

// 新建单链表结点
node_t  *node_free = node_alloc();
vaddr_t *vaddr_free = vaddr_alloc();
vaddr_set(vaddr_free, last_end, amount);
node_set(node_free, vaddr_free, null);
list_insert(&cur->list_, node_free, 1);

// 单链表加入双重链表
if (list_isempty(&prev->list_)) {
    vspace_append(prev, cur);
}
```

`prev` 是在遍历双重链表过程中，找到的第一个可分配地址的元素。如果找到的 `prev` 为空（本节描述的情况），则创建一个新的单链表，并且在最后将该新链表加入双重链表中

中间的逻辑则是创建结点，填充要分配的线性地址（`last_end`）、要分配多少页（`amount`），然后加入单链表的链头（`list_insert()`）

### 单链表非空

假设还是这个线程，经过一段时间的运行后（若干次分配和释放）请求 `60KB` 内存，那么：

![](https://pic1.imgdb.cn/item/679c8ca2d0e0a243d4f8c120.png)

进程依然是从 `0x0000_0000` 开始遍历，这里先忽略其中的细节，只关注核心思路，即双重链表记录了已经使用的地址区间是 `[0x0000_0000, 0x0000_2000) ∪ [0x0001_0000, 0x0001_7000)`，中间有一段地址区间是可用的，但稍微计算后会发现只有 `56KB`，因此最后会将空闲地址锁定在 `0x0001_7000`。之后便是一些链表的插入操作，因此，**单链表非空时，插入结点**

具体代码详见 [kern/mem/vm.c](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/mem/vm.c#L52)，以下是关键代码片段：

```c
while (worker != null) {

    if (worker->next_ != null
        && (((worker->next_->begin_ - last_end) / PGSIZE) < amount)) {
        // 没有足够的空间

        last_end = worker->next_->end_;
        worker = worker->next_;
    } else {
        // 拥有足够的空间
    }

} // end while()
```

`worker` 是双重链表的工作指针，`while()` 是整个双重链表的遍历过程。`if()` 条件（本节描述的情况）表示当前的地址区间太少不够分配，则可分配线性地址、工作指针往后移。直至找到足够大的空间，进入 `else()` 复用前一节逻辑

## 释放

释放的情况稍微有点复杂，这是因为分配地址总是从 `0x0000_0000` 开始，且单链表是递减有序排列的，这就要求释放采取一些手段来保证所有单链表依然有序

### 释放两端地址

某线程经若干次分配释放后，现在请求释放 `0x0000_0000` 这个线性地址

![](https://pic1.imgdb.cn/item/679c904fd0e0a243d4f8c1a2.png)

这里直接释放就行，从整体上看地址区间没有问题。另一种情况比如释放 `0x0000_2000` 也是同样道理。所以，如果**释放地址就是链头第一个，或者链尾最后一个（即释放地址在两端），直接删除**

具体代码详见 [kern/mem/vm.c](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/mem/vm.c#L98)，以下是简化片段：

```c
enum location_e {
    LCT_BEGIN = 0,
    LCT_MIDDLE,
    LCT_END
} lct;

// 查找待释放地址 va 所在的单链表
vspace_t *prev_list = null;
while (cur_list != null) {
    if (cur_list->begin_ <= (uint32_t)va && (uint32_t)va < cur_list->end_)
        break;
    prev_list = cur_list;
    cur_list = cur_list->next_;
}

// 遍历单链表
do {
    node = list_find(&cur_list->list_, i);
    if (node != null) {
        lct = (i == 1) ? LCT_BEGIN : ((i == cur_list->list_.size_) ? LCT_END : LCT_MIDDLE);
        // 释放单链表两端地址
        list_remove(&cur_list->list_, i);

        // ...
    }
    ++i;
} while (node != null);

// 释放物理页
// 释放管理结构
```

定义一个枚举值用来表示单链表结点的位置：位于单链表的链头 `LCT_BEGIN`、中间 `LCT_MIDDLE` 和链尾 `LCT_END`

`cur_list` 是遍历双重链表时的工作结点，第一个 `while()` 循环根据待释放地址 `va` 来确定需要修改的单链表。当找到这样的单链表后，`cur_list` 会指向它

第二个 `do-while()` 循环用来遍历单链表，每枚举一个链表结点，就判断其位置。对于单链表两端的结点，只需要直接移除

后续的逻辑依次是释放虚拟地址 `va` 对应的物理页，这会调用物理内存管理模块的接口来释放；以及释放虚拟模块使用的管理结构，与管理结构相关的分配和释放接口详见 [kern/mem/metadata.{h,c}](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/mem/metadata.h#L8)，逻辑十分直白简单

### 释放中间地址

这是另一种释放地址的情况，假设之后线程需要释放 `0x7000` 地址，则：

![](https://pic1.imgdb.cn/item/679c9451d0e0a243d4f8c1fe.png)

现在，**释放地址前后有其他结点（即释放地址在中间），则需要为链表后面的所有结点创建一个新的单链表**

关键代码片段如下：

```c
do {
    node = list_find(&cur_list->list_, i);
    if (node != null) {
        lct = (i == 1) ? LCT_BEGIN : ((i == cur_list->list_.size_) ? LCT_END : LCT_MIDDLE);
        list_remove(&cur_list->list_, i);

        if (lct == LCT_MIDDLE) {
            // 释放单链表中间地址
            new_list = vspace_alloc();
            for (uint32_t j = i, k = 1; j <= cur_list->list_.size_;) {
                node_t *n = list_remove(&cur_list->list_, j);
                list_insert(&new_list->list_, n, k++);
                prev_vs->next_ = new_list;
            } // end for(j)
            vspace_append(new_list, cur_list);
        }
    }
    ++i;
} while (node != null);
```

当在单链表遍历过程中发现这是一个中间结点，首先创建一个新的单链表，然后 `for()` 循环将后续的结点 "转移" 到新链表 —— 原链表 `list_remove()`，新链表 `list_insert()`。最后将原链表 `vspace_append()` 到新链表后面（为了减少遍历次数，新链表放在前面）

# 动态内存分配

虚拟内存分配粒度太大了，每次分配都是一个 `4KB` 页，因此引入动态内存分配来作更小粒度的内存分配

`hoo` 和 `C/C++` 程序稍微有点不一样，其线性空间如下：

![](https://pic1.imgdb.cn/item/67a1b668d0e0a243d4fbc4cd.png)

整个 `4GB` 空间分为两半，线程自己可用的空间和内核空间各 `2GB`。`hoo` 为所有线程统一分配栈，所以线程栈不放在线程自己的空间，而是放在内核空间，除此之外和普通 `C/C++` 程序线性空间是一致的

程序二进制数据即代码段、数据段这些，不同程序有不同大小，所以这里二进制数据的边界是浮动的。对于 `hoo` 内核，为简化问题，二进制数据边界定为一个页表（实际上 `hoo` 纯二进制很小，几十 kb），即 `4MB`，也即 `hoo` 堆空间从 `0x40_0000` 开始

无论是前面粒度更大的虚拟内存分配，还是现在粒度更小的动态内存分配，都是从线程自己的堆空间中分配内存

`hoo` 是参考 [Linux 0.11 桶分配机制](https://elixir.bootlin.com/linux/0.11/source/lib/malloc.c#L117)（其解释可以参考赵炯博士的 [《Linux 内核 0.11 详细注释》，pdf 456 页](https://mirror.math.princeton.edu/pub/oldlinux/download/clk011.pdf)）作出的实现

![](https://pic1.imgdb.cn/item/67a1b46ad0e0a243d4fbc49d.png)

每个线程都有一个 "manager"，管理着各自的堆空间。"manager" 将可用空间组织为桶，每个桶都有其要管理的内存大小，比如 8B 桶则负责分配和回收 8B 内存空间

![](https://pic1.imgdb.cn/item/67a1bae9d0e0a243d4fbc63e.png)

桶下面挂靠着一个或多个链表，每个链表都是一个 `4KB` 页，所以不同桶的链表元素的数量是不一样的，8B 桶可以近似看成 `4KB / 8` 个元素，16B 桶则近似是 `4KB / 16`

![](https://pic1.imgdb.cn/item/67a1bc30d0e0a243d4fbc65d.png)

每个 `4KB` 页的格式从管理信息中的链头开始，连接下一个链表元素，直至 `4KB` 页中所有元素都连接到一起

![](https://pic1.imgdb.cn/item/67a1bd75d0e0a243d4fbc69a.png)

随着分配释放的进行，有可能一个桶会耗尽。这个时候会从线程堆空间再分配另一个 `4KB` 页，并格式化为上述结构

小结一下动态内存分配机制：

- 分配内存可以视为从链表中取出元素
- 释放内存可以视为将元素加入链表

`hoo` 实现了一个格式化链表，详见 [kern/mem/format_list.h](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/mem/format_list.h#L10)，该定义对应着链表的管理信息：

```c
typedef struct format_list {
    list_t             list_;     // 链表
    uint32_t           capacity_; // 链表元素个数
    struct format_list *next_;    // 下一条链表
} fmtlist_t;
```

这里链表是一个统一的数据结构，详见 [kern/utilities/list.h](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/utilities/list.h#L11)，提供以下接口：

```c
void   list_init(list_t *list, bool cycle);              // 初始化
node_t *list_find(list_t *list, int idx);                // 按索引查找
void   list_insert(list_t *list, node_t *node, int idx); // 插入元素到指定索引
node_t *list_remove(list_t *list, int idx);              // 移除指定索引元素
bool   list_isempty(list_t *list);                       // 判空
```

格式化链表提供分配和释放两个接口：

```c
void *fmtlist_alloc(fmtlist_t **fmtlist);
bool fmtlist_release(fmtlist_t **fmtlist, void *elem);
```

格式化链表的分配，其实是取出链表元素，即 `list_remove()`；释放则对应插入链表元素，即 `list_insert()`

桶管理者定义详见 [kern/mem/bucket.h](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/mem/bucket.h#L10)：

```c
typedef struct buckX_manager {
    uint32_t             size_;
    fmtlist_t            *chain_;
    struct buckX_manager *next_;
} buckx_mngr_t;
```

基于上述基础结构，`hoo` 实现的动态分配详见 [kern/dyn/dynamic.c](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/dyn/dynamic.c#L13)：

```c
void *
dyn_alloc(uint32_t size) {
    if (size == 0)    return null;

    // #1
    pcb_t *cur_pcb = get_current_pcb();
    buckx_mngr_t *mngr = cur_pcb->hmngr_;
    pgelem_t flags = PGFLAG_US | PGFLAG_RW | PGFLAG_PS;

	// #2
    while (mngr != null) {
        if (mngr->size_ >= size) {
            if (mngr->chain_ == null) {
                void *pa = phy_alloc_page();          // 分配物理页
                mngr->chain_ = vir_alloc_pages();     // 分配线性地址
                set_mapping(mngr->chain_, pa, flags); // 建立映射
            }
            break;
        }
        mngr = mngr->next_;
    }

    // #3
    if (mngr == null) {
        uint32_t pages = size <= PGSIZE ? 1 : (size + PGSIZE - 1) / PGSIZE;

        void *va = vir_alloc_pages();                // 连续的线性地址的起始
        for (uint32_t i = 0; i < pages; ++i) {
            void *pa = phy_alloc_page();             // 分配物理页
            set_mapping(va + i * PGSIZE, pa, flags); // 建立映射
        }
        return va;
    }

    // #4
    return fmtlist_alloc(&mngr->chain_);
}
```

- 注释 1：由于堆空间每个线程都不一样，所以 `get_current_pcb()`（暂时当成黑盒）取出线程 pcb，再取出桶管理者
- 注释 2：`while()` 循环遍历所有的桶。这里有两种情况，要么动态分配 1024B 以下的空间，要么动态分配更大的空间。对于前者，初始情况下每个桶的链表是空的，这个时候需要新分配一个 `4KB` 页
- 注释 3：如果是动态分配 1024B 以上的空间，则前一步循环遍历完后，桶管理者依然会是空的，这个时候再进行按需分配，分配完成后直接返回该线性地址
- 注释 4：如果是动态分配 1024B 以下的空间，则复用格式化链表的分配接口来分配内存

动态释放详见 [kern/dyn/dynamic.c](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/dyn/dynamic.c#L52)：

```c
void
dyn_free(void *ptr) {
    if (ptr == null)    return;

    pcb_t *cur_pcb = get_current_pcb();
    buckx_mngr_t *mngr = cur_pcb->hmngr_;

    while (mngr != null) {
        // #1
        if (fmtlist_release(&mngr->chain_, ptr)) {
            // #2
            if (mngr->chain_->capacity_ == mngr->chain_->list_.size_) {
                vir_release_pages();
                mngr->chain_ = null;
            }
            break;
        }
        mngr = mngr->next_;
    }

    // #3
    if (mngr == null)    vir_release_pages();
}
```

- 注释 1：复用格式化链表的释放接口
- 注释 2：如果经上一步释放后，格式化链表全部元素都已释放（管理信息记录的容量和链表当前长度相等），则整个 `4KB` 的格式化链表也可以释放
- 注释 3：如果要释放的内存地址不在桶的链表中出现，则表示这是大于 1024B 的内存空间，这种类型的空间都是按一个 `4KB` 页来分配的，所以释放的时候也当成一个 `4KB` 页来释放

# 小结

对于物理内存管理模块，需要实现两类型接口：

- 分配：[`void *phy_alloc_page()`](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/mem/pm.c#L37)
- 释放：[`void phy_release_page()`](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/mem/pm.c#L52)

对于页表机制，需要实现：

- 创建映射：[`void set_mapping()`](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/mem/pm.c#L83)

对于虚拟内存管理模块，也是两类接口：

- 分配
	- 管理结构：[`void *vir_alloc_kern()`](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/mem/vm_kern.c#L34)
	- 非管理结构：[`void *vir_alloc_pages()`](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/mem/vm.c#L42)
- 释放
	- 管理结构：[`void vir_release_kern()`](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/mem/vm_kern.c#L49)
	- 非管理结构：[`void vir_release_pages()`](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/mem/vm.c#L98)

对于动态内存管理模块，也是两类接口：

- 分配：[`void *dyn_alloc()`](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/dyn/dynamic.c#L13)
- 释放：[`void dyn_free()`](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/dyn/dynamic.c#L52)

---
title: 「从零到一」中断机制
date: 2025-02-01 10:40:17
excerpt: x86 内核中断机制由硬件部分 PIC 与软件部分中断向量表（IDT）的组织组成。前者用来作出中断信号的决策，后者负责解释中断信息。IDT 包含 256 个条目，0-31 号向量保留给处理器异常（如页故障、除零错误）等，32-255 用于外设中断
categories: KERNEL
tag: hoo
---

# 中断机制

- 处理器会在固定的指令周期内检测是否有中断号，之后用这个中断号索引，在 [IDT](https://wiki.osdev.org/Interrupt_Descriptor_Table) 中找到对应的中断描述符 —— 里面保存着 [中断例程 ISR](https://wiki.osdev.org/Interrupt_Service_Routines) 的段选择子
- 处理器用该段选择子从 GDT 中取得对应的段描述符 —— 里面保存了 ISR 的段基址等属性信息，然后进行特权级检查 *（由处理器负责，不用担心）*
- 通过特权级后，处理器会保护现场（利用内核栈来保护），然后跳转至 ISR
- ISR 执行完毕后通过 `iret` / `iretd` 指令恢复原线程执行流

内核的任务是实现 ISR，在 [IDTR](https://wiki.osdev.org/Interrupt_Descriptor_Table#IDTR) 上填入一个 IDT 的地址，IDT 的组织（本质上是个数组）也是由内核来负责

另一个值得一提的是中断压栈，借用 [《操作系统真象还原，郑钢，7.4.2 章节》](https://book.douban.com/subject/26745156/) 的示意图：

![](https://pic1.imgdb.cn/item/679d9250d0e0a243d4f960a1.png)

上述两个示意图只会发生一个。当中断信号到达处理器，则处理器自动将上面这些寄存器环境压栈。一个线程至多拥有两个栈（`hoo` 只涉及两个 [特权级](http://wiki.osdev.org/Security#Rings)，`ring0` 对应内核态，`ring3` 对应用户态），左图的场景是中断前 `ring3`，中断后陷入 `ring0`；右图场景是中断前后均为 `ring0`

举一个具体的例子，当用户在 `shell` 输入一个字符，即在键盘按下了一个键。则处理器会收到一个中断信号，中断之前执行流是 `shell` 进程，即 `ring3`，中断时陷入内核态 ISR，需要切换为 `ring0`。此时属于左图的场景，`shell` 进程使用的 `ring3` 栈是不会被带入到 ISR 的执行时的，陷入内核态时会从 [TSS](http://wiki.osdev.org/Task_State_Segment#Protected_Mode) 中取出 `ring0` 栈，最后处理器会自动将上述寄存器环境保存到 `ring0` 栈

至于右图的场景，比如执行内核任务时，时间片耗尽。中断前是内核态，中断时跳转 ISR 依然是内核态。之前使用的栈就是 `ring0` 栈，则跳转 ISR 后依然使用原来的栈，不涉及栈的切换，处理器依然会压栈寄存器环境，只是不会压栈旧 `%ss` 和 `%esp`

上述寄存器环境有一个信息叫做 ["错误码"](http://wiki.osdev.org/Exceptions)，它是一些有关该中断信号的额外信息，比如缺页异常处理器会压栈错误码，这个时候的错误码是 [PDE / PTE 标识位的组合](http://wiki.osdev.org/Exceptions#Error_code)，`hoo` 通过这个错误码实现了 [缺页异常的 COW](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/intr/routine.c#L69)

## 实现

![](https://pic1.imgdb.cn/item/679d9e9bd0e0a243d4f96aac.png)

如图所示，`hoo` 将 IDT 数组元素视为一个函数地址，这个函数地址就是 ISR 入口。执行流到达 ISR 入口后，结合中断向量会计算得到 ISR 数组的索引，最后跳入 ISR 数组。ISR 数组元素也是一个函数地址

第一步处理器访问 IDT 数组，具体代码详见 [kern/intr/isr.S](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/intr/isr.S#L277)，以下是关键代码片段：

```assembly
# 宏定义
.macro ISRNOERR id
isr_part1_\id:
    pushl $0
    pushl $\id
    jmp   isr_part2
.endm

.macro ISRERR id
isr_part1_\id:
    pushl $\id
    jmp   isr_part2
.endm

# IDT 数组元素
ISRNOERR 0
ISRNOERR 1
# ...

# IDT 数组
isr_part1:
    .long isr_part1_0,  isr_part1_1,  isr_part1_2
    # ...
```

借助 [x86 AT&T 风格汇编宏定义](https://wiki.osdev.org/Opcode_syntax#Important_Details)，为 IDT 数组定义函数，这是因为有些中断处理器会入栈错误码，另一些没有错误码的中断就需要手动入栈一个 0 来保持栈格式的统一，方便后面保护现场、恢复现场的操作

第二步定义 ISR 入口，详见 [kern/intr/trampoline.S](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/intr/trampoline.S#L8)：

```assembly
# ISR 入口
isr_part2:
    # 保护上下文
    pushl %ds
    pushl %es
    pushl %fs
    pushl %gs
    pushal

    # 跳转 ISR
    movl $(2 * 8), %eax
    movl %eax,     %ds
    movl %eax,     %es
    movl 48(%esp), %eax
    call *__isr(, %eax, 4)

    # 恢复上下文
    popal
    popl %gs
    popl %fs
    popl %es
    popl %ds
    addl $8, %esp
    iret
```

逻辑分三段，保护和恢复上下文比较直白，主要看跳转 ISR 的逻辑：

```assembly
    movl $(2 * 8), %eax
    movl %eax,     %ds
    movl %eax,     %es
```

第一个指令是取下标为 2 的 [gdt](https://wiki.osdev.org/GDT_Tutorial)，`hoo` 设置的 gdt 的设置详见 [kern/module/conf.c](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/module/conf.c#L11)：

```c
// #0 空表
// #1 内核代码段
// #2 内核数据段
// #3 用户代码段
// #4 用户数据段
// #5 TSS 段
```

所以这里是将内核数据段加载到段寄存器 `%ds` 和 `%es`

另外的指令：

```assembly
    movl 48(%esp), %eax
    call *__isr(, %eax, 4)
```

看指令是从栈上面取出偏移 48 字节的栈元素，再经过进一步计算得到 ISR 数组的索引，最后跳入该 ISR 元素指向的地址。下面是这个 48 字节的由来：

![](https://pic1.imgdb.cn/item/679f270ad0e0a243d4f98cfb.png)

- 最开始的时候，处理器刚接收到中断信号，会自动压栈橙色部分的寄存器环境
- 之后处理器通过 IDTR 找到 IDT 数组，再找到 IDT 元素，即访问到前面汇编宏定义的内容，压栈黄色部分（橙色和黄色部分 `hoo` 定义为处理器中断栈，见 [kern/intr/intr_stack.h](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/intr/intr_stack.h#L30)）
- 后续执行流便进入 ISR 入口，压栈绿色部分的寄存器环境（绿色部分 `hoo` 定义为内核中断栈，见 [kern/intr/intr_stack.h](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/intr/intr_stack.h#L11)），最后栈顶停留在图示位置。因此栈顶偏移 48 字节即越过了整个绿色部分，访问到黄色部分的 *中断向量号*。而 ISR 数组的定义见 [kern/module/do_intr.c](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/module/do_intr.c#L9)，是一个函数指针数组，对于 `32-bit` 系统，一个指针字是 4 字节，因此中断向量号乘上 4 就是 ISR 数组索引

整个中断执行流至此完毕，具体的 ISR 会放在「内置命令」一文，现在只提供一个默认的 ISR 赋值给所有的 ISR 数组元素，默认 ISR 定义详见 [kern/intr/routine.c](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/intr/routine.c#L51)，主要是输出 ISR 名称、输出上下文环境、执行 `hlt` 命令停机。赋值逻辑详见 [kern/module/do_intr.c](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/module/do_intr.c#L16)：

```c
#define IDT_ENTRIES_NUM     256

// 特权级枚举值
typedef enum privilege_level {
    PL_KERN = 0,
    PL_USER = 3
} privilege_t;

// 门描述符类型枚举值
typedef enum gate_descriptor {
    INTER_GATE = 0x0e,
    TRAP_GATE = 0x0f
} gatedesc_t;

// 函数别名
typedef void (*isr_t)(void);

// 赋值 ISR 数组
for (uint32_t i = 0; i < IDT_ENTRIES_NUM; ++i)
	set_isr_entry(&__isr[i], (isr_t)isr_default);

// 赋值 IDT 数组
for (uint32_t i = 0; i < IDT_ENTRIES_NUM; ++i)
	set_idt_entry(&__idt[i], PL_KERN, INTER_GATE, (uint32_t)isr_part1[i]);
```

`hoo` 提供了两个接口 [`set_isr_entry()`](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/intr/intr.c#L34) 和 [`set_idt_entry()`](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/intr/intr.c#L14) 用来设置 ISR 数组和 IDT 数组，前者直接就是给 ISR 数组赋值；后者由于 IDT 表项有 [格式](https://wiki.osdev.org/Interrupt_Descriptor_Table#Gate_Descriptor)，所以需要额外提供 `PL_KERN`、`INTER_GATE` 等属性，但本质也是给 IDT 数组赋值

```c
static idtr_t __idtr;

__idtr.limit_ = sizeof(__idt) - 1;
__idtr.base_ = (uint32_t)__idt;
idtr_t idtr_value;
__asm__  volatile ("lidt %k1\n\t"
	               "sidt %0" : "=m"(idtr_value) : "m"(__idtr));
```

最后执行 `lidt` 将内存中的 `__idtr` 结构体加载到 IDTR，完成

# 常见 ISR

## 缺页异常

[缺页异常](https://wiki.osdev.org/Exceptions#Page_Fault) 是现代操作系统中很常见的一个异常类型

很多场景都会触发缺页异常，这里主要考虑当访问不在内存的 PDE 或 PTE 的场景，此时 `%cr2` 会保存缺页的线性地址，同时中断错误码会保存 paging-structure 表项的属性位，这些属性位用来标识触发缺页的场景

![](https://pic1.imgdb.cn/item/67a2eb5bd0e0a243d4fbe24f.png)

比如，当错误码是 1 时，对应着 PTE 或 PDE 的表项，可以发现 `bit-0` 都是 `P` 属性位，此时对应的场景是访问 paging-structure 时发现不在内存，可以借此实现换入换出机制（swapping）；当错误码是 2 时，对应着 `R/W` 属性位，此时对应的场景是当前线程对目标页没有写入权限，可以借此实现 [写时复制，COW（Copy on Write）](https://en.wikipedia.org/wiki/Copy-on-write)

`hoo` 没有实现换入换出，而实现了 C.O.W。C.O.W 的场景是，子进程通过 `fork()` 系统调用克隆了父进程，此时子进程所有页表也都是指向和父进程一样的物理页的。不同的是子进程共享的物理页不设置 `R/W` 属性位，当子进程写入物理页时，才进行 C.O.W

关于写操作触发 page fault 还有两个概念需要补充，详见 [《IA32 Architectures Software Developer's Manual, Volume 3A》，Sections 4.6.1 访问地址的规则](https://www.intel.com/content/dam/www/public/us/en/documents/manuals/64-ia-32-architectures-software-developer-vol-3a-part-1-manual.pdf)：

- 访问模式
	- supervisor-mode access：发起访问的 CPL < 3，即内核态线程访问一个线性地址
	- user-mode access：发起访问的 CPL = 3，即用户态线程访问一个线性地址
- 线性地址模式
	- supervisor-mode address：`U/S` 属性位至少在一个 paging-structure entry 上（PTE 或 PDE）是 0
	- user-mode address：`U/S` 属性位在所有 paging-structure entry 上都是 1

写入一个线性地址会让处理器抛出 page fault 的情景是：用户态线程访问 user-mode 线性地址，即 CPL 为 3 的线程访问 paging-structure entry 都是 1 的线性地址

具体实现详见 [kern/intr/routine.c](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/intr/routine.c#L69)，下面代码片段有删减：

```c
#define PGFLAG_PS  1
#define PGFLAG_RW  2
#define PGFLAG_US  4

// C.O.W
if ((err & PGFLAG_RW) == PGFLAG_RW) {
	pcb_t *pcb = get_current_pcb();
	pgelem_t flags = PGFLAG_US | PGFLAG_RW | PGFLAG_PS;

	void *linear_addr_pa = phy_alloc_page();
	void *temp_va = vir_alloc_pages();
	set_mapping(temp_va, linear_addr_pa, flags);
	memmove(temp_va, linear_addr, PGSIZE);
	vir_release_pages();

	pgelem_t *pte = (pgelem_t *)GET_PTE(linear_addr);
	(*pte) = (pgelem_t)linear_addr_pa | flags;
}
```

- 这里 `err` 变量是中断错误码，一个 32 位无符号整型值，从 `ring0` 栈中取出（从栈中偏移多少字节取出这里不关心）。然后去判断属性位是否设置了 `R/W` 位，是说明需要为当前线程分配一个新页，将缺失页上面的数据拷贝过去
- 分配新页的流程是，分配新的物理页，从自己的堆空间中分配新的线性地址，建立映射。然后将缺失页的线性地址上的数据，拷贝到新分配的线性地址。最后，释放这个新线性地址回去堆空间，因为当前线程最后依然会使用缺失页的线性地址
- 最后将新分配的物理地址写入页表对应 PTE

```c
// 设置 %cr0.WP
__asm__ ("movl %%cr0,  %%eax\r\n"
	"orl $0x00010000,  %%eax\r\n"
	"movl %%eax,       %%cr0" ::);
```

还有一点要注意的是，`R/W` 属性会受到 `%cr0` 的影响，详见 [《IA32 Architectures Software Developer's Manual, Volume 3A》，Sections 2.5 控制寄存器组](https://www.intel.com/content/dam/www/public/us/en/documents/manuals/64-ia-32-architectures-software-developer-vol-3a-part-1-manual.pdf)，以下是一些精简的说明：

- CR0.WP（Write Protect）：
	- 置位：阻止内核态线程写入一个只读的物理页
	- 清位：允许上述情况

```c
void
page_fault(void) {
    void *linear_addr = 0;
    __asm__ ("movl %%cr2, %0": "=a"(linear_addr) ::);

    // 从 ring0 栈偏移 60 字节处取出错误码（为什么是 60 字节，取决于每个内核
    //     定义的中断栈是怎样的，hoo 的实现是偏移 60 字节处保存的错误码）
    uint32_t err = 0;
    __asm__ ("movl 60(%%ebp), %0": "=a"(err) ::);

    // COW
}

#define ISR14_PAGEFAULT 14
set_isr_entry(&__isr[ISR14_PAGEFAULT], (isr_t)page_fault);
```

最后将 C.O.W 放到缺页异常 ISR 逻辑里面，并通过 `set_isr_entry()` 接口注册 ISR

## 时间片中断

时间片中断会涉及「调度机制」一章实现的 [调度器](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/sched/tasks.c#L161)，可以先把它当成黑盒，详见 [kern/intr/routine.c](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/intr/routine.c#L103)：

```c
// 时间片中断
void
timer(void) {
    scheduler();
}

#define ISR32_TIMER 32
set_isr_entry(&__isr[ISR32_TIMER], (isr_t)timer);
```

最后通过 `set_isr_entry()` 接口注册 ISR

## 系统调用

由于发起系统调用的整个执行流有一些前置内容，所以具体内容放到「内置命令」一文，这里先把系统调用的函数接口视为一个黑盒

```c
extern void syscall(void);

#define ISR128_SYSCALL 128
set_isr_entry(&__isr[ISR128_SYSCALL], (isr_t)syscall);
```

最后通过 `set_isr_entry()` 接口注册 ISR

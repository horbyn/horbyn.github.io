---
title: 「从零到一」内置命令
date: 2025-02-10 11:26:41
excerpt: 内置命令是整个系统的集大成者，它的实现要基于其他内核模块基础之上。内置命令本质上是磁盘上的一个二进制文件，通过系统调用一步步从磁盘加载到内存上，并最终执行流跳转到对应的内存地址开始执行
categories: KERNEL
tag: hoo
---

# 系统调用机制

系统调用也是通过中断机制发起的，和 `Linux` 一样，`hoo` 也是通过 [`int`](https://en.wikipedia.org/wiki/INT_(x86_instruction)) 指令发起的，也同样使用了中断向量号 80 作为系统调用。`int` 指令会主动发出中断信号，因此被称为软件中断

和硬件中断实现的 ISR 不同，软件中断实现的系统调用主要有两方面不同：

- 系统调用既可以由用户线程，也可以由内核线程发起，因此特权级是 `ring3`
- 系统调用可以嵌套发起，意味着系统调用过程中不能关中断

基于这两点，`hoo` 对于系统调用做了以下基础工作，详见 [kern/module/do_intr.c](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/module/do_intr.c#L28)：

```c
#define IDT_ENTRIES_NUM   256
#define PL_KERN           0
#define PL_USER           3
#define ISR128_SYSCALL    128
#define INTER_GATE        0x0e
#define TRAP_GATE         0x0f

set_isr_entry(&__isr[ISR128_SYSCALL], (isr_t)syscall);                      // 1

for (uint32_t i = 0; i < IDT_ENTRIES_NUM; ++i)
    set_idt_entry(&__idt[i], PL_KERN, INTER_GATE, (uint32_t)isr_part1[i]);  // 2
set_idt_entry(&__idt[ISR128_SYSCALL], PL_USER, TRAP_GATE,
    (uint32_t)isr_part1[ISR128_SYSCALL]);                                   // 3
```

- 注释 1：将 128 号 ISR 设置为 `syscall()`，其定义详见后文，这里先忽略，只需要知道 `syscall()` 用来将执行流改变为内核的功能函数就行了
- 注释 2：设置中断向量表，将中断向量号 0-255 ISR 设置为 `isr_part1` 数组中对应的函数，特权级为 `ring0`
- 注释 3：修改 128 号 ISR 属性为 `ring3` 和 [trap gate](https://wiki.osdev.org/Interrupt_Descriptor_Table#Trap_Gate)，和 interrupt gate 的区别是，trap gate 在执行期间是开中断的

现在，当程序执行 `int $0x80` 指令时：

- 通过 IDTR 找到 IDT 数组，进而找到 IDT[128]，然后进入 ISR 入口函数
- 在 ISR 入口函数中保护现场，跳入 `syscall()`
- 在 `syscall()` 执行完毕后，再恢复现场，最后返回

在真正跳入 `syscall()` 之前，还有很重要的一件事 —— 如何将 `ring3` 环境迁移到 `ring0` 环境？具体来说，在 `ring3` 发起了系统调用，需要传参，这些参数是怎样一步步传递到 `ring0` 的内核功能函数的？

[系统调用传参](https://wiki.osdev.org/System_Calls#Passing_Arguments) 不外乎有三种：寄存器组、栈帧和内存。`Linux` 做法是使用寄存器组，而 `hoo` 的实现采用不同的做法，全部通过栈帧来传参，具体流程如下：

![](https://pic1.imgdb.cn/item/67aae605d0e0a243d4fe46e0.png)

在 `ring3` 陷入内核态之前，在使用着 `rin3` 栈的时候，先将 `ring3` 栈帧的栈顶和栈底记录到上下文。当切换到内核态的时候，此时已经使用着 `ring0` 栈，通过上下文将整个 `ring3` 栈帧拷贝到当前的 `ring0` 栈上。这样，`ring0` 栈就拥有了用户态传参的信息，当执行流跳转到内核功能函数时，从处理器视角来看，就像是直接从一个函数调用另一个函数一样

当 `ring0` 的栈帧准备好了，执行流就进入 `syscall()` 函数，该函数会根据 `eax` 寄存器的值（系统调用号），跳转到对应的内核功能函数，像 `Linux` 的 `read()`、`write()` 等。这些内核功能函数会根据栈帧中的参数，执行相应的功能，最后返回

`hoo` 的实现详见如下，系统调用用户侧详见 [user/user.h](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/user/user.h#L7)，以下代码片段有删减：

```c
// 以打开文件为例
int
sys_open(const char *filename) {
    int fd = -1;
    syscall_entry(SYS_OPEN, &fd);
    return fd;
}

// 系统调用号
#define SYS_OPEN  2

// 系统调用入口
static void
syscall_entry(int syscall_number, void *retval) {
    __asm__ ("pushal\n\t"
        "movl (%%ebp),        %%ebx\n\t"
        "addl $0x8,           %%ebx\n\t"
        "movl (%%ebp),        %%ecx\n\t"
        "movl (%%ecx),        %%ecx\n\t"
        "int $0x80\n\t"
        "popal\n\t"
        "popl %%ebp\n\t"
        "ret" : : "d"(retval), "a"(syscall_number));
}
```

假设用户线程通过 `sys_open()` 发起系统调用，则后续会进入 `syscall_entry()`，这个过程中整个 `ring3` 栈如下图所示：

![](https://pic1.imgdb.cn/item/67c67b6bd0e0a243d40b3406.png)

黄色部分是 `sys_open()` 栈帧的调用约定，绿色部分是 `sys_open()` 栈帧，白色部分是 `syscall_entry()` 栈帧，而当前执行流停留在 `syscall_entry()` 栈帧上

这里有两个栈帧，发起系统调用时的栈帧是 `sys_open()` 栈帧（后文简称为用户栈帧），也即是后面要拷贝到 `ring0` 栈的是它。从示意图可以清楚看出，栈底往高地址偏移 8 字节就是用户栈帧的栈顶；而通过对 `%ebp` 的寄存器间接寻址即可取出用户栈帧的栈底

`syscall_entry()` 就是做了这样一件事情：

- `%eax` 保存了系统调用号
- `%ebx` 保存了用户栈帧的栈顶
- `%ecx` 保存了用户栈帧的栈底
- `%edx` 保存了系统调用返回值的地址

就这样在设置完上下文之后，通过 `int $0x80` 指令进入 `ring0`，完成了从用户态到内核态的切换。后面经过中断机制的一系列流程，现在会进入注册在 IDT 128 号元素的 `syscall()`

`hoo` 系统调用的内核侧实现详见 [kern/syscall/syscall_impl.S](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/syscall/syscall_impl.S#L7)：

```assembly
syscall:

    # 1
    movl 0x20(%ebp), %eax
    movl 0x18(%ebp), %ebx

    # 2
    movl %eax,       %ecx
    subl %ebx,       %ecx
    addl $4,         %ecx
    movl %ecx,       %edx

    movl %ebx,       %esi
    subl %ecx,       %esp
    movl %esp,       %edi
    rep movsb

    # 3
    movl 0x24(%ebp), %eax
    call *__stub(, %eax, 4)

    # 4
    movl 0x1c(%ebp), %ecx
    cmpl $0,         %ecx
    jz syscall_exit
    movl %eax,       (%ecx)

syscall_exit:
    popl %ebp
    ret
```

依然是结合栈帧来看，需要注意的是 `ring3` 上下文经中断机制后便保存到 `ring0` 栈了，而中断机制在进入 ISR 之前最后一条指令是 [`pusha`](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/intr/trampoline.S#L13)，所以进入 `syscall()` 时的栈帧如下：

![](https://pic1.imgdb.cn/item/67ab0ed1d0e0a243d4fe5305.png)

- 注释 1：获取用户栈帧。`0x20(%ebp)` 和 `0x18(%ebp)` 分别对应用户态上下文的 `%ecx` 和 `%ebx`，即对应用户栈帧的栈底和栈顶。这些信息保存到 `ring0` 上下文的 `%eax` 和 `%ebx` 中
- 注释 2：借助 `movsb` 将用户栈帧拷贝到 `ring0` 栈
- 注释 3：以系统调用号作为数组索引，调用内核功能函数（[`__stub`](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/syscall/syscall.c#L13) 是一个函数指针数组）
- 注释 4：内核功能函数返回后，根据指针决定是否需要设置 `%eax` 返回值

至此整个系统调用流程结束，系统调用返回用户态也是借助中断机制完成

# 系统调用

下表所示分别是 16 个用户侧系统调用，以及与其对应的内核侧功能函数，和上一章的展示一样，用户侧只是准备好了环境，实际完成功能的是背后的内核功能函数

可能有一些功能不应该放到系统调用中，比如格式化输出，更应该是平台标准库来做。但如果格式化输出作为一个内核功能，那么当内核自己来调用时反而更高效，只是当用户程序调用时性能会变得很差。但 `hoo` 作为一个的 toy kernel，没有生态可言，自然不会出现大量用户程序，因此就归类为系统调用了

系统调用号|用户侧系统调用|功能|内核功能函数
-|-|-|-
0|[`sys_create()`](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/user/user.c#L30)|创建文件|[`files_create()`](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/fs/files.c#L63)
1|[`sys_remove()`](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/user/user.c#L46)|删除文件|[`files_remove()`](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/fs/files.c#L107)
2|[`sys_open()`](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/user/user.c#L59)|打开文件|[`files_open()`](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/fs/files.c#L132)
3|[`sys_close()`](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/user/user.c#L71)|关闭文件|[`files_close()`](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/fs/files.c#L158)
4|[`sys_read()`](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/user/user.c#L83)|读取文件|[`files_read()`](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/fs/files.c#L178)
5|[`sys_write()`](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/user/user.c#L95)|写入文件|[`files_write()`](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/fs/files.c#L220)
6|[`sys_printf()`](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/user/user.c#L105)|格式化输出|[`kprintf()`](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/module/io.c#L22)
7|[`sys_fork()`](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/user/user.c#L115)|克隆进程|[`fork()`](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/sched/tasks.c#L251)
8|[`sys_wait()`](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/user/user.c#L132)|父进程等待子进程终止|[`wait_child()`](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/sched/tasks.c#L323)
9|[`sys_exit()`](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/user/user.c#L148)|退出|[`exit()`](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/sched/tasks.c#L334)
10|[`sys_cd()`](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/user/user.c#L163)|切换目录|[`dir_change()`](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/fs/dir.c#L422)
11|[`sys_exec()`](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/user/user.c#L175)|切换执行流|[`exec()`](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/fs/exec.c#L16)
12|[`sys_ls()`](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/user/user.c#L188)|输出目录列表|[`files_list()`](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/fs/files.c#L287)
13|[`sys_alloc()`](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/user/user.c#L201)|动态分配内存|[`dyn_alloc()`](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/dyn/dynamic.c#L13)
14|[`sys_free()`](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/user/user.c#L213)|释放动态分配的内存|[`dyn_free()`](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/dyn/dynamic.c#L52)
15|[`sys_workingdir()`](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/user/user.c#L227)|获取当前目录|[`dir_get_current()`](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/fs/dir.c#L492)

上表细节详见 [kern/syscall/syscall.c](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/syscall/syscall.c#L18)，其中，`#0` 至 `#5` 和 `#13` 至 `#14` 已经出现在「[文件系统](https://horbyn.github.io/2025/02/07/hoo-7/)」和「[内存管理](https://horbyn.github.io/2025/01/30/hoo-3/)」一文，后文将略过

## 格式化输出

用户侧和前文例子一样，只是准备上下文环境，然后借助 `syscall_entry()` 陷入内核态，进而调用内核功能函数

```c
#define SYS_PRINTF  6

void
sys_printf(const char *format, ...) {
    syscall_entry(SYS_PRINTF, 0);
}
```

格式化输出相关内容参考 [GNU 可变参数宏](https://www.gnu.org/software/libc/manual/html_node/How-Variadic.html) 等资料，主要是 `va_list`、`va_start()`、`va_arg()`、`va_end()` 等宏函数的使用

`hoo` 实现了一个格式化模块，详见 [kern/utilities/format.{h,c}](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/utilities/format.h#L13)，这里将不跳入具体的细节了：

```c
typedef char *va_list;
#define POINTER_SIZE                (sizeof(const char *))
#define TYPE_TO_POINTER_SIZE(type)  ((sizeof(type) - 1) / POINTER_SIZE + 1)
#define VA_START(a,fst)             ((a) = (((va_list)&(fst))))
#define VA_ARG(a,type)              \
    ((a) = (a) + (sizeof(va_list) * TYPE_TO_POINTER_SIZE(type)))
#define VA_END(a)                   ((a) = (va_list)0)

void format(const char *fmt, va_list args, void *redirect);
```

核心思路是将参数转换为栈帧上的地址，`va_list` 本质上就是一个地址，所有宏函数都是在栈帧内操作给定地址，进行偏移等从而获得下一个参数。`format()` 则是 `hoo` 中最底层的格式化函数，内核功能函数会在高层调用它，其他模块（`hoo` 实现了一个日志模块，也会利用格式化功能输出日志）也会在高层调用它。函数签名中最后一个参数用来进行输出重定向，`hoo` 只实现了重定向到标准输出或者文件

借助 `format()`，格式化功能就很简单了：

```c
void
kprintf(const char *fmt, ...) {
    va_list va;
    VA_START(va, fmt); // 将 fmt 的地址赋值给 va
    format(fmt, va, (void *)FD_STDOUT);
    VA_END(va);
}
```

## fork

`fork()` 的作用是克隆进程。调用 `fork()` 的进程是父进程，新进程是子进程，子进程共享父进程整个线性空间，父进程需要等待子进程终止

`fork()` 在内核中的地位非常高。自计算机启动，一直有一个执行流，从实模式、保护模式，直至最后任务系统完成初始化 —— 任务队列开始建立，这个执行流才被最终确定下来，这是第一个进程。有了 `fork()` 之后，就可以在不影响第一个进程（拥有特权级的内核进程）的情况下创建另一个进程作为用户进程（后文的 `shell`）。如果不用 `fork()` 创建新进程而是通过将 `ring0` 进程修改为 `ring3` 进程，然后跳转至用户进程的执行流入口，这样也可以，但是系统内只会有一个进程，而且是 `ring3` 进程，当需要调用内核功能的时候，就只能通过系统调用的方式进行，增加了复杂度

`fork()` 的实现中一个很重要的目标就是去拷贝父进程的线性空间，这个线性空间具体来说就是将父进程的页目录表复制一份。这个过程是递归的，意思是从页目录表开始，每个页表的每一个物理页，都要进行拷贝

![](https://pic1.imgdb.cn/item/67ac39d4d0e0a243d4fe8aa4.png)

如图所示，拷贝发生在最后一层，最终结果是父子进程所有页表的每个 PTE，都指向同一个物理页，这就是所谓的 *"共享"*。这个过程中，唯一要注意的是 PTE 的属性位，前文「[中断机制](https://horbyn.github.io/2025/02/01/hoo-4/)」一文提及了 `hoo` 在缺页异常中实现了 C.O.W，因此子进程在拷贝 PTE 的时候需要将 `R/W` 清位

详见 [kern/sched/tasks.c](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/sched/tasks.c#L251)，以下代码片段有删减：

```c
#define PG_DIR_VA  0xfffff000 // 页目录表对应的线性地址
typedef uint32_t pgelem_t;    // paging-structure 结构

// copy_beg：高地址 0x8000_0000 对应的页目录表索引
// copy_end：页目录表最后一个索引
// new_pgdir_va：新进程（即子进程）的页目录表线性地址
// new_pgdir_pa：子进程的页目录表物理地址

// 1
for (int i = 0; i < copy_beg; ++i) {
	pgelem_t *pde = (pgelem_t *)PG_DIR_VA + i;
	if (*pde) {
		void *new_page_table = phy_alloc_page();
		pgelem_t *new_page_table_va = vir_alloc_pages();
		set_mapping(new_page_table_va, new_page_table, flags);

		// 2
		for (int j = 0; j < 4096 / sizeof(pgelem_t); ++j) {
			pgelem_t *pte = (pgelem_t *)(
				((uint32_t)pde << 10) | (j * sizeof(uint32_t)));
			if (*pte)    new_page_table_va[j] = *pte & ~((pgelem_t)PGFLAG_RW);
		}

		new_pgdir_va[i] = (pgelem_t)new_page_table | flags;
	} else    new_pgdir_va[i] = 0;
}
// 3
for (uint32_t i = copy_beg; i < copy_end; ++i)
	new_pgdir_va[i] = *((pgelem_t *)PG_DIR_VA + i);
// 4
new_pgdir_va[copy_end] = (pgelem_t)new_pgdir_pa | flags;
```

- 注释 1：拷贝父进程线性地址空间。由于父进程是调用 `fork()` 的进程，所以在 `fork()` 里面通过 `0xffff_f000` 访问的页目录表是父进程的页目录表。通过判断 PDE 是否全零来确定是否拷贝：
	- 非零：创建一个新的物理页，分配一个新的虚拟地址，建立映射
	- 全零：子进程页目录表对应的 PDE 写 0
- 注释 2：修改 PTE 属性位为只读。注意是 PDE 对应页表的全部 PTE
- 注释 3：拷贝内核线性地址空间。高地址这部分直接复制就行
- 注释 4：将子进程页目录表的物理地址填入最后一个 PDE，即索引 1023

关于 `fork()`，另一个值得一提的点是子进程的执行流从哪开始。`Linux` 平台对于创建进程一般有两个函数，`fork()` 和 `clone()`，前者子进程的执行流开始于 `fork()` 返回处，后者子进程的执行流由形参指定。`hoo` 借鉴了这种思想，希望在创建进程的时候更灵活，因此在内核功能函数的函数签名上，定义为：

```c
tid_t fork(void *entry);
```

这里形参 `entry` 就可以指定执行流起点，既可以指定为下一条指令的地址，也可以指定为某一个函数。但是由于用户侧系统调用已经固定了 `fork()` 子进程执行流为下一条指令，所以实际上形参 `entry` 并没有起太大作用，所以关于执行流起点这部分逻辑此处省略，代码详见 [kern/sched/tasks.c](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/sched/tasks.c#L300)

`hoo` 的具体实现详见 [kern/sched/tasks.c](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/sched/tasks.c#L251)，以下代码片段有删减：

```c
tid_t
fork(void *entry) {

    pgelem_t flags = PGFLAG_US | PGFLAG_RW | PGFLAG_PS;

    // 1
    void *new_pgdir_pa = phy_alloc_page();
    pgelem_t *new_pgdir_va = vir_alloc_pages();
    set_mapping(new_pgdir_va, new_pgdir_pa, flags);

    // 2
    void *new_ring0_pa = phy_alloc_page();
    void *new_ring0_va = vir_alloc_pages();
    set_mapping(new_ring0_va, new_ring0_pa, flags);

    // 3
    void *new_ring3_pa = phy_alloc_page();
    void *new_ring3_va = vir_alloc_pages();
    set_mapping(new_ring3_va, new_ring3_pa, flags);

    // 拷贝父进程线性空间...

    // 4
    tid_t new_tid = thread_tid_alloc();
    pcb_t *new_pcb = thread_pcb_get(new_tid);
    pcb_set(new_pcb/* ... 还有其他参数，此处忽略 ... */);

    // 5
    node_t *n = node_alloc();
    node_set(n, new_pcb, null);
    task_ready(n);

    return new_tid;
}
```

- 注释 1：从内核空间中创建一个页目录表。页目录表只能由内核来分配，原因是线程自己销毁自己时，仍需要使用线程自己的页目录表。待线程自己销毁结束，变成僵尸进程，然后再由内核介入，将页目录表从内核自己的线性空间中删除
- 注释 2：从内核空间中创建一个 `ring0` 栈，为什么要从内核空间创建，原因同上
- 注释 3：从内核空间中创建一个 `ring3` 栈
- 注释 4：拷贝 pcb。pcb 中除了保存像 `ring0` 栈、`ring3` 栈、页目录表等信息外，还有一些信息和父进程有关，这里需要将这些所有信息写入子进程 pcb 中
- 注释 5：将子进程 pcb 加入就绪队列的队尾

用户侧的系统调用接口如下，详见 [user/user.c](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/user/user.c#L115)：

```c
int
sys_fork(void) {
    int tid = -1;
    unsigned int bak_entry = 0;
    __asm__ ("movl 0x8(%%ebp), %0\n\t"
        "movl 0x4(%%ebp), %%eax\n\t"
        "movl %%eax, 0x8(%%ebp)"
        : "=c"(bak_entry));
    syscall_entry(SYS_FORK, &tid);
    __asm__ ("movl %0, 0x8(%%ebp)"
        : : "a"(bak_entry));
    return tid;
}
```

在进入 `syscall_entry()` 前后，多了两个内联汇编语句，原因是用户侧系统调用接口和内核侧功能函数的函数签名不一致：

```c
// 用户侧系统调用接口
int sys_fork(void);

// 内核侧功能函数接口
tid_t fork(void *entry);
```

那么在用户侧发起系统调用之前就需要重新编排 `ring3` 栈

![](https://pic1.imgdb.cn/item/67ad875dd0e0a243d4fec574.png)

所以第一个内联汇编语句，将 `%ebp` 往上偏移 8 字节取出，备份到变量 `bak_entry`。然后将 `%ebp` 往上偏移 4 字节的栈元素保存到 `%ebp` 往上偏移 8 字节处

而第二个内联汇编语句则是恢复备份

## wait

`wait()` 用于调用 `fork()` 之后的父进程等待子进程的执行结束。子进程执行期间父进程可能需要等待，父进程通过睡眠来减少对处理器的占用，子进程执行完毕再将父进程唤醒

借助前文「[设备驱动](https://horbyn.github.io/2025/02/05/hoo-6/)」一文的 `sleep()`，`wait()` 的实现非常简单，见 [kern/sched/tasks.c](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/sched/tasks.c#L323)：

```c
void
wait_child(spinlock_t *sl) {
    wait(sl);
    sleep(sl, sl);
    signal(sl);
}
```

由于睡眠需要提供一个等待就绪的资源，所以这里直接把 spinlock 视为资源

用户侧的系统调用接口如下，详见 [user/user.c](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/user/user.c#L132)：

```c
void
sys_wait() {
    unsigned int bak_spinlock = 0;
    unsigned int temp_spinlock = 0;
    __asm__ ("movl 0x8(%%ebp), %0\n\t"
        "movl %1, 0x8(%%ebp)"
        : "=a"(bak_spinlock)
        : "c"(temp_spinlock));
    syscall_entry(SYS_WAIT, 0);
    __asm__ ("movl %0, 0x8(%%ebp)"
        : : "a"(bak_spinlock));
}
```

和前面 `fork()` 一样由于用户侧、内核侧函数接口不一致，需要在用户侧额外编排 `ring3` 栈

```c
// 用户侧系统调用
void sys_wait();

// 内核侧功能函数
void wait_child(spinlock_t *sl);
```

两处内联汇编语句也是对 `%ebp` 往上偏移 8 字节处进行备份与恢复

## exit

进程通过 `exit()` 自己销毁自己，常见场景是父进程通过 `fork()` 创建了子进程，子进程完成自己任务后通过 `exit()` 终止自己，并且唤醒上一节通过 `wait()` 陷入睡眠的父进程

在这个过程中，子进程需要做到：

- 释放 pcb 中占用的资源
- 释放页目录表
- 唤醒父进程
- 将自己 pcb 加入任务销毁队列，等待后面内核进一步释放资源
- 重新调度。因为 pcb 已经从任务运行队列移动到其他队列，所以需要调度器重置任务运行队列

`hoo` 的具体实现详见 [kern/sched/tasks.c](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/sched/tasks.c#L334)，以下代码片段有删减：

```c
#define PD_INDEX(x)             (((x)>>22) & 0x3ff)
#define KERN_HIGH_MAPPING       0x80000000
#define PG_MASK                 0xfffff000
#define PG_DIR_VA               PG_MASK
typedef uint32_t                pgelem_t;
#define PG_STRUCT_SIZE          ((PGSIZE) / sizeof(pgelem_t))
#define INVALID_INDEX           (-1)
#define LSIDX_AFTAIL(list_ptr)  ((list_ptr)->size_ + 1)

void
exit() {
    pcb_t *pcb = get_current_pcb();

    // 释放 pcb 资源...（每个内核实现都有不同的资源，具体释放情况各有不同，因此这里省略）

    // 1
    for (int i = 0; i < PD_INDEX(KERN_HIGH_MAPPING); ++i) {
        pgelem_t *pde = (pgelem_t *)(PG_DIR_VA + i * sizeof(uint32_t));
        if (*pde & ~PG_MASK) {
            for (int j = 0; j < PG_STRUCT_SIZE; ++j) {
                pgelem_t *pte = (pgelem_t *)(
                    ((uint32_t)pde << 10) | (j * sizeof(uint32_t)));
                if (*pte & ~PG_MASK) {
                    phy_release_page((void *)(*pte & PG_MASK));
                    *pte = 0;
                }
            }

            phy_release_page((void *)(*pde & PG_MASK));
            *pde = 0;
        }
    }

    // 2
    if (pcb->parent_ != INVALID_INDEX) {
        pcb_t *parent_pcb = thread_pcb_get(pcb->parent_);
        if (parent_pcb->sleep_) {
            wakeup(parent_pcb->sleep_);
        }
    }

    // 3
    wait(&__sl_tasks);
    node_t *n = queue_pop(&__queue_running);
    list_insert(&__list_expired, n, LSIDX_AFTAIL(&__list_expired));
    signal(&__sl_tasks);

    // 4
    scheduler();
}
```

- 注释 1：释放页目录表所有物理页。释放范围为页目录表的索引 0 至 511（内核地址 `0x8000_0000` 对应的索引），外层循环变量 i 控制页目录表索引，内层循环变量 j 控制页表索引。如果页目录表项或页表项有效，则 `phy_release_page()` 释放对应的物理页
- 注释 2：唤醒父进程。早在 `fork()` 的时候（此时是父进程正在执行），父进程就已经将自己的线程 id 写入了新进程的 pcb 中。现在子进程退出之际，通过 pcb 找到父进程的线程 id，如果是一个有效 id，则表示父进程正在睡眠，需要调用 `wakeup()` 唤醒父进程
- 注释 3：将子进程从任务运行队列中移除，并添加到任务销毁队列中。`LSIDX_AFTAIL()` 是一个宏函数用来范围队列的最后一个元素的索引，这里将前面运行队列中出队的元素加入销毁队列的队尾
- 注释 4：重新调度。子进程退出后，不能再回到用户态，但此时任务运行队列已经没有任务，所以调用 `scheduler()` 切换其他进程执行

用户侧系统调用详见 [user/user.c](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/user/user.c#L148)：

```c
void
sys_exit() {
    syscall_entry(SYS_EXIT, 0);
}
```

## 切换目录

就是实现一个 `Linux` 的 `cd` 命令。需要注意的是相对目录和绝对目录的切换，相对目录的处理方式是获取进程所在的目录结构，转换为绝对目录

为了保存进程的目录结构，`hoo` 使用了以下结构：

![](https://pic1.imgdb.cn/item/67b06450d0e0a243d4ff9dbf.png)

每个进程都使用一个物理页来保存目录结构，而 `hoo` 一个文件名最多 16 字节，所有计算得一个进程最多可以嵌套 `4096 / 16 = 256` 个目录。对于 `/usr/boo/mytext.txt` 这个目录，分为 `/`、`usr`、`boo`、`mytext.txt` 四部分，每个部分都是目录结构中的一个字符串

目录结构定义详见 [kern/utilities/curdir.h](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/utilities/curdir.h#L18)，本质是一个字符数组指针和数组长度，除此之外还定义了两个操作接口：

```c
typedef struct current_directory {
    char     *dir_;
    uint32_t dirlen_;
} curdir_t;

int  curdir_get(const curdir_t *curdir, char *path, uint32_t pathlen);
int  curdir_set(curdir_t *curdir, const char *path);
```

操作接口会定义一个工作指针，通过每次移动 16 字节的指针长度，实现对目录结构的遍历

获取接口详见 [kern/utilities/curdir.c](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/utilities/curdir.c#L34)，以下代码片段有删减：

```c
#define PGSIZE              4096
#define DIRITEM_NAME_LEN    16
#define MAX_OPEN_DIR        (PGSIZE / (DIRITEM_NAME_LEN))

int
curdir_get(const curdir_t *curdir, char *path, uint32_t pathlen) {

    // 1
    uint32_t acc = 0;
    const char *worker = 0;
    for (int i = 0; i < MAX_OPEN_DIR; ++i) {
        // 2
        worker = curdir->dir_ + i * DIRITEM_NAME_LEN;
        if (worker[0] == 0)    break;

        uint32_t len = strlen(worker);
        if (acc + len > pathlen) {
            bzero(path, pathlen);
            return -1;
        } else {
            // 3
            memmove(path + acc, worker, len);
            acc += len;
        }
    }

    path[acc] = 0;
    return 0;
}
```

- 注释 1：变量 `acc` 是累加值，表示截至每次迭代所获取目录名的长度。因为形参提供的缓冲区有可能无法容纳所有目录名
- 注释 2：获取每次迭代的目录名
- 注释 3：如果形参给出的缓冲区长度还足够，则将目录名复制到缓冲区中

设置接口详见 [kern/utilities/curdir.c](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/utilities/curdir.c#L67)，以下代码片段有删减：

```c
#define DIRNAME_ROOT_ASCII  47 // '/' 的 ASCII 码
#define DIR_SEPARATOR       DIRNAME_ROOT_ASCII

int
curdir_set(curdir_t *curdir, const char *path) {

    char *worker = 0;
    int i = 0, j = 0;
    bzero(curdir->dir_, curdir->dirlen_);

    for (; i < MAX_OPEN_DIR; ++i) {
        if (path[j] == 0)    break;
        // 1
        worker = curdir->dir_ + i * DIRITEM_NAME_LEN;

        // 2
        for (;; ++j) {
            if (path[j] == DIR_SEPARATOR) {
                ++j;
                break;
            } else    *worker++ = path[j];
        }
        *worker++ = DIR_SEPARATOR;
        *worker = 0;
    }
    if (i == MAX_OPEN_DIR)    return -1; // 3

    return 0;
}
```

- 注释 1：获取每次迭代的目录名
- 注释 2：遍历形参给定的目录名。以 `/` 作为一个目录的分隔，每获取一个目录，就将该目录拷贝到目录结构中
- 注释 3：如果目录结构中存放的目录数达到上限，则返回失败

在完成这两个目录结构接口后，切换目录的流程如下：

- 判断目录名格式。绝对路径还是相对路径，如果是相对路径则通过目录结构接口转换为绝对路径
- 设置目录结构。通过传入一个绝对路径，调用目录结构的设置接口

`hoo` 的实现详见 [kern/fs/dir.c](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/fs/dir.c#L422)，以下代码片段有删减：

```c
#define DIRNAME_ROOT_ASCII  47 // '/' 的 ASCII 码

int
dir_change(const char *dir) {
    pcb_t *cur_pcb = get_current_pcb();
    char *abs = dyn_alloc(PGSIZE);

    if (dir[0] == DIRNAME_ROOT_ASCII) {
        // 1
        memmove(abs, dir, strlen(dir));
    } else {
        // 2
        curdir_get(cur_pcb->curdir_, abs, PGSIZE);
        memmove(abs + strlen(abs), dir, strlen(dir));
    }

    // 3
    diritem_t *cur_diritem = dyn_alloc(sizeof(diritem_t));
    if (diritem_find(abs, cur_diritem) == false) {
        dyn_free(cur_diritem);
        dyn_free(abs);
        return -1;
    }
    dyn_free(cur_diritem);

    // 4
    curdir_set(cur_pcb->curdir_, abs);
    curdir_set(thread_curdir_get(cur_pcb->parent_), abs);
    dyn_free(abs);
    return 0;
}
```

- 注释 1：处理绝对路径。如果目录名以 `/` 打头视为绝对路径，此时直接拷贝形参给定的目录名
- 注释 2：处理相对路径。先通过目录结构获取接口得到绝对路径，然后将形参追加到后面
- 注释 3：判断决定路径对应的目录是否存在
- 注释 4：更新当前进程的当前目录和父进程的当前目录。上述代码片段是通过系统调用一步步进入的，而系统调用最终会被封装为一个 `ring3` 程序，即 `cd` 命令。当用户在命令行输入 `cd` 命令时，实际上是在 `shell` 进程中执行 `cd` 命令。而 `shell` 进程的逻辑是每执行一个任务就通过 `fork()` 和 `exec()` 创建一个全新的子进程来执行。因此对于切换目录来说，仅仅修改子进程的目录结构是无意义的，必须一并修改父进程的目录结构，这样当 `shell` 进程执行完 `cd` 命令后，再执行其他命令时，才能在新的目录下执行。更多详情见后面的 `shell` 进程

用户侧系统调用接口详见 [user/user.c](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/user/user.c#L163)：

```c
int
sys_cd(const char *dir) {
    int ret = -1;
    syscall_entry(SYS_CD, &ret);
    return ret;
}
```

## 切换执行流

跳转执行流是指，从文件系统中打开一个二进制文件，然后重置当前进程的线性空间，将二进制文件加载到内存，最后跳转到二进制文件中执行

这个过程中有两个很重要的步骤，第一个是重置当前进程的线性空间，第二个是跳转到二进制文件中执行，下面是一些说明

前面「[内存管理](https://horbyn.github.io/2025/01/30/hoo-3/)」一文展示过 `hoo` 进程的线性空间：

![](https://pic1.imgdb.cn/item/67a1b668d0e0a243d4fbc4cd.png)

暂时把执行新执行流的进程称为新进程，那么新进程的二进制数据边界很可能和当前进程（现在还没开始切换）是不一样的，新进程的二进制数据边界在前一步读取二进制文件时获取。现在以新进程二进制边界为基准，在边界前面的所有 paging-structure 都要重新分派，这就是线性空间的重置过程

不用担心把当前进程的线性空间破坏了，因为程序二进制数据只会在 `ring3` 执行，现在通过系统调用陷入了内核态，执行的是高地址的 `ring0` 代码，不会影响到当前进程的执行，只需要确保当前进程不要返回原来的 `ring3` 代码即可

这一步会通过将控制流从原来 `ring3` 代码转移到新加载程序的 `ring3` 代码保证。为了执行新代码，需要先把二进制文件读取到内存中，这个内存地址就是新二进制文件的入口地址，然后通过 `jmp` 指令跳转到新二进制文件的入口地址，这样就完成了执行流的切换

遵循着上面两点核心思路，`hoo` 的实现如下，详见 [kern/fs/exec.c](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/fs/exec.c#L16)，下面代码片段有删减：

```c
#define MAX_ARGV            2
#define MAXSIZE_PATH        128
#define DIR_LOADER          "/bin/"
#define PGSIZE              4096
#define PGDOWN(x, align)    (((uint32_t)(x)) & ~((align) - 1))
#define PGUP(x, align)      (PGDOWN(((uint32_t)(x) + (align) - 1), (align)))
typedef void (*builtin_t)(void);

void
exec(const char *filename) {
    // 1
    static char param[MAXSIZE_PATH], cmd[MAXSIZE_PATH];
    uint32_t flen = strlen(filename);
    int i = 0;
    for (; i < flen; ++i) {
        if (filename[i] == ' ') {
            memmove(cmd, filename, i);
            memmove(param, filename + i + 1, flen - i - 1);
            break;
        }
    }
    if (i == flen)    memmove(cmd, filename, flen);
    static char *argv[MAX_ARGV];
    argv[0] = cmd;
    argv[1] = param;
    uint32_t argc = param[0] == 0 ? 1 : 2;

    // 2
    static char absolute_path[MAXSIZE_PATH * 2];
    if (cmd[0] != '/') {
        uint32_t size = strlen(DIR_LOADER);
        memmove(absolute_path, DIR_LOADER, size);
        memmove(absolute_path + size, cmd, flen);
    } else    memmove(absolute_path, cmd, flen);
    fd_t fd = files_open(absolute_path);
    if (fd == -1) {
        kprintf("Command: \"%s\" not found\n", absolute_path);
        exit();
    }
    uint32_t file_size = files_get_size(fd);       // 3
    uint32_t file_pages = PGUP(file_size, PGSIZE); // 3
    pcb_t *cur_pcb = get_current_pcb();
    cur_pcb->break_ = file_pages;                  // 4

    // 5
    uint32_t amount_pgdir = file_pages / MB4;
    if (file_pages % MB4)    ++amount_pgdir;
    uint32_t vaddr_program = 0;
    for (i = 0; i < amount_pgdir; ++i) {
        // 遍历页目录表，处理 PDE
        void *pgtbl_pa = phy_alloc_page();
        pgelem_t flag = PGFLAG_US | PGFLAG_RW | PGFLAG_PS;
        pgelem_t *pde = (pgelem_t *)GET_PDE(i * MB4);
        *pde = (pgelem_t)pgtbl_pa | flag;

        // 遍历页表，处理 PTE
        for (int j = 0; vaddr_program < file_pages && j < MB4;) {
            void *program_pa = phy_alloc_page();
            set_mapping((void *)vaddr_program, program_pa, flag);
            j += PGSIZE;
            vaddr_program += PGSIZE;
        }
    }

    // 6
    builtin_t program = (builtin_t)0;
    files_read(fd, program, file_size);

    // 7
    __asm__ ("movl %0, %%eax\n\t"
        "movl %2, -0x4(%%eax)\n\t"
        "movl %3, -0x8(%%eax)\n\t"
        "movl %4, -0xc(%%eax)\n\t"
        "movl $next_insc, -0x10(%%eax)\n\t"
        "subl $0x10, %%eax\n\t"
        "pushl %1\n\t"
        "pushl %%eax\n\t"
        "jmp mode_ring3\n\t"
        "next_insc:\n\t"
        "addl $0x8, %%esp\n\t"
        "movl %%esp, %%ebp\n\t"
        "call sys_close\n\t"
        "call sys_exit"
        : : "c"(cur_pcb->stack3_), "d"(program), "b"(fd), "S"(argv), "D"(argc));
}
```

- 注释 1：处理命令和参数。传入的形参 `filename` 可能是 `cd /opt/some_dir/` 这种，命令和参数通过空格来分割，将空格前面字符串保存到数组 `cmd` 而后面字符串保存到数组 `param`，最后赋值变量 `argc` 和 `argv`，`hoo` 目前最多只支持一个参数
- 注释 2：格式化文件名。传入的形参 `filename` 就是一个命令，比如 `cd`，实际上在 `hoo` 中这些命令是文件系统中的一个文件，它保存在 `/bin` 目录下。所以当执行 `cd` 命令的时候，对应的文件 `/bin/cd`，这里就是得到这个决定路径。然后通过文件系统接口 `files_open()` 打开文件
- 注释 3：获取二进制文件大小。利用文件系统接口 [`files_get_size()`](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/fs/files.c#L270)，该接口通过读取文件 inode 来确定文件大小。虽然此时获得了二进制文件的实际大小，但由于页表映射的地址是对齐 `4KB` 的，所以后续通过 `PGUP()` 进行向上对其
- 注释 4：重置当前进程的二进制数据边界
- 注释 5：重置当前进程的线性空间。前面说过重置也就是重新分配 paging-structure，具体来说就是（1）重新赋值 PDE；（2）重新赋值 PTE
    - 外循环枚举 PDE，每次为 PDE 分配一个物理页作为页表，将物理地址写入 PDE
    - 内循环枚举 PTE，每次为 PTE 预先分配一个物理页，方便后续将磁盘二进制文件读取到内存，循环条件要么到达了二进制文件实际的大小，要么到达了一个页表所表示的 `4MB` 大小就退出
- 注释 6：将二进制文件从磁盘读取到内存。通过文件系统接口 `files_read()` 将二进制文件从磁盘读取到内存 0 的位置，这个地方前一步已经重置过线性空间，映射都是全新的
- 注释 7：切换执行流。这里引入了一个从 `ring0` 进入 `ring3` 的函数 `mode_ring3()`，关于它的详情见后文，只需要知道 `x86` 从高特权级进入低特权级方法只有一个，就是中断返回，具体来说是执行 `iret` 指令。`mode_ring3()` 就是借助了这个指令，对于处理器来说它并不关心执行 `iret` 是否真的要从中断中返回，只关心执行 `iret` 时 `ring0` 和 `ring3` 栈是否正确，因此 `jmp mode_ring3` 之前的汇编指令用来设置 `ring3` 栈，而在 `mode_ring3()` 函数中设置 `ring0` 栈。至于后面的汇编指令，用来处理命令完成后的返回，注意返回时候仍然是 `ring3`，所以不能直接调用内核功能函数，只能通过系统调用接口。这里命令执行返回后需要关闭文件、需要执行 `exit()` 来销毁自己

下面来详细看下内联汇编指令的整个过程：

```assembly
__asm__ ("movl %0, %%eax\n\t"
    "movl %2, -0x4(%%eax)\n\t"
    "movl %3, -0x8(%%eax)\n\t"
    "movl %4, -0xc(%%eax)\n\t"
    "movl $next_insc, -0x10(%%eax)\n\t"
    "subl $0x10, %%eax\n\t"
    : : "c"(cur_pcb->stack3_), "d"(program), "b"(fd), "S"(argv), "D"(argc));
```

变量 `cur_pcb->stack3_` 表示 `ring3` 栈的栈顶，被赋值给 `%eax` 寄存器，然后变量 `fd` 写入 `ring3` 栈的栈顶（往下偏移 4 字节），后面每次偏移 4 字节同理，逻辑上相当于 `ring3` 栈入栈，因此是依次入栈变量 `argv`、`argc`，最后调整栈顶

![](https://pic1.imgdb.cn/item/67b1a38fd0e0a243d4ffcaa2.png)

那么现在的 `ring3` 栈就如左图所示，相信有读者已经发现了这个栈格式遵循着 `x86` 调用约定，如右图。当刚执行 `int main(int argc, char **argv)` 时，栈顶是返回地址，栈顶往上是两个参数。根据这个格式可以得出，新执行流使用 `argc` 和 `argv` 两个参数；并且执行流结束之后是可以返回的，返回地址就是汇编标号 `next_insc` 处

```assembly
__asm__ ("..."
    "pushl %1\n\t"
    "pushl %%eax\n\t"
    "jmp mode_ring3\n\t"
    "next_insc:\n\t"
    : : "c"(cur_pcb->stack3_), "d"(program), ...);
```

前面说过 `mode_ring3()` 借助 `iret` 进入 `ring3`，本质上需要特殊设置 `ring0` 栈的布局，但 `mode_ring3()` 还需要一些额外信息，需要知道 `ring3` 栈在哪里、`ring3` 函数入口在哪里。所以两条入栈指令将变量 `program`（二进制文件的内存地址）和 `%eax`（根据前面的汇编指令可知，`%eax` 是 `ring3` 栈）记录在 `ring0` 栈中，然后才跳入 `mode_ring3()`。汇编标号 `next_insc` 是 `mode_ring3()` 的下一条指令，控制 `ring3` 执行流的返回

下面结合流程图来看下 `mode_ring3()` 的详情，它位于 [kern/sched/switch.S](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/sched/switch.S#L46)：

```assembly
mode_ring3:
    pushl %ebp
    movl %esp,           %ebp

    # 1
    movl $((4 * 8) | 3), %eax
    movl %eax,           %ds
    movl %eax,           %es
    movl %eax,           %fs
    movl %eax,           %gs

    # 2
    movl 0x4(%ebp),      %eax   # 取出 ring3 栈
    pushl $((4 * 8) | 3)        # 取出 ss
    pushl %eax                  # 入栈 ring3 栈
    pushf                       # 入栈 eflags
    orl $0x200,          %ss:(%esp)
    pushl $((3 * 8) | 3)        # 入栈 cs
    movl 0x8(%ebp),      %eax
    pushl %eax                  # 入栈 eip

    # 3
    xorl %eax,           %eax
    xorl %ebx,           %ebx
    xorl %ecx,           %ecx
    xorl %edx,           %edx
    xorl %esi,           %esi
    xorl %edi,           %edi
    movl 0x4(%ebp),      %ebp

    iret
```

左图是进入 `mode_ring3()` 之前的 `ring0` 栈，入栈了二进制地址和 `ring3` 栈栈顶，右图展示了 `mode_ring3()` 执行后的 `ring0` 栈

![](https://pic1.imgdb.cn/item/67b1b5bfd0e0a243d4ffd18b.png)

- 注释 1：重置数据段。`$((4 * 8) | 3)` 表示的是用户态使用的数据段（[`hoo` 设置的 GDT 数组](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/module/conf.c#L11)下标 4 表示用户态数据段）
- 注释 2：伪造 `ring0` 栈。结合右图可知 `0x4(%ebp)` 是 `ring3` 栈，`0x8(%ebp)` 是 `ring3` 返回地址，而 `$((3 * 8) | 3)` 和前一点一样，是 GDT 下标 3 表示用户态代码段。总的来看就是依次入栈 `%ss`、`%esp`、`%eflags`、`%cs`、`%eip`，这样 `iret` 才能正确执行
- 注释 3：重置上下文。在进入一个新的执行流之前，把所有寄存器都重置，而 `%ebp` 设置为和 `ring3` 栈顶一样，表示新执行流开始时 `%esp` 和 `%ebp` 都指向同一个地方，即 `ring3` 栈顶

当 `ring3` 执行流返回时，依然是 `ring3` 权限，下图展示了这个过程中 `ring3` 栈的变化：

![](https://pic1.imgdb.cn/item/67b1ba41d0e0a243d4ffd29d.png)

- 左图：刚返回时，前一步 "调用了" `mode_ring3()` 的环境还没清楚，执行 `addl $0x8, %esp` 清除两个 "参数"
- 中图：下一步是发起 `sys_close()` 系统调用，需要一个参数，文件描述符来告诉内核关闭哪个文件，所以这里的 `fd` 相当于调用 `sys_close()` 时入栈的参数
- 右图：刚进入 `sys_close()` 执行完调用约定后的栈格式

```c
__asm__ ("..."
        "addl $0x8, %%esp\n\t"
        "movl %%esp, %%ebp\n\t"
        "call sys_close\n\t"    // 1
        "call sys_exit"         // 2
        ...);
```

- 注释 1：关闭文件
- 注释 2：退出进程

退出当前进程后，`hoo` 会通过调度器选择下一个就绪进程来执行，至此便结束了整个新的执行流

用户侧系统调用接口详见 [user/user.c](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/user/user.c#L175)：

```c
void
sys_exec(const char *program) {
    syscall_entry(SYS_EXEC, 0);
}
```

## 输出目录列表

就是实现一个 `Linux` 的 `ls` 命令，同样也要注意绝对目录和相对目录的问题

`ls` 命令的需求：

- 给定一个文件：输出文件大小和文件的绝对路径名字，比如 `32B    /opt/file.txt`
- 给定一个目录：输出目录里面的内容，比如 `/bin` 目录下面有两个二进制文件和一个子目录，会输出 `ls    cd    subdir/`。其中，目录以 `/` 结尾，文件则什么后缀都没有

`hoo` 的实现详见 [kern/fs/files.c](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/fs/files.c#L287)，以下代码片段有删减：

```c
#define DIRNAME_ROOT_ASCII  47  // '/' 的 ASCII 码
#define PGSIZE              4096

int
files_list(const char *dir_or_file) {
    char *absolute = dyn_alloc(PGSIZE);
    bzero(absolute, PGSIZE);

    // 1
    if (dir_or_file == 0 || (dir_or_file != 0 && dir_or_file[0] != DIRNAME_ROOT_ASCII)) {
        curdir_get(get_current_pcb()->curdir_, absolute, PGSIZE);

        if (dir_or_file != 0 && dir_or_file[0] != DIRNAME_ROOT_ASCII)
            memmove(absolute + strlen(absolute), dir_or_file, strlen(dir_or_file));
    } else    memmove(absolute, dir_or_file, strlen(dir_or_file));

    // 2
    diritem_t *found = dyn_alloc(sizeof(diritem_t));
    if (diritem_find(absolute, found) == false)    return -1;

    if (found->type_ == INODE_TYPE_FILE) {
        // 3
        kprintf("%dB\t\t%s\n", (__fs_inodes + found->inode_idx_)->size_, absolute);
    } else if (found->type_ == INODE_TYPE_DIR) {
        // 4
        char *dir = diritem_traversal(found);
        for (uint32_t i = 0; i < __fs_inodes[found->inode_idx_].size_; ++i) {
            kprintf("%s\t", dir);
            dir += DIRITEM_NAME_LEN;
        }
        kprintf("\n");
        dyn_free(dir);
    } else    return -1;

    dyn_free(found);
    if (dir_or_file == null || absolute[0] != DIRNAME_ROOT_ASCII)
        dyn_free(absolute);
    return 0;
}
```

- 注释 1：获取形参给定目录名的绝对路径。值得注意的是，当执行 `ls` 时是不带形参的，此时需要打印当前目录下的内容，借助前面章节目录结构的接口 `curdir_get()` 获取当前目录
- 注释 2：检查给定目录是否存在
- 注释 3：对于文件，直接打印大小和绝对路径名
- 注释 4：对于目录，递归打印目录下的所有文件名。[`diritem_traversal()`](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/fs/dir.c#L255) 是目录项接口，其功能是遍历目录项数组，每枚举一个，就保存它的目录名。遍历完成后目录名就被一级一级地保存下来，最终返回上层，即这里的变量 `dir`。目录的 inode 其 `size_` 成员保存的是目录的数量，所以以它为循环条件将每一级目录名打印出来

用户侧系统调用接口见 [user/user.c](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/user/user.c#L188)：

```c
int
sys_ls(const char *dir_or_file) {
    int ret = -1;
    syscall_entry(SYS_LIST, &ret);
    return ret;
}
```

## 获取当前目录

就是实现一个 `Linux` 的 `pwd` 命令。由于 `hoo` 使用目录结构来缓存整个目录树，所以现在要实现 `pwd` 就很简单了，直接调用目录结构的获取接口，见 [kern/fs/dir.c](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/fs/dir.c#L492)：

```c
int
dir_get_current(char *buff, uint32_t bufflen) {
    return curdir_get(get_current_pcb()->curdir_, buff, bufflen);
}
```

只需要提供缓冲区，借助 `curdir_get()` 获取当前目录的绝对路径即可

用户侧系统调用接口见 [user/user.c](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/user/user.c#L227)：

```c
int
sys_workingdir(char *wd, unsigned int len) {
    int ret = 0;
    syscall_entry(SYS_WORKINGDIR, &ret);
    return ret;
}
```

# 内置命令

内置命令本质上是磁盘中一个二进制文件，最初保存在 `hoo` 内核链接到一起，伴随着 `hoo` 内核一并加载到内存，然后在内核初始化过程中被写入文件系统。当需要执行内置命令是，则从文件系统中打开文件，读取文件到内存

`hoo` 在初始化时通过 [`load_builtins()`](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/kern.c#L54) 函数加载内置命令，详见 [kern/fs/builtins.c](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/fs/builtins.c#L52)，下面代码片段有删减：

```c
#define DIR_LOADER      "/bin/"
#define BUILT_SHELL     "shell"

void
load_builtins(void) {
    // 1
    files_create(DIR_LOADER);

    // 2
    builtin_to_file(BUILT_SHELL, (void *)__BASE_BUILTIN_SH,
        (uint32_t)__END_BUILTIN_SH - (uint32_t)__BASE_BUILTIN_SH);
}

void
builtin_to_file(const char *filename, void *addr, uint32_t len) {
    char *specific_file = dyn_alloc(64);
    // 3
    filename_append(DIR_LOADER, specific_file, filename);
    if (files_create(specific_file) == 0) {
        // 4
        fd_t fd = files_open(specific_file);
        if (fd == -1)    return;
        files_write(fd, addr, len);
        files_close(fd);
    }

    dyn_free(specific_file);
}
```

- 注释 1：创建 `/bin` 目录，用来保存所有内置命令
- 注释 2：将内置命令（这里以 `shell` 为例）写入文件系统。其中 `__BASE_BUILTIN_SH` 和 `__END_BUILTIN_SH` 在 Makefile 中定义，并在编译阶段导出，作为 `shell` 的起始和结束地址，详见 [Makefile](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/Makefile#L164)
- 注释 3：将 `/bin` 和 `shell` 拼接成 `/bin/shell`，即内置命令 `shell` 的绝对路径名
- 注释 4：将 `shell` 写入文件系统的具体实现。先在文件系统中创建文件，创建成功则写入 `__BASE_BUILTIN_SH` 到 `__END_BUILTIN_SH` 之间的数据，即 `shell` 的代码

内置命令大多数都是借助上一章系统调用来完成工作，`hoo` 提供了下面这些内置命令：

- `sh`：即 `shell`
- `cd`：切换目录
- `ls`：列出目录
- `pwd`：获取当前目录
- `mkdir`：创建目录
- `touch`：创建文件
- `rm`：删除目录或文件

## 第一个 ring3 进程

`hoo` 内核启动后，会创建一个 `ring3` 进程来执行内置命令，这个进程就是 `sh`，即 `shell`。`sh` 是 `hoo` 内核的命令行解释器，负责解析用户输入的命令，并执行命令

```c
void
kern_exec(void) {
    tid_t result = fork(the_first_ring3);
    if (result != 0) {
        // 1
        while (1)    kill(); // 2
    }
}

#define BUILT_SHELL "shell"
void
the_first_ring3(void) {
    // 3
    sys_exec(BUILT_SHELL);
}
```

- 注释 1：创建 `ring3` 进程。`hoo` 内核在初始化完成后会进入 `kern_exec()`，它通过 `fork()` 来创建一个 `ring3` 子进程。然后 `hoo` 自己变成了 `ring0` 的父进程，最后进入一个无限循环，不断调用 `kill()` 函数来检查是否有已经过期的线程，如果有则杀死它们。这里父进程 `hoo` 不需要等待子进程终止，因为子进程后续会变成 `shell` 需要无限循环地执行
- 注释 2：`kill()` 的功能是杀死已经过期的进程，详情见后文
- 注释 3：`the_first_ring3()` 是子进程的入口，此时子进程权限是 `ring3`，所以要跳转执行流只能通过系统调用，这里通过 `sys_exec()` 来跳转至二进制文件 `shell`

前文「系统调用 - exit」提过，每个进程销毁自己时，会将自己的 pcb 加入到任务销毁队列，因此 `kill()` 通过它就可以找到需要进一步清除资源的进程，这些资源进程在销毁自己时不能释放，因此推迟到这一步 `kill()` 来完成。有三个：`ring0` 栈、`ring3` 栈和页目录表

所以 `kill()` 的逻辑很简单，就是遍历任务销毁队列，释放上面三个资源，详见 [kern/sched/tasks.c](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/sched/tasks.c#L386)：

```c
void
kill(void) {
    for (int i = 1; i <= __list_expired.size_; ++i) {
        node_t *n = list_find(&__list_expired, i);
        pcb_t *pcb = (pcb_t *)n->data_;
        list_remove(&__list_expired, i); // 1

        // 2
        phy_release_vpage((void *)PGDOWN(pcb->stack0_, PGSIZE));

        // 3
        phy_release_vpage((void *)PGDOWN(((void *)pcb->stack3_ - PGSIZE), PGSIZE));

        // 4
        phy_release_page(pcb->pgdir_pa_);
        bzero(pcb, sizeof(pcb_t));

    }
}
```

- 注释 1：从任务销毁队列中移除该任务
- 注释 2：释放 `ring0` 栈
- 注释 3：释放 `ring3` 栈
- 注释 4：释放页目录表，同时清空 pcb

## shell

考虑下 `shell` 的执行场景，应该是每执行一个命令，就需要创建一个新的进程，`shell` 作为父进程陷入睡眠，等待子进程执行完毕；子进程用来执行命令

`hoo` 的实现如下，详见 [user/builtin_shell.c](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/user/builtin_shell.c#L14)，以下代码片段有删减：

```c
#define FD_STDIN    0

static char TMP_PROMPT[] = "[root]";
static char command[MAX_CMD_LEN];

void
main_shell(int argc, char **argv) {
    char ch = 0;
    int i = 0;

    // 1
    sys_cd("/");

    while (1) {
        sys_printf("%s ", TMP_PROMPT);
        i = 0;

        do {
            // 2
            sys_read(FD_STDIN, &ch, 1);
            sys_printf("%c", ch);

            if (i < MAX_CMD_LEN)    command[i++] = ch;
            else {
                sys_printf(" (Command beyond %d characters!)\n", MAX_CMD_LEN);
                break;
            }
        } while (ch != '\n');

        // 3
        command[i] = 0;
        int pid = sys_fork();
        if (pid != 0) {
            // 父进程
            sys_wait();
        } else {
            // 子进程
            sys_exec(command);
        }
    }
}
```

- 注释 1：将当前工作目录切换到根目录
- 注释 2：读取用户输入的命令。`FD_STDIN` 是标准输入的文件描述符，`sys_read()` 从标准输入读取一个字符，并存储在 `ch` 中。如果 `ch` 不是换行符，则再将其存储在 `command` 数组。这个过程会检查 `command` 数组是否满，是则输出错误信息并退出循环
- 注释 3：解析命令。首先调用 `sys_fork()` 创建一个子进程，如果返回值不为 0，则表示当前进程是父进程，调用 `sys_wait()` 等待子进程结束。如果返回值为 0，则表示当前进程是子进程，调用 `sys_exec()` 执行命令

![](https://pic1.imgdb.cn/item/67b2962bd0e0a243d4000e01.png)

最终，`hoo` 通过创建 `ring3` 子进程，然后子进程通过系统调用完成了 `shell` 进程的创建

## 切换目录

[`cd` 命令](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/user/builtin_cd.c#L10) 主要封装了切换目录的系统调用，很简单：

```c
void
main_cd(int argc, char **argv) {
    char *param = argc > 1 ? argv[1] : 0;
    int ret = sys_cd(param);
    if (ret == -1)    sys_printf("cd: \"%s\" No such file or directory\n", param);
    else if (ret == -2)
        sys_printf("cd: \"%s\" The given path is a file\n", param);
}
```

## 列出目录

[`ls` 命令](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/user/builtin_ls.c#L10) 也是封装了列出目录的系统调用：

```c
void
main_ls(int argc, char **argv) {
    char *param = argc > 1 ? argv[1] : 0;
    int ret = sys_ls(param);
    if (ret == -1)    sys_printf("ls: \"%s\" No such file or directory\n", param);
}
```

## 获取当前目录

[`pwd` 命令](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/user/builtin_pwd.c#L11) 也是封装了对应的系统调用：

```c
void
main_pwd(int argc, char **argv) {
    char *wd = alloc(512);
    if (workingdir(wd, 512) == 0)    sys_printf("%s\n", wd);
    else    sys_printf("pwd: cannot get current directory\n");
    free(wd);
}
```

## 创建目录

创建目录需要处理相对路径和绝对路径的问题，`hoo` 的做法是统一将相对路径转换为绝对路径，然后才发起创建目录的系统调用，详见 [user/builtin_mkdir.c](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/user/builtin_mkdir.c#L13)

```c
#define MAX_PATH_LEN 512

void
main_mkdir(int argc, char **argv) {
    // 1
    char *abs = alloc(MAX_PATH_LEN);
    if (argv[1][0] != '/') {
	    if (workingdir(abs, MAX_PATH_LEN) != 0) {
	        sys_printf("mkdir: failed to get the current working directory\n");
	        free(abs);
	        return;
	    }
	    memmove(abs + strlen(abs), argv[1], strlen(argv[1]));
    } else {
        memmove(abs, argv[1], strlen(argv[1]));
    }

    // 2
    uint32_t len = strlen(abs);
    if (abs[len - 1] != '/') {
        abs[len] = '/';
        abs[len + 1] = 0;
    }

	// 3
    sys_create(abs);
    free(abs);
}
```

- 注释 1：转换绝对路径。[`alloc()`](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/user/lib.c#L90) 是动态内存分配系统调用的封装，[`workingdir()`](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/user/lib.c#L114) 是获取当前目录系统调用的封装，[`free()`](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/user/lib.c#L100) 是动态内存释放系统调用的封装。这些函数放在 user/lib.c 中，作为 `hoo` 平台的库函数。这里通过 `workdingdir()` 获取当前目录，保存到数组 `abs`，然后将相对路径追加到数组后面
- 注释 2：`sys_create()` 通过后缀 `/` 来区分是否目录，所以数组 `abs` 最后需要加上后缀
- 注释 3：发起系统调用

## 创建文件

创建文件和创建目录一样，不同之处在于 `hoo` 文件不需要 `/` 后缀，因此大致流程和创建目录一样，详见 [user/builtin_touch.c](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/user/builtin_touch.c#L13)：

```c
void
main_touch(int argc, char **argv) {
    // 处理绝对路径 ...

    // 1
    uint32_t len = strlen(abs);
    if (abs[len - 1] == '/') {
        abs[len - 1] = 0;
    }

	// 发起系统调用
    sys_create(abs);
    free(abs);
}
```

- 注释 1：如果出现了 `/` 后缀则删除

## 删除目录或文件

删除命令对于目录和文件的处理都是统一的，但是也要区分绝对路径的问题，详见 [user/builtin_rm.c](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/user/builtin_rm.c#L13)：

```c
#define MAX_PATH_LEN 512

void
main_rm(int argc, char **argv) {
	// 处理绝对路径 ...

	// 发起系统调用
    sys_remove(abs);
    free(abs);
}
```

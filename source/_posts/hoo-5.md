---
title: 「从零到一」调度机制
date: 2025-02-04 13:35:16
excerpt: x86 内核调度机制的本质是记录任务和调度任务，前者通过 PCB 进行定义，后者采用 FIFO 进行实现
categories: KERNEL
tag: hoo
---

# 进程控制块

一个任务就是一个执行流，一个执行流本质上是一堆 `x86` 指令的集合，在执行指令的时候，需要有一个栈（比如 `call` 指令、`ret` 指令）、还需要使用寄存器组（比如 `mov` 指令）。换句话说，每个任务在其运行时，都对应一套环境。将这套环境再加上一些和任务有关的管理信息封装到一起，便成为了进程控制块，PCB，`hoo` 的定义详见 [kern/sched/pcb.h](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/sched/pcb.h#L21)

# 调度机制

![](https://pic1.imgdb.cn/item/67a07f66d0e0a243d4f9b5c6.png)

可以将一个任务视为内存上的一个栈，比如内存上有两个栈，那么相当于内核正在管理两个任务的调度。假设 `t0` 时刻，`%esp` 指向 *vs code* 的栈，那么就是说 `t0` 时刻正在运行 *vs code*；同理当 `t1` 时刻，`%esp` 指向浏览器，就是说 `t1` 时刻正在运行浏览器

所以可以看出来，调度机制的关键是 **设置 `%esp` 的指向**

`x86` 调度机制的硬件设施是 [8253 可编程时间计数器](https://wiki.osdev.org/Programmable_Interval_Timer)，它负责在一定时间间隔后向处理器发送一个中断信号，换句话说这个中断信号会驱动调度机制的开始

![](https://pic1.imgdb.cn/item/67a08d27d0e0a243d4f9b773.png)

最简单的方法是，每次触发时间片中断时，将当前 `%esp` 保存到前一个任务的 pcb 的栈字段，然后将后一个任务 pcb 中保存的栈字段写入 `%esp`。当 `%esp` 的值改变那一瞬间，即表示完成了两个栈的切换，即表示完成了两个任务的切换

![](https://pic1.imgdb.cn/item/67a1ab0ed0e0a243d4fbc38c.png)

从时间片中断开始，小结一下任务的调度过程：

- t0 时刻，任务 A 首先是收到时间片中断，通过 IDTR 找到 IDT 元素，进入找到 ISR 入口
- 在 ISR 入口处保护现场，也即将寄存器环境全部保存到栈里面
- 跳入 ISR，即时间片中断 ISR，它会执行上述逻辑。遍历任务队列获取前后两个任务的 pcb，然后切换 `%esp`，切换到任务 B
- 任务 B 执行一段时间后，到达 t1 时刻，也会收到时间片中断，重复前面三步逻辑，最后和任务 A 的 `%esp` 进行交换，交换完成后又切换回去任务 A
- 之前任务 A 是在 ISR 入口处跳转到 ISR，现在从 ISR 返回，下一步就是恢复现场，即从栈里面取出寄存器环境，从内核态中返回到用户态，继续原来的任务

# spinlock

任务调度会使得多个任务（多个线程） "同时" 访问一些共享资源，带来数据不一致的问题，因此需要实现锁，`hoo` 主要使用 spinlock 来保证多个线程之间串行访问资源，参考 [OSDev spinlock](https://wiki.osdev.org/Spinlock#Improved_Lock)。`hoo` spinlock 是一个 [整型值结构体](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/utilities/spinlock.h#L10)，1 表示锁被占用，0 表示锁空闲：

```c
typedef struct spinlock {
    uint32_t islock_;
} spinlock_t;
```

实现了两个接口，[获取锁](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/utilities/spinlock.c#L23) 和 [释放锁](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/utilities/spinlock.c#L41)：

```c
// 获取锁
void
wait(spinlock_t *spin) {
    __asm__ ("1:");

    // 测试锁
    while (test(spin));

	// 获取锁
    __asm__ ("\n\t"
        "lock btsl $0, %0\n\t"
        "jc 1b"
        : "=m"(*spin) :: "cc");
}

// 释放锁
void
signal(spinlock_t *spin) {
    __asm__ ("movl $0, %0" :: "m"(*spin) :);
}
```

测试锁 `test(spin)` 对同一个锁对象，可以被多个线程同时看见，测试只是简单地判断锁变量的整型值是 1 还是 0

申请锁使用了 `x86` 指令 [`bts`](https://www.felixcloutier.com/x86/bts) 来设置比特位，[`lock`](https://www.felixcloutier.com/x86/lock) 前缀用在许多 read-modify-write 指令（访存指令），用来保证操作的原子性；释放锁只是简单地将锁清 0，处理器对值写入一个 32 位无符号数是可以保证原子性的，所以不需要 `lock` 前缀

# 实现

## 任务系统初始化

`hoo` 将任务队列分为两个，一个就绪队列，记录即将上处理器的线程；另一个运行队列，记录正在运行的线程（单处理器则运行队列总是只有一个元素，多处理器则有多个元素）

```c
static queue_t __queue_ready, __queue_running;
```

队列是统一的封装的数据结构，详见 [kern/utilities/queue.h](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/utilities/queue.h#L10)，提供了如下接口（初始化、判队空、入队、出对和查看队头）：

```c
// 队列插入位置
typedef enum enqueue_method {
    TAIL = 0,
    HEAD
} enq_mth_t;

void queue_init(queue_t *q);
bool queue_isempty(queue_t *q);
void queue_push(queue_t *q, node_t *m, enq_mth_t mth);
node_t *queue_pop(queue_t *q);
node_t *queue_front(queue_t *q);
```

则 `hoo` 任务系统的初始化为，详见 [kern/sched/tasks.c](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/sched/tasks.c#L125)：

```c
static spinlock_t __sl_tasks;

queue_init(&__queue_ready);
queue_init(&__queue_running);
spinlock_init(&__sl_tasks);

// 为 hoo 伪造一个 pcb 块，入队运行队列
node_t *hoo_node = node_alloc();
queue_push(&__queue_running, hoo_node, TAIL);
```

执行流从引导阶段直至当前，虽然一直都是 `hoo` 本身，但还没有为它 "正名"，现在需要伪造一个 pcb 块并将 `hoo` 加入运行队列。至此，就绪队列为空，运行队列只有 `hoo` 线程一个

## 调度器

完整代码详见 [kern/sched/tasks.c](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/sched/tasks.c#L161)，以下是关键片段：

```c
#define TIMETICKS 16 // 每 16 个时间片就执行一次调度

// pcb 结构体，有删减
typedef struct pcb {
    uint32_t *stack0_; // 内核栈
    uint32_t ticks_;   // 剩余时间片
} pcb_t;

// 调度器
void
scheduler() {
    if (test(&__sl_tasks))    return;

    // 1
    wait(&__sl_tasks);
    node_t *cur = queue_front(&__queue_running);
    if (cur != null) {
        if (((pcb_t *)cur->data_)->ticks_ > 0) {
            ((pcb_t *)cur->data_)->ticks_--;
            signal(&__sl_tasks);
            return;
        } else {
            ((pcb_t *)cur->data_)->ticks_ = TIMETICKS;
        }
    }

    // 2
    node_t *next = queue_pop(&__queue_ready);
    if (next != null) {
        cur = queue_pop(&__queue_running);
        if (cur != null) {
            queue_push(&__queue_ready, cur, TAIL);
        }
        queue_push(&__queue_running, next, TAIL);

        // 3
        tss_t *tss = get_hoo_tss();
        tss->ss0_ = DS_SELECTOR_KERN;
        tss->esp0_ = PGUP(((pcb_t *)next->data_)->stack0_, PGSIZE);
        signal(&__sl_tasks);

		// 4
        switch_to(cur, next);
    }

    signal(&__sl_tasks);
}
```

几处关键片段：

- 注释 1：检查剩余的时间片。从运行队列取出队头，如果时间片未递减到 0 则递减并退出后续流程；否则重置时间片
- 注释 2：交换两个任务。从就绪队列取出队头，再从运行队列取出队头，交换。新插入队列的结点插入到队尾
- 注释 3：更新 tss。tss 保存了正在运行的线程的内核栈
- 注释 4：切换任务。通过 [kern/sched/switch.S](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/sched/switch.S#L7) 定义的接口操作 `%esp` 寄存器，从而切换不同的两个栈，即切换任务

## 其他接口

有了运行队列之后，可以通过它 [获取当前线程的 pcb](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/sched/tasks.c#L145)：

```c
pcb_t *
get_current_pcb() {
    wait(&__sl_tasks);
    node_t *cur = queue_front(&__queue_running);
    signal(&__sl_tasks);

    return (pcb_t *)cur->data_;
}
```

任务队列是共享资源，所以访问前需要加锁。`hoo` 队列由于是一个统一的数据结构，所以队列元素类型是 `void *`，因此在返回时需要强制转换为 `pcb_t` 类型

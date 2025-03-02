---
title: 「从零到一」设备驱动
date: 2025-02-05 11:12:46
excerpt: 设备驱动作为宏内核中占据主要的一个部分，现代操作系统会包括大量设备驱动。但在 hoo 里面，只实现了四个能驱动任务运行的驱动，分别是 PIC、PIT、磁盘驱动和键盘驱动
categories: KERNEL
tag: hoo
---

# PIC

![](https://pic1.imgdb.cn/item/67a1cae3d0e0a243d4fbc8b7.png)

PIC 全称 Programmable Interrupt Controller，可编程的中断控制器，`x86` 基础设施是 [8259(A) 芯片](https://wiki.osdev.org/8259_PIC)

8259A 内部有两组寄存器：

- 初始化命令寄存器 ICW（只设置一次），写入顺序 ICW1 -> ICW2 -> ICW3 -> ICW4
- 操作命令寄存器 OCW（可多次设置），无写入顺序要求

![](https://pic1.imgdb.cn/item/67a204f6d0e0a243d4fbd060.png)

ICW1 用来初始化 8259A 的连接方式（单片还是多片），以及中断信号的触发方式：

- 边缘触发：信号的上升或下降就会触发，并且触发后会被清除
- 电平触发：信号出于高电平就会触发，并且只要保持高电平，中断就不断被触发

![](https://pic1.imgdb.cn/item/67a206afd0e0a243d4fbd07c.png)

ICW2 用来设置起始的中断向量号（设置 IRQ0 是哪个中断向量号），关于什么是中断向量号可以参考《操作系统真象还原》7.5.1 图 7-11：

![](https://pic1.imgdb.cn/item/67a2082ad0e0a243d4fbd0ac.png)

`x86` 保留的 [异常](https://wiki.osdev.org/Exceptions) 共 32 个，索引从 0 至 31，所以 IRQ0 一般都是从 32 开始，然后 IRQ1 为 33，以此类推。ICW2 只需要填写高 5 位，也就是说任意数字都是 8 的倍数

![](https://pic1.imgdb.cn/item/67a20aefd0e0a243d4fbd0cc.png)

ICW3 是级联（即需要使用多片）才使用，用来设置主片和从片用哪个 IRQ 互连。主片置位的比特位表示引出从片（比如 0x04 表示比特位 2 置位，使用 IRQ2 用来引出从片）；从片只使用最低 3 个比特位，低 3 位的数值表示级联的 IRQ 引脚（比如 0x02 表示 `0000_0010`，表示从片通过 IRQ2 与主片相连）

![](https://pic1.imgdb.cn/item/67a20d8bd0e0a243d4fbd100.png)

ICW4 是杂项设置，只需要关注 AEOI 位，其他不重要。AEOI 的自动和非自动是指结束中断的方式，非自动表示处理器每次接收到中断信号都要响应一个 EOI 信号让 8259A 芯片知道处理器已经处理了该中断；自动则表示处理器无需干预中断过程，结束中断的权利完完全全在 8259A 芯片这里

![](https://pic1.imgdb.cn/item/67a20f3bd0e0a243d4fbd11c.png)

OCW1 用来屏蔽中断信号，就是说不将指定的中断信号上报给处理器。M0 ～ M7 对应 IRQ0 ～ IRQ7，置位的比特位就表示对应的 IRQ 上的中断信号被屏蔽了

而 OCW2 和 OCW3 和非自动结束中断信号有关，`hoo` 使用的是自动结束，所以就略过了，代码详见 [kern/module/driver.c](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/module/driver.c#L11)

```c
#define ICW1_ICW4 1
#define ICW4_AUTO 2

set_icw1(ICW1_ICW4);
set_icw2(0x20, 0x28);
set_icw3(2);
set_icw4(ICW4_AUTO);

#define IRQ_TIMER    0
#define IRQ_KEYBOARD 1
#define IRQ_CASCADE  2
#define IRQ_ATA1     0xe

enable_mask_ocw1(IRQ_TIMER);    // irq0
enable_mask_ocw1(IRQ_KEYBOARD); // irq1
enable_mask_ocw1(IRQ_CASCADE);  // irq2
enable_mask_ocw1(IRQ_ATA1);     // irq14
```

`hoo` 为：

- ICW1 设置了 `0000_0001`，对应到命令字即边缘触发、需要从片
- ICW2 设置了主片 IRQ0 从 32 开始，从片 IRQ0 从 40 开始
- ICW3 设置了主片的 IRQ2 用作级联
- ICW4 设置了 `0000_0010`，对应到命令字即自动结束中断
- OCW1 放行了 IRQ0、IRQ1、IRQ2 和 IRQ14，分别表示接收时间片中断、键盘中断和 ATA 硬盘中断

# PIT

PIT 全称 Programmable Interval Timer，可编程的时间间隔计时器，`x86` 基础设施是 [8253 芯片](https://wiki.osdev.org/Programmable_Interval_Timer)

8253 芯片内部包含一个控制字寄存器，通过 `0x43` 端口访问

![](https://pic1.imgdb.cn/item/67a21614d0e0a243d4fbd1ec.png)

SC 位是选择通道 Select Channel 的缩写，通道 0、1、2 的区别如下：

- channel 0：第一个计数器，通常用于生成定时中断
- channel 1：第二个计算器，通常用于特定任务的计时
- channel 2：第三个计算器，通常用于音频输出

3 个计数器的工作频率均是 1.19318 Mhz，即一秒内会有 1193182 次脉冲信号。来一次脉冲则计数器会减 1，当计数器减到 0，8253 芯片就会输出一个中断信号

一秒内发出多少个输出信号取决于计数器的值变成 0 有多快（初始值越小，则倒计时到 0 就越快）。例如默认下初始值为 65536，则一秒内发出信号次数为 1193182 / 65536 约等于 18.206，即意味着中断信号频率为 18.206 Hz。换句话说，当希望一秒内发出 1000 次信号（频率 100 Hz），通过 1193182 / 1000 就可以计算出来初始值应该为 1193

如果使用第一个计数器，初始值需要写入 `0x40` 端口；要使用第二个计数器则是 `0x41`；第三个是 `0x42`

`hoo` 的实现详见 [kern/module/driver.c](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/module/driver.c#L57)：

```c
#define SC_CHANNEL0   0
#define LOWHIGHBYTE   48
#define M3            6
#define BINARY        0
#define TICKS_PER_SEC 1000

set_command(SC_CHANNEL0, LOWHIGHBYTE, M3, BINARY);
set_counter(TICKS_PER_SEC);
```

含义为：

- 控制字：`0011_0100` 表示使用 channel 0、读写顺序为先低字节再高字节、工作方式为方式 2（周期性产生中断信号）、二进制格式
- 初始值：频率为 1000，则写入初始值为 1193

# ATA

ATA（Advanced Technology Attachment）是一个电气标准，用来规定 ATA 设备（比如硬盘）之间的连接情况，IDE 标准是旧的名称

从软件角度来看，硬盘包括了硬盘本身和硬盘控制器，ATA 驱动可视为对硬盘控制器的编程，编程方式非常繁琐，可以参考 [OSDev ATA PIO Mode](https://wiki.osdev.org/ATA_PIO_Mode) 或其他资料，以下是 `hoo` 的实现思路

## ATA 设备检测

主要利用 [IDENTIFY 命令](https://wiki.osdev.org/ATA_PIO_Mode#IDENTIFY_command)，该命令会读取出来一个 512 字节的数据，准确来说，这 512 字节数据是一个结构体，该结构体被称为 IDENTIFY DEVICE，详见 [《ATA/ATAPI Command Set - 3 (ACS-3)》，7.12.1 一章表格 45](https://people.freebsd.org/~imp/asiabsdcon2015/works/d2161r5-ATAATAPI_Command_Set_-_3.pdf)。对于一个不太复杂的 ATA 驱动来说，大部分字段都可以忽略，因此 `hoo` 仅定义了部分字段，详见 [kern/driver/ata/ata_identify.h](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/driver/ata/ata_identify.h#L26)：

```c
// 序列号
typedef struct ata_serial_number {
    uint16_t serial_number_[10];
} ataser_t;

// 模式号
typedef struct ata_model_number {
    uint16_t model_number_[20];
} atamod_t;

// IDENTIFY DATA
typedef struct ata_identify_data {
    uint16_t :15;
    // 通用配置
    uint16_t word0_ :1;

    uint16_t word1_9_[9];
    // 序列号
    ataser_t word10_19_;

    uint16_t word20_26_[7];
    // 设备模式号
    atamod_t word27_46_;

    uint16_t word47_59_[13];
    // 硬盘扇区总数
    uint16_t word60_61_[2];

    uint16_t word62_255_[194];
} ataid_t;
```

`hoo` 最多支持两个 ATA 通道（可以视为主板上最多有两个 ATA 插槽），分别是 Primary 和 Secondary 通道，由于每个通道都可以支持主盘（master）和从盘（slave），因此 `hoo` 最多支持 4 个 ATA 设备

Primary 通道的数据端口为 `0x1f0` ～ `0x1f7`，控制端口为 `0x3f6`；Secondary 通道的数据端口为 `0x170` ～ `0x177`，控制端口为 `0x376`

读取 IDENTIFY DATA 逻辑详见 [kern/driver/ata/ata_device.c](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/driver/ata/ata_device.c#L123)，以下代码片段有删减，并且仅仅是从 Primary 通道中读取：

```c
#define ATA_CMD_IO_IDENTIFY           0xec
#define ATA_IO_RW_OFFSET_DATA         0x00
#define ATA_IO_RW_OFFSET_DRIVE_SELECT 0x06
#define ATA_IO_W_OFFSET_COMMAND       0x07
#define ATA_IO_R_OFFSET_STATUS        ATA_IO_W_OFFSET_COMMAND
#define ATA_STATUS_BSY                0x80
#define ATA_STATUS_DRQ                0x08
#define ATA_STATUS_ERR                0x01

// helper functions
static inline uint8_t
inb(uint16_t port) {
    uint8_t val;
    __asm__ volatile ("inb %w1, %b0" : "=a"(val) : "d"(port));
    return val;
}
static inline void
outb(uint8_t val, uint16_t port) {
    __asm__ volatile ("outb %b0, %w1" : : "a"(val), "d"(port));
}
static inline void
insw(void *flow, uint32_t len, uint16_t port) {
    __asm__ volatile ("cld; rep insw" :: "D"(flow), "c"(len), "d"(port));
}
static void
ata_wait_register_400ns(uint16_t reg) {
    inb(reg);
    // ...
}

// 1
uint16_t port_io = 0x1f0, port_ctrl = 0x3f0;
outb(0xe0, port_io + ATA_IO_RW_OFFSET_DRIVE_SELECT);
ata_wait_register_400ns(port_ctrl); // 2

// 3
outb(ATA_CMD_IO_IDENTIFY, port_io + ATA_IO_W_OFFSET_COMMAND);

// 4
if (inb(port_io + ATA_IO_R_OFFSET_STATUS) != 0x00) {
	// 轮询状态
	while (inb(port_io + ATA_IO_R_OFFSET_STATUS) & ATA_STATUS_BSY);

	// 等待设备就绪
	while (!((inb(port_io + ATA_IO_R_OFFSET_STATUS) & ATA_STATUS_DRQ)
		|| (inb(port_io + ATA_IO_R_OFFSET_STATUS) & ATA_STATUS_ERR)));

	// 5
	static ataid_t id;
	insw(&id, sizeof(ataid_t), port_io + ATA_IO_RW_OFFSET_DATA);
	// 从 IDENTIFY DATA 中获取序列号、扇区总数等信息

}
```

- 注释 1：将命令字发送到 Drive Select IO 端口（master 设备发送 `0xa0`，slave 设备发送 `0xb0`），Drive Select IO 端口在 Primary 通道上是 `0x1f6` 。将 Sector Count / LBA low / LBA mid / LBA high 这些 IO 端口写入 0（Primary 通道为 `0x1f2` ～ `0x1f5`），这里是忽略了
- 注释 2：操作 ATA 设备有一个 [400 纳秒延迟](https://wiki.osdev.org/ATA_PIO_Mode#400ns_delays) 的说法，意思是说在选择完设备之后需要读取 Status IO 端口 15 次后，最后一次就绪才能进入下一步
- 注释 3：发送 IDENTIRY 命令（`0xec`）到 Command IO 端口（Primary 是 `0x1f7`）
- 注释 4：从 Status IO 端口（Primary 是 `0x1f7`）中读取，如果值为 0 则设备不存在，否则设备存在。之后下一步继续从 Status IO 端口轮询状态，需要 Status IO 端口对应寄存器 `bit-7`（BSY） 清位、`bit-3`（DRQ）置位（或者 `bit-0`（ERR）置位）
- 注释 5：轮询完后，读取 256 次 16 位数据（借助 `insw` 指令单次读取 16 位数据）。当取出 IDENTIFY DATA 之后，从中获取硬盘序列号、硬盘扇区总数等信息

获取完 ATA 设备的基本信息后，`hoo` 会将这些信息保存到 [`ataspc_t` 结构体](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/driver/ata/ata_device.h#L27)：

```c
typedef struct ata_space {
    uint32_t device_amount_;  // 机器上 ATA 设备的总数
    int      current_select_; // 当前选择的 ATA 设备（本质是数组下标）
    atadev_t *device_info_;   // ATA 设备结构体数组
} ataspc_t;
```

ATA 设备结构体详见 [kern/driver/ata/ata_driver.h](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/driver/ata/ata_device.h#L11)，下面代码片段有删减：

```c
typedef struct ata_device {
    bool     valid_;         // 设备是否有效
    uint16_t io_port_;       // 数据端口
    uint16_t ctrl_port_;     // 控制端口
    uint32_t device_no_;     // 设备号
    uint32_t total_sectors_; // 设备扇区总数
    ataser_t dev_serial_;    // 设备序列号
    atamod_t dev_model_;     // 设备模式号
} atadev_t;
```

ATA 对象组织方式如下：

![](https://pic1.imgdb.cn/item/67a322a5d0e0a243d4fbf058.png)

由于 `hoo` 最多只支持 4 个 ATA 设备，所以 ATA 设备数组只有 4 个元素，依次是 Primary 主盘、Primary 从盘、Secondary 主盘和 Secondary 从盘

## ATA 设备读写

`hoo` 使用 [LBA28 方式](https://wiki.osdev.org/LBA) 读写 ATA 设备，读写方式参考 [ATA PIO Mode](https://wiki.osdev.org/ATA_PIO_Mode#28_bit_PIO)，以下是 `hoo` 的实现，详见 [kern/driver/ata/ata_device.c](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/driver/ata/ata_device.c#L94)：

```c
outb(0xe0 | (uint8_t)((lba >> 24) & 0xf),
	io_port + ATA_IO_RW_OFFSET_DRIVE_SELECT); // 1
ata_wait_register_400ns(ctrl_port);

outb(cr, io_port + ATA_IO_RW_OFFSET_SECTOR_COUNT); // 2
outb((uint8_t)(lba & 0xff), io_port + ATA_IO_RW_OFFSET_LBA_LOW); // 3
outb((uint8_t)((lba >> 8) & 0xff), io_port + ATA_IO_RW_OFFSET_LBA_MID);
outb((uint8_t)((lba >> 16) & 0xff), io_port + ATA_IO_RW_OFFSET_LBA_HIGH);
outb((uint8_t)cmd, io_port + ATA_IO_W_OFFSET_COMMAND); // 4
```

- 注释 1：发送 `0xe0`（`0xf0`）到 Master（Slave）设备，并带上 LBA 最高 4 位，写入 `0x1f6`（`0x176`）
- 注释 2：将要读写的扇区数量到 `0x1f2`（`0x172`）
- 注释 3：写 LBA28
- 注释 4：将命令字（读 `0x20`，写 `0x30`）写入 `0x1f7`（`0x177`）

等待命令执行有两种方式：polling（轮询）和 IRQ（中断）。前者一直消耗 CPU 时间来读取设备完成状态，后者让设备完成后主动发送一个中断信号通知 CPU。从性能出发明显后者更优，但 `hoo` 两种方式都实现了，原因是内核初始化阶段是关中断的，这个时候要读写硬盘（初始化文件系统）没办法用 IRQ 方式，只能用 polling；当内核初始化完成后，所有硬盘读写都是采用 IRQ

### Polling

polling 的好处是简单，每次操作 ATA 设备之后，只需要持续读取 Status IO 端口，检查 RDY 是否置位、BSY 是否清位，详见 [kern/driver/ata/ata_device.c](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/driver/ata/ata_device.c#L34)：

```c
static void
ata_wait() {
    // 忽略 io_port 的赋值

    while ((inb(io_port + ATA_IO_R_OFFSET_STATUS)
        & (ATA_STATUS_RDY | ATA_STATUS_BSY)) != ATA_STATUS_RDY);
}
```

polling 实现详见 [kern/driver/ata/ata_polling.c](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/driver/ata/ata_polling.c#L19)，以下代码片段有删减：

```c
typedef uint32_t atacmd_t;

#define ATA_CMD_IO_READ   0x20
#define ATA_CMD_IO_WRITE  0x30
#define BYTES_SECTOR      512

// 1
typedef struct ata_buff {
    void     *buff_;  // 缓存区
    uint32_t len_;    // 缓存区大小
    uint32_t lba_;    // LBA 号
    atacmd_t cmd_;    // 操作命令
} atabuff_t;

void
ata_polling_rw(atabuff_t *buff){
    // 2
    uint32_t sectors_to_rw = buff->len_ / BYTES_SECTOR;
    ataspc_t *space = get_ataspace();
    for (uint32_t i = 0; i < sectors_to_rw && buff->len_ > 0; i++) {
        ata_set_cmd(space->current_select_, buff->lba_, 1, buff->cmd_);
        ata_wait(); // 3

		// 4
        uint32_t rest_bytes = (buff->len_ >= BYTES_SECTOR) ?
            (BYTES_SECTOR / sizeof(uint16_t)) : (buff->len_ / sizeof(uint16_t));

		// 5
        if (buff->cmd_ == ATA_CMD_IO_READ)
            insw(buff->buff_, rest_bytes, ATA_IO_RW_OFFSET_DATA +
                space->device_info_[space->current_select_].io_port_);
        else if (buff->cmd_ == ATA_CMD_IO_WRITE)
            outsw(buff->buff_, rest_bytes, ATA_IO_RW_OFFSET_DATA +
                space->device_info_[space->current_select_].io_port_);

        buff->lba_ += 1;
        buff->len_ -= BYTES_SECTOR;
        buff->buff_ += BYTES_SECTOR;
    }

}
```

- 注释 1：`hoo` 将读写 ATA 的数据封装成为 [`atabuff_t` 结构体](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/driver/ata/ata_device.h#L36)，其中命令字 `atacmd_t` 本质上是 32 位无符号数，用来接收 `ATA_CMD_IO_READ` 和 `ATA_CMD_IO_WRITE` 两个宏
- 注释 2：读写 ATA 设备可能涉及多个扇区，通过将读写字节数除以扇区大小计算扇区数量，然后 `for()` 循环一个一个扇区地读写
- 注释 3：等待 ATA 设备完成
- 注释 4：读写多个扇区时，最后一个扇区可能是不满一个 `BYTES_SECTOR`（512 字节）的，需要对最后一个扇区作特殊处理
- 注释 5：对于 polling 来说，此时 ATA 设备已经完成读写，则通过 `insw()` 或 `outsw()` 两个 helper 将数据拷贝到 `atabuff_t` 结构体

### IRQ

IRQ 的实现分为两部分，第一部分处理 ATA 设备读写，第二部分是硬盘中断 ISR

IRQ 的实现还要借助 sleep() 和 wakeup() 两个系统调用。当 ATA 设备正在工作的时候，让当前线程睡眠；当 ATA 设备就绪的时候，由运行队列上的第一个线程（正在占用处理器的线程）唤醒

#### Sleep、Wakeup

一个线程进入睡眠最简单的逻辑是：将当前线程从运行队列中移除，然后另外引入一个睡眠队列，将当前线程的 pcb 加入睡眠队列。然后立即进行调度，因为此时没有任何线程占用处理器

那么反过来，当需要唤醒一个睡眠线程时，从睡眠队列中取出这个 pcb，加入就绪队列等待下一次调度

`hoo` 就是按照这个思路来实现 sleep() 和 wakeup() 的，现在只剩下一个问题，当睡眠队列有多个 pcb 时，唤醒线程时怎么知道这一次的资源到达是对应着哪个 pcb？`hoo` 的解决办法是在线程睡眠的时候，就要给出资源地址，并在 pcb 定义一个字段专门用来记录要等待的资源。这样当唤醒线程的时候（也是要给出资源地址），对比给出的资源和每个 pcb 内记录的资源，就能够找出到底要唤醒哪个线程

睡眠的具体实现详见 [kern/sched/tasks.c](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/sched/tasks.c#L207)，以下代码片段有删减：

```c
void
sleep(void *resource, spinlock_t *resource_lock) {
    disable_intr();
    pcb_t *cur = get_current_pcb();
    cur->sleep_ = resource; // 1

    signal(resource_lock);  // 2
    scheduler();            // 3

    enable_intr();
    cur->sleep_ = null;     // 4
    wait(resource_lock);
}
```

- 注释 1：将资源地址记录到 pcb 内
- 注释 2：释放资源的锁。因为进入临界区是不能睡眠的，否则如果这个临界区资源只能自己解锁，而这个时候能够唤醒你的线程也在等待临界区资源，那么线程的睡眠将是永久。不用担心此时释放锁会不会造成共享资源的数据不一致，因为前面第一句代码已经关中断了，现在就是个串行执行流
- 注释 3：立即进行调度。理由前面说了，现在逻辑上没有任何线程在运行
- 注释 4：重置 pcb 和锁。到了这一步很可能已经过了很久很久了，要等待的资源已经到达，可以恢复执行流了，则 pcb 和锁回到最开始睡眠之前的状态

唤醒的具体实现详见 [kern/sched/tasks.c](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/sched/tasks.c#L233)，以下代码片段有删减：

```c
void
wakeup(void *resource) {

	// 1
    for (uint32_t i = 1; i <= __list_sleeping.size_; ++i) {
        node_t *n = list_find(&__list_sleeping, i);
        // 2
        if (((pcb_t *)n->data_)->sleep_ == resource) {
            node_t *to_wakeup = list_remove(&__list_sleeping, i--);
            task_ready(to_wakeup); // 3
        }
    }
}
```

- 注释 1：睡眠队列实际上 `hoo` 没有使用队列而是用了链表，因为需要遍历每个元素
- 注释 2：对比资源找到需要唤醒的线程
- 注释 3：找到要唤醒的线程后从睡眠链表中取出，通过 `task_ready()` 接口加入就绪队列

#### ATA 设备读写

![](https://pic1.imgdb.cn/item/67a5a631d0e0a243d4fc7957.png)

`hoo` 引入一个队列来缓存所有正在发生读写的 atabuff。如图所示，所有线程都可以同时发起 ATA 设备读写，读写信息封装到 atabuff，然后将 atabuff 加入 ata 队列。其中 ata 队列是共享资源，访问时通过 spinlock 来保护

具体实现详见 [kern/driver/ata/ata_irq.c](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/driver/ata/ata_irq.c#L60)，以下代码片段有删减：

```c
typedef uint32_t atacmd_t;
#define ATA_CMD_IO_READ   0x20
#define ATA_CMD_IO_WRITE  0x30

typedef struct ata_buff {
    void     *buff_;  // 缓存区
    uint32_t len_;    // 缓存区大小
    uint32_t lba_;    // LBA 号
    atacmd_t cmd_;    // 操作命令
    bool     finish_; // 操作完成标识
} atabuff_t;

static queue_t __queue_ata;           // ata 队列
static spinlock_t __slqueue, __slata; // 锁

// 1
wait(&__slqueue);
queue_push(&__queue_ata, atabuff, TAIL);
signal(&__slqueue);

// 2
ata_set_cmd(atabuff->lba_, atabuff->len_, buff->cmd_);
if (buff->cmd_ == ATA_CMD_IO_WRITE)
	outsw(buff->buff_, buff->len_ / sizeof(uint16_t), io_port);

// 3. sleep (give up CPU)
wait(&__slata);
while (buff->finish_ == false)
	sleep(atabuff, &__slata);
signal(&__slata);
```

- 注释 1：将 atabuff（里面保存了读写 ATA 设备的信息）加入队列
- 注释 2：发起 LBA28 方式读写 ATA 设备。对于读和写稍微有点不一样，读是设备准备完成后才可以写缓存区；写是在最开始就要将缓存区数据写入 IO 端口
- 注释 3：主动放弃处理器，进入睡眠。这里锁 `__slata` 是用来串行访问每个 atabuff 的，不过这里加锁可以省略，因为每个线程请求的资源 —— atabuff 都是不一样的。这里加锁的目的是配平 `sleep()` 的函数参数，因为进入 `sleep()` 需要持有资源的锁，此后，线程将 atabuff 记录到 pcb 进入睡眠。另外，睡眠之前先查看资源是否已经准备就绪了，通过判断 `finish_` 标识获悉

#### 硬盘中断 ISR

由于 ata 队列是按照 FIFO 方式组织的，所以总是队头的元素先处理完成，因此处理器每次接收到硬盘中断，只需要处理 ata 队列的队头元素

具体实现详见 [kern/driver/ata/ata_irq.c](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/driver/ata/ata_irq.c#L31)，以下代码片段有删减：

```c
void
ata_irq_intr(void) {
	// 1
	wait(&__slqueue);
	atabuff_t *done = queue_pop(&__queue_ata);
	signal(&__slqueue);
	if (done != null) {
		if (done->cmd_ == ATA_CMD_IO_READ) {
			insw(done->buff_, done->len_ / sizeof(uint16_t), io_port_);
		}
		done->finish_ = true;
	}
	
	// 2
	wakeup(done);
}
```

- 注释 1：取下 ata 队列队头，完成读写。对于读，现在 ATA 设备的 IO 端口已经准备好数据，将其读取出来放入缓存区；对于写，什么都不做。然后将 `finish_` 标识置位
- 注释 2：唤醒挂靠到当前 atabuff 的线程

```c
#define ISR46_HARD1 46
set_isr_entry(&__isr[ISR46_HARD1], (isr_t)ata_irq_intr);
```

最后通过 `set_isr_entry()` 接口注册 ISR

# 键盘驱动

键盘从软件层面来看，也包括两部分，键盘和键盘控制器，`x86` 基础设施是 [8042 芯片](https://wiki.osdev.org/%228042%22_PS/2_Controller)

和键盘有关的有两个方面：[通码 / 断码（`hoo` 使用了第一套）](https://wiki.osdev.org/PS/2_Keyboard#Scan_Code_Set_1) 和 [环形缓冲区](https://en.wikipedia.org/wiki/Circular_buffer)

## 第一套通码 / 断码

通码 / 断码就是键盘的输出，和 ASCII 码一样都是一套编码标准，但是和 ASCII 码不是一一对应的，通码 / 断码转换 ASCII 码详见 [第一套通码 / 断码](https://wiki.osdev.org/PS/2_Keyboard#Scan_Code_Set_1)

## 环形缓冲区

这是一个数据结构，和环形队列十分相似，区别是额外加入了生产者 - 消费者问题的实现，引入这个数据结构是用来缓存键盘输入

缓存键盘输入的场景主要发生在键盘驱动和输出设备之间：

- 键盘驱动：用户按下一个键位，触发硬盘中断，将通码 / 断码转换为 ASCII 码，缓存到环形缓冲区
- 输出设备：如果环形缓冲区有数据，就输出

`hoo` 实现的生产者 - 消费者问题详见 [kern/utilities/circular_buffer.h](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/utilities/circular_buffer.h#L20)，以下代码有删减：

```c
// 环形缓冲区
typedef struct circular_buffer {
    uint32_t    capacity_;
    char        *buff_;
    int         head_;
    int         tail_;
    spinlock_t slock_;
} cclbuff_t;

// 生产者，缓存字符
bool
cclbuff_put(cclbuff_t *cclbuff, char c) {
    if (cclbuff_isfull(cclbuff))    return false;
    cclbuff->buff_[cclbuff->head_] = c;
    cclbuff->head_ = (cclbuff->head_ + 1) % cclbuff->capacity_;
    wakeup(cclbuff);
    return true;
}

// 消费者，读取字符
char
cclbuff_get(cclbuff_t *cclbuff) {
    if (cclbuff_isempty(cclbuff)) {
        wait(&cclbuff->slock_);
        sleep(cclbuff, &cclbuff->slock_);
        signal(&cclbuff->slock_);
    }
    char ch = cclbuff->buff_[cclbuff->tail_];
    cclbuff->tail_ = (cclbuff->tail_ + 1) % cclbuff->capacity_;
    return ch;
}
```

- 生产者：每 "产生" 一个字符，就存起来，然后唤醒睡眠在该环形缓冲区上的线程
- 消费者：总是先判断缓存是否为空，如果为空就进入睡眠。下次被唤醒的时候，环形缓冲区必定存在数据，此时再输出数据

## 键盘驱动

和 8042 芯片硬件对应的是 PS/2 控制器软件，该控制器的数据端口是 [`0x60`](https://wiki.osdev.org/%228042%22_PS/2_Controller#PS/2_Controller_IO_Ports)。因此键盘驱动的内容很简单，就是：

- 从数据端口中读取一个通码 / 断码
- 将通码 / 断码转换为 ASCII 码

详见代码 [kern/driver/8042/8042.c](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/driver/8042/8042.c#L54)，以下代码片段有删减：

```c
// 1
uint8_t ch = inb(DATA_PORT_8042);
char result = 0;

// 处理控制字符，处理通码 / 断码转换
// result = ...

// 2
cclbuff_t *kbuff = get_kb_buff();
cclbuff_put(kbuff, result);
```

- 注释 1：读取通码 / 断码
- 注释 2：[`get_kb_buff()`](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/driver/8042/8042.c#L38) 返回一个全局对象，在转换得到最终的 ASCII 码 `result` 后就可以缓存到环形缓冲区了

最后还有一点要注意的是，键盘驱动在每次按下键位的时候就应该被触发了，而这个时候也是处理器接收键盘中断信号的时候，所以键盘驱动在 `hoo` 里面就是键盘中断 ISR，通过 `set_isr_entry()` 接口注册 ISR

```c
#define ISR33_KEYBOARD 33
set_isr_entry(&__isr[ISR33_KEYBOARD], (isr_t)ps2_intr);
```

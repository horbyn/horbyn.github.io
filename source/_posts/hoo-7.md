---
title: 「从零到一」文件系统
date: 2025-02-07 17:41:24
excerpt: x86 内核文件系统的功能可以分为两个部分，管理一个磁盘以及实现文件操作接口。hoo 没有采取流行的文件系统格式，而是另外实现了一套组织方式，并围绕这套方式定义了四个主要的文件系统接口：打开文件、关闭文件、创建文件、删除文件、读取文件和写入文件
categories: KERNEL
tag: hoo
---

# 索引结构

操作系统学科通常用 inode 来抽象一个文件，对多个文件进行管理需要借助索引结构

![](https://pic1.imgdb.cn/item/67a5dd2dd0e0a243d4fc9240.png)

一个 inode 是一个数据结构，里面包含了关于一个文件的所有管理信息，索引表只是其中一个管理信息。如图所示，根据索引表，文件一将一些文本信息先保存在空闲块 1，再保存到空间块 2

除了 inode 数据结构以外，`hoo` 还引入了另外一个数据结构目录项，用来统一文件和目录的操作。`hoo` 文件系统内管理的数据只有两类，文件和目录。内核在检索到一份数据时，会先转换为目录项数组，然后再根据文件或目录作不同操作

![](https://pic1.imgdb.cn/item/67a61392d0e0a243d4fca044.png)

索引表是一个下标数组，共 8 个元素：

- 前 6 个元素：直接索引，也就是每个下标都直接表示一个扇区
- 下标 6 号元素：一级索引，下标指示的扇区又是另外一个下标数组。由于一个扇区 512 字节，一个下标元素 4 字节，所以一个扇区可以保存 128 个下标。这些下标才表示真正的扇区
- 下标 7 号元素：二级索引，在一级索引之上又多一层索引

# 文件系统

文件系统简单来说就是怎么组织一个硬盘，`hoo` 没有使用常见的文件系统格式，而是自定义一个格式，下面是自定义格式的说明：

![](https://pic1.imgdb.cn/item/67a5d3e3d0e0a243d4fc8f13.png)

- 第一个扇区：留空（`hoo` 没有实现硬盘分区，如果未来有需要这个扇区留给分区用）
- 第二个扇区：超级块，也就是文件系统的管理信息
- 第三个扇区开始：inode 位图，也就是记录下来哪些 inode 可用哪些不可用
- 扇区 x 开始：inode 块，前面 inode 位图不一定只占用一个扇区，占用多少个扇区不是固定的
- 扇区 y 开始：空闲块位图，也就是记录下来哪些空闲块可用哪些不可用
- 扇区 z 开始：空闲块

## 超级块初始化

超级块定义在 [kern/fs/super_block.h](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/fs/super_block.h#L11)：

```c
typedef struct super_block {
    uint32_t magic_;                 // magic number
    uint32_t lba_partition_,         // 分区信息所在的 LBA 号
        lba_super_block_,            // 超级块所在的 LBA 号
        lba_map_inode_,              // inode 位图所在的 LBA 号
        lba_inodes_,                 // inode 所在的 LBA 号
        lba_map_free_,               // 空闲块位图所在的 LBA 号
        lba_free_;                   // 空闲块所在的 LBA 号
    uint32_t map_free_sectors_;      // 空闲块占据了多少个扇区
    uint32_t inode_block_index_max_; // 二级索引最多有多少个扇区
} super_block_t;
```

以下是一些说明：

- `magic_`：`hoo` 文件系统通过将 `0x1905e14d`（纪念 1905 的爱因斯坦奇迹年）记录在超级块以确认文件系统格式
- `inode_block_index_max_`：如前文所示，一个 inode 会拥有一个包含了 8 个元素的索引表，`hoo` 的索引表是二级索引。那么，一个 inode 可表示的扇区数量就是（详见 [kern/fs/super_block.c](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/fs/super_block.c#L41)）：
	- 前 6 个索引是直接索引，可以表示 6 个扇区
	- 第 7 个索引是一级索引，可以表示 512 / 4 = 128 个扇区（一级索引指示的扇区有 512 字节，一个扇区号 4 字节，所以一个扇区可以表示 128 个扇区号，也即对应 128 个扇区）
	- 第 8 个索引是二级索引，可以表示 128 * 128 个扇区（计算过程略，结合前一点和前文示意图可以得到）

## inode 位图和 inode 块初始化

![](https://pic1.imgdb.cn/item/67a62072d0e0a243d4fca291.png)

inode 位图每个比特位表示一个 inode 块，置位表示对应的 inode 块已经分配，清位表示未分配

inode 位图和 inode 块都有两份，一份 on-disk，一份 in-memory。所有线程的 inode 读写都是面向 in-memory 结构，然后内核会在适当时刻将 in-memory 结构统一写入硬盘

in-memory 结构的 inode 位图借助 [kern/utilities/bitmap.h](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/utilities/bitmap.h#L18) 的接口来操作，对 inode 位图和 inode 块的初始化分两种情况：

- 硬盘已经写入了文件系统
	- inode 位图（in-memory）从硬盘的对应 LBA 处读取
	- inode 块（in-memory）也是从对应的 LBA 处读取
- 硬盘是空盘
	- inode 位图（in-memory）全部为 0，写入硬盘对应 LBA 处
	- inode 块（in-memory）也全部为 0

inode 定义详见 [kern/fs/inodes.h](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/fs/inodes.h#L20)：

```c
#define MAX_INODE_BLOCKS 8
typedef struct inode {
    // 文件大小或目录个数
    uint32_t    size_;
    // 索引表: [0-5] 直接索引; [6] 一级索引; [7] 二级索引
    uint32_t iblocks_[MAX_INODE_BLOCKS];
} inode_t;

// 全局 inode in-memory 数组
#define MAX_INODES   64
extern inode_t __fs_inodes[MAX_INODES];

void inodes_rw_disk(int inode_idx, atacmd_t cmd);
```

`__fs_nodes` 对象是 in-memory inodes 数组，整个文件系统最多支持 64 个 inode，换句话说，文件和目录加在一起最多只支持保存 64 个。伴随 inode 出现同时还定义一个读写 inode 的接口，详见 [`kern/fs/inodes.c`](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/fs/inodes.c#L100)，实际上是 ATA 读写的一个封装。对于 ATA 读是 on-disk inode 读取到 in-memory inode；对于 ATA 写则是 in-memory inode 写入 on-disk inode

初始化详见 [kern/fs/inodes.c](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/fs/inodes.c#L20)，以下代码片段有删减：

```c
#define BYTES_SECTOR 512
#define MAX_INODES   64
static bitmap_t __bmfs;                          // 1
static uint8_t __bmbuff_fs_inodes[BYTES_SECTOR];
inode_t __fs_inodes[MAX_INODES];

void
setup_inode(bool is_new) {

	// 2
    atacmd_t cmd = is_new ? ATA_CMD_IO_WRITE : ATA_CMD_IO_READ;
    bitmap_init(&__bmfs, MAX_INODES, __bmbuff_fs_inodes);
    bzero(__fs_inodes, sizeof(__fs_inodes));
    bzero(__bmbuff_fs_inodes, sizeof(__bmbuff_fs_inodes));

    // 3
    ata_driver_rw(__bmbuff_fs_inodes, sizeof(__bmbuff_fs_inodes),
        FS_LAYOUT_BASE_MAP_INODES, cmd);

    // 4
    if (is_new == false) {
        for (uint32_t i = 0; i < MAX_INODES; ++i) {
            if (bitmap_test(&__bmfs, i) != false)
                inodes_rw_disk(i, cmd);
        }
    }
}
```

- 注释 1：`__bmfs` 是全局 inode 位图，后面的 `__bmbuff_fs_inodes` 对象是位图结构的缓存区，该缓存区就一个扇区大小，所以最多可以支持 512 * 8 = 4096 个 inodes
- 注释 2：根据外部传入的参数获悉硬盘是新盘还是旧盘，然后初始化 in-memory 对象
- 注释 3：如果是新盘，`cmd` 是写命令，否则是读命令。这里根据新盘还是旧盘设置 inodes 位图的值
- 注释 4：如果是旧盘，前一步已经将 inodes 位图从硬盘中读取出来了，检索整个位图，将已经分配的 inode 块从硬盘中读取到内存

## 空闲块位图初始化

和 inode 位图一样，空闲块位图也是一个比特位表示一个空闲块，置位表示已分配，清位表示未分配。空闲块位图也是有 on-disk 和 in-memory 两份，初始化逻辑也是类似，此处不再赘述

不同的是空闲块不需要做任何处理，因为空闲块只有 on-disk 部分，`hoo` 没有引入空闲块的缓存层，这确实是一点遗憾

## 根目录初始化

![](https://pic1.imgdb.cn/item/67a6dbeed0e0a243d4fceb6b.png)

根目录是唯一的，因此 `hoo` 文件系统也需要定义一个全局唯一的目录项对象来保存。从目录项中可以找出 inode 索引（一般根目录都是第一个，索引为 0），进而找到对应的 in-memory inode 元素。从 inode 元素中又可以找到索引表，进而找到一个磁盘块，对于目录类型来说，该磁盘块是一个数组，一个目录项数组（比如 `Linux` 根目录下面执行 `ls` 命令，会输出一个列表，可以是目录和文件）

通过这种组织方式，当需要检索根目录时，就是遍历最后的目录项数组；当需要在根目录下创建文件或目录时，就是写入最后的目录项数组

`hoo` 在 [kern/fs/dir.h](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/fs/dir.h#L16) 定义了目录项和目录项数组：

```c
typedef uint32_t inode_type_t;
#define INODE_TYPE_INVALID  0
#define INODE_TYPE_FILE     1
#define INODE_TYPE_DIR      2

// 目录项
typedef struct dir_item {
    inode_type_t type_;
    int          inode_idx_;
    char         name_[DIRITEM_NAME_LEN]; // 13.3 格式
} diritem_t;

#define BYTES_SECTOR            512
#define MAX_DIRITEM_PER_BLOCK   ((BYTES_SECTOR) / sizeof(diritem_t))

// 目录项数组
typedef struct dir_block {
    diritem_t dir_[MAX_DIRITEM_PER_BLOCK];
} dirblock_t;
```

- `inode_type_t` 是无符号整型值的别名，同时还定义了 `INODE_TYPE_FILE` 和 `INODE_TYPE_DIR` 用来表示文件和目录
- 目录项的文件名参考 [8.3 文件名格式](https://en.wikipedia.org/wiki/8.3_filename) 定义了 13.3 格式，表示文件名长度不超过 12 个字符，一个点字符，一个不超过 3 个字符的后缀名
- 目录项数组实际上是一个磁盘块转换而来的，也即数组总长度为 512 字节

因为根目录结构体成员的值是固定的，所以其目录项不保存到硬盘，也就是只有 in-memory 而没有 on-disk 结构。而新盘和旧盘的初始化稍微不同：
- 新盘：调用 [`diritem_create()`](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/fs/dir.c#L296) 接口创建根目录的目录项
- 旧盘：直接为 in-memory 的目录项赋值，详见 [kern/module/fs.c](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/module/fs.c#L34)

`diritem_create()` 是目录项操作，用来新建一个目录，详细代码见 [kern/fs/dir.c](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/fs/dir.c#L296)，这里忽略具体实现，下面展示这个函数的功能示意图：

![](https://pic1.imgdb.cn/item/67a700f9d0e0a243d4fcf8cf.png)

- 分配 inode，此时根目录必定是分配索引 0，然后将索引 0 填入根目录的目录项
- 分配空闲块，并且将其 LBA 填入 inode 的索引表
- 初始化目录项数组，对于一个新目录，`hoo` 会创建两个子目录，当前目录（`.`）和上一级目录（`..`）。对于根目录来说，当前目录是自己，所以 inode 索引是 0，没有上一级目录，所以 inode 索引是 -1

## 全局文件数组初始化

文件是一个软件层面的概念，多个线程可以引用同一个文件，为减少同一个文件创建的副本，`hoo` 引入了全局文件数组。同一个文件是全局唯一的，使用全局文件数组来记录。使用引用计数来管理文件的存留，多个线程引用同一个文件则引用计数增加，当引用计数递减为 0 则释放文件

文件定义详见 [kern/fs/fs_stuff.h](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/fs/fs_stuff.h#L29)：

```c
typedef struct files {
    int      inode_idx_; // 文件对应的 inode 数组索引
    uint32_t ref_;       // 引用计数
} files_t;
```

全局文件数组初始化详见 [kern/fs/files.c](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/fs/files.c#L49)：

```c
#define MAX_TASKS_AMOUNT    1024
#define MAX_FILES_PER_TASK  64
#define MAX_OPEN_FILES      ((MAX_FILES_PER_TASK) * (MAX_TASKS_AMOUNT))

files_t *__fs_files;
__fs_files = dyn_alloc(sizeof(files_t) * MAX_OPEN_FILES);
```

`hoo` 最大支持 1024 个任务，每个任务最多支持打开 64 个文件，所以全局文件数组最多 1024 * 64 个元素，初始化时通过动态内存分配相应大小的内存空间，赋值到全局指针 `__fs_files`

# 文件操作

文件系统与文件操作涉及的所有对全局资源的访问都是没有加锁的，意味着外部对象在使用文件系统接口时需要上锁

文件操作接口有创建、删除、打开、关闭、读取、写入六个，而文件实际上指代文件或目录

## 创建文件

核心思路有三步：

- 找到父目录。每个文件都是关联到父目录底下的，创建文件也即在父目录里面创建
- 创建文件对应的目录项。前面说过文件包含了文件和目录，所以在文件之上还有一层目录项的抽象，用来统一对文件或目录的操作，在真正操作文件或目录之前需要先操作目录项
- 将文件对应的目录项写入父目录项

`hoo` 的具体实现详见 [kern/fs/files.c](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/fs/files.c#L63)，以下代码片段有删减：

```c
#define DIRNAME_ROOT_ASCII  47    // 根目录 / 字符的 ASCII 码
#define DIRITEM_NAME_LEN    16    // 文件名长度

int
files_create(const char *name) {
	// 1
    inode_type_t type = (name[strlen(name) - 1] == DIRNAME_ROOT_ASCII) ?
        INODE_TYPE_DIR : INODE_TYPE_FILE;

    diritem_t *self = dyn_alloc(sizeof(diritem_t));
    if (diritem_find(name, self)) { // 2
        dyn_free(self);
        return -1;
    }
    dyn_free(self);

    diritem_t *di_parent = dyn_alloc(sizeof(diritem_t));
    char parent[DIRITEM_NAME_LEN], cur[DIRITEM_NAME_LEN];
    get_parent_child_filename(parent, cur); // 3
    diritem_find(parent, di_parent);        // 4

    // 5
    diritem_t *di_cur = diritem_create(type, cur, di_parent->inode_idx_);

    // 6
    diritem_push(di_parent, di_cur);
    dyn_free(di_parent);
    dyn_free(di_cur);

    return 0;
}
```

- 注释 1：判断创建文件还是目录。`hoo` 通过判断最后一个字符是否 `/` 来确定，存在为目录，不存在为文件。比如创建 `/bin/abc` 则是创建文件；如果是创建 `/bin/abc/` 则是创建目录
- 注释 2：查找待创建文件的目录项。如果存在则直接返回，避免重复创建相同的文件。[`diritem_find()`](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/fs/dir.c#L206) 是目录项接口，用来返回给定文件名的目录项
- 注释 3：将文件名拆分为父名称和子名称。比如 `/bin/abc`（`/bin/abc/` 也是）会被拆分为父名称 `/bin` 和子名称 `abc`，详见 [kern/utilities/curdir.c](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/utilities/curdir.c#L119)
- 注释 4：查找父目录项
- 注释 5：创建给定文件的目录项。需要指定待创建文件的文件类型、文件名、父目录的 inode 数组索引，通过这些信息创建一个新的目录项，`diritem_create()` 逻辑在创建根目录一节已经给出，不再赘述
- 注释 6：上一步创建的新目录项写入父目录项。[`diritem_push()`](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/fs/dir.c#L333) 也是目录项接口，用来将子目录项写入父目录项

`diritem_push()` 详细代码此处不再展示，下面是该函数的功能示意图：

![](https://pic1.imgdb.cn/item/67a71c59d0e0a243d4fd094f.png)

- 从父目录项中找到 inode。假设父目录是根目录，则此时找到 `inode[0]` 元素
- 从 inode 索引表找到目录项数组
- 将子目录项写入父目录项。此时父目录项什么文件都没有，子目录项将被写入下标 2 处

## 删除文件

核心思路有三步：

- 找到待删除文件的父目录项
- 找到待删除文件的目录项
- 从父目录项中删除给定文件的目录项

`hoo` 的具体实现详见 [kern/fs/files.c](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/fs/files.c#L107)，以下代码片段有删减：

```c
int
files_remove(const char *name) {
    char parent[DIRITEM_NAME_LEN];
    get_parent_child_filename(parent, 0); // 1

    diritem_t di_parent, di_cur;
    diritem_find(parent, &di_parent);     // 2
    diritem_find(name, &di_cur);

    diritem_remove(&di_parent, &di_cur);  // 3
    return 0;
}
```

- 注释 1：从待删除文件名中提取出父文件名
- 注释 2：找到待删除文件的父目录项和自己的目录项
- 注释 3：从父目录项中删除自己。[`diritem_remove()`](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/fs/dir.c#L374) 是目录项接口，用来从父目录项中删除给定的子目录项

同样 `diritem_remove()` 的详细实现此处省略，仅展示其功能示意图：

![](https://pic1.imgdb.cn/item/67a72253d0e0a243d4fd0bd1.png)

- 找到父目录项对应的目录项数组，然后遍历目录项数组，找到符合待删除文件的文件名那一个元素，将该元素清空
- 子目录项也要删除它拥有的文件，具体来说就是它自己目录项数组里面记录的文件。比如对于上图来说，当要删除 `/bin/` 目录时，此时还要删除 `/bin/cat` 文件。至于怎么删除 `/bin/cat`，这就是一个递归删除的过程

## 打开文件

每个线程的 pcb 都有一个文件数组，用来记录文件描述符 fd，表示打开了哪些文件。通过 fd 查找磁盘上的文件数据块的过程如下：

![](https://pic1.imgdb.cn/item/67a7312cd0e0a243d4fd0f24.png)

- 当线程访问 fd 为 7 的文件时，线程会从自己 pcb 的文件数组中找到索引 7。pcb 文件数组是一个文件描述符数组，所以取出的元素也是一个文件描述符，不同的是再次取出的文件描述符是全局唯一的
- 当取出全局唯一 fd，表示的是全局文件数组中的索引。如前文所示，全局文件数组是文件类型 `file_t`，里面记录了文件对应的 inode
- 通过 inode 从全局 in-memory inode 数组中找到 `inode_t` 对象，里面保存了索引表
- 通过索引表就可以找到磁盘块，进而把整个文件找到

`hoo` 为 pcb 的文件数组实现了一层封装，称为 [文件管理器](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/fs/fmngr.h#L11)，通过位图来记录文件数组哪些元素已分配哪些未分配，提供了一组操作接口：

```c
typedef struct file_manager {
    bitmap_t fd_set_; // 管理结构
    fd_t     *files_; // 文件数组
} fmngr_t;

fd_t fmngr_alloc(fmngr_t *fmngr);
void fmngr_free(fmngr_t *fmngr, fd_t fd);
void fmngr_files_set(fmngr_t *fmngr, fd_t fd, fd_t val);
fd_t fmngr_files_get(fmngr_t *fmngr, fd_t fd);
```

- 分配：从管理结构位图中查找未分配的比特位，则该比特位的索引就是 pcb 文件数组的索引
- 释放：将位图结构对应比特位清位
- 设置文件数组元素：将 `val` 写入 pcb 文件数组的索引 `fd` 处
- 获取文件数组元素：取出 pcb 文件数组的索引 `fd` 元素

打开文件的核心思路有两步：

- 从全局文件数组中取出一个未分配的元素索引
- 从 pcb 文件数组中取出一个未分配的元素索引，上一步的全局索引赋值给该元素

`hoo` 的具体实现详见 [kern/fs/files.c](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/fs/files.c#L132)，以下代码片段有删减：

```c
files_t *__fs_files; // 全局文件数组

fd_t
files_open(const char *name) {
    if (name == 0)    panic("files_open(): null pointer");

	// 1
    diritem_t *self = dyn_alloc(sizeof(diritem_t));
    diritem_find(name, self);
    if (self->type_ != INODE_TYPE_FILE)
        return -1;

	// 2
    fd_t index = fd_global_alloc();
    __fs_files[index].inode_idx_ = self->inode_idx_;
    ++__fs_files[index].ref_;

	// 3
    pcb_t *cur_pcb = get_current_pcb();
    fd_t fd = fmngr_alloc(cur_pcb->fmngr_);
    fmngr_files_set(cur_pcb->fmngr_, fd, index);

    dyn_free(self);
    return fd;
}
```

- 注释 1：获取待打开文件的目录项，检查文件类型，不是文件类型返回错误
- 注释 2：设置全局文件数组。[`fd_global_alloc()`](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/fs/files.c#L22) 返回一个未分配的全局文件描述符，该文件描述符作为索引，此时通过索引更新全局文件数组
- 注释 3：设置线程自己的文件数组。通过文件管理器接口 `fmngr_alloc()` 获取一个未分配的索引，再通过 `fmngr_files_set()` 将全局 fd 写入 pcb 文件数组

## 关闭文件

核心思路有两步：

- 从 pcb 文件数组中取出全局文件描述符
- 全局文件数组取出文件，引用计数减一

`hoo` 的实现很简单，详见 [kern/fs/files.c](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/fs/files.c#L158)，以下代码有删减：

```c
void
files_close(fd_t fd) {

    pcb_t *cur_pcb = get_current_pcb();
    fd_t index = fmngr_files_get(cur_pcb->fmngr_, fd);           // 1

    if (__fs_files[index].ref_ > 0)    --__fs_files[index].ref_; // 2
    if (__fs_files[index].ref_ == 0)    fd_global_free(index);   // 3
}
```

- 注释 1：从线程 pcb 的文件数组中取出全局文件描述符
- 注释 2：先对全局文件的引用计数减一
- 注释 3：再判断全局文件的引用计数是否减至 0，是则回收该全局文件。[`fd_global_free()`](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/fs/files.c#L40) 主要是将全局文件描述符设置为未分配

## 读取文件

`hoo` 和 `*nix` 系统一样，文件描述符 0 表示标准输入；1 表示标准输出；2 表示标准错误。经这样划分后，读取文件的输入流分为两个：标准输入和文件

那么，读取文件的核心思路就分为两步：

- 标准输入：结合「[设备驱动](https://horbyn.github.io/2025/02/05/hoo-6/)」一文的键盘驱动的内容，标准输入应该是从键盘中提取，而键盘会将输入字符缓存到键盘的环形缓冲区。换句话说标准输入就是从键盘环形缓冲区中读取数据
- 文件：
	- 从 pcb 文件数组中取出全局文件，进而获得文件对应的 inode
	- 从 inode 的索引表中读取磁盘块，通过磁盘块取出文件数据，最后保存到给定的缓冲区

![](https://pic1.imgdb.cn/item/67a75fc2d0e0a243d4fd1b1a.png)

举个例子，当需要从磁盘中读取 `main.c` 文件时：

- 通过目录项找到 `main.c` 的 inode
- 通过 inode 检索其索引表，发现有两个索引非空，分别（假设）是 LBA 100 和 LBA 200
- 读取 LBA 100 和 LBA 200，就可以获悉整个文件的内容

`hoo` 的具体实现详见 [kern/fs/files.c](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/fs/files.c#L178)，以下代码片段有删减：

```c
#define MAX_INODES 64
files_t *__fs_files;             // 全局文件数组
inode_t __fs_inodes[MAX_INODES]; // in-memory inode 数组

void
files_read(fd_t fd, void *buf, uint32_t size) {

    if (fd == FD_STDIN) {
	    // 1
        cclbuff_t *cclbuff = get_kb_buff();
        for (uint32_t i = 0; i < size; ++i) {
            *((char *)buf + i) = cclbuff_get(cclbuff);
        }
        return;
    }

	// 2
    pcb_t *cur_pcb = get_current_pcb();
    fd_t index = fmngr_files_get(cur_pcb->fmngr_, fd);
    int inode_idx = __fs_files[index].inode_idx_;
    inode_t *inode = __fs_inodes + inode_idx;

	// 3
	uint32_t cr = size / BYTES_SECTOR;
    for (uint32_t i = 0; i < cr; ++i) {
        free_rw_disk();
        memmove();
    }
}
```

- 注释 1：对于标准输入，从全局的键盘环形缓冲区中读取字符，每读取一个字符就保存一个到结果 `buf`
- 注释 2：从线程 pcb 自己的文件数组中取出全局文件，进而取出文件对应的 inode
- 注释 3：调用 [`free_rw_disk()`](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/fs/free.c#L76) 接口循环地从磁盘文件中读取数据，该接口封装了对 ATA 设备的读写，本质上也是从磁盘中读取，此处忽略其细节；后面每读取一个磁盘块（512B）就调用 [`memmove()`](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/user/lib.c#L72) 将其拷贝到结果 `buf`

## 写入文件

和上一节相似，写入文件输出流也有两个：标准输出和文件，前者实际是向输出设备写入，后者则是向磁盘写入

`hoo` 的输出设备实现了 [CGA 标准](https://en.wikipedia.org/wiki/Color_Graphics_Adapter)（CGA 是老标准，相对更新更广泛的是 VGA，当然，VGA 也很老了），对应的基础设施是 `80 * 25` 字符模式的显存输出。`hoo` 的实现详见 [kern/driver/cga/cga.h](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/driver/cga/cga.h#L8)，主要提供了一个操作接口 —— 写入，写入位置和字符属性等由这个 CGA 模块内部负责：

```c
void cga_putstr(const char *str, uint32_t len); // 将这个缓冲区的字符写入显存
```

那么，写入文件的核心思路就分为两步：

- 标准输出：将给定缓冲区的字符串输出到 CGA 模块
- 文件：
	- 从 pcb 文件数组中取出全局文件，进而获得文件对应的 inode
	- 从 inode 的索引表中读取磁盘块，然后将给定缓冲区的字符串写入磁盘块

![](https://pic1.imgdb.cn/item/67a76724d0e0a243d4fd1d7e.png)

举个例子，在保存 `main.c` 的源文件的一瞬间，执行流最终调用了文件写入函数：

- 通过目录项找到 `main.c` 的 inode
- 通过 inode 检索其索引表，发现为空，新分配一个磁盘块，LBA 为 100
- 将缓冲区写入 LBA 100

`hoo` 的具体实现详见 [kern/fs/files.c](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/fs/files.c#L220)，以下代码片段有删减：

```c
void
files_write(fd_t fd, const char *buf, uint32_t size) {
    if (fd == FD_STDOUT) {
	    // 1
        cga_putstr(buf, size);
        return;
    }

	// 2
    pcb_t *cur_pcb = get_current_pcb();
    fd_t index = fmngr_files_get(cur_pcb->fmngr_, fd);
    int inode_idx = __fs_files[index].inode_idx_;

    for (uint32_t i = 0; i <= size / BYTES_SECTOR; ++i) {
	    // 3
        free_rw_disk();
    }

    // 4
    __fs_inodes[inode_idx].size_ = size;
    inodes_rw_disk(inode_idx, ATA_CMD_IO_WRITE);
    free_map_update();
}
```

- 注释 1：对于标准输出，直接将整个缓冲区写入到 CGA 模块
- 注释 2：从线程 pcb 自己的文件数组中取出全局文件，进而取出文件对应的 inode 索引
- 注释 3：循环将缓冲区数据写入 inode 索引表对应的磁盘块
- 注释 4：更新文件对应的 inode。更新文件大小，然后将 in-memory inode 写入磁盘（同步 on-disk inode），最后更新 inode 位图，因为写入文件就相当于 inode 已分配，因此 inode 位图对应比特位需要置位，接口 [`free_map_update()`](https://github.com/horbyn/hoo/blob/e1739ab3d639caee5c52e6ca5abd01214fbbe0ff/kern/fs/free.c#L63) 就是将整个 in-memory inode 位图写入磁盘（同步 on-disk inode 位图）

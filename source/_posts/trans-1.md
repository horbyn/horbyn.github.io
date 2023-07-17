---
title: RISC-V 调用约定（译文）
date: 2022-03-29 23:08:55
excerpt: 原文来自于 xv6 lec5 的 prerequirement，谈论 risc-v 的调用约定
tags: translation
---

## 介绍

原文来自 [MIT 6.S081, Fall-2011, Lec 5 的 Preparation](https://pdos.csail.mit.edu/6.828/2021/schedule.html)

原文链接 [请点击此处](https://pdos.csail.mit.edu/6.828/2021/readings/riscv-calling.pdf)

<br>

## 调用约定 (Calling Convention)

> This chapter describes the C compiler standards for RV32 and RV64 programs and two calling conventions: the convention for the base ISA plus standard general extensions (RV32G/RV64G), and the soft-float convention for implementations lacking floating-point units (e.g., RV32I/RV64I).

"本章描述的是 C 编译器的 RV32 和 RV64 程序的标准，还有两个调用约定：第一个是基础 ISA 加上标准通用扩展（RV32G/RV64G）的调用约定；第二个是软浮点数调用约定，这个约定是为那些缺乏浮点运算器的机器所实现的（如 RV32I/RV64I）"

<br>

### 18.1 C 数据类型和对齐 (C Datatyped and Alignment)

> Table 18.1 summarizes the datatypes natively supported by RISC-V C programs. In both RV32 and RV64 C compilers, the C type int is 32 bits wide. longs and pointers, on the other hand, are both as wide as a integer register, so in RV32, both are 32 bits wide, while in RV64, both are 64 bits wide. Equivalently, RV32 employs an ILP32 integer model, while RV64 is LP64. In both RV32 and RV64, the C type long long is a 64-bit integer, float is a 32-bit IEEE 754-2008 floating-point number, double is a 64-bit IEEE 754-2008 floating-point number, and long double is a 128-bit IEEE floating-point number.

"表 18.1 总结了 risc-v C 程序原生支持的数据类型。在 RV32 以及 RV64 C 编译器上，C 类型 int 都是 32 位宽度。但是，long 类型和指针类型，却是和整数寄存器的宽度一样了。所以在 RV32 架构里面，long 类型和指针类型都是 32 位宽度；但是在 RV64 架构里，它们两者却是 64 位宽度。同样地，RV32 使用 ILP32 模式而 RV64 使用 LP64。不过在 RV32 和 RV64，C 类型 long long 都是一个 64 位整数，float 都是一个 32 位 IEEE 754-2008 浮点数，double 都是一个 64 位 IEEE 754-2008 浮点数，long double 是一个 128 位 IEEE 浮点数"

![](https://s2.loli.net/2022/03/29/UjPx61OsDXoRBai.png)

> The C types char and unsigned char are 8-bit unsigned integers and are zero-extended when stored in a RISC-V integer register. unsigned short is a 16-bit unsigned integer and is zeroextended when stored in a RISC-V integer register. signed char is an 8-bit signed integer and is sign-extended when stored in a RISC-V integer register, i.e. bits (XLEN-1)..7 are all equal. short is a 16-bit signed integer and is sign-extended when stored in a register.

"C 类型的 char 和 unsigned char 都是 8 位无符号整数，并且当存储在一个 risc-v 整数寄存器时是零扩展的。unsigned short 是一个 16 位无符号整数，并且当存储在一个 risc-v 整数寄存器时也是零扩展的。signed char 是一个 8 位有符号整数，当它存储在一个 risc-v 整数寄存器时是符号扩展的，即 bits(XLEN-1)..7 都是相同的。short 是一个 16 位有符号整数，当它存储在一个 risc-v 整数寄存器时是符号扩展"

**（译者注：XLEN 在 risc-v 文档里是用来指出寄存器当前宽度的符号，在这里 XLEN-1 用来表示最高位 ———— 1 个比特长所以是表示最高那个比特位）**

> In RV64, 32-bit types, such as int, are stored in integer registers as proper sign extensions of their 32-bit values; that is, bits 63..31 are all equal. This restriction holds even for unsigned 32-bit types.

"在 RV64 里存储在整数寄存器的 32 位类型，比如 int 类型，都是拿它们 32 位符号扩展作为当前数值，即位 64..31 都是相等的。这种情况即使在无符号 32 位类型里也是如此"

> The RV32 and RV64 C compiler and compliant software keep all of the above datatypes naturally aligned when stored in memory.

"RV32 和 RV64 的 C 编译器和对应的软件，在存储到内存时，都会自动保持上述数据类型对齐"

<br>

### 18.2 RVG 调用约定 (RVG Calling Convention)

> The RISC-V calling convention passes arguments in registers when possible. Up to eight integer registers, a0–a7, and up to eight floating-point registers, fa0–fa7, are used for this purpose.

"risc-v 调用约定尽可能通过寄存器传递参数。最多达到 8 个整数寄存器 a0-a7，以及 8 个 浮点数寄存器 fa0-fa7，都是出于传递参数目的（而设计的）"

> If the arguments to a function are conceptualized as fields of a C struct, each with pointer alignment, the argument registers are a shadow of the first eight pointer-words of that struct. If argument i < 8 is a floating-point type, it is passed in floating-point register fai; otherwise, it is passed in integer register ai. However, floating-point arguments that are part of unions or array fields of structures are passed in integer registers. Additionally, floating-point arguments to variadic functions (except those that are explicitly named in the parameter list) are passed in integer registers.

"如果将函数的参数看作像 C 结构体字段那样的概念，这些字段指针长度对齐，那么参数寄存器就是该结构体的前八个指针字长。如果参数是浮点数类型，它会通过浮点数寄存器 **fa***i* 来传递（i < 8）。否则，参数时通过整数寄存器 **a***i* 来传递。但是，如果浮点数参数是联合体或结构体数组成员的一部分，它们会通过整数寄存器传递。另外，可变参数的浮点数参数（即除了在参数列表里显式命名的）是通过整数寄存器来传递的"

> Arguments smaller than a pointer-word are passed in the least-significant bits of argument registers. Correspondingly, sub-pointer-word arguments passed on the stack appear in the lower addresses of a pointer-word, since RISC-V has a little-endian memory system.

"比一个指针字长要短的参数，通过参数寄存器的最低有效位来传递。相应地，子指针字参数通过栈上每个指针字的低地址传递，因为 risc-v 是一个小端字节序系统"

**（译者注：子指针字我猜测应该是像 x86 寄存器组的 al 之于 ax 的概念）**

> When primitive arguments twice the size of a pointer-word are passed on the stack, they are naturally aligned. When they are passed in the integer registers, they reside in an aligned even-odd register pair, with the even register holding the least-significant bits. In RV32, for example, the function void foo(int, long long) is passed its first argument in a0 and its second in a2 and a3. Nothing is passed in a1.

"当一个长度为指针字两倍长的参数通过栈传递时，他们会自动对齐。当这些参数通过整数寄存器传递，它们通过 *even-odd register pair* 规则对齐然后保存在栈上，即偶数寄存器保存着这个参数的最低有效位。比如，在 RV32 里有一个函数 `void foo(int, long long)`，第一个参数通过 **a0** 传递，第二个参数通过 **a2** 和 **a3** 传递，而 **a1** 什么东西都没有"

**（译者注：*even-odd register pair* is a pair of consecutive registers that starts with an even register ———— *even-odd register pair* 是一对开始于偶数寄存器的连续的寄存器对）**

> Arguments more than twice the size of a pointer-word are passed by reference.

"比一个指针字长度两倍还长的参数通过引用传递"

> The portion of the conceptual struct that is not passed in argument registers is passed on the stack. The stack pointer sp points to the first argument not passed in a register.

"（上文谈及的那个）概念上的结构体里，不通过参数寄存器传递的那部分参数，是通过栈传递的。栈指针 **sp** 指向第一个不通过寄存器传递的参数"

> Values are returned from functions in integer registers a0 and a1 and floating-point registers fa0 and fa1. Floating-point values are returned in floating-point registers only if they are primitives or members of a struct consisting of only one or two floating-point values. Other return values that fit into two pointer-words are returned in a0 and a1. Larger return values are passed entirely in memory; the caller allocates this memory region and passes a pointer to it as an implicit first parameter to the callee.

"函数返回值保存在整数寄存器 a0 和 a1，以及浮点数寄存器 fa0 和 fa1。只有当浮点数值是原语或只有一个或两个浮点数值组成的结构体成员时，才保存到浮点寄存器。其他恰好是两个指针字长的返回值会保存在 a0 和 a1。更长的返回值全部通过内存返回，而这部分内存由 caller 负责分配，然后将它的指针隐式地作为 callee 的第一个参数传递过去"

> In the standard RISC-V calling convention, the stack grows downward and the stack pointer is always kept 16-byte aligned.

"在标准 risc-v 调用约定里面，栈是向下生长的，栈指针总是 16 字节对齐"

> In addition to the argument and return value registers, seven integer registers t0–t6 and twelve floating-point registers ft0–ft11 are temporary registers that are volatile across calls and must be saved by the caller if later used. Twelve integer registers s0–s11 and twelve floating-point registers fs0–fs11 are preserved across calls and must be saved by the callee if used. Table 18.2 indicates the role of each integer and floating-point register in the calling convention.

"除了参数寄存器和返回值寄存器，其他 7 个寄存器 t0-t6 以及 12 个浮点数寄存器 ft0-ft11 都是临时寄存器，函数调用时才会使用，这些寄存器由 caller 负责保存。而另外的 12 个寄存器 s0-s11 以及 12 个浮点数寄存器 fs0-fs11 也是函数调用时才使用，但这些寄存器是 callee 负责保存的。表 18.2 指出在函数调用中每个寄存器和浮点数寄存器的作用"

![](https://s2.loli.net/2022/03/29/SKuWEzvx39aliCH.png)

<br>

### 18.3 软浮点数调用约定 (Soft-Float Calling Convention)

> The soft-float calling convention is used on RV32 and RV64 implementations that lack floatingpoint hardware. It avoids all use of instructions in the F, D, and Q standard extensions, and hence the f registers.

"软浮点数调用约定用在缺乏浮点数硬件的 RV32 和 RV64 机器上。这避免了使用 F、D 和 Q 标准扩展中的所有指令，还有 f 寄存器"

> Integral arguments are passed and returned in the same manner as the RVG convention, and the stack discipline is the same. Floating-point arguments are passed and returned in integer registers, using the rules for integer arguments of the same size. In RV32, for example, the function double foo(int, double, long double) is passed its first argument in a0, its second argument in a2 and a3, and its third argument by reference via a4; its result is returned in a0 and a1. In RV64, the arguments are passed in a0, a1, and the a2-a3 pair, and the result is returned in a0.

"整数的参数像 RVG 调用约定那样，使用相同的方式传递和返回参数，栈的规则也是相同的。浮点数参数通过整数寄存器传递和返回，使用相同尺寸下整数参数的规则。比如，RV32 中，函数 `double foo(int, double, long double)` 的第一个参数通过 **a0** 来传递，第二个参数通过 **a2** 和 **a3**，第三个参数通过 **a4** 传递一个引用，结果返回到 **a0** 和 **a1**"

> The dynamic rounding mode and accrued exception flags are accessed through the routines provided by the C99 header fenv.h.

"动态舍入模式和 accrued 异常标记通过 C99 头文件 fenv.h 提供的例程访问"
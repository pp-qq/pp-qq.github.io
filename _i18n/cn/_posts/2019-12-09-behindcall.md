---
title: "函数调用的背后"
hidden: false
tags: [开发经验]
---


一般情况下, 我们很少会关注函数调用是如何实现的, 反正大概就是压栈出栈什么的. 但是在我们 debug 时, 尤其是在 debug coredump 时, 知道这背后的细节还是会起到很大帮助的. 如我们在 debug qtcreator 时, 见 [为什么我的 QtCreator 看不了 GCC 源码]({{site.url}}/2019/12/05/qtcannotopengcc/). 之前我对这方面的掌握一直零零散散的, 这里总结一下.

目前据我所知, 编译器在实现函数调用时都要遵循一个特定的 ABI 约定, 该 ABI 约定规定了参数是通过寄存器还是通过内存来传递? 函数返回值如何传递? 函数内部是否需要为调用者保存某些寄存器等. ~~如果我没有搜错的话,~~ GCC 遵循的 API 约定应该是 [X86 psABI](https://github.com/hjl-tools/x86-psABI/wiki/X86-psABI). 该文件使用的是 AT&T 风格的汇编语法, 参见 [Linux 汇编语言开发指南](https://www.ibm.com/developerworks/cn/linux/l-assembly/index.html) 来了解一二. 详见 "3.2 Function Calling Sequence" 节了解在函数调用上, GCC 遵循的约定,  如下列举出一些关键点:

-    The Stack Frame 组织. 对于一个函数来说, 其 frame 在栈中的位置为 `[0(%rsp), 16(%rbp))`. 其中 rsp, rbp 值是该函数视角下看到的取值. 所以在函数调用前后, rsp, rbp 的值始终是不变的. 

-   Parameter Passing; 该 ABI 约定首先按照一系列规则对参数进行了分类, 之后定义了每类参数在传递时应该符合的规范. 如最常见的整数以及指针类型, 将依次尝试使用 %rdi, %rsi, %rdx, %rcx, %r8 and %r9 寄存器来传递参数, 如果无可用寄存器, 那么会使用内存, 即通过栈来传递.

-   寄存器归属权. 寄存器 rbp, rbx, r12, r13, r14, r15 属于调用方使用, 被调用函数如果会使用到这些寄存器, 那么应该首先将这些寄存器值保存在内存, 并在返回前恢复寄存器原值. 其他寄存器属于被调用方, 可任意折腾; 若调用方使用了这些寄存器, 那么其在调用函数时若有必要, 应该自己保存这些寄存器的取值.

GDB 与 ABI. 很显然 GDB 也需要遵循 ABI 约定来理解函数栈帧区域. 如当在 GDB 中使用 `info f` 获取栈帧信息时:

```
(gdb) info f
# 这里 0x7fff8d3031a0 便是上面所说的 `16(%rbp)`.
# 当前函数栈帧区域是 [rsp, 0x7fff8d3031a0 /* 16(%rbp) */)
# 由于栈增长方向是向下的, 所以这里认为 16(%rbp) 处地址是栈帧起始地址.
Stack level 3, frame at 0x7fff8d3031a0:
 rip = 0xaab7ed in secure_read (be-secure.c:152); saved rip 0xac61a3
 called by frame at 0x7fff8d3031d0, caller of frame at 0x7fff8d3030e0
 source language c.
 Arglist at 0x7fff8d303190, args: port=0x614000004a40, ptr=0x1a90540 <PqRecvBuffer>, len=8192
 Locals at 0x7fff8d303190, Previous frame's sp is 0x7fff8d3031a0
 Saved registers:
  # 当前栈帧中保存着的寄存器.
  # r15 估计未被当前函数使用, 所以没保存.
  rbx at 0x7fff8d303170, rbp at 0x7fff8d303190, r12 at 0x7fff8d303178, r13 at 0x7fff8d303180, r14 at 0x7fff8d303188, rip at 0x7fff8d303198
(gdb) disassemble
Dump of assembler code for function secure_read:
   0x0000000000aab574 <+0>:	push   %rbp
   0x0000000000aab575 <+1>:	mov    %rsp,%rbp
   0x0000000000aab578 <+4>:	push   %r14
   0x0000000000aab57a <+6>:	push   %r13
   0x0000000000aab57c <+8>:	push   %r12
   0x0000000000aab57e <+10>:	push   %rbx
   0x0000000000aab57f <+11>:	sub    $0x90,%rsp
   ...
```

其实这里我主要好奇的是 `info registers` 的实现, 尤其是当当前选择的函数栈帧并不是当前正在运行着的时. 若当前函数栈帧是正在运行着的, 那么 info registers 便可以通过 ptrace() 或者从 coredump 中某处获取. 但当当前函数栈帧不是正在运行着的时, 此时像 rdi, rai 这种不会被被调用者保存的寄存器, 他们的值早已被后续函数在执行时修改了, 所以拿不到当前函数栈帧下时这些寄存器的值了. 那 info registers 是怎么获取到的呢? 实验(主要是没从 GDB 文档中获取到相关细节, 而且又懒得看 GDB 源码了)表明: 在 info registers 时, 若寄存器会被被调用者保存, 那么 GDB 会通过读取被被调用者的栈帧区域来获取这些寄存器在当前栈帧下的值. 若寄存器不会被调用者保存, 则展示的是这些寄存器实际的取值, 即等同于在正在运行着的函数栈帧下执行 info registers 获取的值.
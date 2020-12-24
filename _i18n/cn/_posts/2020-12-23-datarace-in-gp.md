---
title: "不不不这不可能 - data race 造成的诡异现象"
hidden: false
tags: ["Postgresql/Greenplum"]
---

最近在忙着为之前做的 [外表分区](http://hidva.com/g?u=https://help.aliyun.com/document_detail/164815.html#title-xl7-dtw-5ai) 增加导出能力的功能, 继之前压测发现的 [gp 内核一处内存泄漏](http://hidva.com/g?u=https://github.com/greenplum-db/gpdb/issues/11244) 之后, 本以为接下来就顺风顺水波澜不惊, 准备开始走评审, 合入, 上线了. 没想到, 又出了一个幺蛾子:

```
(gdb) bt
#0  0x00007fac6e2b7277 in raise () from /lib64/libc.so.6
#1  0x00007fac6e2b8968 in abort () from /lib64/libc.so.6
#2  0x00007fac735ce8a9 in ?? () from /lib64/libasan.so.3
#3  0x00007fac735c37ab in ?? () from /lib64/libasan.so.3
#4  0x00007fac735bc9c9 in ?? () from /lib64/libasan.so.3
#5  0x00007fac735bd467 in __asan_report_load4 () from /lib64/libasan.so.3
#6  0x00000000016a7298 in timesub (timep=0x7ffd3b7a9d30, offset=28800, sp=0x63200000c598, tmp=0x2410120 <tm>) at localtime.c:1553
#7  0x00000000016a6219 in localsub (sp=0x63200000c598, timep=0x7ffd3b7a9f80, tmp=0x2410120 <tm>) at localtime.c:1364
#8  0x00000000016a63f3 in pg_localtime (timep=0x7ffd3b7a9f80, tz=0x63200000c498) at localtime.c:1377
#9  0x000000000154151f in log_line_prefix (buf=0x7ffd3b7aa190, edata=0x2401ac0 <errordata>) at elog.c:3134
#10 0x00000000015482c4 in send_message_to_server_log (edata=0x2401ac0 <errordata>) at elog.c:4409
#11 0x000000000153d09d in EmitErrorReport () at elog.c:1921
#12 0x0000000001536b9b in errfinish (dummy=0) at elog.c:704
```

而且诡异的是, gdb print 相关状态显示完全是正常的:

```
(gdb) p tmp->tm_mon
$1 = 11
(gdb) p idays
$2 = 18
```

相关代码如下:

```c
static const int mon_lengths[2][12] = {};

ip = mon_lengths[isleap(y)];  // 这里 y = 2020; isleap(y) = 1;
for (tmp->tm_mon = 0; idays >= ip[tmp->tm_mon]; ++(tmp->tm_mon))
    idays -= ip[tmp->tm_mon];
```

AddressSanitizer 给出的报错如下:
```
ERROR: AddressSanitizer: global-buffer-overflow on address 0x000001d7cdc0 at pc 0x0000016a7298 bp 0x7ffd3b7a9b50 sp 0x7ffd3b7a9b40
READ of size 4 at 0x000001d7cdc0 thread T0
```

这里 0x000001d7cdc0 即 `ip[12]`, 但这里 tmp->tm_mon 为 11, 最多也只是访问 `ip[11]` 来着! 怎么会访问 `ip[12]`. 一开始怀疑是 gdb 出现了某些问题, 所以 disassemble timesub, 准备在寄存器层面能不能看出点头绪. 在借助 [as2cfg](http://hidva.com/g?u=https://github.com/hidva/as2cfg) 绘制出 timesub 的 CFG 之后, 再结合 abort 时 pc 的位置, 确定了导致出错的相关指令序列如下. 之后再使用 info reg 获取到相关寄存器的取值. 注意在[调用约定]({{site.url}}/2019/12/09/behindcall/)中, 对于 rbp, rbx, r12, r13, r14, r15 这类归属于调用者的寄存器, info reg 显示的值, 便是当前堆栈下的值. 对于这些寄存器之外的寄存器, info reg 显示的是程序崩溃前一刻的值, 参考意义不是很大, 毕竟崩溃前会调用 raise(), abort() 这些函数, 而且这些函数都有可能改变这些寄存器的取值.

```
   0x00000000016a7242 <+3264>:	mov    rax,QWORD PTR [rbp-0x140]  # rax = 37814560, 0x02410120, 即变量 tm.
   0x00000000016a7249 <+3271>:	mov    eax,DWORD PTR [rax+0x10]   # eax = tm->tm_mon, 11
   0x00000000016a724c <+3274>:	cdqe  # rax = 11
   0x00000000016a724e <+3276>:	lea    rdx,[rax*4+0x0]  # rdx = 44
   0x00000000016a7256 <+3284>:	mov    rax,QWORD PTR [rbp-0xd8]  # rax,30920080,0x01d7cd90, mon_lengths+48, 即 ip
   0x00000000016a725d <+3291>:	lea    rcx,[rdx+rax*1] # rcx = &ip[tm->tm_mon], 30920124, 0x1d7cdbc
```

如上部分逻辑, 负责计算 `ip[tmp->tm_mon]` 的地址, 此时可以看到即使是从寄存器层面, tmp->tm_mon 也是 11, `ip[tmp->tm_mon]` 的地址是 0x1d7cdbc, 接下来需要从这个地址加载 4 个字节, 然后与 idays 做比较. 如下这部分逻辑是由 AddressSanitizer 插入, 语义便是检测 rcx 中的内存值是否合法.

```
   0x00000000016a7261 <+3295>:	mov    rax,rcx
   0x00000000016a7264 <+3298>:	mov    rdx,rax
   0x00000000016a7267 <+3301>:	shr    rdx,0x3
   0x00000000016a726b <+3305>:	add    rdx,0x7fff8000
   0x00000000016a7272 <+3312>:	movzx  edx,BYTE PTR [rdx]
   0x00000000016a7275 <+3315>:	test   dl,dl
   0x00000000016a7277 <+3317>:	setne  sil
   0x00000000016a727b <+3321>:	mov    rdi,rax
   0x00000000016a727e <+3324>:	and    edi,0x7
   0x00000000016a7281 <+3327>:	add    edi,0x3
   0x00000000016a7284 <+3330>:	cmp    dil,dl
   0x00000000016a7287 <+3333>:	setge  dl
   0x00000000016a728a <+3336>:	and    edx,esi
   0x00000000016a728c <+3338>:	test   dl,dl
```

若 rcx 中的地址合法, 则 dl 寄存器取值为 0, 此时会跳到 `<+3350>` 处, 取出 rcx 指向内存前 4 bytes 值. 若 rcx 地址不合法, 则 dl 寄存器非 0, 此时会调用 `__asan_report_load4()` 输出错误日志并 abort.

```
   0x00000000016a728e <+3340>:	je     0x16a7298 <timesub+3350>
   0x00000000016a7290 <+3342>:	mov    rdi,rax
   0x00000000016a7293 <+3345>:	call   0x4e9b10 <__asan_report_load4@plt>
=> 0x00000000016a7298 <+3350>:	mov    eax,DWORD PTR [rcx]
   0x00000000016a729a <+3352>:	cmp    eax,DWORD PTR [rbp-0x110]  # *(int*)(rbp-0x110) = 18
```

在我们这个情况, AddressSanitizer 监测到 rcx 中地址不合法. 这不可能啊!!! 一方面, 我们能人肉确定 0x1d7cdbc 这个地址值肯定是合法的! 另一方面, `__asan_report_load4()` 曝出的不合法的地址是 0x01d7cdc0. 特意从 [asan 源码](http://hidva.com/g?u=https://github.com/gcc-mirror/gcc/blob/master/libsanitizer/asan/asan_rtl.cpp) 看了下 `__asan_report_load4()` 实现:

```c
#define ASAN_REPORT_ERROR(type, is_write, size)                     \
extern "C" NOINLINE INTERFACE_ATTRIBUTE                             \
void __asan_report_ ## type ## size(uptr addr) {                    \
  GET_CALLER_PC_BP_SP;                                              \
  ReportGenericError(pc, bp, sp, addr, is_write, size, 0, true);    \
}
```

根据调用约定, addr 参数由 rdi 寄存器传递, 在我们上面的指令序列中, rdi 值来自于 rax, 而且 rax 与 rcx 取值相同, 所以这里 addr 参数应该是 0x1d7cdbc! 而不应该是 0x01d7cdc0!

当事情到达这一步时, 我主观上已经开始认为整个 coredump 都只是 AddressSanitizer 的误报, 毕竟我这边还赶工期呢, 不准备继续排查下去了, 准备总结总结然后扔到冷藏柜中存起来了.

就在总结的时候, 才意识到 `tm` 这个变量, 并不是 tmp!!! 或者说我一开始就没有意识到在 timesub() 时 tmp 参数指向着一个**全局变量** tm! 实际上在意识到这个之后, 很快就能发现整个事情的原因就是全局变量 tm 被多个线程同时读写导致的. 也就是后面给社区提的 issue [pg_localtime should not be used in multi-thread](https://github.com/greenplum-db/gpdb/issues/11300)

说到这里, 忽然意识到另外一个被打入冷宫未解决的 bug:

```
(gdb) bt
#0  0x00007fe914c01277 in raise () from /lib64/libc.so.6
#1  0x00007fe914c02968 in abort () from /lib64/libc.so.6
#2  0x00000000014e35cf in ExceptionalCondition (conditionName=0x1bd6cc0 "!(memoryAccount->allocated >= memoryAccount->freed)", errorType=0x1bd6ac0 "FailedAssertion", fileName=0x1bd6a60 "../../../../src/include/utils/memaccounting_private.h", lineNumber=183) at assert.c:66
#3  0x000000000157304f in MemoryAccounting_Free (memoryAccountId=398583, allocatedSize=1048) at ../../../../src/include/utils/memaccounting_private.h:183
(gdb) p *memoryAccount
$1 = {type = T_MemoryAccount, ownerType = MEMORY_OWNER_TYPE_MainEntry, allocated = 35112, freed = 32368, peak = 12008, maxLimit = 0, relinquishedMemory = 0, acquiredMemory = 0, id = 398583, parentId = 398582}
```

也即 `memoryAccount->allocated >= memoryAccount->freed` 是成立的, 所以不应该触发 assert failed! 现在看来应该也是 memoryAccount 被多个线程同时读写了吧, 但不幸的是, 我这边还在再次试图复现这些 bug.

是的是的是的了!, 确实是因为 rxThreadFunc 调用了 pfree(), palloc() 导致的了, 如同我之前提的这个 [quickdie may be invoked on rxThread](http://hidva.com/g?u=https://github.com/greenplum-db/gpdb/issues/11006) issue 所示, rxThreadFunc 确实可能会调用 pfree(), palloc(); 而 pfree(), palloc() 便会修改 MemoryAccounting_Free(), 便会导致 `memoryAccount->allocated`, `memoryAccount->freed` 被多个线程同时读写, 造成了 data race!

哈哈! 冷藏未决 bug 库清 0!

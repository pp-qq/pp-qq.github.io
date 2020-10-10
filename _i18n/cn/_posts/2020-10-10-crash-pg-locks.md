---
title: "SELECT pg_locks crash 了"
hidden: false
tags: ["Postgresql/Greenplum"]
---


## TL; DR

Greenplum 4.3 pg resqueue lock 链路 ResLockWaitCancel() 访问 LockMethodProcLockHash 这个共享结构时未使用指定的锁, 导致其他并发访问 LockMethodProcLockHash 的会话, 比如 `select * from pg_locks`, 看到了 LockMethodProcLockHash HASH_REMOVE 操作的中间状态, 操作的原子性被破坏, 导致了 crash.

## 正文

国庆长假第一天刚睁眼, 就看到老板钉了一下 "全局死锁检测有个 coredump, 抓紧看一下"...

脸都没洗就抱着电脑看了下, 心态放平了一点, 原来是 `select * from pg_locks` 获取系统当前锁信息时 coredump 了, 并不是全局死锁检测自己逻辑出问题了. 但头皮又麻了起来, select pg_locks 这可是 postgresql 用了十几年最核心的功能逻辑, 在我们线上也稳定运行了好几年了, 据我所知也从来没有听到有人反馈过 select pg_locks coredump 过. 她怎么会出问题呢?!

```
(gdb) bt
#0  0x00000000007bbe8e in GetLockmodeName (lockmethodid=104, mode=0) at lock.c:2570
#1  0x0000000000815cfa in pg_lock_status (fcinfo=0x7fff26d740b0) at lockfuncs.c:424
...
#9  0x00000000006a7a10 in SPI_execute (src=0xbc0119 "SELECT * FROM pg_locks", read_only=1 '\001', tcount=0) at spi.c:400
```

从堆栈上可以很明显的看到 crash 的原因, lockmethodid 合法值范围只会是 1, 2, 3, 这个 104 一看就不对劲. 接下来就要看下为啥会有 104 这个奇怪的值.

```
(gdb) set $mystatus = (PG_Lock_Status *) funcctx->user_fctx
(gdb) p $mystatus->lockData->nelements
$1 = 10687
(gdb) p $mystatus->currIdx
$2 = 10685
(gdb) set $lockData = $mystatus->lockData
(gdb) set $lock = &($lockData->locks[$mystatus->currIdx])
(gdb) p $lock->tag.locktag_lockmethodid
$4 = 104 'h'
```

在 lockData 中, 这个值就已经不合法了. 而 lockData 则是调用函数 GetLockStatusData() 获取到, 并存放在 funcctx->user_fctx 中的. 所以现在有几个可能性:

1.  GetLockStatusData() 返回的 lockData 中 lockmethodid 就已经是非法值了.
2.  GetLockStatusData() 返回 lockData 是正确的. 只不过保存在 funcctx->user_fctx 中的 lockData 由于某些原因, 比如内存写飞了, 导致 funcctx->user_fctx 中的 lockData 被写错了. 这个写错包括:

    -   GetLockStatusData() 返回 lockData->nelements = 10685, 但被 pg_lock_status() 链路误写为 10687, 导致 pg_lock_status() 访问到 `lockData->locks[10685]` 这个未初始化数据.
    -   GetLockStatusData() 返回 lockData->nelements = 10687, 但 `lockData->locks[10685]` 这个元素被 pg_lock_status() 链路误写了, 导致 pg_lock_status() 访问到不合法的 lockmethodid 值.

考虑到 pg 作为一个多进程架构, 其一个 backend 内只会有一个执行线程, 并不会有多线程下数据竞争的问题. 大致梳理了下 pg Set Returning Function 调用链路, 可以看到 funcctx->user_fctx 只会被 pg_lock_status 访问, 从代码上也不到有对其内 lockData 的写操作, 也即 lockData 被误写的可能性极低. 而且结合 `lockData->locks` 这些结构是 GetLockStatusData() 利用 palloc() 分配的, 根据 PG palloc() 保存的元信息也能很明显的看到 GetLockStatusData() 返回 lockData->nelements 就是 10687.

```
(gdb) p *$lockData
$1 = {nelements = 10687, proclocks = 0x2c78a20, procs = 0x2d49610, locks = 0x344c7a0}
(gdb) p ((AllocChunk)(0x344c7a0 - 16))->size / (double)sizeof(LOCK)
$5 = 10687
```

所以接下来就主要是排查下 GetLockStatusData() 为啥会返回不合法的 lockData. GetLockStatusData() 的逻辑很简单, 就是将 LockMethodProcLockHash 这个以 hash table 形式保存的锁信息转换为线性表示. LockMethodProcLockHash 位于共享内存中, 会被多个 backend 并发读写, 所以 GetLockStatusData() 会提前加上合适的锁. 考虑到 GetLockStatusData() 转换逻辑非常简单, 所以很显然接下来就怀疑:

1.  LockMethodProcLockHash 结构内保存的 lockmethodid 就已经是非法值了,
2.  hash_get_num_entries(LockMethodProcLockHash) 大于 LockMethodProcLockHash 内元素的实际个数, 导致了 GetLockStatusData() 返回 lockData 中末尾几项未初始化, 导致了末尾这几项 lockmethodid 取值随机.

很简单, 先把 coredump 中 LockMethodProcLockHash print 出来看下就行. 考虑到 LockMethodProcLockHash 就是 PG HTAB 结构, 根据 PG HTAB 的实现很容易写出如下 print HTAB 的 gdb 脚本:

```gdb
set confirm off
set pagination off
set disassembly-flavor intel
set print elements 0

define printkey
    set $proclock = (PROCLOCK*)$arg0
    set $proc = $proclock->tag.myProc
    set $lock = $proclock->tag.myLock
    print $lock->tag
end


define printbucket
    set $bucketptr = (HASHELEMENT*)$arg0
    while $bucketptr
        set $keyptr = (((char *)($bucketptr)) + (((intptr_t) ((sizeof(HASHELEMENT))) + ((8) - 1)) & ~((intptr_t) ((8) - 1))))
        printkey $keyptr
        set $bucketptr = $bucketptr->link
    end
end

define printhash
    set $hashp = (HTAB*)$arg0
    set $max_bucket = $hashp->hctl->max_bucket
    set $max_bucket++
    set $curBucket = 0
    while ($max_bucket)
        set $segment_num = $curBucket >> $hashp->sshift
        set $segment_ndx = (($curBucket) & (($hashp->ssize)-1))
        set $bucket = $hashp->dir[$segment_num][$segment_ndx]
        printbucket $bucket
        set $max_bucket--
        set $curBucket++
    end
end

printhash LockMethodProcLockHash
quit
```

但运行起来就太慢了, 等了 10 分钟才 print 了寥寥几条数据. 考虑到 select pg_locks coredump 这个 bug 触发频次应该是极低的, 毕竟几年了才见到了这一例, 便把电脑扔下带娃出去玩去了.

等到再次拿起电脑看的时候, LockMethodProcLockHash 倒是 print 完毕了, 但不幸的是如上两条可能性都不成立, print LockMethodProcLockHash 打印出其内元素数目等同于 hash_get_num_entries() 返回值, 而且这些元素内 lockmethodid 都合法. 不过考虑到 coredump 中的 LockMethodProcLockHash 已经不是 GetLockStatusData() 调用时的样子了. 而且最主要的是 postgresql.org 上确实有人遇到过 hash_get_num_entries(LockMethodProcLockHash) 大于 LockMethodProcLockHash 内元素实际个数的[情况](https://www.postgresql.org/message-id/8053.1357659565%40sss.pgh.pa.us). 原因是因为写 LockMethodProcLockHash 时未加上合适的锁, 导致了写操作原子性被破坏, 其他并发读操作看到了 LockMethodProcLockHash 的中间状态.

所以接下来重点便是从代码上排查所有涉及到 LockMethodProcLockHash 读写的链路, 考虑到我们 coredump 中的 case 的情况, 重点排查对 LockMethodProcLockHash 执行 HASH_REMOVE 操作的链路加锁情况. 最终经过一番枯燥无味的排查之后发现了这个弱智 bug...

```
LockWaitCancel()
	partitionLock = ((LWLockId) (FirstLockMgrLock + LockHashPartition(lockAwaited->hashcode)));
	LWLockAcquire(partitionLock, LW_EXCLUSIVE);
	RemoveFromWaitQueue(MyProc, lockAwaited->hashcode);
	LWLockRelease(partitionLock);

ResLockWaitCancel()  # bug!!!!!!!
	partitionLock = ((lockAwaited->hashcode) % NUM_LOCK_PARTITIONS);  # 没有加上 FirstLockMgrLock!!!!!!!
	LWLockAcquire(partitionLock, LW_EXCLUSIVE);
	ResRemoveFromWaitQueue(MyProc, lockAwaited->hashcode);
	LWLockRelease(partitionLock);
```

## 后记

多进程架构非常不爽的一点是, 一个进程崩溃之后, 其他进程并不会受到影响, 导致崩溃那瞬间其他进程的状态看不到了. 而多线程时, 一个线程崩溃会导致整个进程崩溃, 也就意味着我们很可能可以从 coredump 中看到其他线程崩溃前的状态, 从而可能会加速问题排查.

rust! rust! rust!, 自从用 rust 实现了 [waitforgraph](https://github.com/hidva/waitforgraph) 之后, 我就已经变成 rust 信仰粉了. rust 书写起来的感觉简直太愉悦了!!! 实际上我们最近遇到了好几个只需要改动 1 行代码便能修复的 **严重**(真的很严重!) bug, 在 rust 语言层面便能规避掉了.


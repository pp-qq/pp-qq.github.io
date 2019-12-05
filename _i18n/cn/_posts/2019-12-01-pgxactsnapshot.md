---
title: "PG 中的事务: 快照"
hidden: false
tags: ["Postgresql/Greenplum"]
---

>   本文章内容根据 PG9.6 代码而来.

众所众知, PG 通过 MVCC 多版本机制实现了事务. 在 PG 中, 每个 query 在执行时, 都会首先通过 GetSnapshotData() 来获取一张快照, 这个快照可以认为是数据库在某一特定时间点下所有数据的集合, 这张快照中包含的信息很简单:

-  xmin, 当前正在运行的事务集合中最小的 xid 值. 所有在 xmin 之前的事务都被认为是已经结束的.
-  xmax, 当前结束运行的事务集合中最大的 xid 值. 所有在 xmax 之后的事务都被认为是正在运行的. 在 PG 具体实现中, 将 xmax 置为最大的 xid 值 + 1, ~~咱也不知道为啥要这样做...~~, 本文后续以具体实现为准.
-  正在运行中的事务 xid 集合, 这部分信息分别放在 xip, subxip 中; xip 内存放着当前正在运行的 top-level 事务集合. subxip 内存放着当前正在运行的子事务 xid 集合. 由于 PGPROC 结构体中并未保存完整的子事务 id, 毕竟 PGPROC 位于共享内存中, 所以 subxids 字段中默认最多只能保存 64 个子事务 id. 即 subxip 中的信息可能是不完全的. 实际完全与否通过 suboverflowed 这个 flag 来标识, 若 suboverflowed 为 true, 则表明 subxip 中信息是不完全的, 此时完整的子事务 xid 集合则需要通过 pg_subtrans 设施来判断了. 对于位于 `[xmin, xmax)` 中的 xid, 可以通过检查该 xid 是否在 xip, subxip 中存在与否来判断该 xid 的运行状态.

这里可以看出通过快照信息只能获取事务是否已经结束结束, 具体事务的提交状态还是要通过 pg_clog 等设施来判断了.

GetSnapshotData() 与事务提交链路的交互, 这里可以把 GetSnapshotData() 与事务结束链路共享的部分抽象为是正在运行中的事务集对象, 该对象由两个部分组成: 正在运行中的事务 xid 集合, 存放在 PGXACT::xid 中; 以及已经结束运行的事务集合中最大的 xid 值, 存放在 `ShmemVariableCache->latestCompletedXid` 中. 该共享对象被 ProcArrayLock 保护着. 如此抽象之后整件事就清晰了一点, GetSnapshotData() 需要读取正在运行中的事务集对象, 因此其会首先以 LW_SHARED 方式对 ProcArrayLock 加锁, 之后读取出正在运行中的事务集对象, 并以此完成 snapshot 的构造. 而事务提交链路则涉及到对该对象的修改, 因此其会在链路最后的环节 ProcArrayEndTransaction() 中以 LW_EXCLUSIVE 的方式对 ProcArrayLock 加锁, 之后将自身从正在运行事务集对象中移除. 在正在运行事务集对象中, 正在运行中的事务 xid 集合由所有 backend 对应的 `MyPgXact->xid` 来表示, 若 `MyPgXact->xid` 取值为 0, 则表明相应 backend 中没有在运行事务. 同理 ProcArrayEndTransaction() 中会将 `MyPgXact->xid` 置为 0 来表明自身当前事务结束了. 由于 ProcArrayEndTransaction() 中 `LWLockRelease(ProcArrayLock); /* Release operation */` 与 GetSnapshotData() 中的 `LWLockAcquire(ProcArrayLock, LW_SHARED); /* Acquire operation */` 形成了 [Release-Acquire ordering](https://en.cppreference.com/w/cpp/atomic/memory_order#Release-Acquire_ordering), 所以 ProcArrayEndTransaction() 中将 `MyPgXact->xid` 置为 0 的操作总是对 GetSnapshotData() 可见的. 但是在分配新事务 XID 的 GetNewTransactionId() 中, 其会在未持有 ProcArrayLock 上任何锁的情况下对 `MyPgXact->xid` 进行赋值, 那么此时这种赋值操作对 GetSnapshotData() 可见么? 尤其是考虑到现代 CPU 使用了各种奇淫技巧: CPU Cache, Store Buffer, Invalid Queue, 乱序执行等, 直观看来这里我们应该在 GetNewTransactionId() 完成对 `MyPgXact->xid` 的赋值之后加个 write memory barrier, 在 GetSnapshotData() 读取 `MyPgXact->xid` 之前加个 read memory barrier, 从而使得最新的 `MyPgXact->xid` 取值可见([你应该了解的 memory barrier 背后细节]({{site.url}}/2018/12/05/whymb/)). 所以我最开始以为这里有个 BUG: GetSnapshotData() 获取到的运行中的事务 xid 集合并不完全, 存在一个正在运行中的 xid 小于 latestCompletedXid, 但不在 GetSnapshotData() 获取到的运行中的事务 xid 集合中.~~当时以为发现了个金矿...要名留开源界了==!~~.

所以我更加仔细地研究了 GetNewTransactionId(), ProcArrayEndTransaction(), GetSnapshotData() 三者所在链路之间的交互, 最终发现这里并没有如上可见性问题导致的 BUG... 我忽略了 GetNewTransactionId() 与 ProcArrayEndTransaction() 之间的关系, 如下序列是对三链路的模拟. 由于 XidGenLock 带来的 Release-Acquire ordering 使得 backend A 对 `APgXact->xid` 的写操作 [inter-thread happens before](https://en.cppreference.com/w/cpp/atomic/memory_order#Happens-before) backend B 对 `BPgXact->xid` 的写操作, 以及在 backend B 中, `write BPgXact->xid` sequenced before `write latestCompletedXid`, 以及在 ProcArrayLock 作用下, B 中的 `write latestCompletedXid` inter-thread happens before C 中的 `read latestCompletedXid`, 在这一系列规则之下我们可以知道: A 中的 `write APgXact->xid` happens before C 中的 `read APgXact->xid`! ~~啪~~

```
  backend A                       backend B                          backend C
/* GetNewTransactionId() */    /* GetNewTransactionId() */        /* GetSnapshotData() */
wlock(XidGenLock);             wlock(XidGenLock);                 rlock(ProcArrayLock);
write APgXact->xid;            write BPgXact->xid;                read latestCompletedXid;
unlock(XidGenLock);            unlock(XidGenLock);                read APgXact->xid;
                               ...                                read BPgXact->xid;
                               /* ProcArrayEndTransaction() */    unlock(ProcArrayLock);
                               wlock(ProcArrayLock);
                               write latestCompletedXid;
                               unlock(ProcArrayLock);
```

即在 PG 中任何时刻下都存在不变量: 任何小于 latestCompletedXid 的 xid 要么在 `MyPgXact->xid` 中, 要么已经结束运行了. 这保证了 GetSnapshotData() 与 GetSnapshotData() 行为的正确性.

再说回 ProcArrayEndTransaction(), PG 的大佬们为了减少事务提交时由于对 ProcArrayLock 的锁争用导致的性能下降, 也采取了一些措施: ProcArrayEndTransaction() 首先会以非阻塞的形式尝试获取 ProcArrayLock 上写锁, 若成功获取, 则通过 ProcArrayEndTransactionInternal() 完成对 `MyPgXact->xid` 的清零以及其他必要操作. 若无法获取锁, 则会将自身放到一个链表中并挂在 `MyProc->sem` 上等待其他 backend 帮自己调用 ProcArrayEndTransactionInternal() 来完成自身状态的清理. 这里由链表首元素来负责清理自身以及链表中所有 backend 的状态, 并在清理结束之后唤醒其他 backend. 在这个过程中, PG 通过一系列原子操作来精妙地完成了对这个链表的维护工作, 我觉得值得说道说道:

```c++
struct PGPROC {
    //...
    /* Support for group XID clearing. */
    /* 若为 true, 则表明当前 backend 在链表中. */
    bool procArrayGroupMember;
    /*
     * 若当前 backend 在链表中, 则 procArrayGroupMemberXid 记录着调用
     * ProcArrayEndTransactionInternal 时参数 latestXid 的取值.
     */
    TransactionId procArrayGroupMemberXid;
    /* 若当前 backend 在链表中, next 记录着链表中位于当前 backend 之后下个 backend pgprocno 值. */
    pg_atomic_uint32 procArrayGroupNext;
    //...
}

struct PROC_HDR{
    // ...
    /* 链表首元素 pgprocno 值 */
    pg_atomic_uint32 procArrayGroupFirst;
    // ...
}
```

当 backend 发现自己没法立即获取到 ProcArrayLock 锁时, 会将自己放在链表的最前面, 如下 while 循环会一直进行尝试(毕竟这时可能也有其他 backend 同样进行着同样操作.), 在 while 循环结束之后, backend 知道自己已经放到链表中了, 并且若此时 nextidx 为 0, 则表明自己是第一个放到链表中, 将负责整个链表中所有 backend 的状态清理工作.

```c++
proc->procArrayGroupMember = true;
proc->procArrayGroupMemberXid = latestXid;
while (true)
{
    nextidx = pg_atomic_read_u32(&procglobal->procArrayGroupFirst);
    pg_atomic_write_u32(&proc->procArrayGroupNext, nextidx);

    if (pg_atomic_compare_exchange_u32(&procglobal->procArrayGroupFirst,
                                       &nextidx,
                                       (uint32) proc->pgprocno))
        break;
}
```

若 nextidx 不为 0, 则表明自己不是链表首元素, 那就挂在信号量 `MyProc->sem` 上等待其他 backend 清理以及唤醒.

```c++
if (nextidx != INVALID_PGPROCNO /* 0 */)
{
    PGSemaphoreLock(&proc->sem);
    return ;
}
```

此时 nextidx 为 0, 自己是链表首元素, 开始清理工作. 记着与此同时, 仍可能有 backend 正在将自己放入链表中. 所以准确来说此时自己只是第一个放入链表之中的, 并不是链表首元素, 实际上自己是在链表最后一个位置中. 如下 while 循环会一直尝试获取链表首元素, 并通过将 `procglobal->procArrayGroupFirst` 置为 0 来重新开启一段新的链表. 在 while 之后, 其他 backend 在执行 ProcArrayGroupClearXid() 时见到的都已经是新链表了. 同样在 while 之后, nextidx 记录着当前 backend 获取到的链表的首元素下标, 之后就是中规中矩的遍历清理唤醒操作了.

```c++
/* We are the leader.  Acquire the lock on behalf of everyone. */
LWLockAcquire(ProcArrayLock, LW_EXCLUSIVE);
while (true)
{
    nextidx = pg_atomic_read_u32(&procglobal->procArrayGroupFirst);
    if (pg_atomic_compare_exchange_u32(&procglobal->procArrayGroupFirst,
                                        &nextidx,
                                        INVALID_PGPROCNO))
        break;
}

```

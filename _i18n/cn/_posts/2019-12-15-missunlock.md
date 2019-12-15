---
title: "为什么 unlock 时没有唤醒我?"
hidden: false
tags: ["Postgresql/Greenplum"]
---

还是我们的 [ADB PG](https://www.aliyun.com/product/gpdb) 测试实例, 收到了测试脚本执行超时的报警, 看了一下发现是由于已经执行很久的 DELETE 持有的锁阻塞了测试脚本中 DDL 的执行, 又看了一下这个 DELETE backend 的堆栈:

```
#0  0x00002b2049a2af67 in semop () from /lib64/libc.so.6
#1  0x0000000000770bc4 in PGSemaphoreLock (sema=0x2b2099b4b3e0, interruptOK=0 '\000') at pg_sema.c:433
#2  0x00000000007c042f in LWLockAcquire (lockid=FirstLockMgrLock, mode=LW_EXCLUSIVE) at lwlock.c:569
#3  0x00000000008b6b77 in ResLockRelease (locktag=0x7fff6005f6e0, resPortalId=0) at resqueue.c:517
#4  0x00000000008b835f in ResLockPortal (portal=0x1b8d980, qDesc=0x1b95e10) at resscheduler.c:704
```

居然是长时间地阻塞在 LWLockAcquire() 之中了, 要知道 lwlock 作为 PG 内部使用的轻量锁机制, 其不应该会被长时间阻塞的. 除非是有 backend 长时间持有着该锁, 但是诡异的是, 该锁当前并未被任何 backend 以任何形式持有着:

```
(gdb) f 2
#2  0x00000000007c042f in LWLockAcquire (lockid=FirstLockMgrLock, mode=LW_EXCLUSIVE) at lwlock.c:569
(gdb) p *lock
$2 = {mutex = 0 '\000', releaseOK = 0 '\000', exclusive = 0 '\000', shared = 0, exclusivePid = 0, head = 0x0, tail = 0x2b2099b54d00}
```

something was wrong, 难道是某次 unlock 忘了唤醒我们了??? 这里先简单介绍下 PG lwlock 实现机制, PG 使用 LWLock 对象来标识一把锁:

```c
typedef struct LWLock
{
    slock_t     mutex;			/* Protects LWLock and queue of PGPROCs */
    bool        releaseOK;		/* T if ok to release waiters */
    char        exclusive;		/* # of exclusive holders (0 or 1) */
    int         shared;			/* # of shared holders (0..MaxBackends) */
    int	        exclusivePid;	/* PID of the exclusive holder. */
    PGPROC      *head;			/* head of list of waiting PGPROCs */
    PGPROC      *tail;			/* tail of list of waiting PGPROCs */
    /* tail is undefined when head is NULL */
} LWLock;
```

这里介绍一下几个值得注意的字段: releaseOK 表明在 LWLockRelease() 时是否应该唤醒等待获取该锁的 waiter, 若为 true, 则表明唤醒, 否则不唤醒. 该字段初始值为 true, 会在 LWLockRelease 发现有 waiter 需要唤醒, 并且准备唤醒这些 waiter 之前置为 false, 之后这些被唤醒的 waiter 在 LWLockAcquire() 后续循环时再次将其置为 true. head, tail 指向着等待获取当前锁的 backend 组成的列表, head 指向着链表头, tail 指向着链表尾, 链表中的 backend 通过 PGPROC::lwWaitLink 链接:

```c
struct PGPROC
{
    // ...
    /* Info about LWLock the process is currently waiting for, if any. */
    bool        lwWaiting;		/* true if waiting for an LW lock */
    bool        lwExclusive;	/* true if waiting for exclusive access */
    struct PGPROC *lwWaitLink;	/* next waiter for same LW lock */
    // ...
}
```

LWLockAcquire() 会在发现无法立即获取到锁时将自己放入到 LWLock waiter 链表中, 之后挂在 PGPROC::sem 上等待被唤醒. LWLockRelease() 在释放掉自身的锁之后, 会从 LWLock waiter 链表中选择待唤醒的 backend, 通过通过 PGSemaphoreUnlock(PGPROC::sem) 来唤醒他们.

所以我在一开始看到 LWLockAcquire(), LWLockRelease() 代码时最初想法是: memory order 导致的, LWLockAcquire() 将自身挂在 waiter 链表的行为对 LWLockRelease 所在 backend 是不可见的, 或者是 LWLockRelease 设置 PGPROC::lwWaiting 的效果对 LWLockAcquire() 所在 backend 不可见. 毕竟我在 LWLockAcquire(), LWLockRelease() 针对这两处数共享数据的读写上未看到任何显式屏障操作, 尤其是 PG SpinLockRelease() 实现仅是一次简单地赋值.  我对 PG 中 memory order 执念的由来可以见 [PG 中的事务: 快照]({{site.url}}/2019/12/01/pgxactsnapshot/). 甚至还由于为啥这种情况单单在这台机器上出现还以为是这台机器 CPU 有点问题, 于是一开始还想着兴师动众地编写一堆测试 demo 来尝试在当前机器上运行同样行为的代码来观察是否会出现 memory order 问题...

幸好这些念头在我捋完 PG lwlock 实现之后被打消了. 这时 GDB 看了下 MyProc 的状态发现确实 lwWaiting, lwWaitLink 已经被清空了:

```
(gdb) p *MyProc
$1 = {,lwWaiting = 0 '\000', lwExclusive = 1 '\001', lwWaitLink = 0x0,}
```

再结合 PGSemaphoreUnlock 的实现:

```
void
PGSemaphoreUnlock(PGSemaphore sema)
{
    int	errStatus;
    struct sembuf sops;

    sops.sem_op = 1;			/* increment */
    sops.sem_flg = 0;
    sops.sem_num = sema->semNum;

    /*
     * Note: if errStatus is -1 and errno == EINTR then it means we returned
     * from the operation prematurely because we were sent a signal.  So we
     * try and unlock the semaphore again. Not clear this can really happen,
     * but might as well cope.
     */
    do
    {
        errStatus = semop(sema->semId, &sops, 1);
    } while (errStatus < 0 && errno == EINTR);

    if (errStatus < 0)
        elog(FATAL, "semop(id=%d,num=%d) failed: %m", sema->semId, sema->semNum);
}
```

想到了一种可能性 semop() 系统调用失败了! 但是由于测试实例日志并未被全量保存, 而且实例日志刷掉太猛, 确实没找到任何 semop 失败的日志. 所以只能假设如果是 semop 失败了会怎么样: 这时 PGSemaphoreUnlock 所在的 backend 会 FATAL 退出, 不会触发 Postmaster 进入 recovery mode. 另外一方面由于 semop 失败导致 LWLockAcquire backend 未被唤醒会导致 LWLock::releaseOk 继续保持为 false, 嗯上面的 GDB 也显示了此时该值确实仍为 false. 那就这样吧: root cause 就认定为由于 semop 失败导致的==! (所以我觉得 PGSemaphoreUnlock() 中 FATAL 应该改为 PANIC 的! 像这里 case, 由于 releaseOk 为 false 导致 LWLockRelease() 时不会执行任何唤醒操作, 会导致越来越多的 backend 永久阻塞在 LWLockAcquire() 中. 仍是我们这个 case, 除了 DELETE 之外, 看了下还有几个 SELECT 也是同样的情况!

那么如果遇到这种情况该怎么恢复呢? 只需要在编写一个小 demo 手动调用相应 semop() 操作唤醒即可, 毕竟 sysv semaphore 是系统级资源, 我们并不需要一定处于 PG 环境下才能操作.

```c
/* Compile with ` -lrt -pthread ` */
#include <errno.h>
#include <stdio.h>
#include <sys/types.h>
#include <sys/ipc.h>
#include <sys/sem.h>
#include <semaphore.h>

typedef struct PGSemaphoreData
{
    int         semId;			/* semaphore set identifier */
    int         semNum;			/* semaphore number within set */
} PGSemaphoreData;

void
PGSemaphoreUnlock(PGSemaphoreData *sema)
{
    int			errStatus;
    struct sembuf sops;

    sops.sem_op = 1;			/* increment */
    sops.sem_flg = 0;
    sops.sem_num = sema->semNum;

    do
    {
        errStatus = semop(sema->semId, &sops, 1);
    } while (errStatus < 0 && errno == EINTR);

    printf("err: %d\n", errStatus);
    return;
}

int main()
{
    PGSemaphoreData d;
    d.semId = 20181218;
    d.semNum = 1145;
    PGSemaphoreUnlock(&d);
    return 0;
}
```

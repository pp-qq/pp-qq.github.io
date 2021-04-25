---
title: "消失"的两阶段事务
hidden: false
tags: ["Postgresql/Greenplum"]
---

在排查完 [消失的两阶段事务]({{site.url}}/2021/02/14/prepared-xact/), 意识到社区已经修复了这个问题之后, 当时大概看了下修复姿势, 就抛之脑后了. 直到最近在实现 [KuiBaDB](https://github.com/hidva/KuiBaDB) xlog 写入以及 redo 链路时, 细细研究了下 PG 的 xlog 写入以及 recovery, 尤其是 timeline 相关的链路. 才意识到社区的修复好像有点问题.

如社区 [PR](http://hidva.com/g?u=https://github.com/greenplum-db/gpdb/pull/10654) 中所示, 社区对如上问题的修复主要是改变了 CreateCheckPoint() 获取两阶段事务信息的姿势. 具体位置如下:

```c
if (InRecovery)
{
    getTwoPhasePreparedTransactionDataInRecovery(ptas);
    return;
}
```

这里在 pg xlog recovery 时, InRecovery 总是为 true, 通过在 CreateCheckPoint() 中添加如上代码, 使得 END_OF_RECOVERY 对应的那次 CreateCheckPoint() 不再从 TwoPhaseState 中获取两阶段事务, 而是直接从 crashRecoverPostCheckpointPreparedTransactions_map_ht 中获取. 这部分对于 primary crash recovery 是没啥问题的.

但对于 miror 提升到 primary 链路时好像有点问题. 主要是对于 mirror, 其 checkpointer process 会在 xlog replay 之前便启动, 负责 mirror restart point 的执行, 而且针对 mirror 提升到 primary 链路, 其 CreateCheckPoint() 并不会发生在负责 xlog replay 的 startup process, 而是发生在 checkpointer process, 即如下代码所示:

```c
if (bgwriterLaunched)
{
    if (LocalPromoteIsTriggered)
    {
        checkPointLoc = ControlFile->checkPoint;
        record = ReadCheckpointRecord(xlogreader, checkPointLoc, 1, false);
        if (record != NULL)
        {
            promoted = true;
            CreateEndOfRecoveryRecord();
        }
    }

    if (!promoted)
        RequestCheckpoint(CHECKPOINT_END_OF_RECOVERY |
                            CHECKPOINT_IMMEDIATE |
                            CHECKPOINT_WAIT);
}
```

对于 mirror 提升为 primary 链路, 如上代码块中 bgwriterLaunched = true, 即 startup process 会通过 RequestCheckpoint() 来请求 checkpointer process 创建一次 END_OF_RECOVERY checkpoint. 这就有个问题了, InRecovery 这个全局状态只在 startup process 中存在, 在 checkpointer process, 这个状态始终是 false, 也即 mirror END_OF_RECOVERY checkpoint 获取两阶段的方式还是通过尚未填充的 TwoPhaseState, 即此时 mirror checkpoint 拿到的两阶段事务为空. 如果 mirror 在提升为 primary 之后, 在完成这次错误的 checkpointer 之后, 在 startup process 正常退出之后, 在接收 QD 两阶段事务恢复请求之前 PANIC 进入 crash recovery 模式, 那么在 recovery 时由于最近一次 checkpoint 中不包含两阶段事务, 导致 mirror 会认为自身没有任何待处理的两阶段事务.

当然此时两阶段事务在 QD 中也是有记录的, 所以 QD 仍会 retry commit prepared/abort prepared, 但此时已经提升为 primary 的 mirror 会由于没有残留两阶段事务而误认为事务已经处理, 从而对于 QD 下发的 retry commit prepared/abort prepared 请求都会返回 SUCCESS 导致 QD 认为分布式事务已经提交:

```c
gxact = LockGXact(gid, GetUserId(), raiseErrorIfNotFound);
if (gxact == NULL)
{
   /*
    * We can be here for commit-prepared and abort-prepared. Incase of
    * commit-prepared not able to find the gxact clearly means we already
    * processed the same and committed it. For abort-prepared either
    * prepare was never performed on this segment hence gxact doesn't
    * exists or it was performed but failed to respond back to QD. So,
    */
}
```

这就会导致一个尴尬的情况, master 认为一个分布式事务成功提交, 但实际上这个事务在某个 segment 上并未成功提交, 而导致用户看到不一致的数据.

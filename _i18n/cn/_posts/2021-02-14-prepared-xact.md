---
title: "消失的两阶段事务"
hidden: false
tags: ["Postgresql/Greenplum"]
---

大年三十, 忽然收到之前搭建的 gp 集群 mirror xlog 堆积的报警, 本来没太当回事, 以为又是想往常一样, 要么是 mirror replay wal 时太慢了, 要么是有个两阶段事务一直没有结束导致. 又忽然想到, 如果是两阶段事务一直没有结束, 那么 primary, mirror 应该要一起 xlog 堆积的. 所以八成是 mirror replay wal 又慢了. 但登陆上去的时候才发现, mirror replay 的并不慢, 完全紧跟着 primary 的进度..

不得以上了下 gdb, 看了下居然是 `TwoPhaseState->oldestPrepRecPtr` 导致的, 而 oldestPrepRecPtr 是在 mirror 遇到 checkpoint xlog record 时调用 SetOldestPreparedTransaction() 计算出来的, 依据的是当前系统中尚未结束的两阶段事务, 即 crashRecoverPostCheckpointPreparedTransactions_map_ht 这个 hashtab 中的信息. 这里简单介绍下 gp 两阶段事务中对 prepared 事务的管理, gp 会将 prepared 事务的 xid 以及 prepare xlog record 的 LSN 保存起来, 之后在 prepared 事务被 commit prepared/rollback prepared 时会根据 LSN 取出 prepare record 之后做处理. 这意味着 prepared 事务的 prepare xlog record 所在文件要一直保留着直至 prepared 事务被 commit/rollback. 而 crashRecoverPostCheckpointPreparedTransactions_map_ht, 其结构类似 `HashMap<Xid, LSN>`, 保存着尚未结束的 prepared 事务的 xid 以及对应的 LSN 信息. `TwoPhaseState->oldestPrepRecPtr` 则是 crashRecoverPostCheckpointPreparedTransactions_map_ht 中最老的那个 LSN, `TwoPhaseState->oldestPrepRecPtr` 所在 xlog 文件一定要保留不能删掉. 这也是为何 mirror xlog 堆积的原因.

等等, 又是一直没有结束的两阶段事务? 为啥 primary 没有 xlog 堆积?!. 而且到底是哪些尚未结束的 prepared 事务导致的? 也即意味着需要 dump 出 crashRecoverPostCheckpointPreparedTransactions_map_ht 的内容看下. 幸好之前针对 pg hashtab 结构编写了 dump pg hashtable 的 gdb 脚本. 看下是哪个两阶段事务一直没有结束:

```gdbinit
define printkey
    p *((TransactionId*)$arg0)
end

define printbucket
    set $bucketptr = (HASHELEMENT*)$arg0
    while $bucketptr
        set $keyptr = (((char *)($bucketptr)) + (((long int) ((sizeof(HASHELEMENT))) + ((8) - 1)) & ~((long int) ((8) - 1))))
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
```

```gdb
(gdb) printhash crashRecoverPostCheckpointPreparedTransactions_map_ht
$1 = 4773565
```

可以看到 mirror 中只有 4773565 这一个未结束的 prepared 事务, 继续回到之前的问题, 为啥这个事务没有导致 primary xlog 堆积呢? 毕竟如果这个事务真的没有结束, primary 也是要保留这个事务对应 prepare record 所在 xlog 文件的. 先看下这个事务在 mirror 中关联的 xlog record 记录, 看下是否有对应的 commit prepared/rollback prepared record:

```
$ pg_xlogdump -t 3 -x 4773565 00000003000004E90000002F
rmgr: Transaction len (rec/tot):  336/  368, tx: 4773565, lsn: 4E9/BFCFA2F8, prev 4E9/BFCFA120, bkp: 0000, desc: prepare
```

可以看到确实没有对应的 commit prepared/rollback prepared xlog record. 这里多提一句, gp 原生的 pg_xlogdump -x 选项只会根据 XLogRecord::xl_xid 字段来过滤, 而对于 commit prepared/rollback prepared, 这俩语句不能运行在事务块中, 对应 XLogRecord::xl_xid 字段总是为 0, 所以 gp 原生 pg_xlogdump -x 将无法显示事务关联的 commit prepared/rollback prepared 日志. 但我之前对 pg_xlogdump 魔改了一番, 会根据 xlog record 类型, 尽可能地提取出 xlog record 关联的事务 xid, 之后会以这个 xid 来过滤. 所以如上 pg_xlogdump 的输出意味着确实没有 commit prepared/rollback prepared 日志.

而且 primary 上的 xlog file 已经经过多次回收, 早已经没有了 4773565 事务关联的任何 record 了. 并且通过 utility 模式链接 priamry, select pg_prepared_xacts 看了下确实没有尚未结束的两阶段事务. 为了更进一步确定, 根据 primary pg_control 中对应的 checkpoint 信息从 xlog 中提取了最近两次 checkpoint record 的内容, 看到了 prepared transaction agg state count = 0, 意味着确实没有进行中的两阶段事务了:

```
$ pg_xlogdump -t 3 -s 50C/C6E5FF28 -n 1
rmgr: XLOG        len (rec/tot):     92/   124, tx:          0, lsn: 50C/C6E5FF28, prev 50C/C6E5FD78, bkp: 0000, desc: checkpoint: DTX committed count 0, DTX data length 4, prepared transaction agg state count = 0
```

从 primary 4773565 事务在 clog 中对应的记录可以看到, 4773565 对应的 xid status = 0, 即 TRANSACTION_STATUS_IN_PROGRESS.

```
$ python -c "print 4773565 - 1048576 * 4"
579261
$ python -c "print 579261/4, 579261 % 4"
144815 1
$ od -A d -t x1z -j 144815 -N 1 pg_clog/0001
0144815 51   >Q<
0144816
$ python -c 'print bin(0x51)'
0b1010001
```

但 gdb primary 看了下快照中确实没有了 4773565 这个事务了. 即 primary 侧认为 4773565 事务 crash 了, 没有被显式的 commit/rollback. 没办法, 只能尝试通过 primary pg_log 中的信息来看看有没有些蛛丝马迹了. 可以看到 primary 时间线如下所示:

```
2021-02-09 09: 34: 20 CST; LOG: latest completed transaction id is 5123530 and next transaction id is 5123531
2021-02-09 09: 34: 20 CST; LOG: recovering prepared transaction 4773565
2021-02-09 09: 34: 20 CST; LOG: database system is ready
2021-02-09 09: 34: 23 CST; LOG: received immediate shutdown request
2021-02-09 09: 35: 31 CST; LOG: latest completed transaction id is 5123530 and next transaction id is 5123531
2021-02-09 09: 35: 31 CST; LOG: database system is ready
```

可以很明确看到在 09: 34 那次启动时, 4773565 这个 prepared 事务在 primary 还是存在的, 并且 primary 还是明显知道 4773565 这个事务已经 prepared, 但还没有 commit/rollback. 但在 09: 35 那次启动时, 4773565 这个 prepared 事务就被 primary 看不到了, 在 09: 35 那次重启中, primary 认为没有任何尚未结束的 prepared 事务. 之前提到过 gp 会将两阶段事务保存在 checkpoint 中, 并且在重启时会根据 checkpoint 中信息来恢复两阶段事务. 所以这意味着 09: 35 那次重启时从 checkpoint record 中没有看到任何未结束的 prepared 事务. 也即意味着 09: 34 那一秒生命周期中最后一次生成的 checkpoint record 中没有记录 4773565 这个未结束的事务. 根据日志, 在 09: 34 这一秒中, gp 至少有两处会生成 checkpoint:

1.  在完成所有 xlog redo 之后, 会 CreateCheckPoint().
2.  在 shutdown 时, 也会 CreateCheckPoint().

考虑到 09: 34 那次是 immediate shutdown, 不会触发 checkpoint, 所以意味着 primary 在 09: 34 那一秒生命周期中完成所有 xlog redo 之后, 生成的 checkpoint record 中没有记录 4773565 这个尚未结束的 prepared 日志. 看了下代码很明显会保存尚未结束的 prepared 事务的嘛.

```c
prepared_transaction_agg_state *p = NULL;
getTwoPhasePreparedTransactionData(&p);  // 获取尚未结束的两阶段事务
// 将获取到的尚未结束的两阶段事务序列化到 checkpoint record 中.
rdata[2].data = (char*)p;
```

继续看了下 getTwoPhasePreparedTransactionData() 实现. 嗯, 是从 TwoPhaseState 结构中获取尚未结束的两阶段事务, 很合理嘛. 等等!!! TwoPhaseState???!!! 这时候 TwoPhaseState 结构还没有填充来着!!! 这时候两阶段事务信息还是保存在 crashRecoverPostCheckpointPreparedTransactions_map_ht 这一坨中的. gp 会在 xlog redo 结束之后, 在 CreateCheckPoint() 之后, 才会调用 RecoverPreparedTransactions() 将 crashRecoverPostCheckpointPreparedTransactions_map_ht 中结构转换保存到 TwoPhaseState 中. emmmm... 好吧, 所以在 xlog redo 之后, CreateCheckPoint() 生成的 checkpoint record 总是拿不到任何尚未结束的两阶段事务的. 所以在 09: 35 重启时, 根据 checkpoint 中信息认为系统中没有任何尚未结束的 prepared 事务了. 所以总算搞清楚了 primary 是如何丢失了 477355 这个 prepared 事务的了...

在后续准备给社区 gp 提 issue 时, 也发现社区已经修复了[这个问题](https://github.com/greenplum-db/gpdb/pull/10654), 只不过社区修复的是同一个 bug 另外一种表象. 即由于 CreateCheckPoint 可能回收了 prepared 事务对应 prepare record 所在 xlog file 导致 RecoverPreparedTransactions() 失败.





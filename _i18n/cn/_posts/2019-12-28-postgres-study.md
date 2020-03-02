---
title: "PG/GP 学习杂烩"
hidden: true
tags: ["Postgresql/Greenplum"]
---

这里记录着对 Postgresql/Greenplum 代码学习期间总结记录的一些东西, 这些东西大多篇幅较小(或者质量不高...), 以至于不需要强开一篇 POST.

## pg_xlogdump

pg_xlogdump, 用来 dump xlog segment file, 我们这里介绍一下 pg_xlogdump 的使用姿势. pg_xlogdump 的主要意图便是 dump 指定 start LSN, end LSN 区间内的所有 xlog record. 其中 LSN 给定形式是: logid/recoff, 其中 logid 为 LSN 的高 32 位, recoff 为 LSN 的低 32 位. 比如 LSN 22411048 便对应着 '0/155f728', 没有 '0x' 前缀. 

之后 pg_xlogdump 会根据 start LSN 计算出相应的 segment filename, 然后再在指定的路径列表下搜索 segment file, 若找到则打开 segment file 并开始 dump 工作. 这里搜索路径列表包括 '.' 当期目录, './pg_xlog' 等.

pg_xlogdump 的 start LSN, end LSN 除了显式给定之外, 还可以通过 segment filename 指定, 对于 start LSN 来说, 由 segment filename 计算出来的 LSN 便是 start LSN. 对于 end LSN 来说, 由 segment filename 计算出来的 LSN 再加上 segment filesize(默认: 16M)之后才是 end LSN.

## 为啥 PG 中要持久化 cmin/cmax?

按照 PG 说法: 对 cmin/cmax 的持久化主要是用来判断事务内的可见性, 若事务内 SQL A 在扫描时发现某行 cmin 发生在自身 commandId 之前, 那么它就晓得这行对自己是可见的. 但这就有一个问题了: PG 中事务内的 SQL 总是串行执行的, 所以若 SQL A 扫描时发现某行 xmin 等于自身事务, 那么它就晓得这行是自身事务插入的, 即这行肯定是同一事务内在 SQL A 之前的 SQL 插入的, 也即这行对 SQL A 来说是可见的. 不过话说 PG 中 SQL 在扫描时能否看到自己插入的行呢? 如果能看到自身插入的行, 那么语义上这些行对自身是否应该是可见的呢? 如果 PG 中 SQL 扫描上可能会看到自身插入的行, 并且我们从语义上规定这些行对自身是不可见的, 那么我们确实需要 cmin 这个值来判断一下. 

但目前来看 PG 中 SQL 在执行时应该是不会看到自身插入的行的, 毕竟 PG planner 针对 INSERT/UPDATE/DELETE SQL 生成的执行计划中, 负责实际插入/更新的 ModifyTable plan node 总是位于 plan tree 最顶层, 即当实际插入/更新操作发生时, 扫描操作已经执行结束了. 那么为啥还需要 cmin 呢?

后来和同事讨论了一下, cmin 的目的应该主要还是在于实现事务隔离级别. PG SnapshotData 中是有 curcid 这个字段记录着当前快照对应的 commandid 的, 在持久化 cmin 的情况下, 某个特定 tuple 是否对特定的 snapshot 是否可见就可以直接比较 tuple 中的 cmin 与 snapshot 中的 curcid 就行. 之后对于 Read Committed 隔离级别下的事务, 由于其 snapshot 每次查询时都会获取, 因此其 SnapshotData.curcid 为待执行查询对应的 commandid, 在 tuple 可见性判断时, 其就能看到同一事务内之前查询执行的效果. 对于 Repeat Read 隔离级别的事务, 其 snapshot 在事务开始时获取, 即 SnapshotData.curcid 取值为 0, 因此其看不到自身事务查询执行的效果.

但如果仅是这目的的话, 我们也可以通过在 SnapshotData 加个字段指定其所在事务的事务隔离级别, 之后在可见性判断时, 针对同一事务更新的 tuple, 若 snapshot 指定事务隔离级别是 Read Commited, 那么 tuple 对自身可见. 若 snapshot 指定事务隔离级别是 Repeat Read, 那么 tuple 则对自己不可见. 

所以还是不晓得是否真的需要 cmin/cmax..

## PG 中一条 Query 的旅程.

这里介绍 PG 中对于一条 Query 是如何处理的, 尤其是在不同阶段 Query 的各种中间表示. 

在最开始时, Query 就是一个 C 字符串. PG Parser 在收到这个字符串之后通过 scan.l, gram.y 等工具将其转换为 Parse Tree. 在 PG 中, Parse Tree 没有一个统一的表示, 不同类型的 SQL 对应着不同的 Parse Tree, 如 Create Table AS 语句对应着 CreateTableAsStmt parse tree, PG 支持的各种类型 Parse Tree 都在 parsenodes.h 文件中定义. 可以通过 gram.y 来获悉某个类型的 SQL 对应的 parse tree. parse 这步是纯粹地语法解析, 此时 PG 未做任何语义上的处理, 比如查询 system catalog 来判断一个 FuncCall 是普通的函数调用还是聚合函数调用.

之后, PG transformation process 开始接手处理 PG Parser 生成的 parse tree, 此时 PG 会根据需要查询 system catalog, 进行各种语义处理, 最终生成一个 Query 对象来保存处理后的结果. 在 PG 中, 将各种类型的 SQL 分为两大类: Utility statement, Non-utility statement, utility statement 不需要被优化器做优化处理, 比如 LISTEN/NOTIFY 就是 utility statement. 而 non-utility statement 需要被优化器优化, 对应着最常见的 SELECT/INSERT/UPDATE/DELETE 语句等. 如 Query struct 注释中说明: utility statement, non-utility statement 都使用 Query 来表示.

再之后, PG rewrite system 开始接手处理生成的 Query 对象, 其会根据用户定义的 rule system 规则对 Query 进行改写, rewriter 的结果仍是 Query 对象. PG 中 view 便是使用 rewrite system 实现的, 当 PG 在 Query 对象中遇到 view 时, 会将 view 展开为其对应的语句.

再之后, 针对 non-utility statement, PG planner 会对他们进行各种优化, 最终生成 PlannedStmt 对象. PlannedStmt 可以简单地看做是一堆 plan node 组成的 tree. 在 Planner 期间, Planner 会用到 Path node 组成的 path tree 来表示各种可行的执行路径, Path node 可以看做是 plan node 的阉割版, 其内只保存着足够 planner 作决策所需要的信息, 比如 cost 等, path node 都继承自 Path 类. PlannedStmt 中每个 plan node 都继承自 Plan 类, 都可认为实现了如下方法:

```c
void* NextTuple();
```

NextTuple() 返回该 plan 获取到的下一行数据, 若返回 NULL 则表明当前 plan node 已经执行完毕, 不会再返回任何行了. 每个 plan node 在实现自己 NextTuple() 逻辑时, 都会调用其子节点的 NextTuple() 方法来获取输入, 之后对输入行进行一些处理之后返回. 

所以 executor 的实现可以简单认为就是反复调用 PlannedStmt 中最顶层 plan node 的 NextTuple() 方法, 直至返回为 NULL. 所以 PG 并未像 presto 那样, 算子(也即 plan node)之间通过 page 来通信, 一个 page 中包含了很多行, 从而来实现 batch 化. 或许我们可以搞个优化....

而对于 utility statement, 他们的执行并不需要优化器来做各种优化, 直接根据各自 utility 语义按照规则执行即可. utility 语句执行入口见 ProcessUtility().

## PG 9.6

>   记录了对 PG9.6 文档的学习总结

log shipping; Directly moving WAL records from one database server to another is typically described as log shipping. PG 中有 file-based log shipping, 以及 Record-based log shipping. 顾名思义, file-based log shipping 是指一次传递一个 xlog segment file. record-based log shipping 是指一次传递一个 xlog record.

warm standy, 基于 log shipping 技术实现, 简单来说便是 standby server 通过一次 basebackup 启动之后, 接下来会不停地从 primary 上读取 xlog 并应用. 在此过程中, standby 会周期性地执行类似 checkpoint 的机制, 即 restartpoint. 使得在 standby 收到 activate 信号之后, 其只需要消费完最后一次 restartpoint 之后的 xlog records, 便可提供可用服务, 这个时间窗口往往很短暂. 这也正是被称为 "warm" standby 的原因. 在 '26.2.2. Standby Server Operation', 介绍了 standby server 的大致流程, 即 standby server 被拉起之后执行的操作序列. 在 '26.2.3', '26.2.4' 中介绍了为开启 warm standby, standby server 以及 primary 所需的配置. 

hot standby, A warm standby server can also be used for read-only queries, in which case it is called a Hot Standby server. 我个人对这块技术兴致泛泛..

Streaming replication; 便是 PG 实现 record-based log shipping 的技术. 当 standby server 使用 Streaming replication 时, 会创建个 wal receiver 进程, wal receiver 会使用 '51.3. Streaming Replication Protocol' 中介绍地协议连接 primary, 之后 primary 会为此创建一个 wal sender 进程, 之后 wal sender 与 wal receiver 会继续使用着 Streaming Replication Protocol 进行通信以及数据交互. 参考 '26.2.5.2. Monitoring' 节了解如何查询 wal sender, wal receiver 的状态.

Replication Slots, PG 引入 replication slots 主要是为了解决两个问题:

-   wal segment 被过早回收, 在 replication slot 之前是通过 wal_keep_segments 或者 wal archive 来解决的.
-   rows 被 vacuum 过早回收, 在此之前是通过 hot_standby_feedback 与 vacuum_defer_cleanup_age 解决.

参考 '26.2.6. Replication Slots' 了解 replication slots 如何创建, 以及如何查询当前 replication slots 状态等.

Synchronous Replication; When requesting synchronous replication, each commit of a write transaction will wait until confirmation is received that the commit has been written to the transaction log on disk of both the primary and standby server. Read only transactions and transaction rollbacks need not wait for replies from standby servers. Subtransaction commits do not wait for responses from standby servers, only top-level commits. Long running actions such as data loading or index building do not wait until the very final commit message. All two-phase commit actions require commit waits, including both prepare and commit. 与此相关的有两个 GUC: synchronous_commit, synchronous_standby_names. 

archive_mode GUC; 目前一个 PG 实例可以有三种工作模式: archive recovery, standby, normal. archive_mode 控制着在这三种模式下, wal archiver 的行为. 这里 'archive recovery' 模式是指 '25.3. Continuous Archiving and Point-in-Time Recovery (PITR)' 中新 server 会处于的一种模式.

checkpointer process, 由 postmaster 启动的一个常驻进程, 负责 checkpoint 的执行. checkpointer process 会在指定条件满足时执行 checkpoint, 这些条件包括: max_wal_size, checkpoint_timeout, 或者用户手动执行了 CHECKPOINT 语句等. 在 checkpoint 执行时, a special checkpoint record is written to the log file. Any changes made to data files before that point are guaranteed to be already on disk. In the event of a crash, the crash recovery procedure looks at the latest checkpoint record to determine the point in the log (known as the redo record) from which it should start the REDO operation. 

因此若想临时性关闭 checkpoint, 只需要无限增大 max_wal_size, checkpoint_timeout 即可.

控制 The number of WAL segment files 的因素: min_wal_size, max_wal_size, the amount of WAL generated in previous checkpoint cycles, wal_keep_segments, wal archiving, replication slot 等, 详细了解的话可以参考 '30.4. WAL Configuration'.

restartpoints, In archive recovery or standby mode, the server periodically performs restartpoints, which are similar to checkpoints in normal operation: the server forces all its state to disk, updates the pg_control file to indicate that the already-processed WAL data need not be scanned again, and then recycles any old log segment files in the pg_xlog directory. Restartpoints can’t be performed more frequently than checkpoints in the master because restartpoints can only be performed at checkpoint records. A restartpoint is triggered when a checkpoint record is reached if at least checkpoint_timeout seconds have passed since the last restartpoint, or if WAL size is about to exceed max_wal_size.

PITR, 也即 online backup. 与此相对的是 offline backup, offline backup 操作简单粗暴: 关停集群, 拷贝数据目录, 基于新数据目录重新启动集群. 在 online backup 期间, 会强制开启 full page write 特性, 这时因为 online backup 得到 base backup tar 包中的 page 可能是部分写入的, 因此需要 force full page write 来修正.

exclusive/non-exclusive basebackup. Low level base backups can be made in a non-exclusive or an exclusive way. The non-exclusive method is recommended and the exclusive one is deprecated and will eventually be removed. A non-exclusive low level backup is one that allows other concurrent backups to be running (both those started using the same backup API and those started using pg_basebackup).

### 继承与分区

table inheritance, 子表会从父表上继承列定义以及相关约束, 当同名列在继承层次中多次出现, then these columns are “merged” so that there is only one such column in the child table. 合并主要是合并了 Inheritable check constraints and not-null constraints.

继承关系的创建与变更, 可以通过 CREATE TABLE 时 INHERITS 子句来指定关联的父表, 也可以后续通过 ALTER TABLE 来动态修改.

各种 SQL 行为在继承下的表现: 

-   SELECT/UPDATE/DELETE 默认包括子表的数据, 这一行为可以通过 sql_inheritance GUC 控制. 使用 ONLY 修饰可以禁止对子表数据的包含. 使用 `*` 来修饰表名可以显式指定包含子表数据. 
-   INSERT/COPY 只会将数据插入到父表中. 可以理解这一行为, 并且 INSERT 默认也不晓得如何将数据插入到子表
-   ALTER TABLE will propagate any changes in column data definitions and check constraints down the inheritance hierarchy
-   Commands that do database maintenance and tuning (e.g., REINDEX, VACUUM) typically only work on individual, physical tables and do not support recursing over inheritance hierarchies.
-   indexes (including unique constraints) and foreign key constraints only apply to single tables, not to their inheritance children. 

分区; 在 PG 中可以利用继承这一特性来实现分区, 具体步骤参考 '5.10.2. Implementing Partitioning'. 关于 INSERT 路由这里, 除了像 5.10.2 中介绍通过触发器之外, 还可以通过 REWRITE RULE, 参考 '5.10.5. Alternative Partitioning Methods'. 这俩优缺点参考 5.10.5 中介绍. 另外 5.10.5 还介绍通过 VIEW 实现分区表的姿势. 注意对于带有 ON CONFLICT 的 INSERT 来说, 无法是触发器还是 REWRITE RULE 路由, 效果都可能不符合预期.

Constraint exclusion; 参考 '5.10.4. Partitioning and Constraint Exclusion' 介绍. 简单来说, 就是 planner 根据表 check 约束中的信息可以得知表中不包含查询需要的数据, 因此可以避免对该表的扫描操作. All constraints on all partitions of the master table are examined during constraint exclusion, so large numbers of partitions are likely to increase query planning time considerably. Partitioning using these techniques will work well with up to perhaps a hundred partitions; don’t try to use many thousands of partitions.


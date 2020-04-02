---
title: "PG/GP 学习杂烩"
hidden: true
tags: ["Postgresql/Greenplum"]
---

这里记录着对 Postgresql/Greenplum 代码学习期间总结记录的一些东西, 这些东西大多篇幅较小(或者质量不高...), 以至于不需要强开一篇 POST. 若不特殊说明, 本节内容来源于 PG9.6 文档 + PG 9.6 的代码. 或者 GP 6.4 文档 + GP master 代码, 具体 commit id: 53d12bd56fd124fa1b0bcd0d72ff7cf69f0bd441.

## GP 与 presto

GP 与 presto 的分布式执行框架完全类似. 在 [presto 文档](https://prestodb.io/docs/current/overview/concepts.html) 中所涉及到的每一个概念都可以在 GP 中找到对等的概念. 在 presto 中, 每一个 driver 处理一个 split, driver 内 operator 每次以 page 为单位来读取数据, page 采用了列式存储的方式存放了多行数据, page 内使用 block 来存放一列内容. presto 中 driver 就类似于 GP 中的 slice, 而 presto task 就类似于同一个 slice 在 GP 中同一台机器上所有 primary segment 上的集合. 简单来说: 假设一个 presto 集群有 4 个 worker, 某个表 t 有 16 个 split, 那么 presto 一个 task 在一个 worker 上会有 4 个 driver, 每个 driver 消费一个 split 的数据. 这就对应着一个 GP 集群, 有 4 台机器, 每台机器上有 4 个 primary segment.

只是在 presto 中算子之间是以 page 为单位来交换数据的, 而 GP 中是以行为单位交换的. 

## Greenplum 中的分布式事务

分布式事务 ID, 有两部分组成: timestamp, dxid. 其中 timestamp 为实例启动时的时间戳, 在 tmShmemInit() 中被初始化为 `time()` 返回值, 之后在实例运行期间一直保持不变. dxid 是一个简单地计数器, 其在实例启动时在 tmShmemInit() 中被初始化为 1; 函数 currentDtxActivate() 会负责为当前分布式事务分配一个 dxid. 目前看仅当 query 需要 write 时才会分配 dxid, 以及显式 BEGIN 开启事务时也会分配. 当 dxid 到达 0xffffffff 时, 表明在当前实例生命周期内无法再分配 dxid 了, 因此系统会 PANIC 重启. 

分布式事务 ID 的比较. 很简单, 先比较 timestamp, 再比较 dxid 即可. 但一般情况下比较中的两个分布式事务, 总是有一个事务是在实例当前生命周期分配的, 即 timestamp 与实例 tmShmemInit() 初始化值一致. 此时若另外一个分布式事务 B.timestamp 与该事物 A 不一致, 则表明另外一个是事务是在实例之前生命周期分配的, 所以 B 会被认为早于 A. 

分布式事务快照. GP 中针对 distributed transaction id, distributed snapshot 的实现基本上就是把 PG 中 xid, snapshot 的实现照搬了一遍, 只不过是把事务的概念扩展到分布式事务. 关于 PG 中 xid, snapshot 的介绍可参考 [PG 中的事务: 快照]({{site.url}}/2019/12/01/pgxactsnapshot/). 这篇文章中所用到的设施都可以在 GP 中找到对等的实现, 比如与 xid 对应的是 distributed transaction id, 即 gxid. 与 `ShmemVariableCache->latestCompletedXid` 对应的是 `ShmemVariableCache->latestCompletedDXid`, 与 XidGenLock 对应的是 shmGxidGenLock 这个 lock, 与 PGXACT 对应的结构是 TMGXACT 等等.

TMGXACT; 这个结构起到了 PG 中 PGXACT 的作用, 其内存放着当前 backend 分布式事务相关的一些信息.

DistributedSnapshot; GP 中使用 DistributedSnapshot 表示正在运行着的分布式事务. 此时 distribTransactionTimeStamp 表明这些分布式事务 timestamp 部分的值. 因为这些运行中的分布式事务都是在实例当前生命周期内分配的, 因此他们具有相同的 timestamp 取值. distribSnapshotId 为分布式快照 id. 下一个待分配的快照 id 存放在 shmNextSnapshotId 中, 其指向的空间由 tmShmemInit() 负责分配并初始化为 0. xminAllDistributedSnapshots 对应着 PG 中 RecentGlobalXmin 取值, 相当于是所有连接 TMGXACT::xminDistributedSnapshot 的最小值. 剩下的 xmin, xmax, inProgressXidArray 就类似于 PG SnapShotData 中相应成员, 只不过是分布式事务 dxid.

CreateDistributedSnapshot() 根据当前情况构造一个分布式快照. 类似于 PG 的 GetSnapshotData. 分布式事务 dxid 在函数 currentDtxActivate 中分配. 这里使用 shmGxidGenLock 来进行同步, 该 lock 类似于 PG 的 XidGenLock. 

GP 分布式事务的大致实现. 每次用户在 GP 中开启一个 distributed transaction 时, 位于每个 segment 上归属于当前 session 的 segmates 中的 writer backend 就会开启一个 local transaction, 之后 distributed transaction 的所有行为都发生在每个 segment 的 local transaction 中. 当 distributed transaction 被提交时, master 上的 QD 就会下发 PREPARE TRANSACTION 命令给每一个 local transaction, 在所有 local transaction 正确地完成 PREPARE 之后, QD 接着会下发 COMMIT PREPARED 命令给所有 local transaction 来完成每个 local transaction 的提交. 当所有 local transaction 提交完毕之后, 整个分布式事务也便认为已经提交完成了. COMMIT PREPARED 理论上总应该是成功的, 若真的不幸有某个 segment 上 COMMIT PREPARED 失败, 那么 GP 就会反复重试该操作. GP 这里并未像 PG clog 那样维护着每个事务的提交状态, 因为 global transaction 的提交状态就等同于其 local transaction 的提交状态, 即对于分布式事务 A, 若我们发现其在某个 segment 上对应局部事务 B 是 commited, 那么 A 在其他 segment 上对应的局部事务也总是提交的. 

RecentGlobalXmin. 考虑到分布式事务的存在, GP 中的 segment 的 RecentGlobalXmin 并不能直接是原 PG GetSnapshotData 逻辑计算的结果. 考虑分布式事务 A 在三个 segment 各对应着 local transaction lx1, lx2, lx3. 当 A 提交时, 其会对三个 segment 下发 COMMIT PREPARED 提交 lx1,lx2,lx3. 但三个 segment 并不可能同一时间完成三个事务的提交, 可能会出现 lx1, lx3 提交了, lx2 正在提交中. 此时在 lx1 segment 上计算 RecentGlobalXmin 将会是 latestCompletedXid + 1, 即 lx1 + 1. 但此时 lx1 对应的分布式事务还没有提交呢, 所以这里计算出来的 global xmin 有点大了. GP 中通过 DistributedLogShared->oldestXmin 来维护着每个 segment db global xmin 的取值. oldestXmin 要满足语义: 小于 oldestXmin 的 local transaction 对应的 global transaction 都已经结束. 在实例启动时, 其会被初始化, 具体初始化逻辑还未看, 我理解应该会初始化为下一个 xid. 之后 GP 会在 GetSnapshotData() 调用时通过函数 DistributedLog_AdvanceOldestXmin() 来前移 oldestXmin. 在 DistributedLog_AdvanceOldestXmin 调用参数中: oldestLocalXmin 为 PG GetSnapshotData 根据 local transaction 信息计算出来的 RecentGlobalXmin, distribTransactionTimeStamp,xminAllDistributedSnapshots 是分布式事务下 global xmin, 即任何在其之前发生的分布式事务都已经结束了. DistributedLog_AdvanceOldestXmin 的逻辑很简单, 其会从  DistributedLogShared->oldestXmin 遍历到 oldestLocalXmin, 对于这里面每个 xid 都获取到对应的 global dxid, 若此时 global dxid < {distribTransactionTimeStamp,xminAllDistributedSnapshots}, 则会前移  DistributedLogShared->oldestXmin, 直至到达 oldestLocalXmin. 在实现上 DistributedLog_AdvanceOldestXmin 可能会被同一个 segment 属于不同 segmate 的 writer 并发调用. 我理解这时安全的操作. 另外 DistributedLog_AdvanceOldestXmin 中使用 TransactionIdPrecedes 来比较 dxid 是一个 bug. 参见 [PR](https://github.com/greenplum-db/gpdb/pull/9723).

DistributedLog. GP 通过该模块存放着每个 local xid 对应的 distribute xid. 该模块采用了类似 clog 的机制来管理, 其也使用了 SLRU 实现 cache. 该模块中每个 local xid 对应着 8bytes, 存放着 local xid 对应的 global transaction id. 仅当 local xid 被提交时, 即 COMMIT PREPARED 时, GP 才会将 local xid 以及对应的 global transaction id 通过函数 DistributedLog_SetCommittedWithinAPage() 写入. 

distributed log 会被周期性地截断, 以节省存储空间. 函数 DistributedLog_AdvanceOldestXmin() 负责完成这一过程. 这里截断操作是安全的, 不会导致任何有损数据安全性的风险. 因为 DistributedLog_AdvanceOldestXmin() 内总是截断 DistributedLogShared->oldestXmin 之前的 local transaction 对应的 distributed log 信息. 这些 local transaction 对应的分布式事务总是已经结束了的, 也即针对这些分布式事务的提交状态, 我们只需要查看 local transaction 的提交状态即可. 也即我们再也不会关心这些 local transaction 对应分布式事务的相关信息了.

DistributedLog_CommittedCheck() 读取 DistributedLog 返回一个 local xid 对应着的 global transaction id. 这里之所以名字中包含 "committed check" 主要是因为只有被提交的 local xid 其对应的 global transaction id 才会被写入, 所以若能够从 DistributedLog 中读取到 local xid 对应的信息, 那边表明该 local xid 已经是提交了的. 若未能在 distributed log 找到对应信息, 则要么是这些 local transaction 提交了, 只不过对应的 distributed log 信息被 DistributedLog_AdvanceOldestXmin 截断了. 要么是因为这些 local transaction abort 了. 也即总是需要结合 clog 信息来做判定. 

cdblocaldistribxact.c. 其内 cache 了 local xid 与其对应 dxid 的信息, 减少了对 DistributedLog 文件的访问. 其内使用 LRU 策略来管理 cache 的换入换出. 涉及到的结构有: LocalDistribCacheHtab, 类似于 `std::unordered_map<localxid, LocalDistribXactCacheEntry>`, 负责存放所有被 cache 的 local xid 以及 dxid 组合. LocalDistribXactCache, 扮演了 LRU cache 实现中双链表的角色, 其结构类似于 `std::list<LocalDistribXactCacheEntry>`, 位于链表头的 cache entry 总是最近一次被访问到的 entry. gp_max_local_distributed_cache 这个 GUC 用来指定 cache capacity, 若取值为 0, 则表明不启用 cache. 注意这里 cache entry 中并未存放 global transaction id 中 timestamp 的部分, 也就是意味着所有在 LocalDistribXactCache 中的分布式事务的 timestamp 总是等于当前实例启动时分配到的 timestamp. LocalDistribXactCache_CommittedFind() 用来查找该 cache. LocalDistribXactCache_AddCommitted() 用来往 cache 中新增一项. 可以根据这俩函数的实现来了解 cache 的详细结构.

DistributedSnapshotWithLocalMapping; 在 DistributedSnapshot 之上加了一些 cache 性的包装. 用来提升 XidInMVCCSnapshot() 函数的检测效率. 字段 inProgressMappedLocalXids 存放着 ds 内所有正在运行着的分布式事务在当前 segment 上对应的 local transaction xid. minCachedLocalXid, maxCachedLocalXid 则分别是 inProgressMappedLocalXids 中的最小值, 最大值. 所以在 XidInMVCCSnapshot 中若发现某个 xid 在 inProgressMappedLocalXids 存在, 那意味着该 xid 对应的分布式事务正在运行中, 省去了对 distributed log 与 DistributedSnapshot 的查找与检测. 

DistributedSnapshotWithLocalMapping_CommittedTest(); 用来检测 localXid 对应的分布式事务是否在 DistributedSnapshot 中. 相当于是 PG XidInMVCCSnapshot() 的分布式版本. 返回:

-   DISTRIBUTEDSNAPSHOT_COMMITTED_INPROGRESS; 意味着在 DistributedLog 中找到了该 local xid 对应的分布式事务 id 信息, 并且该分布式事务在 DistributedSnapshot 中, 即该分布式事务正在运行中.

-   DISTRIBUTEDSNAPSHOT_COMMITTED_VISIBLE; 意味着在 DistributedLog 中找到了该 local xid 对应的分布式事务 id 信息, 并且该分布式事务不在 DistributedSnapshot 中, 即该分布式事务已经结束运行. 另外又由于只有当 local xid 提交时, 才会写入进 DistributedLog 中, 所以这时也意味着 local xid 已经提交了.

-   DISTRIBUTEDSNAPSHOT_COMMITTED_IGNORE; 意味着在 DistributedLog 中找到了该 local xid 对应的分布式事务 id 信息, 并且该分布式事务是在实例上一次生命周期中分配的. (我理解这时也应该返回 DISTRIBUTEDSNAPSHOT_COMMITTED_VISIBLE 的...

-   DISTRIBUTEDSNAPSHOT_COMMITTED_UNKNOWN; 意味着没有在 DistributedLog 中找到了该 local xid 对应的分布式事务 id 信息. (按我理解这是也可以设置 HEAP_XMIN_DISTRIBUTED_SNAPSHOT_IGNORE hint 了..

DISTRIBUTEDSNAPSHOT_COMMITTED_INPROGRESS/DISTRIBUTEDSNAPSHOT_COMMITTED_VISIBLE 分别对应着 XID_IN_SNAPSHOT/XID_NOT_IN_SNAPSHOT. 

SnapshotData, GP 中 SnapshotData 存放着分布式快照 DistributedSnapshot, 以及 local snapshot. 这里 DistributedSnapshot 与 local snapshot 一一对应, 即对于每一个 DistributedSnapshot 中的分布式事务, 都有且仅有一个 local transaction 在 local snapshot 中与之对应. SnapshotData 中 DistributedSnapshot 存放在 SnapshotData::distribSnapshotWithLocalMapping::ds 中, 字段 haveDistribSnapshot 表明当前 SnapshotData 是否包含了分布式快照. GetSnapshotData() 用来填充 SnapshotData, 在不同角色下, 其具有不同的行为:

-   对于 QD, 此时需要完成 DistributedSnapshot, local snapshot 的获取. 对于 QE writer, 需要从 DtxContextInfo::distributedSnapshot 拷贝出 QD 发来的分布式快照, 然后再计算出 local snapshot, 并通过函数 updateSharedLocalSnapshot 填充到 SharedSnapshotSlot 中供  QE 使用. 对于 QE reader, 需要从 SharedSnapshotSlot 中获取由 writer 填充的分布式快照与 local snapshot 信息; 之后便直接返回了.  
-   DistributedLogShared->oldestXmin 的更新.


GP 分布式事务可见性检测的简单描述: 在 segment 上的 local transaction 所持有的 snapshot 包括: 正在运行的 local transaction 集合, 正在运行着的 global transaction 集合, 这两个集合是等价的, 即这里 global transaction 与 local transaction 一一对应. 在扫描 tuple 时, 若一行 tuple 的 xmin 在正在运行着的 local transaction 集合中, 则表明该 tuple 所对应 local transaction, 所对应 global transaction 尚未提交, 此时该 tuple 不可见. 若当前 tuple 不在正在运行 local transaction 集合中, 那么此时会根据 distributedlog 模块找出 local transaction 对应的 global transaction, 若此时 global transaction 正在运行, 则 tuple 不可见. 若此时 global transaction 不在正在运行, 那么表明该 global transaction 已经结束, 此时再根据 clog 找到 local transaction 提交状态, 也就是 global transaction 提交状态. 也就对于一个 abort/commit 的 global transaction, 其下所有 local transaction 一定都是 abort/commit 的.

HeapTupleSatisfiesMVCC() 用来检测一个特定的 tuple 是否对一个特定的 snapshot 可见. 同时也会根据检查结果设置某些 hint 用来加速后续对同一 tuple 的检测. 比如若第一次检测某个 tuple 时, 发现其 xmin 已经提交了, 那么便会将 HEAP_XMIN_COMMITTED hint 保存在该 tuple 的 t_infomask 字段中, 参考 transam/README 'Writing Hints' 节介绍, 这种更改也会在可能的时候被持久化, 这样后续对同一 tuple 的检测就可以省略掉查询 clog 来判断 xmin 是否提交了. 在 PG 基础上, GP 也新增了部分 hint:

-   HEAP_XMIN_DISTRIBUTED_SNAPSHOT_IGNORE; 若 tuple t_infomask2 中存在该 flag, 则表明该行对应的 tuple 可见性检查时不需要再次检查 distributed snapshot. HeapTupleSatisfiesMVCC() 一般会在这些 tuple 所在 local transaction 对应的 distributed log 已经被 DistributedLog_AdvanceOldestXmin() 截断时为这些 tuple 设置 HEAP_XMIN_DISTRIBUTED_SNAPSHOT_IGNORE flag, 这样后续检测时就可以省略对分布式快照的检测了. 


XidInMVCCSnapshot() 用来检查一个特定的 xid 是否在指定 snapshot 中. 参数 distributedSnapshotIgnore 指定了 tuple 中是否设置了 HEAP_XMIN_DISTRIBUTED_SNAPSHOT_IGNORE hint. 参数 setDistributedSnapshotIgnore 用来返回是否需要给 tuple 设置 HEAP_XMIN_DISTRIBUTED_SNAPSHOT_IGNORE hint. XidInMVCCSnapshot() 会返回 XID_IN_SNAPSHOT/XID_NOT_IN_SNAPSHOT 来表明查找结果. 返回 XID_SURELY_COMMITTED 表明当前 xid 不再 snapshot 中, 并且该 xid 已经得知是 commited 了, 不需要再次查找 clog 确认了. 比如当 DistributedSnapshotWithLocalMapping_CommittedTest 返回 DISTRIBUTEDSNAPSHOT_COMMITTED_VISIBLE 时, XidInMVCCSnapshot 便可以返回 XID_SURELY_COMMITTED 了.

## GlobalXmin 与 snapshot

GlobalXmin 主要用来控制 VACUUM 的行为. 当 VACUUM 发现某个 tuple 对应的 XMAX 已经提交, 也即该 tuple 已经被删除了. 并且该行 XMAX 先于 GlobalXmin, 即 TransactionIdPrecedes(XMAX, GlobalXmin) 返回 TRUE. 那么意味着当前 tuple 不会再被任何 backend 读取了, VACUUM 可以安全地删除这一 tuple 了. 

为了维护计算 GlobalXmin, PG 引入了 PGXACT::xmin, 记录着当前 backend 内所有现存 snapshot 中 SnapshotData::xmin 的最小值. 所以这时 GlobalXmin 便是所有 backend 对应 PGXACT 结构中 xmin 的最小值了. 

而为了维护更新 PGXACT::xmin, PG 引入了 snapmgr.c 模块, 用来追踪管理当前 backend 分配的所有 snapshot. backend 内分配的所有 snapshot 都会放入到 RegisteredSnapshots 中, RegisteredSnapshots 使用了 pairingheap 这一数据结构, 对 pairingheap 不了解的话可以暂且把他视为最小堆, 具有最小 xmin 的 snapshot 总是会被放在堆顶. PG 中 snapshot 可能会被 resowner.c, active snapshot stack 两个模块引用, SnapshotData::active_count, SnapshotData::regd_count 这两个计数器便是用来分别追踪当前 snapshot 被引用的次数, 仅当这两个引用次数都变为 0 时, snapshot 才能被释放. 存在一些特殊的 snapshot, 虽然他们引用计数不为 0, 但是他们并未被任何 resowner.c, active snapshot stack 引用着, 这些 snapshot 会被特殊处理, 具体哪些 snapshot 参考 snapmgr.c 头部注释. 简单来说有: FirstXactSnapshot, any snapshots that have been exported by pg_export_snapshot, CatalogSnapshot, historic snapshots used during logical decoding.

每当一个 snapshot 由于不再被其他模块引用而释放时, 该 snapshot 便会从 RegisteredSnapshots 中移除, 接着 PG 会根据变更后的 RegisteredSnapshots 结构判断是否可以前移 PGXACT::xmin. 简单来说若变更后 RegisteredSnapshots 堆顶 snapshot xmin 大于 PGXACT::xmin 时, PG 便会更新 PGXACT::xmin. 函数 SnapshotResetXmin() 实现了这一过程, 其会在需要时被 PG 调用. 另外为了简单实现, only registered snapshots not active snapshots participate in tracking which one is oldest; we don't try to change MyPgXact->xmin except when the active-snapshot stack is empty.

RegisteredSnapshots; 其结构类似于 `std::min_heap<SnapshotData*>`, 也即其中存放的只是 SnapshotData 地址, 当我们把一个 SnapshotData 从 RegisteredSnapshots 中移除时, SnapshotData 本身内存如何释放需要由上层调用着考虑, 可能会直接调用 pfree, 可能由于 SnapshotData 是 static-alloced 的, 而不采取任何动作.

active snapshot stack; ActiveSnapshot 总是指向着 active snapshot stack 栈顶元素. 按我理解, 当 PG 其他模块需要使用一个 snapshot 来判断可见性时, 他们总是使用 ActiveSnapshot 指向的快照. PushActiveSnapshot()/PopActiveSnapshot() 用来操作 active snapshot stack.
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

而对于 utility statement, 他们的执行并不需要优化器来做各种优化, 直接根据各自 utility 语义按照规则执行即可. utility 语句执行入口见 ProcessUtility(). utility 语句在 PG 中的处理是非常直白的, 在 ProcessUtility() 之前基本上不会对 Parsetree 做任何处理; 在 ProcessUtility 执行时可能会稍作处理, 之后根据 parsetree 的内容直接执行了. 而且 PG 中一条 utility 可能会拆分为多条 utility 执行. 比如带有 primary key 的 CREATE TABLE 在 PG 中就被拆分为多个 stmt 执行的. 第一条 stmt 是一个纯粹地创建表的 statement, 第二条 stmt 是一个 CREATE INDEX 子句用来创建 primary key 使用的 index.

## PG 中的加减列

在 PG 中, 针对一个表, 其约定表中每个列都有一个唯一标识, 该标识在列被创建之后指定, 之后永远不变, 即使列被删除了, 列对应的标识也不会被复用.

PG 中新增列会将新列写入到 heapfile 中, 手动试了下 `ALTER TABLE ADD COLUMN colname coltype DEFAULT defval` 是这样的. 本来我以为这个时候没必要写入的, 毕竟 heapfile 中每一行都记录着 attrite number, 在读取时如果发现一列并没有在 heapfile 中, 那么使用列的默认值即可. 但后来想到这样一种场景, 比如:

```sql
ADD COLUMN i INT DEFAULT 3
SELECT i FROM t; -- 此时返回 3.
CHANGE COLUMN i DEFAULT 33
SELECT i FROM t; -- 此时同一行的 i 将返回 33. 这样感觉之前 SET DEFAULT 3 的 SQL 就没被持久化.
```

PG 中列删除, 只是简单地在 pg_attribute 标记下, 不会改动 heapfile, 另外 pg_attribute 记录的 attval, attlen 这些与 pg_type 中某些字段重合的信息使得即使列的类型也被删除了, 仍然不影响对 heapfile tuple 的解析. 此时 INSERT 对于 dropped column 的处理会认为他们是 NULL. (所以 NULL 在数据库中是不可缺少的...


## syscache, relcache, invalid message queue

为了提升 backend 查询 system catalog 的效率, PG 中引入了 syscache, relcache 来加速这一过程. 既然是 cache, 就需要引入 cache 的同步机制, 也就是 invalid message queue. 关于 relcache, syscache 的介绍参考 [PostgreSQL的SysCache和RelCache](https://niyanchun.com/syscache-and-relcache-in-postgresql.html) 这篇文章. 关于对 invalid message queue 介绍参考我在 sinvaladt.c 中的注释.


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

### FDW

FDW 相关 catalog; pg_catalog.pg_foreign_table 中存放着每一个 fdw table 相关信息.

FDW 的组成部分, 参考 '55.1. Foreign Data Wrapper Functions' 了解. 简单来说就是一个 handler function, 一个 validator function.

handler function 中涉及到各个回调的语义, 参考 '55.2. Foreign Data Wrapper Callback Routines' 了解, 其内介绍了每个回调在 PG 中的语义以及使用场景, FDW 作者应该忠实地实现这些回调. 

Foreign Data Wrapper Helper Functions; '55.3. Foreign Data Wrapper Helper Functions' 介绍了一些 FDW 作者可用的 helper 函数. Several helper functions are exported from the core server so that authors of foreign data wrappers can get easy access to attributes of FDW-related objects, such as FDW options.

Foreign Data Wrapper Query Planning; 根据 55.2 中介绍可以看到 FDW 一些回调会在 planner 阶段调用, 此时 FDW 会看到关于 planner 的所有细节, 也可以操作这些所有细节. 因此我理解对 PG 优化器/执行器架构理解地越深, 在这些 FDW 回调中能做的就越多.

在优化器/执行器所用到的结构中, 所有 fdw_private 或者类似的字段都是专门用于 FDW 的, FDW 作者可以在这里面存放一些特定的信息. 这些 fdw_private 包括 RelOptInfo::fdw_private ForeignPath::fdw_private, ForeignScan::fdw_private 等. ForeignScan::fdw_exprs 也仅被 FDW 使用, 不过这时要遵循一定的约定, 即 fdw_exprs 内只能存放 Expr, These trees will undergo post-processing by the planner to make them fully executable.

对 GetForeignPlan() 参数 scan_clauses 的处理. 若 FDW 本身不考虑任何条件下推的功能, 那么处理姿势很简单, 只需要在 GetForeignPlan 时像 file_fdw 中 fileGetForeignPlan 做法一样, 把 `extract_actual_clauses(scan_clauses, false)` 去掉 pseudoconstant expression 之后的 qual list 交给 ForeignScan::qual 即可. 此时会由 PG 本地执行器来完成条件的过滤.  若 FDW 本身需要考虑条件下推的功能, 那么在 GetForeignPaths 阶段就需要把哪些准备下推的 qual 找出来, 之后和 cost_index() 中做法一样, 对于下推的 qual 按照 FDW 自己的意思来计算 qualcost, 对于不能下推准备在 PG 执行的 qual, 调用 cost_qual_eval 来计算这些 qualcost, 之后把两类 qual qualcost 汇总设置为 Path cost. 最后在 GetForeignPlan 时, 将准备下推到 FDW 的 qual 从 scan_clauses 中移除出去. 

若某些准备下推的 qual 部分输入需要在本地运算(我并不晓得有哪些这样的场景..), 可以把这部分 expression 放入 ForeignScan::fdw_exprs 中, planner 会对这些 expression 调用 set_plan_references 来做一些处理使得 fdw_exprs 变为可执行的状态.

fdw_scan_tlist; 参考原文了解其语义. 在执行器 ExecInitForeignScan 构造 ForeignScanState 时, 若发现 ForeignScan tlist 与 fdw_scan_tlist 不符合, 则会生成相应的 Projectinfo.

FDW parameterized path 的生成, 参考:  'In join queries, it might also choose to construct path(s) that depend on join clauses..'

FDW 支持 remote join, 未细看, 见原文 'If an FDW supports remote joins...'

FDW 支持 AGG; 未细看.. 见原文 'An FDW might additionally support direct execution of...' 节.

'PlanForeignModify and the other callbacks described' 之后内容未看, 目测与写入有关.

### Index Methods and Operator Classes

Access method, index access method. 按照我的理解, PG 最初是希望所有对表数据, 索引数据的访问都通过 access method 来进行, 这样就可以把 PG 内核与具体的数据存储格式隔离开, 便于今后新数据存储格式的引入. 目前 PG 中只有 index 实现了这种访问姿势, 即 index access method, 也即新实现一个索引类型只需要新实现一个 index access method 即可, 完全不需要改动 PG 内核. 话说目前业界也在试图实现 table access method, 比如像 zstore 等.

operator class, operator class 是 PG 中 type 与 index 之间的桥梁. operator class 有两部分组成: 

-   operators, 又被称为 strategy. the set of WHERE-clause operators that can be used with an index (i.e., can be converted into an index-scan qualification). 即告诉优化器, 当在 WHERE 条件中出现这些 operators 时, 可以试下 index scan.
-   support procedures, 由 index access method 内部使用. 一般 index access method 会使用 support procedures 来确定数据在 index 中的位置.

PG index access method 使用 number 来标识 operator, support procedures. 简单来说, 就是 index access method 根据其实现细节为其支持的 operators, 以及要使用 support procedures 各指定一个 int 整数标识符, 之后用户在定义 operator class 时, 将指定的 int 整数标识符关联到对应的 operator 或者 function 上. 比如 btree index access method 支持的 number 参考 'Table 36-2', 那么当用户为一个新类型建立 btree operator class 时的姿势就可以是:

```sql
CREATE OPERATOR CLASS CUSTOM_TYPE_ops
DEFAULT FOR TYPE CUSTOM_TYPE USING btree AS
	OPERATOR    1   <  (CUSTOM_TYPE, CUSTOM_TYPE),  
	OPERATOR    2   <= (CUSTOM_TYPE, CUSTOM_TYPE),
	OPERATOR    3   =  (CUSTOM_TYPE, CUSTOM_TYPE),
	OPERATOR    4   >= (CUSTOM_TYPE, CUSTOM_TYPE),
	OPERATOR    5   >  (CUSTOM_TYPE, CUSTOM_TYPE),
	FUNCTION    1   CUSTOM_TYPE_cmp(CUSTOM_TYPE, CUSTOM_TYPE);
```

default operator class. It is possible to define multiple operator classes for the same data type and index method. By doing this, multiple sets of indexing semantics can be defined for a single data type. For example, a B-tree index requires a sort ordering to be defined for each data type it works on. It might be useful for a complex-number data type to have one B-tree operator class that sorts the data by complex absolute value, another that sorts by real part, and so on. Typically, one of the operator classes will be deemed most commonly useful and will be marked as the default operator class for that data type and index method. 当对给定列建立索引时, 若此时未显式指定 operator class, 那么则使用 default operator class.

operator family; An operator family contains one or more operator classes, and can also contain indexable operators and corresponding support functions that belong to the family as a whole but not to any single class within the family. We say that such operators and functions are “loose” within the family, as opposed to being bound into a specific class. Typically each operator class contains single-data-type operators while cross-data-type operators are loose in the family. 参见 '36.14.5. Operator Classes and Operator Families' 第一段了解 operator family 背景. ~~这里我有一个非常适当的例子可以活生生地展示下 operator family 的使用场景, 但是现在太晚了, 我要睡觉了, 就不写了. 等我以后有空时吧~~~

既然有了 operator family, 为啥我们还需要 operator class. The reason for defining operator classes is that they specify how much of the family is needed to support any particular index. If there is an index using an operator class, then that operator class cannot be dropped without dropping the index — but other parts of the operator family, namely other operator classes and loose operators, could be dropped. Thus, an operator class should be specified to contain the minimum set of operators and functions that are reasonably needed to work with an index on a specific data type, and then related but non-essential operators can be added as loose members of the operator family.

opclass/opfamily 对 operator 的重要性; 要知道 PG 是支持用户自定义类型与 operator 的, 对于一个用户定义的 operator, 当其未出现在任何 operator class/family 中时, PG 对这个 operator 的背景知识是一无所知的, 这就意味着如果我们在 WHERE 中使用了这个 operator, 那么 PG 将只能走 seqscan. 当一个 operator 出现在某个 operator class/family 中时, 这就意味着根据这个 operator 在 opclass/opfamily 所处的位置, 即 strategy number, PG 就知晓了这个 operator 相关的特性, 从而在优化过程中, 根据这些特性做出某些优化动作. 以 operator `<(CUSTOM_TYPE, CUSTOM_TYPE)` 为例, 若其未出现在任何 opclass/opfamily 中, 那么当该 operator 出现在 WHERE 条件中时, 将只能走 seqscan 来判断这个 operator. 但是如果 operator 出现在某个 opclass/opfamily strategy = 1 对应的位置, 那么 PG 便知道了 operator `<(CUSTOM_TYPE, CUSTOM_TYPE)` 是 CUSTOM_TYPE 这个类型的 lessthan 比较运算符. 意味着对于 CUSTOM_TYPE 类型的 A, B, C, 若 `A < B`, `B < C`, 那么 PG 便知道 `A < C` 也是成立的. 同样若 `B < C`, 并且 `B < A` 不成立, 那么 PG 便知道 `C < A` 也肯定不成立. 很显然此时 `<` 的实现要符合 PG 这里的假设要求! 也意味着当 `<` 出现在 WHERE 条件中, 并且此时有相关索引时, 那么 PG 就会考虑 indexscan. 参见 '举个栗子' 节对此情况的演示.

operator class 不单单用来与索引交互. PostgreSQL uses operator classes to infer the properties of operators in more ways than just whether they can be used with indexes. Therefore, you might want to create operator classes even if you have no intention of indexing any columns of your data type. 参见 '36.14.6. System Dependencies on Operator Classes' 了解.

order operator, search operator; 参见 '36.14.7. Ordering Operators' 了解. 简单来说就是可以用索引实现 order by 子句.

lossy index. 参见 '36.14.8. Special Features of Operator Classes' 了解, 简单来说就是 lossy index scan 返回的结果集是实际 WHERE 结果集的超集, 此时在 index scan 之后仍需要一一判断下 index scan 返回的每一行是否匹配条件.

STORAGE clause. 参见 '36.14.8. Special Features of Operator Classes' 了解, 简单来说就是对于一个类型 T 来说, 其存放在索引的可以是另外一个类型.

#### 举个栗子

假设我们现在自定义了类型 MagicInt2, MagicInt4, 大部分情况下这俩类型与 int2, int4 类型具有相同的性质, 除了:

- 不支持 MagicInt2 与 MagicInt4 相互之间的转换.
- `<(MagicInt2, MagicInt2)` 与 `<(MagicInt2, MagicInt4)` 的比较规则如下伪代码所示:

  ```c
  bool lessthan(MagicInt2 left, MagicInt2/* MagicInt4 */ right) {
    if (left <= 10)
      return true;
    if (left <= 500)
      return false;
    if (left <= 600)
      return true;
    return false;
  }
  ```

同时我们也定义了 MagicIntOps operator family 以及 MagicInt2Ops, MagicInt4Ops operator class:

```sql
CREATE OPERATOR FAMILY MagicIntOps USING btree;

CREATE OPERATOR CLASS MagicInt2Ops
DEFAULT FOR TYPE MagicInt2 USING btree FAMILY MagicIntOps AS
  OPERATOR    1   <  (MagicInt4, MagicInt4)
  ...;

CREATE OPERATOR CLASS MagicInt4Ops
DEFAULT FOR TYPE MagicInt4 USING btree FAMILY MagicIntOps AS
  OPERATOR    1   <  (MagicInt4, MagicInt4)
  ...;
```

之后再做一下准备工作:

```sql
CREATE TABLE t(i int, d64 MagicInt2);
INSERT INTO t SELECT i, i FROM generate_series(1, 1000000) f(i);
CREATE INDEX on t(d64); 
ANALYZE t;
SET enable_seqscan TO off;
```

之后可以看到 `<(MagicInt2, MagicInt4)` 出现在 WHERE 条件中时, PG 只会有 seqscan path. 

```sql
zhanyi=# explain select i from t where d64 < '11'::MagicInt4;
                                                     QUERY PLAN                                                      
---------------------------------------------------------------------------------------------------------------------
 Gather Motion 3:1  (slice1; segments: 3)  (cost=100000000000000000000.00..100000000000000000000.00 rows=15 width=4)
   ->  Seq Scan on t  (cost=100000000000000000000.00..100000000000000000000.00 rows=5 width=4)
         Filter: (d64 < '11.00'::MagicInt4)
 Optimizer: Postgres query optimizer
```

与之相对的是 `<(MagicInt2, MagicInt2)` 出现在 WHERE 中时, PG 会选择 index scan 这个更高效的链路.

```sql
zhanyi=# explain select i from t where d64 < '11'::MagicInt2;
                                 QUERY PLAN                                  
-----------------------------------------------------------------------------
 Gather Motion 3:1  (slice1; segments: 3)  (cost=0.15..0.41 rows=15 width=4)
   ->  Index Scan using t_d64_idx on t  (cost=0.15..0.41 rows=5 width=4)
         Index Cond: (d64 < '11.00'::MagicInt2)
 Optimizer: Postgres query optimizer
```

另外也有个有趣的现象是:

```sql
zhanyi=# explain select d64 from t where d64 < '11'::MagicInt2;
                                  QUERY PLAN                                  
------------------------------------------------------------------------------
 Gather Motion 3:1  (slice1; segments: 3)  (cost=0.15..0.41 rows=15 width=8)
   ->  Index Only Scan using t_d64_idx on t  (cost=0.15..0.41 rows=5 width=8)
         Index Cond: (d64 < '11.00'::MagicInt2)
 Optimizer: Postgres query optimizer

zhanyi=# explain select d64 from t where d64 < '11'::MagicInt4;
                                  QUERY PLAN                                  
------------------------------------------------------------------------------
 Gather Motion 3:1  (slice1; segments: 3)  (cost=0.15..0.41 rows=15 width=8)
   ->  Index Only Scan using t_d64_idx on t  (cost=0.15..0.41 rows=5 width=8)
         Index Cond: (d64 < '11.00'::MagicInt4)
 Optimizer: Postgres query optimizer
```

可以看到由于我们这里只 `SELECT d64` 使得 PG 发现单纯地 index only scan 便可以满足要求. 但这里两个 index only scan 执行起来是不太一样的! 对于 `d64 < '11'::MagicInt2` 这条查询, 当 index only scan 遇到 `d64 = 11`, 发现此时 `d64 < '11'::MagicInt2` 不再成立, 而且这里使用的 `<` 是出现在 operator class 的, 所以 PG 会认为在 `d64=11` 之后的行都不再满足 `d64 < '11'::MagicInt2`, 所以便会终止 index only scan, 也即意味着最终仅会返回 10 行. 但对于 `d64 < '11'::MagicInt4` 这条查询, PG 虽然是 index only scan, 但会扫描完 index, 不会提前终止. 所以:

```sql
zhanyi=# select count(d64) from t where d64 < '11'::MagicInt4;
 count 
-------
   110  -- 扫描完 index 中所有 entry.

zhanyi=# select count(d64) from t where d64 < '11'::MagicInt2;
 count 
-------
    10
```

根据我们之前对 `<` 的实现可知 110 便是期望结果, 之所以在 `d64 < '11'::MagicInt2` 时结果只有 10 行, 是由于我们这里的实现未满足 PG 的假设, 很显然是我们的实现错误了, 毕竟是为了演示.

在我们把 `<(MagicInt2, MagicInt4)` 加入到 operator family MagicIntOps 中时, PG 便知道了 `<(MagicInt2, MagicInt4)` 这个运算符相关背景信息以及相关假设: 比如对于 MagicInt2 类型的 B, C; 以及 MagicInt4 类型的 A, 当 B < C, 并且 B < A 不成立时, PG 便会顺理成章地假设 C < A 也是不成立的. 此后 `d64 < '11'::MagicInt2` 与 `d64 < '11'::MagicInt4` 的行为便完全一致了. 


## Partitioning Large Tables

> 基于 GP6.4 文档

首先看下 DISTRIBUTED BY 与 PARTITION BY 区别: Table distribution is physical: Greenplum Database physically divides partitioned tables and non-partitioned tables across segments to enable parallel query processing. Table partitioning is logical: Greenplum Database logically divides big tables to improve query performance and facilitate data warehouse maintenance tasks, such as rolling old data out of the data warehouse. Partitioning does not change the physical distribution of table data across the segments. 所以是先计算分布, 然后再计算分区了?!

GPDB 支持多级分区, 一个多级分区表看上去像是一棵树. 每一级分区上可以采用多种分区姿势: 

-	range partitioning: division of data based on a numerical range, such as date or price.
-	list partitioning: division of data based on a list of values, such as sales territory or product line.

In a multi-level partition design, only the subpartitions at the bottom of the hierarchy can contain data. 分区树中每一个节点都有对应的 CHECK 约束, 用来限制能插入该分区的数据. 如:

```sql
zhanyi=# \d+ mlp
                  Table "public.mlp"
 Column |  Type   | Modifiers | Storage  | Description 
--------+---------+-----------+----------+-------------
 id     | integer |           | plain    | 
 year   | integer |           | plain    | 
 month  | integer |           | plain    | 
 day    | integer |           | plain    | 
 region | text    |           | extended | 
Child tables: mlp_1_prt_1,
              mlp_1_prt_2
Has OIDs: no
Distributed by: (id)
Partition by: (year)

zhanyi=# \d+ mlp_1_prt_1
              Table "public.mlp_1_prt_1"
 Column |  Type   | Modifiers | Storage  | Description 
--------+---------+-----------+----------+-------------
 id     | integer |           | plain    | 
 year   | integer |           | plain    | 
 month  | integer |           | plain    | 
 day    | integer |           | plain    | 
 region | text    |           | extended | 
Check constraints:
    "mlp_1_prt_1_check" CHECK (year >= 2000 AND year < 2005)
Inherits: mlp
Child tables: mlp_1_prt_1_2_prt_asia,
              mlp_1_prt_1_2_prt_europe,
              mlp_1_prt_1_2_prt_usa
Has OIDs: no
Distributed by: (id)
Partition by: (region)
```

分区表的 INSERT; 表的分区可以直接被 INSERT, 此时 GP 就会按照如上 CHECK 约束来检查 INSERT 是否合法. 当然也可以使用根节点位置的表作为 INSERT 目标, 此时 GP 会自动路由. 

Default Partition; 无论每级分区采用的是 range partitioning 还是 list partitioning, 都可以指定 Default Partition, 不满足那些显式指定条件的数据将会被插入到 Default Partition 中. default partition 上没有 check. ~~我还以为会智能地根据已有 partition check 来推测 default partitoin 呢.~~ 因此在应用直接插入数据到 Default Partition 时, 需要确认 the data in the default partition must not contain data that would be valid in other leaf child partitions of the partitioned table. Otherwise, queries against the partitioned table with the exchanged default partition that are executed by the Pivotal Query Optimizer might return incorrect results.

分区与 Unique; A primary key or unique constraint on a partitioned table must contain all the partitioning columns. A unique index can omit the partitioning columns; however, it is enforced only on the parts of the partitioned table, not on the partitioned table as a whole.

uniform 分区; uniform 是分区表的一个属性, 分区表是否是 uniform 的规则判定参见 [uniform](https://gpdb.docs.pivotal.io/43320/admin_guide/query/topics/query-piv-uniform-part-tbl.html#topic1). 考虑到 uniform 可以随意操作分区情况, uniform 并不总是成立的. 

分区裁剪; The query optimizer uses CHECK constraints to determine which table partitions to scan to satisfy a given query predicate. The DEFAULT partition (if your hierarchy has one) is always scanned. DEFAULT partitions that contain data slow down the overall scan time. The following limitations can result in a query plan that shows a non-selective scan of your partition hierarchy. 可以通过 explain 查看 scan 了那些 partition.

分区与继承; Internally, Greenplum Database creates an inheritance relationship between the top-level table and its underlying partitions, similar to the functionality of the INHERITS clause of PostgreSQL. The Greenplum system catalog stores partition hierarchy information so that rows inserted into the top-level parent table propagate correctly to the child table partitions. 为啥非得创建个继承关系把分区与继承这俩扯一块去, 感觉不相干啊. 按我理解 GP 估计是要 PG 正好提供的继承模型来对 INSERT 进行路由. 但总觉怪怪的!

分区最佳实践; Consider partitioning by the most granular level. A multi-level design can reduce query planning time. 当然这只是一般情况下, 原文也讲了. When you create multi-level partitions on ranges, it is easy to create a large number of subpartitions, some containing little or no data. This can add many entries to the system tables, which increases the time and memory required to optimize and execute queries. but a flat partition design runs faster.

Exchanging a Partition; 相当于 swap 操作, 但是仅会 swap 一些元信息, 以及数据指针. 在 exchange 非 default partition 时, GP 默认会利用 partition 上的 check 约束来检查数据合法性. 可以使用  WITHOUT VALIDATION 来关闭这一行为. 在 exchange default paritition 时, default partition 上没有任何 check 导致 GP 无法检查数据合法性, 所以默认 GP 不允许 exchange default partition. 如果强行 exchange default partition, 需要用户确认数据满足放入 Default Partition. 如下例子演示 Exchanging a Leaf Child Partition with an External Table:

```sql
zhanyi=# \d+ sales_2000_ext;
        External table "public.sales_2000_ext"
 Column |  Type   | Modifiers | Storage  | Description
--------+---------+-----------+----------+-------------
 id     | integer |           | plain    |
 year   | integer |           | plain    |
 qtr    | integer |           | plain    |
 day    | integer |           | plain    |
 region | text    |           | extended |
Type: readable
Encoding: UTF8
Format type: csv
Format options: delimiter ',' null '' escape '"' quote '"'
External location: gpfdist://172.17.0.6:8080/sales_2000

zhanyi=# \d+ sales_1_prt_yr_1
            Table "public.sales_1_prt_yr_1"
 Column |  Type   | Modifiers | Storage  | Description
--------+---------+-----------+----------+-------------
 id     | integer |           | plain    |
 year   | integer |           | plain    |
 qtr    | integer |           | plain    |
 day    | integer |           | plain    |
 region | text    |           | extended |
Check constraints:
    "sales_1_prt_yr_1_check" CHECK (year >= 2000 AND year < 2001)
Inherits: sales
Has OIDs: no
Distributed by: (id)

zhanyi=# select * from sales_2000_ext;
 id | year | qtr | day |     region
----+------+-----+-----+----------------
  1 | 2000 |   1 |   1 | blog.hidva.com
  3 | 2000 |   1 |   1 | blog.hidva.com
  2 | 2000 |   1 |   1 | blog.hidva.com
  4 | 2000 |   1 |   1 | blog.hidva.com
(4 rows)

zhanyi=# select * from public.sales_1_prt_yr_1
zhanyi-# ;
 id | year | qtr | day |     region
----+------+-----+-----+----------------
  3 | 2000 |   1 |   1 | blog.hidva.com
  1 | 2000 |   1 |   1 | blog.hidva.com
  2 | 2000 |   1 |   1 | blog.hidva.com
(3 rows)

-- swap 后.

zhanyi=# ALTER TABLE sales ALTER PARTITION yr_1
zhanyi-#    EXCHANGE PARTITION yr_1
zhanyi-#    WITH TABLE sales_2000_ext WITHOUT VALIDATION;
NOTICE:  exchanged partition "yr_1" of partition "yr_1" of relation "sales" with relation "sales_2000_ext"
ALTER TABLE
zhanyi=# select * from public.sales_1_prt_yr_1;
 id | year | qtr | day |     region
----+------+-----+-----+----------------
  1 | 2000 |   1 |   1 | blog.hidva.com
  3 | 2000 |   1 |   1 | blog.hidva.com
  2 | 2000 |   1 |   1 | blog.hidva.com
  4 | 2000 |   1 |   1 | blog.hidva.com
(4 rows)

zhanyi=# select * from sales_2000_ext;
 id | year | qtr | day |     region
----+------+-----+-----+----------------
  3 | 2000 |   1 |   1 | blog.hidva.com
  1 | 2000 |   1 |   1 | blog.hidva.com
  2 | 2000 |   1 |   1 | blog.hidva.com
(3 rows)

zhanyi=#  \d+ sales_2000_ext;
             Table "public.sales_2000_ext"
 Column |  Type   | Modifiers | Storage  | Description
--------+---------+-----------+----------+-------------
 id     | integer |           | plain    |
 year   | integer |           | plain    |
 qtr    | integer |           | plain    |
 day    | integer |           | plain    |
 region | text    |           | extended |
Check constraints:
    "sales_1_prt_yr_1_check" CHECK (year >= 2000 AND year < 2001)
Has OIDs: no
Distributed by: (id)

zhanyi=# \d+ sales_1_prt_yr_1
       External table "public.sales_1_prt_yr_1"
 Column |  Type   | Modifiers | Storage  | Description
--------+---------+-----------+----------+-------------
 id     | integer |           | plain    |
 year   | integer |           | plain    |
 qtr    | integer |           | plain    |
 day    | integer |           | plain    |
 region | text    |           | extended |
Type: readable
Encoding: UTF8
Format type: csv
Format options: delimiter ',' null '' escape '"' quote '"'
External location: gpfdist://172.17.0.6:8080/sales_2000
Check constraints:
    "sales_1_prt_yr_1_check" CHECK (year >= 2000 AND year < 2001)

```

分区表的 ALTER TABLE 语法; 考虑到多级分区的存在, 对分区表树中某个节点的 ALTER 操作需要明确指出从分区表根节点到该节点的访问路径. 这是通过 0 个或多个 ALTER PARTITION 子句来指定的. 每一个 ALTER PARTITION 有三种方式来指定下一个分区节点: parition_number, `FOR (RANK(number))`, `FOR ('value')`, 关于这三种方式语义参考 GP ALTER TABLE 文档. 多个 ALTER PARTITION 确定的下一个分区节点链表就组成了一个访问路径. 下面举个例子:

```sql
CREATE TABLE p3_sales4 (id int, day int, year int, month int, region text)
PARTITION BY LIST (year) 
SUBPARTITION BY LIST (month) 
    SUBPARTITION TEMPLATE (VALUES(1), VALUES(2))
SUBPARTITION BY LIST (region) 
    SUBPARTITION TEMPLATE (VALUES ('usa'), VALUES ('asia'))
(VALUES(2018), VALUES(2019));
```

如上 SQL 会创建出具有如下分区层次的分区表:

![]({{site.url}}/assets/p3_sales4.jpg)

如果想对 Y2018M2Rasia 分区叶子表做一个 exchange 操作, 对应的 ALTER TABLE 语法便是:

```sql
ALTER TABLE p3_sales4   -- 首先从根节点出发
ALTER PARTITION FOR ('2018')  -- 这里指定了第 0 层分区中可以存放 year=2018 的那个分区.
ALTER PARTITION FOR ('2')  -- 指定了第 1 层分区中可以存放 month=2 的那个分区.
EXCHANGE PARTITION FOR ('asia')   -- 指定了第 2 层分区中可以存放 region='asia' 的那个分区. 并对该分区做一次 exchange 操作.
WITH TABLE xxx;
```

## pg_partition

The pg_partition system catalog table is used to track partitioned tables and their inheritance level relationships. Each row of pg_partition represents either the level of a partitioned table in the partition hierarchy, or a subpartition template description. The value of the attribute paristemplate determines what a particular row represents. 按我理解 pg_partition 是根据分区表建表 DDL 收集到的信息来填充的. 下面以一个具体分区表在 pg_partition 中的元信息来介绍 pg_partition:

```sql
CREATE TABLE p3_sales (id int, year int, month int, day int, 
region text)
DISTRIBUTED BY (id)
PARTITION BY RANGE (year)
    SUBPARTITION BY RANGE (month)
       SUBPARTITION TEMPLATE (
        START (1) END (2) EXCLUSIVE EVERY (1), 
        DEFAULT SUBPARTITION other_months )
           SUBPARTITION BY LIST (region)
             SUBPARTITION TEMPLATE (
               SUBPARTITION usa VALUES ('usa'),
               DEFAULT SUBPARTITION other_regions )
( START (2002) END (2004) EXCLUSIVE EVERY (1), 
  DEFAULT PARTITION outlying_years );
```
其在 pg_partition 的元信息有:

```
zhanyi=# select oid,parrelid::regclass,* from pg_partition;
  oid   | parrelid | parrelid | parkind | parlevel | paristemplate | parnatts | paratts | parclass 
--------+----------+----------+---------+----------+---------------+----------+---------+----------
 104106 | p3_sales |   103395 | r       |        0 | f             |        1 | 2       | 1978
 104143 | p3_sales |   103395 | r       |        1 | t             |        1 | 3       | 1978
 104144 | p3_sales |   103395 | r       |        1 | f             |        1 | 3       | 1978
 104219 | p3_sales |   103395 | l       |        2 | t             |        1 | 5       | 1994
 104220 | p3_sales |   103395 | l       |        2 | f             |        1 | 5       | 1994
(5 rows)
```

可以看到:

parrelid, The object identifier of the table. 即分区表根表对应的 oid.
parnatts, 按我理解存放着分区列的个数. 一般取值为 1. 不晓得 PG/GP 是否支持指定多个分区列. 
paratts, parclass; 一一对应. `paratts[i]`, 使用 `SELECT * FROM pg_attribute WHERE attrelid = ${parrelid} and attnum = ${paratts[i]};` 可以查找到分区列的具体信息. `parclass[i]`, 存放着该分区列对应的 op class 信息.
parlevel, paristemplate; 根据 DDL 可以看到, 在 parlevel = 0 层使用 year 列取值来进行分区. 而且是以非模板的. 在 parlevel = 1 层使用 month 列值进行分区, 这里是以模板形式建立的分区. 在 parlevel = 2 层使用 region 列来建立分区. 根据 pg_partition 中的元信息可以看到, 使用模板建立的分区其在 pg_partition 中对应着两行, 一行描述着分区级别本身. 一行表明了该级分区是通过模板建立的. ~~感觉是有点重复描述了.~~. 另外也可以看到分区树中叶子节点那一层(parlevel=3)并未在 pg_partition 表中体现.


## pg_partition_rule

按我理解, pg_partitoin 中每一行在 pg_partition_rule 中都对应着多行, 来描述某个特定级层分区的信息. 对于 paristemplate=true 的行, 其在 pg_partition_rule 中对应的行记录着模板取值, 此时这些行不与任何具体的分区表关联, 仅是用来存放模板的信息. 如 oid=104143 的 pg_partition 行在 pg_partiton_rule 对应的行信息:

```
zhanyi=# select * from pg_partition_rule where paroid = 104143;
-[ RECORD 1 ]-----+----------------------------------------------------------------------------------------------------------
paroid            | 104143
parchildrelid     | 0  # 取值为 0, 不关联任何具体的分区表.
parparentrule     | 0
parname           | 
parisdefault      | f
parruleord        | 2
parrangestartincl | t
parrangeendincl   | f
parrangestart     | ({CONST :consttype 23 :constlen 4 :constbyval true :constisnull false :constvalue 4 [ 1 0 0 0 0 0 0 0 ]})  -- 0x1 小端模式(不明白为啥展示是 8 个字节.
parrangeend       | ({CONST :consttype 23 :constlen 4 :constbyval true :constisnull false :constvalue 4 [ 2 0 0 0 0 0 0 0 ]})
parrangeevery     | ({CONST :consttype 23 :constlen 4 :constbyval true :constisnull false :constvalue 4 [ 1 0 0 0 0 0 0 0 ]})
parlistvalues     | <>
parreloptions     | 
partemplatespace  | 0
-[ RECORD 2 ]-----+----------------------------------------------------------------------------------------------------------
paroid            | 104143
parchildrelid     | 0
parparentrule     | 0
parname           | other_months
parisdefault      | t
parruleord        | 1
parrangestartincl | f
parrangeendincl   | f
parrangestart     | <>
parrangeend       | <>
parrangeevery     | <>
parlistvalues     | <>
parreloptions     | 
partemplatespace  | 0
```

对于 paristemplate=false 的行, 其在 pg_partition_rule 中对应的行记录着该级层分区下所有的子分区表的信息. 如对于 parlevel = 0 的行, 其有三个子分区, 所以在 pg_partition_rule 中对应着三行, 这三行分别存放着三个子分区的具体信息. 对于 parlevel = 1 的行, 这一层本身有三个分区表, 每个分区表又有 2 个子分区, 所以共有 6 个子分区表. 所以在 pg_partition_rule 中并不会有分区根表的信息.

这里介绍下 pg_partition_rule 部分比较特别的列的语义, 其他列语义描述参考 [GP 官方文档](https://gpdb.docs.pivotal.io/5190/ref_guide/system_catalogs/pg_partition_rule.html). 

parchildrelid; 存放着当前分区表在 pg_class 的 oid. 这里列名包含 'child' 是站在 pg_partition 的角度来看待的.
parparentrule; 这里原文应该是写错了. 该列存放着当前分区表父表在 pg_partition_rule 的 oid, 所以 references 是 pg_partition_rule.oid.
parname; 当前分区表在建表 DDL 中的名字. 若用户未显式指定, 则为空. 如:

```
oid               | 104343
parchildrelname   | p3_sales_1_prt_2_2_prt_2_3_prt_other_regions
paroid            | 104220
parchildrelid     | 103844
parparentrule     | 104145
parname           | other_regions
--------
oid               | 104307
parchildrelname   | p3_sales_1_prt_2_2_prt_other_months_3_prt_usa
paroid            | 104220
parchildrelid     | 103712
parparentrule     | 104207
parname           | usa
```

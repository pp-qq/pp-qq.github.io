---
title: "为啥 PG 中要持久化 cmin/cmax?"
hidden: true
tags: ["Postgresql/Greenplum"]
---


按照 PG 说法: 对 cmin/cmax 的持久化主要是用来判断事务内的可见性, 若事务内 SQL A 在扫描时发现某行 cmin 发生在自身 commandId 之前, 那么它就晓得这行对自己是可见的. 但这就有一个问题了: PG 中事务内的 SQL 总是串行执行的, 所以若 SQL A 扫描时发现某行 xmin 等于自身事务, 那么它就晓得这行是自身事务插入的, 即这行肯定是同一事务内在 SQL A 之前的 SQL 插入的, 也即这行对 SQL A 来说是可见的. 不过话说 PG 中 SQL 在扫描时能否看到自己插入的行呢? 如果能看到自身插入的行, 那么语义上这些行对自身是否应该是可见的呢? 如果 PG 中 SQL 扫描上可能会看到自身插入的行, 并且我们从语义上规定这些行对自身是不可见的, 那么我们确实需要 cmin 这个值来判断一下.

但目前来看 PG 中 SQL 在执行时应该是不会看到自身插入的行的, 毕竟 PG planner 针对 INSERT/UPDATE/DELETE SQL 生成的执行计划中, 负责实际插入/更新的 ModifyTable plan node 总是位于 plan tree 最顶层, 即当实际插入/更新操作发生时, 扫描操作已经执行结束了. 那么为啥还需要 cmin 呢?

后来和同事讨论了一下, cmin 的目的应该主要还是在于实现事务隔离级别. PG SnapshotData 中是有 curcid 这个字段记录着当前快照对应的 commandid 的, 在持久化 cmin 的情况下, 某个特定 tuple 是否对特定的 snapshot 是否可见就可以直接比较 tuple 中的 cmin 与 snapshot 中的 curcid 就行. 之后对于 Read Committed 隔离级别下的事务, 由于其 snapshot 每次查询时都会获取, 因此其 SnapshotData.curcid 为待执行查询对应的 commandid, 在 tuple 可见性判断时, 其就能看到同一事务内之前查询执行的效果. 对于 Repeat Read 隔离级别的事务, 其 snapshot 在事务开始时获取, 即 SnapshotData.curcid 取值为 0, 因此其看不到自身事务查询执行的效果.

但如果仅是这目的的话, 我们也可以通过在 SnapshotData 加个字段指定其所在事务的事务隔离级别, 之后在可见性判断时, 针对同一事务更新的 tuple, 若 snapshot 指定事务隔离级别是 Read Commited, 那么 tuple 对自身可见. 若 snapshot 指定事务隔离级别是 Repeat Read, 那么 tuple 则对自己不可见.

所以还是不晓得是否真的需要 cmin/cmax..

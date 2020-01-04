---
title: "PG/GP 学习杂烩"
hidden: true
tags: ["Postgresql/Greenplum"]
---

这里记录着对 Postgresql/Greenplum 代码学习期间总结记录的一些东西, 这些东西大多篇幅较小(或者质量不高...), 以至于不需要强开一篇 POST.

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
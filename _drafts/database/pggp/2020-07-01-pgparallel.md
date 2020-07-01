---
title: "PG Parallel Query"
hidden: true
tags: ["Postgresql/Greenplum"]
---

根据 PG12 文档加入少许的猜测总结而来.

首先看下执行器提供的能力. 执行器提供 Gather, Gather Merge, Parallel Append, Parallel HashJoin 这类支持起 parallel worker 的算子. 具体来说 Gather/Gather Merge 在 Init 执行时会启动多个 parallel worker 来运行其 lefttree 指向的 plan tree. 在 Gather/Gather Merge Next() 时会首先检测 parallel worker 有无已经准备好的 tuple, 如果有就使用这个 tuple. 如果没有就自己执行 lefttree, 也即 backend 也会执行 lefttree 的. 如果 parallel worker 会吐出大量的数据, 可以看到 backend 基本上所有的操作都在处理 paraller worker 吐出的数据上, 其 lefttree 虽然会执行, 但基本上不会再生成有效数据. 也即 backend lefttree 与 parallel worker lefttree 的工作负载是动态分配的, 能者多劳. Gather/GatherMerge 所启动的 parallel worker 数目由优化器确定, 执行器实际启动的数目受限于系统资源可能会小于优化器确定的 parallel worker. 参见 15.3. Parallel Plans 了解各种 plan 在 Gather 下时的工作行为. 

Parallel Append; Parallel Append node can have both partial and non-partial child plans. Non-partial children will be scanned by only a single process. The executor will instead spread out the participating processes as evenly as possible across its child plans, so that multiple child plans are executed simultaneously. Append 另一种 parallel 的方式是挂在 Gather/GatherMerge 下面, 此时 When an Append node is used in a parallel plan, each process will execute the child plans in the order in which they appear, so that all participating processes cooperate to execute the first child plan until it is complete and then move to the second plan at around the same time. 并且此时 Append 下面 can only have partial children.

Parallel HashJoin; the inner side is a parallel hash that divides the work of building a shared hash table over the cooperating processes. HashJoin Gather 并行方式: In a hash join (without the "parallel" prefix), the inner side is executed in full by every cooperating process to build identical copies of the hash table. 


再看下优化器的能力. 就是根据执行器提供的并行能力加入到候选 pathlist 中, 最后结合 cost 确定最优计划. 

partial plan; partial plan 吐出的数据是完整正确数据的一部分. 很显然 partial plan 应该挂在 gather/gather merge 之下.
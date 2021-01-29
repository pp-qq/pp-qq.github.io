---
title: "Greenplum 从自适应调度到 Concurrency Scaling"
hidden: false
tags: ["Postgresql/Greenplum"]
---

自去年提出了 [Greenplum 自适应调度]({{site.url}}/2020/09/21/adaptive-schedule/) 的想法, 到最近把这套自适应调度推到我们线上, 这期间也对最初提出的想法又做了一系列加强, 也进一步加深了对 Greenplum 执行框架的理解. 关于 Greenplum 执行框架这里不在做过多介绍, 可以参阅之前的文章. 简单来说, 在优化结束, 执行计划确定了之后, GP 会遍历 plan tree, 之后以 Motion 节点为边界将执行计划切分为多个 slice, 同时这里还会确认每一个 slice 的并发度, 以及 slice 需要调度到哪些 segment 上执行. 在自适应调度之前, 每个 slice 并发度固定都是集群中 primary segments 的个数. 很显然这不是很合适, 因为如果 planner 发现 slice 实际上要处理的行数寥寥无几, 那么我们应该适当减少 slice 并发度的. 反之, 如果 planner 发现 slice 要处理的行数会有点多, 那么应该适当增加 slice 并发度. 所以自适应调度, 这里的自适应就是指根据 slice 待处理的数据量来自适应调整 slice 的并发度, 从最小为 1, 最大为 primary segments 数目乘以一个预定义最大并发系数. 这个其实就类似于 Spark 3.0 'Coalescing Post Shuffle Partitions', 只不过 Spark 3.0 是根据实际执行过程中, 上游 slice 实际吐出的行数来决定下游 slice 的并发度. 而 Greenplum Motion 节点是流式的, 不会落盘, 所以无法做到执行期间, 只能放在 planner 这里. 放在 planner 这里有个缺陷, 就是 planner 预估行数可能不准... 所以任重而道远..

在把自适应调度 1.0 推到线上之后, 接下来免不了要想一下接下来的路该怎么走, 而且就很突然, Concurrency Scaling 就忽然跳入到我的脑海. 自从看到 Redshift 2019 年 3 月份推出了 Concurrency Scaling, 就一直对这个特性念念不忘, 你想想啊, 在 Concurrency Scaling 之后, 用户可以只需要买存储资源, 计算资源完全可以共用一个大池子, 用户查询会在需要的时候从大池子中拉出更多的节点来对查询进行加速, 这性价比得多高啊. 当时惊为天人, (非常幼稚地)心想, 新增节点少不了要把数据也整过去啊, 是怎么秒级把数据拷贝过去的?? 现在在自适应调度框架内也意识到了, 对于那些执行起来不依赖集群状态的 slice, 其实调度到哪里执行都无所谓地. 而对于 Greenplum 来说, 除了 Scan 这类算子必须要依赖集群状态, 其他的算子都已经是集群状态无关, 或者可以改造为集群状态无关. 就像 Hash Join 虽然执行起来会读取统计信息来确认 bucket number, 但这种行为可以放在 slice 下发之前执行, 也就是将所有需要获取集群状态的操作都放在下发之前执行, 下发之后算子的实际执行完全与集群状态无关. 这个时候确实可以临时创建几个节点, 然后将 slice 调度过去.


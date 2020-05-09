---
title: "GP 存储计算分离的一种实现"
hidden: false
tags: ["Postgresql/Greenplum"]
---

## 效果

和 presto 中将执行计划切分为多个 Stage 一样, GP 也会将执行计划切分为多个 Slice, 每一个 slice 表示着执行的一个阶段. 在优化阶段, 在 PG 优化器的基础之上, GP 会根据表数据的分布策略在合适的地方加入 Motion 节点, Motion 节点用来根据需要对数据进行重分布. 在优化结束, 执行计划确定了之后, GP 会遍历 plan tree, 之后以 Motion 节点为边界将执行计划切分为多个 slice, 同时这里还会确认每一个 slice 需要调度到哪些 segment 上执行. 以如下查询为例:

```sql
segmentexpand=# explain select * from localtable t1 inner join foreigntable t2 on t1.col1 = t2.col1;
                                                                        QUERY PLAN                                                                         
-----------------------------------------------------------------------------------------------------------------------------------------------------------
 Gather Motion 3:1  (slice2; segments: 3)  (cost=100.13..808.32 rows=45 width=88)
   ->  Hash Join  (cost=100.13..808.32 rows=15 width=88)
         Hash Cond: (t1.col1 = t2.col1)
         ->  Seq Scan on localtable t1  (cost=0.00..542.00 rows=14734 width=44)
         ->  Hash  (cost=100.12..100.12 rows=1 width=44)
               ->  Redistribute Motion 3:3  (slice1; segments: 3)  (cost=0.00..100.12 rows=1 width=44)
                     Hash Key: t2.col1
                     ->  Foreign Scan on foreigntable t2  (cost=0.00..100.10 rows=1 width=44)
                           Oss Url: endpoint=oss-cn-hangzhou-zmf-internal.aliyuncs.com bucket=adbpg-regress dir=NOTEXISTSforeigntable/ filetype=plain|text
                           Oss Parallel (Max 4) Get: total 0 file(s) with 0 bytes byte(s).
 Optimizer: Postgres query optimizer
```

这里 localtable 是本地 heap 表, 以列 col1 作为分布列. foreigntable 则是一个 foreign table. 上述查询计划如下图所示:

{% mermaid %}
graph TD;
    subgraph "slice1 (gangsize: 3)";
    FS(ForeignScan) --> |t2.col1| RM(RedistributeMotion 3:3);
    end;
    subgraph "slice2 (gangsize: 3)";
    RM --> H[Hash];
    SS[SeqScan] --> HJ[HashJoin];
    H --> HJ;
    HJ --> GM[GatherMotion];
    end;
{% endmermaid %}


在该查询计划之中总共有两个 slice, 其中 slice1 负责执行 ForeignScan 算子拉取数据之后, 按照 col1 列将数据重新哈希分布. slice2 则是读取 slice1 重分布之后的结果然后进行 hashjoin. 此时对于 slice2, 由于他需要读取 SeqScan 本地表, 所以 GP 会将 slice2 调度到所有 primary segment 上执行. 而对于 slice1, GP 仍然是选择将 ForeginScan 调度到所有 primary segment 上执行. 

在具体执行时, GP 会在每一个 primary segment 创建出两个 QE, 分别负责 slice1, slice2 的执行. 以 primary segment A 的视角为例, 在如上查询执行时, master 上的 QD backend 会使用 libpq 协议连接 A 对应 postmaster, 在 A 下创建出两个 QE backend: QE_A1, QE_A2; 其中 QE_A1 会负责执行 slice1, 他会执行 ForeignScan 算子, 将 scan 返回的每一行按照列 col1 哈希之后分发到 slice2 对应的 QE 中. QE_A2 负责执行 slice2.

但其实这并没有必要限制 slice1 只能有三个 QE. slice1 并没有涉及到本地数据的访问, 他是一个纯计算性质的 slice, 因此我们并不必要限制 slice 对应 QE 的数目. 扩展来说, 对于执行计划中纯计算任务的 slice, 我们并没必要限制 slice QE 数目为集群中 primary segment 数目. 如下在我对 GP 优化器/执行器进行一番魔改之后:

{% mermaid %}
graph TD;
    subgraph slice1;
    FS(ForeignScan) --> |t2.col1| RM(RedistributeMotion 6:3);
    end;
    subgraph slice2;
    RM --> H[Hash];
    SS[SeqScan] --> HJ[HashJoin];
    H --> HJ;
    HJ --> GM[GatherMotion];
    end;
{% endmermaid %}


这里 slice1 对应的 QE 数目是 6 个, 是集群 primary segment 数目的两倍. slice2 由于涉及到本地数据访问, 其 QE 数目仍然是集群中 primary segment 的数目: 3 个. 在执行时, 每一个 primary segment 下都会创建出 3 个 QE, 其中两个负责执行 slice1, 另一个负责执行 slice2. 

理论上, 由于纯粹计算性质的 slice 对应 QE 数目增加了, 即查询执行并发度进一步增加了, 查询本身的耗时将会进一步降低, 当然一条查询耗费的资源也增加了.

## 实现

详细细节参考 [CodeReview](https://github.com/hidva/gpdb/compare/use-more-qe-for-computing-slice%5E1...hidva:use-more-qe-for-computing-slice). 这里概括下大概, 以及背后为何改动的原因:

1.  在优化器确定执行计划之后. 我们遍历每一个 PlanSlice, 在 GP 中, 通过 PlanSlice 来表示着查询执行计划中一个 slice. 对于每一个 PlanSlice, 若其满足如下要求:

	-	对应着 reader gang, 即不涉及到数据写操作; 
	-	PlanSlice 所对应的计划树 T 中不含有 SeqScan, IndexScan 等这类会涉及到本地数据访问的算子; 
	-	其子 PlanSlice 对应的 Motion 节点的 MotionType 不是 explicit motion, gather motion, explicit/gather motion 意味着当前 PlanSlice 的调度取决于子 PlanSlice. 

        这里有个小问题, 如果此时 MotionType 是 MOTIONTYPE_BROADCAST, 那么我们是否还需要增加当前 PlanSlice QE 数目? 虽然 QE 数目的增加使得当前 PlanSlice 执行并行度上来了, 但 broadcast motion 也意味着数据传输量也提升了, 所以这需要抉择一下..

	-	PlanSlice 并不能 direct dispatch

	那么表明当前 PlanSlice 是一个纯粹地计算性质的 slice, 其对应 QE 数目可以随意调整. 此时我们会按照 GUC 的配置调整 PlanSlice::numsegments. 比如将其调整为集群中 primary segment 数目 * 一个固定倍数 segment_expand.
	
2.	在执行器开始时, GP 会调用 InitSliceTable() 将 PlanSlice 转换为对应的 ExecSlice, ExecSlice 除了存放 PlanSlice 具有的信息之外, 还存放着一些执行相关的信息, 比如当前 Slice 对应着哪些 QE backend 等. 这里我们根据 PlanSlice::numsegments 来填充 ExecSlice::segments, ExecSlice::segments 中存放着 content id 列表, 指定了当前 slice 需要调度到这些 content id 对应的 primary segment 上.
	
    比如如果当前集群中共有 3 个 primary segment, GUC segment_expand 配置为 2, 那么 ExecSlice::segments 取值为 `{0, 1, 2, 0, 1, 2}`, 即对应着 6 个 QE, 每一个 Primary segment 下会创建 2 个 QE backend.
	
    当然这里延伸来讲, 我们可以根据集群中 primary segment 的负载来调整准备调度到该 primary segment 的 QE 数目. 比如如果发现由于计算倾斜 primary segment 0 负载较轻, primary segment 2 负载较重, 那么如上 ExecSlice::segments 可以是 `{0, 0, 0, 1, 1, 2}`, 即 primary segment 0 会创建出 3 个 QE backend, 而 primary segment 2 只需要创建出 1 个.

3.  新增全局变量 QEIDInSlice, 表示着当前 QE 在其所属 slice 中的 id, 实际上是当前 QE 在 slice primaryProcesses 中的下标. QEIDInSlice 语义等同于 GpIdentity.segindex. QE 会在 exec_mpp_query() 收到 slice table 之后更新 QEIDInSlice.

4.	在 execMotionSender() 中, 若 motion->motionType == MOTIONTYPE_GATHER_SINGLE, 意味着当前 send slice 中只需要返回 1 个 QE backend 上的执行结果. 此时会将 GpIdentity.segindex 替换为 QEIDInSlice. QEIDInSlice 记录着当前 QE 在其所属 slice 中的 id, 从 0 开始.

5.	在 ExecResult() 中, 调整 TupleMatchesHashFilter() 函数中 GpIdentity.segindex 为 QEIDInSlice. 
6.	getChunkSorterEntry(), EndMotionLayerNode() 中, 将 getgpsegmentCount() 替换为 num_senders. 因为此时 sender slice QE 的数目并不一定是 getgpsegmentCount() 了.
7.	(可选)调整下 ic_htab_size. 原取值为  `getgpsegmentCount() * 2`, 替换为 `getgpsegmentCount() * segment_expand * 2`.


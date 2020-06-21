---
title: "一次'失败'的尝试"
hidden: false
tags: ["Postgresql/Greenplum"]
---

## 前言

这个工作的起因是因为某一天在回家的路上我忽然想到了 java 中的 BufferedInputStream. BufferedInputStream 通过为底层各种 InputStream 引入了缓冲区的能力使得读取底层 InputStream 的效率大幅度提升. 那么这个能不能类比到 PG 中呢, 也即能不能引入一个 buffered plan node, buffered plan node 在执行时会首先批量执行其子 plan node, 填充缓存结果行, 之后会从缓存的结果行中吐出一行给上层. 以 `SELECT count(1) FROM lineitem` 为例, 此时 plan tree 如下:

```
 Aggregate
   ->  Seq Scan on lineitem
(2 rows)
```

引入 buffered plan node 之后:

```
 Aggregate
   ->  BufferedPlan
         ->  Seq Scan on lineitem
```

当 Aggregate 需要拉取数据时, BufferedPlan 便会从自身缓存中高效快速地吐出数据, 对于 Aggregate 看来, 这个取数据就像是自身 PlanState 中某个缓冲区取数据一样, 因此 Aggregate 的执行模式会比较固定, 局部性会比较好. 同样地将 BufferedPlan 发现缓冲区没有额外数据时, 会批量执行 SeqScan 来拉取数据, 这样 SeqScan 的执行模式也比较固定, 局部性也比较好. 

也就是说在引入 BufferedPlan 之后, 每个算子在执行时的执行模式都会变得更加固定, 相应地局部性效果就非常好, 这就因此带来了 cache miss, branch miss 等的降低. 反应到查询, 可能会带来查询时间的降低. 

## 第一次尝试

第一次尝试就是把上面的思想编码实现集成到 PG 中, 为此我们额外加入了一个 BufferedPlan.

```c++
struct BufferedPlan {
    Plan plan;
    size_t batchsize;
};
```

之后在优化器完成 plan tree 的生成之后, 我们会遍历 plan tree, 在每一个 plan node 之上加一个 BufferedPlan. PG 中某些 plan node 的子 plan node 并不是位于 lefttree, righttree 中, 如 Append 算子. 在本次 POC 中, 我们并未考虑这类节点. 

```c++
Plan*
AddBuffered(Plan *plan)
{
    if (plan == NULL)
        return NULL;
    if (list_length(plan->initPlan) > 0)
        elog(ERROR, "plan->initPlan isn't empty");
    if (plan->lefttree != NULL)
        plan->lefttree = AddBuffered(plan->lefttree);
    if (plan->righttree != NULL)
        plan->righttree = AddBuffered(plan->righttree);
    BufferedPlan *ret = makeNode(BufferedPlan);
    copy_plan_costsize(&ret->plan, plan);
    ret->plan.targetlist = plan->targetlist;
    ret->plan.lefttree = plan;
    ret->batchsize = buffer_plan_size;  // maybe decided by child plan type.
    return (Plan*)ret;
}
```

之后 BufferedPlan 执行逻辑就比较直观了. 不过在实现上也是忽然意识到 PG 为了减少对内存的使用, ExecProcNode() 返回的 tuple 仅在 tuple memory context 中, 也即返回 tuple 在下次 ExecProcNode 调用时便不再有效, 因此 BufferedPlan 为了缓存 tuple, 必须要对每一个 tuple 做一次物化:

```c++
TupleTableSlot*
ExecBufferedPlan(PlanState /* BufferedPlanState */ *node)
{
    BufferedPlanState *pnode = (BufferedPlanState*)node;
    if (likely(pnode->bufferptr < pnode->buffers.size()))
        // 若当前 buffered plan node 中仍有缓存的数据, 则直接从缓存中吐出数据.
        return ExecStoreMinimalTuple(pnode->buffers[pnode->bufferptr++], pnode->ps.ps_ResultTupleSlot, false);

    // buffered plan node 已经没有缓存的数据了, 需要从子 plan node 再拉取一批数据.
    if (unlikely(pnode->is_done))
        // 子 plan node 已经执行完毕, 则不再拉取, 直接返回 NULL.
        return NULL;

    // 子 plan node 仍未执行完毕, 继续拉取. 拉取之前释放一下上次缓存的资源.
    MemoryContextReset(pnode->buffermctx);
    pnode->buffers.resize(0);
    pnode->bufferptr = 0;

    // 开始实际拉取数据
    for (size_t idx = 0; idx < ((BufferedPlan*)node->plan)->batchsize; ++idx) {
        auto *slot = ExecProcNode(outerPlanState(node));
        if (unlikely(TupIsNull(slot))) {
            pnode->is_done = true;
            break;
        }
        auto oldmctx = MemoryContextSwitchTo(pnode->buffermctx);
        pnode->buffers.push_back(ExecCopySlotMinimalTuple(slot));  // 需要一次物化
        MemoryContextSwitchTo(oldmctx);
    }
    if (unlikely(pnode->bufferptr >= pnode->buffers.size()))
        return NULL;
    return ExecStoreMinimalTuple(pnode->buffers[pnode->bufferptr++], pnode->ps.ps_ResultTupleSlot, false);
}
```

BufferedPlan 在执行时每一行都需要物化的操作意味着这一版本的性能注定不会太好. 实际测试结果也表明了这一事实.

## 加入 block memory context

那么我们能不能去掉每行都要物化的代价呢? 之所以物化是因为 PG 中 plan node 数据交互是以 tuple 为单位的, 所以 PG 中每一行是位于 tuple memory context 之中的, 每次 plan node 在执行时都会 reset tuple memory context 从而使得上次执行时吐出的 tuple 不再有效. 这是合理并且可以节省内存的操作. 那么既然我们引入了 buffered plan node, 也即意味着 plan node 之间数据交互的单位类似于 presto 中那样, 不再是以 tuple 为单位, 而是以 page(block) 为单位的. 相应地我们也需要引入 block memory context. 为了快速验证, 我们并没有实际引入 block memory context, 而是直接快速粗暴地禁止对 memory context 进行 reset 操作:

```c
void
MemoryContextReset(MemoryContext context)
{
    return;
}
```

同样考虑到 SeqScan/ForeignScan 返回的 tuple slot 总是 ss_ScanTupleSlot, 而且 heap_getnext() 返回的 HeapTuple 也总是一块固定的内存, 如果以 seqscan 为原型改动太大. 所以这里我们以 ForeignScan 链路为原型进行 POC. 既然我们现在以 block 为单位来交换数据了, 那么相应地需要把 scan tuple slot 也扩展成 block 的. 为此我们扩展了 ForeignScanStat 到 BufferedForeignScanState, 引入了 TupleTableSlot 数组来表示 block scan tuple slot:

```c
typedef struct BufferedForeignScanState {
    ForeignScanState scan;
    TupleTableSlot *buffers;  // capacity: buffered_scan_cap
    int buffersize;
    int bufferidx;
    bool is_done;
} BufferedForeignScanState;
```

```c
BufferedForeignScanState*
ExecInitBufferedForeignScan(ForeignScan *node, EState *estate, int eflags)
{
    // ...
    state->buffers = palloc0(sizeof(TupleTableSlot) * buffered_scan_cap);
    for (int i = 0; i < buffered_scan_cap; ++i)
    {
        TupleTableSlot *slot = &state->buffers[i];
        slot->type = T_TupleTableSlot;
        slot->tts_isempty = true;
        slot->tts_mcxt = CurrentMemoryContext;
        ExecSetSlotDescriptor(slot, RelationGetDescr(scanstate->ss.ss_currentRelation));
        estate->es_tupleTable = lappend(estate->es_tupleTable, slot);
    }
}
```

同时 buffered foreign scan node 的执行逻辑也被相应地简化了, 主要是 buffered plan state 中 buffers 中直接缓存 tuple 指针, 而不再是物化后的结果.

之后以 TPCH 1G 为例, 可以看到在 buffered foreign scan 加成下, 查询时间确实会降低一些, 提升了约 11%. 不开启 buffered foreign scan, 耗时 25691.207 ms. 开启之后在 buffered_scan_cap=2048 时性能达到最佳为 22782.283 ms. 而且从 perf state 也可以看到这里在开启 buffered foreign scan 之后, branch-misses, L1-dcache-miss 等都有了显著地降低. 具体来说 L1-dcache-load-misses 从 2.48% 降低到 0.58%, L1-dcache-store-misses 从 0.68% 降低到了 0.25%, branch-misses 从 1.17% 降低到 1.06%, IPC 从 1.73 提升到 1.96, 这也印证了最开始所说的:

>   也就是说在引入 BufferedPlan 之后, 每个算子在执行时的执行模式都会变得更加固定, 相应地局部性效果就非常好, 这就因此带来了 cache miss, branch miss 等的降低. 反应到查询, 可能会带来查询时间的降低. 

完整源码已经上传到 [hidva/postgres](https://github.com/hidva/postgres/tree/bufferplan-poc). 有需要的可以直接下载编译使用即可.

## 后语

写到这里的时候, 整篇文章完全违背了他最开始的意图, 本来这篇文章是想

-   展示一种通用的 buffered plan node. 最近看了很多向量化执行相关的论文, 可以看到向量化最大的好处就是在于固化了每个算子的执行模式, 使得局部性原理得到了最大化的应用, 相应地性能表现也就非常优秀. 所以我也因此想出了 buffered plan node, 毕竟在 buffered plan node 加成下, 每个 plan node 的执行模式也能固化使得局部性效果应该也不差. 但受限于 PG 中 plan node 之间以 tuple 为单位交换数据, 各个模块算子在实现上也都重度依赖了这一约定, 使得 buffered plan node 设想以失败而告终... ~~实际上如果 buffered plan node POC 成功的话, 我最开始设想的文章标题是 "50行代码让你的 PG 性能再翻 XX!"...~~

-   展示 C++ 相较于 C 的优异性. 从最开始的 buffered plan node 也可以看出 buffered plan node 是 C++ 实现的, 代码量也相对较少. 我在日常 PG 开发中越来越感觉到 C 开发效率的落后, 所以就想借此计划展示一下. 可 buffered plan node POC 的失败使得这一计划也灰飞烟灭了... ~~不过我和几个小伙伴私底下也正在用 C++ 加多线程重写整个 PG. 希望能赶到 9.6 deadline 之前完工==~~

😌


## PG/GP EXPLAIN

### EXPLAIN JSON

本节介绍了 PG 的 EXPLAIN JSON/YAML 的输出格式, 简单来说 PG 会将输出组织成数组的形式: `[ Query , Query ]`, 之所以是数组是因为 PG 考虑到用户的一个查询经过 query rewriter 之后可能会有多个查询的情况, 这里每一个 Query 就表示着 rewritten 之后一个查询的执行计划. 在 Query 中, 如下所示又存在了多个属性, 其中 `"Plan"` 便是 Query 计划树的根节点.

```json
{
  "Plan": {
    /* plan node 的一些属性 */
    "Plans": [  /* Plans 中存放着当前 plan node 子 plan 集合. */
      { /* a plan node */ },
      { /* a plan node */ },
    ]
  },
  "Setting": {}
}
```

### PG EXPLAIN ANALYZE

当用户对某个查询使用了 EXPLAIN ANALYZE 时, PG 会按照常规链路对查询进行优化, 执行. 只不过在执行时 PG 会告诉执行器需要在执行时采集 plan node 的运行状态. 具体做法参见 ExplainOnePlan() 函数, PG 会根据用户 EXPLAIN ANALYZE 的选项构造出 InstrumentOption, 之后作为参数传递给 CreateQueryDesc(), 经由 QueryDesc::instrument_options, 传递给 EState::es_instrument. 之后在 ExecInitNode() 中当检测到 EState::es_instrument 设置之后, 调用 InstrAlloc() 来初始化每一个 plan state PlanState::instrument 字段; 再之后就是 ExecProcNode() 时当检测到 PlanState::instrument 被设置时, 便收集并更新相应的统计信息. 最后在查询执行完毕之后, PG 会遍历 plan state tree, 根据 plan state 中 PlanState::instrument 字段记录的统计信息来生成 explain analyze 的结果.

### GP EXPLAIN ANALYZE

GP EXPLAIN ANALYZE 链路与 PG 版本大致上是一样的, 当然考虑到 GP 是分布式执行, 所以在执行统计信息收集上还是有点区别的. 具体便是当 QE 完成当前 slice 执行时, 其会收集当前 slice 所有 plan state PlanState::instrument 字段中记录的统计信息, 以一种特殊方式序列化之后通过一个特别的 libpq 消息发送给 QD. QD 在收集到一个 slice 所有 QE 发来的统计信息之后, 会进行计算汇总之后, 得到 slice 中每一个 plan state 全局执行的相关统计信息之后保存在自身 plan state tree 中, 也即当 QD 侧执行结束时, 便与单机 PG 一样, plan state PlanState::instrument 中已经存放着相关的统计信息了. 之后复用 PG explain 的链路完成统计信息的输出.

#### QE -> QD

在 QE 完成自身 slice 执行之后, 会在 standard_ExecutorEnd() 中调用 cdbexplain_sendExecStats() 函数序列化自身 slice plan state 中统计信息, 之后通过 'Y' 消息发送给 QD. QE 发送给 QD 的 explain analyze 序列化消息由如下几个部分组成:

1.  CdbExplain_StatHdr, 准确来说是从 `[CdbExplain_StatHdr.type, inst)` 这部分作为 header.
2.  多个 CdbExplain_StatInst, 当前 slice 中每一个 plan state 都对应着一个 CdbExplain_StatInst 结构体, 存放着 plan state 执行统计信息.
3.  notebuf, 每个 plan state 除了数值型统计信息之外可能还会有字符串的统计说明, 这些字符串型的值统一放在 notebuf 中, CdbExplain_StatInst::bnote, enote 表明当前 plan state 字符串说明在 notebuf 中的偏移与长度. 在 notebuf 中, 各个 plan state note 之间用 '\0' 分隔. 最后一个 plan state note 也会以 '\0' 结尾.

在 CdbExplain_StatInst, notebuf 中, plan state 的顺序由 planstate_walk_node() 遍历顺序决定. 

#### QD 汇总


		// 这里若 primaryWriterSliceIndex 为 0, 则表明当前查询纯读, 此时 QD 上的 es_processed 已经是精确数据了.
		// 不再需要汇总 QE 结果. 实际执行上, 这里 cdbdisp_sumCmdTuples()/cdbdisp_maxLastOid() 应该都会返回 0.
		// 当 primaryWriterSliceIndex 不为 0 时, 此时 primaryWriterSliceIndex 指定了那个会写数据的 slice, 
		// 此时会汇总该 slice 下所有 QE 执行结果.

'Y' 与 'C' 被合并为一个 result. pqParseInput3.
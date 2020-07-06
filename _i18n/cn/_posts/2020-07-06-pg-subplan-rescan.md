---
title: "PG 中的 SubPlan, ReScan"
hidden: false
tags: ["Postgresql/Greenplum"]
---

之前在尝试为 [ADB PG](https://aliyun.com/product/gpdb) 加入[弹性调度]({{site.url}}/2020/05/09/compute-storage/) 能力, 在调试期间, 曾经遇到一个非常诡异的 bug, 结果时对时不对. 当时触发这个 bug 的查询非常复杂, 使用了大量的子查询, 所以一度让我怀疑是不是弹性调度未做好子查询情况下的适配. 所以当时便去看了下 PG/GP 中子查询的优化执行链路, 最终发现是因为 double 类型精度问题导致地正常现象 :-(! 这篇文章试图从子查询在编译之后的中间表示, 到子查询优化之后的中间表示, 再到子查询的执行模型从头到尾地描述下 PG 中的子查询. 这篇文章注重从整体链路上来描述子查询, 并不会过多地关注于代码上的具体实现. 

这里所说的子查询是指出现在表达式中的子查询, 比如如下查询:

```sql
-- Q1
select * from t where c4 <= (select min(j) from t1);
-- Q2
select * from t where c4 <= (select min(j) from t1 where i = t.c1);
-- Q3
select * from ta where (tac1, tac2) < (select tbc1, tbc2 from tb where tbc1 = tac1);
```

这里 `select min(j) from t1`, `select min(j) from t1 where i = t.c1` 便是子查询. 以 Q1 为例, 用户此时期望的语义是: 首先扫描 t1 表, 得到 j 的最小值, 之后筛选出 t 中所有 c4 不大于 j 最小值的行. Q2 的语义则是: 对于表 t 中的每一行, 都执行一下 `select min(j) from t1 where i = t.c1` 得到所有满足条件行中 j 的最小值, t.c1 会被替换为当前扫描表 t 行中 c1 列的值; 之后再判断 t.c4 是否不大于此时的 min(j), 若 t.c4 <= min(j), 则表明当前 t 表的行符合筛选条件, 应该返回. 否则表明当前行不满足筛选条件, 不应该返回.

## 语义分析与优化

SubLink; 在对查询进行语义分析之后, PG 使用 SubLink 来表明表达式中的子查询. SubLink 自身也是 PG 表达式体系成员之一, 与 OpExpr 等一样都是 Expr 的子类. 参见 SubLink 注释了解不同场景下的子查询对应的 SubLink 对象预计长啥样. 以如上 Q3 查询为例, 使用 gdb 断在 `standard_planner()` 可以看到此时查询的过滤条件是一个 Sublink:

```
(gdb) p *parse->jointree->quals
$3 = {type = T_SubLink}
(gdb) p nodeToString(parse->jointree->quals)
```

此时 SubLink::testexpr 记录着 `(tac1, tac2) < (select * from tb where tbc1 = tac1);` 这个条件, 具体来说 testexpr 中信息是 `(Var{tac1}, Var{tac2}) < (PARAM_SUBLINK{paramid=1}, PARAM_SUBLINK{paramid=2})`; 这里使用了两个 PARAM_SUBLINK 实例来代替 `(select * from tb where tbc1 = tac1)`; SubLink::subselect 记录着 `select * from tb where tbc1 = tac1`, 根据 SubLink 注释可以看到这里 subselect 至多只能返回一行; 这里两个 PARAM_SUBLINK 对象对应着 subselect 执行输出一行中的两个列, paramid 便是 Param 所对应列的编号. 此时整个查询执行流程大概是, 每扫描出 ta 表中的一行, 都对 SubLink::subselect 进行求值, 并使用求值结果替换掉 testexpr 中 PARAM_SUBLINK 对象, 之后再对 testexpr 进行求值对 ta 表扫出的一行进行过滤.

Param; PG 中 SubPlan 的实现严重依赖着 PG Param 模块, 因此我们这里先提一下 Param. Param 与 Var 起着差不多的语义, 都用做表示一个值的变量. 在运行时, Var 变量对应的值是从 ExprContext 中某个 tuple 某个列中获取. 而 Param 对应的值则是从一个数组中获取, 每个 Param 都有一个唯一的 id 表明自己在该数组中的下标.  

可以很直观的看到对于一个查询来说, 表达式中的子查询, 以及子查询中表达式的子查询组成了一个查询树的结构. 因此对子查询的优化也是树型的. 具体来说在 standard_planner() 中调用 subquery_planner() 完成对 top-most 查询的优化时, subquery_planner() 会调用 preprocess_expression() 来完成表达式预处理, preprocess_expression() 内部如果发现表达式是 SubLink 类型, 便会调用 SS_process_sublinks() 进行处理, 此时会递归调用 subquery_planner() 对 sublink 对应的子查询进行优化. 并将优化之后生成的 plan tree 与 SubPlan 对象追加到 PlannerGlobal::subplans 等字段中. 考虑到这里 PG 采用深度优先的次序来优化查询树, 因此在 PlannerGlobal::subplans 中, 位于叶子节点的子查询会先于她的父节点. PlannerInfo::query_level 记录着当前查询在查询树中所在的层次, 位于查询树根节点的查询 level 为 1, 之后依次以 1 递增; PlannerInfo::parent_root 记录着当前查询的父查询.

目前看来, 子查询处理的逻辑主要由函数 subquery_planner() 来完成. 对于 grouping_planner(), query_planner() 这类函数是没有太过于关注查询是否是子查询, 以及查询是否包含子查询.

SubPlan, 在对子查询进行优化之后, PG 使用 SubPlan 来作为子查询的中间表示. 这里不严谨地介绍下子查询的求值方式. 若在对 SubLink 优化之后, 发现 SubPlan 是个 init plan, 即 SubPlan 不依赖父查询的任何变量, 但可能会依赖祖先查询的某些变量, 那么便会将 SubPlan 存放在父查询 top most Plan::initPlan 字段中. 具体来说在 build_subplan() 中若发现子查询是个 init plan 便将其追加到父查询 PlannerInfo::init_plans 中. 之后在父查询 create_plan() 时通过 SS_attach_initplans() 将子查询 attach 到父查询 top most Plan::initPlan 中. 之后父查询开始运行时, 会首先执行 topmost Plan::initPlan 中的 init plan, 并将结果保存在 SubPlan::setParam 对应的 param id 中, 之后再执行父查询本身. 若优化之后, 发现 SubPlan 不是个 init plan, 即 SubPlan 的运行依赖父查询的某些变量, 那么 SubPlan 会被放入表达式所在 plan node 中(此时 SubPlan 直接作为表达式的一部分存放在表达式树中), 之后在对表达式进行求值时运行 SubPlan, 具体来说 PG 会首先在 outer query context 下求解 args, 之后将结果保存在 parParam 指定的 param exec 中, 此时 subplan 对外界的 param 依赖已经全部求解了. 之后 PG 会运行 subplan plantree, 并将结果保存在 paramIds 指定的 param 中. 之后再对 testexpr 进行求解得到结果.

AND/ANY SubPlan 不可能是 init plan; 从 build_subplan() 的实现可以看出, 对于 ANY_SUBLINK/ALL_SUBLINK 的 subplan, 即使 SubPlan::parParam 为空, 也不会是 init plan. 我这里猜想可能是因为 SubPlan::testexpr 的缘故. AND/ANY SubPlan 除了 subselect 部分之外, 还有个 testexpr 部分. SubPlan::parParam 为 NULL 只是意味着 subselect 部分不依赖父查询, 但 testexpr 并不确定. 比如 `select * from ta where tac1 > ALL (select tbc1 from tb);`, 这里 subselect 并不依赖父查询, 即 SubPlan::parParam 为 NULL, 但 testexpr 左侧操作数就是父查询的列, 即依赖父查询, 所以不能作为 init plan. 

## Var 与 Param

Var, 在语义分析之后, 若子查询依赖了外部查询的变量, 那么子查询中该变量对应 Var 对象 varlevelsup 字段将为一个大于 0 的适当值, 记录着 Var 来源父查询相对于当前子查询的级别. 比如若有查询结构: A -> B -> C, 其中 C 这个子查询依赖了 A, B 子查询的列. 那么 C 对 B 中列的 Var::varlevelsup 为 1, 对 A 中列的 Var::varlevelsup 为 2. 在 subquery_planner() 中 preprocess_expression() 这步中会调用 SS_replace_correlation_vars() 函数来收集当前查询中所有引用 outer query 的变量, 并为它们分配相应的 param id, 之后将它们替换为对应的 PARAM. 为了让 outer query 知道其内哪些变量被引用着, 以及实现相同的变量具有相同的 param id. 每层查询都会在其对应的 PlannerInfo 中通过 plan_params 字段维护着一个类似 `std::map<Var, paramId>` 的结构, 一方面可以在子查询结束之后, 通过其父查询 PlannerInfo::plan_params 得知子查询引用了哪些变量. 另一方面也确保了相同的变量可以具有相同的 paramId. 如: `select * from ta where ta.c1 > (select tb.c1 from tb where tb.c1 < ta.c1 and tb.c2 > ta.c1)`, 在优化 tb 所在那层子查询时, 这里虽然会有两个标识 ta.c1 的 Var 实例, 但会被分配相同的 paramId. 

这种 duplicate-elimination 能力只会在单个子查询粒度生效, 并不会跨子查询生效. 具体来说假设我们有子查询树: A -> B, B -> C, B -> D, 其中 C, D 分别引用 A.c1, B.c1, 那么 C 中 B.c1 与 D 中 B.c1 具有不同的 PARAM ID, C 中的 A.c1 与 D 中的 A.c1 将具有相同的 PARAM ID. 之所以造成这种原因如 make_subplan() 函数实现所示, outer query 会在其下一个子查询优化完毕之后清空 outer query 对应 PlannerInfo::plan_params. 即 B 在 C 优化完毕之后清空 B 对应 PlannerInfo::plan_params, 之后 D 便看不到 C 用了哪些变量, 从而无法共享 paramid. 

其实我感觉是可以做到共享的, 只不过收益可能并没有那么大. 当然实现上并不能简单地不清空 PlannerInfo::plan_params, 以 B, C, D 为例, 如果在 C 优化之后, 不清空 B 的 PlannerInfo::plan_params, 那么在计算 D 的 PlannerInfo::outer_params 就会把那些仅被 C 依赖的参数也一并加入了进去, 这很显然不太合理.

PlannerInfo::outer_params; contains the paramIds of PARAM_EXEC Params that outer query levels will make available to this query level. 可以简单理解为若外部查询想运行当前查询, 则必须已经填充了 outer_params 指定的参数. 在 subquery_planner() 中, 当 grouping_planner() 完成当前查询的优化之后, PG 会调用 SS_identify_outer_params() 根据父/祖先 PlannerInfo 中 PlannerInfo::plan_params 字段的取值来计算当前查询 PlannerInfo::outer_params.

## MULTIEXPR PARAM

MULTIEXPR PARAM 使用场景如: `update t set (c1,c2) = select (1, 2), (c3, c4) = select (3, 4);` 这种语句, 这里 `select (1,2)`, `select (3,4)` 便各是一个 multiexpr sublink. 在语义分析之后, 每一个 multiexpr sublink 都有一个唯一的 sublinkid, 之后使用 multiexpr param 来替换 multiexpr sublink, 如上 update 会被改写为:

```sql
update t set c1 = MultiexprParam{sublinkid1, TargetId1}, c2 = MultiexprParam{sublinkid1, TargetId2}, ...
```

这里 sublinkid1 指定了 multiexpr param 对应的 multiexpr sublink sublinkid, TargetId 对应着当前 multiexpr param 是对 multiexpr sublink targetlist 第 n 个 target 的引用.

在对 multiexpr sublink 子查询的优化结束之后, 会在 build_subplan() 函数中, 为 multiexpr sublink 每一个 target list 都分配一个对应的 param exec, 之后将这些 param exec 放在一个 list 中, 放入父查询对应 PlannerInfo::multiexpr_params 中下标 `subLinkId - 1` 处. 最后在父查询 set_plan_references() 中 fix_param_node() 这一步将 multiexpr param 替换为对应的 param exec, 这里根据 multiexpr param 的 sublinkid1, TargetId1 字段很容易找到对应的 param exec.

目测 multiexpr 不支持跨级引用, 即 A -> B -> C, A 不能依赖 C 的 multiexpr sublink, 因为并没有从代码中看到哪里会把 B 对应 PlannerInfo::multiexpr_params 拷贝到 A 中.

## PARAM_SUBLINK

PARAM_SUBLINK 的使用场景上 Q3 查询语义分析之后所示. 之后再对子查询完成优化之后, 会在 build_subplan() 这一步中通过函数 convert_testexpr() 将 testexpr 中的 PARAM_SUBLINK 替换为 PARAM_EXEC.

## SubPlan Rewind

PG 执行器支持以一种高效的方式来对 SubPlan 执行 Rewind 操作. 但需要优化器告知需要针对哪些 subplan 做 Rewind 操作优化. 具体来说, 在 build_subplan() 这一步, PG 会根据 subplan 的特性判断是否为其开启 Rewind 优化, 若需要则将 subplan id 保存在 PlannerGlobal::rewindPlanIDs 中, 在 standard_planner() 结尾时, 会将 PlannerGlobal::rewindPlanIDs 保存在 PlannedStmt::rewindPlanIDs, 最终执行器在 InitPlan() 中如果发现 subplan id 要求采取 rewind 优化操作, 会使用 EXEC_FLAG_REWIND flag.

## Param 的执行

ParamExec, subplan 的执行离不开 PG PARAM EXEC 模块, PG 使用 PARAM EXEC 来完成往 subplan 中传递值, 以及从 subplan 中返回值等操作. 简单不严谨地介绍 param exec 大致结构是: 对于一个查询, 其内所有 param exec 都有一个唯一的 id 对应对应. 在执行时, PG 会分配一个 Datum 数组 values[]. 每个 param 都对应着两个角色: 值的提供方, 使用方; 值的提供方会完成对 param exec 的求解之后将结果保存在 `values[param.id]` 中, 值的使用方则从 `values[param.id]` 中拿到值并使用. 在具体实现上, EState::es_param_exec_vals 便起到 values 这个数组的角色. 在 ExecInitExpr() 中, Param 类型节点对应的求值函数是 ExecEvalParamExec(). ExecEvalParamExec() 会根据 Param::paramid 从 EState::es_param_exec_vals 中获取 Param 对应的 ParamExecData 对象, 之后根据 ParamExecData 中的信息来完成 Param 节点的求值. 简单来说, 在 ExecEvalParamExec() 中, 若 ParamExecData::execPlan 未设置, 则表明 ParamExecData 的值已经求解了, 此时直接返回 ParamExecData::value, isnull 就成. 反之则表明 ParamExecData 尚未被求解, 此时需要调用 ExecSetParamPlan() 运行 execPlan 来完成对 param 的求解. 某些情况下 execPlan 吐出的结果对应着多个 Param, 对这些 param 中任意一个进行求值都会使得其他 param 的值一并求解了. 另外这里 ExecSetParamPlan() 在完成求值之后一般会清除掉 ParamExecData::execPlan, 这是合理的, 因为大部分 init plan 只需要执行一次即可, 对 ParamExecData::execPlan 的清除意味着下次 ExecEvalParamExec() 时直接返回 ParamExecData 中已经计算出来的值即可.

## ReScan

ReScan 使用场景, 以 NestLoopJoin 为例, 其一般执行模式是, 先扫描 outer plan tree 得到 outer tuple, 之后依次为 filter 扫描 inner plan tree, 扫描出 inner plan 中满足与 outer tuple 进行 join 的 inner tuple, 之后拼接 outer tuple, inner tuple 并返回. 也即意味着每次扫描 outer 得到 outer tuple 之后都需要重置 inner plan, 使得对 inner plan 下次 ExecProcNode() 调用能从头开始扫描. 为此 PG 引入了 parameter-change-driven rescanning 机制. 以 nestloop join 为例, inner plan 往往以 PARAM_EXEC 的形式依赖着 outer plan 某些变量, 当 outer plan 扫描得到一个新的 outer tuple 时, 意味着 inner plan 中这些参数的取值发生了变化, 因此应该触发对 inner plan 的 ReScan.

Plan::extParam, Plan::allParam; extParam 记录着当前 plan node 以及其子 plan node 依赖的 PARAM EXEC, 当这些 PARAM 的值发生改变时应该触发对 plan node 以及其子 plan 的 rescan. 实际上 Plan::initPlan 中存放着 init plan 设置的参数, 即 SubPlan::setParam 也会影响 plan node 以及其子 plan 的执行, 但这些 param 并不能算是 external 的, 所以并未包含在 extParam 中, 而是存放在 allParam 中了. PG 会在 standard_planner() 的尾部调用 SS_finalize_plan() 来完成对所有 plan node extParam, allParam 的计算.

PlanState::chgParam, 存放着当前 PlanState 依赖的外部 param 中有哪些 param 的值发生了改变, 在 ExecInitNode() 创建 plan state 时, 该字段初始化为 NULL. 之后在运行中 PG 会根据实际情况设置 chgParam. 以 nestloop join 为例, 在 ExecNestLoop() 中当 PG 通过扫描 outer plan 拿到了下一个 outer tuple 之后会设置 inner plan topmost PlanState::chgParam 字段来告知 inner plan 其依赖的某些 param 值发生了变化, 可能需要触发一次 rescan. 每次执行 ExecProcNode() 期望获取 plan state 下一行输出时, ExecProcNode() 都会检测 chgParam 是否置位, 若置位则调用 ExecReScan() 完成对 plan state 以及其子 plan state 的 rescan 重置工作.

## SubPlan 的执行

PG 会在 InitPlan() 中完成对当前查询所有 subplan 对应 plan tree 的 ExecInitNode() 操作, ExecInitNode() 创建的 plan state tree 存放在 EState::es_subplanstates 结果中. PlannedStmt::subplans 与 EState::es_subplanstates 一一对应, 分别存放着子查询的 plan tree 以及 plan state tree. 每一个 SubPlan 通过 SubPlan::plan_id - 1 作为下标来完成 plan tree, plan state tree 的确定. 

### InitPlan 的执行

ExecInitNode(), PG 会在 ExecInitNode() 为 Plan::initPlan 中所有 init plan 通过函数 ExecInitSubPlan() 创建出对应的 SubPlanState, 并保存在 PlanState::initPlan 中, 即 Plan::initPlan 与 PlanState::initPlan 一一对应, 分别存放着 init plan 对应的 SubPlan, SubPlanState 结构. 在 ExecInitSubPlan() 中, PG 会根据 init plan SubPlan::setParam 的取值将 init plan 负责求解的 Param 对应的 ParamExecData::execPlan 设置为 init plan 自身. 从而使得这些 param 在调用 ExecEvalParamExec() 求解时, 便会运行这里的 init plan 来得到 param 的结果. 

ReScan; 只要一个子查询不依赖其父查询中的变量, 该子查询便是一个 init plan. 也即 init plan 只能表明子查询不依赖父查询的参数, 并不意味着 init plan 完全不依赖任何参数, init plan 可能会依赖其祖先查询中的变量. 因此 init plan 也是有 ReScan 行为的. 比如 A, B, C, C 是 B 的 init plan, 但 C 依赖着 A 中某些变量, 那么在执行时 PG 执行器会把 C 作为 init plan 来执行. 当 C 依赖的 A 变量值变化时, 这一变化会首先传递给 B topmost planstate; 之后 B 在 ExecReScan() 时会继续将 A 变量值发生了变化传递给 C; 之后 C 会调用 ExecReScanSetParamPlan() 对 init plan 进行 rescan 操作, 此时会重新将 init plan 对应的参数 ParamExecData::execPlan 设置为 init plan 自身; 使得下次 ExecEvalParamExec() 调用会再次对 init plan 进行求值. 这里在 ExecSetParamPlan() 中在调用 ExecProcNode(initplanTopMostPlan) 时, 由于 init plan TopMostPlan::chgParam 被置位, 所以 ExecReScan() 会被调用来完成对 init plan tree 的 rescan 操作.

### Non-InitPlan 的执行

ExecInitExpr(), Non-InitPlan 会被作为一个普通的表达式节点来处理, 即会在 ExecInitExpr() 中调用 ExecInitSubPlan() 生成 SubPlan 对应的 SubPlanState, 追加到 PlanState::subPlan 中. ExecInitSubPlan() 内部会设置 SubPlanState 对应的表达式求值函数为 ExecSubPlan().

ExecSubPlan() 这里的求值步骤与上面对 SubPlan 的介绍差不多, 主要就三步: 首先对 SubPlanState::args 求值, 然后运行 subplan plan tree, 之后根据 subplan 的结果求解 testexpr, 并返回 testexpr 的结果. 另外考虑到 Non-InitPlan 依赖着其父查询中某些变量, 因此每次 ExecSubPlan() 时都会触发 subplan ReScan() 操作.

### MultiExpr SubPlan 的执行

若 MultiExpr SubPlan 是 init plan, 则遵循 init plan 的执行链路. 

若 MultiExpr SubPlan 不是 init plan. 则根据 build_subplan() 实现可知, 此时 PG 仍会设置 SubPlan::setParam 字段, 并且返回 SubPlan 自身. 以 `update t set (c1, c2) = (select c2, c1);` 查询为例演示下 multiexpr subplan 是如何求值的, 该查询优化结束之后生成的执行计划如下所示:

```
Update on public.t
  ->  Seq Scan on public.t
        Output: $2, $3, c3, c4, c5, c6, (SubPlan 1 (returns $2,$3)), ctid
        SubPlan 1 (returns $2,$3)
          ->  Result
                Output: t.c2, t.c1
```

这里 `SubPlan 1` 便是 build_subplan() 返回的对象, `$2, $3` 便是该 subplan 吐出的 param exec, 也即 SubPlan::setParam 字段. 之后在 InitPlan() 中, 由于这里 multiexpr subplan 并不是 init plan, 即其是表达式的一部分, 因此对应 multiexpr subplan state 会在 ExecInitExpr() 中调用 ExecInitSubPlan() 函数创建. 在 ExecInitSubPlan() 函数中, 由于 SubPlan::setParam 不为 NULL, 所以这里 ExecInitSubPlan() 会将 `$2, $3` 对应的 ParamExecData::execPlan 设置为自身. 之后在 SeqScan 第一次运行时, 会调用 ExecProject() 根据 SeqScan targetlist 来计算 SeqScan 需要吐出的行. 也即此时会依次调用 ExecEvalParamExec(), ExecEvalParamExec(), ExecSubPlan() 分别用来对 targetlist 中 `$2`, `$3`, `SubPlan 1` 进行求解. 这里在 ExecEvalParamExec() 调用中, 由于 ExecInitSubPlan() 设置了 ParamExecData::execPlan, 所以此时会和 init plan 链路一样调用 ExecSetParamPlan() 运行 multiexpr subplan plan tree 得到结果, 并依次填充 `$2, $3`. 之后 ExecSetParamPlan() 便会清除 ParamExecData::execPlan; 在 init plan 求解链路中, 这是合理的, 毕竟 init plan 只需要执行一次, 对 ParamExecData::execPlan 的清除意味着下次 ExecEvalParamExec() 时直接返回 ParamExecData 中已经计算出来的值即可. 但在这里 non-initplan multiexpr subplan 中, 这里的清除很显然是不合理的. 幸运的是接下来在对 `SubPlan 1` 的求值中, 会调用 ExecSubPlan(), ExecSubPlan() 内部发现当前 subplan 是个 multiexpr subplan 之后便会重新将 `$2, $3` 对应的 ParamExecData::execPlan 设置为自身, 便返回. 也即后续每次对 SeqScan 调用 ExecProject() 时, `$2`, `$3` 对应的 ParamExecData::execPlan 都不为 NULL, 即每次都需要运行下 subplan 来求解.

## 分布式下的 SubPlan

从上可以看到 Non-InitPlan 的执行严重依赖了 PG ReScan 模块. 在分布式场景下, 以 Greenplum 为例, 其会将查询切分为多个 slice, slice 之间通过 Motion 节点通信, 而且 Motion 节点是不支持 ReScan 的. 那么这时又该如何实现 SubPlan 呢? 后面有时间再介绍...

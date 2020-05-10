---
title: "PG 中的优化器: 概念"
hidden: false
tags: ["Postgresql/Greenplum"]
---

>   本文章内容根据 PG9.6 代码而来.

我个人感觉, 对 PG 优化器的学习一定要切合一个特定的链路, 更细化地说是一个特定的查询. 因为 PG 优化器被用来处理所有可能的查询, 它里面包含了大量的分支判断, 虽然 PG 将若干分支进行了一定的抽象汇总, 但是如果没有特定查询场景下, 咋一看也是有点蒙的. 另外该篇文章主要着重于对优化过程中所用到的各种概念的描述, 并未太过详细地描述优化器实际执行时的代码.

PG 的优化器负责抉择出所有需要选择的地方, 比如 PG 优化器在扫描表时需要确定是使用 seqscan, 还是使用 indexscan, 如果是使用 seqscan, 那么考虑到 PG9.6 引入了并行 worker, 那么 PG 优化器也需要判断出需要多少个 worker 等等. 在 PG 优化器确定了执行计划之后, PG 执行器便会就忠实地按照 PG 优化器的结果开始执行了.

## 查询

PG 之中, 会将一个查询分为多层来进行处理, 在这种层次模型中, 每一层都会读取下一层的输出, 做些属于自身层所需的逻辑处理, 之后吐出处理后的数据供上一层使用. 位于最底层的便是 scanjoin 层用来表示着查询所需要的数据源, 该层负责存放 query 中涉及到哪些表, 以及相关的 WHERE, JOIN/ON 条件. 吐出 JOIN 之后的结果. 之后若用户在 query 中使用了 window, agg, groupby 等特性时, pg 都会各为这些特性创建一层来表示.

在不同的阶段, PG 也会使用不同的中间表示结构来表示查询, 从最开始的 parsetree, 到语义分析后的 Query querytree, 再到最终优化后的 PlannedStmt.

## "表"的表示与组织

这里 "表" 是指广义上的表, 即所有具有表格行为的东西都会视为表. 比如: 一个返回 set of record 的函数就可认为是张表. 在不同的阶段, PG 会使用不同的中间表示结构来表示一张"表". 

RangeVar; 在语法解析阶段 parsetree 中, PG 使用 RangeVar 来表示表, 简单来说所有出现在 FROM 子句的语法构造都会用 RangeVar 来表示. 

RangeTblEntry; 在语义分析 querytree 中, PG 使用 RangeTblEntry 来表示一个表极其类似物. 此外 querytree 会将查询中所有 RangeTblEntry 都放在 range table list 中, 即 Query::rtable 字段, 之后在其他需要表示表的地方都将只通过表在 range table list 中对应的下标来表明, 即代码中经常见到的 rt index/relid. 在优化阶段, 为了加速对 RTE 的索引, 在优化开始时, PG 会调用 setup_simple_rel_arrays() 将 Query::rtable 中存放的 RTE 的地址存放在 PlannerInfo::simple_rte_array 数组中, 之后通过 relid 来找到对应 RTE 时, 就不需要遍历 list 了, 直接 simple_rte_array[relid] 便可得到对应的 RTE 了. 

RelOptInfo 用于优化阶段中表示一张表. 所有 RelOptInfo 也都会被组织成一个 array, 其他地方也是通过 index 来索引. 具体来说 PlannerInfo::simple_rel_array 字段存放着所有 RELOPT_BASEREL/RELOPT_OTHER_MEMBER_REL/RELOPT_DEADREL 类型的 RelOptInfo 结构. 表示 relid 指定 RTE 对应的 RelOptInfo 结构就存放在 simple_rel_array[relid] 中. PlannerInfo::join_rel_list 字段存放着所有 RELOPT_JOINREL 类型的 RelOptInfo. PlannerInfo::upper_rels 用来存放着所有的 RELOPT_UPPER_REL 类型的 RelOptInfo, 这里面具体组织方式参考 'Post scan/join planning'.

参见 'flat rangetable' 节了解执行阶段执行器对表的组织.

无论是在语义分析, 优化, 还是执行阶段, 用来表示 table 的索引总是从 1 开始, 但是对应的数组/list下标却总是从 0 开始, 因此在根据索引取出对应结构时要想 rt_fetch 一样记得减 1.

## inheritance or UNION ALL 

本节从整体上介绍下 PG 对于继承以及 UNION ALL 的实现机制. 

当查询涉及到继承或者 UNION ALL 时, PG 引入了 append relation, member relation 概念. 其中 append relation 表示着整体的数据源, 即 UNION ALL 之后的结果, 或者是继承层次中所有叶子节点表扫描结果的并集. member relation 则用来表示部分的数据源, 比如是 UNION ALL 所涉及到的查询之一的结果, 或者是继承层次中某个特定叶子节点表扫描结果. member relation 对外不可见, 即 append relation 作为牌面负责与其他模块交互, 比如出现在 join tree 中. append relation 对应着 RELOPT_BASEREL 类型的 RelOptInfo. member relation 对应着 RELOPT_OTHER_MEMBER_REL 类型的 RelOptInfo. 

在优化时, PG 先针对每一个 member relation, 确定他们的执行路径. then the parent baserel is given Append and/or MergeAppend paths comprising the best paths for the individual member rels.  

AppendRelInfo; PG 中使用 AppendRelInfo 来存放 member relation 与 append relation 的对应关系. 想象中这种对应关系存放格式可能是 `std::unordered_map<int, std::vector<int>>`, key 是 append relation relid, values 对该 append relation 下所有 member relation relid 集合. 但实际上 PG 是使用 `std::vector<std::pair<int, int>>` 这种结构来存放映射关系的, 此时 pair first, second 分别是 member relation relid, append relation relid. 这里 AppendRelInfo 就充当着 `std::pair<int, int>` 的角色, 存放着一个映射关系, 即一个 member relation 与其对应的 append relation. PlannerInfo::append_rel_list 就对应着 `std::vector<std::pair<int, int>>`, 存放着所有的映射关系.

RangeTblEntry::inh 字段; 若该字段为 true, 则表明 RangeTblEntry 对应着一个 append relation, 其下所有 member relation 可以通过遍历 PlannerInfo::append_rel_list 来找出. 若该字段为 false, 则表明当前 RTE 不会是 append relation, 也便不需要遍历 PlannerInfo::append_rel_list 了.

由于目前 append relation/member relation 都只能是 base reloptinfo, 所以 it prevents us from pulling up a UNION ALL member subquery if it contains a join. 但并不影响最优计划的生成, 所以 PG 大佬们也就没想着解决.

## Post scan/join planning

之前提过查询在 PG 中是分层处理的, 在优化时, 也是一样. 简单来说, PG 会首先确定 scanjoin 的所有可行的执行路径. 之后根据用户所用到的特性, 再为相应的层确定相应的执行路径. 最终完成执行计划的生成. 考虑到在 PG 的设计中, 所有执行路径都关联到一个特定的 RelOptInfo. 因此在为 scanjoin 层之上的高级特性做优化时, PG create RelOptInfos representing the outputs of these upper-level processing steps.  These RelOptInfos are mostly dummy, but their pathlist lists hold all the Paths considered useful for each step. 

These "upper relations" are identified by the UPPERREL enum values shown in UpperRelationKind, plus a relids set, which allows there to be more than one upperrel of the same kind.  We use NULL for the relids if there's no need for more than one upperrel of the same kind.  Currently, in fact, the relids set is vestigial because it's always NULL. 但是在 RELOPT_UPPER_REL 类型 RelOptInfo 中, 并没有字段存放着 UpperRelationKind 类型信息, 所以对于 RELOPT_UPPER_REL 类型 RelOptInfo, 其对应 UpperRelationKind 信息需要根据他在 PlannerInfo 中的位置来确定. RelOptInfo::relids 用来存放这里所说的 relids.

PlannerInfo::upper_rels. 其结构类似于 `std::vector<std::list<RelOptInfo>>`, PlannerInfo::upper_rels[idx] 存放着所有 UpperRelationKind 取值为 idx 对应的 RelOptInfo; 对于一个特定的 RelOptInfo, 通过 RelOptInfo::relids 字段来索引它在 `std::list<RelOptInfo>` 中的位置. 即对于 (UpperRelationKind=idx, relid=j) 的 upper relations, 他对应的 RelOptInfo 是 `PlannerInfo::upper_rels[idx][j]`. 若 upper relation 的 relid 取值为 NULL, 则 j 视为 0.


## scan/join planning

本节介绍了优化器是如何确定 query scanjoin 层所需的执行路径的.

### preprocess expression

preprocess_expression; 表达式预处理. 包括了常量折叠等操作. 在 PG 中, 倾向于尽可能多地导出 top-level AND 表达式. 这应该是所有数据库的共性了, 之前在 ADB MYSQL 中也看到过类似处理. 估计是在 top-level AND 情况下, 如: `qual1 AND qual2 AND qual3 ...` 只需要一个 qual 求值为 FALSE 便可省略对其他 qual 的计算. 所以 preprocess expression 具体包含了:

1.  eval_const_expressions(); 做一些基于常量的优化, 如常量求值: `2 + 2` 被转换为 `4`, `TRUE or qual` 被转换为 `TRUE`, `A == TRUE` 被转换为 `A` 等. 这里也会借着遍历表达式树的机会做些结构上的变换, 如: flatten nested AND and OR clauses into N-argument form. any function calls that require default arguments will be expanded, and named-argument calls will be converted to positional notation.

2. canonicalize_qual_ext(); 继续为了更多地导出 top-level AND 表达式而努力, 如: `(A and B) or (A and C) or (A and D)` 转换为 `A and (B or C or D)`.
3. make_ands_implicit(); 在已经导出了 top-level AND 表达式之上, 使用 `{qual1, qual2, qual3, ...}` 这种 list 结构来表示 `qual1 AND qual2 AND qual3 AND ...`. 如 make_ands_implicit 注释所示, PG 约定: qual list 为空, 表明始终为 true.

### pseudoconstant expression

pseudoconstant expression; variable-free expression, 即表达式中不含有任何变量, 但是也不属于常量的表达式. 比如当表达式中包含了 stable function, 如 `NOW() > '2018-12-18'`. 由于 pseudoconstant 不是常量, 所以无法在 eval_const_expressions() 中被折叠. pseudoconstant expression 在执行时只需要求值一次即可. 针对 pseudoconstant expression, PG 会构造出对应的 Result plan, 此时 Result::resconstantqual 就存放着 pseudoconstant expression. 如:

```
pg=# explain select * from t where now() > '2018-12-18';
                                   QUERY PLAN                                    
---------------------------------------------------------------------------------
 Result  (cost=0.01..22.71 rows=1270 width=36)
   One-Time Filter: (now() > '2018-12-18 00:00:00+08'::timestamp with time zone)
   ->  Seq Scan on t  (cost=0.01..22.71 rows=1270 width=36)
```

Result plan 的执行可以参考 ExecResult 函数. 简单来说: 首先会对 resconstantqual 进行求值, 若结果为 FALSE, 则 result plan 执行结束, 未返回任何行. 若结果为 TRUE, 则返回 result 子 plan 的行.

pseudoconstant expression 在 jointree 中的求值位置参考下面介绍.

### qual, jointree

qual, jointree. 考虑到 PG 中 join 的输入只有两个: 一个 outer, 一个 inner. 所以对于 scanjoin 层的执行路径的确定最终形式是一个 jointree, jointree 的叶子节点表示参与 join 的 baserel, 中间节点表示着部分 join 后的结果, 根节点表示着 scanjoin 的输出. PG 在语义分析阶段就得知了每一个 qual 所涉及到的 RTE, 对于出现在 WHERE 用于单表过滤的 qual, 很显然他们只涉及到一个 RTE; 对于出现在 JOIN/ON 用来过滤 join 后结果的 qual, 可能会涉及到多个 RTE. PG 使用 Relids 类型存放着一个 qual 涉及到的 RTE 对应 relid 集合, 该集合同时也定义了 qual 在 jointree 中的执行位置, 即 qual 应该在包含了所有 relid 集合的 jointree 上做运算. 某些时刻我们可以通过给 qual 指定一个比其实际所需 relid 更大的 Relids 集合来强制限定 qual 在更高层的 jointree 上进行计算. 比如对于查询:

```sql
SELECT * FROM t1, t2 WHERE t1.c1 = 33 AND t1.c2 = t2.c2
```

此时形成的 jointree 如下所示:

{% mermaid %}
graph TD;
    A[t1 join t2]-->B[t1];
    A-->C[t2];
{% endmermaid %}

对于 qual `t1.c1 = 33`, 由于他只涉及到单张表 t1, 所以会被下推到 jointree 中 t1 叶子节点上执行. 对于 qual `t1.c2 = t2.c2` 则只能是放在 jointree 根节点上执行了.

原则上, PG 总是倾向于把 qual 推到最最下层来处理, 这里可以降低上层 join 时输入的行数. 但是考虑到 outer join nullable side 的存在, 某些 qual 并不能无脑下推. 详细的下推规则将不在这里展开.

另外在对 pseudoconstant expression 的处理上, 很显然 pseudoconstant expression 应该要尽量最早执行, 所以 pseudoconstant expression 会在语义允许的情况下一直上移到 jointree 最上层. 当然仍然是由于 outer join 的存在, 我们可能无法将 pseudoconstant expression 上移到根节点.

若确定 qual 在 jointree 求值位置之后, qual 会被 RestrictInfo 包装起来, 并存放在相应的 RelOptInfo 中. 具体可参考 RelOptInfo,RestrictInfo 注释.

### EquivalenceClasses, PathKey

简单来说, 就是 PG 会收集查询中所有使用等于运算符的 qual, 并且把这些信息保存起来便于后续优化处理. 以 query:

```sql
SELECT ... WHERE x = y ORDER BY x, y 
```

为例, 这里会把 x = y 提取并保存起来. 之后在处理 `ORDER BY x, y` 时便可推断出没必要再针对 y 列再进行一次排序了. 


EquivalenceClasses 的保存. `PlannerInfo::eq_classes` 存放着在优化过程中收集到的 EquivalenceClasses 信息, 其结构类似于 `std::list<EquivalenceClass>`. EquivalenceClass, 结构类似于 `std::vector<EquivalenceMember>`, 存放着一组互相之间相等的 EquivalenceMember 集合. 而 EquivalenceMember, 则可认为是普通的 Expr. 因此如上 SQL 对应的 eq_classes 结构是 `{EquivalenceClass{EquivalenceMember{x}, EquivalenceMember{y}}}`.

EquivalenceClasses 的语义. 我理解存放在 `PlannerInfo::eq_classes` 的 EquivalenceClasses 表示着当前 plannerinfo 对应的 query 输出的每一行都成立的等值条件. 也即当前 plannerinfo 对应 query 输出的每一行都符合 `PlannerInfo::eq_classes` 中所有 EquivalenceClasses 定义的等值条件. 所以对于查询:

```sql
select * from t where (i = 20181218 or j = 'hidva.com');
```

此时 PlannerInfo::eq_classes 为空! 无论是 `i = 20181218` 还是 `j = 'hidva.com'` 都不能算是 EquivalenceClasses.

但是对于查询:

```sql
select * from t where (i = 33 and j = 'test');
```

此时 PlannerInfo::eq_classes 结构为: `{ {i, 33}, {j, 'test'} }`. 

EquivalenceClasses 的收集. 简单来说, 便是遍历 preprocess expression 时生成的 qual list, 然后检测每一个 qual 是否符合 EquivalenceClasses 要求, 若符合则将其存放在 PlannerInfo::eq_classes 中. 参考 distribute_qual_to_rels(), process_equivalence() 来了解具体细节.

PathKey, 关于 PathKey 介绍, 以及与 EquivalenceClasses 的处理顺序, 参考 optimizer/README 中相应章节介绍. 这里不再赘述.

## cost, set_pathlist

整个 PG 优化器说简单其实也很简单, 之前说过 PG 将查询分为多层, 每层都对应着一个 RelOptInfo 实例来表示. PG 优化器要做的就是针对每一个 RelOptInfo, 想出各种可行的执行路径, 然后按照 PG 的 cost 模型计算出每个执行路径要花费的 cost, 最后选择一个 cost 值最小的执行路径. 比如以 set_plain_rel_pathlist 为例, 就是想出 seqscan, indexscan, tidscan 这三类对应的执行路径, 然后一股脑地塞到 pathlist 中, 供上层选择. 就是整个过程比较繁琐, 涉及到的信息量有点多, 导致链路熟悉起来有点吃力.

这里 cost 又分为 startup cost, total cost, 大部分情况下, 我们只考虑 total cost. 但也有一些例外, for relations that are on the RHS of a SEMI or ANTI join, a fast-start plan can be useful because we're only going to care about fetching one tuple anyway. RelOptInfo::consider_startup 等字段就是用来表明当前 RelOptInfo 是否有优先考虑 startup cost 的倾向. set_base_rel_consider_startup() 则是用来根据 RelOptInfo 在查询中的位置来设置其对应的 consider_startup 字段, 简单来说就是若 reloptinfo 出现在 SEMI join 右侧, 那么就设置 consider_startup 字段为 true.

## use physical tlist

根据 PG 执行器在为 seqscan plan 构造对应的 planstate 链路, 即函数 ExecAssignScanProjectionInfo() 实现可知, 若 seqscan plan 中的 target list 与底层表列集合不一致时, 即条件 tlist_matches_tupdesc() 不符合时, 此时便需要为 seqscan plan 加入 project 步骤, 即对于从底层表读取上来的每一行, 都需要应用一下 project 得到 seqscan plan 上层期望的 target list. 为了避免每一行都做一次 project, PG 优化器在生成 seqscan plan 时会争取让 seqscan plan target list 与表的列保持一致, 使条件 tlist_matches_tupdesc 满足, 避免每次都做一次 project. 那么什么时候可以让 seqscan plan target list 与表列保持一致呢:

1.  首先是 seqscan plan 上一级的 plan 无所谓其下的 seqscan 是否使用了 physical table target list. 举个例子. 表 t1 定义如下:

    ```sql
    CREATE TABLE t1(i int, j int);
    ```

    对于查询 Q1:

    ```sql
    pg=# explain select i from t1 where NOW() > '2018-12-18 11:45:33';
                                       QUERY PLAN                                    
    ---------------------------------------------------------------------------------
     Result  (cost=0.01..32.61 rows=2260 width=4)
       One-Time Filter: (now() > '2018-12-18 11:45:33+08'::timestamp with time zone)
       ->  Seq Scan on t1  (cost=0.01..32.61 rows=2260 width=4)
    ```

    来说, 用户的 SELECT 要求这里生成的 Result plan 的 target list 只有 `{ i }`. 对于 Result plan 下面的 SeqScan 来说, 其 target list 只要求包含 i 列即可, 对 seqscan target list 是否只能包含 i 列这点上没有要求. 因此此时 PG 在生成 seqscan plan 时, 便会使用 physical table target list, 即 seqscan plan target list 是 `{i, j}`, 从而避免了在 seqscan 层做 project.

    虽然这个时候, result plan 便不可避免地需要 project 了. 不过按照 PG 对 Result plan 的设计, 他本来就是总要做 project 的, 参考 ExecResult() 的实现.

2.  如果 seqscan plan 上层 plan 无所谓, 接下来就要看 seqscan plan 自身能否满足使用 physical table target list 的要求了. 参见 use_physical_tlist() 实现了解具体的要求. 这里不再赘述.

## flat rangetable

根据之前对优化部分的介绍可知, 优化结束后, 我们可以得到一组呈现树结构的 PlannerInfo, 位于根节点的 PlannerInfo 表示着 top-level querytree 对应的 plantree, 叶子节点的 PlannerInfo 表示着 sub-querytree 对应的 sub-plan. 无论是 top-level querytree 还是 sub-querytree, 其 Query::rtable 字段中都存放着在当前 query 中所有 range table, 并且在 query 以及对应的 PlannerInfo 中, 都通过 range table index 来索引 range table. 也即此时同一个 range table index 在不同的 query 中对应着不同的 range table. 

但执行器期望的是所有的 range table 都位于同一个数组中, 每一个 range table 都只有一个下标来索引. 具体来说, 执行器期望所有 range table 都位于 PlannedStmt::rtable 中. 所以这需要我们将优化器生成的一组 PlannerInfo 中包含的所有 range table 都放在 PlannedStmt::rtable 中, 同时针对 plantree 中出现的每个 range table, 调整他们的索引. 举个例子说明为啥需要调整索引: 假设优化结束之后生成 plannerinfo1, plannerinfo2, plannerinfo1 具有 2 个 rangetable: rt11, rt12, plannerinfo2 具有 3 个 rangetable: rt21, rt22, rt23. 在我们将这些 range table 都塞到 PlannedStmt::rtable 中得到: `{rt11, rt12, rt21, rt22, rt23}`. 很显然这里我们需要把 plannerinfo2 对应 plantree 中所有对 rt21 的引用下标从之前的 1 调整为 3.

所以 PG 会在优化阶段结束之后, 在 set_plan_references() 中完成这项工作. 具体参考 set_plan_references 的注释与实现.

## 概念

这里汇总了 PG 优化器过程中所用到的各种概念, 便于后续查找.

plain path, 也即 unparameterized path.

reloptinfo size estimates, 包括了 rows and widths 这些信息.

Partial Indexes, predicate of the partial index; 见 PG 文档 '11.8. Partial Indexes'.

partial path. A partial path is one which can be executed in any number of workers in parallel such that each worker will generate a subset of the path's overall result.

security barrier, 与 view 有关, 详见 [39.5. Rules and Privileges](https://www.postgresql.org/docs/9.6/rules-privileges.html)




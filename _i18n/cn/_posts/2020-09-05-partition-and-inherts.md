---
title: "当分区表遇到了继承"
subtitle: "资深 pg 玩家踏出来的坑"
hidden: false
tags: ["Postgresql/Greenplum"]
---


## TL;DR

Greenplum 基于 PG 继承机制实现了分区表机制, 但未做好与手动创建的继承关系之间的处理. 导致了当两者混用时可能会出现各种意想不到的情况.

## Long Story

就在刚刚, 我在享受我美好周末的时候. 忽然被拉到了一个电话会议中. 有一个用户 CREATE INDEX 总是失败, 而且很严重, 会触发 coredump. 一阵头大, 毕竟最近一次版本是我发布的, 难道有坑?! 连忙打开电脑看了下刚被拉进去一个群中的相关上下文信息. 看到了每次 coredump 总是位于相同的堆栈:

```
2    0x889c6a postgres StandardHandlerForSigillSigsegvSigbus_OnMainThread (elog.c:4783)
3    0x2b3f8d9e27e0 libpthread.so.0 <symbol not found> (??:0)
4    0x5c2a04 postgres <symbol not found> (analyze.c:8951)
5    0x5c381e postgres <symbol not found> (analyze.c:480)
6    0x5c4bce postgres parse_analyze (analyze.c:336)
7    0x7ce2b3 postgres pg_analyze_and_rewrite (postgres.c:724)
```

悄悄松了口气, 好像与我最近发布的版本关联性不大. 跪在了对查询的语义分析阶段. 但是, 这也不应该跪啊. 这里先介绍下 gp 对分区表的实现. gp 基于 pg 的继承机制实现了分区表, 如下 SQL 为 part 创建了两个子分区 part_1, part_2. 

```sql
create table part ( i int, j int ) partition by list (j) (values('2018'), values('2019'));
```

在实现上, gp 会令 part_1, part_2 继承 part 表. 同时再给 part_1, part_2 分别加上对应的 Check constraints, 这里 part_1 对应着 `(j = 2018)`, part_2 对应着 `j=2019`. 之后结合着 pg 对表继承的支持以及 [Constraint Exclusion](https://www.postgresql.org/docs/8.2/ddl-partitioning.html?f=hidva.com) 特性便能在不需要大幅改动整个执行框架的前提下便能实现分区裁剪等功能. 在 gp 之中, 除了继续使用了 pg_inherits 来存放分区表树中父节点表与子节点表的继承关系之外. gp 也引入了另一个系统表 pg_partition_rule, 每个子分区在这种表中都对应着一条记录存放着子分区相关的元信息, 如当前子分区中, 分区列的取值范围等.

而这次 coredump 也就是 core 在对子分区在 pg_partition_rule 中对应 tuple 的访问上. 这里大概的逻辑是 create index 时, pg 先通过 pg_inherits 拿到记录的所有子分区表, 之后对于每个子分区表, 提取出他们在 pg_partition_rule 中对应的记录并做些相关处理.

```c
/*
 * We want the index name to resemble our partition table name
 * with the master index name on the front. This means, we
 * append to the indexname the parname, position, and depth
 * as we do in transformPartitionBy().
 *
 * So, firstly we must retrieve from pg_partition_rule the
 * partition descriptor for the current relid. This gives us
 * partition name and position. With paroid, we can get the
 * partition level descriptor from pg_partition and therefore
 * our depth.
 */
partrel = heap_open(PartitionRuleRelationId, AccessShareLock);

tuple = caql_getfirst(
        caql_addrel(cqclr(&cqc), partrel), 
        cql("SELECT * FROM pg_partition_rule "
            " WHERE parchildrelid = :1 ",
            ObjectIdGetDatum(relid)));

Assert(HeapTupleIsValid(tuple));

name = ((Form_pg_partition_rule)GETSTRUCT(tuple))->parname;  -- BOOM!
parname = pstrdup(NameStr(name));
position = ((Form_pg_partition_rule)GETSTRUCT(tuple))->parruleord;
paroid = ((Form_pg_partition_rule)GETSTRUCT(tuple))->paroid;
```

也就是在试图将 pg_partition_rule 中 parname 字段的值拷贝出来时, SIGSEGV 了. 我一开始以为是由于各种各样的原因, pg_partition_rule 这张系统表被写坏了. 便给用户发了条 SQL. 如果真是 pg_partition_rule 被玩坏了, 那么 SQL 应该就会触发 coredump 的. 但用户却立马反馈我: 没有记录.

```sql
SELECT * FROM pg_partition_rule WHERE parchildrelid = '${ChildPartTableName}'::regclass;
```

没有记录??? 怎么可能会没有记录! (内心吐槽)你该不会没有把我变量的标识 `${ChildPartTableName}` 替换为真实的子分区表名吧. 就让用户截个图来看看:

```
tmp=# \d+ UserTable
                         Table "public.UserTable"
 Column |  Type   | Modifiers | Storage | Stats target | Description
--------+---------+-----------+---------+--------------+-------------
 i      | integer |           | plain   |              |
 j      | integer |           | plain   |              |
Indexes:
    "idx_x" btree (j)
Child tables: UserTable_1_prt_1,
              UserTable_1_prt_2,
              UserTable_1_prt_3
Distributed by: (i)
Partition by: (j)

tmp=# SELECT * FROM pg_partition_rule WHERE parchildrelid = 'UserTable_1_prt_3'::regclass;
(0 rows)
```

还真的没有记录啊!! 怎么可能啊!! 难道是 `CREATE TABLE PARTITION BY` 创建分区表时, 事务没能正确提交并留下了一个可见的中间状态? 不不不, gp/pg 不会出现这么弱智的 bug 的. 但还是若用户临时打开 gp_select_invisible 确认了一下, 确实仍没有相关记录. 

不过除此之外, 确实还有另外一种可能会出现这种情况, 于是在电话会议中顺嘴提了句: 还有一种可能, 就是用户自己手动通过 CREATE TABLE INHERITS 添加了子分区, 而不是通过 ALTER TABLE ADD PARTITION, 而且还非常睿智地仿照了 gp 子分区表名的生成规则将表名指定为了 'UserTable_1_prt_3'. 不过想了想这操作太高端了, 所以又接了句, 不过我觉得可能性不大. 当然我还是背地了试了一试:

```sql
create table part ( i int, j int ) partition by list (j) (values('2018'), values('2019'));
create table part3 ( i int , j int )  INHERITS(part);
create index idx_x on part(j); -- coredump
```

然后就惊讶地发现他真的 coredump 了! 而且堆栈也与用户的一致! 于是基于用户真的这么执行了的假设, 继续让用户执行了一系列 SQL 来验证输出结果与假设是否匹配. 同时向用户打探他们是怎么添加分区. 最终发现用户确实是通过 CREATE TABLE INHERITS 添加的分区. 实际上这种方式添加的方式由于缺少 pg_partition_rule 信息, 并没有被优化器/执行器使用到. 而用户之所以没有意识到这一情况是因为他们还有个默认分区. 在插入时, 用户的数据并没有预期插入到他们通过 CREATE TABLE INHERITS 创建的子分区, 而是统一塞到了默认分区. 在读取时, 由于会查询默认分区. 使得用户一直没有感知到这一事实.!

## 后记

我一直对 GP/PG12 通过继承来实现分区表的方式耿耿于怀. 主要是在优化器并不会利用分区这个信息来做些简化措施. 对于分区表, 优化器只是将其当作一个具有子表的表来看待, 优化器仍然会对每一个子表单独生成 plan. 为每个子表单独生成 plan 在继承表这一场景中是合理的, 毕竟每个子表可能具有不同的信息, 为每个子表单独生成 plan 可以使得每个子表的扫描都能使用最优的路径. ~~但老实说, 并不晓得为啥 PG 当初会提供继承表, 真有人再用么==!~~. 但对于分区表时, 则完全没有必要这么做, 我们可以大胆地应用均匀性假设认为每个分区都具有相同的数据分布, 从而不必要单独优化每一个子分区表, 所有子分区表都将使用统一的执行计划. 当然如果优化器能做得足够快, 则单独为每个子分区表生成计划也无所谓. 但现在现实是, 当分区数目稍微多一点, 优化器就已经是肉眼可见的瓶颈了, 很多时候优化时间已经超过执行时间了..

我认为根本原因就是, 优化器并没有将分区表视为一个表来看待, 而是认为分区表是其所有子表的集合. 因此 pg 会单独为每一个子表生成执行计划. 也因为此, pg 会在优化阶段就执行分区裁剪操作. 而不是像其他数据库那样在优化时将分区表视为整体, 在执行时进行分区裁剪. 除了上面的槽点之外, 不将分区表视为一个整体有时候甚至会导致执行计划中 plan node 的数目剧烈膨胀以至于由于占据过多的内存而由于内存不足无法完成计划的生成, 这可是在我们线上活生生遇到过的:

> explain 报 "insufficient memory reserved"
> 
> 用户 update 针对分区表未带分区列条件, 导致分区裁剪没生效, 导致 explain 生成的 plan tree 预计将会有 `PartitionNum(UserTable1) * PartitionNum(UserTable2) * PartitionNum(UserTable3)`, 即 `164 * 164 *164`, 大概 400w 左右个 node, 导致了内存不足. 在针对 UserTable3, UserTable2 表加上分区列条件后, 使得  PartitionNum(UserTable2), PartitionNum(UserTable3) 降为 1, 此时虽然能完成执行计划的生成, 但如文件 ~~[postgre.plan.txt](http://blog.hidva.com)~~ 所示, 这个执行计划是真的长啊..!

举个简单例子来演示如上事故中的情况:

```sql
create table t1(c1 int, c2 int, c3 int, c4 int) partition by range (c3);
create table t1_1 partition of t1 for values from ('2018') to ('2019');
create table t1_2 partition of t1 for values from ('2019') to ('2020');

create table t2(c1 int, c2 int, c3 int, c4 int) partition by range (c3);
create table t2_1 partition of t2 for values from ('2018') to ('2019');
create table t2_2 partition of t2 for values from ('2019') to ('2020');

create table t3(c1 int, c2 int, c3 int, c4 int) partition by range (c3);
create table t3_1 partition of t3 for values from ('2018') to ('2019');
create table t3_2 partition of t3 for values from ('2019') to ('2020');
```

在如上 SQL 创建的三个分区表基础上执行如下语句:

```sql
zhanyi=# explain (costs off) update t3 a set c2=1 from t1 inner join t2 on t1.c3 = t2.c4 where t1.c3 = 2018 and a.c4 = 3;
                            QUERY PLAN
------------------------------------------------------------------
 Update on t3 a
   Update on t3_1 a_1
   Update on t3_2 a_2
   ->  Nested Loop
         ->  Nested Loop
               ->  Seq Scan on t3_1 a_1
                     Filter: (c4 = 3)
               ->  Materialize
                     ->  Seq Scan on t1_1 t1
                           Filter: (c3 = 2018)
         ->  Materialize
               ->  Append
                     ->  Index Scan using idx_t2_c4 on t2_1
                           Index Cond: (c4 = 2018)
                     ->  Seq Scan on t2_2
                           Filter: (c4 = 2018)
   ->  Nested Loop
         ->  Append
               ->  Index Scan using idx_t2_c4 on t2_1
                     Index Cond: (c4 = 2018)
               ->  Seq Scan on t2_2
                     Filter: (c4 = 2018)
         ->  Materialize
               ->  Nested Loop
                     ->  Index Scan using idx_t3_2_c4 on t3_2 a_2
                           Index Cond: (c4 = 3)
                     ->  Seq Scan on t1_1 t1
                           Filter: (c3 = 2018)
```

可以看到 pg 将上述 update sql 拆分为了两个 update 语句, 并**分别**进行了优化. 

```sql
update t3_1 a set c2=1 from t1 inner join t2 on t1.c3 = t2.c4 where t1.c3 = 2018 and a.c4 = 3;
update t3_2 a set c2=1 from t1 inner join t2 on t1.c3 = t2.c4 where t1.c3 = 2018 and a.c4 = 3;
```

与此对比的是, 如果我们在优化时将分区表视为一个整体, 而在执行时完成分区裁剪与路由工作. 那么这时候的执行计划可就清晰了很多:

```
tmp=# explain (costs off) update t3 a set c2=1 from t1 inner join t2 on t1.c3 = t2.c4 where t1.c3 = 2018 and a.c4 = 3;
                  QUERY PLAN
-----------------------------------------------
 Update on t3 a
   ->  Nested Loop
         ->  Nested Loop
               ->  Seq Scan on t3 a
                     Filter: (c4 = 3)
               ->  Materialize
                     ->  Seq Scan on t1
                           Filter: (c3 = 2018)
         ->  Materialize
               ->  Seq Scan on t2
                     Filter: (c4 = 2018)
```


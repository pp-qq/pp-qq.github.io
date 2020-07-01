---
title: "GP 中的分区表"
hidden: true
tags: ["Postgresql/Greenplum"]
---

## Partitioning Large Tables

> 基于 GP6.4 文档

首先看下 DISTRIBUTED BY 与 PARTITION BY 区别: Table distribution is physical: Greenplum Database physically divides partitioned tables and non-partitioned tables across segments to enable parallel query processing. Table partitioning is logical: Greenplum Database logically divides big tables to improve query performance and facilitate data warehouse maintenance tasks, such as rolling old data out of the data warehouse. Partitioning does not change the physical distribution of table data across the segments. 所以是先计算分布, 然后再计算分区了?!

GPDB 支持多级分区, 一个多级分区表看上去像是一棵树. 每一级分区上可以采用多种分区姿势:

-	range partitioning: division of data based on a numerical range, such as date or price.
-	list partitioning: division of data based on a list of values, such as sales territory or product line.

In a multi-level partition design, only the subpartitions at the bottom of the hierarchy can contain data. 分区树中每一个节点都有对应的 CHECK 约束, 用来限制能插入该分区的数据. 如:

```sql
zhanyi=# \d+ mlp
                  Table "public.mlp"
 Column |  Type   | Modifiers | Storage  | Description
--------+---------+-----------+----------+-------------
 id     | integer |           | plain    |
 year   | integer |           | plain    |
 month  | integer |           | plain    |
 day    | integer |           | plain    |
 region | text    |           | extended |
Child tables: mlp_1_prt_1,
              mlp_1_prt_2
Has OIDs: no
Distributed by: (id)
Partition by: (year)

zhanyi=# \d+ mlp_1_prt_1
              Table "public.mlp_1_prt_1"
 Column |  Type   | Modifiers | Storage  | Description
--------+---------+-----------+----------+-------------
 id     | integer |           | plain    |
 year   | integer |           | plain    |
 month  | integer |           | plain    |
 day    | integer |           | plain    |
 region | text    |           | extended |
Check constraints:
    "mlp_1_prt_1_check" CHECK (year >= 2000 AND year < 2005)
Inherits: mlp
Child tables: mlp_1_prt_1_2_prt_asia,
              mlp_1_prt_1_2_prt_europe,
              mlp_1_prt_1_2_prt_usa
Has OIDs: no
Distributed by: (id)
Partition by: (region)
```

分区表的 INSERT; 表的分区可以直接被 INSERT, 此时 GP 就会按照如上 CHECK 约束来检查 INSERT 是否合法. 当然也可以使用根节点位置的表作为 INSERT 目标, 此时 GP 会自动路由.

Default Partition; 无论每级分区采用的是 range partitioning 还是 list partitioning, 都可以指定 Default Partition, 不满足那些显式指定条件的数据将会被插入到 Default Partition 中. default partition 上没有 check. ~~我还以为会智能地根据已有 partition check 来推测 default partitoin 呢.~~ 因此在应用直接插入数据到 Default Partition 时, 需要确认 the data in the default partition must not contain data that would be valid in other leaf child partitions of the partitioned table. Otherwise, queries against the partitioned table with the exchanged default partition that are executed by the Pivotal Query Optimizer might return incorrect results.

分区与 Unique; A primary key or unique constraint on a partitioned table must contain all the partitioning columns. A unique index can omit the partitioning columns; however, it is enforced only on the parts of the partitioned table, not on the partitioned table as a whole.

uniform 分区; uniform 是分区表的一个属性, 分区表是否是 uniform 的规则判定参见 [uniform](https://gpdb.docs.pivotal.io/43320/admin_guide/query/topics/query-piv-uniform-part-tbl.html#topic1). 考虑到 uniform 可以随意操作分区情况, uniform 并不总是成立的.

分区裁剪; The query optimizer uses CHECK constraints to determine which table partitions to scan to satisfy a given query predicate. The DEFAULT partition (if your hierarchy has one) is always scanned. DEFAULT partitions that contain data slow down the overall scan time. The following limitations can result in a query plan that shows a non-selective scan of your partition hierarchy. 可以通过 explain 查看 scan 了那些 partition.

分区与继承; Internally, Greenplum Database creates an inheritance relationship between the top-level table and its underlying partitions, similar to the functionality of the INHERITS clause of PostgreSQL. The Greenplum system catalog stores partition hierarchy information so that rows inserted into the top-level parent table propagate correctly to the child table partitions. 为啥非得创建个继承关系把分区与继承这俩扯一块去, 感觉不相干啊. 按我理解 GP 估计是要 PG 正好提供的继承模型来对 INSERT 进行路由. 但总觉怪怪的!

另外分区中 INDEX 之间也是有继承关系的. 在分区表父表上建立的 index 会自动在子表上也建立对应的 index, 这时 GP 认为子表 index 继承父表 index. 如下:

```sql
create table t ( i int primary key, j int ) partition by list (i) (values(2018) , values(2019));
```

此时 pg_constraint:

```
zhanyi=# select oid,pg_get_constraintdef(oid),conrelid::regclass, conindid::regclass from pg_constraint where conindid != 0;
  oid  | pg_get_constraintdef | conrelid  |    conindid
-------+----------------------+-----------+----------------
 36020 | PRIMARY KEY (i)      | t         | t_pkey
 36022 | PRIMARY KEY (i)      | t_1_prt_1 | t_1_prt_1_pkey
 36024 | PRIMARY KEY (i)      | t_1_prt_2 | t_1_prt_2_pkey
(3 rows)
```

pg_inherits:

```
zhanyi=# select inhrelid::regclass, inhparent::regclass from pg_inherits ;
    inhrelid    | inhparent
----------------+-----------
 t_1_prt_1      | t
 t_1_prt_2      | t
 t_1_prt_1_pkey | t_pkey
 t_1_prt_2_pkey | t_pkey
```

相应地 t_pkey 对应 pg_class 中 relhassubclass 也为 true 了.

分区最佳实践; Consider partitioning by the most granular level. A multi-level design can reduce query planning time. 当然这只是一般情况下, 原文也讲了. When you create multi-level partitions on ranges, it is easy to create a large number of subpartitions, some containing little or no data. This can add many entries to the system tables, which increases the time and memory required to optimize and execute queries. but a flat partition design runs faster.

Exchanging a Partition; 相当于 swap 操作, 但是仅会 swap 一些元信息, 以及数据指针. 在 exchange 非 default partition 时, GP 默认会利用 partition 上的 check 约束来检查数据合法性. 可以使用  WITHOUT VALIDATION 来关闭这一行为. 在 exchange default paritition 时, default partition 上没有任何 check 导致 GP 无法检查数据合法性, 所以默认 GP 不允许 exchange default partition. 如果强行 exchange default partition, 需要用户确认数据满足放入 Default Partition. 如下例子演示 Exchanging a Leaf Child Partition with an External Table:

```sql
zhanyi=# \d+ sales_2000_ext;
        External table "public.sales_2000_ext"
 Column |  Type   | Modifiers | Storage  | Description
--------+---------+-----------+----------+-------------
 id     | integer |           | plain    |
 year   | integer |           | plain    |
 qtr    | integer |           | plain    |
 day    | integer |           | plain    |
 region | text    |           | extended |
Type: readable
Encoding: UTF8
Format type: csv
Format options: delimiter ',' null '' escape '"' quote '"'
External location: gpfdist://172.17.0.6:8080/sales_2000

zhanyi=# \d+ sales_1_prt_yr_1
            Table "public.sales_1_prt_yr_1"
 Column |  Type   | Modifiers | Storage  | Description
--------+---------+-----------+----------+-------------
 id     | integer |           | plain    |
 year   | integer |           | plain    |
 qtr    | integer |           | plain    |
 day    | integer |           | plain    |
 region | text    |           | extended |
Check constraints:
    "sales_1_prt_yr_1_check" CHECK (year >= 2000 AND year < 2001)
Inherits: sales
Has OIDs: no
Distributed by: (id)

zhanyi=# select * from sales_2000_ext;
 id | year | qtr | day |     region
----+------+-----+-----+----------------
  1 | 2000 |   1 |   1 | blog.hidva.com
  3 | 2000 |   1 |   1 | blog.hidva.com
  2 | 2000 |   1 |   1 | blog.hidva.com
  4 | 2000 |   1 |   1 | blog.hidva.com
(4 rows)

zhanyi=# select * from public.sales_1_prt_yr_1
zhanyi-# ;
 id | year | qtr | day |     region
----+------+-----+-----+----------------
  3 | 2000 |   1 |   1 | blog.hidva.com
  1 | 2000 |   1 |   1 | blog.hidva.com
  2 | 2000 |   1 |   1 | blog.hidva.com
(3 rows)

-- swap 后.

zhanyi=# ALTER TABLE sales ALTER PARTITION yr_1
zhanyi-#    EXCHANGE PARTITION yr_1
zhanyi-#    WITH TABLE sales_2000_ext WITHOUT VALIDATION;
NOTICE:  exchanged partition "yr_1" of partition "yr_1" of relation "sales" with relation "sales_2000_ext"
ALTER TABLE
zhanyi=# select * from public.sales_1_prt_yr_1;
 id | year | qtr | day |     region
----+------+-----+-----+----------------
  1 | 2000 |   1 |   1 | blog.hidva.com
  3 | 2000 |   1 |   1 | blog.hidva.com
  2 | 2000 |   1 |   1 | blog.hidva.com
  4 | 2000 |   1 |   1 | blog.hidva.com
(4 rows)

zhanyi=# select * from sales_2000_ext;
 id | year | qtr | day |     region
----+------+-----+-----+----------------
  3 | 2000 |   1 |   1 | blog.hidva.com
  1 | 2000 |   1 |   1 | blog.hidva.com
  2 | 2000 |   1 |   1 | blog.hidva.com
(3 rows)

zhanyi=#  \d+ sales_2000_ext;
             Table "public.sales_2000_ext"
 Column |  Type   | Modifiers | Storage  | Description
--------+---------+-----------+----------+-------------
 id     | integer |           | plain    |
 year   | integer |           | plain    |
 qtr    | integer |           | plain    |
 day    | integer |           | plain    |
 region | text    |           | extended |
Check constraints:
    "sales_1_prt_yr_1_check" CHECK (year >= 2000 AND year < 2001)
Has OIDs: no
Distributed by: (id)

zhanyi=# \d+ sales_1_prt_yr_1
       External table "public.sales_1_prt_yr_1"
 Column |  Type   | Modifiers | Storage  | Description
--------+---------+-----------+----------+-------------
 id     | integer |           | plain    |
 year   | integer |           | plain    |
 qtr    | integer |           | plain    |
 day    | integer |           | plain    |
 region | text    |           | extended |
Type: readable
Encoding: UTF8
Format type: csv
Format options: delimiter ',' null '' escape '"' quote '"'
External location: gpfdist://172.17.0.6:8080/sales_2000
Check constraints:
    "sales_1_prt_yr_1_check" CHECK (year >= 2000 AND year < 2001)

```

分区表的 ALTER TABLE 语法; 考虑到多级分区的存在, 对分区表树中某个节点的 ALTER 操作需要明确指出从分区表根节点到该节点的访问路径. 这是通过 0 个或多个 ALTER PARTITION 子句来指定的. 每一个 ALTER PARTITION 有三种方式来指定下一个分区节点: parition_number, `FOR (RANK(number))`, `FOR ('value')`, 关于这三种方式语义参考 GP ALTER TABLE 文档. 多个 ALTER PARTITION 确定的下一个分区节点链表就组成了一个访问路径. 下面举个例子:

```sql
CREATE TABLE p3_sales4 (id int, day int, year int, month int, region text)
PARTITION BY LIST (year)
SUBPARTITION BY LIST (month)
    SUBPARTITION TEMPLATE (VALUES(1), VALUES(2))
SUBPARTITION BY LIST (region)
    SUBPARTITION TEMPLATE (VALUES ('usa'), VALUES ('asia'))
(VALUES(2018), VALUES(2019));
```

如上 SQL 会创建出具有如下分区层次的分区表:

![]({{site.url}}/assets/p3_sales4.jpg)

如果想对 Y2018M2Rasia 分区叶子表做一个 exchange 操作, 对应的 ALTER TABLE 语法便是:

```sql
ALTER TABLE p3_sales4   -- 首先从根节点出发
ALTER PARTITION FOR ('2018')  -- 这里指定了第 0 层分区中可以存放 year=2018 的那个分区.
ALTER PARTITION FOR ('2')  -- 指定了第 1 层分区中可以存放 month=2 的那个分区.
EXCHANGE PARTITION FOR ('asia')   -- 指定了第 2 层分区中可以存放 region='asia' 的那个分区. 并对该分区做一次 exchange 操作.
WITH TABLE xxx;
```

## pg_partition

The pg_partition system catalog table is used to track partitioned tables and their inheritance level relationships. Each row of pg_partition represents either the level of a partitioned table in the partition hierarchy, or a subpartition template description. The value of the attribute paristemplate determines what a particular row represents. 按我理解 pg_partition 是根据分区表建表 DDL 收集到的信息来填充的. 下面以一个具体分区表在 pg_partition 中的元信息来介绍 pg_partition:

```sql
CREATE TABLE p3_sales (id int, year int, month int, day int,
region text)
DISTRIBUTED BY (id)
PARTITION BY RANGE (year)
    SUBPARTITION BY RANGE (month)
       SUBPARTITION TEMPLATE (
        START (1) END (2) EXCLUSIVE EVERY (1),
        DEFAULT SUBPARTITION other_months )
           SUBPARTITION BY LIST (region)
             SUBPARTITION TEMPLATE (
               SUBPARTITION usa VALUES ('usa'),
               DEFAULT SUBPARTITION other_regions )
( START (2002) END (2004) EXCLUSIVE EVERY (1),
  DEFAULT PARTITION outlying_years );
```
其在 pg_partition 的元信息有:

```
zhanyi=# select oid,parrelid::regclass,* from pg_partition;
  oid   | parrelid | parrelid | parkind | parlevel | paristemplate | parnatts | paratts | parclass
--------+----------+----------+---------+----------+---------------+----------+---------+----------
 104106 | p3_sales |   103395 | r       |        0 | f             |        1 | 2       | 1978
 104143 | p3_sales |   103395 | r       |        1 | t             |        1 | 3       | 1978
 104144 | p3_sales |   103395 | r       |        1 | f             |        1 | 3       | 1978
 104219 | p3_sales |   103395 | l       |        2 | t             |        1 | 5       | 1994
 104220 | p3_sales |   103395 | l       |        2 | f             |        1 | 5       | 1994
(5 rows)
```

可以看到:

parrelid, The object identifier of the table. 即分区表根表对应的 oid.
parnatts, 按我理解存放着分区列的个数. 一般取值为 1. 不晓得 PG/GP 是否支持指定多个分区列.
paratts, parclass; 一一对应. `paratts[i]`, 使用 `SELECT * FROM pg_attribute WHERE attrelid = ${parrelid} and attnum = ${paratts[i]};` 可以查找到分区列的具体信息. `parclass[i]`, 存放着该分区列对应的 op class 信息.
parlevel, paristemplate; 根据 DDL 可以看到, 在 parlevel = 0 层使用 year 列取值来进行分区. 而且是以非模板的. 在 parlevel = 1 层使用 month 列值进行分区, 这里是以模板形式建立的分区. 在 parlevel = 2 层使用 region 列来建立分区. 根据 pg_partition 中的元信息可以看到, 使用模板建立的分区其在 pg_partition 中对应着两行, 一行描述着分区级别本身. 一行表明了该级分区是通过模板建立的. ~~感觉是有点重复描述了.~~. 另外也可以看到分区树中叶子节点那一层(parlevel=3)并未在 pg_partition 表中体现.


## pg_partition_rule

按我理解, pg_partitoin 中每一行在 pg_partition_rule 中都对应着多行, 来描述某个特定级层分区的信息. 对于 paristemplate=true 的行, 其在 pg_partition_rule 中对应的行记录着模板取值, 此时这些行不与任何具体的分区表关联, 仅是用来存放模板的信息. 如 oid=104143 的 pg_partition 行在 pg_partiton_rule 对应的行信息:

```
zhanyi=# select * from pg_partition_rule where paroid = 104143;
-[ RECORD 1 ]-----+----------------------------------------------------------------------------------------------------------
paroid            | 104143
parchildrelid     | 0  # 取值为 0, 不关联任何具体的分区表.
parparentrule     | 0
parname           |
parisdefault      | f
parruleord        | 2
parrangestartincl | t
parrangeendincl   | f
parrangestart     | ({CONST :consttype 23 :constlen 4 :constbyval true :constisnull false :constvalue 4 [ 1 0 0 0 0 0 0 0 ]})  -- 0x1 小端模式(不明白为啥展示是 8 个字节.
parrangeend       | ({CONST :consttype 23 :constlen 4 :constbyval true :constisnull false :constvalue 4 [ 2 0 0 0 0 0 0 0 ]})
parrangeevery     | ({CONST :consttype 23 :constlen 4 :constbyval true :constisnull false :constvalue 4 [ 1 0 0 0 0 0 0 0 ]})
parlistvalues     | <>
parreloptions     |
partemplatespace  | 0
-[ RECORD 2 ]-----+----------------------------------------------------------------------------------------------------------
paroid            | 104143
parchildrelid     | 0
parparentrule     | 0
parname           | other_months
parisdefault      | t
parruleord        | 1
parrangestartincl | f
parrangeendincl   | f
parrangestart     | <>
parrangeend       | <>
parrangeevery     | <>
parlistvalues     | <>
parreloptions     |
partemplatespace  | 0
```

对于 paristemplate=false 的行, 其在 pg_partition_rule 中对应的行记录着该级层分区下所有的子分区表的信息. 如对于 parlevel = 0 的行, 其有三个子分区, 所以在 pg_partition_rule 中对应着三行, 这三行分别存放着三个子分区的具体信息. 对于 parlevel = 1 的行, 这一层本身有三个分区表, 每个分区表又有 2 个子分区, 所以共有 6 个子分区表. 所以在 pg_partition_rule 中并不会有分区根表的信息.

这里介绍下 pg_partition_rule 部分比较特别的列的语义, 其他列语义描述参考 [GP 官方文档](https://gpdb.docs.pivotal.io/5190/ref_guide/system_catalogs/pg_partition_rule.html).

parchildrelid; 存放着当前分区表在 pg_class 的 oid. 这里列名包含 'child' 是站在 pg_partition 的角度来看待的.
parparentrule; 这里原文应该是写错了. 该列存放着当前分区表父表在 pg_partition_rule 的 oid, 所以 references 是 pg_partition_rule.oid.
parname; 当前分区表在建表 DDL 中的名字. 若用户未显式指定, 则为空. 如:

```
oid               | 104343
parchildrelname   | p3_sales_1_prt_2_2_prt_2_3_prt_other_regions
paroid            | 104220
parchildrelid     | 103844
parparentrule     | 104145
parname           | other_regions
--------
oid               | 104307
parchildrelname   | p3_sales_1_prt_2_2_prt_other_months_3_prt_usa
paroid            | 104220
parchildrelid     | 103712
parparentrule     | 104207
parname           | usa
```

## Exchange Partition 实现猜测

这里从现象入手简单猜测一下 Exchange partition 背后的原理. 具体操作是执行了 ALTER ... EXCHANGE PARTITION, 根据 xlog dump 分析出修改了哪些表, 之后 dump exchange partition 前后这些表的数据, 并进行了对比.

首先看下 partition 组织, 如上所示 GP 中是 pg_partition, pg_partition_rule 两个系统表存放着分区表的结构. 所以 exchange partition A with table B 会发生如下变更, 这里假设 A 在分区层次中的父表是 C, 这里 A, B, C 均是表的 oid, 而不是表名.

1.  把 A 在 pg_partition_rule 中记录的 parchildrelid 换为 B 表的 oid.
2.  表约束, 既然 A, B 可以 exchange, 那么 GP 自然认为 A 拥有的分区表约束, B 自然也满足, 所以会把 A 的表约束同时加到 B 上. 考虑到 A 中数据仍然符合表约束, 所以 GP 这里不会移除 A 的约束. 所以如果 B 是 external table, 那么虽然 B 在语法上不能使用 CHECK 子句来指定表约束, 但 exchange 之后 B 便自然具有表约束了. 具体变化是:

    -   在 pg_constraint 表中为 B 新增相应记录, 这里新增约束记录与 A 现有约束记录基本上完全一致, 除了 coninhcount 字段.. 同时更新 B::relchecks 字段从 0 变为 A::relchecks 的值. 这里有个 [BUG](https://github.com/greenplum-db/gpdb/issues/9956) 呦~
3.  之后在修改下继承关系, 移除 A 的继承关系, 加上 B 的继承关系; 这里假设 exchange 前, A 的父表是 C, 那么该步会让 B 继承 C, 同时移除 A 对 C 的继承. 具体行为是:

    1.  A 的列在 pg_attribute 对应的 attislocal 字段从 'f' 变为 't', attinhcount 从 1 变为 0.
    2.  B 的列则进行了相反的改变, 即 attislocal 从 't' 变为 'f', attinhcount 从 0 变为 1.
    3.  A 中约束对应 coninhcount 变为 0.
    4.  由于 B 中某些约束在 C 中也存在, 所以这里会更新 B 中约束 coninhcount 取值.
    5.  pg_inherits 中相应记录的变更: 移除 A 与 C 的继承关系, 新增 B 与 C 的继承关系.

    对应的 SQL  应该是:

    ```sql
    ALTER TABLE A NO INHERIT C;
    ALTER TABLE B INHERIT C;
    ```

    但这里实际发生的行为与如上 SQL 又不太一样. 比如:

    ```sql
    create table t1( i int, j int );
    create table t2 ( i int, j int, z int );
    ```

    此时 t2 列的属性:

    ```
    zhanyi=# select attname,attislocal,attinhcount from pg_attribute where attrelid  = 't2'::regclass;
        attname    | attislocal | attinhcount
    ---------------+------------+-------------
    gp_segment_id | t          |           0
    tableoid      | t          |           0
    cmax          | t          |           0
    xmax          | t          |           0
    cmin          | t          |           0
    xmin          | t          |           0
    ctid          | t          |           0
    i             | t          |           0
    j             | t          |           0
    z             | t          |           0
    (10 rows)
    ```

    执行 `alter table t2 inherit t1;` 之后:

    ```
    zhanyi=# select attname,attislocal,attinhcount from pg_attribute where attrelid  = 't2'::regclass;
        attname    | attislocal | attinhcount
    ---------------+------------+-------------
    gp_segment_id | t          |           0
    tableoid      | t          |           0
    cmax          | t          |           0
    xmax          | t          |           0
    cmin          | t          |           0
    xmin          | t          |           0
    ctid          | t          |           0
    i             | t          |           1
    j             | t          |           1
    z             | t          |           0
    (10 rows)
    ```

    可以看到 attislocal 并没有变化.

4.  为 A 对应的 record type 新增 array 类型. 在 PG/GP 中, 每当新建一个表时, 都会同时新增出两个类型: record type, array type, 其中 record type 用于可用于表示新表一行数据, array type 则是元素类型为新建 record type 的数组. 但在分区表中, 只有根表才会有对应 record type 的 array type. 中间表与叶子节点表则都只有对应的 record type.
    这里考虑到 A 被 exchange 了, 不再是分区表体系中一员了, 此时便会为 A 新增对应的 array type. 不过这样的话, 由于 B 是有 array type 的, B 在 exchange 时看代码 GP 也没有删除 B array type.
5.  会交换下 A, B 的表名. 即 swap(A.relname, B.relname). 以及 A record type, array type 与 B record type, array type 类型名.
6.  GP 可能认为 ACL 是跟着表名走的, 所以这里也会交换下 A, B 的 relacl 字段信息.
7.  针对如上改动在 pg_depend 新增/删除适当的记录, 主要有:

    -   A 依赖 C 的记录被移除. 新增 B 依赖 C 的记录.
    -   B 新增的约束与 B 的依赖.
    -   为 A 新建的 array type 对 record type 的依赖.

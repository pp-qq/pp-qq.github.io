---
title: "PG Index Methods and Operator Classes"
hidden: true
tags: ["Postgresql/Greenplum"]
---

## Index Methods and Operator Classes

Access method, index access method. 按照我的理解, PG 最初是希望所有对表数据, 索引数据的访问都通过 access method 来进行, 这样就可以把 PG 内核与具体的数据存储格式隔离开, 便于今后新数据存储格式的引入. 目前 PG 中只有 index 实现了这种访问姿势, 即 index access method, 也即新实现一个索引类型只需要新实现一个 index access method 即可, 完全不需要改动 PG 内核. 话说目前业界也在试图实现 table access method, 比如像 zstore 等.

operator class, operator class 是 PG 中 type 与 index 之间的桥梁. operator class 有两部分组成:

-   operators, 又被称为 strategy. the set of WHERE-clause operators that can be used with an index (i.e., can be converted into an index-scan qualification). 即告诉优化器, 当在 WHERE 条件中出现这些 operators 时, 可以试下 index scan.
-   support procedures, 由 index access method 内部使用. 一般 index access method 会使用 support procedures 来确定数据在 index 中的位置.

PG index access method 使用 number 来标识 operator, support procedures. 简单来说, 就是 index access method 根据其实现细节为其支持的 operators, 以及要使用 support procedures 各指定一个 int 整数标识符, 之后用户在定义 operator class 时, 将指定的 int 整数标识符关联到对应的 operator 或者 function 上. 比如 btree index access method 支持的 number 参考 'Table 36-2', 那么当用户为一个新类型建立 btree operator class 时的姿势就可以是:

```sql
CREATE OPERATOR CLASS CUSTOM_TYPE_ops
DEFAULT FOR TYPE CUSTOM_TYPE USING btree AS
	OPERATOR    1   <  (CUSTOM_TYPE, CUSTOM_TYPE),
	OPERATOR    2   <= (CUSTOM_TYPE, CUSTOM_TYPE),
	OPERATOR    3   =  (CUSTOM_TYPE, CUSTOM_TYPE),
	OPERATOR    4   >= (CUSTOM_TYPE, CUSTOM_TYPE),
	OPERATOR    5   >  (CUSTOM_TYPE, CUSTOM_TYPE),
	FUNCTION    1   CUSTOM_TYPE_cmp(CUSTOM_TYPE, CUSTOM_TYPE);
```

default operator class. It is possible to define multiple operator classes for the same data type and index method. By doing this, multiple sets of indexing semantics can be defined for a single data type. For example, a B-tree index requires a sort ordering to be defined for each data type it works on. It might be useful for a complex-number data type to have one B-tree operator class that sorts the data by complex absolute value, another that sorts by real part, and so on. Typically, one of the operator classes will be deemed most commonly useful and will be marked as the default operator class for that data type and index method. 当对给定列建立索引时, 若此时未显式指定 operator class, 那么则使用 default operator class.

operator family; An operator family contains one or more operator classes, and can also contain indexable operators and corresponding support functions that belong to the family as a whole but not to any single class within the family. We say that such operators and functions are “loose” within the family, as opposed to being bound into a specific class. Typically each operator class contains single-data-type operators while cross-data-type operators are loose in the family. 参见 '36.14.5. Operator Classes and Operator Families' 第一段了解 operator family 背景. ~~这里我有一个非常适当的例子可以活生生地展示下 operator family 的使用场景, 但是现在太晚了, 我要睡觉了, 就不写了. 等我以后有空时吧~~~

既然有了 operator family, 为啥我们还需要 operator class. The reason for defining operator classes is that they specify how much of the family is needed to support any particular index. If there is an index using an operator class, then that operator class cannot be dropped without dropping the index — but other parts of the operator family, namely other operator classes and loose operators, could be dropped. Thus, an operator class should be specified to contain the minimum set of operators and functions that are reasonably needed to work with an index on a specific data type, and then related but non-essential operators can be added as loose members of the operator family.

opclass/opfamily 对 operator 的重要性; 要知道 PG 是支持用户自定义类型与 operator 的, 对于一个用户定义的 operator, 当其未出现在任何 operator class/family 中时, PG 对这个 operator 的背景知识是一无所知的, 这就意味着如果我们在 WHERE 中使用了这个 operator, 那么 PG 将只能走 seqscan. 当一个 operator 出现在某个 operator class/family 中时, 这就意味着根据这个 operator 在 opclass/opfamily 所处的位置, 即 strategy number, PG 就知晓了这个 operator 相关的特性, 从而在优化过程中, 根据这些特性做出某些优化动作. 以 operator `<(CUSTOM_TYPE, CUSTOM_TYPE)` 为例, 若其未出现在任何 opclass/opfamily 中, 那么当该 operator 出现在 WHERE 条件中时, 将只能走 seqscan 来判断这个 operator. 但是如果 operator 出现在某个 opclass/opfamily strategy = 1 对应的位置, 那么 PG 便知道了 operator `<(CUSTOM_TYPE, CUSTOM_TYPE)` 是 CUSTOM_TYPE 这个类型的 lessthan 比较运算符. 意味着对于 CUSTOM_TYPE 类型的 A, B, C, 若 `A < B`, `B < C`, 那么 PG 便知道 `A < C` 也是成立的. 同样若 `B < C`, 并且 `B < A` 不成立, 那么 PG 便知道 `C < A` 也肯定不成立. 很显然此时 `<` 的实现要符合 PG 这里的假设要求! 也意味着当 `<` 出现在 WHERE 条件中, 并且此时有相关索引时, 那么 PG 就会考虑 indexscan. 参见 '举个栗子' 节对此情况的演示.

operator class 不单单用来与索引交互. PostgreSQL uses operator classes to infer the properties of operators in more ways than just whether they can be used with indexes. Therefore, you might want to create operator classes even if you have no intention of indexing any columns of your data type. 参见 '36.14.6. System Dependencies on Operator Classes' 了解.

order operator, search operator; 参见 '36.14.7. Ordering Operators' 了解. 简单来说就是可以用索引实现 order by 子句.

lossy index. 参见 '36.14.8. Special Features of Operator Classes' 了解, 简单来说就是 lossy index scan 返回的结果集是实际 WHERE 结果集的超集, 此时在 index scan 之后仍需要一一判断下 index scan 返回的每一行是否匹配条件.

STORAGE clause. 参见 '36.14.8. Special Features of Operator Classes' 了解, 简单来说就是对于一个类型 T 来说, 其存放在索引的可以是另外一个类型.

### 举个栗子

假设我们现在自定义了类型 MagicInt2, MagicInt4, 大部分情况下这俩类型与 int2, int4 类型具有相同的性质, 除了:

- 不支持 MagicInt2 与 MagicInt4 相互之间的转换.
- `<(MagicInt2, MagicInt2)` 与 `<(MagicInt2, MagicInt4)` 的比较规则如下伪代码所示:

  ```c
  bool lessthan(MagicInt2 left, MagicInt2/* MagicInt4 */ right) {
    if (left <= 10)
      return true;
    if (left <= 500)
      return false;
    if (left <= 600)
      return true;
    return false;
  }
  ```

同时我们也定义了 MagicIntOps operator family 以及 MagicInt2Ops, MagicInt4Ops operator class:

```sql
CREATE OPERATOR FAMILY MagicIntOps USING btree;

CREATE OPERATOR CLASS MagicInt2Ops
DEFAULT FOR TYPE MagicInt2 USING btree FAMILY MagicIntOps AS
  OPERATOR    1   <  (MagicInt4, MagicInt4)
  ...;

CREATE OPERATOR CLASS MagicInt4Ops
DEFAULT FOR TYPE MagicInt4 USING btree FAMILY MagicIntOps AS
  OPERATOR    1   <  (MagicInt4, MagicInt4)
  ...;
```

之后再做一下准备工作:

```sql
CREATE TABLE t(i int, d64 MagicInt2);
INSERT INTO t SELECT i, i FROM generate_series(1, 1000000) f(i);
CREATE INDEX on t(d64);
ANALYZE t;
SET enable_seqscan TO off;
```

之后可以看到 `<(MagicInt2, MagicInt4)` 出现在 WHERE 条件中时, PG 只会有 seqscan path.

```sql
zhanyi=# explain select i from t where d64 < '11'::MagicInt4;
                                                     QUERY PLAN
---------------------------------------------------------------------------------------------------------------------
 Gather Motion 3:1  (slice1; segments: 3)  (cost=100000000000000000000.00..100000000000000000000.00 rows=15 width=4)
   ->  Seq Scan on t  (cost=100000000000000000000.00..100000000000000000000.00 rows=5 width=4)
         Filter: (d64 < '11.00'::MagicInt4)
 Optimizer: Postgres query optimizer
```

与之相对的是 `<(MagicInt2, MagicInt2)` 出现在 WHERE 中时, PG 会选择 index scan 这个更高效的链路.

```sql
zhanyi=# explain select i from t where d64 < '11'::MagicInt2;
                                 QUERY PLAN
-----------------------------------------------------------------------------
 Gather Motion 3:1  (slice1; segments: 3)  (cost=0.15..0.41 rows=15 width=4)
   ->  Index Scan using t_d64_idx on t  (cost=0.15..0.41 rows=5 width=4)
         Index Cond: (d64 < '11.00'::MagicInt2)
 Optimizer: Postgres query optimizer
```

另外也有个有趣的现象是:

```sql
zhanyi=# explain select d64 from t where d64 < '11'::MagicInt2;
                                  QUERY PLAN
------------------------------------------------------------------------------
 Gather Motion 3:1  (slice1; segments: 3)  (cost=0.15..0.41 rows=15 width=8)
   ->  Index Only Scan using t_d64_idx on t  (cost=0.15..0.41 rows=5 width=8)
         Index Cond: (d64 < '11.00'::MagicInt2)
 Optimizer: Postgres query optimizer

zhanyi=# explain select d64 from t where d64 < '11'::MagicInt4;
                                  QUERY PLAN
------------------------------------------------------------------------------
 Gather Motion 3:1  (slice1; segments: 3)  (cost=0.15..0.41 rows=15 width=8)
   ->  Index Only Scan using t_d64_idx on t  (cost=0.15..0.41 rows=5 width=8)
         Index Cond: (d64 < '11.00'::MagicInt4)
 Optimizer: Postgres query optimizer
```

可以看到由于我们这里只 `SELECT d64` 使得 PG 发现单纯地 index only scan 便可以满足要求. 但这里两个 index only scan 执行起来是不太一样的! 对于 `d64 < '11'::MagicInt2` 这条查询, 当 index only scan 遇到 `d64 = 11`, 发现此时 `d64 < '11'::MagicInt2` 不再成立, 而且这里使用的 `<` 是出现在 operator class 的, 所以 PG 会认为在 `d64=11` 之后的行都不再满足 `d64 < '11'::MagicInt2`, 所以便会终止 index only scan, 也即意味着最终仅会返回 10 行. 但对于 `d64 < '11'::MagicInt4` 这条查询, PG 虽然是 index only scan, 但会扫描完 index, 不会提前终止. 所以:

```sql
zhanyi=# select count(d64) from t where d64 < '11'::MagicInt4;
 count
-------
   110  -- 扫描完 index 中所有 entry.

zhanyi=# select count(d64) from t where d64 < '11'::MagicInt2;
 count
-------
    10
```

根据我们之前对 `<` 的实现可知 110 便是期望结果, 之所以在 `d64 < '11'::MagicInt2` 时结果只有 10 行, 是由于我们这里的实现未满足 PG 的假设, 很显然是我们的实现错误了, 毕竟是为了演示.

在我们把 `<(MagicInt2, MagicInt4)` 加入到 operator family MagicIntOps 中时, PG 便知道了 `<(MagicInt2, MagicInt4)` 这个运算符相关背景信息以及相关假设: 比如对于 MagicInt2 类型的 B, C; 以及 MagicInt4 类型的 A, 当 B < C, 并且 B < A 不成立时, PG 便会顺理成章地假设 C < A 也是不成立的. 此后 `d64 < '11'::MagicInt2` 与 `d64 < '11'::MagicInt4` 的行为便完全一致了.


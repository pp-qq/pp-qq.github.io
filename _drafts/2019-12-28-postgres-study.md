---
title: "PG/GP 学习杂烩"
hidden: true
tags: ["Postgresql/Greenplum"]
---

这里记录着对 Postgresql/Greenplum 代码学习期间总结记录的一些东西, 这些东西大多篇幅较小(或者质量不高...), 以至于不需要强开一篇 POST. 若不特殊说明, 本节内容来源于 PG9.6 文档 + PG 9.6 的代码. 或者 GP 6.4 文档 + GP master 代码, 具体 commit id: 53d12bd56fd124fa1b0bcd0d72ff7cf69f0bd441.

## PG 中的随机数

PG 中每个 backend 在启动时会 srandom(), 之后程序中只需要使用 random() 来生成随机数即可.

## elog(ERROR) 与 C++

在使用 C++ 编写 PostgreSQL 特定模块时, 需要注意 PG 的某些基础设施并不能与 C++ 很好地契合在一起. 比如 elog(ERROR) 就与 C++ 自身的 stack unwinding 冲突, 也即我们不应该在任何 C++ 代码路径中使用 elog(ERROR).

## GP 与 presto

GP 与 presto 的分布式执行框架完全类似. 在 [presto 文档](https://prestodb.io/docs/current/overview/concepts.html) 中所涉及到的每一个概念都可以在 GP 中找到对等的概念. 在 presto 中, 每一个 driver 处理一个 split, driver 内 operator 每次以 page 为单位来读取数据, page 采用了列式存储的方式存放了多行数据, page 内使用 block 来存放一列内容. presto 中 driver 就类似于 GP 中的 slice, 而 presto task 就类似于同一个 slice 在 GP 中同一台机器上所有 primary segment 上的集合. 简单来说: 假设一个 presto 集群有 4 个 worker, 某个表 t 有 16 个 split, 那么 presto 一个 task 在一个 worker 上会有 4 个 driver, 每个 driver 消费一个 split 的数据. 这就对应着一个 GP 集群, 有 4 台机器, 每台机器上有 4 个 primary segment.

只是在 presto 中算子之间是以 page 为单位来交换数据的, 而 GP 中是以行为单位交换的.

## pg_xlogdump

pg_xlogdump, 用来 dump xlog segment file, 我们这里介绍一下 pg_xlogdump 的使用姿势. pg_xlogdump 的主要意图便是 dump 指定 start LSN, end LSN 区间内的所有 xlog record. 其中 LSN 给定形式是: logid/recoff, 其中 logid 为 LSN 的高 32 位, recoff 为 LSN 的低 32 位. 比如 LSN 22411048 便对应着 '0/155f728', 没有 '0x' 前缀.

之后 pg_xlogdump 会根据 start LSN 计算出相应的 segment filename, 然后再在指定的路径列表下搜索 segment file, 若找到则打开 segment file 并开始 dump 工作. 这里搜索路径列表包括 '.' 当期目录, './pg_xlog' 等.

pg_xlogdump 的 start LSN, end LSN 除了显式给定之外, 还可以通过 segment filename 指定, 对于 start LSN 来说, 由 segment filename 计算出来的 LSN 便是 start LSN. 对于 end LSN 来说, 由 segment filename 计算出来的 LSN 再加上 segment filesize(默认: 16M)之后才是 end LSN.

## PG 中的加减列

在 PG 中, 针对一个表, 其约定表中每个列都有一个唯一标识, 该标识在列被创建之后指定, 之后永远不变, 即使列被删除了, 列对应的标识也不会被复用.

PG 中新增列会将新列写入到 heapfile 中, 手动试了下 `ALTER TABLE ADD COLUMN colname coltype DEFAULT defval` 是这样的. 本来我以为这个时候没必要写入的, 毕竟 heapfile 中每一行都记录着 attrite number, 在读取时如果发现一列并没有在 heapfile 中, 那么使用列的默认值即可. 但后来想到这样一种场景, 比如:

```sql
ADD COLUMN i INT DEFAULT 3
SELECT i FROM t; -- 此时返回 3.
CHANGE COLUMN i DEFAULT 33
SELECT i FROM t; -- 此时同一行的 i 将返回 33. 这样感觉之前 SET DEFAULT 3 的 SQL 就没被持久化.
```

PG 中列删除, 只是简单地在 pg_attribute 标记下, 不会改动 heapfile, 另外 pg_attribute 记录的 attval, attlen 这些与 pg_type 中某些字段重合的信息使得即使列的类型也被删除了, 仍然不影响对 heapfile tuple 的解析. 此时 INSERT 对于 dropped column 的处理会认为他们是 NULL. (所以 NULL 在数据库中是不可缺少的...


## syscache, relcache, invalid message queue

为了提升 backend 查询 system catalog 的效率, PG 中引入了 syscache, relcache 来加速这一过程. 既然是 cache, 就需要引入 cache 的同步机制, 也就是 invalid message queue. 关于 relcache, syscache 的介绍参考 [PostgreSQL的SysCache和RelCache](https://niyanchun.com/syscache-and-relcache-in-postgresql.html) 这篇文章. 关于对 invalid message queue 介绍参考我在 sinvaladt.c 中的注释.

## PG catalog 不遵循 MVCC

准确来说应该是 PG 中根据 catalog name 找到对应的 oid 这一步并不是 MVCC, 准确来说这一步总是使用 SnapshotNow. 但这一行为正在慢慢移除最终应该是将遵循 MVCC 语义. 主要原因是因为在目前 SnapshotNow 情况下, 如果不加以额外的措施可能会出现出乎预料的行为. for example, the case where a row is updated.  Depending on the placement of the old and new tuple versions in the table and its indexes, our scan might see either the old or the new version first.  If the updating transaction commits after we see the old version and before we see the new version, we'll see both of them; if the updating transaction commits after we see the new version and before we see the old version, we'll see neither of them.  Both of these results are quite surprising. In practice, the consequence is that we never safely allow a row in a system catalog to be updated without first taking a lock strong enough to keep other backends from searching for that row. 在引入 mvcc 之后, 某些 ALTER/DDL 命令可以降低自身锁级别.


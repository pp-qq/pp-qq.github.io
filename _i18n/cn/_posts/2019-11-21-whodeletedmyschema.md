---
title: "谁动了我的 Schema?"
hidden: false
tags: ["Postgresql/Greenplum"]
---

在一次常规的[ADB PG](https://www.aliyun.com/product/gpdb)实例备份巡检中, 发现了一个实例备份失败, 而且报错原因很是奇怪: `schema with OID 34196 does not exist`. 查看代码得知该报错是指: 在 pg_namespace 中找不到 pg_class 中某个 relation 对应的 schema. 这不可能啊! 毕竟在 schema 内仍存在对象时我们是无法删除 schema 的啊:

```sql
rdsgp=# drop schema test;
ERROR:  cannot drop schema test because other objects depend on it
HINT:  Use DROP ... CASCADE to drop the dependent objects too.
```

登录到该实例上开始查看, 如下可以看到 oid=34298 的表 test2 对应的 schema 确实在 pg_namespace 中不存在. 很诡异!

```sql
migrate=# select oid,relname,relkind from pg_class where relnamespace = 34196;
  oid  | relname | relkind 
-------+---------+---------
 34298 | test2   | r
(1 row)

migrate=# select * from pg_namespace where oid = 34196;
 nspname | nspowner | nspacl 
---------+----------+--------
(0 rows)
```

继续通过 GP 一些元数据表来查看该表相关信息, 可知表 oid=34298 在 2019-10-14 22:19:53 时创建, 具有一个分布列.

```sql
migrate=# select * from pg_stat_last_operation where objid in (34298, 34196) order by statime desc;
 classid | objid | staactionname | stasysid | stausename | stasubtype |           statime            
---------+-------+---------------+----------+------------+------------+------------------------------
    1259 | 34298 | CREATE        |    24579 | migrate    | TABLE      | 2019-10-14 22:19:53.59333+08
(1 row)

migrate=# SELECT * from gp_distribution_policy where localoid = 34298;
 localoid | attrnums 
----------+----------
    34298 | {1}
(1 row)
```

于是想看下该表在 segments 上的元信息, (继续透漏着诡异的气息), 在 segment 上该表不存在!

```sql
migrate=# select * from gp_dist_random('pg_class') where oid = 34298;
(No rows)
```

这不可能!!! 表 oid = 34298 明明是存在分布列的, 表明其不是通过 `PGOPTIONS='-c gp_session_role=utility'` 这种操作创建的, 也就是这个表不可能只在 master 上存在的啊! . (通过 gp_session_role=utility 创建的表是不可能有分布列的:

```sql
$PGOPTIONS='-c gp_session_role=utility' psql 
Timing is on.
Pager usage is off.
psql (8.2.15)
Type "help" for help.

rdsgp=# create table t(i int) DISTRIBUTED BY(i);
CREATE TABLE
Time: 14.219 ms
rdsgp=# select * from gp_distribution_policy where localoid = 't'::regclass;
(0 rows)  -- 不会存在分布列!

Time: 2.851 ms
```

至此, 这个实例上目前发现两个比较诡异的问题:

-  为啥表 oid=34298 对应的 schema 已经不存在了?
-  为啥表 oid=34298 只在 master 上存在?

使用 pg_filedump 查看 pg_namespace 对应的 table data file, 可以看到确实存在过 oid=34196 的 schema, 对应 schema name 为 `zz`, 该 schema 在事务 xid=1019109 时创建, 在事务 xid=1021142 时被删除. 还可以看到事务 xid=1021142 在删除 oid=34196 schema 同时还新建了 oid=34286 同名 schema:

```
Item 191 -- Length:  100  Offset: 12664 (0x3178)  Flags: USED
  XMIN: 1019109  CMIN: 13  XMAX: 1021142  CMAX|XVAC: 13  OID: 34196
  Block Id: 0  linp Index: 191   Attributes: 3   Size: 32
  infomask: 0x0511 (HASNULL|HASOID|XMIN_COMMITTED|XMAX_COMMITTED) 
  t_bits: [0]: 0x03 

  3178: e58c0f00 d6940f00 0d000000 00000000  ................
  3188: bf000318 11052003 f0572203 94850000  ...... ..W".....
  3198: 7a7a0000 00000000 00000000 00000000  zz..............
  31a8: 00000000 00000000 00000000 00000000  ................
  31b8: 00000000 00000000 00000000 00000000  ................
  31c8: 00000000 00000000 00000000 00000000  ................
  31d8: 03600000                             .`..

 Item 193 -- Length:  100  Offset: 12456 (0x30a8)  Flags: USED
  XMIN: 1021142  CMIN: 13  XMAX: 1021368  CMAX|XVAC: 13  OID: 34286
  Block Id: 0  linp Index: 193   Attributes: 3   Size: 32
  infomask: 0x0511 (HASNULL|HASOID|XMIN_COMMITTED|XMAX_COMMITTED) 
  t_bits: [0]: 0x03 

  30a8: d6940f00 b8950f00 0d000000 00000000  ................
  30b8: c1000318 11052003 f0572203 ee850000  ...... ..W".....
  30c8: 7a7a0000 00000000 00000000 00000000  zz..............
  30d8: 00000000 00000000 00000000 00000000  ................
  30e8: 00000000 00000000 00000000 00000000  ................
  30f8: 00000000 00000000 00000000 00000000  ................
  3108: 03600000  
```

这就很奇怪了, 为啥事务 xid=1021142 在删除 oid=34196 的 schema 时, 没有报错呢, 毕竟 oid=34196 schema 下面是有个 oid=34298 表的咧. 继续使用 pg_filedump 看下 pg_class 的内容, 可以看到 oid=34298 表 test2 是在 xid=1021147 时创建的, 与删除 oid=34196 schema 的事务 xid=1021142 很接近啊, 难道是 MVCC 搞的鬼?

```
 Item  95 -- Length:  168  Offset: 16808 (0x41a8)  Flags: USED
  XMIN: 1021147  CMIN: 0  XMAX: 0  CMAX|XVAC: 0  OID: 34298
  Block Id: 7  linp Index: 95   Attributes: 30   Size: 32
  infomask: 0x0911 (HASNULL|HASOID|XMIN_COMMITTED|XMAX_INVALID) 
  t_bits: [0]: 0xff [1]: 0xff [2]: 0xff [3]: 0x0f 

  41a8: db940f00 00000000 00000000 00000700  ................
  41b8: 5f001e08 110920ff ffff0f00 fa850000  _..... .........
  41c8: 74657374 32000000 00000000 00000000  test2...........
  41d8: 00000000 00000000 00000000 00000000  ................
  41e8: 00000000 00000000 00000000 00000000  ................
  41f8: 00000000 00000000 00000000 00000000  ................
  4208: 94850000 fb850000 03600000 00000000  .........`......
  4218: fa850000 00000000 00000000 00000000  ................
  4228: 00000000 00000000 00000000 00000000  ................
  4238: 00007268 38000000 00000000 00000000  ..rh8...........
  4248: 00000000 d6940f00                    ........    
```

细想一下, 确实存在一种可行性: 事务 1 分别执行 `DROP SCHEMA zz`, `CREATE SCHEMA zz`. 事务 2 在事务 1 DROP CREATE 之间执行 `CREATE TABLE zz.test2`, 对于事务 2 而言, 由于此时事务 1 尚未提交, 所以其认为 schema `zz` 仍是有效的; 之后事务 1, 事务 2 分别 commit 之后应该就会出现上文所示的情形. 找了个环境试了下, 确实会这样! 呃...

难道高版本 PG 也存在这个明显的问题么? 目前线上 ADB PG 基于 GP 4.3 研发, 而 GP4.3 基于 PG8.2. 找了个 PG9.6 的环境试了下如上操作序列, 发现 PG9.x 通过 object lock 机制避免了这种情况. 在事务 1 执行 `DROP SCHEMA zz` 时, 会给 schema zz 加个 AccessExclusive object lock, 而事务 2 在 `CREATE TABLE zz.test2` 时, 会尝试对 schema zz 加个 AccessShare object lock, 该操作会一直阻塞, 直至事务 1 COMMIT:

```
pg=# select * from pg_locks
 object        |    16384 |          |      |       |            |               |    2615 | 18123 |        0 | 2/2                | 61127 | AccessShareLock(事务 2)    | f       | f
 object        |    16384 |          |      |       |            |               |    2615 | 18123 |        0 | 3/4                | 61218 | AccessExclusiveLock(事务 1) | t       | f  
```

而在事务1 COMMIT 之后, 由于原 schema zz 已经被删除, 所以事务 2 会报错:

```
pg=# begin;
BEGIN
pg=# create table zz.test2(i int);
ERROR:  schema "test" does not exist
LINE 1: create table zz.test2(i int);
```

至此诡异问题 1 算是清晰了. 那为啥会出现诡异问题 2 呢? 理论上 segment 上应该也会存在 oid=34298 的表才对啊. 再次祭出 pg_filedump, 找了个 segment 上的 pg_class 看了下, 可以看到 segment 上确实存在过 oid=34298 的表, 不过这个表所在 schema 确为 oid=0x85ee(34286), 而且该表已经被事务 xid=52450 删除了:

```
 Item  95 -- Length:  168  Offset: 16808 (0x41a8)  Flags: USED
  XMIN: 52402  CMIN: 14  XMAX: 52450  CMAX|XVAC: 14  OID: 34298
  Block Id: 7  linp Index: 95   Attributes: 30   Size: 32
  infomask: 0x0511 (HASNULL|HASOID|XMIN_COMMITTED|XMAX_COMMITTED) 
  t_bits: [0]: 0xff [1]: 0xff [2]: 0xff [3]: 0x0f 

  41a8: b2cc0000 e2cc0000 0e000000 00000700  ................
  41b8: 5f001e00 110520ff ffff0f00 fa850000  _..... .........
  41c8: 74657374 32000000 00000000 00000000  test2...........
  41d8: 00000000 00000000 00000000 00000000  ................
  41e8: 00000000 00000000 00000000 00000000  ................
  41f8: 00000000 00000000 00000000 00000000  ................
  4208: ee850000 fb850000 03600000 00000000  .........`......
  4218: fa850000 00000000 00000000 00000000  ................
  4228: 00000000 00000000 00000000 00000000  ................
  4238: 00007268 38000000 00000000 00000000  ..rh8...........
  4248: 00000000 accc0000                    ........        
```

根据代码可知, 同一个 object 在 master, segment 肯定会具有同样的 oid, 反之具有同样 oid 的 object 一定是同一个! 那为啥这里 master 上 oid=34298 表对应 schema 为 oid=34196, 而在 segment 上对应 schema 确为 oid=34286 呢?!

等等, 这个 oid=34286 schema 有点眼熟啊, 这就是事务 xid=1021142 创建的同名 schema 啊, 而且在解决诡异问题 1 时, 我们也知道执行 `DROP SCHEMA zz`, `CREATE SCHEMA zz` 事务 xid=1021142, 与执行 `CREATE TABLE zz.test2` 的事务 xid=1021147 是同时执行的. 所以目前问题就是, master 上看到 schema zz 的 oid 为 34196, 而 segment 上看到 schema zz oid 为 34286. 还是继续看代码吧, 看了下 ADB PG 中 CREATE TABLE 链路:

1.  master 上执行 create table 操作, 如往 pg_class 中追加一行等.
2. 通过 cdbdisp_dispatchUtilityStatement 将 create table 下发给 segments. 很奇怪的是这里在下发时, 针对 schema 部分, 下发的不是 schema oid, 而是 schema name, 也就是 segment 上在确定 schema oid 时仍是需要根据 schema name 查找的.

至此想出来了一种可能会触发如上诡异问题 2 的操作序列, 在事务 2 开始执行 cdbdisp_dispatchUtilityStatement, 但并未真正下发操作时, 事务 1 执行 COMMIT. 之后事务 2 下发 create table 到 segment, 之后 segment 在执行 create table 时拿到 schema oid 确实就会与 master 上不一致了! 于是通过 GDB 给 cdbdisp_dispatchUtilityStatement 来了个断点, 执行事务 1, 事务 2, 确实会复现出 master, segment 上同一个 object 处于不同 schema 的情况. 

至此诡异问题 2 算是解决了, 至于为啥 segment 上 oid=34298 表被删除了, 那应该就是用户随后又执行了 `DROP SCHEMA zz CASCADE` 了吧, 试了下此时 DROP SCHEMA 操作确实可以执行成功, 并且确实会删除 segments 上 oid=34298 的表.  
本文介绍了 mysql 中一些黑科技的介绍

## bp

buffer pool, 就是 PG 中的 shared buffer, 与 PG 一致, mysql buffer pool 分为多个 part, 从而来降低锁争用与开销. Buffer pool 结构如下所示, 与 PG 不同的是, mysql buffer pool 支持动态变大/变小.
￼
![]({{site.url}}/assets/mysql-bp.png)

## cb

Change Buffer, 见下图. Mysql 中对 secondary index 的变更链路大概是: 若待更新 index block 已经在内存中, 则直接写内存, 否则写入到 cb 中, 这样避免了在 index block 不存在时对其的 read.

![]({{site.url}}/assets/mysql-cb.png)
￼

## Compact row format
￼
变长字段长度列表，该位置用来存储所申明的变长字段中非空字段实际占有的长度列表，例如有3个非空字段，其中第一个字段长度为3，第二个字段为空，第三个字段长度为1，则将用 01 03 表示，为空字段将在下一个位置进行标记。变长字段长度不能超过 2 个字节，所以 varchar 的长度最大为 65535。 这个还不错, 与 PG 将长度编码到列本身来比, mysql 这种将长度放在行首可以某种程度随机读取了.

![]({{site.url}}/assets/mysql-compact-row-format.png)

## other

(这里放着一些仅需要一句话就能说清的技能..

Adaptive Hash Index, mysql 内部会根据查询历史来动态建立 hash index, 这个体验应该还是不错的.

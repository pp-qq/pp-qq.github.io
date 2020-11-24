---
title: "内存又泄漏了啊=。="
hidden: false
tags: ["Postgresql/Greenplum"]
---

双 11 例行巡检时忽然发现大盘上某处地方不太对劲, 两周以来, 实例计算节点所占内存一直在缓慢地上升中. 登陆到实例计算节点上 top shift+M 看了下, 两个 postgresql startup process 很诡异地占了很大的内存, 位列 top2. 要知道 startup process 只是反复 redo xlog, redo 完一条 xlog 之后, 这期间所持有内存就会释放掉, 一般常驻内存也就 M 级别, 这次这俩已经占了 10G+ 级别了. 但继续观察了好大一会, startup process 虽然一直在活跃, 但常驻内存却一直没有上升了. 至此一个猜想是: 某个 rmgr redo 逻辑有点问题, 存在内存泄漏, 但这个 rmgr xlog 行为不是很频繁, 导致内存泄漏并不是很明显. 先 gcore 生成个 corefile 看下吧.

关于内存泄漏, 本质上就是代码中有某一处逻辑一直在分配内存, 而且从来没回收. 既然泄漏源来自于某一处逻辑, 同一处逻辑对分配内存的使用一般也具有某种特定相同的 pattern, 也即意味着泄漏出的内存的内容一般也会呈现出某种 pattern. 所以内存泄漏首要任务找出泄漏内存的 pattern, 之后再根据 pattern 在源码中定位相应逻辑. 关于如何找出泄漏内存的 pattern, 可以结合着自家业务模型来整, 比如可以根据 tcmalloc 的内存分布特征, 或者 c++ 虚表这些特征来试图找出 pattern. 考虑到当前实例网络不通, 一时半会无法把 mempattern 这些工具部署上去. 索性就用手头上现有的 strings 试下, 毕竟, adbpg 中也是确实有不少字符串操作来着, 先用 strings 看下:

```
strings ${corefile} | sort | uniq -c | sort -nr > strings.txt
```

然后这一下子就碰到好运气了, 有一个字符串出现次数明显不符合预期:

```
head -n 10 strings.2.txt
84812936 base/16392
 138239 WAIT_AUDIT
 132430 2000-01-01 00:00:00
 120658 SELLER_SEND_GOODS
```

继续祭出 gdb find 下 'base/16392' 出现在何处, 如下 heapstart, heapend 为进程 heap 空间所占用的地址区间, 可以根据 `maintenance info sections` 结合着 `/proc/$pid/maps` 找下,

```
gdb ${bin} ${core} --batch -ex 'find ${heapstart},${heapend},"base/16392"' > gdb.find.txt 2>&1
```

从 gdb find 出来的结果很明显可以看到这些地址之间间隔固定 144 bytes!

```
$ tail -n 10 gdb.find.txt
0x75b39c8
0x75b3a58
0x75b3ae8
0x75b3b78
0x75b3c08
0x75b3c98
0x75b3d28
0x75b3db8
0x75b3e48
```

接下来就是随便找个地址, 看下这块地址中的内容有没有其他值得注意的 pattern 了. 另外如果这些地址是使用 pg palloc() 分配的话, palloc() 会在地址块之前前 16byte 内塞一些元信息. 幸运的是 gdb 可以看到这些地址确实是 palloc() 分配的, 并且是在 TopMemoryContext 中分配的, 并且根据 TopMemoryContext 中的 allBytesAlloc, allBytesFreed 也可以看到大概有 12G 的内存未被回收, 这与一开始 top 看到的结果也能对应着.

```
(gdb) x/288c 0x75b3a58
0x75b3a58:      98 'b'  97 'a'  115 's' 101 'e' 47 '/'  49 '1'  54 '6'  51 '3'
0x75b3a60:      57 '9'  50 '2'  0 '\000'        0 '\000'        0 '\000'        0 '\000'        0 '\000'        0 '\000'
.... 都是 0!
0x75b3ad8:      -56 '\310'      -91 '\245'      102 'f' 2 '\002'        0 '\000'        0 '\000'        0 '\000'        0 '\000'
0x75b3ae0:      -128 '\200'     0 '\000'        0 '\000'        0 '\000'        0 '\000'        0 '\000'        0 '\000'        0 '\000'
0x75b3ae8:      98 'b'  97 'a'  115 's' 101 'e' 47 '/'  49 '1'  54 '6'  51 '3'
0x75b3af0:      57 '9'  50 '2'  0 '\000'        0 '\000'        0 '\000'        0 '\000'        0 '\000'        0 '\000'
.... 都是 0!
0x75b3b68:      -56 '\310'      -91 '\245'      102 'f' 2 '\002'        0 '\000'        0 '\000'        0 '\000'        0 '\000'
0x75b3b70:      -128 '\200'     0 '\000'        0 '\000'        0 '\000'        0 '\000'        0 '\000'        0 '\000'        0 '\000'
```

```
(gdb) p *((AllocChunk)0x75b3ad8)
$2 = {sharedHeader = 0x266a5c8, size = 128}
(gdb) p *((AllocChunk)0x75b3ad8)->sharedHeader
$3 = {context = 0x2669a50, memoryAccountId = 7, balance = 12214020216, prev = 0x0, next = 0x0}
(gdb) p *((AllocChunk)0x75b3ad8)->sharedHeader->context
$4 = {type = T_AllocSetContext, methods = {alloc = 0x93b890 <AllocSetAlloc>, free_p = 0x93af10 <AllocSetFree>, realloc = 0x93b8a0 <AllocSetRealloc>,
    init = 0x93a7f0 <AllocSetInit>, reset = 0x93abd0 <AllocSetReset>, delete_context = 0x93ab30 <AllocSetDelete>,
    get_chunk_space = 0x93a800 <AllocSetGetChunkSpace>, is_empty = 0x93a810 <AllocSetIsEmpty>, stats = 0x93a820 <AllocSet_GetStats>,
    release_accounting = 0x93aa70 <AllocSetReleaseAccountingForAllAllocatedChunks>}, parent = 0x0, firstchild = 0x2698ed8, nextchild = 0x0,
  name = 0x2669b88 "TopMemoryContext", isReset = 0 '\000', allBytesAlloc = 132719041776, allBytesFreed = 120015349904, maxBytesHeld = 12703724688,
  localMinHeld = 0}
```

还有根据 strings 找到的模式, 可以看到 "base/16392" 出现了 84812936 次, 每次出现至少就是 128 + 16bytes, 大概算了一下, 12213062784bytes, 与 TopMemoryContext 中 allBytesAlloc, allBytesFreed 差值 12703691872 差不多能对应上. 所以现在泄漏源基本上确定了, 就是这 128bytes 取值为 "base/16392" 的内存块搞的鬼! 接下来就是好好想像这 128 bytes 究竟是程序中哪一块分配出来的! 128, 字符串, 对 pg 源码稍有印象的话, 基本上就可以想到 psprintf() 啊!

```c
char *
psprintf(const char *fmt,...)
{
	size_t		len = 128;		/* initial assumption about buffer size */

	for (;;)
```

继续 vscode 火力全开, 看看有谁调用过 `psprintf("base`:

```
7 results - 3 files

src/backend/utils/adt/misc.c:
  302  			if (tablespaceOid == DEFAULTTABLESPACE_OID)
  303: 				fctx->location = psprintf("base");
  304  			else

src/bin/pg_basebackup/pg_basebackup.c:
  1811  	basebkp =
  1812: 		psprintf("BASE_BACKUP LABEL '%s' %s %s %s %s %s %s",
  1813  				 escaped_label,

src/common/relpath.c:
  118  		/* The default tablespace is {datadir}/base */
  119: 		return psprintf("base/%u", dbNode);
  120  	}

  168  			if (forkNumber != MAIN_FORKNUM)
  169: 				path = psprintf("base/%u/%u_%s",
  170  								dbNode, relNode,

  172  			else
  173: 				path = psprintf("base/%u/%u",
  174  								dbNode, relNode);

  178  			if (forkNumber != MAIN_FORKNUM)
  179: 				path = psprintf("base/%u/t_%u_%s",
  180  								dbNode, relNode,

  182  			else
  183: 				path = psprintf("base/%u/t_%u",
  184  								dbNode, relNode);
```

接下来, 就是按部就班找下哪些链路调用了 GetDatabasePath(), 而且还没有 pfree 的, 不难找, 就看到了 ao_truncate_replay(). 接下里又是往社区刷个小 [PR](https://github.com/greenplum-db/gpdb/issues/11202) 的机会了~

实际上除了 ao_truncate_replay() 之外, `dbase_redo()` 目测也是有同样问题的内存泄漏, 只不过触发几率小一些, 用户需要反复 create database, drop database 才可能碰到.



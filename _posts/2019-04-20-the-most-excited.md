---
title: "天秀之路"
tags: [开发经验]
---

记录着一些有趣的事儿. 可能是亲身经历的, 也可能是八卦听说来的. 我平日最喜欢八卦围观各种 bug. 对于其中一些令人拍案惊奇的 bug 会脱敏之后放在这里.

## 千万不要相信从网页上复制来的内容

最近在主持一场对我们的[分布式 OLAP 产品 ADB](https://help.aliyun.com/product/92664.html)压测行动. 主要是验证某次 fix 对性能地提升. 在第一天对老版本的压测之后, 为了后续压测方便, 我将压测命令保存在阿里内部的工单系统 aone 上. 在第二天应用了 fix patch 之后, 直接复制了网页上保存着的压测命令开始了压测. 这次压测效果异常地好, 粗略计算来看性能提升了至少 50 倍. 大家都是非常的开心. 但是,

我日常打开了 grafana 查看在压测过程中各种指标信息, 震惊地发现数据库连接数在压测期间只有 1 个! 一种不祥地预感涌上心头, 按理来说数据库连接数至少要不小于在压测时指定的并发数才对! 再给压测程序加了一些 log, 经历了无数次尝试之后震惊地发现了如下事实:

![]({{site.url}}/assets/javajar.jpg)

看起来完全相同的命令行却导致了完全相反的输出. 加上 od 之后, 才发现一些幺蛾子:

![]({{site.url}}/assets/odjavajar.png)

由于多余的两个字符导致 `-r` 选项被认定是不存在的, 所以走了默认值 1 了.

## 我曾经将程序性能优化了至少 3000 倍

还是在我们的[分布式 OLAP 产品 ADB](https://help.aliyun.com/product/92664.html)中, 较为常见的用户案例是与 [阿里云 RDS](https://www.aliyun.com/product/rds/mysql), [阿里云 DTS](https://www.aliyun.com/product/dts) 搭配在一起使用, 具体就是 rds 用作 oltp 库, adb 用作 olap 库, dts 负责将 rds 的 dml 操作同步到 adb 中. 为了提升同步效率, dts 引入了启发式 dml 聚合算法. 就是将多条基于主键删除的 DELETE 语句通过 OR 运算符聚合形成一条 DELETE 语句. 如将 `DELETE FROM table WHERE primarykey = val1`, `DELETE FROM table WHERE primarykey = val2` 聚合成 `DELETE FROM table WHERE primarykey = val1 OR primarykey = val2`. 极端情况下 OR 运算符数量会在 100 个左右. 然后 ADB 的 DELETE 链路用了非常朴素的操作, 就是中规中矩地查找, 然后再一一删除. 在此场景大量 OR 运算符下, 查询堆栈会非常地深, 直接导致查询执行很久甚至无法正常完成.

我当时所做对此的优化就是将 DELETE WHERE 条件按照 OR 进行拆分, 将 OR 运算数存放在 orOps. 如下:

```java
// 按照深度优先遍历 cond. 生成结果与 cond 具有相同的结合性以及优先级.
private static LinkedList<Expr> splitOR(Expr root) {
    LinkedList<Expr> ret = new LinkedList<>();
    // 之所以不用 ArrayDeque, 是因为不能塞 null 值.
    ArrayList<Expr> stack = new ArrayList<>(16);
    push(stack, root);
    while (!stack.isEmpty()) {
        Expr exp = pop(stack);
        if (!(exp instanceof ExprAndOr)) {
            ret.add(exp);
            continue;
        }
        ExprAndOr expOr = (ExprAndOr)exp;
        if (expOr.getAndOrType() != ExprAndOr.OR) {
            ret.add(exp);
            continue;
        }
        push(stack, expOr.getRight());
        push(stack, expOr.getLeft());
    }
    return ret;
}
```

然后遍历 orOps, 对于每一个 OR 操作数, 如果其是一个基于主键的删除, 则直接删除该行. 最后对于 orOps 中剩下的, 无法基于主键的删除, 再使用 OR join 生成一个表达式, 走普通的查询引擎进行普通的删除.

此番操作直接将 DTS 发来的 DELETE 语句执行时间从 138s 提升到 40ms 左右.

![]({{site.url}}/assets/deleteor64noop.png)
![]({{site.url}}/assets/deleteor64op.jpg)

## Hadoop ChecksumFileSystem 天秀的 setPermission 姿势

Hadoop ChecksumFileSystem::setPermission, 经过一堆调用链之后最终会通过启动个 chmod 进程来为新建文件设置权限. 这直接导致我们线上 CPU 利用率飙满. 具体来说, 就是我们的[分布式 OLAP 产品 ADB](https://help.aliyun.com/product/92664.html)采用了存储计算分离架构, 其数据是放在阿里自研的分布式文件系统盘古上. ADB 中通过 org.apache.hadoop.fs SDK 来访问存储于盘古上的数据. 具体来说, ADB 将会通过 org.apache.hadoop.fs.FileSystem#copyToLocalFile() 来下载文件到本地, 然后 hadoop fs 将使用 org.apache.hadoop.fs.LocalFileSystem 来访问位于本地磁盘上的文件数据. 然后 LocalFileSystem::create() 实现如下:

```java
@Override
public FSDataOutputStream create(Path f, FsPermission permission,
    boolean overwrite, int bufferSize, short replication, long blockSize,
    Progressable progress) throws IOException {
  Path parent = f.getParent();
  if (parent != null && !mkdirs(parent)) {
    throw new IOException("Mkdirs failed to create " + parent);
  }
  final FSDataOutputStream out = new FSDataOutputStream(
      new ChecksumFSOutputSummer(this, f, overwrite, bufferSize, replication,
          blockSize, progress), null);
  if (permission != null) {
    setPermission(f, permission);
  }
  return out;
}
```

而上面 setPermission() 函数经过一堆调用链之后会调用到 org.apache.hadoop.fs.RawLocalFileSystem::setPermission(), 该函数实现如下:

```java
@Override
public void setPermission(Path p, FsPermission permission
    ) throws IOException {
  execCommand(pathToFile(p), Shell.SET_PERMISSION_COMMAND,
      String.format("%04o", permission.toShort()));
}
```

也就是每次 LocalFileSystem::create 都可能会启动一个 chmod 进程.

在 ADB 中, 当用户数据库的规模非常大时, 在某一时刻可能会并行地从盘古上下载很多文件到本地, 由于之前的 LocalFileSystem::create 都会启动一个 chmod 进程. 这直接导致了我们 CPU 开始飙满. 如下图:

![]({{site.url}}/assets/fullcpu.jpg)

jstack 可以看到线程堆栈为:

![]({{site.url}}/assets/hadoopfsstack.jpg})

在修复之后, 在同样的场景下, cpu 利用率如下图:

![]({{site.url}}/assets/cpuafterfix.png)


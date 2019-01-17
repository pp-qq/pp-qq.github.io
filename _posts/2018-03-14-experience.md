---
title: 开发经验
tags: [开发经验]
---

## zk acl

首先介绍一些概念. id, 字符串类型, 在 zk 中用来唯一标识一个个体, 即 zk service 会将 id 相同的两个连接认为是同一个个体发来的, 她们具有一样的权限. ZooKeeper supports pluggable authentication schemes. Ids are specified using the form scheme:id, where scheme is a the authentication scheme that the id corresponds to. 即 zk 将 id 的生成, 比较等操作全部交给 schema 标识的插件来执行. 在用户创建一个连接到 zk service 之后, 可以通过 `addauth schema authdata` 来添加 id 信息, 此时 zk service 会把 authdata 交给 schema 标识的插件. 若插件验证没毛病, 则生成 id 并绑定到当前连接上. 若插件验证 authdata 姿势不对, 则当前 zk session 很快会进入 auth failed 状态不再可用.

acl, 形式为 (id, perms), 表明着 id 标识的实体具有的权限为 perms. 如果 unix 权限模块的 `rwx` 一样, 这里 perms 是 `rdcwa`, 每个字母表示的权限意义参见原文. 对于一个特定的 znode 而言, 其关联的 acl 信息会以 acl 数组形式记录. 若 id 不再该数组中, 则表明 id 标识的实体对该 znode 没有任何权限. 反之若 id 在数组中能找到一项与之对应的 acl 项, 则按照该项中的 perms 字段来判断 id 标识的实体具有的权限. 按我理解对于一个 zk session 而言, 其对于一个特定的 znode 节点具有的权限应该是该 zk session 所有关联的 id 在 znode 上具有的权限并集.

在修改 znode 具有的 acl 时, 除了可以按照 schema 的规则硬编码 authdata 之外; 还可以通过 `auth` 这个特殊 schema 来设置, 如原文所说 auth doesn't use any id, 表示着当前 zk session 已经关联的所有 id. 在举例说明之前首先看下 digest schema authdata 编码规则, 用 python 描述如下:

```py
def digest(authdata):
    parts = authdata.split(b':')
    return parts[0] + b':' + base64.b64encode(hashlib.sha1(authdata).digest())
```

所以:

```
[zk: localhost:2181(CONNECTED) 7] setAcl /hidva digest:blog:uo7MDEe6ih83BFRte9n0eQImqeU=:ra
```

与

```sh
# digest(b'blog:hidva.com') 将返回 'blog:uo7MDEe6ih83BFRte9n0eQImqeU='.
[zk: localhost:2181(CONNECTED) 0] addauth digest blog:hidva.com
[zk: localhost:2181(CONNECTED) 0] setAcl /hidva auth::ra
```

是等价的.


参考: [ZooKeeper access control using ACLs](http://zookeeper.apache.org/doc/r3.4.13/zookeeperProgrammers.html#sc_ZooKeeperAccessControl)

## zk 数据回退

这里只是记录了我们在以某种方式操作 zk 集群时观察到的数据版本回退的情况, 具体为何会发生回退待今后有空时再进行深究. 事件的背景是, 我们现在有一台由 5 个 zk server 组成的 zk service, 现在需要为其再增加 5 台 zk server 组成一个有 10 台 zk server 的 zk service, 为何会执行这么个操作的背景这里咱就不深究了. 然后发现在执行这么个操作之后, zk 上的数据发生了回退. 而且现象是可复现的. 

## zk unimplemented 报错

实践发现, 在 zk observer proxy 机器上写操作会提示未实现错误. 怎么不会转发呢?!

## sed, awk 学习

参考资料: [sed](http://www.gnu.org/software/sed/manual/sed.html#Execution-Cycle), [awk](https://awk.readthedocs.io/en/latest/).

关于对 sed, awk 的学习, 应该首先了解 sed, awk 的工作流程, 然后再根据具体需求学习详细章节. 以 sed 为例, 其大致工作流程就是按行遍历输入, 将每行交给用户提供的命令, 输出执行命令后的结果. 以 awk 为例, 与 sed 相似 awk 也是按行遍历, 只不过 awk 在提取一行之后, 会按照特定的分隔符将行分割为列数组, 特定的分隔符默认是空白字符, 可以通过 `-F` 指定其他字符, awk 会将列数组分别赋值给特定变量 `$1` 等, 然后执行用户提供命令. 话说回来 sed, awk 的作者们怎么对文本分析需求揣摩地那么透彻!!!

## iostat

常用使用命令 'iostat -x -d 磁盘设备或者分区 1'. 实践表明 iostat 用在磁盘分区, 比如 sdc1, sdd1 上时并不是很准确, 所以一般是用在整块磁盘上, 比如 sdc, sdd.

iostat 结果中字段的意思 google 了解一下即可.

## 磁盘与分区

之前学习 linux 基础以及 extX 文件系统时了解过 `/dev/sda` 是指整块磁盘, `/dev/sda1` 是指 sda 磁盘上一个分区; 不过还是在入了分布式存储领域之后才扎扎实实感受到这些概念. 另外一般情况下在分布式存储系统节点上, 用作数据存储的磁盘一般只会有一个分区, 毕竟同一磁盘上所有分区会共享某些资源, 并不能实现并行效果.

## curl 与 100 continue

(HTTP)  Maximum  time  in  seconds  that  you  allow curl to wait for a 100-continue response when curl emits an Expects: 100-continue header in its request. By default curl will wait one second. This option accepts decimal values! When curl stops waiting, it will continue as if the response  has been received.

一般情况下, server 都能正确响应 "Expect: 100-continue", 但包不及某些用户自定义的 http server 不完全遵守 http 语义啊. 比如就像我遇到的强势找过来的用户质问为什么我们的分布式消息队列系统 Bigpipe 在收到消息之后要 1 秒后才能推送到他们的 server 上! 能找到是因为他们的 server 未正确响应 "Expect: 100-continue" 也是靠各种机缘才确定的啊!

## undefined macro AC_MSG_NOTICE

如下, 编译 facebook/folly 提示错误; 本质原因是 aclocal 未加载 pkg.m4 导致; 执行 `find / -type f -name 'pkg.m4'` 找到 pkg.m4 路径之后, 将其 cp 到 `aclocal --print-ac-dir` 中即可解决. 如果 find 未找到 pkg.m4, 则表明系统未安装 pkg-config, 此时需要安装 pkg-config; 此时可以尝试再次编译来判断是否需要 cp pkg.m4, 毕竟一般情况下, 安装 pkg-config 时会自动完成这一步; 当然如果系统中存在多份 aclocal, 并且 pkg-config 自动拷贝时使用的 aclocal 与编译 folly 时使用的 aclocal 不一致的话, 仍然需要手动 cp;

```sh
configure.ac:131: warning: PKG_PROG_PKG_CONFIG is m4_require'd but not m4_defun'd
m4/fb_check_pkg_config.m4:1: FB_CHECK_PKG_CONFIG is expanded from...
configure.ac:131: the top level
configure.ac:145: warning: PKG_PROG_PKG_CONFIG is m4_require'd but not m4_defun'd
m4/fb_check_pkg_config.m4:1: FB_CHECK_PKG_CONFIG is expanded from...
configure.ac:145: the top level
configure.ac:172: warning: PKG_PROG_PKG_CONFIG is m4_require'd but not m4_defun'd
m4/fb_check_pkg_config.m4:1: FB_CHECK_PKG_CONFIG is expanded from...
configure.ac:172: the top level
configure:16567: error: possibly undefined macro: AC_MSG_NOTICE
      If this token and others are legitimate, please use m4_pattern_allow.
      See the Autoconf documentation.
autoreconf: /opt/compiler/gcc-4.8.2/bin/autoconf failed with exit status: 1
```

## 语言风格

对于一种编程语言的语言风格, 如命名习惯等, 首先以业界已有的规范为准, 比如 golang 语言风格就以 gofmt 为准, c++ 语言风格就以 google c++ 为准. 这里记录一些未被大佬们归纳的风格问题做法.

### C++ 中的空行

google c++ 规范中并未严格限定空行规范, 只是建议尽量减少空白行; 这里结合其他语言中的规范总结如下.

何时空行, 我认为空行用来分割不同实体, 即用来分割类的定义, 函数的定义等; 在函数实现中, 使用空行来分割不同逻辑块. 逻辑块的划分标准是每一个逻辑块都可以用一个函数来实现替代.

空行的数目, 按照 python pep8 的规范, 同属于同一个实体下的内容使用 1 行分割, 不同实体之间使用 2 行分割; 这里实体是指函数, 类等. 如:

```py
# i = 1, j = 2 同属于同一个实体 f, 所以使用 1 行分割.
# f(), g() 同属于同一个实体 I, 所以也使用 1 行分割.
# I, J 不同实体, 所以 2 行分割.

class I(object):

    def f():
        i = 1  # 1

        j = 2  # 2

        return

    def g():
        return


class J(object):
    pass
```

## 启发式究竟是什么意思?


我一直不太懂 "启发式" 是啥意思?! 比如说算法导论中在介绍不相交集合时引入的 "加权合并启发式策略" 等等.

最近在学习 vivaldi algorithm 中感觉对 "启发式" 有点了解了; 按我理解带有启发式字样的算法随着时间的推移其运行效果将会越好; 就像 vivaldi 算法随着时间推移每个节点掌握的网络拓扑就越精准, 效果就越好.


## 要使用 HTTP Cache-Control


注意使用 HTTP Cache-Control 首部来控制 http 行为, 不然可能会有预料之外的效果; 比如 chrome 就可能会直接 from disk cache 而不会发送请求!


## 代码风格: 简洁高效赏心悦目


要时刻明确与坚持自己的代码风格.

## 层次化也是模块化


之前认为所有的架构设计都可以归纳为模块化, 层次化; 现在意识到层次化中的层次也是模块的一种, 底层向高层呈现的接口也就是底层标识模块的接口. 所以层次化也是模块化.

即所有的架构设计都可以归纳为模块化, 模块之间通过明确的接口语义通信, 在使用模块提供的接口时无需了解模块的实现细节.

## 注意 fdatasync 的写放大

fdatasync 每次刷盘是以 pagesize 为最小单位进行(可能是 4 KB), 那么在进行一些小数据的写入的时候, 每次刷盘都会放大为 4 KB, 从而使得 IO 出现瓶颈.

## 磁盘分区要对齐 pagesize

在对磁盘进行分区的时候, 如果不进行pagesize的对齐, 会导致fdatasync的性能大幅下降, 所以要先检查磁盘分区是否已进行pagesize对齐.

## 记住那些闪光点

应该在博客中记录下自己平时遇到过的经典 BUG; 以及开发中一些闪光点, 比如之前的 mysql JSON 调优, storm PIPEQ 调优等. 一方面这个东西今后用作回顾也算不错. 另一方面在面试时可能会被问过遇到的最经典的 bug.


## 安全编码意识很重要

曾经我以为那些远程溢出漏洞都是一些很愚蠢的程序猿写出来的. 现在我倒是觉得溢出真是防不胜防啊! 如下代码, 摘自[rocksdb.gb 中 block.go](https://github.com/pp-qq/rocksdb.go/blob/master/rockstable/block.go):

```go
k_end := offset + unshared
if unshared <= 0 {
	k = anchor[:shared]
} else if shared <= 0 {
	k = this.data[offset:k_end]
}
```

如果 go 在 index expression 时未进行下标范围检测, 那么由于溢出的存在, `k_end` 可能是个负值, 导致在 `this.data[offset:k_end]` 时会访问到非法内存.


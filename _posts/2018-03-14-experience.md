---
title: 开发经验
tags: [开发经验]
---

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


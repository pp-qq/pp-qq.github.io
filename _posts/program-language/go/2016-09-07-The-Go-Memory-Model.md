---
title: "The Go Memory Model"
hidden: false
tags: [Go, 读后感]
---


## Introduction

略

## Advice

当数据被多个 goroutines 同时 accesse(存取) 时, 这些 access must serialize.

To serialize access, protect the data with synchronization primitives(同步原语),
such as channel operations, those in the `sync` and `sync/atomic` packages.

## Happens Before

1.  不同 goroutine 观测到的 execution order 可能不同, 其实, 一直不是很理解这里的
    "观测" 究竟是个啥意思, 然后发现原文举了个栗子, 还挺形象的.

介绍了若干概念. 与 C++11 的 spec 相比, 这里介绍的概念真是太少了. 如下

2.  happens before, happen after, happen concurrently; 关于这仨概念, 具体参考原文.

    Within a single goroutine, the happens-before order is the order expressed by the program.
    也就是讲, single goroutine 中所有 memory operations 之间的 happens-before order 就是代码里面
    指定的顺序; 即若在代码里面, memory operation A 在 memory operation B 之前, 则 A happens before B.

    The initialization of variable `v` with the zero value for `v`'s type behaves as a write in
    the memory model.

    Reads and writes of values larger than a single machine word behave as multiple machine-word-sized
    operations in an unspecified order. 这里 multiple machine-word-sized operations 理解为:
    多个 machine-word-sized operation, 每一个 operation 作用在一个机器字上.

3.  allowed to observe, 对于 variable `v` 上一个 read operation `r` 来说, 其 allowed to observe
    的 write operation 其实是一个集合, 并且对于集合中每一个 write operation `w` 来说, 都满足指定的
    条件, 这里具体的条件参考原文.

4.  To guarantee that a read op `r` of a variable `v` observes a particular(指定的) write op `w` to `v`,
    需要达成的条件参见原文. 此时也可以从原文的条件中推断出: `w` is the only write `r` is allowed to observe.

5.  结论: Within a single goroutine, there is no concurrency, so the two definitions are equivalent: a read
    `r` observes the value written by the most recent write `w` to `v`. When multiple goroutines access a
    shared variable `v`, they must use synchronization events to establish happens-before conditions that
    ensure reads observe the desired writes.


## Synchronization

接下来指定了若干条条例, 这些条例满足 happens before 的情况.

### Initialization

1.  参见 [Package initialization][1]与原文, 这里用 happens before 这个概念重新定义了一下.

### Goroutine creation

1.  The [go statement][2] that starts a new goroutine happens before the goroutine's execution begins.

    这个条例也就解释了当使用 `pthread_create()` 创建线程时, 当前线程对某个变量的修改对新线程是否可见
    这个问题. 实际上, 据我了解的并没有 C 语言标准中并未指定修改对新线程是否可见.

### Goroutine destruction

1.  The exit of a goroutine is not guaranteed to happen before any event in the program.

### Channel communication

1.  参见原文, 了解 4 个条例就行.

### Locks

1.  参见原文, 了解 2 个条例就行.

    总结来说的话, 就是若某次 unlock()(可能是 RUnlock() 或者 Unkock()) 操作导致了 lock()(可能是 Lock(),
    或者 RLock()) 操作返回, 则这个 unlock() 操作 happens before 这次 lock() 操作.

### Once

1.  A single call of `f()` from `once.Do(f)` happens (returns) before any call of `once.Do(f)` returns.

## Incorrect synchronization

略

## 参考

1.  [The Go Memory Model 1.7][0]



[0]: <https://golang.org/ref/mem>
[1]: <{{site.url}}/2016/08/30/go-spec/#package-initialization>
[2]: <{{site.url}}/2016/08/30/go-spec/#go-statements>



---
title: "从 C++20 标准来看 memory order: 1"
hidden: false
tags: [C++]
---

接 [从 C++20 标准来看 memory order:0]({{site.url}}/2020/09/15/cpp20-memory-order-0/)

在 c++20 标准中, 与 memory order 有关的章节主要集中在 6.9.1 Sequential execution, 6.9.2 Multi-threaded executions and data races, 31.4 Order and consistency 中. 要想精确掌握 memory order, 对这些内容的硬啃是避免不了的. 所以我这里不会再试图复述标准中的内容. 而是归纳总结了常用 memory order 的语义. 并提供了一些例子, 再结合标准中的条款来论证为啥例子中的行为会是这样. 最后再零零散散记录了对标准中一些难以理解的部分的理解.

很明显可以看到标准中总共定义了 relaxed, consume, acquire, release, acq_rel, seq_cst 6 个 memory order. 其中 consume 目测要被废弃了. 简单来说 consume 可以视为是 acquire 的子集, 具有比 acquire 更弱的 order 要求. 也就是说在可能的情况下, 使用 consume 比 acquire 负担会更少. c++11 一开始提出 consume, 是想着给予实现充分的自由, 以及更大的性能发挥空间. 但从实际情况上看, 如同 c++20 标准所说, consume 还是挺鸡肋的, 所以目前大佬中准备从标准中移除 consume. 这里不再介绍 consume 相关的语义. 剩余几种 memory order 可以与标准库提供的 atomic operations 结合在一起使用, 使得这些操作除了能原子执行之外, 还自带同步的特效. 如文章一开始举例所示, atomic_store(&ready, true), atomic_read() 只是纯粹的原子操作, 并没有同步的语义. 因此 thread B 看到 ready=true, 并不意味能看到 obj 初始化之后的结果. 而参照 c++ memory order 语义在执行原子操作的同时加上 memory order 的要求, 便使得原子操作同时也带有了同步的光环, 可以确保 thread B 在看到 ready=true 的同时, obj 初始化之后的结果对 thread B 也一定可见. 从 c++ 标准库文档中可以看到, c++ 所有原子操作都同时带有 order 参数, 开发者可以通过 order 指定正确的 memory order 使得原子操作同时也具有同步的语义. 下面会介绍如何正确地指定 memory order 参数.

## relaxed

relaxed! 指定了 relaxed 的原子操作其实并不是个 synchronization operations, 并不具有同步的光环. 当开发者使用 relaxed 时, 意味着开发者只是想执行一个纯粹的原子操作, 对 memory order 没有任何要求. 原子操作意味着对于外界来说, 要么看到操作执行前的状态, 要么看到操作执行结束的状态, 并不会看到操作执行过程中的中间状态. 举个不恰当的例子, 在 armv7 上, 执行 `f_s = 0x3333333333`, 这里 f_s 是 uint64_t 的全局变量, 会分为两条指令执行, 一条负责前 32bit 的写入, 另一条负责后 32bit 的写入. 也即对于其他线程, 是可能看到 f_s 取值为 0x33333333 这一中间状态的. 但如果使用了原子操作, 则不会有这种问题. 可以在 godbolt 上看下 f_s = 0x3333333333 原子/非原子执行时对应的汇编.

relaxed, 一般使用场景, 是用在计数器场景中. 比如 llvm libstdc++ 中对于 shared_ptr 的实现, 在自增引用计数的时候使用的就是 relaxed:

```c++
template <class _Tp>
inline _LIBCPP_INLINE_VISIBILITY _Tp
__libcpp_atomic_refcount_increment(_Tp& __t) _NOEXCEPT
{
#if defined(_LIBCPP_HAS_BUILTIN_ATOMIC_SUPPORT) && !defined(_LIBCPP_HAS_NO_THREADS)
    return __atomic_add_fetch(&__t, 1, __ATOMIC_RELAXED);
#else
    return __t += 1;
#endif
}
```

我之前有个疑惑就是, thread A, B 同时执行 fetch_add(relaxed) 这类 read-modify-write 操作时, 会不会看到的是同一个初始值? 也即会不会 A 执行 fetch_add() 后的结果对 B 尚不可见. 这点标准中已经有了解答, 可以理解为 read-modify-write 操作看到的总是最新值! 

>   Atomic read-modify-write operations shall always read the last value (in the modification order) written before the write associated with the read-modify-write operation.

另一个疑惑是, thread A atomic_store(any memory order) 的 side effects 对 thread B 是否立即可见? 也即 thread B 执行 atomic_read(any memory order) 是否能立即看到 A 写入值. 或者举个例子:

```c++
std::atomic_bool stop(false);

// thread A
stop.store(true, std::memory_order_relaxed);

// thread B
while (!stop.load(std::memory_order_relaxed)) ;
```

thread B 是否可能会一直看不到 thread A 写入到 stop 中的值, 而一直死循环? 标准也有了解答. 即 thread A 对 stop 的写入对 B 并不会立刻可见, 但会确保在一段时间之后可见.

>   An implementation should ensure that the last value (in modification order) assigned by an atomic or synchronization operation will become visible to all other threads in a finite period of time.
>   
>   Implementations should make atomic stores visible to atomic loads within a reasonable amount of time.

## acquire, release, acq_rel

acquire, release, acq_rel, 这仨 memory order 只是指定了原子操作同时也是个 acquire operation 或者是个 release operation. 标准通过指定了 acquire operation, release operation 的行为使得原子操作具有了同步的语义. 在这种场景下, 对于原子读操作, 合法的 memory order 只有 acquire, 此时表明原子读操作同时也是个 acquire operation. 对于原子写操作, 合法的 memory order 只有 release, 此时意味着原子写操作同时也是个 release operation. 对于原子 read-modify-write 操作, 倒是可以指定为这仨中任一个; 当指定了 acquire, 意味着 read-modify-write 只是个 acquire operation; 当指定了 release, 意味着 read-modify-write 只是个 release operation; 当指定了 acq_rel, 意味着 read-modify-write 先是个 acquire operation, 再是个 release operation. 

简单来说, 若 A 是个 atomic release operation, B 是个 atomic acquire operation, 并且 B 读取到了 A 写入的值, 那么 A synchronizes with B. A synchronizes with B 也就意味着 A happens before B. A happens before B 意味着所有先于 A 发生的各种 side effects, 比如值修改, 对 B 都是可见的. 如下所示:

```c++
int i = 0;
std::atomic<bool> ready {false};

// thread A
i = 20181218;  // 1
ready.store(true, release);  // 2

// thread B
while (!ready.load(acquire)) ;  // 3
assert(i = 20181218);  // 4
```

thread B 中的 assert 一定成立, 因为当其上循环返回时, 意味着 B 读取到了 A 写入的值, 意味着 A store happens before B load, 所以 B 将能看到所有 A 之前发生的 side effects. 如下会根据标准的规则来简单论证一下. 根据 sequenced before 的规则 6.9.1.9, 可以知道 1 is sequenced before 2, 3 is sequenced before 4. 同样我们也知道了 2 happens before 3, 根据规则 intro.races-9, intro.races-10. 也即 1 happens before 2 happens before 3 happens before 4. 1 happens before 4 意味着 1 的 visible side effect 对 4 是可见的, 根据规则 intro.races-13.

精确来说, 对于 A, atomic release operation; B, atomic acquire operation; 只要 B takes its value from any side effect in the release sequence headed by A, 那么 A 就 synchronizes with B. release sequence 的定义见 intro.races-5. 继续以之前的 PopulateQueue, ConsumeQueueItems 为例. 在线程 b, c 中, 在 ConsumeQueueItems 执行到 Process() 时. 比如 c 执行到 Process(), 那么意味着 c 此时看到的 count 一定是由 a PopulateQueue() release operation 起始写入, 中间可能经过了 b, c 中的多次 fetch_sub 更改之后的值. 由 a 起始 release operation 写入, 中间 b, c 多次 read-modify-write 更改就组成了一个 release sequence. 也就是说 c takes its value from any side effect in the release sequence headed by release operation in a. 也即意味着 `#1` synchronizes with `#2`, 也即意味着 `#0` 中对 queue_data 状态的更改对 `#4` 可见! 

## seq_cst

对于原子读操作, 当指定了 seq_cst order 时, 意味着当前读操作是一个 acquire operation. 原子写操作指定了 seq_cst, 意味着写操作是一个 release operation. 原子 read-modify-write 操作指定了 seq_cst 意味着先是一个 acquire operation, 再是一个 release operation. 因此指定了 seq_cst order, 仍继续遵循如上定义的 acquire operation, release operation 对应的同步语义.

但除了 acquire operation, release operation 之外, seq_cst 还自有其自己的特殊性, There is a single total order S on all memory_­order​::​seq_­cst operations, including fences. 简单来说, 就是程序中所有 seq_cst order 的 atomic operations, fences 都可以认为是在一个线程中串行发生的. 举个例子, 运行在 cpu0 上的线程 A 中的 atomic_obj1.store(1, release), 运行在 cpu1 上的线程 B 中的 atomic_obj2.store(2, release) 是可能并行执行的. 但如果这里把 release 换成了 seq_cst, 所以 store 一定只能是串行执行的. postgresql 在介绍事务隔离级别的时候, 举了一个很巧妙的例子演示了 Repeatable Read 与 Serializable 的不同, 以及 Serializable 存在的必要性. 在看到这个例子之前, 我一直意味 Serializable 等同于 Repeatable Read, 没啥存在必要. 我这里也想举一个很巧妙的例子来演示下 seq_cst 与 acquire, release 的区别, 以及 seq_cst 存在的必要性. 但我没有~~懒地~~想到. 自己 google 吧, 比如[这篇文章](http://cbloomrants.blogspot.com/2011/07/07-10-11-mystery-do-you-ever-need-total.html).


## 后记

哈哈, 写完啦~

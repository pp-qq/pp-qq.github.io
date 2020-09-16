---
title: "从 C++20 标准来看 memory order: 0"
hidden: false
tags: [C++]
---

早在 2016 年, 我就想熟练掌握 memory order. 当时还想着 c++ memory order 这么重要的概念, 一定对其有着最精确, 不能有丝毫歧义的理解. 所以就想着从 c++ 标准文档这个第一手资料入手学习. 悲剧的是当时就怎么都读不懂, 就是每一个字都认识, 合在一起就不知啥意思这种地步. 于是不得不匆匆收尾, 留下了 [C++11-原子操作]({{site.url}}/2016/03/11/%E5%8E%9F%E5%AD%90%E6%93%8D%E4%BD%9C/) 这么个虎头虎脑的总结. 现在 c++20 标准也已经板上钉钉了, 对 c++ memory order 的执念又开始慢慢涌了上来. 所幸 c++20 除了额外地增加了很多特性之外, 也大幅改善了标准文档的可读性, 也让我借此机会一了夙愿, 总算实现了对 c++ memory order 的熟练掌握.

## memory order 是什么?

所以首要的问题是 memory order 是什么? 以及为啥 c++ 要引入 memory order? 首先来看一个场景: 现在有线程 A, B; A 作为生产者, 其会负责某个对象 obj 的初始化工作, 在完成初始化之后, 设置 flag ready 告诉消费者 B, 对象准备就绪, 可以使用了. 用 mutex 实现如下:

```c++
struct Object {
    int a;
};
Object obj;
bool ready = false;        
```

<table>
<tbody>
<tr>
<td>
<pre>
// thread A
void ThreadA() {
    mutex.Lock();
    DoInit(&obj);
    ready = true;
    mutex.Unlock();
}
</pre>
</td>
<td>
<pre>
// thread B
void ThreadB() {
    while (true) {
        bool r = false;
        mutex.Lock();
        r = ready;
        mutex.Unlock();
        if (r) break;
    }
    Use(obj.a);
}
</pre>
</td>
</tr>
</tbody>
</table>

可以很明显地看出这种实现的缺陷, 太费时了. 所以大佬们想出了另外一种方案:

<table>
<tbody>
<tr>
<td>
<pre>
// thread A
void ThreadA() {
    DoInit(&obj);
    atomic_store(&ready, true);
}
</pre>
</td>
<td>
<pre>
// thread B
void ThreadB() {
    while (!atomic_load(&ready))
        ;
    Use(obj.a);
}
</pre>
</td>
</tr>
</tbody>
</table>

但这种方案有一个问题, 不同的硬件平台具有不同的内存模型. 也就是在 thread B 看到 ready=true 时, 并不意味着 obj 已经完成了初始化, 或者说并不意味着 DoInit(&obj) 对 obj 的更改对 thread B 可见. 完全可能出现一种情况, thread A DoInit(&obj) 对 obj 所做的所有改动仍缓存在 thread A 所在 CPU0 store buffer 中, 对运行在 CPU3 上的 thread B 完全不可见. 这点背景知识可参考 [我们都应该了解的 memory barrier 以及背后细节]({{site.url}}/2018/12/05/whymb/). 大佬们需要在 atomic_store, atomic_read 之外根据硬件平台各自的要求加入额外的 fetch/barrier 操作使得如上模型正确性成立. 很显然这是个很大成本的操作, 需要对各个硬件平台的内存模型有着精确的了解. 最近随着国产化的流行, 大量的代码从 x86-64 平台迁移到 arm, 我们也遇到过不少由于不了解 arm 平台内存模型, 未正确加入相应 fence/barrier 指令而导致的各种各样的坑. 这么坑往往与高并发有关, 而且很难复现与排查!

因此 c++11 在引入多线程的同时引入了自己的 c++ memory order 模型, 开发者只需要按照 c++ memory order 语义, 在使用原子操作/fence 时指定相应的 memory order. 编译器会负责根据各个平台的要求翻译为正确的指令集合. 在 c++11 引入了 memory order 之后, llvm 也基于此定义了 llvm memory order, 我们可以不严谨地认为 llvm memory order 等同于 c++ memory order. 同样, 基于 llvm 构建的 rust 对应的 rust memory order 我们也可以认为与 c++11 memory order 一致.

## 真没必要掌握!

但老实说, c++ memory order 到真没有必要掌握了解. 大不了直接用 mutex 嘛, 再不济总是使用 memory_order::seq_cst 嘛. 就像 golang 一样, 从 [The Go Memory Model]({{site.url}}/2017/10/18/go-c-atomic/) 可以看到, golang 是非常不鼓励使用基于原子操作来实现同步的:

> Programs that modify data being simultaneously accessed by multiple goroutines must serialize such access.
>
> To serialize access, protect the data with channel operations or other synchronization primitives such as those in the sync and sync/atomic packages.
>
> If you must read the rest of this document to understand the behavior of your program, you are being too clever.
>
> Don't be clever.

## 虽然是有丁点好处~

虽然说对 c++ memory order 的精确掌握可以让我们写出正确且**极致**高效的代码. 举个例子:

```c++
void PopulateQueue()
{
    unsigned constexpr kNumOfItems = 20;
    for (unsigned i = 0; i<kNumOfItems; ++i) queue_data.push_back(i);  // 0
    count.store(kNumOfItems, std::memory_order_seq_cst);  // #1 
}

void ConsumeQueueItems()
{
    while (true) {
        int item_index;
        if ((item_index = count.fetch_sub(1, std::memory_order_seq_cst)) <= 0) continue;  // #2 
        Process(queue_data[item_index - 1]);  // 3
    }
}

int main()
{
    std::thread a(PopulateQueue);
    std::thread b(ConsumeQueueItems);
    std::thread c(ConsumeQueueItems);
    a.join();
    b.join();
    c.join();
    return global;
}
```

这里 `#1`, `#2` 处的 memory_order 参数取 `(seq_cst, seq_cst)`, `(release, acq_rel)`, `(release, acquire)` 都不影响程序的正确性. 但在 arm 这种只弱一致性内存模型平台上的编译结果来看, `(release, acq_rel)` 将比 `(seq_cst, seq_cst)` 少一条 dmb, Data Memory Barrier 指令. 而 `(release, acquire)` 又进一步比 `(release, acq_rel)` 再少一条 dmb 指令. 就算是 x86-64 这种提供了强一致性内存模型的平台, 使用 `(release, acq_rel)` 也能比 `(seq_cst, seq_cst)` 少一条 xchg 指令, 要知道 xchg 可是自带隐式 LOCK 语言的啊, ~~这得多影响性能啊!(夸张)~~. 

接 [从 C++20 标准来看 memory order:1]({{site.url}}/2020/09/15/cpp20-memory-order-1/)

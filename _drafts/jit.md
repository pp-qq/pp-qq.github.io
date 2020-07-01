## jit 与 tcmalloc

tcmalloc 的 HeapProfile 采用 HashMap 的数据结构来保存内存分配的调用栈。
其 hash 计算逻辑比较有意思:

-   得到调用栈的信息，根据callstack各个frame 的指令地址，来生成一个 hash
-   只要callstack 有一个 frame 的指令地址变化了，那整个callstack就会对应一个新的hash，也就会重新保存一份
-   保存的是callstack 各个frame 的指令地址

这意味着只要堆栈稍一变化, tcmalloc HeapProfile 便需要重新分配一个新的 entry. 在 JIT 这种堆栈时刻变化的场景, HeapProfile 很容易就会打满内存. 这就造成了内存泄露的假象.

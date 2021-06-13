---
title: "深入浅出 KuiBaDB: Expression"
hidden: false
tags: ["KuiBaDB"]
---

## 前言

[KuiBaDB](https://github.com/KuiBaDB/KuiBaDB) 的表达式想解决之前在 PostgreSQL 中遇到的表达式相关的几个问题:

-   最高只支持 8byte 对齐. 之前做过基于 int128 的 decimal128 类型, int128 是 16byte 对齐, 因此编译器在某些场景下会生成一些要求 16byte 对齐, 但效率更高的指令. 但由于 pg 最高只支持 8byte 对齐, 即 decimal128 的 typalign 只能是 8, 即 pg 中 decimal128 数据只能在 8byte 上对齐. 导致这些要求 16byte 对齐的指令运行会 crash, 所以很痛苦.

-   表达式结果不支持内存复用. 同样还是 decimal128 为例, decimal128 对应的加法运算接口伪代码实现:

    ```c
    Datum decimal128plus(Datum left, Datum right) {
        Datum ret = palloc(16);
        *ret = left + right;
        return ret;
    }
    ```

    即这里每次都需要动态分配 16byte 空间. 虽然 pg memory contex 做了一定的池化处理, 但如果能完全避免与 memory context 打交道效率应该会更好. 另外这里尝试过在 decimal128plus() 内实现自己的结果复用能力, 比如:

    ```c
    static decimal128 g_sum;
    Datum decimal128plus(Datum left, Datum right) {
        g_sum = left + right;
        return &g_sum;
    }
    ```

    但不幸地发现, pg 有时候会对函数返回的 Datum 调用 pfree, 比如:

    ```c
    str = OutputFunctionCall(&typoutputinfo_width, value);
    /* pg_strtoint32 will complain about bad data or overflow */
    width = pg_strtoint32(str);
    pfree(str);
    ```

-   不支持公共子表达式消除. 之前做过 Teradata 到 Greenplum 的迁移, Teradata 是支持 select target list 的列在后续部分被引用的, 如下 col1 便被多次引用了.

    ```sql
    select expr1 as col1, col1 + 3 from table1 where col1 > 7
    ```

    但 Greenplum/PostgreSQL 不支持这种能力, 所以如上 SQL 在迁移时不得不改写为:

    ```sql
    select expr1 as col1, (expr1) + 3 from table1 where (expr1) > 7.
    ```

    而且 GP/PG 不支持公共子表达式消除, 所以 expr1 便不得不会被多次计算.

-   按行计算, 一次只能计算一行. 这个就是老生常谈的问题了, 不再多述.

## Datums

为了解决 pg 一次只能计算一行这个问题, 一个质朴的想法是那我一次计算多行. PG 中函数接口原型是 `Datum ExecEvalExpr(ExprState *state, ExprContext *econtext, bool *isNull)`, 即一次接受一行作为输入, 返回对应的一个值. 那一次计算多行的版本可以是 `Vec<Datum> ExecEvalVecExpr(ExprState* expression, ExprContext* econtext, bool* selVector, Vec<Datum>* inputVector, ExprDoneCond* isDone)`, 即一次接受多行, 为每一行计算出一个对应的值并返回. 这也正是 openGauss 中向量化引擎的做法.

为此, 我们引入 Datums, Datums 等同于 `Vec<Datum>`, 负责保存一组 Datum. KuiBaDB 在设计 Datums 格式遵循了如下几个原则:

1.  Datums 应该与 PG Datum 一样, 仅负责存放数据, 不负责元信息存放, 即 Datums 中并不会存放着 typalign, typlen 这些信息.
2.  Datums 序列化, 反序列化的成本应该尽可能低. 实际上 KuiBaDB 中 Datums 布局就是列存 block 的布局. 序列化的低成本意味着我们能尽可能地避免 encoding/decoding 开销.
3.  同属于同一类型的 Datums 之间应该能比较效率地拼接成一个 Datums, 或者从一个 Datums 中拆分. 当前 KuiBaDB 中算子的返回类型是 `Vec<Datums>`, 即 `Vec<TupleTableSlot>` 的列式版本. 在列存写入链路中, 会将执行器返回的多个 `Vec<Datums>` 拼接为一个 `res: Vec<Datums>`, 即 `res[i]` 来自于执行器吐出的多个 `Vec<Datums>` 中 i 列对应的 Datums 拼接后的结果. res 会被序列化为一个列存 block 并写入. 同样在列存读取时, 会将一个列存 block 对应的大 `Vec<Datums>` 拆分为多个小 `Vec<Datums>`, 并一一吐给执行器作为执行器输入. 所以拆分, 拼接的效率越小越好咯.
主要是在列存写入时, 我们会将从计算引擎接受到的多个 `Vec<Datums>`
4.  Datums 支持随机访问, 即访问 Datums 中第 n 个元素并不需要对前 n - 1 个元素进行解码. 这样使得我们能写出更有效率的计算代码, 如下代码在计算时, 将 null 的计算, 与实际的计算分开进行, 更有利于编译器生成向量化加速指令, 而且局部性更友好. 想充分利用局部性原理不就得相同执行模式的事情一起进行, 不同执行模式的东西分开处理嘛.

    ```rust
    fn add(left: Datums, right: Datums) {
        left.nullbitmap |= right.nullbitmap;
        for i in 0..left.len() {
            left[i] += right[i];
        }
    }
    ```

    正如之前我在 [一次'失败'的尝试]({{site.url}}/2020/06/20/unsuccessful-work/) 提到的:

    > 最近看了很多向量化执行相关的论文, 可以看到向量化最大的好处就是在于固化了每个算子的执行模式, 使得局部性原理得到了最大化的应用, 相应地性能表现也就非常优秀.

所以 Datums 最终定义如源码所示, 可以看到这里 Datums 是支持任意 typalign 的, Datums 在分配内存时总会遵循 typalign 要求. 这里不在做额外介绍. 额外提一句为啥 Datums 要支持 single 模式, 在 a > 3 这种计算时, 3 这种常数就应该以 Single 形态存在的. 但 a 是 batch 的. 当然 KuiBaDB 可以在执行 a + 3 之前将 3 从 single 转换为与 a 具有相同的 ndatum 的 batch, 但这样没必要不是么. 所以 `>` 运算符对应函数实现就少不了判断 left 或者 right 是否是 single, 既然会有这个判断, 那么索性优化下 single 时的存储咯. 话说 openGauss 就会提前将 3 从 single 转化为 batch, 这里在 `>`, `+` 等运算符对应实现中不需要考虑 left, right 可能为 single 的问题..

## 公共子表达式消除

公共子表达式消除一个朴素的实现是, 在 ExecInitExpr() 过程中, 当遇到表达式 x 时, 首先看下 x 是否已经遇到过, 若已经遇到过, 则表明 x 是公共子表达式, 其可被消除. 这里一个主要的问题, 是表达式的求值顺序, 若 expr2 想复用 expr1 的结果, 则 expr1 要先于 expr2 求值. 在 flink 中, 是通过构造 scope tree, 通过 scope tree 来判断 expr1 能否复用 expr2. 在 KuiBaDB 中, ExecInitExpr() 遍历表达式树的顺序正好就是表达式的求值顺序, 因此若在 ExecInitExpr(expr2) 的过程中, 发现 expr2 的子表达式 expr1 已经遇到过, 那么便意味着 expr1 求值先于 expr2, expr2 这里可以复用之前 expr1 求值结果.

KuiBaDB 中公共子表达式消除与结果内存复用是放在一起实现的. 在 ExecInitExpr() 遍历表达式树过程中, 会为每个表达式, 子表达式分配一个 id: result index. 之后在求解表达式时, 我们会先分配或者复用一个 Datums 数组 results, 每个表达式在运算后便将其结果保存在 `results[expr.result_index]` 中. 这样只要我们能复用 results 所占内存空间, 便达到了结果内存复用的效果. 为了实现公共子表达式消除, 引入了 ExprInitCtx 结构, 其保存了 ExecInitExpr() 遍历表达式树的过程中, 已经遇到的表达式以及他们对应的 result_index. 在后续 ExecInitExpr() 过程中, 若再次遇到了先前已经遇到的表达式, 便会在此处将表达式替换为 ReusedResult, ReusedResult 在求值时, 是直接返回 `results[result_index]`, 即返回之前已经求解的结果. 这里使用了 PG queryjumble.c 中的做法为每一个表达式计算一个 hash. 若两个表达式具有相同的 hash, 则意味着两个表达式相同. 与 PG queryjumble.c 不同的是, KuiBaDB 使用了 md5 作为哈希算法. 主要是 PG queryjumble.c 也没有严谨地提出其所用哈希算法的碰撞几率, 咱自己也不会算, 总感觉 queryjumble.c 仅能用于一些不严肃的场景中...

可以看到这里 ExprInitCtx 控制了公共子表达式消除的作用范围. 而且考虑到表达式复用不能跨算子进行. 因此每个算子应根据自身实际情况构建一个或多个 ExprInitCtx, 并按照自身表达式求值顺序来调用 ExecInitExpr(). 另外若表达式中含有 volatile 函数, 则意味着表达式会有额外的副作用, 其结果不应该被复用. 老实说, 我不是很理解 volatile 函数存在的意义, 正经的计算性质的函数哪有啥副作用啊, 输入啥计算啥就行了呗?!

## col > random()

虽然当前 KuiBaDB 尚不支持 random() 函数, 但也考虑了 random() 这类函数应该如何处理? 以 col > random() 为例, 这里 col 是 batch, random() 如果只返回了一个 single 的话, 会使 col batch 中每一个都与同一个 single 进行比较. 这违背了 random() 的语义, 毕竟 col batch 每一行, 都应该调用 random() 得到一个不同的随机数. 为此我们需要引入一个额外的 expr context, 这个 expr context 告诉了接下来的表达式其所在上下文, 简单来说, 就是告诉接下来的表达式应该吐出多少行? 这即是 openGauss ExprContext::align_rows 的意义. 这也是 KuiBaDB 以后的解法==

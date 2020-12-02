---
title: "rust 究竟是怎么模式匹配的"
hidden: false
tags: ["JustForFun"]
---

最近用 rust 重写了之前用 go 写的一个[锁等待图生成工具](https://github.com/hidva/waitforgraph), 这个小玩意会读取收集 Greenplum 当前锁信息, 并生成对应的锁等待图, 可用来大幅加速线上问题的排查. 不幸的是, 之前用 go 写出之后, 不小心把源码弄丢了, 导致我们目前只有 binary 能用. 导致了在使用过程中很多想加的小功能都整不了了. 正巧这次借着 rust 的机会重新实现了下这个功能, 此间过程中也加深了对 rust 各种特性的理解, 比如模式匹配. 模式匹配在 rust 中被大量使用, 在 rust 中, 赋值, 函数参数等都是一次模式匹配, 就感觉到很奇妙.

这篇文章介绍了如何根据 rust reference 文档中内容推断出模式匹配背后地实现细节, 从而可以更有自信地使用 rust 的模式匹配功能. 但一般情况下我们并不需要掌握, 根据目前对 rust 使用来看, rust 是一门很"自然"的语言. 尤其是她的模式匹配, 凭直觉使用即可, 能编译通过便意味着直觉是正确的, 当编译出错时, 根据 rust 的错误信息修正下即可. 同样这些细节是根据文档, 而不是根据真正的代码实现来推断的, 所以可能会有点误差.

## 基于树结构地匹配

我对模式匹配一开始的认知是两棵树结构的匹配. 在 rust 中, scrutinee, 即待匹配的表达式, 她的运算结果就对应着一个值, 这个值总可以看作是一个树结构组织. 同样 pattern 本身也会被 rust 组织为一个树结构. 之后 rust 的模式匹配就转变为两棵树结构的匹配了. 比如如下例子:

```rust
struct S1{m1: i32, m2: i32};
struct S2(i32, i32);
let Some((x, S2(p1, p2))) = Some((S1{m1: 2018, m2: 1218}, S2(1218, 2018)))
```

中 pattern, scrutinee 对应的两棵树结构如下:


{% mermaid %}
graph TD

subgraph scrutinee
Some_s[Some] --> tuple_s[tuple]
tuple_s --> S1_s[S1]
tuple_s --> S2_s[S2]
S1_s --> m1_s[2018]
S1_s --> m2_s[1218]
S2_s --> 1218
S2_s --> 2018
end

subgraph pattern
Some --> tuple
tuple --> S2
tuple --> x
S2 --> p1
S2 --> p2
end
{% endmermaid %}

所以很明显能看到这里 `x = S1{m1: 2018, m2: 1218}`, `p1 = 1218`, `p2 = 2018`.

这一认知大部分场景下都工作地很好, 直至遇到了 reference scrutinee 以及 non-reference pattern.

## binding mode

按照我上面逻辑, 对于如下形式的模式匹配:

```rust
let i : &Option<(i32)> = ..
let Some((j)) = i;
```

我理解应该会在一开始就由于树结构对不上而编译报错的, 毕竟这里 scrutinee 是引用, 而 pattern 是非引用. 所以当看到编译通过, 毕竟 j 类型是 &i32 时就很诧异. 所以对 rust 模式匹配背后的实现细节更加好奇, 最终在 rust reference 中找到了如下这段话, 这段话完整地描述了 rust 中模式匹配究竟是怎么实现的. 但描述地很精简, 下面会按照我的理解来扩写这段话成更直白的描述.

> If a binding pattern does not explicitly have ref, ref mut, or mut, then it uses the default binding mode to determine how the variable is bound. The default binding mode starts in "move" mode which uses move semantics. When matching a pattern, the compiler starts from the outside of the pattern and works inwards. Each time a reference is matched using a non-reference pattern, it will automatically dereference the value and update the default binding mode. References will set the default binding mode to ref. Mutable references will set the mode to ref mut unless the mode is already ref in which case it remains ref. If the automatically dereferenced value is still a reference, it is dereferenced and this process repeats.


这里 binding pattern, 我理解就是指 Identifier patterns, identifier pattern 会在匹配的同时将 scrutinee 中的值绑定到某个变量中. binding mode; 指定了 binding pattern 的工作模式. 比如当 binding mode 是 ref 时, 意味着将 scrutinee 中对应值的引用绑定到 binding pattern 指定的变量中. binding pattern 可通过 ref, ref mut 等关键字来显式指定其 binding mode. 如下所示:

```
let i = 33;
let ref j = i;
```

这里 j 作为 binding pattern, 其 binding mode 是 ref, 即将 i 的引用绑定到 j 中. 即如上语句等同于 `let j = &i`.

rust 每一次模式匹配都有一个全局的 default binding mode, 指定了本次模式匹配过程中所有未显式指定 binding mode 的 binding pattern 在 binding 时所用的 mode. 在模式匹配的过程中, rust 会在某些条件成立时修改 default binding mode, 这一修改会影响同一模式匹配中后续所有 binding pattern 的 binding mode. 简单来说, 我们可以认为 rust 中模式匹配实现伪代码如下, 这里 PatternMatch 是 rust 模式匹配的入口, default binding mode 初始值是 move.

```rust
fn PatternMatch(pattern: AST, scrutinee: AST) {
    let def_binding_mode = "move";
}
```

当在模式匹配的过程中, 当 a reference is matched using a non-reference pattern 时, rust 会 dereference the value and update the default binding mode. 这个更新 default binding mode 的逻辑伪代码如下所示:

```python
if reference is immutable:
  def_binding_mode = "ref"
else: # reference is mutable:
  if def_binding_mode != "ref":
     def_binding_mode = "ref mut"
```

这里 Non-reference patterns include all patterns except bindings, wildcard patterns (_), const patterns of reference types, and reference patterns.

```rust
fn main () {
    let v1 = 33;
    let v2 = 77;
    let v: &Option<(i32, &i32)> = &Some((v1, &v2));
    let Some((ref x, y)) = v;  // 1
}
```

接下来用上面这个例子来演示下 rust 模式匹配的过程:

1.  开始模式匹配, 将 default binding mode 初始化为 move.
2.  发现 v 是 reference, 而且此时 pattern `Some(..)` 为 non-reference pattern. 此时 dereference v. 并将 default binding mode 更新为 ref.
3.  接下来 scrutinee 是 `(v1, &v2)`, pattern 是 `(ref x, y)`. 这里并不需要变更 default binding mode.
4.  接下来 scrutinee 是 v1, pattern 是 `ref x`, 这里 pattern 明确指定了 ref, 所以不需要使用 default binding mode. v1 类型是 i32. 因此 x 类型为 `&i32`, 其值为 v1 的 reference.
5.  接下来 scrutinee 是 `&v2`, pattern 是 `y`, 此时 pattern does not explicitly have ref, ref mut, or mut, 所以使用 default binding mode. 而 default binding mode 为 ref, 即 pattern 等同于 `ref y`, 所以 y 类型为 `&&i32`, 其值为 `&v2` 的 reference.

这里可以在 y 之前使用 mut 等来阻止使用 default binding mode. 加上 mut 之后, `let Some((ref x, mut y)) = v` y 类型便是 &i32 了.


如下, [pattern-binding-modes](https://github.com/rust-lang/rfcs/blob/master/text/2005-match-ergonomics.md) 中关于 binding mode 转换过程的状态图很形象.

```
                        Start
                          |
                          v
                +-----------------------+
                | Default Binding Mode: |
                |        move           |
                +-----------------------+
               /                        \
Encountered   /                          \  Encountered
  &mut val   /                            \     &val
            v                              v
+-----------------------+        +-----------------------+
| Default Binding Mode: |        | Default Binding Mode: |
|        ref mut        |        |        ref            |
+-----------------------+        +-----------------------+
                          ----->
                        Encountered
                            &val
```

## Reference patterns

在对 binding mode 这套掌握之后, 我以为我已经可以在 rust 模式匹配中游刃有余信手拈来了. 直到遇到了 reference pattern! 如同 rust reference 中对 reference pattern 的定义:

```
ReferencePattern :
   (&|&&) mut? Pattern
```

所以我一开始认为 ReferencePattern 的实现, 就是 dereference the pointers that are being matched, 之后将 dereference 的结果再与 Pattern 按照常规的路子进行匹配.

```rust
fn main () {
    let v1 = 33;
    let v2 = 77;
    let v: &Option<(i32, &(i32))> = &Some((v1, &(v2)));
    let Some((ref x, &(y))) = v;  // 1
}
```

所以这里 y 作为 binding pattern, 此时 default binding mode 为 ref, 也即 y 应该是 `&i32` 类型, 其值是 v2 的 reference. 但 MIR 清晰地显示出 y 是 i32 类型!!! 值即 v2!!! 我好不容易建立的关于 rust 模式匹配的知识体系被摧毁了! ~~(甚至怀疑过是不是 rustc 出 bug 了...~~

接下来就继续开始自圆其说了, 一开始我认为 ReferencePattern 中的 Pattern 在匹配时会忽略 default binding mode, 总是使用 move binding mode. 但下面例子中 d 的类型是 `&i32`, 即 d 作为 ReferencePattern 中 Pattern 的一部分, 其在匹配时使用的是 ref binding mode. 毫无疑问地打破了这一猜想.

```rust
fn main () {
    let v1 = 33;
    let v2 = 77;
    let v3 = (v2);
    let v4 = (v2, &v3);
    let v: &Option<(i32, &(i32, &(i32)), &i32)> = &Some((v1, &v4, &v1));
    if let Some((ref x, &(y, (d)), z)) = v {}
    ()
}
```

然后忽然意识到:

> rust PatternMatch 中可能以栈的形式管理了 default binding mode, 每次遇到 ReferencePattern 时, 都会将一个新的, 取值为 move 的 default binding mode 压入到栈中, 对 ReferencePattern 内 Pattern 的匹配将使用这个新的 default binding mode. 在退出 ReferencePattern 时, 会将这个 default binding mode 出栈.

那么接下来就是设计几个例子来看看能不能用这套新理论解释通了:

```rust
fn main () {
    let v1 = 33;
    let v2 = 77;
    let v: &Option<(i32, &(i32), &i32)> = &Some((v1, &(v2), &33));
    if let Some((ref x, &(y), z)) = v {}
    ()
}
```

这个例子中, 根据 MIR 可以看到 z 的类型是 `&&i32`, y 的类型是 `i32`. 即 y 在匹配时使用了 move binding mode, 而 z 在匹配时继续使用了 ref binding mode. nice, 能解释通.

```rust
-- ninghtly
#![feature(move_ref_pattern)]
fn main () {
    let v1 = 33;
    let v2 = 77;
    let mut v3 = (v2);
    let v4 = (v2, &mut v3);
    let v: &Option<(i32, &(i32, &mut (i32)), &i32)> = &Some((v1, &v4, &v1));
    if let Some((ref x, &(y, (d)), z)) = v {}
    ()
}
```

这个例子虽然由于 borrow checker 的原因不能编译通过, 但能看到 x 类型是 `&i32`, y 的类型是 `i32`, d 的类型是 `&mut i32`! d 的类型是 `&mut i32` 意味着此时 default binding mode 是 ref mut, 是由于 rust 遇到了 `&mut (i32)` 这个 mutable reference 而更改的, 也即意味着此时 default binding mode 一定是 move, 而不是 ref, 因为如上所述, rust 并不会将 default binding mode 从 ref 改为 ref mut, 只会从 move 改为 ref mut. nice, 能继续解释通!

## 总结

rust 模式匹配伪代码实现如下所示, PatternMatch 作为模式匹配的入口, 其内会使用 def_binding_mode 作为 binding pattern 默认的 binding mode. 在 rust 遇到 ReferencePattern, 会在 dereference 之后, 递归调用 PatternMatch 来完成 dereference 之后结果与 ReferencePattern 内 Pattern 的匹配. 递归调用意味着 ReferencePattern Pattern default binding mode 再次变为了 move.

```rust
fn PatternMatch(pattern: AST, scrutinee: AST) {
    let def_binding_mode = "move";
}
```
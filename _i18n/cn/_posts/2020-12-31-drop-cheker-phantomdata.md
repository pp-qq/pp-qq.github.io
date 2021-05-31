---
title: "Drop checker 与 PhantomData"
hidden: false
tags: ["Rust"]
---

在回家的路上时候, 忽然想到了 PhantomData.. 当时在囫囵吞枣地学习 rust 时对 PhantomData 只是一扫而过, 只是有印象说是, 应该根据语义来决定是否应该加 PhantomData. 比如 Iter 对外看上去就像是 `&'a T` 的容器, 所以 Iter 在定义上使用了 `_marker: marker::PhantomData<&'a T>,`. 而同样, Vec 看上去是 T 的容器, 所以使用了 `_marker: marker::PhantomData<T>`. 但现在一反刍下来, 发现有点不对劲, 如果我忘了加 PhantomData 会怎么样, 会不知不觉中引入什么坑么.. 越想越是不安.. 所以到家后细细嚼咽了 Rustonomicon 有关 PhantomData 部分, 并总结如下.

## Drop checker check 了什么

再介绍 Rustonomicon 之前, 首先要说下 Rust Drop checker, Drop checker 所做的一个主要的检查便是:

>   For a generic type to soundly implement drop, its generics arguments must strictly outlive it.

即对于如下形式的类型定义:

```rust
struct S<'a, T> {
    // ...
}
```

S 是 generic type, 若 S 实现了 Drop trait, 那么 rust drop checker 要求 generics arguments, 即 `'a`, `T` 必须要 outlive it! 这里 it 我理解是指 S 的实例. 即对于如下代码:

```rust
let s: S<'a, T> = // ...
```

rust drop checker 会检查 `'a` outlive `'s`, 这里 `'s` 表示着 s 的 lifetime, 即 `'a: 's` 要成立. 同样 `T: 's` 也要成立! 所以 Rustonomicon 中举的例子:

```rust
struct Inspector<'a>(&'a u8);

impl<'a> Drop for Inspector<'a> {
    fn drop(&mut self) {
        println!("I was only {} days from retirement!", self.0);
    }
}

struct World<'a> {
    inspector: Option<Inspector<'a>>,
    days: Box<u8>,
}

fn main() {
    let mut world = World {
        inspector: None,
        days: Box::new(1),
    };
    world.inspector = Some(Inspector(&world.days));
    // Let's say `days` happens to get dropped first.
    // Then when Inspector is dropped, it will try to read free'd memory!
}
```

会编译错误. `Inspector(&world.days)` 意味着 Inspector 的 generic parameter `'a` 对应的 generic arguments 是 world.days 的 lifetime. 另外 'its generics arguments must strictly outlive it' 中 it 是指 world.inspector. 所以 rust drop checker 要求 lifetime of world.days outlive lifetime of world.inspector, 但 rust 中规定了同属于同一个 struct 的 field 互相不 outlive. 即 world.inspector 不 outlive world.days, world.days 也不 outlive world.inspector. 所以违背了 rust drop checker, 编译报错.

## 为什么还需要 PhantomData?

其实到了这里, 对 PhantomData 与 Drop checker 感觉还有点迷糊, 比如如下 BugBox 实现:

```rust
struct BugBox<T> {
    d: *const T,
    // _marker: std::marker::PhantomData<T>,
}

impl<T> BugBox<T> {
    fn new(val: T) -> BugBox<T> {
        let p = unsafe {alloc(Layout::new::<T>()) as *mut _};
        unsafe {
            ptr::write(p, val);
        }
        BugBox {
            d: p,
            // _marker: Default::default(),
        }
    }
}

impl<T> Drop for BugBox<T> {
    fn drop(&mut self) {
        let d = unsafe {ptr::read(self.d)};
        std::mem::drop(d);
        unsafe {dealloc(self.d as *mut _, Layout::new::<T>());}
    }
}
```

rust drop checker 会要求 T outlive BugBox, 有没有 PhantomData 无所谓啊! 确实, 上面 BugBox 实现确实目前来说没有问题. 但当与如下类型结合使用时, 就会产生不应该的编译错误.

```rust
struct Safe1<'a>(&'a str, &'static str);

unsafe impl<#[may_dangle] 'a> Drop for Safe1<'a> {
    fn drop(&mut self) {
        println!("Safe1(_, {}) knows when *not* to inspect.", self.1);
    }
}

struct SafeS<'a> {
    b: Option<BugBox<Safe1<'a>>>,
    s: String,
}

pub fn main() {
    let mut ss = SafeS {
        b: None,
        s: "".to_string(),
    };
    ss.b = Some(BugBox::new(Safe1(&ss.s, "")));
}
```

如上代码人肉判断是没有问题的, 但由于 BugBox 实现了 Drop, rust drop checker 要求 `Safe<'a>` outlive BugBox, 而实际上这一要求又不满足导致了编译报错. 但人肉判断, 这里 '`Safe<'a>` outlive BugBox' 并不是必须的, 因为 Safe 在其 drop 中并未访问 `'a`. 所以对 BugBox 做了第一版修改, 使用 `may_dangle` attribute:

```rust
unsafe impl<#[may_dangle] T> Drop for BugBox<T> {
    fn drop(&mut self) {
        let d = unsafe {ptr::read(self.d)};
        std::mem::drop(d);
        unsafe {dealloc(self.d as *mut _, Layout::new::<T>());}
    }
}
```

但这样又引入了另外一个问题, 由于 T 标记了 may_dangle, 因此 rust drop checker 不再要求 T outlive BugBox, 所以可以写出如下会导致 use-after-free 的代码:

```rust
// 代码3
struct Safe<'a>(&'a str, &'static str);

impl<'a> Drop for Safe<'a> {
    fn drop(&mut self) {
        println!("Safe({}, {}) knows when *not* to inspect.", self.0, self.1);
    }
}

struct Str(String);

impl Drop for Str{
    fn drop(&mut self) {
        self.0 = "DROPED!!!".to_string();
    }
}

struct SafeS<'a> {
    s: Str,
    b: Option<BugBox<Safe<'a>>>,
}

pub fn main() {
    let mut ss = SafeS {
        b: None,
        s: Str("HelloWorld".to_string()),
    };
    ss.b = Some(BugBox::new(Safe(&ss.s.0, "")));
}
```

所以这时候就需要为 BugBox 引入 PhantomData 了. 这样在与 Safe 一起使用时可以得到预期内的编译报错:

```rust
   Compiling playground v0.0.1 (/playground)
error[E0713]: borrow may still be in use when destructor runs
  --> src/main.rs:58:34
   |
58 |     ss.b = Some(BugBox::new(Safe(&ss.s.0, "")));
   |                                  ^^^^^^^
59 | }
   | -
   | |
   | here, drop of `ss` needs exclusive access to `ss.s.0`, because the type `Str` implements the `Drop` trait
   | borrow might be used here, when `ss` is dropped and runs the destructor for type `SafeS<'_>`
   |
   = note: consider using a `let` binding to create a longer lived value

error: aborting due to previous error
```

而且又不影响 `BugBox<Safe1>` 的编译.


## 总结

所以现在总结下来, rust drop check 的规则目前看如下, 对于 T, T 实现了 Drop trait:

1.  rust drop check 会首先检查 T 所有 generic arguments outlive T. 此时若 T::drop() 实现中, 某个 generic parameter 具有 may_dangle attribute, 那么 rust dropck 将忽略这一 generic parameter 对应 generic arguments 检查. 即如下例子中, rust dropck 并不要求 T1 outlive V, 但要求 T2 outlive T.

    ```rust
    struct V<T1, T2> { /* ... */}

    unsafe impl<#[may_dangle] T1, T2> Drop for V<T1, T2> {
        /* ... */
    }
    ```

2.  之后 rust dropck 会递归遍历 T 的所有 field, 若某个 field 类型 T1 实现了 Drop, 则 T1 中所有 generic arguments 必须 outlive field, 除非 T1 使用了 may_dangle 来修饰了某一 generic arguments. 即这里对 T1 应用了第一步 drop check 规则.

现在再次回到 BugBox 定义中, 这里 BugBox 最终正确定义与 Vec 实现一样. 即 BugBox::drop() 使用了 may_dangle 修饰了 generic parameter T. 同时 BugBox 内包含 `PhantomData<T>`. 那么对于 `BugBox<Safe1>`, 通过应用如上 2 个 drop check rule, 可知 rust dropck 并不要求 `'a` outlive BugBox, 也不要求 `'a` outlive `_marker`. 而对于 `BugBox<Safe>`, 由于 Safe 没有使用 may_dangle 来修饰 `'a`, 所以 `BugBox<Safe>` 要求 `'a` outlive `_marker`, 所以 '代码3' 示例编译不过.

## 参考

-   [Why is it useful to use PhantomData to inform the compiler that a struct owns a generic if I already implement Drop?](https://stackoverflow.com/questions/42708462/why-is-it-useful-to-use-phantomdata-to-inform-the-compiler-that-a-struct-owns-a)

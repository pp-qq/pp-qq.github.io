---
title: "Drop checker 与 PhantomData"
hidden: false
tags: ["JustForFun"]
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

## PhantomData 如果没正确使用会导致什么后果?

我更迷糊了... 我本来以为如下例子不加 PhantomData 会编译成功, 但后来一想这里 BugBox 实现了 Drop, drop checker 会要求 T outlive BugBox 的, 肯定会编译失败, 也即用不用 PhantomData 无所谓.

```rust
use std::alloc::{alloc, dealloc, Layout};
use std::ptr;

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

struct S<'a>(&'a str);

impl<'a> Drop for S<'a> {
    fn drop(&mut self) {
        println!("S::F. {}", self.0);
    }
}

struct Bug<'a> {
    b: Option<BugBox<S<'a>>>,
    s: String,
}

pub fn main() {
  let mut bug = Bug {
      b: None,
      s: "HelloWorld".to_string(),
  };
  bug.b = Some(BugBox::new(S(bug.s.as_str())));
}
```

不过倒也强行找出了一个用了 PhantomData 会编译报错, 不用就编译成功的例子, 即删掉如上例子中 BugBox::Drop() 实现. 但感觉并没有太大的说服力...






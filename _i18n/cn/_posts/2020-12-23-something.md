---
title: "最近遇到的有趣事情"
hidden: false
tags: ["开发经验"]
---

## C/C++ strict aliasing rule

之前在做某个项目时, 遇到了一个问题, 细细抽取之后, 得到最小可复现代码, 即如下代码在 gcc O2 时会得到错误的结果.

```c
#include <stdlib.h>
#include <stdio.h>

static inline
int64_t GetScaleFromBits(int64_t bits)
{
    constexpr int64_t scales = 0x000a000800040002;  // constexpr 加不加都会报错.
    return ((int16_t*)&scales)[bits];
}

int main(int argc, char **argv) {
    for (int64_t i = 0; i < 4; ++i)
        printf("%ld\n", GetScaleFromBits(i));
}
```

GetScaleFromBits() 的语义, 其实就是如下代码, 当时不知道怎么脑抽了, 写成如上形式...!

```c
static inline
int64_t GetScaleFromBits(int64_t bits)
{
    int16_t scales = {2, 4, 8, 10};
    return scales[bits];
}
```

具体排查过程省略, 这里直接说下结论, 导致得到错误结果的主要原因是 `-fstrict-aliasing`, 实际上 man gcc 然后看下 `-fstrict-aliasing` 就能明白了, GetScaleFromBits() 违背了 strict aliasing rule....

## rust &str 与系统调用

我们知道, 像 open(), stat() 这些系统调用, 其对字符串参数的要求是以 `\0` 结尾. 但 rust `&str` 类型却不是以 `\0` 结尾, 那么如下代码, 是怎么完成这一转换的呢?

```rust
use std::fs::File;

fn main()  {
    let filepath = "hellofoo.txtworld";
    println!("{:#?}", filepath.as_ptr());
    let mut f = File::open(&filepath[5..12]).unwrap();
}
```

本来, 一开始呢, 我是准备从 File::open() 源码入手, 一步步往下看的, 但很快就迷失在 CStr, OsStr, Path 这几个互相转换中. 后来才想起来, 完全可以 gdb 调试一下的. 无论 如rust 是怎么完成这一转化的, filepath 这个变量是肯定要读取的, 所以我们借助于 gdb rwatch 很快就确定了这一转换发生位置:

```
Continuing.
Hardware read watchpoint 4: *$d  # filepath 前 8 字节.

Value = 8029749289371329896
0x00007ffff7325ef3 in __memcpy_ssse3_back () from /lib64/libc.so.6
(gdb) bt
#0  0x00007ffff7325ef3 in __memcpy_ssse3_back () from /lib64/libc.so.6
#1  0x000055555556cec0 in copy_nonoverlapping<u8> () at /rustc/18bf6b4f01a6feaf7259ba7cdae58031af1b7b39/library/core/src/intrinsics.rs:1858
#2  copy_from_slice<u8> () at /rustc/18bf6b4f01a6feaf7259ba7cdae58031af1b7b39/library/core/src/slice/mod.rs:2524
#3  spec_extend<u8> () at /rustc/18bf6b4f01a6feaf7259ba7cdae58031af1b7b39/library/alloc/src/vec.rs:2227
#4  extend<u8,&[u8]> () at /rustc/18bf6b4f01a6feaf7259ba7cdae58031af1b7b39/library/alloc/src/vec.rs:2368
#5  into_vec () at library/std/src/ffi/c_str.rs:384
#6  new<&[u8]> () at library/std/src/ffi/c_str.rs:396
#7  cstr () at library/std/src/sys/unix/fs.rs:863
#8  open () at library/std/src/sys/unix/fs.rs:697
#9  std::fs::OpenOptions::_open::h3ce33d457946905c () at library/std/src/fs.rs:922
#10 0x000055555555da57 in std::fs::OpenOptions::open::h2ef7ba01971d00ff (self=0x7fffffffdf08, path=0x55555558dff5) at /rustc/18bf6b4f01a6feaf7259ba7cdae58031af1b7b39/library/std/src/fs.rs:918
#11 0x000055555555db03 in std::fs::File::open::h236e38b877ded3eb (path="foo.txt") at /rustc/18bf6b4f01a6feaf7259ba7cdae58031af1b7b39/library/std/src/fs.rs:335
```

可以看到这里需要重新分配内存, 并追加 `\0`. 涉及到源码见 [ffi/c_str.rs](https://hidva.com/g?u=https://github.com/rust-lang/rust/blob/master/library/std/src/ffi/c_str.rs), 在 `new()` -> `_new()` -> `from_vec_unchecked()` 链路.

## tcp_tw_reuse 对于相同的 remote ip port 不顶用

众所周知, tcp_tw_reuse 用于在可行的情况下 reuse port, 比如在开启 tcp_tw_reuse 时, connect remote-ip1:port1, remote-ip2:port2 可能会产生如下四元组:

```
localip:localport1 -> remote-ip1:port1
localip:localport2 -> remote-ip2:port2
```

即会使用相同的 localport1. 但如果 remote-ip1:port1 与 remote-ip2:port2 完全一致的话, tcp_tw_reuse 就不起作用了, 此时总要选择不同的 localport 来构造不一样的四元组. 所以这时只能通过降低 tcp_tw_timeout 来避免 cannot assign requested address 报错了.





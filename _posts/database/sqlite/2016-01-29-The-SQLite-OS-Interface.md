---
category: sqlite
---

# 简介

## sqlite 架构
![sqlite 架构图]({{site.url}}/assets/vfs1.gif)

*   Tokenizer,Parser,Code Generator;负责将 SQL 编译为 byte code(又被称为 prepared statement);
*   Virtual Machine;负责运行 prepared statement;
*   B-Tree,Pager;**未看**
*   OS Interface;又被称为 VFS;sqlite 库中所有需要与 OS 交互的操作都通过 VFS 进行.因此移植
    sqlite 很简单,只需要重新实现一个 VFS 即可.

## VFS 相关
*   每一个 VFS 都有唯一的标识名;同一时间内可以注册多个 VFS.
*   sqlite 中每一个连接与 VFS 一一对应,可以在打开连接时指定其使用的 VFS.

### 内置 VFS
*   sqlite3 库内部提供了若干个 unix VFS.这些 VFS 唯一的区别在于对文件锁的处理;除了'unix','unix-excl'
    VFS 之外,其他 VFS 对文件锁的实现都是不可共存的.
*   2个进程使用不同的 unix VFS 来访问同一数据库文件,可能会无法看到对方的文件锁,导致数据库文件被污染.

### 选择特定的 VFS
*   默认 VFS;默认 VFS 的默认值是'unix',或者'win32'.优先级:低.
*   在打开数据库时,可以指定所使用的 VFS 的名称.
*   在通过 URL 来打开数据库时,可以通过'?vfs='来指定 VFS 的名称.优先级:高.

# 实现新的 vfs
*   实现新 VFS 的方式就是继承(C 语言中的**继承**):`sqlite3_file`,`sqlite3_vfs`,`sqlite3_io_methods`
    这几个类.
*   `sqlite3_file`;表示一个打开的文件.
*   `sqlite3_io_methods`;相当于`sqlite3_file`的成员函数;提供了包括读,写,获取文件长度等接口.
    在`sqlite3_file`的对象中,存放着指向对应`sqlite3_io_methods`的指针.
*   `sqlite3_vfs`;表示一个 VFS;存放着 VFS 的名称,以及接口地址.

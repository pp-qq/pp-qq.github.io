---
title: "C++11 标准阅读"
subtitle: "Storage Class Specifiers"
hidden: false
tags: ["C++"]
---

# 前言
* 根据[storage_duration](http://en.cppreference.com/w/cpp/language/storage_duration)总结而来.


# Storage Class Specifiers
*   是声明语法的一部分;指定了标识符2个独立的属性:storage duration;linkage;
*   static;指定了标识符具有 static/thread storage duration;并且具有 internal linkage 属性.
*   extern;指定了标识符具有 static/thread storage duration;并且具有 external linkage 属性.
*   thread_local;指定了标识符具有 thread storage duration;未指定标识符的 linkage 属性.

# Storage duration
*   atomic storage duration;此时对象所占的内存在进入代码块时分配;在推出代码块时回收;此时只是
    内存分配;并没有构造对象;另外不要与变量的作用域搞混.
*   static storage duration;此时对象所占的内存在进程创建时分配;在进程结束时回收;
*   thread storage duration;此时对象所占的内存在线程创建时分配;在线程结束时回收;每一个线程都
    有自己的副本.
*   dynamic storage duration;此时对象所占的内存其分配与回收由用户决定.

# Static local variable
*   何时初始化;若 static local variable 使用 zero/constant 初始化;则编译器在编译时就已经
    初始化(即 .data 段赋值);否则在第一次遇到初始化语句时初始化,并且在整个进程执行期间只会初始化
    一次,而且是多线程安全!
*   初始化异常时;
    -   若初始化时发生了异常;则会认为未成功初始化,即未初始化;会在下一次遇到初始化语句时再一次初始化,
        直至初始化成功.
    -   若初始化时递归,即在初始化过程中又一次进入 static local variable 所在的代码块;此时行为
        未定义;
*   何时析构;仅当 staic local variable 成功初始化之后,才会在进程终止时执行析构函数.







**转载请注明出处!谢谢**

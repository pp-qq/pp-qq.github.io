---
title: "Android 开发"
subtitle: "SDK, NDK, Android 项目流程"
tags: [Android, "Android NDK"]
---

# WHAT
*   记录了 Android 开发过程笔记.

# Android SDK 介绍

## platform-tools
*   platform-tools;存放着一些 build-tools,这些 build-tools 会周期性更新以与 Android 新
    平台兼容;这也就是为什么将其与 basic sdk tools 分开放置的原因.


# Android NDK 介绍

## 项目目录布局
*   项目目录布局,如下:

    ```shell
    project/  #项目根目录.
    └── jni   #native code
        ├── Android.mk
        └── Application.mk
    ```
    当编译时,在 project 下运行 ndk-build,此时会根据 jni/Android.mk 来编译 native code;
    并将生成库安装到 project/libs/ 下面.

## static runtimes 或 shared runtimes.
*   当选择 static runtimes,并且 jni 下有多个 module,这样会导致每一个 module 都有 static
    runtimes 的一个副本.这样 static runtimes 内部使用,或者暴露出来的全局变量就会重复,会导致
    以下问题:
    *   memory allocated in one library, and freed in the other would leak or even
        corrupt the heap.
    *   exceptions raised in libfoo.so cannot be caught in libbar.so (and may
        simply crash the program).
    *   the buffering of std::cout not working properly.
*   当选择 shared runtimes 时,就不会有这些问题,只不过此时在 APP 启动时,应该按照依赖顺序来
    依次加载 so.如:现有`libfoo.so`,`libbar.so`,`libstlport_shared.so`;其中`libfoo.so`依赖
    `libbar.so`;`libstlport_shared.so`又被`libbar.so`,`libfoo.so`依赖;则应该:

    ```java
    static {
        System.loadLibrary("stlport_shared");
        System.loadLibrary("bar");
        System.loadLibrary("foo");
    }
    ```

## 找不到 so
*   现有`libfoo.so`,`libgnustl_shared.so`;其中`libfoo.so`依赖`libgnustl_shared.so`.
    然后如下代码会提示:`java.lang.UnsatisfiedLinkError: Cannot load library: libgnustl_shared.so`;

    ```java
    static {
        System.loadLibrary("foo");
    }
    ```
    而下面代码则正常:

    ```java
    static {
        System.loadLibrary("gnustl_shared");
        System.loadLibrary("foo");
    }
    ```
    WHY?
*   `System.loadLibrary('foo')` 会调用`dlopen()`,然后解析出`libfoo.so`依赖着`libgnustl_shared.so`;
    因此会执行`dlopen('libgnustl_shared.so')`,然后问题就在这里,此时`dlopen()`没有关于上层 APP 的任何信息.
    所以他只会在`LD_LIBRARY_PATH`环境变量指定的路径中查找;即只会在`/lib`,`/system/lib`下面查找;所以找不到!
    而`System.loadLibrary('foo')` 本身知道 APP 的所有信息,然后其在调用`dlopen()`时就已经指定了路径,如:
    `dlopen('/data/com.package/lib/libfoo.so')`;
*   在`dlopen()`指定通过`setenv()`更新`LD_LIBRARY_PATH`的值可以么?!不可以,因为链接器在`exec()`加载进程
    时就会复制当前环境变量并保存;之后`dlopen()`只使用保存值!即`setenv()`不起作用.

# Android 源码阅读
## 基础概念
*   release;任何时刻中,Android 都存在一个 release 版本;各方在这个 release 版本的基础上进行新特性开发与测试.
    每一个 release 版本都有一个对应的版本号;即 AndroidManifest.xml 中 sdkversion;release 的版本号在
    release 的代码树中某个位置定义.

*   upstream project;即 Android 项目依赖的第三方开源库;Android 项目中以 git submodule 的形式引用着
    这些子模组.



















**转载请注明出处!谢谢**

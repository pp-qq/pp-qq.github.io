---
title: "Gcc 使用 init priority 控制全局变量初始化顺序"
hidden: false
tags: 
 - 
   "C++"
---

## init_priority

在 C++ 标准中,对于全局变量的初始化顺序,只规定了若全局变量的定义在同一 translation unit
(可以理解为:源文件) 中,则定义的顺序决定了初始化的顺序,并没有规定跨 translation unint
的情况下初始化顺序.

gcc 中可以通过`__attribute__((__init_priority__(PRIORITY)))`在全局变量定义时指定其初始化
顺序,这里`PRIORITY`值越小,优先级越高;并且`PRIORITY`的合法范围:`[101,65535]`.若若干全局变量
的`init_priority`值相同,则**试验发现**:此时相当于这些全局变量都未指定`init_priority`的规则
来整.

对于跨 so 的全局变量,其初始化顺序依赖于 so 之间的依赖关系;如:若 A.so 依赖于 B.so,则很显然
B.so 的初始化代码段先于 A.so 执行,即 B.so 中的全局变量先于 A.so 中的全局变量初始化.

所以,我们只需要考虑组成同一 so(或可执行文件) 的众多 translation unit 中全局变量的初始化顺序.

-   情况一:这些全局变量均未使用`init_priority`;则同一 translation unit 中的全局变量初始化顺序按照
    标准来整;跨 translation unint 的全局变量,其初始化顺序取决于链接时,全局变量定义所在'.o'
    在命令行参数中的出现顺序.

    这部分均属**试验发现**,因为没找到这部分的标准资料;对于跨 translation unit,若在链接时
    A.o 出现在 B.o 之前,则根据 gcc 版本不同,A.o 中的全局变量初始化可能先于 B.o 中的全局变量,
    也可能后于.
    
-   情况二:所有全局变量均使用`init_priority`;则按照 GCC 标准来整.

-   情况三:部分全局变量使用了`init_priority`,部分没有;则**试验发现**(也是因为没有找到相关文档),
    所有使用了`init_priority`的全局变量(下称 As),其初始化顺序**均**先于未使用`init_priority`
    的全局变量(下称 Bs);

    对于 As 中包含的全局变量,其初始化顺序取决于优先级的值.对于 Bs 中包含的全局变量,其初始化
    顺序取决于'情况一'
    
### 模版与 init_priority

这里讲述了模板与`init_priority`的交互;注意以下结论均是**试验发现**(因为没找到标准文档).

```sh
# 本次试验中所使用 g++ 版本.
$ g++ -v
使用内建 specs。
COLLECT_GCC=g++
COLLECT_LTO_WRAPPER=/usr/lib/gcc/x86_64-pc-cygwin/5.4.0/lto-wrapper.exe
目标：x86_64-pc-cygwin
配置为：/cygdrive/i/szsz/tmpp/gcc/gcc-5.4.0-1.x86_64/src/gcc-5.4.0/configure --srcdir=/cygdrive/i/szsz/tmpp/gcc/gcc-5.4.0-1.x86_64/src/gcc-5.4.0 --prefix=/usr --exec-prefix=/usr --localstatedir=/var --sysconfdir=/etc --docdir=/usr/share/doc/gcc --htmldir=/usr/share/doc/gcc/html -C --build=x86_64-pc-cygwin --host=x86_64-pc-cygwin --target=x86_64-pc-cygwin --without-libiconv-prefix --without-libintl-prefix --libexecdir=/usr/lib --enable-shared --enable-shared-libgcc --enable-static --enable-version-specific-runtime-libs --enable-bootstrap --enable-__cxa_atexit --with-dwarf2 --with-tune=generic --enable-languages=ada,c,c++,fortran,lto,objc,obj-c++ --enable-graphite --enable-threads=posix --enable-libatomic --enable-libcilkrts --enable-libgomp --enable-libitm --enable-libquadmath --enable-libquadmath-support --enable-libssp --enable-libada --enable-libgcj-sublibs --disable-java-awt --disable-symvers --with-ecj-jar=/usr/share/java/ecj.jar --with-gnu-ld --with-gnu-as --with-cloog-include=/usr/include/cloog-isl --without-libiconv-prefix --without-libintl-prefix --with-system-zlib --enable-linker-build-id --with-default-libstdcxx-abi=gcc4-compatible
线程模型：posix
gcc 版本 5.4.0 (GCC)
```

```cpp
// 本次试验中所使用的公共代码,后续标识符均是引用这里的标识符.

#include <stdio.h>

struct X {
    X(const char *name):
        name_(name)
    {
        printf("%s;this: %p;name: %s\n",__PRETTY_FUNCTION__,this,name_);
    }
    
    ~X()
    {
        printf("%s;this: %p;name: %s\n",__PRETTY_FUNCTION__,this,name_);
    }

private:
    const char *name_ = nullptr;
};


template <typename Type>
struct Y {
    static X x;
};

template <typename Type>
__attribute__((init_priority(333))) X Y<Type>::x("hello");
```

*   试验1;结论:仅当用到模板类的成员时,该成员才会被实例化.

    ```cpp
    int
    main()
    {
        Y<int> a;
        Y<double> b;
    }
    ```
    
    ```shell
    $ g++ -Wall -std=gnu++11 main.cc
    $ ./a.out # 没有输出,因为此时 Y::x 并未实例化!
    $ 
    ```
    
*   试验2;结论:模板类的实例化类似于简单的宏替换;

    ```cpp
    int
    main()
    {
        void *ptr1 = &Y<int>::x;
        void *ptr2 = &Y<double>::x;
        return 0;
    }
    
    // 这里生成的 Y<int> 代码如下:
    
    struct Y_int {
        static X x;
    };
    
    __attribute__((init_priority(333))) X Y_int::x("hello");

    // 这里生成的 Y<double> 代码如下:
    
    struct Y_double {
        static X x;
    };
    
    __attribute__((init_priority(333))) X Y_double::x("hello");
    
    ```
    
    此时`Y<int>::x`,`Y<double>::x`的初始化顺序取决于编译器实例化的顺序,在本例中,编译器先遇到`Y<int>`,
    即`Y<int>::x`也被实例化,因此也先被初始化.

*   试验3;结论:如下:

    ```cpp
    
    template <>
    __attribute__((init_priority(333))) X Y<int>::x("int");
    
    int
    main()
    {
        void *ptr2 = &Y<double>::x;
        void *ptr1 = &Y<int>::x;
        return 0;
    }    
    
    ```
    
    注意,此时`Y<int>::x`先于`Y<double>::x`初始化;因为`Y<int>::x`已经是一个完整的变量定义了,它不再是模板了.




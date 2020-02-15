---
title: "GNU Autotools 一览"
tags: ["gcc"]
---

老实说, 这篇文章对你来说可能并没有啥用, 我也只是想为 PostgreSQL 加入 c++ 构建支持才去了解下 autotools 的. 不过按照我的习惯, 既然了解了就应该总结一下, 既然总结了那就正好发出来吧==

GNU Autotools, 和 cmake 一样, 都是一种构建工具. GNU Autotools 由众多工具组成, 每个工具都有自己的文档, 所以对于初入者来说显得一头雾水, 不知从何入手. 本文试图以一种体系化的方式来介绍 GNU Autotools.

GNU Autotools 的核心就是 configure.ac 文件, 开发者通过 GNU m4 语言在该文件中指定自己项目可能会用到的各种特性, 之后通过 autoconf 将 configure.ac 转换为 configure, 一个仅依赖 bash 的, 可单独执行的 shell 脚本. 对于用户来说, 其在下载完项目准备构建时, 只需要运行 `./configure` 即可. 此时 configure 脚本会根据用户环境探测开发者需要的特性是否存在, 最后将探测结果以特有方式告知开发者, 开发者就可以利用这些探测结果来定制化项目使其可以在用户环境中运行. 

我们来以一个很小的项目来举例说明整个流程, 假设此时我们想写一个输出 helloworld 的程序, 我们用两种选择, 一个是通过 stdio.h 中的 puts 函数来输出, 另外一种则是通过系统调用 write, 我们不确定两者哪个在用户机器上存在, 因此我们写出如下 configure.ac 来进行探测:

```m4
AC_INIT

# 探测用户机器上是否存在 puts, write 函数. 
AC_CHECK_FUNCS([puts write])
AC_CONFIG_HEADERS([config.h])

AC_OUTPUT
```

在通过 autoconf 将上述 configure.ac 转换为 configure 可执行程序之后, 运行该可执行程序, 其会探测当前机器是否存在 puts, write 函数. 并将探测结果写入 config.h 文件中. 此时需要一个模板文件 config.h.in, 这里暂不需要深究该模板文件如何写:

```c
#undef HAVE_PUTS
#undef HAVE_WRITE
```

configure 根据这个模板文件生成的 config.h 文件:

```
/* config.h.  Generated from config.h.in by configure.  */
#define HAVE_PUTS 1
#define HAVE_WRITE 1
```

其他在程序的其他地方我们就可以通过 include config.h 来定制化程序行为了:

```c
#include "config.h"

#if defined(HAVE_PUTS)
#include <stdio.h>
#elif defined(HAVE_WRITE)
#include <unistd.h>
#else
#error "Oh! no!"
#endif

int main(int argc, char **argv) {
    const char msg[] = "helloworld";
#if defined(HAVE_PUTS)
    puts(msg);
#elif defined(HAVE_WRITE)
    write(1, msg, sizeof(msg) - 1);
    write(1, "\n", 1);
#endif
    return 0; 
}
```

除了头文件之外, configure.ac 也可以生成其他文件, 如下我们准备为项目加个小小的 Makefile:

```Makefile
# Makefile.h.in 文件
# `@CC@` 将被 configure 替换为探测到的用户机器上存在的 C 编译器.
CC=@CC@
hello: hello.o
	$(CC) -o hello hello.o    
```

相应的 configure.ac 文件中新增一行:

```
# 在运行 ./configure 时, 其会读取对应的模板文件 Makefile.in, 然后将 `@变量名@` 类似的字符串替换为
# 探测收集到的值. 这里就会把 `@CC@` 替换为用户机器上实际存在的 C 编译器, 如: gcc.
AC_CONFIG_FILES([Makefile])
```

此时由 configure 生成的 Makefile 如下所示:

```
CC=gcc
hello: hello.o
	$(CC) -o hello hello.o
```

然后 make:

```
$ make 
gcc    -c -o hello.o hello.c # 这个是 Makefile 的 Implicit rule 生成的命令. 
gcc -o hello hello.o
```

综上, 对于开发者我们只需要在项目中提供 hello.c, config.h.in, Makefile.in, configure 文件即可. 对于用户其只需要 `./configure && make && ./hello` 即可.

为了进一步降低开发者的工作量, 大佬们围绕着这一套体系又开发出很多小工具来简便开发者的生活, 如 autoheader, 会根据 configure.ac 中的定义生成 config.h.in 文件. 再比如 automake, 会根据 configure.ac 等文件生成 Makefile.in 文件. 等等, 针对这些工具的学习了解, 可以在需要的时候参考他们的文档即可. 对了在 autoconf 文档中有几幅图形象的展示了各个工具的输入输出以及他们之间的交互, 可以看一下. 如: 

```
your source files --> [autoscan*] --> [configure.scan] --> configure.ac

configure.ac --.
               |   .------> autoconf* -----> configure
[aclocal.m4] --+---+
               |   `-----> [autoheader*] --> [config.h.in]
[acsite.m4] ---'
     
Makefile.in

[acinclude.m4] --.
                 |
[local macros] --+--> aclocal* --> aclocal.m4
                 |
configure.ac ----'

configure.ac --.
               +--> automake* --> Makefile.in
Makefile.am ---'

                       .-------------> [config.cache]
configure* ------------+-------------> config.log
                       |
[config.h.in] -.       v            .-> [config.h] -.
               +--> config.status* -+               +--> make*
Makefile.in ---'                    `-> Makefile ---'
```

## GNU M4

整个 GNU Autotools 体系严重依赖 GNU M4, 因此这里我们简单介绍一下 GNU M4. GNU M4 是一种宏处理程序, 根据宏对应的定义将宏调用扩展为相应的文本. 从实际实现上来看, 更类似于 rust 那种基于 token 的宏. 在 GNU m4 中, 会将输入切分为一个个 token, 然后根据每个 token 的类型采取不同的动作, 大部分情况下都会直接输出 token. 当前 GNU m4 中共有 4 种类型的 token:

-   name, A name is any sequence of letters, digits, and the character '_' (underscore), where the first character is not a digit. 如果这里 name 是个已经被定义的宏, 那么 GNU m4 就会开始宏展开过程. 

-   A quoted string is a sequence of characters surrounded by quote strings, defaulting to ``` and `'`, where the nested begin and end quotes within the string are balanced. The value of a string token is the text, with one level of quotes stripped off.

-   Comments; Comments in m4 are normally delimited by the characters ‘#’ and newline. All characters between the comment delimiters are ignored, but the entire comment (including the delimiters) is passed through to the output—comments are not discarded by m4.

-   Other kinds of input tokens; Any character, that is neither a part of a name, nor of a quoted string, nor a comment, is a token by itself. When not in the context of macro expansion, all of these tokens are just copied to output. However, during macro expansion, whitespace characters (space, tab, newline, formfeed, carriage return, vertical tab), parentheses (‘(’ and ‘)’), comma (‘,’), and dollar (‘$’) have additional roles, explained later.

As m4 reads the input token by token, it will copy each token directly to the output immediately. The exception is when it finds a word with a macro definition. In that case m4 will calculate the macro’s expansion, possibly reading more input to get the arguments. It then inserts the expansion in front of the remaining input. In other words, the resulting text from a macro call will be read and parsed into tokens again. m4 expands a macro as soon as possible. If it finds a macro call when collecting the arguments to another, it will expand the second call first. This process continues until there are no more macro calls to expand and all the input has been consumed.

GNU m4 总会在能执行宏扩展的地方执行宏扩展, 不需要我们做出额外的动作. 不过 GNU m4 同时也提供几种机制让我们可以显式禁止宏扩展:

-   GNU 某些内建带有参数的宏, 仅当存在参数时才会被识别为宏并进行宏扩展操作.

-   使用 A quoted string 将输入拆分为多个 token. 

这里我们来详细介绍下宏扩展中的门门道道. 在宏扩展过程中, ',' 用来分隔参数, 除非 ',' 本身出现在 quotes, comments, or unquoted parentheses 中. If too few arguments are supplied, the missing arguments are taken to be the empty string. However, some builtins are documented to behave differently for a missing optional argument than for an explicit empty string. If there are too many arguments, the excess arguments are ignored. 对于参数中的空白字符, Unquoted leading whitespace is stripped off all arguments, but whitespace generated by a macro expansion or occurring after a macro that expanded to an empty string remains intact. 参数尾部的空白字符总会被保留. 另外 GNU m4 允许宏在扩展过程中改变其定义, 此时 the expansion uses the definition that was in effect at the time the opening ‘(’ was seen. 如:

```
$ m4
define(`f', `1')

f
1
f(define(`f', `2'))            
1  # 这里仍使用之前定义.
f  # 虽然这里就会使用最新定义了.
2
```

对于宏展开过程中遇到的宏, GNU m4 提供了一些机制可以让我们控制宏展开的时机, If it is not quoted, it will be expanded prior to the outer macro, so that its expansion becomes the argument. If it is single-quoted, it will be expanded after the outer macro. And if it is double-quoted, it will be used as literal text instead of a macro name. 如:

```
$ m4
define(`foo', `$1') 
 
define(f, 2)

foo(1)
1
foo(``f'')
f  # 注意这里 f 并未被引号起来.
foo(`f')
2
```

如何定义自己的宏? 可以使用 GNU m4 内建 `define(name, expansion)` 来定义一个新的宏, 关于 define 具体语法, 详见 m4 文档. 这里简单总结下 expansion 中的门道. 在 POSIX 规范中, 宏参数个数最大为 9 个, 在 expansion 中分别用 `$1`, `$2`, ... , `$9` 引用. 即不支持 `$` 后面跟多个数字. 但在 GNU m4 中, 便没有这个限制了, 但这个特性又可能会在 m4 2.0 中被移除以此来符合 POSIX 标准. 另外 POSIX 规定了 `${` 行为由实现定义, GNU m4 1.x 此时会直接输出, GNU m4 2.0 这个行为又被调整了, 所以最好不要使用==.

## Autoconf

这里根据 autoconf 文档简单总结下 autoconf. 简单来说 Autoconf 就是 GNU m4 的扩展, 提供了一堆方便开发者使用的宏, 而且使用了 GNU m4 `changequote([, ])` 机制将 `[]` 作为引号. The Autoconf macros are defined in several files. Some of the files are distributed with Autoconf; autoconf reads them first. Then it looks for the optional file ‘acsite.m4’ in the directory that contains the distributed Autoconf macro files, and for the optional file ‘aclocal.m4’ in the current directory.

configure.ac 文件布局. 在 configure.ac 文件的编写过程中, 某些宏可能会依赖其他宏的使用, 因此 autoconf 定义了 configure.ac 文件布局格式: 

```
Autoconf requirements
AC_INIT(package, version, bug-report-address)
information on the package
checks for programs
checks for libraries
checks for header files
checks for types
checks for structures
checks for compiler characteristics
checks for library functions
checks for system services
AC_CONFIG_FILES([file...])
AC_OUTPUT
```

按照这套布局编写 configure.ac 文件应该可以最大化减少由于依赖宏未调用导致报错的信息. 之前提过开发者通过在 configure.ac 中指定他们所需要的特性, 然后生成的 configure 会实际探测这些特性是否存在, 并通过多种方式告知开发者探测结果. 目前在 autoconf 中, ./configure 有 4 种方式可以告知开发者探测结果, 详见 autoconf 4.5 节 'Outputting Files' 内容. 

configure 文件, 由 autoconf 根据 configure.ac 文件生成的可单独执行的文件. 在运行时, configure 会运行各种脚本探测 configure.ac 指定的特性是否存在, 之后生成 config.status 文件. 然后再运行 config.status 文件生成 configure.ac 要求的各种文件. 

## make

这里零散记录下 makefile 若干知识点. 首先要参考 make 文档 '3.7' 节 'How make Reads a Makefile' 内容了解下 make 整体工作流程. 

`+` prefix, 在 Makefile 中, 若 recipe 中有一行使用了 `+` 前缀修饰, 或者其内包含了 `$(MAKE)` 字符串, 那么该行内容总会被执行, 哪怕是用户在执行时使用了 `-p`, `-n` 等选项. 

Built-In Rules, makefile Built-In Rules 基本涵盖了编写 C/C++ 所需要的各种 rules, 可通过 `make -p` 来查看当前 make 内建了哪些 rules.

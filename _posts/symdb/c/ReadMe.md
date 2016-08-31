
## 前言

*   这其中放置了 C 语言中的符号介绍.

## 目录布局

*   由于 C 语言中并没有命名空间等概念,所以对于一篇介绍符号的文档直接放在'symdb/c'下
    以符号名作为文件名即可.

*   当需要以头文件的形式介绍符号时,将其放在'symdb/c/include'下保持头文件的路径即可.
    头文件的路径是头文件被使用时在`#include`中指定的路径,而不是文件的真是绝对路径.
    如:`#include <unistd.h>`,则'unistd.h'的位置就是'symdb/c/include/unistd.h';再如
    `#include <arpa/inet.h>`,则'inet.h'的位置就是'symdb/c/include/arpa/inet.h'.
    

*   如下是一个栗子:

    ```shell
    c
    ├── 2016-03-03-mmap.h.md
    ├── 2016-03-03-munmap.h.md
    └── include
        ├── 2016-03-03-endian.h.md
        ├── 2016-03-03-stdint.h.md
        ├── arpa
        │   └── 2016-03-03-inet.h.md
        └── sys
            └── 2016-03-03-types.h.md 
    ```



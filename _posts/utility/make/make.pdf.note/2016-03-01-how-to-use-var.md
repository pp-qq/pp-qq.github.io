---
title: Makefile-如何使用变量
---

## 预定义的一些变量

### MAKEFILE_LIST

*   依据 makefile 文件被解析的顺序,存放着已经被解析的 makefile 文件的文件名集合;
    在 make 准备解析一个 makefile 之前,便会将其文件名放入`MAKEFILE_LIST`中,大致如下:
    
    ```c++
    MAKEFILE_LIST.append(filename);
    parse(filename);
    ```

*   所以,对于任意一个 makefile 文件来说;若表达式`$(lastword $(MAKEFILE_LIST))`位
    于 makefile 文件的最开始,则该表达式的结果就是当前 makefile 的文件名.
    
*   文件名还是文件路径?`MAKEFILE_LIST`中存放着的是文件名,还是文件路径.在 make 官
    方文档中并没有说明(只说了*the name of each makefile*).所以我试了一下,结果如下:
    
    ```shell
    wangwei@~/project/org/pp-qq/test/makefile-test
    $ cat MAKEFILE_LIST-test.mk 

    name1 := $(lastword $(MAKEFILE_LIST))

    include a/inc.mk

    name2 := $(lastword $(MAKEFILE_LIST))

    all:
        @echo name1 = $(name1)
        @echo name2 = $(name2)

    wangwei@~/project/org/pp-qq/test/makefile-test
    $ tree
    .
    ├── a
    │   └── inc.mk
    └── MAKEFILE_LIST-test.mk

    1 directory, 2 files
    wangwei@~/project/org/pp-qq/test/makefile-test
    $ make -f MAKEFILE_LIST-test.mk 
    name1 = MAKEFILE_LIST-test.mk
    name2 = a/inc.mk 
    ```

    
    



**转载请注明出处!谢谢**

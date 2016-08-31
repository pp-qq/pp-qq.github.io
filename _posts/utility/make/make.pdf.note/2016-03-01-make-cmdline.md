---
title: make-命令行介绍
---


## 常规用法

```shell
make -f Makefile路径 -C 工作目录
```

*   `-C 工作目录`;在 make 做任何事之前,首先`chdir()`切换到`-C`参数指定的目录.
    -   若有多个`-C`选项;如:`-C d1 -C d2`;则等同于:`chdir('d1');chdir('d2')`.

    
    



**转载请注明出处!谢谢**

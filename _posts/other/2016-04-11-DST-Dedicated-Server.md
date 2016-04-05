---
title: 饥荒专用服务器-基础
---


## 前言

*   本文主要讲述了饥荒专用服务器的一些基础知识,并未涉及到专用服务器的搭建.

## 专用服务器命令行选项

```shell
$ cd $(DST_SERVER_DIR)/bin
$ ./dontstarve_dedicated_server_nullrenderer 
```

*   `-persistent_storage_root`,`-conf_dir`;`$(persistent_storage_root)/$(conf_dir)`
    决定了配置文件的目录;专用服务器将在这里来加载配置以及保存存档.
    
    -   `-persistent_storage_root`选项的默认值是 ~/.klei.
    -   `-conf_dir`选项的默认值是 DoNotStarveTogether
    
*   `-cluster`;指定了专用服务器本次要加载的 Cluster 名称;此时专用服务器将去`$(persistent_storage_root)/$(conf_dir)/$(cluster)/`
    下面来加载 Cluster 配置以及资源,并且将相关的存档文件也保存在这里.
    

## Cluster 目录模板

## 参考

*   [Dedicated Server Quick Setup Guide - Linux](http://forums.kleientertainment.com/topic/64441-dedicated-server-quick-setup-guide-linux/)
*   [Dedicated Server Command Line Options Guide](http://forums.kleientertainment.com/topic/64743-dedicated-server-command-line-options-guide/)


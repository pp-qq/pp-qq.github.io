---
title: 饥荒专用服务器-基础
---


## 前言

*   本文主要讲述了饥荒专用服务器的一些基础知识,并未涉及到专用服务器的搭建.

## 若干概念

*   Cluster;我的理解就是世界的意思.

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

```shell
$ tree Cluster_template/                                                                       
Cluster_template/                                                                              
├── cluster.ini                                                                                
├── cluster_token.txt                                                                          
└── Master                                                                                     
    ├── modoverrides.lua                                                                       
    ├── server.ini
    └── worldgenoverride.lua
```

*   `cluster.ini`;存放着 Cluster 的配置信息;如下:
    
    ```ini
    [GAMEPLAY]
    game_mode = survival
    max_players = 7
    pvp = false
    pause_when_empty = true

    [NETWORK]
    lan_only_cluster = false
    offline_cluster = false
    cluster_description = 
    cluster_name = 
    server_intention = social
    cluster_password = 
    cluster_intention = cooperative

    [ACCOUT]
    dedicated_lan_server = false


    [STEAM]
    DISABLECLOUD = true

    [MISC]
    CONSOLE_ENABLED = true
    autocompiler_enabled = true
    ```

    -   在[forums.kleientertainment.com][0]上应该有每一个字段的具体意义.我没找过 @_@

*   `cluster_token.txt`;token嘛,令牌文件,关于如何生成令牌文件,参见[专用服务器搭建][1].如:

    ```
    UKINT+RYTH1+51FUH+AVAVR+Y5MAL+P3N1S==
    ```

*   `Master`;地表世界;该目录下存放着地表世界所有信息,包括地表世界的配置,存档等.

*   `Master/modoverrides.lua`;地表世界中的插件配置.参见'服务端 mod'.

*   `Master/worldgenoverride.lua`;自定义地表世界,如资源多少,地图大小之类的;参见'自定义地表世界'.

*   `Master/server.ini`;地表世界的配置.如下:
    
    ```ini
    [SHARD]
    is_master = true
    ```
    
    -   这里我就知道这么多,具体可以去[forums.kleientertainment.com][0]搜一搜.



## 参考

1.  [Dedicated Server Quick Setup Guide - Linux][1]   
2.  [Dedicated Server Command Line Options Guide][2]   

[0]: <http://forums.kleientertainment.com>
[1]: <http://forums.kleientertainment.com/topic/64441-dedicated-server-quick-setup-guide-linux/> "Dedicated Server Quick Setup Guide - Linux"
[2]: <http://forums.kleientertainment.com/topic/64743-dedicated-server-command-line-options-guide/> "Dedicated Server Command Line Options Guide"




**转载请注明出处!谢谢**

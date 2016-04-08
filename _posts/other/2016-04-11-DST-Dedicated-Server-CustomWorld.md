---
title: 饥荒专用服务器-自定义世界
---

## 一般步骤

1.  使用[自定义世界脚本生成][0]提供的服务,进行适当的设置之后下载对应的'worldgenoverride.lua'
    文件.

2.  新建 Cluster,将'worldgenoverride.lua'文件拷贝到新建'Cluster/Master/'下面.

    -   很显然,'worldgenoverride.lua'只有在世界第一次启动时才会运行创建世界.将'worldgenoverride.lua'
        放到已经存在的 Cluster 中并不会起作用.
    
3.  以新建 Cluster 为名启动饥荒专用服务器.
    



[0]: <http://www.lyun.me/lyun/1191> 

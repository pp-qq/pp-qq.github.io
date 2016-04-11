---
title: 饥荒专用服务器-Git Keep Alive Forever
---

## 前言

*   注意:下面所有信誓旦旦的东西都是我猜的,可能是正确的,但无法证明.

## 数据是如何来保存的

```shell
├── cluster.ini
├── cluster_token.txt
└── Master 
    ├── modoverrides.lua
    ├── save # 地表世界的存档
    │   ├── boot_modindex
    │   ├── client_temp
    │   ├── mod_config_data
    │   ├── modindex
    │   ├── saveindex
    │   ├── server_temp
    │   │   └── server_save
    │   └── session
    │       └── 284095843F39136E
    │           ├── ...
    │           ├── KU_4Cop6dXS_
    │           │   └── ...
    │           ├── KU_ChjEDMBB_
    │           │   └── ...
    │           ├── KU_ETCyH2SS_
    │           │   └── ...
    │           ├── KU_KCg55GED_
    │           │   └── ...
    │           └── KU_OEj0doF2_
    │               └── ...
    └── ...
```

### Master/save

*   地表世界下的所有存档都是在这里.

### Master/save/session

*   一般情况下,其下仅会存放着一个会话ID,仅当在一个世界中所有人物都死亡之后,点击 Reset 世界时,会生
    成新的会话ID,并删除老的会话ID.

*   在专用服务器启动时,若 session 目录下没有会话存在,则服务器会生成一份新的会话;否则使用已经存在
    的会话.

### Master/save/session/$(ID)

*   下面存放着当前世界中存在的用户,以及各个用户的具体信息.如上,世界中有 5 个用户.每一个用户的数据
    信息保存在各自的文件夹中.
    
*   当用户连接到专用服务器中时:
    -   若在 session/$(ID) 下没有以该用户名(用户标识更准确一点)为目录名的目录存在,则表明用户是
        新用户,此时用户可以在客户端选择建立人物之类的.
    -   若在 session/$(ID) 下已经存在,则表明用户是老用户,此时会读取下面的配置信息,并把这些信息
        传递给客户端.

#### 用户的数据信息何时上传

*   反正不是在一改动时就上传,即不会在拔个草,砍个树之后立即更新用户在服务端的存档信息,因为我试了拔草
    之后,git status 显示没有新的改动.

*   在一天过去时,客户端弹出"保存数据"时会把用户信息上传到服务端.

## 使用 git 来 Keep Live Forever

*   incrontab

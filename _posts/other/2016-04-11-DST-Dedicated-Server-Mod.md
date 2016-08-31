---
title: 饥荒专用服务器-Mod使用
---

## 下载

参见[饥荒联机版服务端MOD及更多设置][0]中'DEDICATED……SETUP.LUA法下载MOD'.


## mod 目录布局

```shell
workshop-572538624/
├── modinfo.lua
├── modmain.lua
└── ...
```

*   `modinfo.lua`;存放着 mod 的元信息以及配置信息.


## 启用 mod

*   在`$(CLUSTER_DIR)/Master/modoverrides.lua`中指定指定 Cluster 中地表世界中会启用的插
    件以及选项值.其内容如下:
    
    ```lua
    return
    {
        ["workshop-375859599"] = { 
            enabled = true
        },
        ["workshop-347079953"] = {
            enabled = true
        }
    }
    ```


## 参考

*   [饥荒联机版服务端MOD及更多设置][0]


[0]: <http://www.lyun.me/lyun/427> "饥荒联机版服务端MOD及更多设置"




**转载请注明出处!谢谢**

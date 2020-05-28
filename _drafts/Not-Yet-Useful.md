该篇文章记录了关于某个特定 topic 的学习总结. 只是还不成熟以至于无法为他们建立单独的文章来描述, 所以暂时就塞这里吧. ~~等今后有空时再拿出来完善然后丢进他们该去的位置去~~.


## 如何打印日志

https://mp.weixin.qq.com/s/ChPGFVnfEXpXcAfM5LjlRA

## SQL 中的条件(谓词)下推

按我理解, SQL 中的条件(谓词)下推应该是指将 SELECT 语句中 where 子句包含的条件中, 将直接作用在列本身的谓词提取出来, 并汇聚在一起下推给存储层. 存储层在取数据时会应用这些条件, 仅返回符合条件的数据, 这样可以减少返回的数据量. 计算层会在存储层返回的数据之上再应用 where 子句中包含的其他条件, 进一步筛选满足条件的行. 如用户输入 SQL `SELECT * FROM table WHERE col=1 and LENGTH(col2) = 2`, 那么查询引擎可能会先给存储层下发个 `SELECT * FROM table WHERE col = 1`, 然后查询引擎再在存储层返回的数据上再应用 `LENGTH(col2) = 2` 这一条件进一步筛选.

## Docker 是什么?

首先要铭记 Docker 不是虚拟机, Docker container 与宿主机共用一套内核. Generally speaking a Docker image is just a custom file/directory structure, assembled in layers via FROM and RUN instructions in one or more Dockerfiles, with a bit of meta data like what ports to open or which file to execute on container start. That's really all there is to it. The basic principle of Docker is very much like a classic chroot jail, only a bit more modern and with some candy on top.

Docker for mac 的实现原理大致是首先在 mac 上启动个 linux 虚拟机, 然后在该虚拟机中在启动 docker container. 而且该虚拟机没有 ip 地址, 或者说与 mac 本机共享 ip 地址. docker -p 导出的 port, 可以直接在 mac 本机上访问. 如下可以看到 docker container 导出的端口在 mac 本机可以看到, 并且可以直接访问:

```bash
zhanyi.ww|zhanyide-mac|~/DockerData/root/tmp
$ docker ps
CONTAINER ID        IMAGE                                             COMMAND             CREATED             STATUS              PORTS                                                         NAMES
2b15d60f9b81        xxxx.alibaba-inc.com/xx/yy:0.0.1   "/sbin/init"        11 days ago         Up 5 days           0.0.0.0:22223-22227->22223-22227/tcp, 0.0.0.0:22222->22/tcp   dev
zhanyi.ww|zhanyide-mac|~/DockerData/root/tmp
$ sudo lsof -PiTCP -sTCP:LISTEN
Password:
COMMAND     PID      USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
com.docke 35379 zhanyi.ww   20u  IPv4 0xaf9e525426275aad      0t0  TCP *:22227 (LISTEN)
com.docke 35379 zhanyi.ww   22u  IPv4 0xaf9e525413d807ad      0t0  TCP *:22226 (LISTEN)
com.docke 35379 zhanyi.ww   24u  IPv4 0xaf9e5254112eee2d      0t0  TCP *:22225 (LISTEN)
com.docke 35379 zhanyi.ww   26u  IPv4 0xaf9e525421d84e2d      0t0  TCP *:22224 (LISTEN)
com.docke 35379 zhanyi.ww   28u  IPv4 0xaf9e52540d95112d      0t0  TCP *:22223 (LISTEN)
com.docke 35379 zhanyi.ww   30u  IPv4 0xaf9e525413d81aad      0t0  TCP *:22222 (LISTEN)
```


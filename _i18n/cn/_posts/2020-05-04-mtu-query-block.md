---
title: "MTU 设置不当导致查询阻塞"
hidden: false
tags: ["Postgresql/Greenplum"]
---

早在去年的时候, 就偶尔会在线上碰到查询由于 interconnect 层阻塞的问题, 当时线上的现象就是 send slice QE 一直在不停地调用 sendto() 发送一样的数据, 很明显是由于 send QE 未收到 receiver QE 的 ACK 导致. 当时一直先入为主地认为是 Greenplum 基于 UDP 实现的可靠数据传输的协议有 bug, 毕竟我始终对一个 MPP 数据库亲自动手实现一个基于 UDP 的可靠数据传输协议这一点耿耿于怀. 这也是我去调研 [QUIC]({{site.url}}/2020/05/02/quic-mvfst/) 的原因之一... 而且受限于当时的知识储备, 对于根因的排查也是心有余而智商不足, 一直没去排查过, 而是见过这种问题就将 interconnect 协议改为 TCP. 等到掌握了 innterconnect 以及 GP 执行框架等相关知识储备, 有能力与这个 bug 一决高下的时候, 他却再也不出现了... 

直到上周, 在申请新实例测试待全量上线的 OSS 外表特性时, 测试 Query 又一次堵住了, 更令人激动地是此时 QE 上的堆栈以及 strace 看到的现象与那个让人魂牵梦绕的 BUG 一致:

```
(gdb) bt
#0  0x00002abcb0a33113 in poll () from /lib64/libc.so.6
#1  0x0000000000bdf958 in SendEosUDPIFC () at ic_udpifc.c:5212
#2  0x0000000000bd181e in SendEndOfStream ()
#3  0x000000000094d217 in ExecMotion ()
#4  0x0000000000918498 in ExecProcNode ()
#5  0x0000000000910859 in ExecutePlan ()
#6  0x000000000091167b in standard_ExecutorRun ()
```

```
$strace -ttt -T -e sendto -p 35029
Process 35029 attached - interrupt to quit
1588562909.648985 sendto(11, "\1\0\0\0\325\210\0\0\216x"..., 1552, 0, x, 16) = 1552 <0.000032>
1588562910.655908 sendto(11, "\1\0\0\0\325\210\0\0\216x"..., 1552, 0, x, 16) = 1552 <0.000028>
1588562911.662931 sendto(11, "\1\0\0\0\325\210\0\0\216x"..., 1552, 0, x, 16) = 1552 <0.000023>
1588562912.669760 sendto(11, "\1\0\0\0\325\210\0\0\216x"..., 1552, 0, x, 16) = 1552 <0.000026>
1588562913.676652 sendto(11, "\1\0\0\0\325\210\0\0\216x"..., 1552, 0, x, 16) = 1552 <0.000020>
1588562914.683540 sendto(11, "\1\0\0\0\325\210\0\0\216x"..., 1552, 0, x, 16) = 1552 <0.000018>
```

既然是发送端一直在重试, 那表明是由于 sender 没有收到 receiver 发来的 ACK, 要么是 receiver 没有发送 ACK, 要么是发送的 ACK 中途丢失. strace receiver 看了下:

```
$strace  -ttt -T -p 19341
Process 19341 attached - interrupt to quit
1588562711.815388 restart_syscall(<... resuming interrupted call ...>) = 0 <0.082694>
1588562711.898126 poll([{fd=20, events=POLLIN}], 1, 250) = 0 (Timeout) <0.250271>
1588562712.148436 poll([{fd=20, events=POLLIN}], 1, 250) = 0 (Timeout) <0.250269>
1588562712.398740 poll([{fd=20, events=POLLIN}], 1, 250) = 0 (Timeout) <0.250274>
1588562712.649048 poll([{fd=20, events=POLLIN}], 1, 250) = 0 (Timeout) <0.250272>
```

这里 19341 是 receiver 端负责收包的 rxThread 线程的 tid, 在 GP udpifc 中, receiver 端由线程 rxThread 负责收包以及 ACK 的发送. 可以看到这里 rxThread poll 一直返回 timeout, 也即 rxThread 一直没有收到发送端发来的数据. 尝试从发送端 ping 下 receiver 是没有问题的. 

```
#ping receiver_ip
PING receiver_ip (receiver_ip) 56(84) bytes of data.
64 bytes from receiver_ip: icmp_seq=1 ttl=61 time=0.049 ms
64 bytes from receiver_ip: icmp_seq=2 ttl=61 time=0.041 ms
^C
--- receiver_ip ping statistics ---
2 packets transmitted, 2 received, 0% packet loss, time 1393ms
rtt min/avg/max/mdev = 0.041/0.045/0.049/0.004 ms
```

趁着现在 sender 端不停在重试的功夫, 使用 tcpdump 在分别在发送端, 接收端进行了抓包. 从抓包中可以看到在发送端包确实是发送出去了, 不过接收端没有收到包的迹象. 所以可能是由于包大小的原因导致了包未能成功发送到对端, 根据发送端 sendto() 系统调用返回的包大小重新 ping 了下, 确实, 再也 ping 不通了.

```
#ping -n -s 1552 receiver_ip
PING receiver_ip (receiver_ip) 1552(1580) bytes of data.
^C
--- receiver_ip ping statistics ---
4 packets transmitted, 0 received, 100% packet loss, time 3245ms
```

接下来就是使用 traceroute 这些工具看下具体哪个环境把包丢掉了. 先看下可以发送成功的包大小下 traceroute 探测出来的路径:

```
#traceroute -n receiver_ip 
traceroute to receiver_ip (receiver_ip), 30 hops max, 60 byte packets
 1  x.y.40.55  0.744 ms  0.863 ms  1.028 ms
 2  x.z.36.169  0.405 ms x.z.36.97  0.563 ms x.z.36.145  0.517 ms
 3  x.z.36.90  0.650 ms x.z.36.26  0.768 ms x.z.36.22  0.467 ms
 4  receiver_ip  0.042 ms  0.041 ms  0.037 ms
```

再看下不能被成功接收的包对应的探测路径:

```
#traceroute receiver_ip 1552
traceroute to receiver_ip (receiver_ip), 30 hops max, 1552 byte packets
 1  x.y.40.55 (x.y.40.55)  0.575 ms  0.698 ms  0.872 ms
 2  x.z.36.137 (x.z.36.137)  0.572 ms x.z.36.169 (x.z.36.169)  0.581 ms x.z.36.177 (x.z.36.177)  0.551 ms
 3  x.z.36.78 (x.z.36.78)  0.375 ms x.z.36.6 (x.z.36.6)  0.561 ms x.z.36.14 (x.z.36.14)  0.761 ms
 4  * * *
 5  * * *
```

可以看到包并没有被中间设备丢掉, 而是被 receiver 端发送包大小超过自身 MTU (1500) 而丢弃. 既然原因是因为包大小问题导致的, 那么就控制下 GP sender QE 发送的包大小即可咯, 反复使用不同大小的包 ping 下接收端, 找了个最大能被发送的大小设置到 gp_max_packet_size 上. 问题也就解决了.

为啥线上没有大规模出现过这个问题? 找了几个线上机器登陆看了下, MTU 均为 1500, 而 gp_max_packet_size 是 8k, 理论上该问题出现应该会频繁才对. 找了个测试实例, 新建表:

```sql
CREATE TABLE test(i int, j varchar);
```

插入了几条数据, 这里插入数据中 j 长度为 3k, 然后执行 `SELECT * FROM test;` 抓包同时 strace 看了下, 虽然 send QE 在调用 sendto() 时包大小为 6k, 但在实际上发包时内核会按照 MTU=1500 进行拆包, 所以 receiver 端可以正常接收. 那为啥上面实例中 sender 端没有进行拆包呢? ifconfig 看了下发送端自身 MTU 为 9000...
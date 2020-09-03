---
title: "GP udpifc interconnect 两三事"
hidden: false
tags: ["Postgresql/Greenplum"]
---

GP interconnect 层, 对上提供了一种可靠有序的数据传输方式, 在查询执行中计算节点之间通过 GP interconnect 层来完成所需的数据交互. 当前 GP 中 interconnect 主要有两种实现: tcp, udpifc. 其中 tcp 便是直接基于 TCP 搭建; udpifc 则是基于 UDP 协议实现, 在 UDP 基础之上加入了 ACK, 重传等机制来实现了一种可靠有序的数据传输. 当前我们线上主要使用的是 udpifc, 之所以未选择 tcp, 一方面是使用 tcp 时会占用太多的端口, 简单来说, 对于一个具有 m 个 slice 的查询, 当其运行在具有 n 个计算节点的集群上时, 每一个计算节点都需要占用 `n * m` 个端口. 在实际生产中, m 一般取值为 100, n 一般取值为 64, 也即用户 1 条查询, 一个计算节点就需要占用 6400 个端口, 也即最多只能支持 10 并发. 而对于 UDPIFC 而言, 对于一条查询, 无论 m, n 取值多少, 每一个计算节点都只恒要 2 个端口即可. 另一方面则是从性能上, tcp interconnect 比不上 udpifc. 本文记录了我们在使用 udpifc 过程中遇到的若干问题以及解决方案.


## TL;DR

太长不看版. 很明显可以看出, 如下几个案例问题的根源就是 gp udpifc 重度依赖了 ip 分片这个特性. 在这篇文章写出前后我们又零零散散遇到过十几例类似问题. 这些问题根本原因都是 ip 分片未能正确处理导致的. 这类问题的表现一般有:

- 查询阻塞, pstack 查看堆栈总位于 sendto(), 或者位于 rxThread poll().
- 日志中出现类似 `Failed to send packet (seq %d) to %s (pid %d cid %d) after %d retries in %d seconds`, `interconnect encountered a network error` 这种报错.

相应地解法也很简单, 首先将 `gp_max_packet_size` 降低到 mtu, 一般 1500 以下. 然后观察问题是否仍能复现, 若问题仍能复现, 一般不太可能, 这时候可以联系我==! 若问题无法复现, 那么八成是 ip 分片导致的. 接下来:

1.  首先观察集群中所有机器是否具有相同的 mtu. 如果不具有, 那么将他们调为一致. 建议统一成 1500. 较大的 mtu 比如 9000 也是可以, 但这样有风险, 如果用于互联机器的某个设备, 比如交换机/路由器不支持这么大的 mtu, 那么仍会导致机器之间无法互联互通.
2.  增大 `net.ipv4.ipfrag_high_thresh`, `net.ipv4.ipfrag_time` 配置. 一个参考值是:

    ```
    sysctl -w net.ipv4.ipfrag_high_thresh=8388608
    sysctl -w net.ipv4.ipfrag_time=60
    ```

3.  祈祷

可以看出, 这些解法都是指标不治本的, 我们遇到过将 ipfrag_high_thresh/ipfrag_time 调大之后, 一时解决了问题, 但之后又会出现的情况. 最根本的解法还是要换成 tcp interconnect, 我们在 [QUIC 与 mvfst](https://blog.hidva.com/2020/05/02/quic-mvfst/) 这篇文章中已经解决了 tcp 情况下端口膨胀的问题. 


## MTU 设置不当导致查询阻塞

早在去年的时候, 就偶尔会在线上碰到查询由于 interconnect 层阻塞的问题, 当时线上的现象就是 send slice QE 一直在不停地调用 sendto() 发送一样的数据, 很明显是由于 send QE 未收到 receiver QE 的 ACK 导致. 受限于当时的知识储备, 对于根因的排查也是心有余而智商不足, 一直没去排查过, 而是见过这种问题就将 interconnect 协议改为 TCP. 等到掌握了 innterconnect 以及 GP 执行框架等相关知识储备, 有能力与这个 bug 一决高下的时候, 他却再也不出现了... 

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

## IP 分片数目过多导致重组失败

在上面那个问题过去没多久, 我们又碰到了一例查询由于 interconnect 层阻塞的问题, 当时线上的现象也是 send slice QE 一直在不停地调用 sendto() 发送一样的数据:

```
$strace -ttt -T -e sendto -p 53635
Process 53635 attached - interrupt to quit
1589200484.371911 sendto(11, "\1\0\0\0\203\321\0\0Y^\0\0\230\311\0\0&\324\0\0\237\226\2\0\1\0\0\0\0\0\0\0"..., 8040, 0, {sa_family=AF_INET, sin_port=htons(54310), sin_addr=inet_addr("x.z.94.137")}, 16) = 8040 <0.000030>
1589200485.378437 sendto(11, "\1\0\0\0\203\321\0\0Y^\0\0\230\311\0\0&\324\0\0\237\226\2\0\1\0\0\0\0\0\0\0"..., 8040, 0, {sa_family=AF_INET, sin_port=htons(54310), sin_addr=inet_addr("x.z.94.137")}, 16) = 8040 <0.000027>
1589200486.385013 sendto(11, "\1\0\0\0\203\321\0\0Y^\0\0\230\311\0\0&\324\0\0\237\226\2\0\1\0\0\0\0\0\0\0"..., 8040, 0, {sa_family=AF_INET, sin_port=htons(54310), sin_addr=inet_addr("x.z.94.137")}, 16) = 8040 <0.000031>
^CProcess 53635 detached
```

而且无论是发送端还是接收端, ifconfig 显示 MTU 都是 1500, 也就是这个问题的原因并不是上面 MTU 那个问题. 在使用了 tcpdump 抓包之后

发送端 tcpdump:

![发送端]({{site.url}}/assets/ipfrag-sender.png)

接收端 tcpdump:

![接收端]({{site.url}}/assets/ipfrag-receiver.png)

可以看到之所以接收端没有收到包, 是因为位于 offset=1480 的这个分片没有被接收端收到, 而且很诡异的是在发送端所有次重试中, 总是这个分片没有被收到. 再加上我试着 ping traceroute 第一跳时也发现当大小超过 MTU 时也总是 ping 不通:

```bash
$traceroute -n x.z.94.137
traceroute to x.z.94.137 (x.z.94.137), 30 hops max, 60 byte packets
 1  x.y.48.119 (x.y.48.119)  0.560 ms x.y.48.55 (x.y.48.55)  0.459 ms x.y.48.119 (x.y.48.119)  0.730 ms
 ...
 6  x.z.94.137  0.056 ms  0.052 ms  0.047 ms

# 当不需要分片时, 可以正常 ping 通.
$ping -n -vvv -M want -s 1472 -c 1 x.y.48.119
PING x.y.48.119 (x.y.48.119) 1472(1500) bytes of data.
1480 bytes from x.y.48.119: icmp_seq=1 ttl=255 time=0.490 ms

# 当需要分片时, 便不再能 ping 通了.
$ping -n -vvv -M want -s 1500 -c 1 x.y.48.119
PING x.y.48.119 (x.y.48.119) 1500(1528) bytes of data.
^C
--- x.y.48.119 ping statistics ---
1 packets transmitted, 0 received, 100% packet loss, time 7544ms
```

所以让我一度以为是发送端自身存在问题, 比如内核/网络/机器哪一块没搞好导致的. 最后去咨询了下阿里基础网络的大佬之后, 才发现是因为接收端重组 buffer 过低导致, 在进一步调高了 net.ipv4.ipfrag_high_thresh 之后发现一切便正常了. 另外某些时候可能还需要同时调整 net.ipv4.ipfrag_time, 默认 30s, 可能需要调大一点~

但这仍然存在这两个遗留问题, 既然是接收端 IP 层重组 buffer 过低导致的丢包, 那么 tcpdump 从网卡抓包时, 在接收端应该是能看到 offset=1480 这个分片的啊. 这个后面想了一下, 目前 ip 分片与重组一般都是网卡硬件实现了, 或者是采用了类似 LRO/GRO 之类的优化技术, 即总是在网络栈最底层完成包的重组与拼接, 尽可能减少对上层协议栈传递的包数量, 所以这里可能是由于重组 buffer 过低导致网卡侧直接丢弃了 ip 分片, 所以 tcpdump 就看不到了.

另一个遗留问题, 为啥在发送端 ping traceroute 第一跳时当包体需要分片时也存在 ping 不通的现象? 这个后面也想了一下, 应该是由于这些负责包转发的中间网络设备不会也不该有重组逻辑, 所以当这些设备看到目的 ip 是自身并且需要重组的分片包便直接丢弃了... (也就是当时我要是随便换个机器来 ping 可能就会早点发现并不是发送端的问题...)

后面又想了一下, 这个问题本质原因其实不能怪是系统配置问题, 而是 GP udpifc interconnect 过度依赖了 IP 分片这一操作. 如上 sendto() 也可以看到, 一次 sendto() 的包体大小就有 8040byte, 对应着 6 个 IP 分片了. 更别说这只是其中一个发送端. 这可能也是接收端重组 buffer 一直被打满但一直完成不了一次完整重组的原因. 举个极端例子: 假设接收端 R 重组 buffer 只能容纳 4 个 ip 分片, 现在有两个发送端 S1, S2, 各个都在试图发送长度为 4000 的 UDP 数据包给 R, 那么每个 UDP 数据包都会拆分为三个分片: S1.f1, S1.f2, S1.f3, S2.f1, S2.f2, S2.f3, 这里 S1.f1, S1.f2, S1.f3 为 S1 发送 UDP 数据包拆片后对应的 IP 数据包. 那么在接收端侧可能会存在场景: 先收到了 S1.f1, S1.f2, S2.f1, S2.f2, 然后接收端自身重组 buffer 被打满, 所以开始丢弃 ip 分片, 导致了无法完成任一数据包的重组. 然后 S1, S2 发现没有收到 R 返回的 ACK 响应, 便又开始重试发送数据包, 而接收端又一次因为重组 buffer 问题无法完成重组... 

当然也可以通过降低 gp_max_packet_size 控制下计算节点发送数据包的大小来避免 IP 分片, 但这样相当于由计算节点自身软件来完成 IP 分片了, 与可能会 offload 到网卡硬件实现的 IP 分片相比, 降低 gp_max_packet_size 的同时性能表现也会急剧下降. 而且现行的 Linux 发包优化技术, 像 TSO, GSO 都是尽可能地将分片放在网络栈的最底层来做, 这样可以显著降低网络栈上层之间交换数据包的数量从而来得到不错的性能提升.

后面对这个的改进一方面可以使用 [UDP GRO/GSO]({{site.url}}/2020/05/11/udp-gro-gso/) 技术来避免对 IP 分片的使用. 或者我们把 [QUIC 协议]({{site.url}}/2020/05/02/quic-mvfst/)集成进来, 毕竟与一个 MPP 数据库亲自动手基于 UDP 实现的一个可靠的数据传输协议相比, 精研此道的 QUIC 应该会更成熟一点.

## 网卡未硬件支持分片导致性能下降

这个问题是由我同事处理的, 具体过程便不再详述. 

![]({{site.url}}/assets/ip-defrag.png)

这里简单总结一下便是某机型网卡不支持 UFO(udp fragmentation offload), 使得分片重组工作不得不由 CPU 自己来做, 导致 interconnect 性能急剧下降, 导致 Query 执行耗时也大幅增加. 后面通过临时调大了网卡 mtu 设置避免了 IP 分片, 与公网那种复杂的网络环境不同, 数据中心内网这里网络环境较为可控, 增大 MTU 的风险也是可控的. 但这个问题本质上应该还是过度使用 IP 分片导致的.
 
另外这里将 interconnect 换为 TCP 之后, 性能表现却没有收到影响, 符合预期. 原因应该是因为网卡支持 tcp segmentation offload, 而且 tcp 会将数据流切分为 TCP Segment 之后发送, TCP Segment 一般大小为 MSS(Maximum Segment Size), 而且 MSS 会小于链路最小 MTU, 即 TCP 协议中基本上不会出现 IP 分片操作.

另外这种场景换为 QUIC 能救么, 我理解应该还是可以救一下的, 一方面根据 ethtool 的结果可以看到网卡是支持 GRO 的, 另一方面 QUIC 协议自身也会避免 IP 分片. 所以应该可以救一下, 但还是要实际测一下才行. 

另外从堆栈中也可以看到这里用到了 GRO receiver, 但是还是由于 IP 分片的原因, 使得在 UDP GRO 之前不得不先重组下 IP.

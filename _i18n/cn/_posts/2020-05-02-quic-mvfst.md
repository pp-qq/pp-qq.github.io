---
title: "QUIC 与 mvfst"
hidden: false
tags: ["Postgresql/Greenplum"]
---

## 前言

这篇文章记录了我在学习 QUIC 协议以及阅读 [facebook/mvfst](https://github.com/facebookincubator/mvfst) 代码时随手记得一些笔记, 并没有多大的条理性以及可读性. 对于第三者读者而言, 老实说并没有多大的价值...

之所以对 QUIC 感兴趣, 是因为想用此替换下 Greenplum 这一 MPP 数据库的 interconnect 层. 当前 Greenplum interconnect 层主要有两种实现: TCP 以及 UDPIFC, 其中 UDPIFC 是基于 UDP 实现的可靠数据协议. 在实际生产中, 我们主要使用的是 UDPIFC, 主要是因为 GP TCP interconnect 层太费端口了. 简单来说, 对于一个具有 m 个 slice 的查询, 当其运行在具有 n 个计算节点的集群上时, 每一个计算节点都需要占用 `n * m` 个端口. 在实际生产中, m 一般取值为 100, n 一般取值为 64, 也即用户 1 条查询, 一个计算节点就需要占用 6400 个端口, 也即最多只能支持 10 并发. 而对于 UDPIFC 而言, 对于一条查询, 无论 m, n 取值多少, 每一个计算节点都只恒要 2 个端口即可.

我个人一直感觉对于一个 MPP 数据库而言, 亲自动手实现一个基于 UDP 之上的可靠数据传输协议是一个非常重而且费事不讨好的操作. 再加上我们线上就有时候能碰到由于 interconnect 层问题导致查询不能结束的各种问题. 所以就萌发了使用一个成熟的基于 UDP 实现的可靠数据传输协议来替换 GP udpifc, 最好的情况是能在占用端口与 udpifc 一致的前提下, 性能与可靠性都远超 udpifc. 所以咱就去开始调研了下 QUIC 以及相应的实现了. 

实际上再写这篇文章时, 我已经想到了另外一个法子, 仍然是使用 TCP, 而且每个计算节点占用端口数量仍能为常数值. 以及经过与阿里基础网络架构的同学沟通了下, 与 TCP 相比, QUIC 在公网场景收益比较大. 而且 quicwg 在 [17th Implementation Draft](https://github.com/quicwg/base-drafts/wiki/17th-Implementation-Draft) 中对 QUIC 性能期望值也是基于 QUIC 的 HTTP/3 性能最多比基于 TCP 的 HTTP/2 性能低上 10%. 总之就是说在 MPP 数据库计算节点互联通信这种场景下, QUIC 收益可能不比 TCP. 所以我已经放弃 QUIC 了. 但之前怎么说也看了好久的, 所以就在这里记录一下吧, 说不定哪天能用上呢==

## QUIC 概念

QUIC 相关介绍文章最完善的便当是 quicwg 出品的 [Version-Independent Properties of QUIC](https://quicwg.org/base-drafts/draft-ietf-quic-invariants.html), [QUIC: A UDP-Based Multiplexed and Secure Transport](https://quicwg.org/base-drafts/draft-ietf-quic-transport.html). 这两篇文章作为 QUIC 标准文档, 是非常注重细节地. 对于读者而言, 我个人感觉先粗略过一遍, 了解下 QUIC 的大概, 比如大致的背景, 大致的建链交互, 数据可靠性大致是咋实现的等. 之后再根据需要扣下细节. 下面主要记录下 QUIC 中相关概念:

QUIC connection id, 我感觉叫做 endpoint id 更为合适, QUIC connection 两端 endpoint 都各自有各自的 connection id. 可以把 connection id 看做是比 ip:port 更高一层的用来标识 endpoint 的设施. QUIC packet 中会存放当前 packet 目的 endpoint 的 connection id, QUIC 希望的场景是网络中各种中间设备能按照 packet 中 connection id 将 packet 路由到正确的 endpoint, 而不是根据 dstip:dstport, 这样当 endpoint 物理 ip:port 变化时, QUIC connection 仍有可能继续保持. QUIC 引入 connection id 主要是为了实现连接迁移的功能, 即允许 endpoint 改变自己的 ip:port, 并且这种改变并不会影响到已经连接的 QUIC connection. 


## QUIC 实现

QUIC 当前实现可在 quicwg [Implementations](https://github.com/quicwg/base-drafts/wiki/Implementations) 中看到, 最终我选择了调研 [facebook/mvfst](https://github.com/facebookincubator/mvfst). 另外在跟阿里基础网络同学交流时他们也说过阿里 QUIC 实现明年初也会开源. 在 mvfst 中, 可以根据 Echo sample 代码来理解 mvfst API 使用姿势. 如下简单介绍下 mvfst 所涉及到的概念, 便于加深对代码的理解. 顺便八卦一下这里之所以选择 mvfst 主要有两个原因: 一方面他是用 C++ 写出的, 从我个人经验来看, 总感觉 C 语言在开发时有点缚手缚脚的感觉, 所以便更倾向于 C++ 咯. 另外一方面是由于对 facebook 大佬们 C++ 功底的膜拜, [folly, wangle, proxygen](https://blog.hidva.com/2018/09/24/follywangleproxygen/) 这些 facebook C++ 开源项目真的是让人受益匪浅.

QuicServer 类; 用来实现 QUIC server 功能, QuicServer 在 start() 时会创建指定数目的 QuicServerWorker, 每个 worker 运行在自己的线程中. 所有 QuicServerWorker 都通过 REUSEPORT 监听着相同的地址与端口, 当然使用着不同的套接字, 每个 worker 都有着唯一的 worker id 来标示着自己. 当 QuicServerWorker 收到 Quic client 发来的建立连接请求包时, QuicServerWorker 会创建对应的用来表示 QUIC server endpoint 的 QuicServerTransport 对象, 并为该对象分配一个唯一的 connection id 来标识, 之后 QuicServerWorker 会负责该 QuicServerTransport 实例与其 client endpiont 连接的整个生命周期. 这里 QuicServerTransport connection id 中会编码 QuicServerTransport 所在 QuicServerWorker 的 worker id. 这里 QuicServerWorker 与其创建的 QuicServerTransport 共用着同一个套接字, 即 QuicServerWorker 自己的监听套接字. 

当 QuicServer 收到包时, 当 QuicServer 某个 QuicServerWorker 收到一个 QUIC packet 时, 如果该 QUIC packet 是 short header form, 那么意味着该 packet 是属于某个已存连接的, 此时 mvfst 会根据 dest connection id 提取出对应的 worker id, 之后将 packet 转发给对应的 QuicServerWorker. 若当前 packet 请求建立一个新的 QUIC Connection, 那么当前 QuicServerWorker 便会走上面所说的新建连接部分. 对于 QuicServerWorker 而言, 当其收到属于自己负责的 short packet 时, 那么其会根据 dest connection id 找到对应 server endpoint 对应的 QuicServerTransport 实例, 之后将 packet 交给 QuicServerTransport 来负责处理.

之前在使用 UDP 收发包时, 曾经遇到过由于多个 udp socket bind 在同个本地地址上, 而内核在收包处理的过程中链表查找的实现导致性能开销较大. 所以 mvfst 中应该是规避掉了这个性能问题, 毕竟 mvfst QuicServer 中绑定到相同本地地址的 udp socket 数目等同于 QuicServerWorker 数目, 也即一般为本地 CPU 的个数, 这种情况下, 链表查找的实现我理解应该不是大问题. 吧...

pacer, pacing, 目测是与流控有关. 毕竟他的位置是 quic/congestion_control/Pacer.h

Expire/reject API, 是与 partialReliability 有关, 我理解这时应该不是可靠的数据传输了.

takeover, 目测是 mvfst 引入的用来实现 Quic packet 转发的设施, 好像可以在不同 QuicServer 中转发 packet. 难道是实现了 QUIC 连接迁移那部分?
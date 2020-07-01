---
title: "GP 中的执行器"
hidden: true
tags: ["Postgresql/Greenplum"]
---


## GP 计划分发与结果汇集

CdbComponentDatabases 生命周期管理; 很显然, 我们需要在一个事务内看到一致的 CdbComponentDatabases 信息. 也即每次在事务开始时, 都应该读取 gp_segment_configuration 构造出最新的 CdbComponentDatabases, 之后在同一事务内, CdbComponentDatabases 结构保持不变. 另外考虑到 gp_segment_configuration 实际上变更地频次应该是非常低的, 一般仅当用户使用了 gpexpand 加入了新计算节点或者发生了 primary segment 失效事件使得 FTS 进行过 primary/mirror 切换时, gp_segment_configuration 才会变更. 因此 GP 中每个 backend 都会将获取到的 CdbComponentDatabases 信息保存到全局变量 cdb_component_dbs 中, 并通过 CdbComponentDatabases::fts_version/CdbComponentDatabases::expand_version 来标识着当前 CdbComponentDatabases 信息的版本. 之后在新事务开启时, 通过 expand_version/fts_version 字段来判断 gp_segment_configuration 有没有发生过变更, 若没有, 则此时继续使用上次获取到的 CdbComponentDatabases 信息. 若发生过变更, 则此时会清除上次获取的信息, 重新读取 gp_segment_configuration 获取到最新的信息. 函数 cdbcomponent_updateCdbComponents() 会在每次事务启动时调用, 用来在必要时更新 cdb_component_dbs 中保存的 CdbComponentDatabases 信息. 函数 cdbcomponent_getCdbComponents() 用来在事务期间内调用, 获取 cdb_component_dbs 中保存到的信息.

CdbComponentDatabases 同时也是一个 QE pool, 在 GP 中会将一些 IDLE QE 存放在 CdbComponentDatabaseInfo::freelist 中, 这样再下次上层调用 cdbcomponent_allocateIdleQE() 需要一个新 QE 时, GP 会优先从这些 IDLE QE 中找出满足条件的 QE 并返回, 这样避免了重复的建立连接, 认证, 初始化等逻辑.

DispatcherInternalFuncs; DispatcherInternalFuncs 这个接口类定义了用于实现 GP 计划分发与结果收集的接口. 对 DispatcherInternalFuncs 的使用需要遵循如下流程:

1.  构造一个 CdbDispatcherState 对象, 用于存放本次计划下发相关上下文信息. 通过调用 cdbdisp_makeDispatcherState() 可以构造一个 CdbDispatcherState 实例.
2.  调用 makeDispatchParams() 接口来构造其他 dispatch 接口需要使用的 context 信息. 并将 context 保存在 CdbDispatcherState::dispatchParams 中.
3.  调用 dispatchToGang() 函数来完成计划的下发, 调用 waitDispatchFinish() 来等待计划下发完成; 注意 waitDispatchFinish() 仅是等待 dispatchToGang 下发的计划已经全部发往 QD->QE 连接上. 这里并不会等待计划执行完成. 此后 QE 收到计划, 开始执行计划.
4.  调用 checkResults() 来等待所有 QE 完成计划执行, 并收集 QE 返回的执行结果. 这里结果主要是指用于 QD 构造 CommandComplete message 所需的统计值, 比如 SELECT 返回多少行, UPDATE 更新了多少行这些.

    对于 SELECT 来说, 考虑到 SELECT 返回的数据是本来就是通过 QD 返回给客户端. 用于构造 CommandComplete message 的 EState::es_processed QD 自身就有精确地信息, 不需要从 QE 处获取, 所以此时 checkResults() 的语义只是用来等待 QE 完成执行, 并不会使用这里收集到的结果.

    对于 INSERT/UPDATE/DELETE, 由于实际的 IUD 操作是在 QE 处执行的, 所以此时 QD 会收集提取 primary writer slice 对应的 QE 发来的 CommandComplete message, 之后累加所有 QE 返回的值来作为 QD 侧 EState::es_processed 的值.

    在具体实现上, checkResults() 会不停地对每一个 QE 调用 processResults() 来收集 QE 发来的结果. 根据 processResults() 实现可以看出, QD 认为 QE 会返回多个 PGresult, 因此会不停地调用 PQgetResult() 获取 PGresult, 并将 PGresult 保存在 CdbDispatchResult 中, 当 PQgetResult() 返回 NULL 时, 意味着 QE 完成了计划的执行. 此时 QD 会在 handlePollSuccess() 函数中将 QE 对应 CdbDispatchResult::stillRunning 设置为 false 表明 QE 结束运行了. 等待所有 QE 都结束时, 整个 checkResults() 也便结束了.

QD 连接 QE 使用的就是常规 libpq, 即 QD 把 QE 作为一个 postgresql server, 自己作为一个 client.

QE 的创建; 我们知道 QD 通过 libpq 发起到 primary segment 的链接来创建出 QE. 这里主要介绍下在建立连接时使用的 connection string. cdbconn_doConnectStart() 函数负责构造 connection string, 并发起到 primary segment 的建链. 这里 connection string 主要包含了如下信息:

-   gpqeid; 通过 build_gpqeid_param() 函数构造, 存放着 qe 相关信息.
-   options; 由函数 makeOptions() 构造. 其内存放着所有需要从 QD 发送给 QE 的 GUC 配置. 以及 gp_qd_hostname, gp_qd_port 即 QD 自身地址以及 listen port.

另外也可以看到这里仅指定了用户名, 并没有指定用户密码, 即 QD 发往到 QE 的建链是不需要密码认证的.

cdbconn_doConnectComplete() 会在连接建立完成之后调用, 此时会获取到 QE 返回的一些信息来初始化 SegmentDatabaseDescriptor 相应字段. 该函数也会设置 PQsetNoticeReceiver 来处理 QE 返回的 NOTICE 这些信息.

在 QE 的建链中, 若由于 primary segment 进入了 recovery mode 等而导致的建链失败, GP 会在 cdbgang_createGang_async() 函数中进行重试.

这里 QD 通过 libpq 建立到 QE 的链接只负责控制信息的传递, 不会传输数据. 如果 QD 运行的 slice 存在 motion 节点, 那么此时 QD 也是通过 interconnect 执行 motion, 即 motion 节点的执行在 QD/QE 上没有区别.

'M' 消息, QD 在发送执行计划给 QE 时, 是使用了 GP 新家的 'M' 消息, 参见 buildGpQueryString() 了解这里 'M' 消息的构造.

'Y' 消息, 在 EXPLAN ANALYZE 时, QE 通过 'Y' 消息返回自身 slice 所有 plan state 执行统计信息. 参见下面 'GP EXPLAIN ANALYZE' 了解详细内容.

## udpifc interconnect

udpifc, 是 GP interconnect 层, motion 节点将使用 interconnect 能力来完成数据交互. 在 udpifc 中有两个线程, mainthread 即 PostgresMain() 所在线程, 其充当着 sender, receiver 的角色; 另一个是 rx thread, 其负责实际的包收发工作. mainthread 与 rxthread 之间通过 XXX_control_info 这类全局数据结构通信, 如: ic_control_info, rx_control_info 等. 不同的 XXX_control_info 负责完成不同的通信需求, 比如 ic_control_info 偏向于在 mainthread 与 rx thread 传递一些控制信息. 而 rx_control_info 偏向于在 mainthread 与 rx thread 传递 receiver 数据信息, 我理解应该是 rx thread 收到数据包, 解码之后放入 rx_control_info 中, 供 mainthread 读取. 函数 InitMotionUDPIFC() 会在 QD/QE backend 启动时调用, 其负责 XXX_control_info 这类全局数据结构的初始化, udp listener socket 的创建, rx thread 的启动等工作. 对于 QE 来说, 其 udp listener port 会通过 qe_listener_port parameter 返回给 QD, 参见 cdbconn_get_motion_listener_port() 函数实现.

Motion 中的数据编码. 简单来说, 每一行数据在序列化之后都会加入个 TupSerHeader 首部, 之后再按照指定大小拆分为多个 chunk, 每个 chunk 再加个 chunk header 之后发送出去. 这里 chunk header 共 4 字节: 前 2 byte 存放着 chunk data size, 去掉 header 之后. 后 2byte 存放着 chunk type. 这里若 chunk type 为:

-   TC_WHOLE; 则表明当前 chunk 内存放着包含了 TupSerHeader 首部的完整的一行内容.
-   TC_PARTIAL_START,TC_PARTIAL_MID,TC_PARTIAL_END; 则分别表明当前 chunk 是某个完整一行内容的起始, 中间, 结束 chunk.

TupSerHeader; TupSerHeader 后面跟随的内容可能是一行序列化后的结果也可能是 list<TupleDescNode> 序列化的结果, 可根据 TupSerHeader::natts/TupSerHeader::infomask 字段取值来判断 TupSerHeader 后面跟着的内容. 若 TupSerHeader 后面跟着一行序列化后的结果, 则此时具体编码格式参见 SerializeTuple() 实现, 简单来说依次存放着 nullbits 与
数据内容, 这里数据内容采取与行在 heap file 中一样的编码.

udpifc packet; 在 udpifc 中, 所有待发送的内容总会是拼接成 packet 发送出去, 在拼接后的 packet 中, 总是以 icpkthdr 为首部, icpkthdr 类似于 QUIC 中的 dest connection id, 用来告诉接收端当前 packet 应该被送往哪个 MotionConn. packet size 最大为 gp_max_packet_size. packet 内存放着若干 chunk, 目前看来一个 chunk 不会跨 udp packet, 所以表明 chunk 最大长度的 Gp_max_tuple_chunk_size 总是小于 gp_max_packet_size. 这里 packet 的概念与 QUIC 中 packet 概念很是相似, GP udpifc 中每一个 packet 也各有一个 seq, 基于此来实现了 packet 的 ACK, 重传, 以及可靠的数据传输.

Motion sender, udpifc 发包; GP 中 motion send 有两种方法: direct send, SendChunk; direct send 是指 motion 将待发送的行直接序列化到 MotionConn::pBuff 中, 等待后续 SendChunk 方法被使用时发送. SendChunk 则是 motion 将待发送的行序列化后存放在 TupleChunkList 中, 然后调用 SendTupleChunkToAMS() 来发送, SendTupleChunkToAMS() 最终会调用 SendChunkUDPIFC() 来完成发包工作. SendChunkUDPIFC() 简单来说便是将接受到的 chunk 拷贝到 MotionConn::pBuff 中, 当 pBuff 空间不足时, 将 pBuff 拼接成 packet 发送出去. GP 会优先使用 direct send, 当无法使用 direct send, 比如当 boardcase motion 或者 pBuff 指向空间不足时, 便会使用 send chunk 这一方法. SendChunkUDPIFC() 在发送 packet 时, 使用 ICSenderSocket 这个套接字: `sendto(ICSenderSocket, data, receiver_ip_port)`.

udpifc 收包; 在 udpifc 中, 当当前 QE 是个 receiver QE 时, 其会启动线程 rx thread, 由该线程来接受 sender QE 发来的数据, 并 ACK 这些数据, 之后 rx thread 会把这些数据放在对应的 MotionConn 中, 递交给 main thread 来消费. 该线程入口函数 rxThreadFunc(). rxThreadFunc() 逻辑简单来说便是不停地 poll(UDP_listenerFd), 在 poll() 表明有数据到来时, 调用 recvfrom(UDP_listenerFd) 读取一个 packet, 之后生成相应的 ACK packet 并返回给 sender QE.

## tcp interconnect

tcp interconnect, 考虑到 tcp 自身已经是一个可靠数据传输协议, 所以 GP 中 tcp interconnect 实现比较清晰明了. 在 tcp interconnect 中, 每个 QE 在启动时会随机监听一个端口, 即 TCP_listenerFd. 之后 sender 在执行 execMotionSender() 时, 最终会调用 SendChunkTCP() 来完成一个 chunk 的发送. 这个过程简单来说 sender QE 会 connect receiver QE listener port, 之后通过这个 tcp 连接完成数据的传输. 参见 [issue10048](https://github.com/greenplum-db/gpdb/issues/10048) 这里可以使用 SO_REUSEPORT 来降低端口的使用.

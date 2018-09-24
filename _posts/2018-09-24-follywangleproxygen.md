---
title: "folly, wangle, proxygen 库"
tags: [C++]
---

# folly

关于 folly 库的学习, 按需学习即可, 结合 [Overview](https://github.com/facebook/folly/blob/master/folly/docs/Overview.md) 文档以及自身需求直接学习相应模块即可. 某些情况下, 某些模块有文档但未在 Overview 中链接, 这些文档一般是在模块同级目录的 md 文件内或者就是源码中了. 大部分情况下, C++ 编程涉及到的基础操作都能在 folly 中找到, 如果 Overview 中没有你需要的功能, 可以试着在源码中搜索一下. 下面将会零零散散地介绍 folly 实际使用中遇到地一些点.

`folly::EventBaseObserver::loopSample(int64_t busyTime, int64_t idleTime)` 中 `idleTime` 是一次 loop 中, `epoll_wait()` 所花费时间; `busyTime` 是 `epoll_wait()` 返回之后到下次 loop 开始前的时间. 具体可以参考 `EventBase::loopBody` 源码. 这里留神负责更新 `startWork_` 的 `bumpHandlingTime()` 在一次 loop 中可能会被多次调用, 但只有第一次调用有效, 之后均是 noop.

SharedMutex; 这里有个 upgrade mutex 概念, 还是第一次接触到; 这个概念在 [boost](https://www.boost.org/doc/libs/1_58_0/doc/html/thread/synchronization.html#thread.synchronization.mutex_concepts.upgrade_lockable) 中介绍地更为全面; folly shared mutex 这里完全没介绍什么是 upgrade mutex, 可能大佬们认为这是个众所众知的玩意儿吧.

# wangle

关于 wangle 的学习使用, wangle 文档不是很齐全, 反正当时我是看完 wangle 下面所有的 md 文档之后仍有很多不得其解, 所以不得不直接上手看源码了; 而且由于没有一个全局认知, 刚开始看会很迷糊, 不过会越来越有种拨开云雾见光明的感觉. 下面会零零散散地介绍实际使用中遇到的一些点, 以及 wangle 中一些全局概念, 争取能对 wangle 全局认知建设有点帮助.

Handler, HandlerContext, Pipeline 概念; 其中 Handler 负责实际的数据转换处理操作, 比如将 Read in 转换为 Read out, 将 Write in 转换为 Write out; 以我们实际使用为例, Read in 是 `std::unique_ptr<folly::IOBuf>` 存放着 pb 序列化后的字节流, Read out 是 pb 逆序列化后对应的业务类型, handle 要做的就是利用 pb `ParseFromArray` 进行逆序列化;

HandlerContext 则是将 Handler 串起来. 比如某个 Handler 转换完类型之后通过 HandlerContext 将转换后的结果扔给下一个 Handler 的 HandlerContext; 而下一个 HandlerContext 则将收到的结果扔给其自身的 Handler.

Pipeline 负责将一组 HandlerContext 有序地串起来. Pipeline 将 HandlerContext 分为 in, out 两个方向; 其中 in HandlerContext 类似与回调, 由 wangle 框架在合适的时机主动调用; out HandlerContext 由用户主动调用.

Transport 按我理解可以将其视为一个特殊的 Handler; 其将数据写到网络, 以及从网络中读取数据; 相当于是 wangle 程序与网络的边界设备. 如 AsyncSocketHandler 就是一个 Transport. Transport 一般位于 Pipeline 中的最低端, 用户调用 `Pipeline.write` 时, 数据会依次经过多个 Handler 处理最终交于 Transport 发出. 当 Transport 从网络中收到数据时, 数据也会依次经过多个 Handler 处理.

ClientBootstrap; 关于 ClientBootstrap 内存管理, 这个只能深入源码来进行梳理了, 话说回来异步编程加内存管理真是让人头大啊==. 这里以如下代码举例:

```CPP
ClientBootstrap<TelnetPipeline> client;
client.group(std::make_shared<folly::wangle::IOThreadPoolExecutor>(1));
client.pipelineFactory(std::make_shared<TelnetPipelineFactory>());

auto pipeline = client.connect(SocketAddress(FLAGS_host,FLAGS_port)).get();
// 此时将当前线程, 即 client 所在线程记为线程 A; EventBase 所在线程记为线程 B.
// Eventbase 线程只会存储原生指针, 即 B 中会存放一些原生指针, 这些指针指向着 client 中的子对象.
// 因此这里不能在线程 A 中直接析构 client; 否则线程 B 中的指针会变成野指针. 正确做法是析构之前先 close, 如下:
pipeline->close().get();
// 此后线程 B 中不会再有任何访问 client 及其内部成员的操作. 可以放心释放.
```

# proxygen

proxygen, http server, 是我测试过性能表现最为优异, 书写最为舒适的 c++ http server 框架. 不过当时只是简单地以 `echo BLOG.HIDVA.COM` 作为业务逻辑来测试的. 测试框架还包括 brpc http server, golang net.http, nginx, nginx 是直接通过在 nginx conf 中 `return 200 BLOG.HIDVA.COM;`, beast async server. 这里 golang net.http 性能是超过 proxygen 的, 只不过不属于 c++.

关于 proxygen 的学习, 就和 wangle 一样, 文档还是有限, 需要结合源码一起来搞. 不过好在 proxygen 文档中给出了 proxygen 全局认知, 倒不会有 wangle 那么吃力了. 下面将会零零散散地介绍 proxygen 实际使用中遇到地一些点.

RequestHandler; 顾名思义, 用来处理 request 的 handler, 其接收并处理用户发来的 request.  ResponseHandler, 用来处理 response 的 handler, 其接受并处理 server 发来的 response, 比如把 response 序列化之后返回给用户. RequestHandler 内有一个 ResponseHandler 成员 `downstream_`, RequestHandler 会把生成的 response 发送给 `downstream_` . 同样 ResponseHandler 也有个 RequestHandler 成员 `upstream_`, 我始终觉得 `upstream_` 放在 ResponseHandler 这里怪怪的, 直接放在 Filter 类中, 我觉得更合适. Filter 继承自 RequestHandler, 其会接受下游发来的请求, 并对其稍作处理之后转发给上游; Filter 同时也继承 ResponseHandler, 其会接受上游发来的 response, 并对其稍作处理之后转发给下游.



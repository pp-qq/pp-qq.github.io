---
title: "UDP 与 GRO, GSO"
hidden: false
tags: ["Postgresql/Greenplum"]
---

不知道是不是因为 GSO, GRO 是 Linux 新增特性的原因, 在 google 上找了半天都没有找到一篇详细的介绍如何使用 GSO/GRO 的文章, 最后从 Linux 内核中与 GSO/GRO 相关的 [testcase](https://github.com/torvalds/linux/blob/master/tools/testing/selftests/net/udpgro.sh) 中窥到了一丝信息, 总结如下. 另外由于 GSO 是 5.0 新加的特性, 而且手头上也没有 linux 5.0 的机器, 所以如下总结并未实际验证过...

GSO, 关于 GSO 的原理, 参见 [UDP segmentation offload](https://blog.cloudflare.com/accelerating-udp-packet-transmission-for-quic/) 了解. 简单来说, 在业务发送 UDP 数据包时, 为了避免 IP 层对包进行分片, 一般会将待发送的 UDP 数据包的大小控制在 `MTU - sizeof(udp header) - sizeof(ip header)` 以下. 这里之所以要避免 IP 层分片, 主要是额外的 IP 层分片与重组有时候会导致不少问题, 比如同属于同一个上层数据包的多个 IP 分片在发送时, 任一分片的丢失都将导致整个上层数据包的重传. 再比如接收端设备为了完成 IP 重组不得不分配额外的内存等资源来存放管理当前已经收到的 IP 分片, 如果发送端发送大量的 IP 分片, 那么将会导致接收端用于暂存分片包的缓冲区被打满, 更糟糕的是如果发送端的一个数据包对应的分片数目过多, 那么接收端可能会一直无法完成一次完整的分片重组. 举个极端例子: 假设接收端 R 最多可以缓存 4 个 IP 分片包, 现在有发送端 S 发送了 1 个 8000 字节长度的 UDP 数据包, 在 MTU 为 1500 的情况下, 这个 UDP 数据包将拆分为 6 个分片. 很显然这时 R 将一直无法完成数据包的重组导致数据发送一直失败. 实际上我们在线上也确实遇到过类似的例子, 参见 [IP 分片数目过多导致重组失败]({{site.url}}/2020/05/04/mtu-query-block/#ip-分片数目过多导致重组失败).

UDP GSO, 简单来说就是内核在接受到应用程序发来的一堆待发送的应用数据 D 之后, 会按照应用程序之前告诉内核的配置, 将接收到的 D 拆分为若干块, 之后为每一块加上 UDP header 封装成一个 UDP 数据包发送出去. 后面以 gsosize 来表示这里上层应用告诉内核的每块最大大小. 我们以 QUIC 协议为例, 当上层应用希望发送 2k 字节内容时, 在不使用 GSO 的情况下, QUIC 实现一般会将内容拆分存放到 2 个 QUIC packet 中, 之后对应着 2 个 UDP 数据包发送出去, 对应到伪代码如下. 很显然这涉及到两次 sendto 系统调用:

```c
// 将待 1k 应用数据拼接成 QUIC packet 之后调用 sendto 发送
sendto(fd, "quic short packet header + frame header + [0, 1k) app data");
// 发送后 1k 应用数据
sendto(fd, "quic short packet header + frame header + [1k, 2k) app data");
```

在使用 GSO 之后, 应用需要首先通过 SOL_UDP/UDP_SEGMENT 告诉内核 gsosize 取值, 之后应用按照 gsosize 完成数据的组装:

```c
// 分片1 总长度要限制为 gsosize.
part1 = "quic short packet header + frame header + app data"
// 分片2 存放着剩下的应用数据, 其大小可小于 gsosize.
part2 = "quic short packet header + frame header + app data"

// 之后将分片1, 2 拼接成一个大缓冲区, 然后一次 sendto 调用完成数据发送.
// 除最后一个分片的中间分片的大小要固定为 gsosize.
sendto(fd, part1 + part2);
// 这里内核内部会按照 gsosize 再次将数据拆分为 '分片1', '分片2', 然后分为两个 UDP 数据包发送.
```

所以也可以看到 GSO 对于接收端来说是透明的. 毕竟 GSO 后发送的每一个 UDP 数据包都是一个完整的, 单独的数据包. 

UDP GRO, 最开始我一直没有搞懂 UDP GRO, 单纯地从字面上看 GRO 是说内核会尽量在协议的最底层将收到的多个数据包拼接在一起之后向上传递, 也即上层看到的只是一个数据包. 对于 TCP 中的 GRO, 这里内核在拼接数据包时会遵循 TCP 的语义, 比如内核在收到了三个 TCP 数据包, TCP 序号分别为 33, 34, 35, 那么此时内核会将三个 TCP 数据包拼接成一个之后向上层协议传递, 这时还是可以理解的. 但是对于 UDP 而言, 大部分使用 UDP 作为传输协议的应用都依赖着 udp packet 边界的性质, 比如 QUIC short packet 中, packet header 中并没有长度字段, 完全是使用了 udp header 中的长度字段来隐式地指定了 short packet 的大小. 那这时 GRO 将多个 UDP 数据包拼接成一个之后, 上层应用还咋用这个边界信息来区分? 

这个真的是 google 上找了半天, 现实中问了一圈大佬都没搞清楚, 知道最后快要弃疗的时候看到了内核关于 GRO/GSO 的单测 case 才大概了解了 UDP GRO 是如何拼接成, 很简单就是**仅当** udp 数据包具有相同大小时, 才会被拼接成一个大的 udp 数据包, 同时内核还会告诉上层应用原始 udp 数据包的长度信息. 这样上层应用在需要的时候也可以根据这个信息来确定 udp packet 边界. 如 [udpgso_bench_rx.c](https://raw.githubusercontent.com/torvalds/linux/master/tools/testing/selftests/net/udpgso_bench_rx.c) 所示, 当使用了 UDP GRO 之后, 应用程序的收包姿势如:

```c
static int recv_msg(int fd, char *buf, int len, int *gso_size)
{
	char control[CMSG_SPACE(sizeof(uint16_t))] = {0};
	struct msghdr msg = {0};
	struct iovec iov = {0};
	struct cmsghdr *cmsg;
	uint16_t *gsosizeptr;
	int ret;

	iov.iov_base = buf;
	iov.iov_len = len;

	msg.msg_iov = &iov;
	msg.msg_iovlen = 1;

	msg.msg_control = control;
	msg.msg_controllen = sizeof(control);

	*gso_size = -1;
	ret = recvmsg(fd, &msg, MSG_TRUNC | MSG_DONTWAIT);
	if (ret != -1) {
		for (cmsg = CMSG_FIRSTHDR(&msg); cmsg != NULL;
		     cmsg = CMSG_NXTHDR(&msg, cmsg)) {
			if (cmsg->cmsg_level == SOL_UDP
			    && cmsg->cmsg_type == UDP_GRO) {
				gsosizeptr = (uint16_t *) CMSG_DATA(cmsg);
				*gso_size = *gsosizeptr;
				break;
			}
		}
	}
	return ret;
}
```

当 recv_msg() 返回后, `[buf, len)` 中存放的可能是多个 UDP 数据包拼接之后的内容, 此时 `*gso_size` 存放着原始 UDP 数据包的大小. 所以对于应用来说, 他可以以 `*gso_size` 来切分 buf 然后处理每一个数据包, 即中间位置的数据对应的原始 UDP 数据包大小总是为 `*gso_size`, 最后剩下的数据对应 UDP 数据包大小可能会小于 gsosize. 所以 QUIC 的实现 facebook/mvfst 处理 GRO 的姿势也就可以理解了:

```c++
void QuicServerWorker::onDataAvailable(
    const folly::SocketAddress& client,
    size_t len,
    bool truncated,
    OnDataAvailableParams params) noexcept {
  if { 
    // 未使用 GRO.
  } else {  
    // 此时使用了 gro.  params.gro_ 存放着内核返回的 GRO 大小.
    size_t remaining = len;
    size_t offset = 0;
    while (remaining) {
      if (static_cast<int>(remaining) > params.gro_) {
        // 如上介绍所示: 位于中间位置的数据对应原始 UDP 数据包大小总是为 gro
        auto tmp = data->cloneOne();
        tmp->trimStart(offset);
        tmp->trimEnd(len - offset - params.gro_);

        offset += params.gro_;
        remaining -= params.gro_;
        handleNetworkData(client, std::move(tmp), packetReceiveTime);
      } else {
        // 最后位置的数据对应原始 UDP 数据包大小可能不足 gro.
        data->trimStart(offset);
        remaining = 0;
        handleNetworkData(client, std::move(data), packetReceiveTime);
      }
    }
  }
}
```
---
title: "Storm ShellBolt 死锁"
hidden: false
tags: [Storm]
---

Storm ShellBolt 存在死锁的风险. 在 storm 中, ShellBolt 与其子进程通过标准输入/标准输出, 即文件描述符 0, 1 来通信, 同时也会读取标准出错, 即文件描述符 2 中的内容, 并将读取到的内容通过 storm 的日志系统输出到日志中. 具体如下:

```java
public void writeBoltMsg(BoltMsg msg) throws IOException {
    serializer.writeBoltMsg(msg);
    // Log any info sent on the error stream
    logErrorStream();
}

public void writeSpoutMsg(SpoutMsg msg) throws IOException {
    serializer.writeSpoutMsg(msg);
    // Log any info sent on the error stream
    logErrorStream();
}

public void writeTaskIds(List<Integer> taskIds) throws IOException {
    serializer.writeTaskIds(taskIds);
    // Log any info sent on the error stream
    logErrorStream();
}

public void logErrorStream() {
    try {
        while (processErrorStream.available() > 0) {
            int bufferSize = processErrorStream.available();
            byte[] errorReadingBuffer = new byte[bufferSize];
            processErrorStream.read(errorReadingBuffer, 0, bufferSize);
            ShellLogger.info(new String(errorReadingBuffer));
        }
    } catch (Exception e) {
    }
}
```

从上面代码中可以看到, ShellBolt 依赖的 ShellProcess 总是在成功将数据写入文件描述符 0 之后才会读取文件描述符 2 中的内容. 另外这里文件描述符 0, 1, 2 底层都是管道. 所以存在这么一个场景, 在某一时刻文件描述符 0, 2 对应的管道使用的缓冲区已满; 导致 ShellBolt 子进程在写文件描述符 2 时会阻塞, 而无法消费文件描述符 0 中的内容; 同时 ShellBolt 在写入文件描述符 0 时会阻塞而无法消费文件描述符 2 中的内容; 导致 ShellBolt 与其子进程将一直阻塞.


我们在实际工作中遇到了 ShellBolt 死锁这种场景(要不然也不会发现是吧). 在 topology 运行中, 统计表明总是有 0.96% 左右的 spout tuple 的 ack 未被及时地调用, 这个并不是很符合预期. 根据 storm 日志来看, 自定义的 Scheduler 逻辑仅被执行了一次, 发生在 topology 被提交时, 这就表明了在 topology 运行过程中并没有 task fail, 这就杜绝了 "在 spout tuple 被执行期间, 某些 bolt task fail 导致部分 tuple 未被 ack 导致 spout tuple 也无法被及时地 ack." 这种可能性(真是越来越令人脑壳疼了啊==). 这里简单介绍一下 topology 的架构, 如下:

{% mermaid %}
sequenceDiagram
    participant S as ShellBolt
    participant W as Worker.py
    participant F as FunctionExecutor

    S ->> W: pipe(Work 进程的 fd 0)
    W ->> S: pipe(Work 进程的 fd 1)
    W ->> S: pipe(Work 进程的 fd 2)
    W ->> F: pipe
    F ->> W: pipe
    S -->> F: pipe(Function 进程的 fd 0)
    F -->> S: pipe(Function 进程的 fd 1)
    F -->> S: pipe(Function 进程的 fd 2)
{% endmermaid %}

此时 Worker.py 所处进程的文件描述符 0, 1, 2 均被重定向到用来与 ShellBolt 通信的管道上. 在 Worker.py 的 `storm.BasicBolt.process()` 被调用时, 其会 fork 创建一个子进程 FunctionExecutor, 在 FunctionExecutor 中执行由第三方编写的逻辑, 为了方便管理以及安全起见, FunctionExecutor 会使用如下代码来完成初始化:

```py
# FunctionExecutor 自身也可能会创建子进程, 所以这里创建一个新进程组.
os.setpgrp()
resource.setrlimit(resource.RLIMIT_CPU, config.get().worker_cpu_rlimit())
# 或许这里应该执行切换为普通用户, 参见 seteuid()
```

可以看出这里未对 FunctionExecutor 的文件描述符 0, 1, 2 进行任何处理, 所以 FunctionExecutor 的文件描述符 0, 1, 2 继承自 Worker.py 进程, 所以实际上 FunctionExecutor 与 ShellBolt 也是可以通信的(记住这一个隐患!).


结合 strace 命令, 在 storm 集群中找到了几个 FunctionExecutor 进程, 这些进程一直阻塞在 `write(2, ...)` 调用上! 事实上 FunctionExecutor 并未显式地使用文件描述符 0, 1, 2; 但是**感谢** python 的 PyMySQL 以及 urllib3:

```
/PATH/lib/python2.7/site-packages/pymysql/cursors.py:166: Warning: (1287, u"'@@tx_isolation' is deprecated and will be removed in a future release. Please use '@@transaction_isolation' instead")

  result = self._query(query)

/PATH/lib/python2.7/site-packages/urllib3/connectionpool.py:858: InsecureRequestWarning: Unverified HTTPS request is being made. Adding certificate verification is strongly advised. See: https://urllib3.readthedocs.io/en/latest/advanced-usage.html#ssl-warnings

  InsecureRequestWarning)
```

所以至此情况就会明了了, 由于 PyMySQL, urllib3 这些包的 Warning 导致了 FunctionExecutor 往标准出错文件描述符 2 中输出了大量内容, 导致 2 底层管道的缓冲区满, 导致 FunctionExecutor 被阻塞在 `write(2, ...)` 上, 导致 Worker.py 也因此阻塞以至于无法消费其标准输入文件描述符 0 中的内容, 导致了 ShellBolt 也因此阻塞在 `writeBoltMsg()` 上, 导致了文章开头的场景出现. 这里的修复方案就是在初始化 FunctionExecutor 的逻辑中加入对文件描述符 0, 1, 2 的处理, 具体如下:

```py
# 如果不这么做, 那么 Storm ShellBolt 就存在死锁的风险, 而且确实遇到过 ShellBolt 死锁.
nullfd = os.open(os.devnull, os.O_RDWR)
os.dup2(nullfd, 0)
os.dup2(nullfd, 1)
os.dup2(nullfd, 2)
os.close(nullfd)

# FunctionExecutor 自身也可能会创建子进程, 所以这里创建一个新进程组.
os.setpgrp()
resource.setrlimit(resource.RLIMIT_CPU, config.get().worker_cpu_rlimit())
# 或许这里应该执行切换为普通用户, 参见 seteuid()
```

实际上 Worker.py 在设计时考虑到了 FunctionExecutor 可能会出现的各种异常情况, FunctionExecutor 执行超时也在考虑之内, 只不过这里超时时间设置地有点长(20h+). 即 Worker.py 会在 20h 之后检测到 FunctionExecutor 超时, 然后 Worker.py 就会强行 `kill -9` 掉 FunctionExecutor 所在的进程组.

另外很早就在 icafe(百度内部需求管理系统) 上创建相应的卡片表明需要处理一下 PyMySQL, urllib3 的 warning.

![icafe 卡片][20180120164559]

但一直没有来得及处理, 没想到这个居然会导致那么大的因果==!

[20180120164559]: <{{site.url}}/img/icafewarnings.jpeg>

---
title: "linux perf 介绍"
hidden: true
tags: [开发经验]
---

事件发生, 事件回调. Linux 内核会监测进程运行中发生的各种事件, 并对外暴露事件回调能力, 即在事件发生时通知上层应用, 应用按需完成自身逻辑开发. 以 perf state 为例, 在其注册的事件回调逻辑中, 便是简单地更新一下事件发生计数器. 而对于 perf record 则除了更新事件发生累加器还需要在固定的周期采集事件发生时 CPU 上的堆栈, 从而便于开发者根据此信息确定程序的热点.

Events, Linux 支持多种事件源. software events, 内核自身行为产生的事件, pure kernel counters, 比如: context-switches, minor-faults. PMU hardware events or hardware events, the source of events is the processor itself and its Performance Monitoring Unit (PMU). hardware events and hardware cache events. The perf_events interface also provides a small set of common hardware events monikers. On each processor, those events get mapped onto an actual events provided by the CPU, if they exists, otherwise the event cannot be used. tracepoint events, implemented by the kernel ftrace infrastructure.

sub-Events. An event can have sub-events (or unit masks). On some processors and for some events, it may be possible to combine unit masks and measure when either sub-event occurs. Finally, an event can have modifiers, i.e., filters which alter when or how the event is counted. 我理解就是某些事件具体子事件, 开发者可以通过 unit mask 来指定具体哪个子事件. 以 cycles 为例, cycles:u 指的是用户空间下发生的 cycles, cycles:k 则指的是内核空间下.

Event 的指定, Events are designated using their symbolic names followed by optional unit masks and modifiers. Event names, unit masks, and modifiers are case insensitive. Modifiers allow the user to restrict when events are counted. Events can optionally have a modifier by appending a colon and one or more modifiers. Modifiers 列表见原文列表. All modifiers above are considered as a boolean (flag). Event 也可以通过 the hexadecimal parameter code 指定, 如 `perf stat -e r1a8`, 这种方式硬核了一点.

multiplexing and scaling events; 整个事件我理解应该是这样的, CPU PMU 支持应用通过某种设置告知自己需要监测哪些事件, 之后 CPU 便会监测这些事件并更新相应的寄存器来表示事件发生次数. 因此若 CPU PMU 寄存器只有两个, 但是用户却指定了 4 个 PMU 事件, 那么内核便会使用多路复用的方式来完成这些事件的监听. 具体多路复用的方法参考原文.

The perf tool can be used to count events on a per-thread, per-process, per-cpu or system-wide basis. 当 per-process 时, perf 也会自动监听子进程的行为. 一般常用的便是 per-thread 与 per-process 了. 相关控制选项: `-a`, 指定监听所有 CPU. `-i`, 表明不主动监听子进程. `-C 0,2-3`, 指定仅监听 CPU0, CPU2, CPU3. `-p ${pid}`, use perf to attach to an already running process, What determines the duration of the measurement is the command to execute. Even though we are attaching to a process, we can still pass the name of a command. It is used to time the measurement. Without it, perf monitors until it is killed. Also note that when attaching to a process, all threads of the process are monitored. Furthermore, given that inheritance is on by default, child processes or threads will also be monitored. `-t ${tid}`, attach a specific thread within a process. By thread, we mean kernel visible thread. In other words, a thread visible by the ps or top commands.

## event

这里介绍一些特定 event 的详细信息.

cycles; 即 clock cycle, A clock cycle on a processor is an electronic pulse in which a processor can complete a basic operation such as retrieving a specific data point. Most computational operations actually require multiple clock cycles. Faster processors can complete more clock cycles per second than slower processors. the cycle event does not count when the processor is idle.


## perf stat

perf state keep a running count during process execution. 此时 the occurrences of events are simply aggregated and presented on standard output at the end of an application run. 可以通过 `-e` 来指定采集的事件列表, 不指定 `-e` 时采集什么事件需要看具体版本.

## perf record/perf report

perf record, 负责数据采集, 生成 perf.data 文件. perf reprot, perf annotate 负责分析 perf.data. perf report/perf annotate 在分析采集数据时并不一定需要位于 perf record 采集数据的机器. 但我不清楚这里如何处理符号等操作, 所以最好还是在同一个机器把.

perf record 使用的是 event-based sampling, 即当指定的时间发生指定的次数之后, 内核便会进行一次采样, What gets recorded depends on the type of measurement. This is all specified by the user and the tool. But the key information that is common in all samples is the instruction pointer. 按我理解这里的实现可能是内核根据 perf 用户指定的值设定一次寄存器, 之后每当事件发生时, CPU 便会自减寄存器, 当寄存器值到达 0 时便触发一次中断. 内核收到中断之后便会进行采样. Interrupt-based sampling introduces skids on modern processors. That means that the instruction pointer stored in each sample designates the place where the program was interrupted to process the PMU interrupt, not the place where the counter actually overflows, i.e., where it was at the end of the sampling period. In some case, the distance between those two points may be several dozen instructions or more if there were taken branches.

这次事件次数的大小不能超过 the number of bits in the actual hardware counters, 否则 the kernel silently truncates the period in this case. 一般来说小于 `2**31` 总是安全的.

perf record 在 event-based sampling 基础上又实现了另外一种触发 sampling 的方式, 即 the average rate of samples/sec. The perf tool defaults to the average rate. It is set to 1000Hz, or 1000 samples/sec. That means that the kernel is dynamically adjusting the sampling period to achieve the target average rate.

`-F ${numbers}`, To specify a custom rate, it is necessary to use the -F option. `-c ${numbers}`, To specify a sampling period, instead, the `-c` option must be used. 

Perf record 所用的事件默认是 cycles, 不过可以通过 `-e` 指定其他的 event.

perf report 还是有点不太直观地, 到不如直接看 FlameGraph 生成的火焰图更直观.

如下介绍一些从 `perf record --help/perf report --help` 中看不到的知识:

`perf report -g`; 可用来展示特定函数在不同调用者处的耗时, 比如 funcA 被 funcB, funcC 调用, 在某次运行时, funcA 自身 CPU 耗时 200s, 其中 150s 来自于 funcB 对 funcA 的调用, 另 50s 来自于 funcC 的调用. 那么 perf report -g 展示效果可能如下:

```
funcA
    0.75 funcB
    0.25 funcC
```

`perf report -g` 后可以指定额外的参数(即 type)来控制具体展示效果.

-   flat; 表明平铺地形式展示. 我理解应该是把 funcA, funcB, funcC 放在同一级别下:

    ```
            funcA
    0.75    funcB
    0.25    funcC
    ```

-   graph/fractal 使用树形结构展示, 即 funcB/funcC 在 funcA 的下一级. 在 graph 中, funcB/funcC 函数名前的百分比是绝对值, 等同于 `--percentage absolute`. 而 fractal 意味着 funcB/funcC 函数名前的百分比使用的是相对值, 等同于 `--percentage relative` 效果.

`perf report -g` 的 min 参数, 我理解是指当占比低于 min 的函数调用不需要展示. 比如 `perf report -g graph,0.5` 意味着耗时占比低于 50% 的函数不需要展示出来. 意味着这时只会展示:

```
funcA
    0.75 funcB
    // funcC 耗时低于 0.5, 所以被忽略了.
```

## 参考 

[perf wiki tutorial](https://perf.wiki.kernel.org/index.php/Tutorial)
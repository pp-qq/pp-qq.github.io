---
title: 开发经验-2
tags: [开发经验]
---

# MOCK 也是个好东西啊

mock 是什么? 以及为什么需要 mock, 参见 [ForDummies](https://github.com/google/googletest/blob/master/googlemock/docs/ForDummies.md) 的解答: 
>   When you write a prototype or test, often it's not feasible or wise to rely on real objects entirely. A mock object implements the same interface as a real object (so it can be used as one), but lets you specify at run time how it will be used and what it should do (which methods will be called? in which order? how many times? with what arguments? what will they return? etc).

mock object 与 fake object 这两个概念的区别是什么. Fake objects have working implementations, but usually take some shortcut (perhaps to make the operations less expensive), which makes them not suitable for production. An in-memory file system would be an example of a fake. Mocks are objects pre-programmed with expectations, which form a specification of the calls they are expected to receive. Mock allows you to check the interaction between itself and code that uses it.

mockito, java 常用的 mock 框架. powermock, PowerMock is a framework that extends other mock libraries such as Mockito with more powerful capabilities. 一方面 PowerMock uses a custom classloader and bytecode manipulation to enable mocking of static methods, constructors, final classes and methods, private methods, removal of static initializers and more. By using a custom classloader no changes need to be done to the IDE or continuous integration servers which simplifies adoption. 另一方面 Developers familiar with the supported mock frameworks will find PowerMock easy to use, since the entire expectation API is the same, both for static methods and constructors. PowerMock aims to extend the existing API's with a small number of methods and annotations to enable the extra features. 亲测在 PowerMockRunner 下, Powermock 对 static class/method 的 mock 仅在其所处的 `@Test` 方法内有效. 理所当然的一个结果.



# Prometheus 真是个好东西

首先介绍一下 Prometheus 中的一些基本概念. 

metric, The metric name specifies the general feature of a system that is measured. 比如对于 http server 来说 当前已收到请求总数 http_request_total 就是一个 metric.

labels; 按我理解 labels 是 metric 的属性(或者称为维度), 以 http_request_total 为例, 它可以具有 http_method, http_path 等维度. any given combination of labels for the same metric name identifies a particular dimensional instantiation of that metric. 在使用 prometheus client library 更新某个带有 labels 的 metrics 时, 需要指定所有的 label 取值, 不然 client library 会报错的. While labels are very powerful, avoid overly granular metric labels. The combinatorial explosion of breaking out a metric in many dimensions can produce huge numbers of timeseries, which will then take longer and more resources to process. As a rule of thumb aim to keep the cardinality of metrics below ten, and limit where the cardinality exceeds that value. 按我理解是说一个 metric 对应的 time series 数目不宜过多, 比如不应该超过 10 个. ~~本来我以为这句话是说 metric 的 label 不宜过多.~~.

time series, Prometheus fundamentally stores all data as time series: streams of timestamped values belonging to the same metric and the same set of labeled dimensions. 所以 Every time series is uniquely identified by its metric name and a set of key-value pairs. 在 prometheus 中, 通过 `<metric name>{<label name>=<label value>, ...}` 来作为 time series notation. 如 `http_request_total{method="POST", handler="/messages"}`. 

Samples; Samples form the actual time series data. Each sample consists of: a float64 value, a millisecond-precision timestamp.

Prometheus target; 使用 Prometheus  client libraries 来采集自身 metrics 的应用程序. 这里是 Prometheus server 主动从 Prometheus target 处采集数据, 而不是 target 主动推给 server, 按我理解怕是为了更方便地控制采集频率防止 prometheus server 压力过大吧.

push gateway, a push gateway for supporting short-lived jobs; push gateway 也是一个普通的 prometheus target, short-lived job 可以随时将自己的 metrics push 到 prometheus gateway 上, 之后 prometheus server 会将数据从 push gateway 上拉取到本地.

prometheus exporters. There are a number of libraries and servers which help in exporting existing metrics from third-party systems as Prometheus metrics. This is useful for cases where it is not feasible to instrument a given system with Prometheus metrics directly (for example, HAProxy or Linux system stats). 按我理解就是将目前第三方已有的 metric 系统接入到 prometheus 中, 比如对于 jvm 而言, 其自身会维护 gc 相关的 metric, 利用 jvm exporter 可以将这些 gc metric 导出到 prometheus 中, 从而方便后续可视化观看以及分析.

metric types; These are currently only differentiated in the client libraries (to enable APIs tailored to the usage of the specific types) and in the wire protocol. The Prometheus server does not yet make use of the type information and flattens all data into untyped time series. 参见[prometheus官方文档](https://prometheus.io/docs/concepts/metric_types/)了解目前 prometheus 支持哪些 metric types. 按我理解, prometheus client lib 行为应该就类似一个 kv storage, key 为 metrics + labels 组合, value 为 metrics value. 即对于同一 metrics + label 组合, 任一时刻下只会存放着一个值. prometheus client lib 也不会存放着 application 设置该值时的时间戳, 时间戳应该是由 prometheus server 从 prometheus target 拉取数据时生成的. 对于 Histogram, Summary 类型的 metric, 此时 client lib 会维护一个指定时间窗口内的直方图, 在 prometheus server 采集 target 时, client lib 会根据直方图信息生成相应的值返回给 prometheus server.



## 深入了解 protobuf

pb 的常规使用套路, 很简单, 就是先根据业务需求定义 pb 文件, pb 文件中描述了有哪些 message, 每个 message 有哪些字段, 每个字段是什么类型, 是否是必需的等字段元信息. 之后利用 pb 提供的编译器生成相应语言的代码. 完事后利用生成代码中的接口来将 message 对应着的结构体序列化为字节串, 或者从字节串反序列化出来 message 结构体.

pb 另一种不常使用的套路是利用 DynamicMessage 等 pb 设施来动态生成 pb 文件, 这方面网上一大堆, 需要时可以看一下. DynamicMessage 大致使用姿势以及能实现的效果如下所示:

```java
// 动态定义 message.
ProtobufUtils.SchemaBuilder builder = ProtobufUtils.newSchemaBuilder(messageName);
builder.addField(ProtobufUtils.Label.OPTIONAL, ProtobufUtils.Type.TYPE_BOOL, fieldName1, fieldNo1);
builder.addField(ProtobufUtils.Label.OPTIONAL, ProtobufUtils.Type.TYPE_INT32, fieldName2, fieldNo2);
builder.addField(ProtobufUtils.Label.REQUIRED, ProtobufUtils.Type.TYPE_INT64, fieldName3, fieldNo3);
Descriptors.Descriptor descriptor = builder.build();

// 利用上述动态定义的 message 来反序列化
DynamicMessage msg = DynamicMessage.parseFrom(descriptor, bytes);
Map<Descriptors.FieldDescriptor, Object> fields = msg.getAllFields();
// 等...
```

pb 序列化采用的编码格式, 具体参考[pb 官方文档](https://developers.google.com/protocol-buffers/docs/encoding). 简单来说, pb 序列化生成的二进制串就是 kv, kv, kv 组合, 其中 k 为 fieldno, field wire type 先或运算再采用变长编码之后生成的产物, 这里 fieldno 就是在定义 pb message 时指定的 field number; 而 wire type 用来简单表明 value 的类型以及 value 是如何编码的. v 为 field 的值, 其编码格式由 wire type 指定.



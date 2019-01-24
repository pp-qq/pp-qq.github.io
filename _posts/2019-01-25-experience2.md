---
title: 开发经验-2
tags: [开发经验]
---


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



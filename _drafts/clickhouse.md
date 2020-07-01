
## 存储

存储整体结构看文章中那两张图就行. 目测 ck 是不支持 index scan 的. 只支持 seqscan, 只不过他这里会充分利用粗糙集信息来做 block 级别过滤. 以及利用 parallel scan 来最大化扫描并发能力. 从 CK 的表现不错来看, 感觉也侧面认证了 GP 大佬们一直不鼓励使用 index 不是没有道理的

![]({{site.url}}/assets/ck-storage-1.jpeg)

![]({{site.url}}/assets/ck-storage-2.png)

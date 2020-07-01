## nginx

io_uring 不光可以用于文件 IO. 也可以用于网络编程, 集成到 nginx 之后, 使得 nginx 在长连接下性能提升了不少. 具体数据如下:

connection=1000，thread=200, 测试server上不同worker数目性能。worker数目在8以下时，QPS有20%左右的提升。随着worker数目增大，CPU不成为瓶颈，收益逐渐降低。
server单worker，测试client端不同连接数性能(thread取默认数2）。可以看到单worker情况下，500个连接以上，QPS有20%以上的提升。从系统调用数目上看，io uring的系统调用数基本上在event poll的1/10以内。

## rocksdb

开启 io_uring 后 MultiRead()的 IO 性能提升约 500%（相比不开启 io_uring 实现），而 io_uring 在开启 IOPOLL 和 SQPOLL 模式之后性能继续提升了约 5% ~ 10%；io_uring IOPOLL 模式下时延抖动降低到约 50%，其他模式下时延抖动也有降低。部分场景下 IOPOLL 带来的性能提升并不明显，甚至有出现性能变差的例子. SQPOLL 模式带来的性能提升也很小.

io_uring 对象较重, 尽量复用. io_uring 为写操作带来的提升比读更明显.

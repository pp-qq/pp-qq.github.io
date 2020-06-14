
apr_allocator_t, apr_memnode_t; apr_memnode_t, 表示着一块内存. 而 apr_allocator_t 则类似于 memnode pool. 遗憾的是 apr_allocator_t 不允许用户自定义 alloc, free 函数, 其内部总是使用 malloc()...

apr_pool_t, 行为与语义完全与 PG memcontext 一致.

apr_abortfunc_t(); 当 apr pool 在分配内存失败时会调用该函数. 可参考 apr_palloc() 中对该字段的使用. 该函数返回值目测会被忽略.


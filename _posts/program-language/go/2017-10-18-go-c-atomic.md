以下文章纯属个人理解. 


在学习 C++11 中新增的原子操作以及相应的 memory model 之后; 再看 golang 中的 `sync/atomic`, 可以发现 `sync/atomic` 提供的是纯粹的原子操作, 等同于 c++11 中的 `std::memory_order_relaxed`. 所以 [The Go Memory Model][20171018131724] 在介绍 golang memory model 并未提及到 atomic 可以实现同步语义. 


按我理解 C++11 中的原子操作自带各种同步语义是由于目前硬件限制决定的: CPU 在实现缓存机制时无法做到完全透明, 所以开发者在开发时不得不考虑 CPU 缓存所带来的各种副作用, 这由此导致了 C++11 的原子操作除了操作是原子的之外, 还自带了同步光环. 所以从长远来讲我觉得 golang 中的原子操作才是正宗的原子操作. 


同样由于 golang 的原子操作没有同步光环, 导致无法实现各种无锁数据结构, 曾一度以为很是可惜. 后来意识到在 golang 中或许其实并不需要无锁数据结构, 主要是因为当一个 goroutine 被 block 之后, golang 会调度其他 goroutine 运行, 所以程序整体并没有 block. 另外大多数无锁数据结构都是基于 CAS 以及无脑循环重试实现, 如下:

```C++
typedef struct {
	int key;
	struct node *next;
} node;


typedef struct {
	node *head;	
} list


void list_insert(list *l, int k) {
	node *n = new node(k);

	do {
		node *prev = MCASRead(&l->head);
		node *curr = MCASRead(&prev->next);

		while (curr->key < k) {
			prev = curr;
			curr = MCASRead(&curr->next);			
		}

		n->next = curr;
	} while (!MCAS(1,&prev->next, curr, n));

	return ;
}
```
以上代码参考 [Concurrent Programming Without Locks][20171018133327]. 所以在 golang 中使用锁或许并发性能更好一点.




[20171018131724]: <https://golang.org/ref/mem>
[20171018133327]: <http://www.cl.cam.ac.uk/research/srg/netos/papers/2007-cpwl.pdf>

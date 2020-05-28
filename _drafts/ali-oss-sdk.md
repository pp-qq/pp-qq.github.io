aos_list_s; 表示双链表的 node. 任何需要加入到双链表的对象都需要将 aos_list_s 作为自身成员之一.

aos_list_entry(ptr, type, member); aos_list_s 一般是某个 struct 成员, 这个宏用来根据 aos_list_s 成员的指针来得到其所在 struct 起始地址. 这里 ptr 即 aos_list_s 成员的地址, member 则是 type 中类型为 aos_list_s 的成员.

aos_buf_t; start, end 指定的容量; pos, last 指定的是实际内容所在的位置.


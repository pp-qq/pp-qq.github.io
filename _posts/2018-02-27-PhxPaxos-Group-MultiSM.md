---
title: PhxPaxos Group 多状态机另外一种实现思路
---

目前 [PhxPaxos](https://github.com/Tencent/phxpaxos) 中的 Group 支持挂载多个状态机. 并且除了用户显式挂载的状态机之外, PhxPaxos 也会根据配置往 Group 上挂载一些内部状态机, 比如负责 master 选举的 MasterStateMachine 等.

但目前由于 MasterStateMachine, SystemVSM 等内部状态机各自都会构建自己的 checkpoint 以及从 checkpoint 中恢复状态. 所以如果用户在自己的 StateMachine::Execute() 逻辑中依赖了 MasterStateMachine, SystemVSM 的状态就会导致 Execute() 的执行出现不一致的问题; 具体参考 [PhxPaxos 中如何才能更严格的使用 Master 功能?](https://github.com/Tencent/phxpaxos/issues/112).

按照 paxos made live 中的说法, 一个 Group 应该仅配置一个 StateMachine 即可. Group, 也即 multi paxos 确定的命令序列会依次交给 StateMachine 执行. 只不过此时该 StateMachine 要负责处理成员变更, master 选举, 业务自身逻辑等问题, 会导致开发难度大, 用户接入困难. 所以 PhxPaxos 支持一个 Group 挂载多个 StateMachine; 成员变更, master 选举等功能作为一个个内部状态机实现并由 PhxPaxos 根据配置判断是否需要挂载; 用户自身只需要实现负责处理其业务逻辑的状态机即可. 但这时挂载到同一个 Group 下的多个状态机的 checkpoint 的构建与恢复就是一个问题; 尤其是在 StateMachine 之间存在状态依赖时; 就像上面所述.

这里介绍了实现多状态机的另一种思路, 即通过"栈"的方式实现多状态机, 将多个状态机组织成状态机栈. 这时 checkpoint 的构建由栈底状态机驱动, 栈底状态机在时机合适构建好 checkpoint 之后, 会将该 checkpoint 向栈顶方向传递, 每一层 StateMachine 构建完自身的 checkpoint 之后将其追加到下层生成的 checkpoint 之前然后向栈顶方向传递, 栈顶状态机会负责持久化最终的 checkpoint. 在从 checkpoint 中恢复时, 则将 checkpoint 从栈顶到栈底方向传递, 每层 StateMachine 提取出自己的 checkpoint 信息并利用该信息恢复自身的状态. 这里根据状态机之间的依赖关系来组织状态机栈, 若 StateMachine A 依赖于 StateMachine B 的状态, 那么 B 应该在 A 之上.

这时一些负责处理常见功能的状态机, 比如负责 master 选举的状态机, 负责实现 membership 变更都的状态机可以事先实现; 用户只需要实现负责处理自身业务逻辑的状态机; 然后根据状态机之间的依赖情况来组织状态机栈.

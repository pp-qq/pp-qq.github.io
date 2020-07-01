---
title: "SQLAlchemy Reference"
tags: [读后感, python]
---

## Overview

1.  没讲啥有用的内容, 除了以下注明的.
2.  可以安装 C 扩展来提高性能, 具体如何安装参见原文. 

3.  之前一直不是很理解 ORM 中, 当一个 ORM 对象取字段时, 是直接 select 么? 后来发现在创建 ORM 对象会使用一条 select 取出所有字段然后赋值给这个 ORM 对象, 之后从 ORM 对象拿字段都不会再 select 而是从内存中取. 关于此时对象的字段何时刷新, 参考[这篇文章][2]

## SQLAlchemy Core

### SQL Statements and Expressions API

#### Column Elements and Expressions


```py
class sqlalchemy.sql.expression.TextClause
```


```py
sqlalchemy.sql.expression.text(text, bind=None, bindparams=None, typemap=None, autocommit=None)
```

1.  参见原文. 这里简单说一下. `text()` 构造一个 `TextClause` 对象, 其中  bindparams, typemap, autocommit 参数已经过时所以可以不用管. bind 参数参见原文, 一般不会用到. text 字符串, the text of the SQL statement to be created. use `:<param>` to specify bind parameters; they will be compiled to their engine-specific format. For SQL statements where a colon is required verbatim, as within an inline string, use a backslash to escape. 如下:

    ```py
    t = text("SELECT * FROM users WHERE name='\:username'")  # '\' 转义.
    ```

2.  实验表明, bind parameters 不能用于表名. 

### Engine and Connection Use



#### Engine Configuration

1.  参见原文的图了解, Engine, Pool, Dialect 各自的位置.

    Where above, an Engine references both a Dialect and a Pool, which together interpret the DBAPI’s module functions as well as the behavior of the database. 按照我的理解, Pool 负责管理 DBAPI connection. 而 Dialect 则是 the system SQLAlchemy uses to communicate with various types of DBAPIs and databases, 为什么需要 Dialect 呢, 以 mysql 为例, 假设其存在两个 DBAPI 实现: db1, db2, 其中 db1 使用 rows 来表示被影响的行数, 而 db2 使用 affectrows 来表示被影响的行数; 所以这时候就需要 Dialect 来负责管理这些具体的细节. 
    
##### Engine Creation API

```py
sqlalchemy.create_engine(*args, **kwargs)
```

1.  其语义, 参数的顺序参考原文. 注意 URL 的格式讲解在 'Engine Configuration' 的开始以及 'Database Urls' 中也有描述. 支持的 keyword argument 可以参考原文.

    `create_engine()` 并不会立刻创建连接, 采用了延迟初始化之类的套路.

2.  `PARAM: kwargs`; 参见原文, 注意以下参数的设置: `pool_recycle`.

    -   `max_overflow`; 参见原文. 该选项最好设置为 -1, 表明无限制. 在项目女娲开发中遇到过情况: 参数设置: `pool_size=5, max_overflow=10`, 然后在某个时间点, 由于并发量较大导致从 engine.pool 中拿不到链接导致 Timeout 异常.

##### Pooling

1.  默认 Pool 的实现取决于 dialect, 如当 dialect 是 mysql 时是 QueuePool, 而当 dialect 是 sqlite 时不是 QueuePool, 反正不知道是啥.

##### Custom DBAPI connect() arguments

1.  在 Engine 中, Pool 会通过调用 DBAPI 的 connect() 来获取连接, 参见原文了解如何向 DBAPI.connect() 传递参数.

#### Working with Engines and Connections

##### Basic Usage

1.  Engine 对象与子进程, 参考原文. 其实很好理解, fork 出来的子进程中的 Engine 与父进程的 Engine 共享连接, 然而大部分数据库都不支持这种共享连接的方式, 所以此时会出错.

    但是当 Engine 的 Pool 实现是 NullPool 等类似实现时是可以跨进程的, 因为此时总会创建一个新链接. 但是建议总不要跨进程使用 Engine 对象.
    
##### Using Transactions

1.  参见原文了解如何使用事务.
2.  可以使用 with 简化, 未看. 因为 with 子句还不会用呢我.

###### Nesting of Transaction Blocks

1.  嵌套事务; 参见如下代码了解嵌套事务的场景:

    ```py
    # method_a starts a transaction and calls method_b
    def method_a(connection):
        trans = connection.begin() # open a transaction
        try:
            method_b(connection)
            trans.commit()  # transaction is committed here
        except:
            trans.rollback() # this rolls back the transaction unconditionally
            raise
    
    # method_b also starts a transaction
    def method_b(connection):
        trans = connection.begin() # open a transaction - this runs in the context of method_a's transaction
        try:
            connection.execute("insert into mytable values ('bat', 'lala')")
            connection.execute(mytable.insert(), col1='bat', col2='lala')
            trans.commit()  # transaction is not committed yet
        except:
            trans.rollback() # this rolls back the transaction unconditionally
            raise
    
    # open a Connection and call method_a
    conn = engine.connect()
    method_a(conn)
    conn.close()    
    ```
    
    我的建议是不要使用嵌套事务! 参见 [附录][1] 以及本节介绍的对嵌套事务的实现机制, 可以看出这里三种实现机制对于 'a commit, b rollback' 的场景实现结果各不同, 而且差异不小.
     
2.  本节未细看.

##### Understanding Autocommit

1.  mysql autocommit 实现猜测; 默认情况下 mysql 打开了 autocommit, 也即每一条 sql 语句 mysql 都会当做一个事务来执行. 当关闭 autocommit 之后, 所有的 sql 语句都会在一个事务下执行, 直至使用了 commit/rollback 创建了一个新的事务, 此时使用默认的事务隔离级别. 如下实验验证了本猜测:

    ```shell
                create table i(i int)
    set autocommit = 0;   |                                 # 0
    select * from i;      |                                 # 1
                          |    start transaction;           # 2
                          |    insert into i values(1);     # 3
    select * from i;      |                                 # 4
                          |    commit                       # 5
    select * from i;      |                                 # 6
    ```
    
    如上, '# 1, 4, 6' 标识的 select 都在一个事务(下称 A)下执行; 而 '# 2, 3, 5' 标识的是另一个事务(下称 B); 根据 mysql 的默认事务隔离级别可知, A 的三次 select 都一直返回空.

2.  根据 PEP249 可知, 其不允许 autocommit. a transaction is always in progress, providing only rollback() and commit() methods but no begin(). 

3.  sqlalchemy 的 autocommit 并不会 autocommit select 语句, 所以会出现如上所述的情况(如下代码所示), 建议不要使用 sqlalchemy 的 autocommit 机制:

    ```shell
    $ python
    Python 2.7.12 (default, Nov 19 2016, 06:48:10) 
    [GCC 5.4.0 20160609] on linux2
    Type "help", "copyright", "credits" or "license" for more information.
    >>> import sqlalchemy
    >>> sqlalchemy.__version__
    '1.1.6'
    >>> engine = sqlalchemy.create_engine('mysql://root:mysql!@#$%@localhost/study')
    >>> engine
    Engine(mysql://root:***@localhost/study)
    >>> con1 = engine.connect()
    >>> con2 = engine.connect()
    >>> def select(conn):
    ...     rs = conn.execute("select * from i")
    ...     for r in rs:
    ...             print r
    ... 
    >>> select(con1)
    (1L, 2L)
    (12L, 23L)
    >>> tx = con2.begin()
    >>> con2.execute("insert into i values(3, 4)")
    <sqlalchemy.engine.result.ResultProxy object at 0x7f1fc3c3db10>
    >>> select(con1)
    (1L, 2L)
    (12L, 23L)
    >>> tx.commit()
    >>> select(con1)
    (1L, 2L)
    (12L, 23L)
    >>> 
    ```
    
    参考 Connection.execution_options() 的 autocommit 属性, 可以实现 mysql 默认的 autocommit 语义.
    

##### Connectionless Execution, Implicit Execution

1.  Connectionless Execution 其定义参考原文. 其实现机制可以参考 `Engine.execute()`.
2.  原文还讲了一大堆 implicit execution 这种乱七八糟的概念, 未细看.

##### Engine Disposal

1.  讲了 `Engine.dispose()` 的由来(好大一通废话); 使用场景; 实现细节, 如如何处理 checkout 这种链接.

##### Using the Threadlocal Execution Strategy

1.  按照我的理解, strategy 指定了 connectionless execution 时如何获取 connection. 当 strategy 取 plain 时, 是直接调用 engine.connect() 获取链接; 当 strategy 是 threadlocal 时, 将从 thread local data 中取出连接.

    本来我以为这个是一个很好的特性, 因为这样类似 DBUtils 的 PersistentDB, 效率应该不错. 但是 sqlalchemy 官方建议不要使用 threadlocal 所以就未细看.

##### Connection / Engine API

```py
class sqlalchemy.engine.Connection(engine, connection=None, close_with_result=False, _branch_from=None, _execution_options=None, _dispatch=None, _has_events=None)
```

1.  Connection, which is a proxy object for an actual DBAPI connection. 

2.  `execute(object, *multiparams, **params)`; 按照我的理解, 该函数的实现逻辑如下:

    ```py
    cursor = dbapi_conn.cursor();
    cursor.execute(object)
    return ResultProxy(cursor)
    ```
    
    可以参考 PEP249 了解一些 Cursor 的语义.
    
    一些小细节可以参考原文

3.  `close()`; 关闭当前 Connection 对象, 将 Connection 内的 dbapi connection checkin 到 Engine 的 Pool 中. 此后不同的 Pool implement 会执行不同的操作. 对于 QueuePool 而言, 其会调用 dbapi.connection.rollback(), so that any transactional state or locks are removed, and the connection is ready for its next usage. 而对于 NullPool 而言, 其可能会调用 dbapi.connection.close() 直接关闭掉链接.

4.  `execution_options()`; 参见原文.

    -   autocommit; 若 autocommit 为 True, 则此时 engine 实现了 mysql autocommit 的语义, 既当未明显指定创建一个事务时, 每一条 SQL 语句之后都会自动 COMMIT. 

5.  `begin()`; 参见原文.

```py
class sqlalchemy.engine.Engine(pool, dialect, url, logging_name=None, echo=None, proxy=None, execution_options=None)
```


1.  Engine 对象类似于 golang 的 `sql.DB` 对象. 线程安全, 整个进程内, 一个数据库只需要一个 Engine 对象即可.

2.  `connect(**kwargs)`; 此时会从 Pool 中 checkout 一个 dbapi connnection, 然后基于此创建一个 Connection 对象. 所以 connect() 返回的是一个专用链接. 

3.  `execute(statement, *multiparams, **params)`; 是一个 connectionless execution, 按照我的理解, 其实现逻辑如下:

    ```py
    conn = GetConn() # 根据不同的 strategy 获取连接
    result_proxy = conn.execute(stmt)
    result_proxy.close_on_result = True # 当 result_proxy close 时也会 close conn.
    return result_proxy 
    ```

```py
class sqlalchemy.engine.ResultProxy(context)
```

1.  ResultProxy 是 dbapi cursor wrapper. 
2.  其中的 cursor 何时被 close; 见下:

    -   A ResultProxy that returns no rows, such as that of an UPDATE statement (without any returned rows), releases cursor resources immediately upon construction.
    
    -   A ResultProxy that returns rows, The DBAPI cursor will be closed by the ResultProxy when all of its result rows (if any) are exhausted. 或者手动调用 ResultProxy.close() 关闭.
    
    -   Python GC 时.
    
3.  `close_on_result`; 首先 ResultProxy 对象肯定保存了其对应的 Connection 对象. 当 ResultProxy.close() 调用时, 若 `close_on_result` 为 `True`, 则此时也会调用 ResultProxy.connection.close(). 该属性主要用于实现 connectionless execution. 
4.  `first()`; 参见原文. 原文未指定 fetchall(), fetchone(), first() 这类接口返回结果是个什么类型, 按照 pep249 的说法是一个 sequence.

5.  `close()`; 见以上描述.

    'Changed in version 1.0.0' 这一节啥意思呢, 参见原文, 我的理解如下: 在 sqlalchemy 早期版本, 在 fetchxxx() 消耗完所有 rows 的时候, sqlalchemy 内部为了释放 dbapi 的资源(如 cursor, connection)会调用 `close()`. 但是 `close()` 另外一个语义 'discard ResultProxy object' 导致了这之后对 ResultProxy 的访问会导致异常. 因此在 v1.0.0 版本, sqlalchemy 单独抽取出了 `_soft_close()` 接口, 并在需要释放 dbapi 资源时调用 `_soft_close()`. 因此 v1.0.0 之后, 即使已经消耗完所有的 row, 在调用 fetchxxx() 也不会异常, 只是返回个空集.

```py
class sqlalchemy.engine.result.RowProxy
```

1.  表示一行记录.
2.  按照我的实验, `RowProxy` 行为类似 `namedtuple`. 如:

    ```py
    for i, j in engine.execute('SELECT c1, c2 from t1')
        print i, j
        
    for i, in engine.execute('SELECT c1 from t1')
        print i
        
    for i in engine.execute('SELECT c1 from t1')
        print i  # 此时 i 是 RowProxy!
        print i[0]
        print i['c1']
    ```
    
    `RowProxy` 中的列名完全来自于 mysql server 返回结果. 如下:
    
    ```
    mysql> select t1.i from t1;
    +------+
    | i    |
    +------+
    |    1 |
    |    2 |
    +------+
    2 rows in set (0.00 sec)
    
    mysql> select t1.i as `t1.i` from t1;
    +------+
    | t1.i |
    +------+
    |    1 |
    |    2 |
    +------+
    2 rows in set (0.00 sec)

    >>> engine.execute('select t1.i from t1').first().keys()
    [u'i']
    >>> engine.execute('select t1.i as `t1.i` from t1').first().keys()
    [u't1.i']
    ```
    
```py
class sqlalchemy.engine.Transaction
```

1.  参见原文.

#### Connection Pooling

##### Dealing with Disconnects

1.  参见原文, 我们应该总是使用这里提供的机制来避免出现 'MySQL server has gone away' 的问题. 

### Core API Basics

#### Events

1.  SQLAlchemy includes an event API which publishes a wide variety of hooks into the internals of both SQLAlchemy Core and ORM. 按照我的理解, 这里的 event 也就是 hook 的另一种叫法了么.

##### Targets

1.  见原文.

-   Q1: 根据原文可知, 在调用 `listen()` 时有多种机制来指定 target, 比如 `listen(Engine, 'connect', ...)` 时 target 就是 `Engine.pool`. 很神奇, 如何实现的呢?
-   A1: 按照我的理解, 大概是查表, 参见 `PoolEvent` 的说明.

## Dialects

### MySQL

#### Unicode

参见原文

## 参考

1.  [reference][0]

0.  注, 以上仅列举出来了哪些已经看过的章节, 未看过的章节不与列出. 


[0]: <http://docs.sqlalchemy.org/en/rel_1_1/contents.html> "Release: 1.1.6,  Release Date: Feburary 28, 2017"

[1]: <https://segmentfault.com/a/1190000002411193> "网页剪报/MySQL的嵌套事务实现"

[2]: <http://www.cnblogs.com/fengyc/p/5369301.html> "网页剪报/SQLAlchemy 对象缓存和刷新"

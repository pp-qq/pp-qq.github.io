---
title: ::std::reference_wrapper 文档
---

## reference_wrapper

```c++
template <class T>
class reference_wrapper;
```
*   包装引用的模板类.`reference_wrapper<T> obj`可以看作`T`类型的左值引用,并且通过`operator=`,
    复制构造函数可以将`obj`绑定到不同的`T`类型对象上,这也是该包装类存在的原因.如:
    
    ```c++
    int a = 33;
    int b = 33;
    
    /* 至此 int_ref 只能与 a 绑定在一起!无法更改 int_ref 的绑定对象.
     * int_ref = b;此时等同于 a = b;
     */
    int &int_ref = a; 
    
    /* 此时 int_ref_wrapper 与 a 绑定在一起;但可以更改 int_ref_wrapper 的绑定对象.如:
     * int_ref_wrapper = b;此时 int_ref_wrapper 与 b 绑定在一起,而不是 a = b!
     */
    auto int_ref_wrapper = std::ref(a);
    ```

### 构造函数

```c++
reference_wrapper(T& x);
```

*   构造一个`reference_wrapper`对象,与`x`引用的对象绑定在一起.

```c++
reference_wrapper(const reference_wrapper<T>& other);
```

*   构造一个`reference_wrapper`对象,与`other`引用的对象绑定在一起.

### operator =

```c++
reference_wrapper& operator=(const reference_wrapper<T>& other);
```

*   将当前对象与`other`绑定在一起.

### operator T&

```c++
operator T& () const;
```

*   将当前对象转化为`T&`类型.参见`get()`.

### get

```c++
T& get() const;
```

*   获取当前对象所绑定的对象.

### operator ()

```c++
template <class... ArgTypes>
typename std::result_of<T&(ArgTypes&&...)>::type 
operator() (ArgTypes&&... args) const;
```

*   若当前对象绑定的对象是一个可调用对象,则可以使用`operator()`来调用该函数.
*   若当前对象不是可调用对象,则不存在该函数.


## cref

```c++
template <class T>
std::reference_wrapper<const T> cref(const T& t);

template <class T>
std::reference_wrapper<const T> cref(std::reference_wrapper<T> t);
```
*   helper 函数.

## ref

```c++
template <class T>
std::reference_wrapper<T> ref(T& t);

template <class T>
std::reference_wrapper<T> ref(std::reference_wrapper<T> t);
```
*   helper 函数.

---
title: C++标准头文件 type_traits 文档
---

## add_lvalue_reference

```c++
template <class T>
struct add_lvalue_reference;
```

### type

*   `std::add_lvalue_reference<T>::type`;若`T&`合法,则为`T&`,否则为`T`.注意此时可能存在
    引用折叠.


## add_rvalue_reference

```c++
template< class T >
struct add_rvalue_reference;
```

### type

*   `std::add_rvalue_reference<T>::type`;若`T&&`合法,则为`T&&`;否则为`T`,注意此时可能存
    在引用折叠.如:
    
    ```c++
    std::add_rvalue_reference<int&>::type ==> int&&& ==> int&;
    ```

## is_constructible

```c++
template <class T, class... Args>
struct is_constructible;
```
    
### value

*   `std::is_constructible<...>::value`;指定了是否可以通过`Args`参数来构造`T`类型对象.该
    值的逻辑如下:

    ```c++
    if (T 是函数类型)
        value = false; // 很显然,函数类型无法构造函数对象
    else if ( T (std::declval<Args>()...) 已经定义并且是 public ) // 注意,权限要求!
        value = true;
    else
        value = false;
    ```

*   Access checks are performed as if from a context unrelated to T and any of 
    the types in Args.如若定义为`T(std::declval<Args>()...)`,但是该构造函数是`T`的`private`
    成员,则`value`仍为`false`!
    

#### DEMO

*   `std::declval`的影响

    ```c++
    struct X {
        X() {}
        X(const X &x) = delete;
        X(X &&x) {}
    };

    int
    main(int argc,char **argv)
    {
        std::is_constructible<X,X>::value == 1; // 经过 std::declval,变为 X(X&&).  
        std::is_constructible<X,X&>::value == 0;
        std::is_constructible<X,X&&>::value == 1;
        return 0;
    }
    ```

*   Access Check

    ```c++
    struct X {
        X() = default;
    private:
        X(int) {}
    public:
        X(int,int) {}

        void f()
        {
            X x{33};
            printf("%s: %d\n",__func__,std::is_constructible<X,int>::value);     // 0!因为对应的构造函数是 private.
            printf("%s: %d\n",__func__,std::is_constructible<X,int,int>::value); // 1
            return ;
        }
    };

    int
    main(int argc,char **argv)
    {
        X x;
        x.f();
        printf("%s: %d\n",__func__,std::is_constructible<X,int>::value);    // 0     
        printf("%s: %d\n",__func__,std::is_constructible<X,int,int>::value);// 1
        return 0;
    }
    ```
    
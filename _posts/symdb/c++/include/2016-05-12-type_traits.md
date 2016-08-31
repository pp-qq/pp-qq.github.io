---
title: type_traits 头文件介绍
---

## is_unsigned

```cpp
template <class T>
struct std::is_unsigned;
```

*   用来判断`T`是否是无符号类型,具体判断逻辑如下:

    ```cpp
    if (T is an arithmetic type)
        if (T(0) < T(-1))
            T 是无符号类型;
        else
            T 不是无符号类型;
    else
        T 不是无符号类型;
    ```

    若`T`是无符号类型,则`std::is_unsigned<T>::value`的值为`true`;否则为`false`.


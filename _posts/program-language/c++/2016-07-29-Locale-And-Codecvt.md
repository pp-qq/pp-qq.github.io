---
title: C++ Locale Codecvt 介绍
---


## 参考 

*   [en.cppreference.com][1]

## locale

```cpp
class locale;
```

*   An object of class std::locale is an immutable indexed set of immutable facets.
    其实可以把 `locale` 理解为 `std::unordered_map`, 其中 `key_type` 为 `std::locale::id`, 
    `value_type` 为 `std::local::facet`,而且 `locale` 对象在构造完成之后不在可变,即只
    读,同时 `locale` 内的 `facet` 也是只读.

    Internally, a `locale` object is implemented as-if it is a reference-counted pointer to an  
    array (indexed by std::locale::id) of reference-counted pointers to facets.即大概可以将
    `locale` 看作如下类型:

    ```cpp
    using locale = shared_ptr<std::unordered_map<id, shared_ptr<facet>>;
    ```

    `locale` 如何管理其内的 `facet`, 如下用伪代码表示逻辑:
    
    ```cpp
    // 当 locale 发现对其内的 facet 引用计数变为 0 时
    if (facet.初始引用值 == 0)
        delete static_cast<std::locale::facet*>(f);
    else
        不作任何处理;
        
    // 关于什么是'初始引用值'参见 facet 的介绍.
    ```

## locale::id

*   The class `std::locale::id` provides identification of a locale `facet`, 即 `locale::id` 用于
    唯一表示 `facet`, 如下在实现一个新的 `facet` 时,必须确保其内有 `static std::locale::id id`(通
    过继承方式得来也行),否则将会编译错误(而且从编译输出的错误中可以看出不少信息).

    之后在将一个 `facet` 对象插入到 `locale` 对象中时, `locale` 对象就会使用这个 `facet` 类的 `id`
    来索引该类的对象.Facets with the same id(当 Facets 类型一致时,就会 same id) belong to the same 
    facet category and replace each other when added to a locale object. 

## locale::facet

*   `std::locale::facet` is the base class for facets. 就是一个很普通的抽象类咯.

### 构造函数

```cpp
explicit facet( std::size_t refs = 0 );
```

*   creates a `facet` with starting reference count `refs`. If `refs` is non-zero, the facet will not be 
    deleted when the last locale referencing it goes out of scope.

    这里就是初始引用值这个概念需要注意一下.
    
## codecvt

```cpp
template< 
    class InternT, 
    class ExternT, 
    class State> 
class codecvt;
```

*   Class `std::codecvt` encapsulates conversion of character strings, including wide and multibyte, 
    from one encoding to another. Four standalone (locale-independent) specializations are provided 
    by the standard library:

    -   `std::codecvt<char, char, std::mbstate_t>`;
    -   `std::codecvt<char16_t, char, std::mbstate_t>`
    -   `std::codecvt<char32_t, char, std::mbstate_t>`
    -   `std::codecvt<wchar_t, char, std::mbstate_t>`
    
    以上几种 specializations 明确提供了一个 encoding 到另一个 encoding 的转换,与 locale 无关.
    
    In addition, every `locale` object constructed in a C++ program implements its own (locale-specific) 
    versions of these four specializations. 即在不同的 `locale` 对象中,其内的 `codecvt<char32_t, char, std::mbstate_t>`
    可能执行不同的 encoding 转换,这里取决于具体的 `locale`.
    
    一般不直接使用该类,而是使用 `wstring_convert`.
    
## wstring_convert

```cpp
template< class Codecvt,
    class Elem = wchar_t,
    class Wide_alloc = std::allocator<Elem>,
    class Byte_alloc = std::allocator<char> >
class wstring_convert;
```

*   Class template `std::wstring_convert` performs conversions between byte string `std::string` and wide string 
    `std::basic_string<Elem>`, using an individual code conversion facet `Codecvt`. `std::wstring_convert` assumes 
    ownership of the conversion facet.

    该类就是一个简单的工具类,可以参考 [llvm-m][0] 来了解其内功能, 以下是一些值得注意的地方:
    
    1.  `wstring_convert` 内部保存着 `Codecvt *cvt_` 数据成员,并且在 `wstring_convert` 中总会 `delete cvt_`.


## codecvt_utf8

```cpp
template< 
    class Elem,
    unsigned long Maxcode = 0x10ffff,
    std::codecvt_mode Mode = (std::codecvt_mode)0 > 
class codecvt_utf8 : public std::codecvt<Elem, char, std::mbstate_t>;
```

*   用于 `std::wstring_convert` 的 `Codecvt` 参数,在 UTF-8 与 UTF-16,UTF-32 之间进行转化.

*   `TPARAM: Maxcode,Mode`;参考[原文][1].

## Demo

*   关于 C++ 中对中文标点的处理的一个 DEMO

<script src="https://gist.github.com/pp-qq/51d6039cbf3db7877c1c642a15de5030.js"></script>

[1]: <http://en.cppreference.com/w/cpp/locale/codecvt_utf8>    
[0]: <https://github.com/llvm-mirror/libcxx>




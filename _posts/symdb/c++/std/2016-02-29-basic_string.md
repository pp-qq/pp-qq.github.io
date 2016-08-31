---

title: ::std::basic_string 文档
DeclarationLocation: '<string>'

---


## basic_string

```c++
template< 
    class CharT, 
    class Traits = std::char_traits<CharT>, 
    class Allocator = std::allocator<CharT>> 
class basic_string;
```

*   存放与维护着类`char`对象序列.内部在对`CharT`对象进行操作时完全不依赖于`CharT`对象本身或
    者其提供的运算符重载方法.所有对`CharT`对象的操作都通过`Traits`来进行.

*   内部是连续存储区间;即与`CharT[]`类型相似.
    

### append

```c++
basic_string& append(const CharT* s,size_type count);
```

*   将`[s,s + count)`追加到当前字符串末尾.
*   `PARAM:s,count`;标准上未指定其合法性质;但是在看源码时,发现其必须是以下2种情况之一:
    -   `[s,s + count)`是当前字符串对象的一部分.
    -   `[s,s + count)`与当前字符串对象所占有的存储区域没有任何交集.


### assign

```c++
basic_string& assign(const CharT* s,size_type count);
```

*   `PARAM:s,count`;标准上未指定其合法性质;但是在看源码时,发现其必须是以下2种情况之一:
    -   `[s,s + count)`是当前字符串对象的一部分.
    -   `[s,s + count)`与当前字符串对象所占有的存储区域没有任何交集.

    

### find

```c++
size_type find(const CharT* s, size_type pos = 0) const;
```
*   查找`s`指向的字符串在当前字符串`[pos,size())`范围内第一次出现的位置.若存在,则返回`s`第一个
    字符在当前字符串中的下标;若不存在,则返回`basic_string::npos`.
*   `PARAM:s`;若`s`是空串,若`pos`参数合法,则返回`pos`;否则返回`basic_string::npos`.
*   `PARAM:pos`;其合法范围:`[0,size()]`;若`pos`不合法,则该函数总是返回`basic_string::npos`.
*   **NOTE**;主要是注意一下空串的情形.    

```c++
size_type find(const CharT* s, size_type pos, size_type count) const;
```
*   查找`[s,s + count)`在当前字符串`[pos,size())`范围内第一次出现的位置.若存在,则返回`s`第
    一个字符在当前字符串中的下标;若不存在,则返回`basic_string::npos`.
*   `PARAM:pos`;其合法范围:`[0,size()]`;若`pos`不合法,则该函数总是返回`basic_string::npos`.




**转载请注明出处!谢谢**

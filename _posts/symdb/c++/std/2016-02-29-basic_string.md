---

title: basic_string 使用说明
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

### find

```c++
size_type find(const CharT* s, size_type pos = 0) const;
```
*   查找`s`指向的字符串在当前字符串`[pos,size())`范围内第一次出现的位置.若存在,则返回`s`第一个
    字符在当前字符串中的下标;若不存在,则返回`basic_string::npos`.
*   `PARAM:s`;若`s`是空串,若`pos`参数合法,则返回`pos`;否则返回`basic_string::npos`.
*   `PARAM:pos`;其合法范围:`[0,size()]`;若`pos`不合法,则该函数总是返回`basic_string::npos`.
*   `NOTE`;主要是注意一下空串的情形.    

```c++
size_type find(const CharT* s, size_type pos, size_type count) const;
```
*   查找`[s,s + count)`在当前字符串`[pos,size())`范围内第一次出现的位置.若存在,则返回`s`第
    一个字符在当前字符串中的下标;若不存在,则返回`basic_string::npos`.
*   `PARAM:pos`;其合法范围:`[0,size()]`;若`pos`不合法,则该函数总是返回`basic_string::npos`.


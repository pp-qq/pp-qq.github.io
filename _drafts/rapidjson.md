Recursive parser, Iterative parser;  Recursive parser is faster but prone to stack overflow in extreme cases. Iterative parser use custom stack to keep parsing state. 简单来说就是 Recursive parser 所有状态都保存在栈上, 因此当 JSON 复杂时, 可能会有栈溢出的风险. 而 Iterative parser 则会动态分配内存来保存状态, 所以没有风险. 或许我们可以给 recursive parser 每次递归上像 PG 一样加个已用 stack 大小 check 操作, 当大小超过指定限制时报错退出. 这样在享受效率的同时, 不会崩溃.

recursive parser 默认打开. 可以通过 kParseIterativeFlag parser flag 来指定使用 iterator parser.

token-by-token parser, 即 IterativeParseInit/Next/Complete 系列函数. 就是把 Iterative parser 中的过程拆分出来了, 由调用者来驱动.

insitu, 也就是 in place 解析. 此时 decoded string 会直接写在源串空间中, 这里 decoded string 是指 json string 中类似 `\uxxxx` 这种转义符 decode 之后的结果. in place 之所以可行, 是因为 json 语法隐式规定了解码后的字符串长度一定小于源串.


## Hander

rapidjson::Handler::String() 中 str 隐式地以 0 结尾.

Handler::RawNumber() 则可能隐式地以 0 结尾, 也可能不结尾...! 可以看下 reader.h 中 RawNumber 调用位置. 简单来说, 若 copy 参数为 true, 意味着此时没有使用 insitu 解析, 此时隐式以 0 结尾. 若 copy 参数为 false, 则表明使用了 insitu 解析, 此时 rapidjson 无法追加 0 字符, 并且可能会破坏掉后面的信息. 以 `{"a": 33, "b": 34}` 为例, 当 rapidjson 解析完 33 之后, 如果追加 0 则意味着 33 后面的 `,` 被覆盖为 0 了, 此时便会影响后面的解析了..

kParseNumbersAsStringsFlag; 根据 ParseNumber 源码可以看出, rapidjson 在解析数字字符的同时也会计算相关的值信息, 所以使用 kParseNumbersAsStringsFlag 与不使用相比, 并没有太大差别. 我本来以为使用了 kParseNumbersAsStringsFlag 之后, rapidjson 不会再做类似 str2int, str2double 这类操作了...

## Writer::RawValue

```cpp
bool RawValue(const Ch* json, size_t length, Type type);
```

*   写入一个合法的 JSON 字符串.

*   `PARAM:json,length,type`;这里`json,length`指定了合法的 JSON 字符串;而`type`指定了这个 JSON 字符串的类型.

*   DEMO1:

    ```cpp
    StringBuffer sb;
    Writer<StringBuffer> writer(sb);

    writer.StartObject();
    writer.Key("Hello");

    const char *raw_json_str = "[1,2,3]";
    writer.RawValue(raw_json_str,strlen(raw_json_str),kArrayType);
    writer.EndObject();
    ```

*   DEMO2:

    ```cpp
    StringBuffer sb;
    Writer<StringBuffer> writer(sb);

    writer.StartObject();
    writer.Key("Hello");

    // 这里是错误的!因为 raw_json_str 并不是合法的 JSON 字符串;应该为: raw_json_str = "\"hello\"".
    const char *raw_json_str = "hello";
    writer.RawValue(raw_json_str,strlen(raw_json_str),kStringType);

    writer.EndObject();
    ```

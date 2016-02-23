---
---

# if

```makefile
$(if condition,true-part);
$(if condition,true-part,false-part);
```

*   `PARAM:condition`;对`condition`进行展开,则展开结果为空串,则表明条件为假,否则表明条件为真.
    若`condition`本身不能不需要展开,则使用其自身来判断.如:
    
    ```makefile
    hello := 
    $(if hello,true,false); # hello 本身不需要展开,则使用'hello'本身来测试,很显然此时条件为真.
    $(if $(hello),true,false); # '$(hello)'展开后为空,此时条件为假.
    ```
*   `RETURN`;若`condition`为真,则结果为`true-part`;若`condition`为假,则结果为`false-part`,
    若`false-part`不存在,则结果为空.

# and

```makefile
$(and cond1,cond2,cond3,...);
```

*   `PARAM: condN`;与`$(if)`中`condition`一致!
*   `RETURN`;自左到右依次展开`condN`,若所有的`cond`展开后都不为空,则结果就是最右侧`cond`展开
    的结果.若某个`cond`展开后为空,则结果为空.

# or

```makefile
$(or cond1,cond2,cond3,...);
```

*   `PARAM: condN`;与`$(if)`中`condition`一致!
*   `RETURN`;自左到右依次展开`condN`,若所有的`cond`展开后都为空,则结果为空;若某个`cond`展开
    后不为空,则结果为该`cond`展开后的结果.

    
# findstring

```makefile
$(findstring a,b)
```

*   该函数的行为类似如下代码:
    
    ```c++
    if (strstr(b,a) != nullptr)
        return a;
    else
        return ""; // 空串.
    ```


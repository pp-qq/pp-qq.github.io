---
title: "PG 中的 numeric"
hidden: true
tags: ["Postgresql/Greenplum"]
---

PG 中的 numeric 认为任何浮点数都可以写成

$$
(-1)^S \times 10000 ^ {-E} \times C
$$

以 2018121811.45 为例, 对应的 S, E, C 分别是 0, -1, 20181218114500; 之后在存放着时, 对于 C, PG 会将每 4 个数字放在一个 int16 类型中. 如下所示:

```c
(gdb) ptype var
type = struct NumericVar {
    int ndigits;  
    int weight;
    int sign;
    int dscale;
    NumericDigit *buf;  // 可忽略
    NumericDigit *digits;
} *
(gdb) p *var
$2 = {ndigits = 4, weight = 2, sign = 0, dscale = 2, buf = 0x0, digits = 0x625000058f4e}
(gdb) x/4dh  0x625000058f4e
0x625000058f4e:	20	1812	1811	4500
```

这里 NumericVar::ndigits 记录着 C 中共有多少 digit, 注意这里 digit 是在 10000 进制下的数字. `weight + 1` 记录着小数点前 digit 的个数. sign 则是符号位. digits 则是 int16 数组, 存放着所有数字.

在这种编码下, numeric 的运算也便比较直观了, 以加法为例, 简单来说就是将两个操作数的 digits 部分从最低位依次相加, 当然需要考虑到进位的情况. 

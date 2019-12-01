---
title: "GCC 中的整数转换"
hidden: false
tags: ["gcc", "C++"]
---

一直以来, 我对 C/C++ 中的整数类型转换规则了解一直是云里雾里的, 尤其是涉及到有符号整数类型时, 更是说不清个所以然. 这种情况一直存在着, 主要是我在业务日常开发上很少遇到整数类型转换, 所以也一直没想着去搞清, 直至遇到了 Postgresql 代码, PG 代码中在 TransactionIdPrecedes() 等函数实现中大量使用了整数类型转换(详见 [PG 中的事务 id]({{site.url}}/2019/12/01/pgxact/)), 为了避免对这些代码的理解产生了歧义, 这次下决心搞清这里背后的规则.

那么首先要参考的材料就是 C/C++ 标准了:

>   A value of any integer type can be implicitly converted to any other integer type. Except where covered by promotions and boolean conversions above, the rules are:
>   -   if the target type can represent the value, the value is unchanged
>   -   otherwise, if the target type is unsigned, the value 2^b
, where b is the number of bits in the target type, is repeatedly subtracted or added to the source value until the result fits in the target type. In other words, unsigned integers implement modulo arithmetic.
>   -   otherwise, if the target type is signed, the behavior is implementation-defined (which may include raising a signal)

暂不提其中提到的 implementation-defined 行为, 光是 repeatedly subtracted or added to the source value 就够理解的了. 这里提到的重复加减是指数学意义上的么? 何时加? 何时减呢? 既然文档给出的答案不甚清晰, 就只能去深入 GCC 代码从具体细节上来了解这方面内容了.

介绍 GCC 实现背后细节的文档有 GCC 官方文档: [GNU Compiler Collection (GCC) Internals](https://gcc.gnu.org/onlinedocs/gcc-9.2.0/gccint/), 这个文档介绍地都是零散的知识点, 并没有(或者是我没找到)从全局上介绍一下 GCC 整个架构. 以及一个同人篇: [GNU C Compiler Architecture](https://en.wikibooks.org/wiki/GNU_C_Compiler_Internals/GNU_C_Compiler_Architecture), 这篇文档从整体全局上介绍了 GCC 整个架构, 不过具体模块细节上有所缺失. 另外虽然这篇文档基于 GCC 4.x 版本写就, 但根据 GCC 9.2.0 代码来看, 文档内容仍基本上是符合代码的. 总之从这两篇文档我们了解到在涉及到 C/C++ 语言编译过程中, GCC 使用了 4 种表达方式: 从最开始的 AST 到 GENERIC, 再到 GIMPLE, 再到 RTL Representation, 最后到了汇编. 通过 GCC 文档以及 GCC 提供的 Developer Options `-fdump-tree-xxx`, `-fdump-rtl-xxx` 等选项将一次编译过程中每个中间结果表达 dump 到文件之后可以看到在 AST, GENERIC, GIMPLE 这些层中, 转换操作仍然是通过一个抽象算子(CONVERT_EXPR/NOP_EXPR)来表达的; 在 RTL 这一层时, 才真正地选择了具体的指令来实现了这些抽象操作. 因此我们只需要找到 GIMPLE -> RTL 转换函数, 了解该函数针对 CONVERT_EXPR/NOP_EXPR 算子是如何生成 RTL 指令的逻辑即可. 最终找到了 convert_mode_scalar() 函数, 具体代码片段:

```c
  {
    convert_optab ctab;

    if (GET_MODE_PRECISION (from_mode) > GET_MODE_PRECISION (to_mode))
      ctab = trunc_optab;
    else if (unsignedp)
      ctab = zext_optab;
    else
      ctab = sext_optab;

    if (convert_optab_handler (ctab, to_mode, from_mode)
	!= CODE_FOR_nothing)
      {
	emit_unop_insn (convert_optab_handler (ctab, to_mode, from_mode),
			to, from, UNKNOWN);
	return;
      }
  }
```

~~GNU 关于 C 的代码风格很是奇怪...~~

最终总结下来在 GCC 中整数转换规则是:


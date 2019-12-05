---
title: "为什么我的 QtCreator 看不了 GCC 源码"
hidden: false
tags: ["开发经验"]
---

在分析 [GCC 中的整数转换]({{site.url}}/2019/12/01/gccintconv/)之初, 我一如既往地想把 GCC 源码导入到 QtCreator 中, 没想到遇到了:

![qtisdead]({{site.url}}/assets/qtisdead.png)

以及一堆堆栈.

```
Thread 12 Crashed:: Thread (pooled)
0   libCPlusPlus.4.10.2.dylib     	0x000000010a8e3178 CPlusPlus::Parser::parseClassOrNamespaceName(CPlusPlus::NameAST*&) + 8
1   libCPlusPlus.4.10.2.dylib     	0x000000010a8e3dd8 CPlusPlus::Parser::parseNestedNameSpecifier(CPlusPlus::List<CPlusPlus::NestedNameSpecifierAST*>*&, bool) + 40
2   libCPlusPlus.4.10.2.dylib     	0x000000010a8e414c CPlusPlus::Parser::parseName(CPlusPlus::NameAST*&, bool) + 220
3   libCPlusPlus.4.10.2.dylib     	0x000000010a8efcf3 CPlusPlus::Parser::parseClassSpecifier(CPlusPlus::List<CPlusPlus::SpecifierAST*>*&) + 451
4   libCPlusPlus.4.10.2.dylib     	0x000000010a8e8053 CPlusPlus::Parser::parseSimpleDeclaration(CPlusPlus::DeclarationAST*&, CPlusPlus::ClassSpecifierAST*) + 2611
5   libCPlusPlus.4.10.2.dylib     	0x000000010a8f09ce CPlusPlus::Parser::parseMemberSpecification(CPlusPlus::DeclarationAST*&, CPlusPlus::ClassSpecifierAST*) + 1118
6   libCPlusPlus.4.10.2.dylib     	0x000000010a8f02e5 CPlusPlus::Parser::parseClassSpecifier(CPlusPlus::List<CPlusPlus::SpecifierAST*>*&) + 1973
7   libCPlusPlus.4.10.2.dylib     	0x000000010a8e8053 CPlusPlus::Parser::parseSimpleDeclaration(CPlusPlus::DeclarationAST*&, CPlusPlus::ClassSpecifierAST*) + 2611
8   libCPlusPlus.4.10.2.dylib     	0x000000010a8f09ce CPlusPlus::Parser::parseMemberSpecification(CPlusPlus::DeclarationAST*&, CPlusPlus::ClassSpecifierAST*) + 1118
9   libCPlusPlus.4.10.2.dylib     	0x000000010a8f02e5 CPlusPlus::Parser::parseClassSpecifier(CPlusPlus::List<CPlusPlus::SpecifierAST*>*&) + 1973
10  libCPlusPlus.4.10.2.dylib     	0x000000010a8e8053 CPlusPlus::Parser::parseSimpleDeclaration(CPlusPlus::DeclarationAST*&, CPlusPlus::ClassSpecifierAST*) + 2611
11  libCPlusPlus.4.10.2.dylib     	0x000000010a8f09ce CPlusPlus::Parser::parseMemberSpecification(CPlusPlus::DeclarationAST*&, CPlusPlus::ClassSpecifierAST*) + 1118
12  libCPlusPlus.4.10.2.dylib     	0x000000010a8f02e5 CPlusPlus::Parser::parseClassSpecifier(CPlusPlus::List<CPlusPlus::SpecifierAST*>*&) + 1973
13  libCPlusPlus.4.10.2.dylib     	0x000000010a8e8053 CPlusPlus::Parser::parseSimpleDeclaration(CPlusPlus::DeclarationAST*&, CPlusPlus::ClassSpecifierAST*) + 2611
14  libCPlusPlus.4.10.2.dylib     	0x000000010a8f09ce CPlusPlus::Parser::parseMemberSpecification(CPlusPlus::DeclarationAST*&, CPlusPlus::ClassSpecifierAST*) + 1118
```

一开始并没有当回事, 因为在我的电脑上 QtCreator 确实会时不时地崩一下(但是 QtCreator 始终是我用过的最好的 IDE!!!). 但当我再次打开 QtCreator, QtCreator 又立马再次崩掉; 不信邪地又一次打开, 又一次崩掉之后, 整件事情看起来就很怪异了. 这下我怎么捋 GCC 代码?! 我怎么知道 GCC 中整数转换到底是怎么进行的?! 我如何去没有歧义地理解 Postgresql 中关于事务 XID 的逻辑?! 这样下去是不行的, 还是要先解决掉 QT 崩溃这个拦路虎.

那就 lldb 一把吧, bt 下之后看到堆栈很长.

```
(lldb) bt
* thread #18, name = 'Thread (pooled)', stop reason = EXC_BAD_ACCESS (code=2, address=0x7000044daff8)
  * frame #0: 0x000000010a2fadb4 libCPlusPlus.4.10.2.dylib`CPlusPlus::Parser::parseNestedNameSpecifier(CPlusPlus::List<CPlusPlus::NestedNameSpecifierAST*>*&, bool) + 4
    frame #1: 0x000000010a2fb14c libCPlusPlus.4.10.2.dylib`CPlusPlus::Parser::parseName(CPlusPlus::NameAST*&, bool) + 220
    frame #2: 0x000000010a3036d8 libCPlusPlus.4.10.2.dylib`CPlusPlus::Parser::parseElaboratedTypeSpecifier
    ... 此处省略 1w 个堆栈 ...
    frame #15711: 0x000000010a2ff053 libCPlusPlus.4.10.2.dylib`CPlusPlus::Parser::parseSimpleDeclaration(CPlusPlus::DeclarationAST*&, CPlusPlus::ClassSpecifierAST*) + 2611
    frame #15712: 0x000000010a3079ce libCPlusPlus.4.10.2.dylib`CPlusPlus::Parser::parseMemberSpecification(CPlusPlus::DeclarationAST*&, CPlusPlus::ClassSpecifierAST*) + 1118
    frame #15713: 0x000000010a3072e5 libCPlusPlus.4.10.2.dylib`CPlusPlus::Parser::parseClassSpecifier(CPlusPlus::List<CPlusPlus::SpecifierAST*>*&) + 1973
    frame #15714: 0x000000010a2ff053 libCPlusPlus.4.10.2.dylib`CPlusPlus::Parser::parseSimpleDeclaration(CPlusPlus::DeclarationAST*&, CPlusPlus::ClassSpecifierAST*) + 2611
    frame #15715: 0x000000010a2fb87c libCPlusPlus.4.10.2.dylib`CPlusPlus::Parser::parseTranslationUnit(CPlusPlus::TranslationUnitAST*&) + 252
    frame #15716: 0x000000010a33224e libCPlusPlus.4.10.2.dylib`CPlusPlus::TranslationUnit::parse(CPlusPlus::TranslationUnit::ParseMode) + 126
```

所以第一直觉是 BUG 或者其他原因导致无限递归导致了栈溢出, `ulimit -s` 看了下 mac 默认对堆栈空间限制是 8M:

```bash
$ ulimit -s
8192  /* unit: kb */
```

那么这里是 BUG 导致的无限递归么? 从 bt 展示的堆栈可以看到这里貌似目测并不是 "无限" 递归, 可以看到最顶上的 parseClassOrNamespaceName() 实际上在解析 AST 叶子节点了, 所以这里递归本身是正常的, 那么我们只需要通过 ulimit 把栈空间调大点就成.

但是问题又来了, 究竟是 GCC 哪个源文件具有这么大的能量导致了如此之深的递归呢, 从 bt 展示的堆栈大概可以想象出源码大概得长这个样子:

```c++
class C1 {
    class C2 {
        class C3 {
            class C4 {
                class C5 {
                    class C6 {
                        class C7 {
                            class C333 { /* ... */ };
                        };
                    };
                };
            };
        };
    };
};
```

我现在开始对这个文件很好奇了! 在 QtCreator 中, TranslationUnit 类表明着一个待解析的源文件, 其内成员 `[_firstSourceChar, _lastSourceChar)` 存放着文件内容. 所以接下来只需要调到 'frame #15716', 然后找到当时的 this 指针就行, 祈祷保佑存放着这个 this 指针内容的寄存器已经被压入函数栈帧中了. 根据调用约定, this 参数作为函数的第一个参数应该会通过 rdi 寄存器传递给 parse(), 结合 parse() 的反汇编:

```
(lldb) disassemble
libCPlusPlus.4.10.2.dylib`CPlusPlus::TranslationUnit::parse:
    0x10a2d61d0 <+0>:   pushq  %rbp
    0x10a2d61d1 <+1>:   movq   %rsp, %rbp
    0x10a2d61d4 <+4>:   pushq  %r15
    0x10a2d61d6 <+6>:   pushq  %r14
    0x10a2d61d8 <+8>:   pushq  %rbx
    0x10a2d61d9 <+9>:   subq   $0xb8, %rsp
    0x10a2d61e0 <+16>:  movl   %esi, %ebx
    0x10a2d61e2 <+18>:  movq   %rdi, %r15
    ...
```

可以看到 this 指针经由 rds -> r15 保存在了 r15 寄存器中了. 而且幸运的是 r15 寄存器已经被保存在函数栈帧中了!

```
(lldb) register read
General Purpose Registers:
       ...
       r15 = 0x0000000154682a50
```

那么接下来我们只需要一次 read:

```
(lldb) memory read --force -size 1 -format c -count 271521 0x0000000149780018
0x149780018: # 1 "/Users/zhanyi.ww/project/or
0x149780038: g/gnu/gcc-9.2.0/gcc/testsuite/gc
0x149780058: c.c-torture/compile/limits-struc
0x149780078: tnest.c"\n# 21 "/Users/zhanyi.ww/
0x149780098: project/org/gnu/gcc-9.2.0/gcc/te
0x1497800b8: stsuite/gcc.c-torture/compile/li
0x1497800d8: mits-structnest.c"\n# expansion b
0x1497800f8: egin 1174,4 21:5 ~2 21:5 ~2 21:5
0x149780118:  ~2 21:5 ~2 21:5 ~2 21:5 ~2 21:5
0x149780138:  ~2 21:5 ~2 21:5 ~2 21:5 ~2 21:5
0x149780158:  ~2 21:5 ~2 21:5 ~2 21:5 ~2 21:5
...
0x149793978:  ~2 21:5 ~2\nstruct s0000 {struct
0x149793998:  s0001 {struct s0002 {struct s00
0x1497939b8: 03 {struct s0004 {struct s0005 {
0x1497939d8: struct s0006 {struct s0007 {stru
0x1497939f8: ct s0008 {struct s0009 { struct
0x149793a18: s0010 {struct s0011 {struct s001
0x149793a38: 2 {struct s0013 {struct s0014 {s
0x149793a58: truct s0015 {struct s0016 {struc
0x149793a78: t s0017 {struct s0018 {struct s0
0x149793a98: 019 { struct s0020 {struct s0021
0x149793ab8:  {struct s0022 {struct s0023 {st
0x149793ad8: ruct s0024 {struct s0025 {struct
0x149793af8:  s0026 {struct s0027 {struct s00
...
0x1497b6018: t s9996 {struct s9997 {struct s9
0x1497b6038: 998 {struct s9999 {\n# expansion
0x1497b6058: end\n# 22 "/Users/zhanyi.ww/proje
0x1497b6078: ct/org/gnu/gcc-9.2.0/gcc/testsui
0x1497b6098: te/gcc.c-torture/compile/limits-
0x1497b60b8: structnest.c"\n  int x;\n# expansi
0x1497b60d8: on begin 1198,4 ~30000\n} x; } x;
0x1497b60f8:  } x; } x; } x; } x; } x; } x; }
...
0x1497c23b8: } x; } x; } x; } x; } x; } x; }
0x1497c23d8: x; } x; } x; } x; } x; } x; } x;
0x1497c23f8:  } x; } x; } x; } x; } x; } x; }
0x1497c2418:  x; } x; } x; } x; } x; } x; } x
0x1497c2438: ; } x;\n# expansion end\n# 24 "/Us
0x1497c2458: ers/zhanyi.ww/project/org/gnu/gc
0x1497c2478: c-9.2.0/gcc/testsuite/gcc.c-tort
0x1497c2498: ure/compile/limits-structnest.c"
0x1497c24b8: \n\0\0\0
```

就可以看到这个充满神秘的源文件内容了. 看样子是 GCC 编译测试套件中的一个测试文件, 实际源码为:

```
#define LIM1(x) x##0 {x##1 {x##2 {x##3 {x##4 {x##5 {x##6 {x##7 {x##8 {x##9 {
#define LIM2(x) LIM1(x##0) LIM1(x##1) LIM1(x##2) LIM1(x##3) LIM1(x##4) \
		LIM1(x##5) LIM1(x##6) LIM1(x##7) LIM1(x##8) LIM1(x##9)
#define LIM3(x) LIM2(x##0) LIM2(x##1) LIM2(x##2) LIM2(x##3) LIM2(x##4) \
		LIM2(x##5) LIM2(x##6) LIM2(x##7) LIM2(x##8) LIM2(x##9)
#define LIM4(x) LIM3(x##0) LIM3(x##1) LIM3(x##2) LIM3(x##3) LIM3(x##4) \
		LIM3(x##5) LIM3(x##6) LIM3(x##7) LIM3(x##8) LIM3(x##9)
#define LIM5(x) LIM4(x##0) LIM4(x##1) LIM4(x##2) LIM4(x##3) LIM4(x##4) \
		LIM4(x##5) LIM4(x##6) LIM4(x##7) LIM4(x##8) LIM4(x##9)
#define LIM6(x) LIM5(x##0) LIM5(x##1) LIM5(x##2) LIM5(x##3) LIM5(x##4) \
		LIM5(x##5) LIM5(x##6) LIM5(x##7) LIM5(x##8) LIM5(x##9)
#define LIM7(x) LIM6(x##0) LIM6(x##1) LIM6(x##2) LIM6(x##3) LIM6(x##4) \
		LIM6(x##5) LIM6(x##6) LIM6(x##7) LIM6(x##8) LIM6(x##9)

#define RBR1 } x; } x; } x; } x; } x; } x; } x; } x; } x; } x;
#define RBR2 RBR1 RBR1 RBR1 RBR1 RBR1 RBR1 RBR1 RBR1 RBR1 RBR1
#define RBR3 RBR2 RBR2 RBR2 RBR2 RBR2 RBR2 RBR2 RBR2 RBR2 RBR2
#define RBR4 RBR3 RBR3 RBR3 RBR3 RBR3 RBR3 RBR3 RBR3 RBR3 RBR3
#define RBR5 RBR4 RBR4 RBR4 RBR4 RBR4 RBR4 RBR4 RBR4 RBR4 RBR4

LIM4(struct s)
  int x;
RBR4
```

至此:

-   GCC 对自己真够狠的!
-   QtCreator 对源文件的解析能力也真是棒棒的!


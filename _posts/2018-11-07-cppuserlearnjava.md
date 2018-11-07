---
title: "C++er 的 java 入门指南"
hidden: false
tags: [java]
---
# 前言

本文章根据 [Java Tutorials Learning Paths, java 1.8](https://docs.oracle.com/javase/tutorial/tutorialLearningPaths.html) 结合 C++ 经验制作而成; 只会记录一些琐碎的概念与知识点; 大多数语法上禁忌没有记录在内, 比如 local class 不能定义 static method 这种, 毕竟编译器会时刻提示我们的嘛.

个人觉得比较适合 C++er 的 java 入门入作; 毕竟 java 与 C++ 大体上是非常相似的, 比如 java static nested class 就是等同于 C++ 内部类的存在嘛, 所以没必要再耗费精力通过一本书来系统地学习 java 了. 但是 java 又有一些细节与 C++ 很不一样, 比如: java inner class instance 居然与一个 enclosing class instance 关联, 该文档主要是用来覆盖这些琐碎的细节的. 总之绝对不能依仗对 C++ 的熟练来想当然 java 的语言特性, 模棱两可的地方一定要通过 java tutorials 或者 java spec 明确了!


# Object-Oriented Programming Concepts 


主要关注 state, behavior, fields, methods, data encapsulation, package 这几个概念, 虽然早有所闻, 但这里书面化的描述还是挺稀奇的. 其中 state, behavior 用来描述现实世界中的 object, 类似于 java object 的 fields, methods. methods, Methods operate on an object's internal state and serve as the primary mechanism for object-to-object communication. Hiding internal state and requiring all interaction to be performed through an object's methods is known as data encapsulation. A package is a namespace that organizes a set of related classes and interfaces. 

"is a" relationship; google 一下了解这个概念的具体定义.

# Language Basics

主要是了解 java 中一些基本概念, 这些概念倒也不是不晓得; 主要为了更无障碍地学习后续章节, 这里做一下记录不至于后面看到了眼生. 

Instance Variables (Non-Static Fields). Class Variables (Static Fields). Local Variables, Similar to how an object stores its state in fields, a method will often store its temporary state in local variables; 这里将 local variables 视为 method 存放 temporary state 的观点还是挺稀奇的. state, 状态, 目前发现确实是编程中一个很重要的概念啊, 尤其是在异步编程模型中. Parameters, Parameters refers to the list of variables in a method declaration. Arguments, Arguments are the actual values that are passed in when the method is invoked. fields, Non-Static Fields, Static Fields 的统称. variables, Instance Variables (Non-Static Fields), Class Variables (Static Fields), Local Variables, Parameters 的统称. member, A type's fields, methods, and nested types are collectively called its members, 这里 type 应该是指 class, 注意 Constructors are not members. 

Primitive Data Types; java 中共有 8 种 primitive data types: byte, short, int, long, float, double, char, boolean. 在 >= javaSE8 之后, java 也通过类库的方式支持了 unsigned int, unsigned long, 具体参见原文了解. Autoboxing and Unboxing; 编译器会在需要的时候将数据在 primitive types 类型与 corresponding object wrapper classes 类型来回转换; autoboxing 是指编译器将数据从 primitive type 转换为相应的 reference type; unboxing 是指编译器从 reference type 转换为相应的 primitive type; ~~为啥不叫作 AutoUnboxing???~~; 

reference type; Java Language Specification 中明确定义了什么是 reference type, 对于现在来说, 可以认为除 primitive data types 来说之外的所有 type 都是 reference type.

Default Values; 对于 java 支持的 4 类 variables, 针对 field 来说, this default will be zero or null, depending on the data type, 具体参见原文表格. 对于 local variable 来说, the compiler never assigns a default value to an uninitialized local variable, 需要程序员自己整. 

Literals; A literal is the source code representation of a fixed value; literals are represented directly in your code without requiring computation. 这个倒是看过的对 literals 概念来说最合适的定义了, 就算是 golang specification 中也未明确定义 literal. 参见原文了解常见的 literal 写法.

Array Initializers, Array Creation Expressions;  javase tutorial 文档介绍的很不详细, 还是需要根据 java specification 来看细节. 比如 `int[][] i = new int[f()][g{()]` 中当 `f()` 抛出异常时, `g()` 是否还会被调用? 以及 `i.length` 是等于 `f()` 还是 `g()` 等. 

Operator Precedence; 参见原文表格了解各个操作符的优先级次序. When operators of equal precedence appear in the same expression, a rule must govern which is evaluated first. All binary operators except for the assignment operators are evaluated from left to right; assignment operators are evaluated right to left.

target type of an expression, The target type of an expression is the data type that the Java compiler expects depending on where the expression appears.

statement, A statement forms a complete unit of execution. 同样之前只是晓得 statement 是什么, 但又说不清楚. statement 这个概念在解释型语言中很形象, 比如 python 就必须在读取到完整 statement 时才开始执行, 否则就会一直等待用户继续输入.

block, A block is a group of zero or more statements between balanced braces and can be used anywhere a single statement is allowed.

然后就是一些琐碎的知识点, 毕竟 java 大体我还是了解的, 除了那么点细节:

instanceof operator; keep in mind that null is not an instance of anything, 这个还真没有注意到过.

The switch Statement; A switch works with the byte, short, char, and int primitive data types. It also works with enumerated types, the String class, and a few special classes that wrap certain primitive types: Character, Byte, Short, and Integer. 注意当 switch works with reference type 时, 会使用 `.equals()` 方法来进行比较; 所以若 switch works with null, 则 NPE. The body of a switch statement is known as a switch block. A statement in the switch block can be labeled with one or more case or default labels. The switch statement evaluates its expression, then executes all statements that follow the matching case label. 这里把 `case`, `default` 作为 label 看待感觉很合理, 如下之前一直觉得执行流从 `#1` 跳到 `#2` 很违和, 毕竟她们属于不同的 case 是吧, 现在把 case 视为 label 就很合理了, 这时 `#1` 与 `#2` 在同一个 block 中, 从 `#1` 执行到 `#2` 理所当然.

```java
i = 2;
switch (i) {
case 1:
case 2:
    ++i;
    ++j;  // #1
case 3:
    ++z;  // #2
}
```

# Classes and Objects

老规矩, 先来看一些基本概念:

method signature; 由 the method's name and the parameter types 组成.

covariant return type; means that the return type is allowed to vary in the same direction as the subclass. 既 You can override a method and define it to return a subclass of the original method, 如:

```java
class T1 {
    public Object f() {
        System.out.printf("T1::f; %s\n", this);
        return new Object();
    }    
};


public class Test extends T1 {
    @Override
    public String f() {  
        System.out.printf("Test::f; %s\n", this);
        return "hell";
    }
    
    public static void main(String[] args) {
        Test t = new Test();
        t.f();
    }
}
```

explicit constructor invocation; 语义上等同于 C++ 中的委托构造函数; 语法上通过 `this(...)` 来调用其他构造函数, If present, the invocation of another constructor must be the first line in the constructor.

nested class, enclosing class; The Java programming language allows you to define a class within another class. Such a class is called a nested class. And the another class is called the enclosing class. 

static nested class, inner class; Nested classes are divided into two categories: static and non-static. Nested classes that are declared static are called static nested classes. Non-static nested classes are called inner classes. static nested class 等同于 C++ 中的内部类. 而 inner class 则非常特殊了, 具体见下.

effectively final, A variable or parameter whose value is never changed after it is initialized is effectively final.

constant variable, A constant variable is a variable of primitive type or type String that is declared final and initialized with a compile-time constant expression.

然后再来看一些琐碎的知识点:

Declaring Classes; class 声明时的几个要素, 参见原文了解. 原来一个 class 是可以实现多个 interface 的啊.

编译器自动生成的构造函数; The compiler automatically provides a no-argument, default constructor for any class without constructors. This default constructor will call the no-argument constructor of the superclass, 然后执行 Instance Variables 声明时的初始化表达式来初始化各个 fields.

```java
public class Test {
    public static int f() {
        System.out.println(33);
        return 3;
    }

    int i = f();

    public static void main(String[] args) {
        Test i = new Test();  // 执行 f();
        Test i1 = new Test(); // 再次执行 f();
    }
}
```

Arbitrary Number of Arguments; 下面用个例子来讲解变长参数使用相关:

```java
public class Test {
    public static void f(Object... objs) {
        System.out.println(objs);
        if (objs != null) {
            System.out.println(objs.length);
        }
    }
  
    public static void main(String[] args) {
        f();  // 此时 f() 内, objs 不为 null, 而是一个 length 为 0 的空数组.
        f(1, 2, 3);
        int[] i = {1, 2, 3};
        f(i);  // objs.length = 1, 而不是 i.length
        Object[] objs1 = {4, 5};
        System.out.println(objs1);  
        f(objs1);  // objs = objs1
        Object[] objs2 = null;
        System.out.println(objs2);
        f(objs2);  // objs = objs2
    }

}
```

new operator; java 中 `new` 作为一个运算符, 其 requires a single, postfix argument: a call to a constructor. The name of the constructor provides the name of the class to instantiate. 然后 returns a reference to the object it created. 所以 `int j = new Rectangle().height + 33` 是一个合法的表达式.

Access level modifiers; Access level modifiers determine whether other classes can use a particular field or invoke a particular method. There are two levels of access control: 

-    At the top level—public, or package-private (no explicit modifier).
-    At the member level—public, private, protected, or package-private (no explicit modifier). 此时 The protected modifier specifies that the member can only be accessed within its own package (as with package-private) and, in addition, by a subclass of its class in another package, 倒是与 C++ 不太一样了哈.

Instance methods can access class variables and class methods directly. 这里假设存在 `Class T`, 以及 `T` 实例 `t`; 所以有 `T.class` 表示 `T` 对应的 `Class` 实例, 而 `t.class` 则是非法的; 这里 `T.class` 是一个特殊的 literal, class literal, 而不是说 `class` 是 `T` 的 static field. 所以 `t.class` 非法并不意味着本节开头的命题为假. 肛精退散~

`final` 的语义; 按我理解, final 修饰的 variables 仅允许被赋值一次, 更精确地来说, 若 variables 被 final 修饰了, 那么其后仅允许存在一个 statement 存在对 variable 的赋值行为. 如:

```java
final int i;
if (false) {
    i = 33;
}
// 由于上面的 if statement 存在了对 i 的赋值行为, 即使实际运行时并没有执行赋值操作,
// 这里仍然不允许再次对 i 进行赋值, 此时编译器反馈: 'Test.java:8: 错误: 可能已分配变量i'.
i = 44;
```

A final method cannot be overridden in a subclass. 

static initialization block, Initializer blocks; 其语法很是简单. 关键是语义, 尤其是执行次序, 原文并未明确指定执行次序, 可以通过下面的例子来看一下, 不过最好还是通过 java spec 文档了解.

```java
public class Test {
    public Test() {
        f("005");
    }
    
    public static int f(String desc) {
        System.out.println("Test; " + desc);
        return 1;
    }

    static int i1 = f("1");
    
    static {
        f("2");
    }

    static int i2 = f("3");

    static {
        f("4");
    }
    
    int i3 = f("001");
    
    {
        f("002");    
    }
        
    int i4 = f("003");
    
    {
        f("004");
    }

    public static void main(String[] args) {
        Test t = new Test();
        return ;
    }
}
```

Inner Class; an inner class is associated with an instance of its enclosing class and has direct access to that object's methods and fields. Also, because an inner class is associated with an instance, it cannot define any static members itself. 这里说 inner class 不能定义 static members, 我感觉有点不合理; 按我理解, inner class 首先是一个普通的 class, 其唯一的特殊之处在于 inner classs instance associated with an instance of its enclosing class; 就像 C++ object 中存在一个指向其所属类 vtables 的指针一样, inner class instance 中存在一个指向 enclosing class instance 的指针; 所以我觉得这里 inner class 不能定义 static member 更多是主观上觉得不合适, 而不是存在客观事实原因. To instantiate an inner class, you must first instantiate the outer class. Then, create the inner object within the outer object with this syntax: `OuterClass.InnerClass innerObject = outerObject.new InnerClass()`. 这里我觉得语法换成 `innerobj = new outObj.InnerClasss()` 是不是更自然合理一点?

Inner Class Shadow; 下面用一个例子来展示 shadow 这种现象, 以及在这种现象中如何访问被 shadowed 的 variables.

```java
public class Test {
    private String a = "blog.hidva.com";
    class A {
        private String a = "go.hidva.com";  // shadow Test.a
        class B {
            private String a = "hidva.com";  // shadow A.a
            public void f(String a) {  // shadow B.a
                System.out.println(a);
                System.out.println(this.a);  // 所以平常用的 this 也是 unqualified 的啊!
                System.out.println(A.this.a);  // 通过 qualified this 来访问 shadowed variables.
                System.out.println(Test.this.a);
            }
        }
    }

    public static void main(String[] args) {
        Test t = new Test();
        A a = t.new A();
        A.B b = a.new B();  // 并不是 a.new A.B();
    // 你自己说说这里换成 new a.B() 是不是很清晰!
        b.f("*.hidva.com");
    }

}
``` 

Inner Class Serialization; Serialization of inner classes, including local and anonymous classes, is strongly discouraged. 按我理解就是 java 存在两种层次的 spec, java language sepc, jvm spec; 为了在不变更 jvm spec 的基础上实现 inner class 等这种 language construct, 不得不使用一些魔法(synthetic constructs); 在 inner class serialization, inner class 反射这些场景中就不得不暴漏一些魔法细节; 然后不同 jvm 厂商可能会使用不同的魔法来实现 inner class 这种 language construct; 所以一个 jvm 厂商在 inner class serialization 生成物中包含的细节可能就不会被其他 jvm 厂商识别; 就是存在不兼容性. 

Local Classes; Local classes are classes that are defined in a block. Local classes in static methods, can only refer to static members of the enclosing class. Local classes in non-static methods, 等同于 inner class, 此时 local class instance 与特定的 enclosing class instance(目测只能是 this) 关联, 可以直接访问 enclosing class non-static fields. In addition, a local class has access to local variables. When a local class accesses a local variable or parameter of the enclosing block, it captures that variable or parameter. 按我理解, 这里 capature 的意思是指当 local calss 引用 local variables 或者 parameters 时, 此时就会像 C++ lambda 表达式捕捉一样, java 编译器就会在 local class 中额外添加一些 non-static fields, 这些 fields 类型与被引用的 local variables 一致; 在构造 local class instance 时, 会将被引用的 local variables 以传值的方式传递给 local class constructor 以此初始化这些编译器添加的 non-static fields. 可以自己整几个 local class 例子试一试. 原文同时指出: a local class can access local variables and parameters of the enclosing block that are final or effectively final. 按我理解这里同样也是一些主观因素导致的, 可能 java 作者认为如果允许 local class access any local variables 那么此时的行为可能会使一些 java rd 们迷惑. A local class can have static members provided that they are constant variables. 除此之外 local class 不允许其他 static member 了.

Anonymous Classes; 就目前而言, Anonymous Classes 完全等同于 local class. 除了: they do not have a name. Use them if you need to use a local class only once. While local classes are class declarations, anonymous classes are expressions, 对该 expression 求值会生成匿名类的一份实例. Syntax of Anonymous Classes 可以参考原文, 不过目测原文仍有很多细节未介绍啊, 比如如果匿名类有多个待实现的 interface 该咋整?

Enum Types; java 中的 enum types 本质上就是一个普通的 class, 定义 enum types 首先要定义一个完整的 class, 然后在编译期预定义这个 class instance 集合; 之后该 class 实例取值只能是这些预定义的 instance 集合. 针对 enum class 而言, The compiler automatically adds some special methods when it creates an enum; 就像 `values()` method, 参见原文了解 `values` 语义. 另外 All enums implicitly extend `java.lang.Enum`, 所以在定义 enum class 时不能再 extends other enum class 了.

enum class 的简化版, 此时只需要指定预定义的 instance 集合的标识符, 就是 instance name 即可; 编译器会补全所有必需的信息. 如下:

```java
public enum E {
    Blog,
    Hidva,
    Com
}

// 编译器补全生成的 E.class 可能定义是:

public enum E {
    Blog ("blog"),
    Hidva ("hidva"),
    Com ("com");

    private final String d;
    E(String d) {
        this.d = d;
    }  
}
```

### Lambda Expressions

首先建议先过一遍 'Interfaces and Inheritance' 节内容了解一些概念, oracle 这份 java tutorial 章节安排不咋合理啊.

functional interface; A functional interface is any interface that contains only one abstract method. may contain one or more default methods or static methods.

Lambda Expressions; 按我理解 Lambda Expressions 本质上就是 Anonymous Classes. 在 java 编译器遇到 lambda 时, 其会首先确定该 lambda expression 的 target type, 然后据此生成相应的 anonymous class. 当 java 编译器无法根据 lambda expression 所处上下文以及处境确定 target type 时, lambda expression 本身是没有意义, 编译就会失败, 这就限制了 lambda expression 只能在某些场合下使用. target type 最终形态是一个 functional interface, 编译器会根据 target type 中那个唯一的 abstract method 信息来填补 lambda expression 缺失的信息, 比如 lambda expression 中是可以省略参数类型的呦. 

target type 与函数重载, 参见原文 'Target Types and Method Arguments' 举得例子. 个人觉得这种 case 还是尽量不要在代码中遇到, 如果遇到, 最好结合 java spec 文档准确地确定最终 target type, 绝不能想当然, 不然就会留坑.

lambda expression 与 Anonymous Classes 的不同之处在于, Lambda expressions are lexically scoped. This means that they do not inherit any names from a supertype or introduce a new level of scoping. Declarations in a lambda expression are interpreted just as they are in the enclosing environment. 首先来看一个之前被忽略的事实:

```java
public class Test {

    static void main(String[] args) {
        String a = "blog.hidva.com";
        {   
            // 错误: 已在方法 main(String[])中定义了变量 a!!!
            int a = 33;
        }
    }

}
```

所以前面段话意思是说 anonymous classes 实际上 introduce a new level of scoping, 所以可以在 anonymous classes 中存在 shadow 现象; 但是 lambda exression 并未 introduce a new level of scoping, 即 Declarations in a lambda expression are interpreted just as they are in the enclosing environment, 如果在 lambda expression 中定义了同名 variables 时, 就会像上面代码片段一样报错咯.

lambda expression syntax, 参见原文. 关于这里的 `{}` 何时可以省略的问题, 按我理解是当 target type 唯一 abstract method 是 void 并且 `{}` 内只有一条 statement 时, 可以省略 `{}`, 如下:

```java
public class Test {

    static interface I {
        void f(StringBuilder sb);
    }

    public static void main(String[] args) {
        I i = sb -> sb.toString();  // 可以省略 {}.
        i.f(new StringBuilder());
    }

}
```

Method References; 按我理解, Method References 本质上就是各种略写之后的 lambda expression, 就像 lambda expression 是各种略写之后的 anonymous class. 参见原文了解 method reference 的 4 种写法, 以及每种写法下, 编译器是如何补全信息得到最终 lambda expression 的. 

# Interfaces and Inheritance

Defining an Interface; interface 语义大概我是了解的, 但一些语法方面确实不太晓得了, 参见原文学习.

interface Default Methods; 和 abstract method 唯一的区别就是其有个默认实现, 主要用在 interface 新增接口然后又需要保持兼容性这种场景中. 当 extend an interface that contains a default method 时, 可以变更 default method 的语义, 有继续 default, 不改动实现; 继续 default, 变更一下实现; 不再 default, 变为 abstract. 

interface static method; 就和普通的 java static method, 一般作为一个工具类.

由于类可以实现多个 interface, 那么就存在 the supertypes of a class or interface provide multiple default methods with the same signature 这种情况, 此时相关名字解析规则参考原文, 我个人认为这种情况应该从语法上就禁止掉. 同样由于这种情况的存在, 就需要引入 qualified super, 与 qualified this 一样, 语法是 `Class.super`, 具体疗效参考原文. 

Abstract Methods and Classes; 有点印象, 相关定义参考原文吧. abstract class 并不需要实现所有的其实现的 interfaces 中指定的接口, 毕竟它都 abstract 了嘛. 

# Annotations

Annotations, a form of metadata, provide data about a program that is not part of the program itself. Annotations have no direct effect on the operation of the code they annotate. 即 annotation 本身只会负责提供元信息, 其本身没有影响程序执行的能力; 需要与其他系统, 如 java 编译器, java Checker Framework 等结合使用才可能可以影响程序的执行. 

Declaring an Annotation Type; Annotation 定义语法参见原文即可. 至于这里 Annotation 中的 element 为什么要以函数的形式声明的原因见下.

Use an Annotation; Annotation 使用语法: `@AnnotationType(ElementAssign...)`, 这里 ElementAssign 形式为 `ElementName=ElementValue`, 其中 ElementName 由 annotation type 定义时指定; If there is just one element named value, then the name can be omitted. 如果 ElementName 是数组类型, 则 ElementValue 可以为单个值表明长度为 1 的数组. Annotation 通常都是位于单独的一行, 但也不是不可以与它们所注解的 java element 位于同一行.

meta-annotations; Annotations that apply to other annotations are called meta-annotations. 参见原文了解有存在哪些 meta annotations. 

Repeating Annotations; Repeating Annotations 使用场景参见原文的 `@Schedule` 例子, 还是很有市场的. How To Declare a Repeatable Annotation Type, 参见原文了解; ~~这里 container annotation 居然需要我们来手动定义, 我还以为编译器自动生成的呢~~. 至于这里为何要引入 container annotation, 主要是还是为了兼容 java 反射系统的 API, 如 `AnnotatedElement.getAnnotation(Class<T>)` 等; ~~本来我以为是为了在不变更 jvm spec 前提下实现 Repeating Annotations 呢~~. 同样参考原文简单了解如何通过 java 反射系统来获取 java element 的 Retrieving Annotations.

type annotation; Annotations can also be applied to any type use. This means that annotations can be used anywhere you use a type. A few examples of where types are used are class instance creation expressions (new), casts, implements clauses, and throws clauses. This form of annotation is called a type annotation. type annotation 是 java type checking framework 一部分, 其应与 pluggable type system 结合使用. 这里 type annotation 仍只是负责提供元信息, pluggable type system 会利用这些元信息实现一些有用的功能; 参见原文举得 notnull checker 例子. [Checker Framework](http://types.cs.washington.edu/checker-framework/) 提供了一些可能有用的 checker, 比如 lock checker 等.

## Annotations 究竟是什么?

Annotations 本质上就是一个 interface, 所有 Annotations 都 extends java.lang.annotation.Annotation 这个 interface, 所以 Annotation declare 语法使用了 interface 关键词. 按我理解在 use an annotation 时, 编译器会自动生成一个类, 该类实现了指定的 annotation interface, 见下 `A_Use_1`; 之后编译器会实例化该类并将实例存放于某处, 后续通过 java 反射系统 API 如 `getDeclaredAnnotations()` 时, 将会返回这些实例. 

```java
@interface A {
    String a() default "blog.hidva.com";
    String[] b(); 
}

@A(b="hidva.com")  // #1
void f() { }

// 此时针对 #1, 编译器自动生成的类形式可能如下:
class A_Use_1 implements A {
    @Override
    String a() {
        return "blog.hidva.com";
    }

    @Override
    String[] b() {
        return {"hidva.com"};
    }   
}
```

这大概也是为何 annotation type element declarations 以 Method 的形式存在的原因吧.


# Generics 

老规矩, 先介绍一波基本概念:

generic type; A generic type is a generic class or interface that is parameterized over types. 

type parameters, type argument. 

generic type invocation, parameterized type; `GenericClass<T>` 一方面是一个动作, 即 generic type invocation; 另一方面也是一个名词, 即 parameterized type.

raw type; A raw type is the name of a generic class or interface without any type arguments. 由于 type erasure 的存在, 对于 generic type 来说, 其 raw type 是运行时唯一存在的一个类, 其他 parameterized type 都仅在编译期存在. 

reifiable type, Non-reifiable types; 若 type 蕴含的信息在编译期, 运行期完全一致, 那么 type 就是 reifiable type; 反之则是 non-reifiable type. 如 `List<?>` 编译期, 运行时都一个德行, 所以它就是 reifiable type; 但是 `List<? extends Number>` 由于运行时经过 type erasure 丢失了 'extends Number' 这个信息, 所以它就 non-reifiable type.

Heap Pollution; 堆污染, 我第一开始以为这个会导致 jvm 无故 SIGSEGV 呢! 后来发现只是会导致 ClassCastException 异常抛出. 总之 Heap Pollution 现象会导致的结果就是可能会抛出 ClassCastException; 至于哪些情况下会导致 Heap Pollution 现象, 可以参考原文了解一下.

再来看一些琐碎的细节:

diamond notation; parameterized type 一种略写形式, 此时不需要指定 type arguments, java 编译器会根据上下文来自动推断, 就像 `Box<Integer> integerBox = new Box<>();`.

Generic methods; 参见原文了解 generic method 的声明语法, 使用姿势. :

```java
public class Test {
    
    public static <T> void f(T t) {
        System.out.println(t.getClass());
    }

    public static void main(String[] args) {
        // <String>f(new String("hidva.com")); Error!
        Test.<String>f(new String("blog.hidva.com"));
        f(new Double(3.3));
    }

}
```

Bounded Type Parameters; 类似于 C++20 中的 Constraints and concepts, 意图来限制 Type Parameters 对应的 Type Arguments 集合. java 中限制方式有: `<T1 extends InterfaceOrClass, T2 extends IOC1 & IOC2>` 限制了 `T1` 要么是 InterfaceOrClass, 要么必须 extends 或者 implements `InterfaceOrClass`; `T2` 必须同时 extends 或者 implements `IOC1`, `IOC2`, 当然 `T2` 可以是 `IOC1` 或者 `IOC2`, 如果它们满足条件的话.

Given two concrete types A and B, `MyClass<A>` has no relationship to `MyClass<B>`, regardless of whether or not A and B are related. 所以 `List<Number>` 与 `List<Double>` 不存在 is a relationship.

type erasure; type erasure 是 java 实现模板的一种机制. 参见原文了解 type erasure 过程中会做那些事. 其中 'Generate bridge methods to preserve polymorphism in extended generic types.' 可能有点迷, 下面用一个例子来说明为什么需要做这件事(下面用'第三件事'来代替).

```java
public class Node<T> {

    public T data;

    public Node(T data) { this.data = data; }

    public void setData(T data) {
        System.out.println("Node.setData");
        this.data = data;
    }
}

public class MyNode extends Node<Integer> {
    public MyNode(Integer data) { super(data); }

    @Override
    public void setData(Integer data) {
        System.out.println("MyNode.setData");
        super.setData(data);
    }
}

// 代码片段1
MyNode mn = new MyNode(5);
Node n = mn;           
n.setData("Hello");  // #1   
Integer x = mn.data;  // #2    
```

设想一下如果 type erasure 过程不存在第三件事, 那么 type erasure 之后, MyNode 中将存在 `setData(Object)`, `setData(Integer)`, 并且 `#1` 将会调用 `setData(Object)`, 很显然会成功调用; 然后在执行 `#2` 时, 则也会理所当然地抛出 ClassCastException; 最主要的是这种行为不符合 java rd 们的直观预期, 明明 Override 的了啊! 如果 type erasure 过程有第三件事, 那么编译器将为 MyNode 生成如下方法:

```java
public void setData(Object data) {
    setData((Integer) data);
}
``` 

所以 ClassCastException 就会提前在 `#1` 时抛出, 而且一切行为都符合 java rd 们的预期.

## Wildcards

~我并没有太明确 wildcards 存在的意义, 头秃, 毕竟都有模板了是不, 所以本节跳过, 有需要了解的同学可以自己去看文档~~

# Packages

老规矩, 先介绍一波基本概念:

package; A package is a grouping of related types providing access protection and name space management. 

再来看一些琐碎的细节:

import (static); 仅是会导入 name, 方便后续以 unqualified 形式, 即直接通过那个被 import 的 name 标识符来访问相应的实体; import 语句本身不会有任何实质上的类加载操作. 如下:

```java
// ./wwtest/TestWW.java
package wwtest;

public class TestWW {
    public static void hidvaCom() {}
    public static final String g = "blog.hidva.com";
    public static class Go {
    }
}

// ./Test.java
import wwtest.TestWW;
import wwtest.TestWW.Go;  // 后续可以直接使用 'Go'.
import static wwtest.TestWW.g;  // 后续可以直接使用 'g'.
```

package 是 plat 结构, 没有任何层次性; 虽然 package name 看起来是那么 hierarchical. 一堆 package 居然相同的 prefix 仅是 make these packages the relationship evident, but not to show inclusion.

# Exceptions

java exceptions 体系与 C++ 的很是相似, 只不过 java 定下了很多约定使得其异常体系看上去规范了许多, 比如 java 将 exception 分为三类, 而且还制定了 Catch or Specify Requirement 等. 这里仍只是琐碎地介绍 java 特有的一些点:

异常分类; java 中异常首先被分为两类: checked exception, unchecked exceptions; unchecked exceptions 又根据 exception 是否是由 java application 本身触发的又分为了两类: error, runtime exception; 

error are exceptional conditions that are external to the application, 参见原文举得 IOError 例子. Errors are those exceptions indicated by Error and its subclasses. java 期待对 error 的处理方式是: An application might choose to catch this exception, in order to notify the user of the problem — but it also might make sense for the program to print a stack trace and exit.

runtime exception are exceptional conditions that are internal to the application. Runtime exceptions are those indicated by RuntimeException and its subclasses. java 期待对 runtime excedption 的处理方式是: The application can catch this exception, but it probably makes more sense to eliminate the bug that caused the exception to occur.

checked exception are exceptional conditions that a well-written application should anticipate and recover from. All exceptions are checked exceptions, except for those indicated by Error, RuntimeException, and their subclasses. java 通过 Catch or Specify Requirement 来约定了对 checked exception 的处理方式, requirement 具体细节参见原文, 简单了解一下即可, 毕竟不符合 requirement 时会编译失败的.

Catching More Than One Type of Exception with One Exception Handler; 参见原文了解其语义, 语法. 这里按我理解, 以原文例子为例, 此时 `ex` 类型是不确定的; 当 catch block 捕捉了 more than one type of exception 时, 其对应的处理逻辑就不应该再依赖于 ex 的具体类型了, 此时 catch block 关注的是抛出了这些异常, 而不是具体抛出了什么样的异常; ~~打禅机真令人舒适~~.

The finally Block; ~~这里感觉关键词 `final`, `finally` 可以互相复用嘛, 还能省掉一个关键词了.~~ 再说 finally block 之前, 先看下 statement 概念, 就像上面定义的: A statement forms a complete unit of execution. 按我理解, 整个 try-catch-finally block 是一条 statement, finally block 会在执行流将要跳出当前 try-catch-finally statement 开始执行下一条 statement 之间执行; 执行流将要跳出当前 statement 的原因有很多: 比如执行了 try block 中的 return statement, 或者在执行 try block, catch block 时抛出了异常, 或者 try block, catch block 中不存在下一条 statement 了等等; 整个 try-catch-finally statement 执行起来大概是这样的: 

1.    首先执行 try block, 然后根据需要执行相应的 catch block, 这其中发生了会导致执行流跳出 try-catch-finally statement 的原因 A; 
2.    开始执行 finally block, 在 finally block 中可以通过 return statement, 再抛出一个异常生成一个新的跳出 try-catch-finally statement 的原因 B, B 会覆盖 A.
3.    执行流退出 try-catch-finally statement, 并根据最终退出原因(A 或者 B)决定下一步流向.

就像阿里集团开发规约中所讲这里禁止在 finally block 中通过 return statement 等方式生成一个新的退出原因!

The try-with-resources Statement; 这里先看一下 resource 的定义: Any object that implements java.lang.AutoCloseable, which includes all objects which implement java.io.Closeable, can be used as a resource. 然后结合 try-witch-resources statement 的语法来阐述一下其执行流程, 语法简要描述如下:

```java
try (
    ResourceType1 resourceObj1 = Expression1;
    ResourceType2 resourceObj2 = Expression2;
    ...
) {
    try block
} catch blocks ...
finally block ...
```

这里执行流程如下:

1.    根据源码顺序从左到右, 从上到下依次初始化 resources; 若所有 resource 都成功初始化, 则继续; 否则调到第 3 步.
2.    执行 try block; 当执行流将要退出 try block 时; 这里可能是正常退出, 也可能是异常退出; 若异常退出, 则将异常对象设置为 currentExceptionObj.
3.    逆序 close 每一个成功初始化的 resource. 即按照 resource 初始化顺序的逆序. 这里如果 close 时抛出了异常 closeExceptionObj, 此时若存在当前异常对象 currentExceptionObj, 则执行 `currentExceptionObj.addSuppressed(closeExceptionObj)`, 然后继续下个 resource 的 close; 若不存在当前异常对象, 则执行 `currentExceptionObj = closeExceptionObj`, 然后继续下个 resource 的 close 流程.
4.    按照 try-catch-finally statement 的语义开始执行 catch block, finally block. 

# Concurrency

java 的并发编程, 并发编程的基本概念大体都是公用的, 比如 golang, C++, java 中都定义的 happen-before 关系等; 所以这里只会介绍 java 语言层面提供的特性工具; java 库层面提供的特性也不会有太多介绍, 需要的可以直接去 [jdk document](https://docs.oracle.com/javase/8/docs/api/index.html) 自取.

interrupt status; 参见原文 'The Interrupt Status Flag' 了解 java Thead interrupt mechanism 实现细节. 本来我还以为是通过 `pthread_kill()` 这种操作呢.

synchronized methods and synchronized statements; 首先来看一下 synchronized 背后细节, 在 java 中, Every object has an intrinsic lock associated with it, 这里 intrinsic lock 又称 monitor lock, monitor; 等同于 C++ 的 `std::recursive_mutex`, 即 synchronized 是可递归的; java 对 synchronized 的处理姿势大概是: 首先确定用来 synchronize 的对象 obj, 然后再进入 synchronized 时执行类似 `obj.lock()` 的操作加锁, 在退出 synchronized 时执行 `obj.unlock()` 类似操作来释放锁. 关于对象 obj 的确定, 在 synchronized static method 时选择 static method 所属类对应的 Class object; 在 synchronized non-static method 时选择 `this`; 在 synchronized statements 时由 java rd 选择指定 obj. 这里 synchronized methods, Synchronized Statements 的语法参见原文了解即可.

java atomic action; 原文中关于 atomic action 的定义与主流类似, 同时原文也给出了 java 中哪些 action 是 atomic 的, 可以看下了解一波. 但是根据原文

>    However, this does not eliminate all need to synchronize atomic actions, because memory consistency errors are still possible.

的意思, 感觉 action 虽然是 atomic 的, 但是 ation 执行完成之后的副作用对其他线程并不是立刻可见的! 这连 C++ `std::memory_order_relaxed` 的语义都没有赶上啊.

java volatile, java 中 Reads and writes are atomic for all variables declared volatile 是 atomic action, 同时 any write to a volatile variable establishes a happens-before relationship with subsequent reads of that same variable. 即等同于 C++ `std::memory_order_acquire/std::memory_order_release` 语义了.

Liveness 概念; A concurrent application's ability to execute in a timely manner is known as its liveness. 原文同时也介绍了影响 liveness 几种现象: 死锁, 活锁, Starvation, 可以参考原文看下.

Object.notify, Object.notifyAll, Object.wait 语义; `Object.wait()` 必须在已经持有 object monitor lock 的前提下调用, 此时等同于 `std::condition_variable::wait()`, 这里 Object 同时充当着 condition variable 以及 lock; `Object.notify()`, `Object.notifyAll()` 也必须在持有 Object monitor lock 前提下调用, 等同于 `std::condition_variable::notify_one()`, `std::condition_variable::notify_all()`. ~~C++ 中 `std::condition_variable::notify_one()` 并不需要持有锁.~~

# The Platform Environment

platform environment; An application runs in a platform environment, defined by the underlying operating system, the Java virtual machine, the class libraries, and various configuration data supplied when the application is launched. 

Properties are configuration values managed as key/value pairs.

System Properties; The System class maintains a Properties object that describes the configuration of the current working environment. Changing system properties is potentially dangerous and should be done with discretion. Many system properties are not reread after start-up and are there for informational purposes. Changing some properties may have unexpected side-effects.

The Security Manager; 按我理解, java Security Manager 实现机制大概是 jvm 会在执行每一个敏感操作时, 比如打开文件, 写文件等, 查询当前 Security Manager, 如果有的话, 来获悉是否允许操作. 一般情况下, java application 都没有 security manager, 所以该内容不作过多介绍.

# 后语

至此, Java Tutorials Learning Paths 第一部分 "New To Java" 学习总结完毕, 后续部分会在今后需要时再行学习, 然后总结更新.

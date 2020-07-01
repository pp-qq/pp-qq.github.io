---
title: "Git-科学地书写 commit message"
tags: [Git, 读后感]
---

## 前言

科学地书写 commit message 有哪些好处:

-   可以利用脚本根据 commit message 很方便地生成 changlog.md
-   可以在某些场合下过滤掉不重要的 commit;比如在使用二分查找修BUG的时候就可以过滤不重要的提交
-   可以在浏览提交历史时提供更好的信息

-   以上我从来没遇到过,大概是因为以前书写 commit message 的方式不科学吧


## 如何书写

### 整体框架

*   commit message 分为三个部分: Header,Body,Footer;各个部分通过空行来分割.
*   commit message 任何一行均不能超过 100 个字符;行过长可能会导致在终端下浏览提交历史不方便.
*   commit message 的结构:

    ```shell
    <type>(<scope>): <subject>  # 这一行是 Header
    <BLANK LINE>
    <body>
    <BLANK LINE>
    <footer>
    ```



### Header 编写

*   type;指定了 commit 所作修改的类型;可以取以下值:

    -   feat (feature);表明本次 commit 新增了某些特性.
    -   fix (bug fix);
    -   docs (documentation);表明本次 commit 仅是做了些文档的增添工作
    -   style (formatting, missing semi colons, …)
    -   refactor
    -   test (when adding missing tests)
    -   chore (maintain);表明本次 commit 仅是做了些维护性工作,比如修改个版本号之类的

*   scope;指定了 commit 所做修改发生在哪些地方;如果程序按照模块化设计的话,这里可以填写本次 commit
    所做修改发生在的模块的模块名

*   subject;对本次 commit 所做修改的简短描述;应该注意以下情况:

    -   首字母不要大写.
    -   结尾不要使用'.';
    -   use imperative, present tense(现在进行时..?): “change” not “changed” nor “changes”.

    其实我觉得木有必要这样吧 @_@


### Body 编写

*   在 Body 编写上,[AngularJS Git Commit Message Conventions][0]就给了2点约束:

    -   和 subject 一样 use imperative, present tense.
    -   包括本次 commit 所做修改的缘由以及与之前行为的比较.

*   那么按照我的理解就是,在 subject 中指定了 commit 所做修改的简短描述;那么在 Body 里面就应该
    详细描述一下 commit 所做修改了.

### Footer 编写

*   Footer;又可划分多个部分;

*   Closes Issue;在 Footer 中使用单独一行用来关闭 Issue;如下:

    ```
    Closes #234
    Closes #123, #245, #992  // 当同时关闭多个 Issue 时,使用', '来分割.
    ```

*   Breaking changes(我的理解是:不兼容的修改);若某次 Commit 做了不兼容的修改;则应该在 Footer
    中以 breaking change block 指出;breaking change block 的格式如下:

    ```
    BREAKING CHANGE: 然后描述本次 commit 所做的修改;为何这样做;迁移注意事项.
    ```

### DEMO

以下 commit message 摘自[angular/angular.js][1] .

```
fix(ngClass): fix watching of an array expression containing an object

Closes #14405
```

 在 Footer 部分同时存在 Closes,以及 BREAKING CHANGE 的情况:

```
fix(ngAria): don't add roles to native control elements

prevent ngAria from attaching roles to textarea, button, select, summary, details, a, and input

Closes  #14076
Closes #14145

BREAKING CHANGE:

ngAria will no longer add the "role" attribute to native control elements
(textarea, button, select, summary, details, a, and input). Previously, "role" was not added to
input, but all others in the list.

This should not affect accessibility, because native inputs are accessible by default, but it might
affect applications that relied on the "role" attribute being present (e.g. for styling or as
directive attributes).
```

scope 是可选的:

```
fix: make files in src/ jshint: eqeqeq compatible

Add exceptions to the rule in input, ngAria, and parse.
For input and ngAria, the exception is to prevent a breaking change in the radio directive.
A test for the input behavior has been added.
For parse, the exception covers non-strict expression comparison.
```

### revert commit 的 commit message

若某次 commit(下称 commitA) 是对另一次 commit(下称 commitB) 的 revert(参见 git revert);
则 commitA 的 commit message 格式如下:

```
revert: "commitB 的 Header"

This is reverted from commit "commitB的 SHA1 值"
```

如:

```
revert: "fix(ngRoute): allow `ngView` to be included in an asynchronously loaded template"

This reverts commit 5e37b2a7fd0b837fdab97bb3525dabefc0ea848a.
Eagerly loading `$route`, could break tests, because it might request the root or default route
template (something `$httpBackend` would know nothing about).

It will be re-applied for `v1.6.x`, with a breaking change notice and possibly a way to disable
the feature is tests.

Fixes #14337
```


## 参考

*   [AngularJS Git Commit Message Conventions][0]

[0]: <https://docs.google.com/document/d/1QrDFcIiPjSLDn3EL15IJygNPiHORgU1_OOAqWjiDU5Y/edit#>
[1]: <https://github.com/angular/angular.js>



**转载请注明出处!谢谢**

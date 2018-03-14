---
title: "build/core/build-local.mk 实现"
tags: ["Android NDK"]
---

## 确定 NDK_ROOT

*   `NDK_ROOT`;Android NDK 的安装目录.

```makefile
NDK_ROOT := $(dir $(lastword $(MAKEFILE_LIST)))
NDK_ROOT := $(strip $(NDK_ROOT:%build/core/=%))
NDK_ROOT := $(subst \,/,$(NDK_ROOT))
NDK_ROOT := $(NDK_ROOT:%/=%)
ifeq ($(NDK_ROOT),)
    # for the case when we're invoked from the NDK install path
    NDK_ROOT := .
endif
```

## include build/core/init.mk

## 确定 NDK_PROJECT_PATH

*   `NDK_PROJECT_PATH`;Android 项目的路径;在该路径下存在 AndroidManifest.xml 文件,或者
    存在 jni/Android.mk 文件.

```c
if (APP_PROJECT_PATH 存在) {
    if (NDK_PROJECT_PATH 不存在)
        NDK_PROJECT_PATH = APP_PROJECT_PATH;
    else if (NDK_PROJECT_PATH != APP_PROJECT_PATH)
        输出 warning;
} else {
    if (NDK_PROJECT_PATH == 'null') {
        此时将不试图检测 NDK_PROJECT_PATH 的值;
    } else if (NDK_PROJECT_PATH 未定义) {
        在当前目录以及其父目录中确定 AndroidManifest.xml 是否存在;若在其中某个目录中找到该文件,
        则该目录就是 NDK_PROJECT_PATH;

        如果追溯到根目录后发现 AndroidManifest.xml 仍不存在,则检测当前目录以及其父目录确定 jni/Android.mk
        是否存在;若存在,则该目录就是 NDK_PROJECT_PATH;

        如果还未确定 NDK_PROJECT_PATH 的值;报错.
    }
}
```

## 确定 NDK_APPLICATION_MK

*   `NDK_APPLICATION_MK`;Application.mk 的路径;

```c
if ($NDK_PROJECT_PATH/jni/Application.mk 存在)
    NDK_APPLICATION_MK = $NDK_PROJECT_PATH/jni/Application.mk;
else
    NDK_APPLICATION_MK = $(NDK_ROOT)/build/core/default_application.mk;
```

## ToDo...

后续...



**转载请注明出处!谢谢**

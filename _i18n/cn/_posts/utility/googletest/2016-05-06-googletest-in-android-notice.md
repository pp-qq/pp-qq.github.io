---
title: "googletest 在 Android 上的坑"
tags: [gtest, "Android NDK"]
---


## 链接过不了?

*   目录布局以及文件大概内容如下:

    ```shell
    $ tree
    .
    └── jni
        ├── Android.mk
        ├── Application.mk
        ├── test_1.cc
        └── test_2.cc

    $ cat jni/Android.mk
    LOCAL_PATH := $(call my-dir)

    LOCAL_PATH_BAK := $(LOCAL_PATH)
    $(call import-module,third_party/googletest)
    LOCAL_PATH := $(LOCAL_PATH_BAK)

    include $(CLEAR_VARS)
    LOCAL_MODULE := gtest_android

    LOCAL_SRC_FILES := test_1.cc test_2.cc

    LOCAL_STATIC_LIBRARIES := googletest_main

    LOCAL_LDLIBS := -llog

    include $(BUILD_EXECUTABLE)
    ```

    然后在执行'ndk-build'时出错:

    ```shell
    error: undefined reference to 'typeinfo for testing::Test'
    collect2: error: ld returned 1 exit status
    ```

*   修复方案是更改'googletest/Android.mk',为'googletest_static','googletest_shared'
    这俩 module 开启 rtti,exceptions C++特性,如下:

    ```makefile
    include $(CLEAR_VARS)
    LOCAL_MODULE := googletest_static
    LOCAL_SRC_FILES := $(googletest_sources)
    LOCAL_C_INCLUDES := $(googletest_includes)
    LOCAL_EXPORT_C_INCLUDES := $(googletest_includes)
    LOCAL_CPP_FEATURES := rtti exceptions # 改动在这
    include $(BUILD_STATIC_LIBRARY)

    include $(CLEAR_VARS)
    LOCAL_MODULE := googletest_shared
    LOCAL_SRC_FILES := $(googletest_sources)
    LOCAL_C_INCLUDES := $(googletest_includes)
    LOCAL_CFLAGS := -DGTEST_CREATE_SHARED_LIBRARY
    LOCAL_EXPORT_C_INCLUDES := $(googletest_includes)
    LOCAL_CPP_FEATURES := rtti exceptions # 改动在这
    include $(BUILD_SHARED_LIBRARY)
    ```

*   实际上,就在刚刚,我把之前改动的'LOCAL_CPP_FEATURES'从'googletest/Android.mk'去除了之
    后发现居然正确编译链接过去了 @_@;这下子...

## 测试用例去哪了?

*   问题现象;首先看如下代码例子:

    ```shell
    $ tree .
    .
    └── jni
        ├── Android.mk
        ├── Application.mk
        ├── test_1.cc
        └── test_2.cc
    ```

    其中'test_1.cc','test_2.cc'的内容分别是:

    ```cpp
    #include "gtest/gtest.h"

    TEST(XXXTest,test1)
    {
        EXPECT_EQ(1,1);
        EXPECT_EQ(0,0);
    }

    TEST(XXXTest,test2)
    {
        EXPECT_EQ(1,1);
        EXPECT_EQ(0,0);
    }
    ```

    ```cpp
    #include "gtest/gtest.h"

    TEST(XXXTest1,test1)
    {
        EXPECT_EQ(1,1);
        EXPECT_EQ(0,0);
    }

    TEST(XXXTest1,test2)
    {
        EXPECT_EQ(1,1);
        EXPECT_EQ(0,0);
    }
    ```

    'Android.mk','Application.mk'的内容分别是:

    ```makefile
    LOCAL_PATH := $(call my-dir)

    LOCAL_PATH_BAK := $(LOCAL_PATH)
    $(call import-module,third_party/googletest)
    LOCAL_PATH := $(LOCAL_PATH_BAK)

    include $(CLEAR_VARS)
    LOCAL_MODULE := gtest_android
    LOCAL_STATIC_LIBRARIES := googletest_main test1 test2
    include $(BUILD_EXECUTABLE)

    include $(CLEAR_VARS)
    LOCAL_MODULE := test1
    LOCAL_SRC_FILES := test_1.cc
    LOCAL_STATIC_LIBRARIES := googletest_static
    include $(BUILD_STATIC_LIBRARY)

    include $(CLEAR_VARS)
    LOCAL_MODULE := test2
    LOCAL_SRC_FILES := test_2.cc
    LOCAL_STATIC_LIBRARIES := googletest_static
    include $(BUILD_STATIC_LIBRARY)
    ```

    ```makefile
    APP_OPTIM := debug
    APP_PLATFORM := android-21
    APP_ABI :=  armeabi-v7a   arm64-v8a
    APP_STL := gnustl_static
    NDK_TOOLCHAIN_VERSION = 4.9
    ```

    然后执行'ndk-build',并推送到手机上执行之后:

    ```shell
    root@hammerhead:/data/local/tmp # ./gtest_android
    Running main() from gtest_main.cc
    [==========] Running 0 tests from 0 test cases. # 没有测试用例!!??!!
    [==========] 0 tests from 0 test cases ran. (0 ms total)
    [  PASSED  ] 0 tests.
    ```

*   问题解决方案;对'Android.mk'作出如下修改:

    ```diff
    diff --git a/jni/Android.old.mk b/jni/Android.mk
    index 3f0318f..e2b8b09 100644
    --- a/jni/Android.old.mk
    +++ b/jni/Android.mk
    @@ -6,7 +6,7 @@ LOCAL_PATH := $(LOCAL_PATH_BAK)

     include $(CLEAR_VARS)
     LOCAL_MODULE := gtest_android
    -LOCAL_STATIC_LIBRARIES := googletest_main test1 test2
    +LOCAL_WHOLE_STATIC_LIBRARIES := googletest_main test1 test2
     include $(BUILD_EXECUTABLE)

     include $(CLEAR_VARS)
    ```

    然后重新'ndk-build',推送到手机上执行:

    ```shell
    root@hammerhead:/data/local/tmp # ./gtest_android
    Running main() from gtest_main.cc
    [==========] Running 4 tests from 2 test cases.
    [----------] Global test environment set-up.
    [----------] 2 tests from XXXTest
    [ RUN      ] XXXTest.test1
    [       OK ] XXXTest.test1 (0 ms)
    [ RUN      ] XXXTest.test2
    [       OK ] XXXTest.test2 (0 ms)
    [----------] 2 tests from XXXTest (13 ms total)

    [----------] 2 tests from XXXTest1
    [ RUN      ] XXXTest1.test1
    [       OK ] XXXTest1.test1 (0 ms)
    [ RUN      ] XXXTest1.test2
    [       OK ] XXXTest1.test2 (0 ms)
    [----------] 2 tests from XXXTest1 (0 ms total)

    [----------] Global test environment tear-down
    [==========] 4 tests from 2 test cases ran. (23 ms total)
    [  PASSED  ] 4 tests.
    ```

*   问题原因分析;是因为在 gtest_android 模块链接过程中,链接器发现其对 libtest1.a,libtest2.a
    中的 .o 没有依赖,所以未将 libtest1.a,libtest2.a 中的 .o 打包到最终可执行文件中,此时使
    用 readelf 可以看出最终可执行文件并没有 test_1.o,test_2.o 中定义的符号:

    ```shell
    # 注意,此时不能查看 libs/armeabi-v7a/gtest_android 中的符号定义,因为 ndk-build 最后
    # 将生成的可执行文件安装到 libs 目录下时,会使用 strip 移除掉所有不必要保留的符号.
    $ readelf -s -W obj/local/armeabi-v7a/gtest_android | c++filt  | grep XXX
    # 没有输出.
    ```

    所以只需要在链接阶段,强制使用`--whole-archive`选项强制将 .a 文件中的所有 .o 文件链接到
    最终的可执行文件中即可,反映到 ndk-build 上,也就是使用`LOCAL_WHOLE_STATIC_LIBRARIES`.

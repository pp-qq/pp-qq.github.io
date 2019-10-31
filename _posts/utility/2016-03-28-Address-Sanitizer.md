---
title: "Address Sanitizer 使用"
hidden: false
tags: [gcc]
---

## Address Sanitizer 是什么

*   Address Sanitizer;是一种检测内存读取是否合法的一种机制.其会在应用访问无效内存时
    给出错误信息.

## Address Sanitizer 实现机理

*   Address Sanitizer;会在进程的内存空间中开设一段影子内存区,并将进程的整个内存空间与该内存区建
    立一种映射关系;具体就是将进程内存空间中的 8 字节映射到影子内存区中的 1 字节.并且在该1字节中记
    录其在内存空间对应8字节的一些信息,如地址是否合法之类.

*   当在编译时开启了 Address Sanitizer,其会在每一次内存存取时添加额外的指令来检查将要访问的内存
    地址是否合法,并且在不合法时输出错误信息.

按我理解, Asan 同时也有一些 hook 机制, 比如可能 hook 了 malloc, free 等内存分配函数. 本来我以为 asan 无法跨越 so 边界来着, 即如果 1.so 编译时未指定 asan, 主程序 main 链接了 1.so, 并且开启了 asan; 按我理解当 main 中访问 1.so 内分配的内存时, asan 应该会报错来着, 毕竟在 main asan 视角中, main 访问的内存未被分配过. 但实测发现 asan 能覆盖这种情况.

## 如何使用 Address Sanitizer

*   使用`-fsanitize=address`来开启 Address Sanitizer.如:

    ```c++
    int
    main(int argc,char **argv)
    {
        // 这里也可以换成 char *buf = static_cast<char*>(malloc(3));
        // Address Sanitizer 也可以检测出.
        char buf[3] {};
        buf[3] = '3';
        return buf[0];
    }
    ```

    ```shell
    $ g++ -Wall -std=gnu++11 address_sanitizer_test.cc
    $ ./a.out # 成功执行;即使栈已经溢出了.
    $ g++ -Wall -std=gnu++11 address_sanitizer_test.cc -fsanitize=address
    $ ./a.out # 检测到栈溢出了.
    =================================================================
    ==18324==ERROR: AddressSanitizer: stack-buffer-overflow on address... 此处省略若干字...
    ```

Address sanitizer 的行为可以受一些环境变量控制, 具体参见 [google/sanitizers](https://github.com/google/sanitizers). 在实际使用中, 可能会经常性使用某些设置, 如: `export LSAN_OPTIONS=leak_check_at_exit=false`, `export ASAN_OPTIONS="disable_coredump=0:unmap_shadow_on_exit=1:abort_on_error=1"`(To generate a core dump when ASAN detects some error.) 等. 

**转载请注明出处!谢谢**

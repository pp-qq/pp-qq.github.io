---
title: Address Sanitizer 使用
---

## Address Sanitizer 是什么
 
*   Address Sanitizer;地址消毒剂,是一种检测内存读取是否合法的一种机制.其会在应用访问无效内存时
    给出错误信息.

## Address Sanitizer 实现机理

*   Address Sanitizer;会在进程的内存空间中开设一段影子内存区,并将进程的整个内存空间与该内存区建
    立一种映射关系;具体就是将进程内存空间中的 8 字节映射到影子内存区中的 1 字节.并且在该1字节中记
    录其在内存空间对应8字节的一些信息,如地址是否合法之类.
    
*   当在编译时开启了 Address Sanitizer,其会在每一次内存存取时添加额外的指令来检查将要访问的内存
    地址是否合法,并且在不合法时输出错误信息.

## 如何使用 Address Sanitizer

### gcc

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



**转载请注明出处!谢谢**

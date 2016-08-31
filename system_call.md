
## open

The file descriptor returned by a successful call will be the lowest-numbered file descriptor not currently open for the process.
The file offset is set to the beginning of the file;即使指定了 O_APPEND 标志,这里需要注意 O_APPEND 标志的语义

概念:open file description;具有以下属性:
    offset,在 open() 打开文件时会被初始化为 0.
    file status flags;由 open() 负责初始化,后续可以通过 fcntl() 来更改.

flags;标志位集合,可分为:
必须标志;
*   access modes;O_RDONLY,O_WRONLY,O_RDWR 中一个.也可以为 3,仅是 Linux 支持的一种特殊情况.

可选标志;下面以组的形式来介绍可选标志;

*   file creation flags

    -   O_CLOEXEC,enable the close-on-exec flag for the new file descriptor.一方面
        减少了一次 fcntl() 调用,另一方面保证原子性:

        fd = open(...);
        fcntl(fd,O_CLOEXEC);// 设置 O_CLOEXEC 标志.
        这样在 open() 与 fcntl() 之间存在时间窗口.
    -   O_CREAT;当文件不存在时,会创建指定的文件(此时关于新文件的所有者,以及所有组请参考 AUPE).
    O_DIRECTORY,告诉 open() 我们希望打开的是一个目录;这样 open() 会在 pathname 不是目录时出错.
    O_EXCL
        -   与 O_CREAT 一起使用时用来确保文件一定被创建!即若此时文件已经存在,则返回出错,而不是打开文件.

            -   当 pathname 存在并且是符号链接时,此时也会出错,而不会对符号链接进行解引用来
                判断符号链接指向的文件是否存在.

        -   当单独使用时,一般情况下,是未定义的.但是在 Linux >= 2.6;并且 pathname 是一个 block device
            时,此时当 block device is in use by the system 时,open() 会返回 EBUSY.

        -   On NFS, O_EXCL is supported only when using NFSv3 or later on
            kernel 2.6 or later.这里建议了一种利用 link(2) 来实现原子文件锁的方式,但是并
            没有看得太懂,暂且放在这里.


    O_NOCTTY,If pathname refers to a terminal device—see tty(4)—it will not become the process's controlling terminal even if the process does not have one.

        -   这里记录了对 Linux 终端的理解(虽然到现在,也不是很理解 Linux 中终端的概念).

            terminal device;终端设备,即是一款设置,用于人机交互,也就是说通过 terminal device 来与主机通信.
            controlling terminal;控制终端是进程的属性之一,在进程的控制终端上通过按下特殊键可以控制进程的行为(如按下 CTRL+C,可以发送 SIGINT 信号给进程).


    O_NOFOLLOW,If pathname is a symbolic link, then the open fails. Symbolic links in earlier components of the pathname will still be followed.
    O_TMPFILE,此时 access mode 必须取 O_WRONLY 或者 O_RDWR.pathname 必须是一个目录.
        若不与 O_EXCL 一起使用,则 open() 会在 pathname 指定的目录下创建一个无名文件(按照我的理解,就是仅分配了 Inode 节点,文件名部分为空),并返回一个指向着该文件的文件描述符.
        之后可以通过 link() 来将一个文件名与这个无名文件的 inode 绑定在一起.

        若与 O_EXCL 一起使用,则指定了不能将无名文件的 inode 与一个文件名绑定在一起.

        O_TMPFILE 由底层文件系统来支持,即存在不支持 O_TMPFILE 的文件系统.


    O_TRUNC,这个比较适合用伪代码来描述其语义,如下:

        if (path is a fifo or terminal device)
            忽略该标志;
        else if (path is a regular file and access mode 设置了可写(如 O_WRONLY,O_RDWR)
            将文件清空
        else
            行为未定义.

*   file status flags

    -   O_APPEND,以追加模式打开一个文件,意味着每一次调用 write() 写入时,都会先使用 lseek() 将
        偏移移至文件末尾,并且 lseek(),write() 是原子操作,所以说是进程安全,或者线程安全的.

        -   Q1:如果是其他写操作呢,比如 writev(),pwrite() 之类的,没试过.

        在 NFS 上,多个进程以 O_APPEND 打开同一文件之后,同时写文件可能会导致文件被污染,因为
        NFS 不支持追加模式打开文件.那我觉得这里你可以返回出错啊,感觉可能会是一个坑.

    -   O_ASYNC,启用 signal-driven I/O,即当文件描述符上输入,输出变得可用时,会生成一个信号(默认是 SIGIO,可以通过 fcntl() 修改).
        仅在 terminals, pseudoterminals, sockets, and (since Linux 2.6) pipes and FIFOs 上可用.

        -   Currently, it is not possible to enable signal-driven I/O by specifying
            O_ASYNC when calling open(); use fcntl(2) to enable this flag.

        -   具体请了解 fcntl() 吧.

    -   O_DIRECT; Try to minimize cache effects of the I/O to and from this
        file.  In general this will degrade performance, but it is
        useful in special situations, such as when applications do
        their own caching.

    -   O_DSYNC;Write operations on the file will complete according to the requirements
        of synchronized I/O data integrity completion.按照我的理解就是仅当 write operations
        满足了 synchronized I/O data integrity completion 的要求时 write operations 才会被
        认为是完成的,即 write operations 才会返回.即此后的 write()(以及类似的操作)都等同于在完成
        自身调用之后,再调用 fdatasync(),当然这个也具有原子性.

    -   O_SYNC;使用此标志打开文件之后,对文件描述符进行 write operations 将直至满足了 synchronized I/O file integrity completion 以及
        synchronized I/O data integrity completion 的要求后才会返回.即 write()(以及类似 API)将会在完成自身调用后,再一次调用 fsync().

        Q1:此时对于 Read operations 呢,毕竟 read operations 会更改文件的 last access time,那么是否是每一次 read operations 都将等到 last access time 并写入到磁盘上之后才返回?


        O_DSYNC,O_SYNC 分别表示不同的 synchronized I/O 模型(就像 C++11 内存模型也可能支持多个),具体不同的语义以及对效率也有不同的影响.
        fdatasync() 会将所有的数据以及必要的 metadata 信息 transferred to the underlying hardware.而 fsync() 会将数据以及所有的 metadata() transferred to the underlying hardware.
        必要的 metadata 信息指的是若该 metadata 不被  transferred to the underlying hardware,那么下一次 read() 可能会失败,以 st_mtime,st_size 为例,st_size 就是必要的 metadata,因为
        若其不会刷新到 underlying hardware,则下一次 read 可能会失败,比如在 write() 之后断电导致数据没有机会送往 underlying hardware,那么在重启之后的 read() 将无法读取后续内容.而 st_mtime
        则不是必要的 metadata.

        transferred to underlying hardware 是个啥意思?送往底层硬件?以磁盘为例,这里是指数据已经在磁盘上保存了还是仅仅将数据写入到磁盘的排队序列呢?

    -   O_LARGEFILE;为了了解该标志,首先了解一下 O_LARGEFILE 的由来(注意,这部分仅是我的理解,未经过认证,不过我觉得应该没多大偏差,因为挺合理的@_@).
        在老版本 Linux 内核中,即尚没有 pread64(),pwrite64 等系统调用的内核中,在 32 位机器上,使用 4 bytes来表示文件偏移,因此限制了文件的最大大小为 2^32 bytes(4GB).
        为了避免这部分限制,提供了一套以 64 结尾的 API,同时对文件的偏移表示也强行使用了 64 位(类型可能是 unsigned long long).在 32 位机器上,4 bytes 整数的效率肯定比
        8 bytes 整数效率高,因此内核中对文件偏移的表示有 2 套,32 位,64 位;当应用不需要创建大文件时,使用 32 位偏移即可,还能保证效率最优;

        当然在上述所述仅是 VFS 中的接口,当文件系统自身仅支持最大 4 GB 文件时,这样其对与 pread64,pwrite64 的实现可能是直接调用 pread,pwrite 完成(当然这里肯定会检查偏移
        是否会溢出).当文件系统支持比 4GB 还大的文件时,其可能主要实现 pread64,pwrite64,然后其对 pread,pwrite 的实现可能是直接调用了 pread64,pwrite64.

        因此对于应用来说,当其需要创建大文件时(大于 4GB),其需要在 open() 时指定 O_LARGEFILE 标志.并且还需要在所有头文件之前定义 _LARGEFILE64_SOURCE,不然 pread64,pwrite64,O_LARGEFILE 等这些标识符不可见(这里仅是声明不可见,
        但实现都在,GLIBC 大概出于某种考虑才提供该宏的吧).

        Setting the _FILE_OFFSET_BITS feature test macro to 64 (rather than using O_LARGEFILE) is the preferred method of accessing large files on 32-bit systems.即当把 _FILE_OFFSET_BITS 设置为 64 时,
        就不需要显式使用 O_LARGEFILE 文件了;此时创建的所有文件都将是大文件(大于 4GB 的文件),看了一下实现,当 _FILE_OFFSET_BITS 设置为 64 时,下列宏会生效:

            #define open open64 // open64() 会自动设置 O_LARGEFILE 标志.
            #define pread pread64

    -   O_NOATIME;对使用此标志打开的文件描述符进行 read() 时并不会更新文件的 last access time.

        This flag is intended for use by indexing or backup programs, where its use can significantly reduce the amount of disk activity(因为这个时候不需要频繁更新 inode 信息了,所以减少了磁盘活动).

        This flag may not be effective on all filesystems.One example is NFS, where the server maintains the access time.

    -   O_NONBLOCK;**When possible**, the file is opened in nonblocking mode.当文件描述符处于 nonblocking mode 时,包括本次 open() 调用以及后续在该文件描述符之上的所有操作都不会导致进程阻塞.

        O_NONBLOCK 对于 regular file 以及 block devices 无效;即无论是否设置了 O_NONBLOCK,当作用在 regular file,block devices 之上的 operations 需要阻塞时其总会阻塞.

        关于 open() 也不会阻塞的解释,在某些情况下,使用 open() 以阻塞模式打开文件时,open() 可能会阻塞,直至文件描述符准备好进行 I/O,当指定了 O_NONBLOCK 标志,并且文件描述符以非阻塞的模式打开,那么 open() 不会阻塞,也就是其返回
        的文件描述符可能尚未准备好I/O.

    -   O_PATH;使用 O_PATH open() 打开文件时,文件本身并没有被打开,此时返回的文件描述符仅有以下 2 个用途:

        1.  在 filesystem tree 中表示着一个位置,即此时该文件描述符可以作为 *at() 系 API 的 dirfd 参数.
        2.  执行一些仅作用于文件描述符层次的操作,如: dup(),dup2();很显然并执行 read(),write() 这些不单单位于文件描述符层次的 API.

        When O_PATH is specified in flags, flag bits other than O_CLOEXEC, O_DIRECTORY, and O_NOFOLLOW are ignored.

        当 pathname 是符号链接,并且 O_PATH | O_NOFOLLOW 一同使用时,此时 open() 不会出错,并且返回的文件描述符关联着该符号链接.
        将该文件描述符作为 *at() 系 API 的 dirfd 参数,并且路径名为空时,将使这些 *at() 系 API 作用于符号链接自身上.

*   file creation flags 与 file status flags 的区别在于 file status flags 被保存在 open
    file description 中,可以通过 fcntl() 获取以及修改.

    -   不过好像并不是所有的 file status flags 都支持获取与修改.


modes,当 flags 中设置了 O_CREAT 或者 O_TMPFIL 时,必须提供该参数;其他情况下,该参数可以不提供.
当 open() 会创建新文件时,modes 指定了新文件的 file mode bit.即 file mode bit = mode & ~umask.
此时 modes 仅对之后对新文件的访问生效,即本次 open() 不生效,如下:
    int fd = cxx_open(argv[1],O_WRONLY | O_CREAT,0444); // 成功打开文件,即使权限不允许.
    fd = cxx_open(argv[1],O_WRONLY | O_CREAT,0444); // 无法打开文件.
可取值:
              S_IRWXU  00700 user (file owner) has read, write, and execute
                       permission

              S_IRUSR  00400 user has read permission

              S_IWUSR  00200 user has write permission

              S_IXUSR  00100 user has execute permission

              S_IRWXG  00070 group has read, write, and execute permission

              S_IRGRP  00040 group has read permission

              S_IWGRP  00020 group has write permission

              S_IXGRP  00010 group has execute permission

              S_IRWXO  00007 others have read, write, and execute permission

              S_IROTH  00004 others have read permission

              S_IWOTH  00002 others have write permission

              S_IXOTH  00001 others have execute permission

              According to POSIX, the effect when other bits are set in mode
              is unspecified.  On Linux, the following bits are also honored
              in mode:

              S_ISUID  0004000 set-user-ID bit

              S_ISGID  0002000 set-group-ID bit (see stat(2))

              S_ISVTX  0001000 sticky bit (see stat(2))

openat() 与 open() 完全一致,仅是指定文件名的方式不一样而已.

if (文件是新创建的)
    文件.st_atime = .st_mtime = .st_ctime = 当前时间;
    文件的父目录.st_mtime = 文件的父目录.st_ctime = 当前时间;
else if (由于设置了 O_TRUNC 标志导致文件被修改)
    文件.st_mtime = 文件.st_ctime = 当前时间;
    // 实际上,试了一下,即使文件本身为空,然后以 O_TRUNC 的标志打开文件也会将 st_ctime,st_mtime
    // 更改为当前时间;这是根据 O_TRUNC 的语义而定.

/proc/$PID/fd;目录下存放着 pid 为 $PID 的进程打开的文件描述符列表;
/proc/$PID/fdinfo;目录下存放着 pid 为 $PID 的进程打开的文件描述符更详细的信息.

TODO:
Note 节中 FIFOs 部分暂且未看.
O_DIRECT 在 Note 节中的部分未看.

==================================

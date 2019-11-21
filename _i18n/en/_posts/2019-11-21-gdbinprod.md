---
title: Use GDB in production is risky
hidden: false
tags: [experience]
---

The GDB use [ptrace](http://man7.org/linux/man-pages/man2/ptrace.2.html) system call to implement breakpoint, when we use 'b' command to create a breakpoint in GDB, GDB will calculate the address of instruction at which the process(attached by gdb) should stop according to debug information stored in process, then call ptrace(PTRACE_PEEKTEXT) to get the instruction content at this address, and call ptrace(PTRACE_POKEDATA) to change the instruction content at this address to 'int3'(0xCC):

```
# output of `strace -p `pidof gdb``
ptrace(PTRACE_PEEKTEXT, 45391, 0x400648, [0x2009ff058be58948]) = 0
ptrace(PTRACE_POKEDATA, 45391, 0x400648, 0x2009ff05cce58948) = 0 
```

the first call of ptrace(PTRACE_PEEKTEXT) to get origin instruction content and GDB will save it in a list to restore the instruction content of process when gdb exits, or to find which breakpoint is hit when GDB receives a SIGCHLD signal(si_status=SIGTRAP). The ptrace(PTRACE_POKEDATA) call change the instruction content to 'int3'(0xCC). After this, when the execution of process attached by gdb reaches the 'int3' instruction, kernel will send the process a SIGTRAP signal, which would stop the process(the default behavior), then kernel will send GDB a SIGCHLD signal which tells GDB the process is stopped by SIGTRAP, then GDB will know that the process hits a breakpoint.

```
# Change the instruction content to 'int3'(0xCC)
ptrace(PTRACE_PEEKTEXT, 54586, 0x400648, [0x2009ff058be58948]) = 0 <0.000031>
ptrace(PTRACE_PEEKTEXT, 54586, 0x400648, [0x2009ff058be58948]) = 0 <0.000023>
ptrace(PTRACE_POKEDATA, 54586, 0x400648, 0x2009ff05cce58948) = 0 <0.000035>
ptrace(PTRACE_PEEKTEXT, 54586, 0x7f0cf7722e98, [0x4800013281e89000]) = 0 <0.000030>
ptrace(PTRACE_PEEKTEXT, 54586, 0x7f0cf7722e98, [0x4800013281e89000]) = 0 <0.000024>
ptrace(PTRACE_POKEDATA, 54586, 0x7f0cf7722e98, 0x4800013281e8cc00) = 0 <0.000027>
ptrace(PTRACE_PEEKTEXT, 54586, 0x7f0cf7733508, [0x4840488b48900174]) = 0 <0.000024>
ptrace(PTRACE_PEEKTEXT, 54586, 0x7f0cf7733508, [0x4840488b48900174]) = 0 <0.000012>
ptrace(PTRACE_POKEDATA, 54586, 0x7f0cf7733508, 0x4840488b48cc0174) = 0 <0.000046>
ptrace(PTRACE_PEEKTEXT, 54586, 0x7f0cf77344c0, [0x20db9f3d8390ff]) = 0 <0.000024>
ptrace(PTRACE_PEEKTEXT, 54586, 0x7f0cf77344c0, [0x20db9f3d8390ff]) = 0 <0.000024>
ptrace(PTRACE_POKEDATA, 54586, 0x7f0cf77344c0, 0x20db9f3d83ccff) = 0 <0.000029>

# Continue the process
ptrace(PTRACE_CONT, 54586, 0x1, SIG_0) = 0 <0.000028>

# The process hits a breakpoint
--- SIGCHLD {si_signo=SIGCHLD, si_code=CLD_TRAPPED, si_pid=54586, si_status=SIGTRAP, si_utime=0, si_stime=0} ---

ptrace(PTRACE_PEEKUSER, 54586, offsetof(struct user, u_debugreg) + 48, [0]) = 0 <0.000024>
ptrace(PTRACE_GETREGS, 54586, 0, 0x7fff1a28c0f0) = 0 <0.000025>
ptrace(PTRACE_GETREGS, 54586, 0, 0x7fff1a28c0f0) = 0 <0.000023>
ptrace(PTRACE_SETREGS, 54586, 0, 0x7fff1a28c0f0) = 0 <0.000024>

# Restore instruction content.
ptrace(PTRACE_PEEKTEXT, 54586, 0x400648, [0x2009ff05cce58948]) = 0 <0.000028>
ptrace(PTRACE_PEEKTEXT, 54586, 0x400648, [0x2009ff05cce58948]) = 0 <0.000024>
ptrace(PTRACE_PEEKTEXT, 54586, 0x400648, [0x2009ff05cce58948]) = 0 <0.000040>
ptrace(PTRACE_POKEDATA, 54586, 0x400648, 0x2009ff058be58948) = 0 <0.000050>
ptrace(PTRACE_PEEKTEXT, 54586, 0x7f0cf7722e98, [0x4800013281e8cc00]) = 0 <0.000038>
ptrace(PTRACE_POKEDATA, 54586, 0x7f0cf7722e98, 0x4800013281e89000) = 0 <0.000030>
ptrace(PTRACE_PEEKTEXT, 54586, 0x7f0cf7733508, [0x4840488b48cc0174]) = 0 <0.000035>
ptrace(PTRACE_POKEDATA, 54586, 0x7f0cf7733508, 0x4840488b48900174) = 0 <0.000034>
ptrace(PTRACE_PEEKTEXT, 54586, 0x7f0cf77344c0, [0x20db9f3d83ccff]) = 0 <0.000024>
ptrace(PTRACE_POKEDATA, 54586, 0x7f0cf77344c0, 0x20db9f3d8390ff) = 0 <0.000029>
```

So if we use GDB in the production environment, and GDB exits unexpectedly without restore instruction content from int3(0xCC) to their original content, the process attached by GDB will be terminate by SIGTRAP signal when the execution of process reaches a breakpoint. The unexpected exit of GDB had happened many times in my environment when I debug a Postgres backend, and then the Postmaster will enter recovery mode because the backend was killed by Trace/breakpoint trap(SIGTRAP signal), just like this:

```
$./a.out 
hidva.com
f(): 0
f(): 1
# Execute kill -SIGTRAP `pidof a.out` in another console.
Trace/breakpoint trap (core dumped)
```
---
title: ARM 模拟 x86 环境不能直接使用 gdb 调试的解决方案
date: 2023-11-01 20:24:13
excerpt: MacOS M2 模拟 x86 容器环境的调试方案
categories: LIVEHOOD
---

## 现场

我的开发环境为 `arm`（`M2`），但是我的项目只支持运行在 `x86` 上，这可以借助 `rosetta` 的转译从而适配 `arm`（这个过程是透明的）。但是目前这种方法可能还存在局限性，比如不能够直接使用 `gdb` 进行调试，解决这个问题的答案是使用 `gdbserver`

先放上结论

- 将你要调试的程序使用 `[sudo] ROSETTA_DEBUGSERVER_PORT=<某个空闲端口>` 来运行
- 分情况讨论
    + `gdb` 调试：另一个终端输入 `gdb`，运行后依次输入
        + `set architecture i386:x86-64`
        + `file <上一步运行的调试程序的绝对路径>`
        + `target remote localhost:<上一步命令的端口>`
    + `visual studio code` 图形化界面调试：
        + `launch.json` 增加属性 `"miDebuggerServerAddress": "localhost:<上一步命令的端口>"`

<br></br>

现在回过头来，假设已经部署好了一个 `x86` 环境

![](https://pic.imgdb.cn/item/654384f0c458853aefbd15d2.png)

使用下面这个例子

```cpp
#include <iostream>

int
main(void) {
    int i = 0;
    double d = 1.0;
    std::cout << "i = " << i << ";"
        "d = " << d << std::endl;
    return 0;
}
```

编译

```shell
g++ -std=c++17 -g -o test test.cc
```

`visual studio code` 使用以下这个 `launch.json` 来调试

```json
{
    // Use IntelliSense to learn about possible attributes.
    // Hover to view descriptions of existing attributes.
    // For more information, visit: https://go.microsoft.com/fwlink/?linkid=830387
    "version": "0.2.0",
    "configurations": [
        {
            "name": "(gdb) Launch",
            "type": "cppdbg",
            "request": "launch",
            "program": "${workspaceFolder}/test",
            "args": [],
            "stopAtEntry": false,
            "cwd": "${workspaceFolder}",
            "environment": [],
            "externalConsole": false,
            "MIMode": "gdb",
            "setupCommands": [
                {
                    "description": "Enable pretty-printing for gdb",
                    "text": "-enable-pretty-printing",
                    "ignoreFailures": true
                },
                {
                    "description": "Set Disassembly Flavor to Intel",
                    "text": "-gdb-set disassembly-flavor intel",
                    "ignoreFailures": true
                }
            ]
        }
    ]
}
```

当按下 `F5` 调试时，`gdb` 会报错 `Couldn't get registers: Input/output error`

![](https://pic.imgdb.cn/item/654382f8c458853aefb7c0be.png)

参考 [Debugging an x86 application in Rosetta for Linux](https://sporks.space/2023/04/12/debugging-an-x86-application-in-rosetta-for-linux/) 和 [Can't debug with Docker toolchain](https://youtrack.jetbrains.com/issue/CPP-32735/Cant-debug-with-Docker-toolchain)，给出的方法是改用 `gdbserver` 来调试

<br></br>

## 使用 gdb

![](https://pic.imgdb.cn/item/654386ddc458853aefc220ce.png)

先在终端输入

```shell
ROSETTA_DEBUGSERVER_PORT=12345 ./test
```

然后打开另一个终端，执行 `gdb`，然后依次输入

```shell
set architecture i386:x86-64
file ./test
target remote localhost:12345
```

然后就可以开始调试了

<br></br>

## 使用 vscode gui 调试

只需要在 `launch.json`（以上面的配置为基础）加上

```
{
    "version": "0.2.0",
    "configurations": [
        {
            ...
            "miDebuggerServerAddress": "localhost:12345",
            ...
        }
    ]
}
```

然后也是先在另一个终端加上环境变量执行要调试的程序，之后就是用熟悉的方式去调试了

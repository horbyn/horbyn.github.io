---
title: Winsock 实现一个端到端通信软件
date: 2022-03-14 22:39:10
excerpt: 这个一个基于 Winsock 的 Win32 端对端聊天软件。很久很久以前大三的时候就做过控制台的烂尾工程，这次花了点时间重新捡起，新封装了 UI。但由于我兴趣不在后台这方面，所以像 IO 模型、自定义协议之类的机制，都只是 Primer 的程度，本文目的更多是提供一种实现思路
tags: winsock
---

## 介绍

这是一个简单的局域网端对端通信 demo，我开发时更多是出于学习目的，所以更多时候我采用的实现效果是入门级的，如果你想深入了解 IO 模型或者其他内容那可能本文不适合你。整个程序基于 TCP 协议进行通信，采用足够简单的 select 模型实现异步，没有采用哪怕一点儿多线程知识。如果你也想实现一个类似的效果，我认为先导知识是 `Win32 Framework`、`Winsock Framework` 和 `select 模型` 足矣，本文目的主要是阐述设计思路

项目地址 [Win32-chat-room-winsock2](https://github.com/horbyn/Win32-chat-room-winsock2)，欢迎 star/make contribution/post issue &#128075;

<br>

## LICENSE

文档中涉及到的源代码使用 [MIT](https://github.com/horbyn/Win32-chat-room-winsock2/blob/master/LICENSE) 许可证

<br>

## 演示

### 本地测试

本地测试服务器默认绑定 "127.0.0.1:8888"

![](https://pic.imgdb.cn/item/626251eb239250f7c55c6cfc.png)

<br>

### 局域网测试

局域网测试需确保两台电脑处于同一 wifi，然后服务器绑定地址用环回地址是不行的，需要绑定到本地电脑的 ip 地址上

我本地地址是 `192.168.1.4`，服务器因此绑定这个地址，我另一台电脑其本地地址 `192.168.1.7` ，由于处于同一局域网，因此能实现通信

![](https://pic.imgdb.cn/item/62625226239250f7c55cf2d6.png)

![](https://pic.imgdb.cn/item/626252dc239250f7c55eba85.png)

<br>

## 缺陷

首先程序体验不完美，这也是我后面优化的方向：

- 不支持中文。实际上我已经很小心处理 `char` 和宽字符转换了，但还是会使中文出现乱码。而我在后台调试时，"Edit Control" 接收到的中文输入就是乱码，我不确定是不是有什么地方我忽略了
- 显示面板不友好。显示面板采用 "Static Control" 配合我自己封装的函数实现消息显示，如果能直接采用 `TextOut()` 配合滚动条那看起来是非常舒服的。只是说滚动条又是另外一个坑了，需要花点时间研究
- 其他 bug。我在开启多 Client 并且涉及中文输入、切换用户收发消息时出现消息无法正常收发的现象，但这个问题比较难复现，所以现在还不能解决
- C Style。Win32 本来就是一套 C API，虽然说用 C 写无可厚非。但毕竟 C 可读性太差了，基本就是全局变量、状态标志满天飞，很多东西都零零散散地分布于整个工程，不利于后期维护和扩展，我希望以后能用 Cpp 实现 Reconstruction

<br>

## 二次开发

关于 Server 或 Client 返回的 **ERR::xxxxx** 代码，可以在 [Win32 Winsock error code](https://docs.microsoft.com/en-us/windows/win32/winsock/windows-sockets-error-codes-2) 页面搜索查阅，类似：

![](https://pic.imgdb.cn/item/626252dc239250f7c55eba8b.png)

<br>

## 需求分析

在做任何一个开发前，我认为画个图捋捋思路是极其需要的。作为一个 `P2P Server`，根本目的就是要求两个 Client 能够通信，基于这个目的首先需要知道局域网当前在线人数，否则你都不知道有谁在，又怎么和别人聊天呢？

难点就在于统计在线人数这块，如果是用 UDP，维护一个在线人数列表可能涉及 `socket 广播`，因为 UDP 是直接绑定就能用，单纯用本地 socket 可以说彼此之间都不知道对方存在。但用广播这就又踩入另外一个坑了，作为一篇学习向 POST，我希望越简单越好。所以才采用 TCP 作为主要协议，那么统计在线人数这件事就可以完全交给 Server 负责了，因为 Client 肯定要先与 Server 建立连接，另外 Client 离开局域网也会进行 "四次挥手"，这就使得 Server 能非常方便地维护一个局域网在线人数的列表。剩下 Server 要做的就是在人数发生变化时向每一个 Client 发送当前的用户列表

但也要注意到，由于 TCP 协议的使用需要引入 Server，那么端到端通信过程也会相对变得复杂。如果是 UDP，端到端就是字面意思；但是如果是 TCP，端到端实际是 Client-Server-Client 的意思，也就是中间多了一步 Server 转发。因为虽然我每个 Client 可以获取到用户列表，可以知道具体每一个其他 Client 的 socket，但这个 socket 是和 Server 建立连接的，只能接收来自 Server 的消息

上面两点分别讨论了 `获取用户列表`、`转发消息` 两部分内容，这段简述其他零零散散的细节。首先是 `IO 模型`，除非你只实现一个 Client 与 Server 的通信，否则必须使用 IO 模型，IO 模型的引入可以使得 Server 能处理与多个 Client 的连接。然后是 `非阻塞` 的问题，写控制台程序可以直接在 *while (1)* 一直监听或一直连接，但是放在窗口程序不能在某条 Windows 消息里面放 *while ()* 或者说阻塞某条消息，因为消息是处理完就要退出，你如果阻塞某条消息，那么你其他消息比如点击窗口或拖动窗口都会造成程序崩溃。再然后是 `消息边界问题` 问题，打个比方我发了两条消息分别是 "abc" 和 "123"，但 TCP 是流协议，说不定对端收到的信息为 "abc123" 或 "abc12" 或别的，怎么处理这个消息边界问题？这里面涉及的问题是需要展开说的，这是个非常精彩的问题，我会在后面用到的时候具体说明。<span id="mess">最后聚焦于 `要处理的消息` 问题，基于上述分析，Client 要考虑的消息包括 **发送自己想说的话**、**接收用户列表**、**接收 Server 的转发消息**；而 Server 则需要考虑 **接收用户连接请求**、**发送转发消息**、**发送用户列表**</span>

现在总结一下：

对于 Server：

- 接收多个用户的连接请求
- 统计在线人数
- 发送在线人数列表
- 发送转发消息

对于 Client：

- 请求与 Server 连接
- 发送聊天消息
- 接收转发消息
- 接收在线人数列表

<br>

## 准备知识

### Win32 Framework

推荐毛星云前辈的 [《逐梦旅途》](https://book.douban.com/subject/25756435/) ，看前四章就好，能理解怎么创建窗口程序，理解 Framework 里每个 API 就够了

<br>

### Win32 Controls

推荐参考 [Microsoft: Windows Controls](https://docs.microsoft.com/en-us/windows/win32/controls/window-controls)

用到哪个参考哪个，如果不介意我的 UI 丑的话，你也可以像我一样，只使用 "Static"、"Button"、"Edit" 和 "Combo box"

<br>

### Winsock Framework

推荐参考 [Microsoft: Getting Started with Winsock](https://docs.microsoft.com/en-us/windows/win32/winsock/getting-started-with-winsock)

需要注意微软给的 Example 非常非常简单，只涉及一个 Client 和 Server 通信。如果你需要实现更多 Client 和一个 Server 的通信，那么你需要关注下面的 *Advanced Winsock Samples*

但是毕竟 Winsock 是整个 program 的重点，所以我这里简单地班门弄斧一下

服务器 Program Flow 是 *初始化 dll：WSAStartup()* -> *创建：socket()* -> *绑定：bind()* -> *监听：listen()* -> *接收连接：accept()* -> *收发*

客户端 Program Flow 是 *初始化 dll：WSAStartup()* -> *创建：socket()* -> *连接：connect()* -> *收发*

<br>

### Select Model && Nonblocking

我觉得这两个内容密不可分，所以放在一起

首先需要明确有些 Winsock 函数（默认）是阻塞的：

- **accept():** 执行到这个函数会一直等待直至有连接请求出现
- **connect():** 执行到这个函数会一直等待直至与服务器建立连接
- **recv()/send()/recvfrom()/sendto():** 接收数据会阻塞可能很好理解，但发送数据会阻塞是怎么回事？这里又涉及一些 low-level 知识，后面再解释

上面讨论过窗口程序不能在一个消息里面出现阻塞，所以这才需要把这些函数改为非阻塞模式，可以用 `ioctlsocket()` 修改，详见 [Microsoft: ioctlsocket function](https://docs.microsoft.com/en-us/windows/win32/api/winsock/nf-winsock-ioctlsocket)

现在详细讨论下 select model，参考 [Microsoft: select function](https://docs.microsoft.com/en-us/windows/win32/api/winsock2/nf-winsock2-select)。当然阅读理解就不用做了，我们来看中间部分谈到的 "可读"、"可写" 和 "异常" 事件

> In summary, a socket will be identified in a particular set when select returns if:
>  
> readfds:  
> 
> - If listen has been called and a connection is pending, accept will succeed.  
> - Data is available for reading (includes OOB data if SO_OOBINLINE is enabled).
> - Connection has been closed/reset/terminated.  
> 
> writefds:  
> 
> - If processing a connect call (nonblocking), connection has succeeded.
> - Data can be sent.
> 
> exceptfds:  
> 
> - If processing a connect call (nonblocking), connection attempt failed.
> - OOB data is available for reading (only if SO_OOBINLINE is disabled).  

简单来说，*连接请求到达*、*数据到达* 以及 *关闭连接* 都会触发 "可读事件"；*客户端请求连接* 以及 *数据已发送* 会触发 "可写事件"。至于 "异常事件" 我没使用到，所以没去了解。总之，这些 "xx 事件" 其实就是现在这个时刻发生了什么样的事件而已，select model 就是用于捕捉这样的事件而诞生的。所以，以前我们发出一个操作，必须要等它完成我们才能做其他事；现在我们可以交给 select()，然后去做其他事，当我们设置的操作被 select() 捕捉后，再去处理

但是我也想说，不是说使用了 select model 就一定要把所有操作交给 select() 去捕捉。像是 *ECHO Server* 这种入门 demo，你完全可以只使用 select() 去捕捉连接，至于 *echo* 的逻辑完全可以一收到消息就马上转发（*ECHO Server* 可以想想 *echo 命令*，客户端发出消息，服务器收到后马上原路发回，然后客户端接收消息显示出来，这就是 *ECHO Server*）。像这一步转发如果用 select()，那你发一条消息你能收到一万条回复

基于上个场景，你可能还有疑问："如果转发不使用 `select()` 只 `send()` 一次，那消息没发送成功岂不是会丢消息吗？" 这时候就要引入 nonblocking 机制里非常著名的一个错误码 [WSAEWOULDBLOCK 错误码(10035)，Linux 对应 EWOULDBLOCK](https://docs.microsoft.com/en-us/windows/win32/winsock/windows-sockets-error-codes-2) 。简单来说这个错误码等于和你说 "别急，正在处理"，事实上这个错误码并不算真正意义上的错误码。当调用 nonblocking 的 `accept(); connect(); recv()...` 这些函数时都可能出现这个错误码，比如 `connect()`，就是说我三次握手需要时间，第一次调用其实就起作用了，但可能在握手时间内又连续调用了好几次 `connect()` 那么后面的连接请求都会返回 **WSAEWOULDBLOCK**，所以你只需要等，不用作其他处理就行。上面那个问题也是如此， `send()` 只需调用一次就起效了，消息就能发送出去，如果不是网络问题或其他 Fatal 问题，会返回 "WSAEWOULDBLOCK"，所以其实大多数情况下都不会丢失消息的

现在总结一下 select() 用法

- 对于服务器接收连接：先 `listen()`，然后 `select()`，当捕获连接请求，再 `accept()`
- 对于客户端请求连接：先 `connect()`，然后 `select()`，当捕获连接请求，再处理收发
- 对于收发消息：不要求等待 `select()` 捕捉可读或可写事件后才调用 `recv()` 或 `send()`，顺序是任意的，取决于用在什么场景

至此 select 这个 IO 模型就讨论完了，可以看出这里用 select model 主要用于解决连接问题，具体来说是一对多的连接，即所谓异步问题

最后推荐大家可以参考 [Select Model Tutorial](https://www.winsocketdotnetworkprogramming.com/winsock2programming/winsock2advancediomethod5a.html) 看看别人具体是怎么使用的，我 Server 的最终也是参考了里面的思路

<br>

### 消息边界

之前讨论这个问题的时候说了会涉及一个底层问题，这就是 *socket 缓冲区* 的问题，但这里建议参考 [socket缓冲区以及阻塞模式详解](http://c.biancheng.net/view/2349.html) 或其他资料去了解 

为简化问题，假设传输层是不出错的（假设 TCP 真的非常可靠）。这可以忽略一些细节先把功能实现，也即总是可以想象 `send()` 或 `recv()` 这类函数是符合逻辑的，你传输多少它接收多少

其实事实也差不多如此，参考 [Microsoft: send()](https://docs.microsoft.com/en-us/windows/win32/api/winsock2/nf-winsock2-send) 和 [Microsoft: recv()](https://docs.microsoft.com/en-us/windows/win32/api/winsock/nf-winsock-recv)

> On nonblocking stream oriented sockets, the number of bytes written can be between 1 and the requested length, depending on buffer availability on both the client and server computers.  

对于一个非阻塞的流式 socket，send() 可写入的字节数介乎 1 与你请求发送的消息长度之间，具体多少取决于两端缓冲区的可用容量（作为一个局域网低并发的 demo，可以总是想象缓冲区容量充足）

> For connection-oriented sockets (type SOCK_STREAM for example), calling recv will return as much data as is currently available—up to the size of the buffer specified.  

对于一个面向连接的 socket（如 SOCK_STREAM），recv() 总是会返回尽可能多的数据，直至所指定缓冲区的容量大小（同理想象为缓冲区容量充足）

数据边界问题推荐参考 [怎么解决TCP网络传输「粘包」问题？](https://www.zhihu.com/question/20210025/answer/1982654161)。我自己的解决方案也是应用层自己定义一个协议，在此不再班门弄斧

<br>

### 传输二进制

最后一个想分享的知识点是，如何传输结构体？

我们都知道网络传输是分 *网络字节序（大端字节序）（NBO）* 和 *主机字节序（小端字节序）（HBO）* 的，所以在 API 上，`send()` 和 `recv()` 都只支持 *char \** 数据

那么传输结构体你完全可以做一些处理转换为 *char \** 先传输待接收后再还原回来，但这么做就更复杂了，在此我推荐直接用二进制传输。即我们传输结构体总是 `memcpy()` 将数据拷贝到 `char *` 数组，然后传输这个数组。这样有个好处，可以不用理会字节序的转化，发送端直接 `memcpy()` 发送，接收端也直接 `memcpy()` 使用

但是对于字符型数据慎用 `memcpy()`，除非你能保证数据长度，否则造成内存越界后果就是程序闪退

<br>

## 实现思路

### Win32 消息循环

像 Win32 控件使用、Win32 消息处理，这些东西我不打算记录下来了，唯一想单独拎出来分享的是消息机制

我刚开始摸索的时候真的是往服务器主线程上写 `while (1)`，结果现象就是，我一点击窗口或拖动窗口，标题栏便显示 "(无响应)" 三个字，随之而来的就是一个类似于 Trouble shooting 之类的无响应专属弹窗，也是这时候我开始对消息循环有了感性的认识

简单来说，消息循环有两套，一套以 `PostMessage()` 为核心，一套以 `PeepMessage()` 为核心。区别就是前者阻塞后者不阻塞，前者会一直卡在函数处直至有 `WM` 消息到达，如果用这套消息循环，意味着你需要点击一下鼠标、或者拖动一下窗口，程序逻辑才会继续执行。很明显在 Winsock 这个场景里行不通，因为服务器要逻辑上死循环，一直监听连接请求。所以才有了现在这个 [PeepMessage() 逻辑](https://github.com/horbyn/Win32-chat-room-winsock2/blob/a62a76976d1db28b63cc57782f3f10c1156809a4/Server.cpp#L25)，值得一提的是，这也是我阅读毛星云前辈《逐梦旅途》学习来的，我大三的时候刚开始学习 Win32 也是通过这本书，再次向前辈敬礼，R.I.P.

<br>

### 服务器逻辑

我将服务器逻辑分成两大部分，分别是 **配置服务器**（参考 [BOOL ServerConfig()](https://github.com/horbyn/Win32-chat-room-winsock2/blob/a62a76976d1db28b63cc57782f3f10c1156809a4/Server.cpp#L226)）以及 **运行服务器**（参考 [void ServerRun()](https://github.com/horbyn/Win32-chat-room-winsock2/blob/a62a76976d1db28b63cc57782f3f10c1156809a4/Server.cpp#L347)）

<br>

### ServerConfig()

此函数内就是 Winsock Framework，在此只想分享几个细节问题

sockaddr 和 sockaddr_in 两个结构体。都是用于封装协议所识别的信息的，不同的是后者专门用于 TCP/IP 协议栈，所以后者直接划分了两个字段用于存放标识————即 IP 地址和端口号 Port。而前者是广义协议使用的，好比现在有个协议叫 UDQ/JQ 协议栈，这是用 OQ 和 Qpsu 来标识协议实体的，那么对于这个协议就应该用 sockaddr

[创建 socket](https://github.com/horbyn/Win32-chat-room-winsock2/blob/a62a76976d1db28b63cc57782f3f10c1156809a4/Server.cpp#L266) 这里使用的是微软 Example 的写法，按 POSIX 写法应该是直接 sockaddr 实例化一个对象，然后用这个对象去创建 socket()，我在客户端 [创建 socket](https://github.com/horbyn/Win32-chat-room-winsock2/blob/a62a76976d1db28b63cc57782f3f10c1156809a4/Client.cpp#L374) 用了这种写法。如果你电脑只有一块网卡，那么这两种写法没区别，如果你电脑有多块网卡，而且你只想绑定到其中一块网卡，那这种场景就用后者的写法

此函数 Program Flow 直至 `accept()` 为止，因为绑定服务器地址只需进行一次，而接收连接请求却需要一直进行，所以这两步要分开进行

<br>

### ServerRun()

这是服务器最重要的逻辑了

首先要处理的是连接请求，像上面说的那样先用 `select()` 捕捉，像接收连接请求这种事件属于可读事件，所以 [只需要填充第二个参数](https://github.com/horbyn/Win32-chat-room-winsock2/blob/a62a76976d1db28b63cc57782f3f10c1156809a4/Server.cpp#L371)

`select()` 执行完首先要做的是 [检查有无连接请求](https://github.com/horbyn/Win32-chat-room-winsock2/blob/a62a76976d1db28b63cc57782f3f10c1156809a4/Server.cpp#L379)，通过判断用于监听的 socket 是否在可读集合内实现。如果有新连接到达，此条件就满足，因此会进入 `if()` 分支

值得一提的是，`accept()` 会返回新的专门用于数据传输的 socket，原来用于监听的 socket 还会继续监听连接。然后新连接到达后我后面的逻辑是 *"打印用户信息"* -> *"维护在线用户列表"*。维护用户列表我分为了两步：保存用户 socket 和 sockaddr（后面哈希表的处理就是为了保存 sockaddr 结构体的信息）。需要注意到 socket 本身并不等于 sockaddr 结构体，前者本质是一个整型值，是服务器本地才能识别的。端到端通信取决于知不知道对方的 IP 地址和端口，这两个数据是 sockaddr 结构体维护的，所以用户列表必须包含 sockaddr 结构体发送给每个 Client，这样 Client 才知道要通信的另外一端的信息。

再详细分享下哈希表的思想，首先要看下 sockaddr_in 结构体的组成（在 TCP/IP 协议栈里，你可以把 sockaddr_in 和 sockaddr 视为等价）：

> ```c
> struct sockaddr_in {
>     short            sin_family;   // 2B
>     unsigned short   sin_port;     // 2B
>     struct in_addr   sin_addr;     // 4B
>     char             sin_zero[8];  // 8B
> };
> ```

由于后 8 Bytes 只用来填充，总是 0，所以我用前 8 Bytes 作为哈希表的键，对应它的 socket。所以是一个 [uint64_t -> SOCKET 的哈希表](https://github.com/horbyn/Win32-chat-room-winsock2/blob/a62a76976d1db28b63cc57782f3f10c1156809a4/Server.h#L75)

至此，便是接收请求的逻辑。后面 **维护用户列表** 思路可能比较凌乱，如果你有其他想法可以按你自己的思路来，这里仅提供其中一个思路

<br>

接收完连接请求，便需要遍历用户列表里面所有用户有无产生 IO 事件了，还记得前面一开始分析需求的时候 [服务器要处理的消息](#mess) 吗？

现在来回顾一下，对于服务器来说需要接收 "连接请求" 以及 "其他 Client 发送来的消息"，需要发送 "在线用户列表"。翻译一下就是对于服务器，可读事件是 "连接请求"、"用户的聊天消息"（当然 Client 下线也属于可读事件）；可写事件是 " '广播' 在线用户列表" （当然此处广播并不是真正意义上的广播，只是用一个 `for()` 循环不断发送以达到给每个 Client 发送的目的）

连接请求这个可读事件前面已经处理了，所以现在 [捕获的是另一个可读事件 ———— "用户聊天消息"](https://github.com/horbyn/Win32-chat-room-winsock2/blob/a62a76976d1db28b63cc57782f3f10c1156809a4/Server.cpp#L447)。对于这个事件，服务器要做的事情 [就是转发而已](https://github.com/horbyn/Win32-chat-room-winsock2/blob/a62a76976d1db28b63cc57782f3f10c1156809a4/Server.cpp#L486)

最后一个可读事件，[用户下线](https://github.com/horbyn/Win32-chat-room-winsock2/blob/a62a76976d1db28b63cc57782f3f10c1156809a4/Server.cpp#L457)，这里涉及 TCP 协议里一个名词 "优雅关闭"，详见 [shutdown()函数：优雅地断开TCP连接](http://c.biancheng.net/view/2354.html)。简单提一点，客户端需要先告诉服务器自己要断开连接了，好处就是未收发完的数据会继续收发，只有新数据不处理；然后服务器对这个已断开连接的用户 [最后一次 `recv()` 会返回 0](https://github.com/horbyn/Win32-chat-room-winsock2/blob/a62a76976d1db28b63cc57782f3f10c1156809a4/Server.cpp#L457)，此时服务器才可以进行释放资源之类的操作

事实上，若 Client 是优雅关闭的 (graceful termination) 会进入 TCP 四次挥手过程的 TIME_WAIT 阶段

![](https://pic.imgdb.cn/item/626252dc239250f7c55eba91.png)

而如果 Client 不是优雅关闭，Server 最后一次 `recv()` 会返回 *SOCKET_ERROR*，错误码需要通过 `WSAGetLastError()` 获取

![](https://pic.imgdb.cn/item/62625367239250f7c5606cf7.png)

<br>

处理完可读事件，现在来考虑怎么处理可写事件 ———— 即 "发送用户列表"。虽然理论上你可以交给 `select()` 去决定什么时候可以发送，然后才将用户列表发送出去。但要考虑到，在一个局域网环境，而且是低并发量的情景下，几乎无时无刻都会触发 "可写事件"。因为你不用考虑网络因素，而且数据量足够少，那么只要遍历到一个 socket 就可以发送一次数据，这样反而无时无刻 Server 都会广播用户列表。Client 接收到的用户列表肯定是大量大量地重复的，反而会使 Client 要专门写一个实现去重的逻辑

退一万步讲，只要我有一次能将用户列表更新成功，后续的更新就算有延迟其实也不影响 Client 原来的聊天，更何况我们现在的需求下网络环境几乎可以不考虑

所以，为了使问题简化，我不打算将这个可写事件交给 `select()` 处理。相反，我只在必要的时候更新，也即 [新用户上线](https://github.com/horbyn/Win32-chat-room-winsock2/blob/a62a76976d1db28b63cc57782f3f10c1156809a4/Server.cpp#L436) 以及 [原有用户下线](https://github.com/horbyn/Win32-chat-room-winsock2/blob/a62a76976d1db28b63cc57782f3f10c1156809a4/Server.cpp#L481) 这两种情况进行更新

<br>

### 客户端逻辑

客户端这边我引入了一个比较有趣的动作，就是按一下 "Connect" 会连接服务器，同时按钮切换为 "Terminate" 示意你再按一次会断开与服务器的连接。这里就不展开了，主要就是 `SetWindowText()` 的使用，具体逻辑参考 [void ResetState()](https://github.com/horbyn/Win32-chat-room-winsock2/blob/a62a76976d1db28b63cc57782f3f10c1156809a4/Client.cpp#L313) 和 [void  ChangeState(int *)](https://github.com/horbyn/Win32-chat-room-winsock2/blob/a62a76976d1db28b63cc57782f3f10c1156809a4/Client.cpp#L330) 这两个函数

和服务器类似，Winsock Framework 我也是分为几个逻辑去处理。但不同的是，Client 请求连接要单独分出来，这也是一个需要不断重复的逻辑，只有你连接上服务器，才能进行下一步不是吗。所以总共分为 [配置: ClientConfig()](https://github.com/horbyn/Win32-chat-room-winsock2/blob/a62a76976d1db28b63cc57782f3f10c1156809a4/Client.cpp#L357)、[连接: ClientConn()](https://github.com/horbyn/Win32-chat-room-winsock2/blob/a62a76976d1db28b63cc57782f3f10c1156809a4/Client.cpp#L433) 和 [运行: ClientRun()](https://github.com/horbyn/Win32-chat-room-winsock2/blob/a62a76976d1db28b63cc57782f3f10c1156809a4/Client.cpp#L494)

配置和连接类似服务器所以不展开，而如果你参考我的代码你会发现傻逼全局标识变量满天飞，这是我的问题，我承认我是 "面向测试编程" 一步步来的，没有一个很宏观的设计，确实很容易导致 "xx标识"、"全局xx" 使用过量，所以仅供参考，我主要想分享的是思路

现在再来回顾下 [客户端需要关注的消息](#mess)。要发送的是 "自己想说的话"；要接收的是 "在线用户列表" 和 "Server 的转发"。翻译过来就是前者是可写事件，后者是可读事件

我把 [检测可读事件](https://github.com/horbyn/Win32-chat-room-winsock2/blob/a62a76976d1db28b63cc57782f3f10c1156809a4/Client.cpp#L526) 放在前面是因为，如果 `recv()` 返回 0 即意味着服务器下线了，那再处理什么都没意义，就可以直接退出了

由于 [可读事件有两种类型](https://github.com/horbyn/Win32-chat-room-winsock2/blob/a62a76976d1db28b63cc57782f3f10c1156809a4/Client.cpp#L543)，所以有可读事件到达时，应用层需要做些事情才能区分出来，这也是自定义协议最重要的作用。像前面说的区分数据边界，放在这个入门 Demo 里其实我大可规定一个固定的消息长度，每次收发都是这个长度的消息，也可以达到区分边界的目的。但你想让应用层能正确处理多种类型的信息，那最优解还是自定义一个协议。至于我自己的思路，我放在后面分享，现在先关注客户端的逻辑

先将 [UpdateUser()](https://github.com/horbyn/Win32-chat-room-winsock2/blob/a62a76976d1db28b63cc57782f3f10c1156809a4/Client.cpp#L545) 和 [PrintMess()](https://github.com/horbyn/Win32-chat-room-winsock2/blob/a62a76976d1db28b63cc57782f3f10c1156809a4/Client.cpp#L547) 看作 **Stub program** [（关于桩代码（Stub））](https://www.zhihu.com/question/24844900/answer/35126766)，那可读事件就算完成了

<br>

关于 [可写事件](https://github.com/horbyn/Win32-chat-room-winsock2/blob/a62a76976d1db28b63cc57782f3f10c1156809a4/Client.cpp#L556)，看到这里相信你也有些想法了，就是 *"从控件中获取用户输入"* -> *"发送"*，只是说在真正发送之前，请务必 [封装协议](https://github.com/horbyn/Win32-chat-room-winsock2/blob/a62a76976d1db28b63cc57782f3f10c1156809a4/Client.cpp#L584)

<br>

### 自定义协议

现在关注剩余的几个函数：服务器端 [转发消息: TransferMess()](https://github.com/horbyn/Win32-chat-room-winsock2/blob/a62a76976d1db28b63cc57782f3f10c1156809a4/Server.cpp#L513) 和 [广播用户列表: SendUserList()](https://github.com/horbyn/Win32-chat-room-winsock2/blob/a62a76976d1db28b63cc57782f3f10c1156809a4/Server.cpp#L558)；客户端 [显示消息: PrintMess()](https://github.com/horbyn/Win32-chat-room-winsock2/blob/a62a76976d1db28b63cc57782f3f10c1156809a4/Client.cpp#L611)、[更新用户列表: UpdateUser()](https://github.com/horbyn/Win32-chat-room-winsock2/blob/a62a76976d1db28b63cc57782f3f10c1156809a4/Client.cpp#L674) 和 [封装协议: Packing()](https://github.com/horbyn/Win32-chat-room-winsock2/blob/a62a76976d1db28b63cc57782f3f10c1156809a4/Client.cpp#L720)，这些函数都和自定义协议有关

所以我想先分享下我协议的定义思路，我也放到 [注释：制表符画的协议](https://github.com/horbyn/Win32-chat-room-winsock2/blob/a62a76976d1db28b63cc57782f3f10c1156809a4/Server.h#L1) 了

> ```c
> /*
>  * 针对 P2P Server，应用层需要提供自己的协议，此处自定义协议规则如下
>  *
>  * 自定义协议：由包头和包体两部分组成，总是固定长度（MSG_SIZE）
>  *     包头逻辑上同以下结构体
>  *     struct HEAD {
>  *         uint8_t type; // 1B
>  *         uint8_t size; // 2B
>  *     };
>  *     包体总是 128B
>  *
>  * 类型一：
>  * type == 0x7f: 内含数据为用户列表
>  * size:         指出包体数据实际长度
>  *   ├ 1B ┼ 2B ┼     Body: 128B      ┤
>  *   ┌────┬────┬─────────────────────┐
>  *   │0x7f│size│     128 Bytes       │
>  *   └────┴────┴─────────────────────┘
>  *
>  * 类型二：
>  * type == 0x00: 内含数据为聊天消息
>  * size:         指出包体数据实际长度
>  * 包体开头 16B:  指出消息来自哪个 socket
>  *   ├ 1B ┼ 2B ┼     Body: 128B      ┤
>  *   ┌────┬────┬─────┬───────────────┐
>  *   │0x00│size│ 16B │   MESSAGES    │
>  *   └────┴────┴─────┴───────────────┘
> */
> ```

我把每一条消息固定了长度，只因简化处理逻辑。消息分为包头和包体两部分，包头含 `type 类型`、`size 消息长度` 两个字段，共 3 Bytes。包体不同类型不同定义：对于类型一，用于封装用户列表，包体全部 128 Bytes 都用来封装用户的 sockaddr_in 结构体，这个数字是根据 [MAX_CLIENT](https://github.com/horbyn/Win32-chat-room-winsock2/blob/a62a76976d1db28b63cc57782f3f10c1156809a4/Server.h#L51) 和 [MSG_SIZE](https://github.com/horbyn/Win32-chat-room-winsock2/blob/a62a76976d1db28b63cc57782f3f10c1156809a4/Server.h#L55) 这两个宏得到的，总是可以囊括全部的用户 sockaddr_in 结构体信息；对于类型二，用于封装聊天信息，包体开头 16 Bytes 用于封装 Client 本地的 sockaddr_in，这样对端才知道消息来自于哪个 IP 哪个端口，剩下的字节均用于封装具体的消息。值得一提的是，虽然聊天信息本身就是字符串，封装时确实也可以用 `strcat()` 来处理，但我这里以 [以二进制形式封装聊天数据](https://github.com/horbyn/Win32-chat-room-winsock2/blob/a62a76976d1db28b63cc57782f3f10c1156809a4/Client.cpp#L747) 实测也可以，算是提供另外一个思路。但就像前面说的那样，对字符串使用 `memcpy()` 前提是确保拷贝长度无误，否则慎用

以上思路仅供参考，你也可以定义自己喜欢的协议格式，其实剩余的函数就是对照上面的协议格式进行 "封包" 和 "解包" 而已，我就不展开了

<br>

## 写在最后

我想分享下这个过程中我遇到的两个 bug，是什么现象又是怎么解决的

<br>

### BUG 1: 闪退

现象：

- 程序不能百分百正常运行。比如打开程序 10 次，总会有 3~5 次出现闪退

解决：

- 这是一个非常非常常见的 bug，原因是 **缓冲区溢出**
- 此时需要重点关注所有的 **字符串函数**，特别是不规定字符串长度的函数如 `strcpy()`、`strcat()` 等，所以我在实现上全部换成 `StringCchCopy()`、`StringCchCat()`；如果你是 Linux 程序对应 `strcpy_s()`、`strcat_s()` 

<br>

### BUG 2: 无响应

现象：

- 标题栏标题后面新增 *(无响应)* 三个字
- 点击窗口右上角关闭按钮，会出现 "window 无响应"、"是否发送错误报告" 之类的弹窗

解决：

- 这是修改了比 `malloc()` 给定的内存更大的内存空间
- 这种 bug 在运行时可能不会出现任何问题，但是一旦关闭，就会崩溃
- 这就是没有养成 `malloc()` 和 `free()` 配套的好习惯。事实上，只要加上 `free()`，并且程序有越界访问的行文，编译阶段就会被检查出来

<br>

以上是本文所有内容，欢迎评论、欢迎给予我意见，也欢迎交流
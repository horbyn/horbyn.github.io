---
title: Linux 虚拟化实验，探讨 VLAN PVID 和 UNTAGGED
date: 2025-07-17 22:47:23
excerpt: 验证 Linux bridge 的 VLAN 过滤机制，通过实验来测试不同端口类型（Tagged 和 Untagged 端口）处理 VLAN 帧（Tagged 和 Unttagged 帧）的行为，并通过 Linux namespace 实验，结合 bridge vlan 命令配置 PVID/VID，验证 VLAN 通信对于端口类型的配置问题
tags: 虚拟化
---

## Linux bridge

- VLAN Filter 机制：[Linux bridge](https://man7.org/linux/man-pages/man8/bridge.8.html) 模拟物理二层交换机，通过 `bridge vlan` 命令控制 VLAN 流量过滤，决定哪些 VLAN 可通过特定端口
- 关键参数：  
    - `vid`（处理 tagged 帧）：标识 VLAN ID，决定端口接收/转发的 VLAN 帧范围
    - `pvid`（处理 untagged 帧）（处理 ingress 时生效）：针对进入 bridge 的未携带 VLAN tag 的 ingress，任何未携带 tag 的流量都被分配这个指定的 ID
    - `untagged`（处理 egress 时生效）：针对离开 bridge 的带上 VLAN tag 的 egress，携带了指定 tag 的流量在离开端口时都会被视为 untagged（没有 VLAN tag）
    - `self`：VLAN 是配置在一个物理设备上，当设备是 bridge 时必须指定
    - `master`：VLAN 是配置在一个软件 bridge 上（默认）
- 端口类型类比：  
    - 硬件交换机：Access（单 VLAN）、Trunk（多 VLAN）
        - `access` 只能属于一个 VLAN，一般用于连接主机
        - `trunk` 可以允许多个 VLAN 通过，一般用于连接交换机
    - Linux bridge：Untagged（类比 Access）、Tagged（类比 Trunk/Hybrid）
        - 类比 Access 端口是因为主机一般是终端，不需要添加 VLAN tag，所以 Access 端口接收 / 发送的流量一般是 untagged
        - 类比 Trunk 端口是因为交换机需要处理 VLAN 流量的转发，所以 Trunk 端口接收 / 发送的流量一般是 tagged

## 实验验证

|**操作类型**|**Tagged 端口**（类比 Trunk/Hybrid）|**Untagged 端口**（类比 Access）|
|---|---|---|
|**接收 Tagged 帧**|仅接受 VID 在端口 vid 列表中的帧|仅接受 VID 在端口 vid 列表中的帧 |
|**接收 Untagged 帧**|根据端口 pvid 打标签（如 pvid=10 → 转为 VID 10）|根据端口 pvid 打标签（如 pvid=20 → 转为 VID 20） |
|**发送 Tagged 帧**|保留标签，仅转发给 VID 匹配的端口|剥离标签（因需以原生帧发给主机）|
|**发送 Untagged 帧**| - | - |

最后一行我认为是不存在的，因为一个 bridge 端口如果想要向外发送 egress，必定是先从 bridge 内部出来。如果 bridge 启用了 bridge VLAN Filter，则其内部总是带 VLAN tag 的，因此从 bridge 端口出去的 egress 总是 tagged 帧，因此不会存在发送 untagged 帧的情况

## 实验场景与结论

参考 [Linux bridge VLAN的配置](https://resona.top/2021/06/02/Linux%20bridge%20VLAN%E7%9A%84%E9%85%8D%E7%BD%AE/) 为实验设置的网络拓扑

![](https://pic1.imgdb.cn/item/68777df258cb8da5c8ba103b.png)

实验布置是：

- 流量路径：`veth1-ns` -> `veth1-br` -> `br0` -> `veth2-br` -> `veth2-ns`
- 用 Linux bridge 模拟二层交换机，所以会修改三个 bridge 端口为 `tagged` 或 `untagged`，来归纳下面的表格
- 因为请求是从 `ns1` 到 `ns2`，所以测试 bridge 端口在接收和发送 VLAN 流量时，定义如下：
	- 靠近 `ns1` 一侧的 bridge 端口（`veth1-br`），用来观察接收请求（ingress）
	- 靠近 `ns2` 一侧的 bridge 端口（`veth2-br`）用来观察发送请求（egress）
- `tagged` 流量使用 namespace 的 VLAN NIC（`vethX-ns-vlan`）进行通信；`untagged` 流量使用 namespace 的虚拟 NIC（`vethX-ns`）进行通信

需要归纳的表格如下：

| **操作类型** | **Tagged 端口**（类比 Trunk/Hybrid） | **Untagged 端口**（类比 Access） |
| ---- | ---- | ---- |
| **接收 Tagged 帧** |  |  |
| **接收 Untagged 帧** |  |  |
| **发送 Tagged 帧** |  |  |
| **发送 Untagged 帧** | - | - |



## 第一个场景：相同网段 untagged 帧通信

网络拓扑：

![](https://pic1.imgdb.cn/item/687786a658cb8da5c8ba659b.png)

- 测试 `untagged` 端口（`veth1-br`）接收 `untagged` 流量（来自 `veth1-ns`）
- 测试 `untagged` 端口（`veth2-br`）发送 `tagged` 流量（来自 `br0`，或者说 "交换机内部"）

部署脚本：

```shell
#!/bin/bash

set -ex

ns1=ns1
ns2=ns2
br=br0

if ip netns show | grep -q "$ns1"; then
  ip netns del $ns1
  echo "Namespace $ns1 已删除"
fi

if ip netns show | grep -q "$ns2"; then
  ip netns del $ns2
  echo "Namespace $ns1 已删除"
fi

if ip link show $br &>/dev/null; then
  ip link del $br
  echo "接口 $br 已删除"
fi

sleep 2

br_ns1=veth1-br
br_ns2=veth2-br
ns1_veth=veth1-ns
ns2_veth=veth2-ns
ns1_veth_vlan=veth1-ns-vlan
ns2_veth_vlan=veth2-ns-vlan

# 创建 bridge 并启用 VLAN 过滤
ip link add $br type bridge
ip link set $br up
ip link set $br type bridge vlan_filtering 1
bridge vlan add dev $br vid 10 tagged self
bridge vlan del dev $br vid 1 self # 删除默认 VLAN

# 创建 Namespace 和 veth pair
ip netns add $ns1
ip netns add $ns2
ip link add $ns1_veth type veth peer name $br_ns1
ip link add $ns2_veth type veth peer name $br_ns2

# 连接 bridge
ip link set $br_ns1 master $br
ip link set $br_ns2 master $br
ip link set $br_ns1 up
ip link set $br_ns2 up

# bridge 靠近 ns1 一侧
bridge vlan add dev $br_ns1 vid 10 pvid untagged
bridge vlan del dev $br_ns1 vid 1  # 删除默认 VLAN

# bridge 靠近 ns2 一侧
bridge vlan add dev $br_ns2 vid 10 pvid untagged
bridge vlan del dev $br_ns2 vid 1  # 删除默认 VLAN

# ns1
ip link set $ns1_veth netns $ns1
ip netns exec $ns1 ip link set $ns1_veth up
ip netns exec $ns1 ip addr add 192.168.10.1/24 dev $ns1_veth
ip netns exec $ns1 ip link add link $ns1_veth name $ns1_veth_vlan type vlan id 10
ip netns exec $ns1 ip addr add 10.10.0.1/24 dev $ns1_veth_vlan
ip netns exec $ns1 ip link set $ns1_veth_vlan up

# ns2
ip link set $ns2_veth netns $ns2
ip netns exec $ns2 ip link set $ns2_veth up
ip netns exec $ns2 ip addr add 192.168.10.2/24 dev $ns2_veth
ip netns exec $ns2 ip link add link $ns2_veth name $ns2_veth_vlan type vlan id 10
ip netns exec $ns2 ip addr add 10.10.0.2/24 dev $ns2_veth_vlan
ip netns exec $ns2 ip link set $ns2_veth_vlan up

set +x
```

查看 bridge VLAN filter 表项：

```shell
➜  ~ bridge vlan show
port              vlan-id  
br0               10
veth1-br          10 PVID Egress Untagged
veth2-br          10 PVID Egress Untagged
```

执行 `ping` 命令：

```shell
➜  ~ ip netns exec ns1 ping -c1 192.168.10.2
PING 192.168.10.2 (192.168.10.2) 56(84) bytes of data.
64 bytes from 192.168.10.2: icmp_seq=1 ttl=64 time=0.479 ms

--- 192.168.10.2 ping statistics ---
1 packets transmitted, 1 received, 0% packet loss, time 0ms
rtt min/avg/max/mdev = 0.479/0.479/0.479/0.000 ms
```

抓包结果就用画图来代替了：

![](https://pic1.imgdb.cn/item/687786a658cb8da5c8ba659a.png)

绿色这个 `untagged` 端口（`veth1-br`）在接收到绿色的 `untagged` 帧时，会放行，下一个抓包点（`br0`）观察到报文被带上 VLAN tag，且 VID 是 10，说明 **`untagged` 端口接收 `untagged` 帧时会将 PVID 作为 VLAN ID，封装一个 VLAN tag**

在 "交换机内部" 都是以 `tagged` 帧的形式传递的，这可以通过观察进入和离开 `br0` 的报文得出结论

黄色这个 `untagged` 端口（`veth2-br`）在发送黄色的 `tagged` 帧时，会放行，下一个抓包点（`veth2-ns`）观察到报文没有 VLAN tag，说明 **`untagged` 端口发送 `tagged` 帧时会剥除 VLAN tag**

| **操作类型** | **Tagged 端口**（类比 Trunk/Hybrid） | **Untagged 端口**（类比 Access） |
| ---- | ---- | ---- |
| **接收 Tagged 帧** |  |  |
| **接收 Untagged 帧** |  | 根据端口 PVID 打标签（如 PVID=10 → 转为 VID 10） |
| **发送 Tagged 帧** |  | 剥离标签（因需以原生帧发给主机） |
| **发送 Untagged 帧** | - | - |

还有一个好玩的事情，如果把 bridge `br0` VID 修改为 20，其余不变并重复实验，可以通信吗？这里就不列出来了，不然文章太长

最后，依然使用这个网络拓扑，可以尝试着用 namespace 中两个 VLAN NIC 来通信，可以发现，绿色这个 `untagged` 端口（`veth1-br`）在接收到 `tagged` 帧时。当 VLAN tag 在 bridge VID 列表内时才会放行，可以观察下一个抓包点（`br0`），说明 **`untagged` 端口接收 `tagged` 帧时仅接受在 bridge VID 列表中的帧**

| **操作类型** | **Tagged 端口**（类比 Trunk/Hybrid） | **Untagged 端口**（类比 Access） |
| ---- | ---- | ---- |
| **接收 Tagged 帧** |  | 仅接受 VID 在端口 VID 列表中的帧 |
| **接收 Untagged 帧** |  | 根据端口 PVID 打标签（如 PVID=10 → 转为 VID 10） |
| **发送 Tagged 帧** |  | 剥离标签（因需以原生帧发给主机） |
| **发送 Untagged 帧** | - | - |

## 第二个场景：相同网段相同 VLAN ID 通信

网络拓扑：

![](https://pic1.imgdb.cn/item/6877b3be58cb8da5c8bb02b1.png)

只是修改了通信的双方，由虚拟 NIC 变更为 VLAN NIC。但是这样之后 bridge 外部便直接是 VLAN 报文，如果 bridge 两个靠近 namespace 的端口不修改为 `tagged`，那么将无法正常通信

考虑 ns1 发送请求的情况，请求到达 bridge 黄色端口 `veth2-br` 之后，如果它是一个 `untagged` 端口，那么从它出去的 egress 也会被剥除 VLAN tag，那么 `ns2` 的通信就异常了；同样的道理当 ns2 返回响应时，响应到达 bridge 黄色端口 `veth1-br` 之后，如果它也是一个 `untagged` 端口，那么从它出去的 egress 也会被剥除 VLAN tag。所以为保证通信的正常，bridge 的两个靠近 namespace 的端口必须设置为 `tagged` 端口

部署环境的脚本：

```shell
#!/bin/bash

set -ex

ns1=ns1
ns2=ns2
br=br0

if ip netns show | grep -q "$ns1"; then
  ip netns del $ns1
  echo "Namespace $ns1 已删除"
fi

if ip netns show | grep -q "$ns2"; then
  ip netns del $ns2
  echo "Namespace $ns1 已删除"
fi

if ip link show $br &>/dev/null; then
  ip link del $br
  echo "接口 $br 已删除"
fi

sleep 2

br_ns1=veth1-br
br_ns2=veth2-br
ns1_veth=veth1-ns
ns2_veth=veth2-ns
ns1_veth_vlan=veth1-ns-vlan
ns2_veth_vlan=veth2-ns-vlan

# 创建 bridge 并启用 VLAN 过滤
ip link add $br type bridge
ip link set $br up
ip link set $br type bridge vlan_filtering 1
bridge vlan add dev $br vid 10 tagged self
bridge vlan del dev $br vid 1 self # 删除默认 VLAN

# 创建 Namespace 和 veth pair
ip netns add $ns1
ip netns add $ns2
ip link add $ns1_veth type veth peer name $br_ns1
ip link add $ns2_veth type veth peer name $br_ns2

# 连接 bridge
ip link set $br_ns1 master $br
ip link set $br_ns2 master $br
ip link set $br_ns1 up
ip link set $br_ns2 up

# bridge 靠近 ns1 一侧
bridge vlan add dev $br_ns1 vid 10 pvid tagged
bridge vlan del dev $br_ns1 vid 1  # 删除默认 VLAN

# bridge 靠近 ns2 一侧
bridge vlan add dev $br_ns2 vid 10 pvid tagged
bridge vlan del dev $br_ns2 vid 1  # 删除默认 VLAN

# ns1
ip link set $ns1_veth netns $ns1
ip netns exec $ns1 ip link set $ns1_veth up
ip netns exec $ns1 ip addr add 192.168.10.1/24 dev $ns1_veth
ip netns exec $ns1 ip link add link $ns1_veth name $ns1_veth_vlan type vlan id 10
ip netns exec $ns1 ip addr add 10.10.0.1/24 dev $ns1_veth_vlan
ip netns exec $ns1 ip link set $ns1_veth_vlan up

# ns2
ip link set $ns2_veth netns $ns2
ip netns exec $ns2 ip link set $ns2_veth up
ip netns exec $ns2 ip addr add 192.168.10.2/24 dev $ns2_veth
ip netns exec $ns2 ip link add link $ns2_veth name $ns2_veth_vlan type vlan id 10
ip netns exec $ns2 ip addr add 10.10.0.2/24 dev $ns2_veth_vlan
ip netns exec $ns2 ip link set $ns2_veth_vlan up

set +x
```

查看 bridge VLAN filter 表项：

```shell
➜  ~ bridge vlan show
port              vlan-id  
br0               10
veth1-br          10 PVID
veth2-br          10 PVID
```

执行 `ping` 命令：

```shell
➜  ~ ip netns exec ns1 ping -c1 10.10.0.2
PING 10.10.0.2 (10.10.0.2) 56(84) bytes of data.
64 bytes from 10.10.0.2: icmp_seq=1 ttl=64 time=0.152 ms

--- 10.10.0.2 ping statistics ---
1 packets transmitted, 1 received, 0% packet loss, time 0ms
rtt min/avg/max/mdev = 0.152/0.152/0.152/0.000 ms
```

抓包结果：

![](https://pic1.imgdb.cn/item/6877b3be58cb8da5c8bb02b2.png)

绿色这个 `tagged` 端口（`veth1-br`）在接收到绿色的 `tagged` 帧时，会放行，下一个抓包点（`br0`）观察到报文被带上 VLAN tag，且 VID 是 10，说明 **`tagged` 端口接收 `tagged` 帧时仅会允许 bridge VID 列表中存在的 VLAN ID**（可以试着修改 VLAN NIC 的 VLAN ID 或修改 bridge 的 VID 得到这个结论，你可以抓包观察不在 VID 列表中的 VLAN 请求根本到达不了 `br0` 以及后面 `ns2` 一侧，这里不列举了）

黄色这个 `tagged` 端口（`veth2-br`）在发送黄色的 `tagged` 帧时，会放行，下一个抓包点（`veth2-ns`）观察到报文携带了原来的 VLAN tag，说明 **`tagged` 端口发送 `tagged` 帧时会保留 VLAN tag，并且只会发送给 VID 匹配的端口**（同样这里可以试着引入 namespace `ns3` 并设置它的 VLAN ID 为其他，可以发现 `br0` 只会将 VLAN ID 10 的请求转发给 `veth2-ns`）

| **操作类型** | **Tagged 端口**（类比 Trunk/Hybrid） | **Untagged 端口**（类比 Access） |
| ---- | ---- | ---- |
| **接收 Tagged 帧** | 仅接受 VID 在端口 VID 列表中的帧 | 仅接受 VID 在端口 VID 列表中的帧 |
| **接收 Untagged 帧** |  | 根据端口 pvid 打标签（如 pvid=10 → 转为 VID 10） |
| **发送 Tagged 帧** | 保留标签，仅转发给 VID 匹配的端口 | 剥离标签（因需以原生帧发给主机） |
| **发送 Untagged 帧** | - | - |

依然使用这个网络拓扑，可以尝试着用 namespace 中两个虚拟 NIC 来通信，可以发现，绿色这个 `tagged` 端口（`veth1-br`）在接收到 `untagged` 帧时会放行，下一个抓包点（`br0`）观察到报文被带上 VLAN tag，且 VID 是 10，说明 **`tagged` 端口接收 `untagged` 帧时加上 PVID 指定的 VLAN ID 标签**

| **操作类型** | **Tagged 端口**（类比 Trunk/Hybrid） | **Untagged 端口**（类比 Access） |
| ---- | ---- | ---- |
| **接收 Tagged 帧** | 仅接受 VID 在端口 VID 列表中的帧 | 仅接受 VID 在端口 VID 列表中的帧 |
| **接收 Untagged 帧** | 根据端口 PVID 打标签（如 PVID=10 → 转为 VID 10） | 根据端口 pvid 打标签（如 pvid=10 → 转为 VID 10） |
| **发送 Tagged 帧** | 保留标签，仅转发给 VID 匹配的端口 | 剥离标签（因需以原生帧发给主机） |
| **发送 Untagged 帧** | - | - |

## 对比场景：不同网段不同 VLAN ID 通信

网络拓扑如下：

![](https://pic1.imgdb.cn/item/6882f89e58cb8da5c8d95a40.png)

部署脚本：

```shell
#!/bin/bash

set -x

if ip netns show | grep -q "router"; then
  ip netns del router
  echo "Namespace router 已删除"
fi

if ip netns show | grep -q "sw1"; then
  ip netns del sw1
  echo "Namespace sw1 已删除"
fi

if ip netns show | grep -q "sw2"; then
  ip netns del sw2
  echo "Namespace sw2 已删除"
fi

if ip netns show | grep -q "s1"; then
  ip netns del s1
  echo "Namespace s1 已删除"
fi

if ip netns show | grep -q "s2"; then
  ip netns del s2
  echo "Namespace s2 已删除"
fi

sleep 2

# 创建路由器、交换机、服务器命名空间
ip netns add router
ip netns add sw1
ip netns add sw2
ip netns add s1
ip netns add s2

# 路由器 <-> 交换机链路
ip link add r2sw1 type veth peer name sw1r
ip link set r2sw1 netns router
ip netns exec router ip link set r2sw1 up
ip link set sw1r netns sw1

ip link add r2sw2 type veth peer name sw2r
ip link set r2sw2 netns router
ip netns exec router ip link set r2sw2 up
ip link set sw2r netns sw2

ip netns exec router ip addr add 192.168.10.1/24 dev r2sw1
ip netns exec router ip addr add 192.168.20.1/24 dev r2sw2

# 交换机 <-> 服务器链路
ip link add sw12s1 type veth peer name s1sw1
ip link set sw12s1 netns sw1
ip link set s1sw1 netns s1

ip link add sw22s2 type veth peer name s2sw2
ip link set sw22s2 netns sw2
ip link set s2sw2 netns s2

# SW1 配置
ip netns exec sw1 ip link add br10 type bridge
ip netns exec sw1 ip link set br10 type bridge vlan_filtering 1
ip netns exec sw1 ip link set br10 up
ip netns exec sw1 ip link set sw1r master br10
ip netns exec sw1 ip link set sw1r up
ip netns exec sw1 ip link set sw12s1 master br10
ip netns exec sw1 ip link set sw12s1 up
ip netns exec sw1 bridge vlan add vid 10 dev br10 pvid tagged self
ip netns exec sw1 bridge vlan add dev sw1r vid 10 pvid untagged
ip netns exec sw1 bridge vlan add dev sw12s1 vid 10 pvid untagged
ip netns exec sw1 bridge vlan del dev br10 vid 1 self # 删除默认 VLAN
ip netns exec sw1 bridge vlan del dev sw1r vid 1 # 删除默认 VLAN
ip netns exec sw1 bridge vlan del dev sw12s1 vid 1 # 删除默认 VLAN

# SW2 配置
ip netns exec sw2 ip link add br20 type bridge
ip netns exec sw2 ip link set br20 type bridge vlan_filtering 1
ip netns exec sw2 ip link set br20 up
ip netns exec sw2 ip link set sw2r master br20
ip netns exec sw2 ip link set sw2r up
ip netns exec sw2 ip link set sw22s2 master br20
ip netns exec sw2 ip link set sw22s2 up
ip netns exec sw2 bridge vlan add vid 20 dev br20 pvid tagged self
ip netns exec sw2 bridge vlan add dev sw2r vid 20 pvid untagged
ip netns exec sw2 bridge vlan add dev sw22s2 vid 20 pvid untagged
ip netns exec sw2 bridge vlan del dev br20 vid 1 self # 删除默认 VLAN
ip netns exec sw2 bridge vlan del dev sw2r vid 1 # 删除默认 VLAN
ip netns exec sw2 bridge vlan del dev sw22s2 vid 1 # 删除默认 VLAN

# 服务器 S1
ip netns exec s1 ip addr add 192.168.10.2/24 dev s1sw1
ip netns exec s1 ip link set s1sw1 up
ip netns exec s1 ip route add default via 192.168.10.1

# 服务器 S2
ip netns exec s2 ip addr add 192.168.20.2/24 dev s2sw2
ip netns exec s2 ip link set s2sw2 up
ip netns exec s2 ip route add default via 192.168.20.1

set +x

```

执行命令：

```shell
➜  ~ ip netns exec s1 ping -c1 192.168.20.2
PING 192.168.20.2 (192.168.20.2) 56(84) bytes of data.
64 bytes from 192.168.20.2: icmp_seq=1 ttl=63 time=0.256 ms

--- 192.168.20.2 ping statistics ---
1 packets transmitted, 1 received, 0% packet loss, time 0ms
rtt min/avg/max/mdev = 0.256/0.256/0.256/0.000 ms
```

之所以不同 VLAN ID 都可以通信，其实是因为 VLAN ID 只在 sw1、 sw2 两个 namespace 内部使用

抓包结果、结论与上节相同，不再重复，该实验仅作对比

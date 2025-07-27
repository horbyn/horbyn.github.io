---
title: KVM 集群部署
date: 2025-07-24 23:17:40
excerpt: 记录了 KVM 集群的安装、虚拟机（Ubuntu 22.04）部署及 NAT 网络下的端口映射配置，重点通过 iptables 实现局域网访问虚拟机，并通过日志分析验证了流量转发机制
tags: 虚拟化
---

## 环境验证与安装

参考：

- [Ubuntu安裝QEMU/KVM和Virt Manager虛擬機管理員](https://ivonblog.com/posts/ubuntu-virt-manager/)
- [如何在 Ubuntu 24.04 安装 KVM ？](https://www.koogua.com/article/584)

步骤：

- 确认裸机支持虚拟化
    ```shell
    sudo grep -E -c '(vmx|svm)' /proc/cpuinfo # 输出中包含 vmx 或 svm
    sudo lsmod | grep kvm # 输出包含 kvm
    ```
- 依赖安装
    ```shell
    sudo apt install qemu-system libguestfs-tools libvirt-clients libvirt-daemon-system bridge-utils virt-manager ovmf swtpm
    ```
- 服务启动与验证
    ```shell
    sudo systemctl status libvirtd
    sudo systemctl enable libvirtd
    sudo systemctl restart libvirtd
    ```

## 虚拟机部署流程

- 使用专用用户与用户组来运行虚拟机
    ```shell
    sudo usermod -a -G libvirt $USER
    sudo usermod -a -G kvm $USER
    ```
- 准备镜像
    在创建虚拟机之前先下载虚拟机需要用的镜像，[Thank you for downloading Ubuntu Server 22.04.5 LTS](https://ubuntu.com/download/server/thank-you?version=22.04.5&architecture=amd64&lts=true)
    ```shell
    sudo mkdir -p /var/lib/libvirt/iso
    sudo cd /var/lib/libvirt/iso
    sudo wget https://releases.ubuntu.com/22.04.5/ubuntu-22.04.5-live-server-amd64.iso
    ```
- 安全配置
    然后修改 `/etc/libvirt/qemu.conf` 文件设置一个使用虚拟机的管理用户，不建议用 root，这样虚拟机进程会以 root 用户身份运行，root 将拥有系统上的所有权限
    ```shell
    user = "libvirt-qemu"
    group = "kvm"
    ```
    重启生效：`systemctl restart libvirtd`
- 创建虚拟机
    安装虚拟机参考 [云计算基础-virt-install创建虚拟机](https://www.bilibili.com/video/BV14A411i7bv/?vd_source=bfa0dadd9476ea4dc18addc67dbc9b83)
    ```shell
    mkdir -p /var/lib/libvirt/disk
    virt-install \
        --hvm \
        --name vm1 \
        --memory 2048 \
        --vcpus 1 \
        --disk path=/var/lib/libvirt/disk/vm1,size=10 \
        --network bridge=virbr0 \
        --os-variant auto \
        --graphics vnc,port=5901,listen=0.0.0.0 \
        --location /var/lib/libvirt/iso/ubuntu-22.04.5-live-server-amd64.iso
    ```
    **关键说明**：  
    - VNC 端口映射需通过客户端（如 TigerVNC）连接 `宿主机 IP:5901`
    - 同法创建 `vm2` 时需修改 `--name` 和 VNC 端口（如 `port=5902`）

下面是一个示例：

```shell
root@byn-N1-PRO:/var/lib/libvirt/iso# virt-install --hvm --name vm1 --memory 2048 --vcpus 1 --disk path=/var/lib/libvirt/disk/vm1,size=10 --network bridge=virbr0 --os-variant auto --graphics vnc,port=5901,listen=0.0.0.0 --location /var/lib/libvirt/iso/ubuntu-22.04.5-live-server-amd64.iso
WARNING  Graphics requested but DISPLAY is not set. Not running virt-viewer.
WARNING  No console to launch for the guest, defaulting to --wait -1

Starting install...
Retrieving 'vmlinuz'                                                                                                                    |    0 B  00:00:00 ... 
Retrieving 'initrd'                                                                                                                     |    0 B  00:00:00 ... 
Allocating 'vm1'                                                                                                                        |    0 B  00:00:00 ... 
Creating domain...                                                                                                                      |    0 B  00:00:00     

Domain is still running. Installation may be in progress.
Waiting for the installation to complete.
```

在终端通过这个命令创建虚拟机时会阻塞，所以需要新建一个终端窗口来查看虚拟机的状态：

```shell
root@byn-N1-PRO:~# ps aux | grep kvm
libvirt+   67228 70.5 18.6 2996036 2226276 ?     Sl   22:26   0:45 /usr/bin/qemu-system-x86_64 -name guest=vm1, ...
root       67243  0.0  0.0      0     0 ?        S    22:26   0:00 [kvm-pit/67228]

root@byn-N1-PRO:~# ss -tlnp
State   Recv-Q  Send-Q  Local Address:Port  Peer Address:Port  Process                                                                                   
LISTEN  0       1             0.0.0.0:5901       0.0.0.0:*      users:(("qemu-system-x86",pid=67228,fd=23))
```

现在这个状态说明虚拟机启动盘已经加载起来了，接下来只需要用一个 VNC 客户端（比如 [tiger VNC](https://github.com/TigerVNC/tigervnc)，对于 Windows 客户端来说选择 `tigervnc64-X.Y.Z.exe` 或 `vncviewer64-X.Y.Z.exe`）连接到这个环境的 5901 端口就可以了

![](https://pic1.imgdb.cn/item/687e53d858cb8da5c8ca1541.png)

接下来就像安装 Ubuntu 系统一样，这里省略

## 虚拟机管理命令
```shell
virsh list --all       # 查看所有虚拟机状态
virsh shutdown vm2     # 关闭 vm2
virsh start vm2        # 启动 vm2
```

## 宿主机局域网中其他设备访问在 NAT 私网的 KVM 虚拟机

- 虚拟机集群默认访问方法
    - 在局域网内其他机器上通过 VNC 端口访问
    - 在宿主机通过 ssh 访问（在安装 Ubuntu 系统时会指定一个静态的地址）
- 局域网内网络拓扑问题
    宿主机物理网卡（如 `wlp2s0`）位于 `192.168.0.0/24` 网段，而虚拟机通过 `virbr0` 分配 `192.168.122.0/24` 地址，导致局域网设备无法直连虚拟机。更具体来说，虚拟机集群的网络在宿主机上是通过 NAT 来部署
    ```shell
    ip addr show                    # 查看宿主机网络配置
    virsh net-dhcp-leases default   # 查看虚拟机集群网络配置
    ```
- 端口映射方案
    如果局域网内想访问 NAT 私网中的虚拟机集群，其中一个办法就是做端口映射，也就是说把宿主机的某个端口映射到虚拟机的某个端口，具体来说是映射到宿主机的 22 号端口，这样我们就可以在局域网内通过 ssh 连接 NAT 私网内的虚拟机集群了
    ```shell
    # 映射宿主机 22221 端口至 vm2（192.168.122.220） 22 号端口
    iptables -t nat -A PREROUTING -p tcp --dport 22221 -j DNAT --to-destination 192.168.122.220:22
    iptables -I FORWARD 1 -i wlp2s0 -d 192.168.122.220 -p tcp --dport 22 -j ACCEPT

    # 映射宿主机 22222 端口至 vm1（192.168.122.213） 22 号端口
    iptables -t nat -A PREROUTING -p tcp --dport 22222 -j DNAT --to-destination 192.168.122.213:22
    iptables -I FORWARD 2 -i wlp2s0 -d 192.168.122.213 -p tcp --dport 22 -j ACCEPT
    ```
    **访问方式**：
    ```shell
    # 宿主机地址 192.168.0.116
    ssh vm2@192.168.0.116 -p 22221
    ssh vm1@192.168.0.116 -p 22222
    ```
- 流量路径验证
    可以通过 iptables 日志确认 DNAT 生效情况：
    ```shell
    # NAT/PREROUTING 链的第一个结点用来观察的是进入宿主机之后，在 DNAT 之前的原始流量
    iptables -t nat -I PREROUTING 1 -j LOG --log-prefix "DBG@NAT_PREROUTING: "

    # FILTER/FORWARD 链的第一个结点用来观察流量被过滤之前的信息
    iptables -I FORWARD 1 -j LOG --log-prefix "DBG@FILTER_FORWARD: "

    # FILTER/INPUT 链最后一个结点用来观察最后一步是否能进入本机
    iptables -A INPUT -j LOG --log-prefix "DBG@FILTER_INPUT: "

    # MANGLE/PREROUTING 链第一个结点用来观察流量未进行 SNAT 的原始报文信息
    iptables -t mangle -I POSTROUTING 1 -j LOG --log-prefix "DBG@MANGLE_POSTROUTING: "

    # NAT/POSTROUTING 链最后一个结点也是用来观察流量在 SNAT 之前的原始信息，和前一个区别是不重定向回本机的流量不会进入 NAT 表
    iptables -t nat -A POSTROUTING -j LOG --log-prefix "DBG@NAT_POSTROUTING: "

    # 实时观察流量，grep -v 用来排除环回口的流量，不然会很多
    dmesg -w | grep "DBG" | grep -v "lo"
    ```

下面是一个示例，当我们在局域网内执行：

```shell
# 局域网内通过客户端 192.168.0.112 访问
ssh -XY vm2@192.168.0.116 -p 22221
```

宿主机系统日志（节选）会观察到：

```shell
# SYN 请求
[ 3219.831028] DBG@NAT_PREROUTING: IN=wlp2s0 OUT= MAC=b0:ac:82:82:9c:81:b0:47:e9:5e:7b:8a:08:00 SRC=192.168.0.112 DST=192.168.0.116 LEN=52 TOS=0x00 PREC=0x00 TTL=128 ID=49334 DF PROTO=TCP SPT=5669 DPT=22221 WINDOW=65535 RES=0x00 SYN URGP=0 
[ 3219.831084] DBG@FILTER_FORWARD: IN=wlp2s0 OUT=virbr0 MAC=b0:ac:82:82:9c:81:b0:47:e9:5e:7b:8a:08:00 SRC=192.168.0.112 DST=192.168.122.220 LEN=52 TOS=0x00 PREC=0x00 TTL=127 ID=49334 DF PROTO=TCP SPT=5669 DPT=22 WINDOW=65535 RES=0x00 SYN URGP=0 
[ 3219.831108] DBG@MANGLE_POSTROUTING: IN=wlp2s0 OUT=virbr0 MAC=b0:ac:82:82:9c:81:b0:47:e9:5e:7b:8a:08:00 SRC=192.168.0.112 DST=192.168.122.220 LEN=52 TOS=0x00 PREC=0x00 TTL=127 ID=49334 DF PROTO=TCP SPT=5669 DPT=22 WINDOW=65535 RES=0x00 SYN URGP=0 
[ 3219.831128] DBG@NAT_POSTROUTING: IN=wlp2s0 OUT=virbr0 MAC=b0:ac:82:82:9c:81:b0:47:e9:5e:7b:8a:08:00 SRC=192.168.0.112 DST=192.168.122.220 LEN=52 TOS=0x00 PREC=0x00 TTL=127 ID=49334 DF PROTO=TCP SPT=5669 DPT=22 WINDOW=65535 RES=0x00 SYN URGP=0 

# SYN ACK
[ 3219.831982] DBG@FILTER_FORWARD: IN=virbr0 OUT=wlp2s0 MAC=52:54:00:12:1b:e1:52:54:00:11:b3:ed:08:00 SRC=192.168.122.220 DST=192.168.0.112 LEN=52 TOS=0x00 PREC=0x00 TTL=63 ID=0 DF PROTO=TCP SPT=22 DPT=5669 WINDOW=64240 RES=0x00 ACK SYN URGP=0 
[ 3219.832016] DBG@MANGLE_POSTROUTING: IN=virbr0 OUT=wlp2s0 MAC=52:54:00:12:1b:e1:52:54:00:11:b3:ed:08:00 SRC=192.168.122.220 DST=192.168.0.112 LEN=52 TOS=0x00 PREC=0x00 TTL=63 ID=0 DF PROTO=TCP SPT=22 DPT=5669 WINDOW=64240 RES=0x00 ACK SYN URGP=0 
```

结合宿主机、virbr0 和 vm 虚拟机中抓包：

```shell
root@byn-N1-PRO:~# tcpdump -i wlp2s0 -n host 192.168.0.112 and port 22221
tcpdump: verbose output suppressed, use -v[v]... for full protocol decode
listening on wlp2s0, link-type EN10MB (Ethernet), snapshot length 262144 bytes
16:08:10.340899 IP 192.168.0.112.5669 > 192.168.0.116.22221: Flags [S], seq 978217954, win 65535, options [mss 1460,nop,wscale 8,nop,nop,sackOK], length 0
16:08:10.341973 IP 192.168.0.116.22221 > 192.168.0.112.5669: Flags [S.], seq 3421888150, ack 978217955, win 64240, options [mss 1460,nop,nop,sackOK,nop,wscale 7], length 0


root@byn-N1-PRO:~# tcpdump -i virbr0 -n
tcpdump: verbose output suppressed, use -v[v]... for full protocol decode
listening on virbr0, link-type EN10MB (Ethernet), snapshot length 262144 bytes
16:08:10.341082 IP 192.168.0.112.5669 > 192.168.122.220.22: Flags [S], seq 978217954, win 65535, options [mss 1460,nop,wscale 8,nop,nop,sackOK], length 0
16:08:10.341856 IP 192.168.122.220.22 > 192.168.0.112.5669: Flags [S.], seq 3421888150, ack 978217955, win 64240, options [mss 1460,nop,nop,sackOK,nop,wscale 7], length 0


vm2@vm2-host:~$ sudo tcpdump -i enp1s0 -n
08:08:10.384895 IP 192.168.0.112.5669 > 192.168.122.220.22: Flags [S], seq 978217954, win 65535, options [mss 1460,nop,wscale 8,nop,nop,sackOK], length 0
08:08:10.385175 IP 192.168.122.220.22 > 192.168.0.112.5669: Flags [S.], seq 3421888150, ack 978217955, win 64240, options [mss 1460,nop,nop,sackOK,nop,wscale 7], length 0
```

路由表（节选）：

```shell
root@byn-N1-PRO:~# ip route show
192.168.122.0/24 dev virbr0 proto kernel scope link src 192.168.122.1
```

- TCP 的 SYN 请求
   - 通过 NAT/PREROUTING 链可知，从局域网进入宿主机 wlp2s0 网络接口。原始请求 192.168.0.112:5669 -> 192.168.0.116:22221，经过 DNAT 后变成 192.168.0.112:5669 -> 192.168.122.220:22
   - 进入路由决策，通过路由表可知，去到 192.168.122.0/24 网段走 virbr0 网络接口
   - 通过 FILTER/FORWARD 链可知，OUT=virbr0，即路由决策之后就确定了需要到达 virbr0 网络接口
   - 通过 MANGLE/POSTROUTING 链可知，对于 NAT 私网的流量，不会进入 INPUT 链，也就是说不会进入本机应用层，而是进行重定向，送入其他网卡
   - NAT/POSTROUTING 链的报文信息和 MANGLE/POSTROUTING 链是一致的
   - 离开协议栈，重定向到 virbr0 网络接口
- TCP 的 SYN ACK 响应
   - 此时响应应该是在虚拟机中产生，后续会传递到 virbr0，通过虚拟机抓包可知，原始响应是 192.168.122.220:22 -> 192.168.0.112:5669
   - 进入路由决策
   - 进入 FILTER/FORWARD 链，IN=virbr0，OUT=wlp2s0，即从 virbr0 网络接口进入 wlp2s0 网络接口
   - 进入 MANGLE/PREROUTING 链，报文信息不变
   - 离开协议栈，重定向到 wlp2s0 网络接口

总结一下：

  - **请求路径**：外部 `SYN` 包经 DNAT 后目标地址变为虚拟机 IP   
  - **响应路径**：虚拟机返回包经 FORWARD 链直接路由至物理网卡 

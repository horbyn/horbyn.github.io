---
title: 部署 HAProxy + Keepalived
date: 2025-07-27 18:11:04
excerpt: 记录了通过 KVM 集群部署高可用的经过，包括部署过程和业务访问的测试
tags: 虚拟化
---

## 网络拓扑与配置方案

### 网络拓扑说明：

![](https://pic1.imgdb.cn/item/6884526d58cb8da5c8e0c8ae.png)

```
物理机（部署 KVM 集群的宿主机）
├─ IP: 192.168.0.115 (以太网网卡，连接外部网络)
└─ NAT 网络: 192.168.122.0/24
   ├─ vm1: 192.168.122.213 (KVM 虚拟机 1)
   └─ vm2: 192.168.122.220 (KVM 虚拟机 2)
```

后文统一将部署 HAProxy 和 keepalived 的物理机称为宿主机

---

## HAProxy 配置详解
配置文件路径：`/etc/haproxy/haproxy.cfg`，在 vm1 和 vm2 上都设置

```cfg
global
    log /dev/log local0
    log /dev/log local1 notice
    maxconn 4096
    user haproxy
    group haproxy
    daemon

defaults
    log global
    mode http
    option httplog
    option dontlognull
    timeout connect 5000
    timeout client 50000
    timeout server 50000
    errorfile 400 /etc/haproxy/errors/400.http
    errorfile 403 /etc/haproxy/errors/403.http
    errorfile 408 /etc/haproxy/errors/408.http
    errorfile 500 /etc/haproxy/errors/500.http
    errorfile 502 /etc/haproxy/errors/502.http
    errorfile 503 /etc/haproxy/errors/503.http
    errorfile 504 /etc/haproxy/errors/504.http

# 前端配置：接收客户端请求
frontend http-in
    bind *:80                               # 监听所有接口的80端口
    default_backend servers                 # 指定默认后端组

# 后端配置：定义服务器组和负载均衡策略
backend servers
    balance roundrobin                      # 使用轮询负载均衡算法
    server web1 192.168.122.213:8080 check  # vm1 部署后端服务器1
    server web2 192.168.122.220:8080 check  # vm2 部署后端服务器2

# 统计页面配置（可选）
listen stats
    bind *:1936                             # 统计页面访问端口
    mode http
    stats enable
    stats uri /                             # 统计页面路径
    stats auth admin:password               # 登录凭证
```

配置说明：

1. **frontend**：定义客户端访问入口
   - `bind *:80`：监听所有网络接口的 80 端口
   
2. **backend**：定义后端服务器池
   - `balance roundrobin`：轮询负载均衡算法
   - `server web1 ... check`：健康检查自动标记故障节点

3. **stats**：监控页面
   - 访问 `http://<IP>:1936` 查看流量统计和服务器状态（IP 用宿主机地址）

---

## Keepalived 配置详解
配置文件路径：`/etc/keepalived/keepalived.conf`，在 vm1 和 vm2 上都设置

**关于 Keepalived VIP 的选择：**
- Keepalived 的 VIP 必须在同一个二层网络内才能实现 ARP 广播
- vm1 和 vm2 位于 NAT 网络 192.168.122.0/24
- 使用局域网地址会导致 ARP 请求无法到达虚拟机

### vm1 (主节点) 配置：
```cfg
global_defs {
    router_id LVS_MASTER    # 唯一标识
    enable_script_security
    script_user root        # 使用root用户执行脚本，或者创建一个专用用户
}

vrrp_script chk_haproxy {
    script "/etc/keepalived/check_haproxy.sh"
    interval 2              # 每2秒检查一次
    fall 2                  # 连续2次失败则认为失败
    rise 1                  # 连续1次成功则认为成功
    weight -51              # 权重变化值
}

vrrp_instance VI_1 {
    state MASTER            # 初始状态为主
    interface enp1s0        # 虚拟机网卡名称(需根据实际修改)
    virtual_router_id 51    # 虚拟路由ID(0-255，集群内唯一)
    priority 150            # 优先级(主>备)
    advert_int 1            # VRRP通告间隔(秒)

    authentication {
        auth_type PASS      # 认证类型
        auth_pass 1111      # 认证密码(集群内相同)
    }

    virtual_ipaddress {
        192.168.122.100/24  # 虚拟IP(VIP)
    }

    track_script {
        chk_haproxy         # 关联健康检查脚本
    }
}
```

### vm2 (备用节点) 配置：
```cfg
global_defs {
    router_id LVS_BACKUP    # 唯一标识
    enable_script_security
    script_user root        # 使用root用户执行脚本，或者创建一个专用用户
}

vrrp_script chk_haproxy {
    script "/etc/keepalived/check_haproxy.sh"
    interval 2              # 每2秒检查一次
    fall 2                  # 连续2次失败则认为失败
    rise 1                  # 连续1次成功则认为成功
    weight -30              # 权重变化值
}

vrrp_instance VI_1 {
    state BACKUP            # 初始状态为备
    interface ens3          # 与主节点相同网卡
    virtual_router_id 51    # 必须与主节点相同
    priority 100            # 优先级低于主节点
    advert_int 1

    authentication {
        auth_type PASS
        auth_pass 1111
    }

    virtual_ipaddress {
        192.168.122.100/24
    }

    track_script {
        chk_haproxy
    }
}
```

### 脚本说明：

健康检查脚本 `/etc/keepalived/check_haproxy.sh`：

```shell
#!/bin/bash

set -euo pipefail
systemctl is-active --quiet haproxy

```

### 配置说明：
1. **vrrp_script**：定义服务健康检查
   - 当 HAProxy 进程不存在时，权重降低可能导致主备切换
2. **vrrp_instance**：定义 VIP 实例
   - `virtual_router_id`：集群内必须一致
   - `priority`：主节点(150) > 备节点(100)
   - `virtual_ipaddress`：VIP 地址（必须位于 NAT 网络）
3. **故障转移机制**：
   - 主节点故障时，备用节点自动接管 VIP
   - 健康检查失败触发权重变化，导致优先级反转
4. **日志文件**：
    - haproxy 配置文件在 `/var/log/haproxy.log`
    - keepalived 默认无配置文件，可以通过 `journalctl -u keepalived -f --since "2025-07-22 08:12:30"` 的方式过滤时间并查看日志

---

## 端口转发配置
在宿主机上设置 DNAT 规则，将外部请求转发到 VIP：

```bash
# 添加端口转发规则
sudo iptables -t nat -A PREROUTING -d 192.168.0.115 -p tcp --dport 80 -j DNAT --to-destination 192.168.122.100:80
iptables -I FORWARD 3 -i wlp2s0 -d 192.168.122.100 -p tcp --dport 80 -j ACCEPT
iptables -t nat -A PREROUTING -p tcp -d 192.168.0.115 --dport 1936 -j DNAT --to-destination 192.168.122.100:1936
iptables -I FORWARD 4 -i wlp2s0 -d 192.168.122.100 -p tcp --dport 1936 -j ACCEPT

# 启用 IP 转发
sudo sysctl net.ipv4.ip_forward=1

# 保存 iptables 规则
sudo apt install iptables-persistent -y
sudo netfilter-persistent save
```

**转发路径**：
外部请求 → 宿主机 (192.168.0.115:80) → DNAT → VIP (192.168.122.100:80) → HAProxy → 后端 Web 服务器

---

## 测试场景设计与部署

### 部署测试 Web 应用
在 vm1 和 vm2 上分别运行 Web 服务器：

```bash
# 在 vm1 (192.168.122.213) 上：
echo "Server 1 | Host: vm1" > index.html
python3 -m http.server 8080 &

# 在 vm2 (192.168.122.220) 上：
echo "Server 2 | Host: vm2" > index.html
python3 -m http.server 8080 &
```

### 配置并启动服务
```bash
# 在所有节点执行
sudo systemctl restart haproxy
sudo systemctl restart keepalived
```

### 测试场景

**场景 1：基本负载均衡测试**
```bash
# 从外部机器连续访问
for i in {1..10}; do
    curl http://192.168.0.115
    sleep 0.5
done

# 预期输出交替显示：
# Server 1 | Host: vm1
# Server 2 | Host: vm2
```

**场景 2：故障转移测试**
```bash
# 1. 查看当前 VIP 所在节点（初始情况下 vm1 是主结点）
ssh root@192.168.0.115 -p 22221 "ip addr show enp1s0 | grep 192.168.122.100"

# 2. 停止主节点 HAProxy
ssh root@192.168.0.115 -p 22221 "systemctl stop haproxy"

# 3. 观察 VIP 漂移
ssh root@192.168.0.115 -p 22222 "ip addr show enp1s0 | grep 192.168.122.100"

# 4. 验证服务连续性
curl http://192.168.0.115  # 应继续得到响应
```

**场景 3：高可用验证**
```bash
# 1. 模拟节点宕机
ssh root@192.168.0.115 "virsh shutdown vm1 && virsh shutdown vm2"

# 2. 监控恢复时间
time while ! curl -s http://192.168.0.115 >/dev/null; do
    sleep 0.1
done
```

### 监控与观察
1. **HAProxy 统计页面**：
   `http://192.168.0.115:1936` (用户: admin, 密码: password)
   - 观察流量分布
   - 查看服务器健康状态

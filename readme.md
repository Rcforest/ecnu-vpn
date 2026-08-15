# ECNU VPN CLI (macOS)

一个基于 [openconnect](https://www.infradead.org/openconnect/) 的一键 VPN 脚本，支持：
- ✅ 全局模式：所有流量走 VPN
- 🔀 分流模式（split-tunnel）：指定站点流量走 VPN
- 🔐 从 macOS Keychain 或环境变量读取密码

⚠️ 目前脚本仅在 macOS 上测试通过。



## 📦 安装依赖

在使用前，请确保已安装以下依赖：

```bash
brew install openconnect
```

- openconnect：核心 VPN 客户端
- openconnect 附带的 vpnc-script：负责设置 VPN 路由
- 分流模式还需要 macOS 自带或已安装的 `dig` 用于解析域名清单



## ⚙️ 环境配置

在项目根目录创建 .env 文件，用于管理所有可配置项：

```bash
# VPN 配置
VPN_HOST=vpn-ct.ecnu.edu.cn
VPN_USER=your_id
VPN_PASS=your_password_here          # 可选，如果不使用 Keychain

# Keychain 配置（推荐方式）
KEYCHAIN_LABEL=ECNU_VPN

# 路径配置
TMP_DIR=./tmp
LOG_FILE=./tmp/ecnu-vpn.log
PID_FILE=./tmp/openconnect-ecnu.pid

```

📌 建议优先使用 Keychain 存储密码：
```bash
security add-generic-password -a "your_ids" -s "ECNU_VPN" -w
```

脚本支持按需启用“学术网站分流”功能。通过 .env 中的配置即可控制是否启用分流，并指定域名列表文件：

```bash
AUTO_SPLIT=1                        
DOMAINS_FILE=./domains.txt 
```
- 当 AUTO_SPLIT=1 时，脚本会自动读取 DOMAINS_FILE 中的域名列表，并为这些域名添加 VPN 路由；
- 如需让固定 IP（例如 SSH 主机）走 VPN，可仅在个人 `.env` 中设置空格分隔的 `SPLIT_IPS`；每个地址添加一条精确 `/32` 路由，不会改变其他外网流量的默认路由；
- DOMAINS_FILE 是一个 纯文本文件，每行一个域名，例如：

```bash
ieeexplore.ieee.org
dl.acm.org
link.springer.com
sciencedirect.com
```

### 校园网服务器分流

当实验服务器只能从校园 VPN 访问，或需要 SSH 连接固定 IPv4 的校园网主机时，在个人 `.env` 中添加 `SPLIT_IPS`。使用 SSH 跳板机时，应同时填入跳板机和目标服务器的 IP：

```bash
# 用实际 IPv4 替换尖括号内的占位符
SPLIT_IPS="<jump-host-ip> <campus-server-ip>"
```

随后以分流模式连接：

```bash
sudo bash ./ecnu-vpn.sh up --split
```

脚本会为每个地址安装精确 `/32` VPN 路由；这些校园服务器流量进入 VPN，未列出的本地与外网流量仍使用原有默认路由。



## 🚀 使用方式

1. 全局模式（默认）

```bash
sudo bash ./ecnu-vpn.sh up
```

- 建立 VPN 连接
- 所有流量将通过 VPN 出口
- 日志会输出当前出口 IP

2. 分流模式（推荐用于学术访问）

```bash
sudo bash ./ecnu-vpn.sh up --split
```

- 仅将 `DOMAINS_FILE` 中的域名和 `SPLIT_IPS` 中的固定 IP 流量走 VPN
- 其他网站保持本地网络出口
- 推荐用于下载论文、访问数据库等学术场景

3. 查看状态

```bash
./ecnu-vpn.sh status
```

- 显示当前 VPN 连接状态和 PID

4. 断开连接

```bash
sudo bash ./ecnu-vpn.sh down
```
- 中断连接



## 📁 日志与调试

日志默认写入：

```bash
./tmp/ecnu-vpn.log
```

可以用以下命令实时查看：

```bash
tail -f ./tmp/ecnu-vpn.log
```

⸻

📌 备注
- 本脚本目前仅在 macOS (arm64) 环境下测试通过；
- Linux 下理论上也可运行，但 DNS 与路由脚本需要适配；

# ECNU aTrust VPN（macOS / Linux）

一条命令连接华东师范大学 VPN（深信服 aTrust），支持 macOS 和 Linux。

> 本项目基于 [@Hagb](https://github.com/Hagb) 的 [docker-easyconnect](https://github.com/Hagb/docker-easyconnect)（Docker 镜像 `hagb/docker-atrust`）开发。aTrust 客户端的容器化由该项目完成，本仓库在其基础上补充了 ECNU 统一身份认证的自动登录、命令行封装和 Raycast 集成。

- aTrust 客户端运行在 Docker 容器（`hagb/docker-atrust`）里，不在本机安装客户端；
- 学校 SSO 登录由脚本通过 HTTPS 自动完成。macOS 上密码优先从钥匙串读取，Linux 上读取 `.env` 里的 `VPN_PASS`；遇到验证码或二次认证时自动改用浏览器；
- 不修改系统路由和 DNS，也不需要 `sudo`。需要走校园网的应用通过本地代理接入。

## 依赖

- Docker 和 Docker Compose v2.24 或更新版本（`docker compose`；`docker-compose.yml` 里 `env_file` 的 `required` 写法需要这个版本）。macOS 可用 [OrbStack](https://orbstack.dev/) 或 Docker Desktop；Linux 需要宿主机有 `/dev/net/tun`，当前用户能直接运行 `docker`（例如已加入 `docker` 组）
- Bash、Python 3.9+（只用标准库）
- `/usr/bin/curl`、`/usr/bin/openssl`。macOS 自带；Linux 发行版通常也装在这里，没有的话用包管理器安装
- 可选：macOS 的 `security`（钥匙串，系统自带）；Linux 上用于打开浏览器的 `xdg-open`

## 首次配置

**1. 创建容器**

```bash
cp atrust.env.example atrust.env   # 填写 VNC 密码（不是学校密码）
docker compose up -d
```

**2. 配置账号**

```bash
cp .env.example .env               # 填写 VPN_USER（学号 / 工号）
chmod 600 .env
```

| 变量 | 说明 | 默认值 |
| --- | --- | --- |
| `VPN_USER` | 学号 / 工号 | 无，必填 |
| `KEYCHAIN_LABEL` | macOS 钥匙串条目的服务名 | `ECNU_VPN` |
| `VPN_PASS` | 学校密码。macOS 上只在钥匙串读不到时使用；Linux 上必填 | 不设置 |

**3. 提供学校密码**

脚本按下面的顺序找密码：

1. 系统有 macOS 钥匙串（`/usr/bin/security`）时，先查钥匙串；
2. 没有钥匙串或查不到时，用 `.env` 里的 `VPN_PASS`。在 macOS 上走到这一步时，终端会提示一句；
3. 两者都没有时报错退出。

*macOS（推荐用钥匙串）：*

```bash
security add-generic-password -a "<学号>" -s ECNU_VPN -w   # 回车后按提示输入密码
```

脚本第一次读取时，macOS 可能会弹窗请求授权。要用的是钥匙串里的“通用密码”条目，Apple“密码”App 里保存的网站密码读不到。

*Linux，或不想用钥匙串时：* 在 `.env` 里写 `VPN_PASS=<密码>`。密码会以明文保存在磁盘上，`.env` 已被 git 忽略，但请确保文件权限是 `600`。

## 使用

```bash
./atrust-vpn.sh up                 # 启动容器 → 登录 → 确认隧道可用（已连接时直接返回）
./atrust-vpn.sh status             # 查询实际连接状态，已连接时退出码为 0
./atrust-vpn.sh down               # 注销会话并停止容器
./atrust-vpn.sh login --http-only  # 调试：不使用缓存 Cookie 重新登录，失败也不打开浏览器
```

- `up` 会复用上次保存的 SSO Cookie；`login` 不使用缓存，用来单独检查“密码 → SSO → 客户端”这条链路。
- 如果服务端要求验证码、二次认证，或 HTTP 登录失败，`up` 会用默认浏览器打开 VPN 门户（macOS 用 `open`，Linux 用 `xdg-open`），最多等待 180 秒，可以用浏览器自动填充密码。打不开浏览器时会打印门户地址，请在**本机**浏览器里手动打开（门户页面要和本机的 aTrust 接口通信，在别的电脑上打开无效）。加上 `--http-only` 则不打开浏览器。
- 门户不允许同一账号同时登录两次，所以已连接时 `login` 会拒绝执行，请先 `down`。
- 判断为“已连接”需要客户端报告在线、服务器是 `https://vpn.ecnu.edu.cn`，而且隧道可用。只有容器在运行不算已连接。

### 接入代理

容器只在本机回环地址上开放端口：

| 端口 | 用途 |
| --- | --- |
| `127.0.0.1:1080` | SOCKS5 代理 |
| `127.0.0.1:8888` | HTTP 代理 |
| `127.0.0.1:5901` | VNC，可查看容器内的 aTrust 界面 |
| `127.0.0.1:54631` | aTrust 客户端本地接口，登录脚本使用 |

命令行工具直接指定代理即可，例如：

```bash
curl -x socks5h://127.0.0.1:1080 https://example.ecnu.edu.cn
```

### SSH 访问校内服务器

在 `~/.ssh/config` **最前面**加上下面这段，VPN 连上时自动走代理，没连上（比如在校内）时直连：

```sshconfig
Match originalhost lab-20 exec "/bin/bash /path/to/ecnu-vpn/atrust-vpn.sh status >/dev/null 2>&1"
    ProxyCommand /usr/bin/nc -X 5 -x 127.0.0.1:1080 %h %p
Host *

Host lab-20
    HostName <服务器 IP>
    User <用户名>
```

然后 `ssh lab-20` 就行。有多台服务器时，把别名都写进 `Match originalhost`，用逗号分隔。Linux 上 `nc -X` 需要安装 `netcat-openbsd`。

### 浏览器与分流规则

浏览器可以使用 SwitchyOmega 等插件，或者在 Clash 规则里把校内域名转发到上面的 SOCKS5 端口。

[`domains.txt`](domains.txt) 整理了校内系统（`*.ecnu.edu.cn`）和一批常用的学术网站域名（IEEE、ACM、Springer、Elsevier、NeurIPS、CVF 等），配置分流规则时可以参考。注意 `vpn.ecnu.edu.cn` 和 `sso.ecnu.edu.cn` 是 VPN 登录本身要用的地址，要放在 `ecnu.edu.cn` 规则之前并设为直连，否则还没连上 VPN 时就登录不了。例如在 Clash 里写成：

```yaml
proxies:
  - { name: ECNU, type: socks5, server: 127.0.0.1, port: 1080 }
rules:
  - DOMAIN,vpn.ecnu.edu.cn,DIRECT
  - DOMAIN,sso.ecnu.edu.cn,DIRECT
  - DOMAIN-SUFFIX,ecnu.edu.cn,ECNU
  - DOMAIN-SUFFIX,ieee.org,ECNU
  - DOMAIN-SUFFIX,acm.org,ECNU
  # ……其余域名同理
```

脚本本身不读取这个文件，增删域名不影响连接。

### Raycast（仅 macOS）

`raycast/` 下有两个 [Raycast Script Commands](https://github.com/raycast/script-commands)，把该目录加入 Raycast 即可使用：

- **ECNU VPN Status**：每 5 秒刷新一次连接状态；
- **ECNU VPN Switcher**：已连接时断开，未连接时连接。

脚本默认在 `raycast/` 的上级目录里找 `atrust-vpn.sh`。如果你只复制了 `raycast/` 目录，请设置环境变量 `ECNU_VPN_DIR` 指向本仓库。

## 安全说明

- 密码优先从 macOS 钥匙串读取，没有钥匙串或读不到时才用 `VPN_PASS`；提交前都会按网页的算法加密，经 HTTPS 发送，不会出现在命令行参数、日志或报错信息中。SSO 表单每次只提交一次，失败后不会自动重试。
- 认证请求只发往 `vpn.ecnu.edu.cn` 和 `sso.ecnu.edu.cn` 的 443 端口，跳转到其他地址会立即停止。所有请求都校验证书，并且不使用终端里的代理环境变量。
- 登录 Cookie 保存在 `tmp/atrust-auth/`（目录权限 700，文件权限 600），删除这个目录就能清除保存的会话。

## 目录结构

```
atrust-vpn.sh        入口：启动容器、加锁，调用登录脚本
atrust-login.py      CAS 登录，并把票据交给 aTrust 客户端
docker-compose.yml   aTrust 容器定义
.env.example         账号配置模板（复制为 .env）
atrust.env.example   VNC 密码模板（复制为 atrust.env）
domains.txt          校内系统与学术网站域名清单，供配置分流规则参考
raycast/             Raycast 脚本
tests/               单元测试（全部 mock，不访问网络）
atrust-data/         容器内客户端的持久化数据（已忽略）
tmp/                 Cookie、锁等运行时文件（已忽略）
```

## 开发

```bash
bash -n atrust-vpn.sh raycast/*.sh
python3 -B -m unittest discover -s tests -v
```

## 常见问题

- **提示“已有登录操作正在进行”**：上次运行异常退出后锁没有释放，删除 `tmp/atrust-login.lock` 即可。
- **54631 端口未就绪**：检查 Docker 是否在运行（Linux 上还要确认 `/dev/net/tun` 存在），可以用 `docker logs ecnu-atrust` 查看容器日志。
- **登录总是转到浏览器**：先运行 `./atrust-vpn.sh login --http-only` 看具体报错，常见原因是钥匙串条目名、`VPN_USER` 或 `VPN_PASS` 填错了。

## 致谢

- [Hagb/docker-easyconnect](https://github.com/Hagb/docker-easyconnect)：本项目依赖其提供的 `hagb/docker-atrust` 镜像运行 aTrust 客户端。容器的更多用法（端口、网关模式、其他架构等）请参考该项目的文档。
- aTrust 是深信服（Sangfor）的软件，版权归深信服所有。本项目和上游项目都不是深信服官方项目。

## 许可

本仓库的代码采用 [Apache-2.0](LICENSE) 许可。许可只覆盖本仓库的代码，不包括上游镜像和 aTrust 客户端，它们分别适用各自的许可条款。

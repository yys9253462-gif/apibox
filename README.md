# ApiBox — VPS 反代项目一键安装脚本集合

面向新手小白的 VPS（云服务器）反代项目一键部署与管理工具。通过清晰的中文交互式数字菜单，自动完成系统体检、缺失依赖补齐、Docker 与 Docker Compose 部署、端口冲突避让、域名绑定以及 Let's Encrypt 免费 HTTPS 证书申请与自动续期。

## 功能特性

- **零基础中文菜单**：数字键选择项目、查看状态、查看日志、重启、更新、卸载、返回上级，每步提供明确提示与可直接复制的手动命令。
- **自动环境准备**：自动识别系统与包管理器，自动安装缺失工具及 Docker / Docker Compose。
- **智能端口避让**：同时检测宿主机监听端口、Docker 已发布端口与 NAT 转发规则，防止端口冲突。
- **自动 HTTPS 与续期**：内置轻量级 Caddy 反向代理，自动向 Let's Encrypt 申请并后台续期 SSL 证书；如宿主机已有 Caddy 则安全备份并幂等接入；如已有 Nginx 则提供可直接粘贴的反代与 `certbot` 申请命令；也可跳过域名先用 `IP:端口` 直接访问。
- **幂等与集中配置**：所有项目配置、`.env` 随机密钥与证书集中存放在 `/opt/vps-proxy/` 下，重复执行不会丢失数据或覆盖已有密钥。
- **极易扩展**：通过 `projects.conf` 注册表与 `projects/_template.sh` 模板，几分钟即可接入新的开源反代项目。

---

## 支持的操作系统

已在以下主流 Linux 发行版（`x86_64` 与 `aarch64 / ARM64` 架构）规范下设计并适配包管理器：

| 系统系列 | 支持版本 | 包管理器 |
|---|---|---|
| Ubuntu | 20.04 / 22.04 / 24.04 LTS | `apt` |
| Debian | 11 / 12 | `apt` |
| CentOS / Rocky / AlmaLinux | 8 / 9 | `dnf` / `yum` |
| Fedora | 38+ | `dnf` |
| Alpine Linux | 3.18+ | `apk` |

---

## 使用前准备

1. **一台海外或可正常访问 GitHub / Docker Hub 的 VPS 服务器**，建议配置至少 `1 核 CPU / 1 GB 内存 / 10 GB 可用磁盘`。
2. **管理员权限**：请使用 `root` 用户登录服务器，或在普通用户下通过 `sudo` 执行。
3. **放行云厂商安全组端口**（非常关键，很多新手卡在这一步）：
   - 如果需要绑定域名并申请 HTTPS 证书：请在云厂商控制台（如 AWS / 阿里云 / 腾讯云 / Vultr）的安全组中放行 **TCP 80** 和 **TCP 443** 端口。
   - 如果暂不绑定域名、直接用 `IP:端口` 访问：请放行对应项目的服务端口（如 Sub2API 默认 `8080`，New API 默认 `3000`）。
4. **域名准备（可选）**：
   - 如需 HTTPS 域名访问，请提前在域名服务商处添加一条 `A` 记录，将域名指向本台 VPS 的公网 IP。
   - 若暂时没有域名，安装时选择 `n` 跳过即可，后续随时可以重新运行脚本补绑域名。

---

## 快速开始（一条命令直接用）

登录到您的 **VPS 服务器终端**（建议使用 `root` 用户，若为普通用户请先执行 `su -` 或 `sudo -i`），**直接复制下面这一条命令粘贴回车**：

```bash
curl -fsSL https://raw.githubusercontent.com/yys9253462-gif/apibox/main/install.sh -o /tmp/apibox.sh && bash /tmp/apibox.sh
```

> **说明**：
> - 无需提前安装 `git` 或 `Docker`，脚本会自动下载完整组件到 `/opt/apibox` 并打开中文交互菜单。
> - 以后需要更新脚本或再次打开菜单，直接执行 `bash /opt/apibox/install.sh`（或重新粘贴上面那条命令）即可。
> - **备用加速源（CDN）**（若上方 GitHub 直连较慢或不通，可改用）：
>   ```bash
>   curl -fsSL https://cdn.jsdelivr.net/gh/yys9253462-gif/apibox@main/install.sh -o /tmp/apibox.sh && bash /tmp/apibox.sh
>   ```

### 非交互快捷命令（适合进阶用户或自动化）

```bash
# 查看支持的项目列表
bash /opt/apibox/install.sh --list

# 全自动安装 Sub2API（自动选空闲端口、跳过域名绑定）
bash /opt/apibox/install.sh --project sub2api --port auto --no-domain --yes

# 全自动安装 New API 并绑定域名自动签发 HTTPS 证书
bash /opt/apibox/install.sh --project newapi --port 3000 --domain api.example.com --email admin@example.com --yes

# 演练模式（不修改系统，仅预览执行过程）
bash /opt/apibox/install.sh --project sub2api --port auto --no-domain --yes --dry-run
```

---

## 当前支持的项目

| 项目 ID | 名称 | 默认端口 | 说明 | 开源仓库 |
|---|---|---|---|---|
| `sub2api` | Sub2API | `8080` | 多账号 AI 接口聚合反代网关（Claude / OpenAI / Gemini） | [weishaw/sub2api](https://github.com/weishaw/sub2api) |
| `newapi` | New API | `3000` | 新一代大模型接口管理与分发系统 | [QuantumNous/new-api](https://github.com/QuantumNous/new-api) |
| `magpie` | Magpie | `3425` | 统一 AI Agent 模型网关（多账号自动切换与 Web 管理） | [yetone/magpie](https://github.com/yetone/magpie) |
| `agent2api` | Agent2API | `3065` | 一体化 AI Agent 网关与管理面板（OpenAI 兼容 /v1 接口 + 多渠道聚合） | [aimod-cc/agent2api](https://github.com/aimod-cc/agent2api) |

---

## 目录结构

```text
apibox/
├── .gitattributes          # 强制脚本与配置为 LF 行尾，防止跨平台换行符报错
├── .gitignore              # 忽略运行时日志与临时文件
├── install.sh              # 统一入口脚本（主菜单、子菜单、参数解析）
├── projects.conf           # 项目注册表（新增项目在此追加一行）
├── lib/                    # 公共函数库
│   ├── common.sh           # 日志、颜色、安全交互、白名单配置读写
│   ├── system.sh           # 系统/资源检测、公网IP、依赖安装、端口与防火墙
│   ├── docker.sh           # Docker/Compose 自动安装、服务启动与异常分型诊断
│   └── ssl.sh              # 反向代理管理与 Let's Encrypt 证书自动申请/续期
├── projects/               # 各项目独立安装脚本
│   ├── sub2api.sh          # Sub2API 安装与运维脚本
│   ├── newapi.sh           # New API 安装与运维脚本
│   └── _template.sh        # 新增项目标准模板
├── tests/
│   └── verify.sh           # 自动化自检与回归测试套件
└── README.md               # 使用说明与扩展指南
```

所有部署后的服务数据、密钥与证书统一集中存放在 `/opt/vps-proxy/`：

- `/opt/vps-proxy/caddy/`：内置 Caddy 配置与 Let's Encrypt 证书存储目录
- `/opt/vps-proxy/<项目ID>/`：各项目的 `docker-compose.yml`、`.env`（权限 600）、`.install.conf` 与持久化 `data/` 目录

---

## 如何扩展新增项目（仓库作者/维护者指南）

本脚手架采用 **注册表 + 独立脚本插件** 解耦设计，新增一个项目只需两步：

### 第 1 步：复制并修改项目脚本

```bash
cp projects/_template.sh projects/myproxy.sh
```

打开 `projects/myproxy.sh`，修改顶部的 `PROJ_*` 元数据（项目 ID、名称、仓库地址、默认镜像、容器端口等）以及 `docker-compose.yml` 中的环境变量与挂载卷路径，确保实现以下标准函数：
- `project_install`
- `project_status`
- `project_logs`
- `project_restart`
- `project_upgrade`
- `project_uninstall`

### 第 2 步：在 `projects.conf` 中注册一行

按照 `项目ID|显示名称|一句话简介|默认端口|脚本相对路径|开源仓库地址|默认容器镜像` 格式在 `projects.conf` 末尾追加一行：

```text
myproxy|My Proxy|我的自定义反代项目简介|9000|projects/myproxy.sh|https://github.com/yourname/myproxy|yourname/myproxy:latest
```

保存后重新运行 `bash install.sh`，新项目就会自动出现在主菜单中。最后建议运行一次自检：

```bash
bash tests/verify.sh
```

---

## 常见问题排查（FAQ）

### 1. 安装完成但浏览器打不开 `http://公网IP:端口`？
请检查以下两处：
1. **云厂商控制台安全组 / 防火墙**：是否已经放行对应端口（例如 `8080` 或 `3000`）的入方向流量？
2. **容器是否正常运行**：执行 `docker ps -a` 查看容器状态是否为 `Up`，若为 `Restarting` 或 `Exited`，在脚本菜单选择「查看实时日志」或手动执行：
   ```bash
   docker logs --tail 100 vps-proxy-sub2api
   ```

### 2. 绑定域名后，Let's Encrypt HTTPS 证书签发失败？
请按以下顺序排查：
1. **DNS 是否生效**：在本地或服务器上运行 `ping 你的域名`，确认返回的 IP 是本台 VPS 的公网 IP。
2. **80 与 443 端口是否放通**：Let's Encrypt 验证域名所有权必须从公网访问服务器的 80/443 端口，云厂商安全组务必同时放行 TCP 80 和 TCP 443。
3. **使用 Cloudflare 代理（橙色云朵）时**：请在 Cloudflare 后台 `SSL/TLS` -> `概述` 中将加密模式设为 **完全（Full）**，不要选「灵活（Flexible）」，否则会出现重定向死循环或握手失败。
4. **查看证书申请日志**：
   ```bash
   docker logs --tail 50 vps-proxy-caddy
   ```

### 3. 提示 80/443 端口已被宿主机 Nginx 占用怎么办？
为了不破坏您服务器上原有的网站业务，脚本不会强行覆盖您的 Nginx 配置。您可以：
- 直接复制脚本在终端里为您生成的 Nginx 反代配置片段，保存到 `/etc/nginx/conf.d/`，然后执行 `nginx -t && systemctl reload nginx` 与 `certbot --nginx -d 您的域名`；
- 或者先在安装时跳过域名，使用 `IP:端口` 访问。

### 4. 如何彻底卸载某个项目？
再次运行 `bash /opt/apibox/install.sh`，选择对应项目进入二级菜单，按 `6` 选择「卸载服务」。脚本会自动停止容器、清理对应域名的反代配置，并询问您是否删除数据目录（默认保留，防止误删数据）。

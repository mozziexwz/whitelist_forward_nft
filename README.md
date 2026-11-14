# whitelist_forward_nft

懒人一键脚本：基于 nftables 的 **IP 白名单防火墙 + 端口转发（TCP+UDP）**，适合用 VPS 做中转。

当前分支为 **v2.1.0 开发版本**，包含下述 IPv6 / 内核跨族转发；已发布的 v2.0.0 仍只支持 IPv4→IPv4。新增功能请使用当前分支检出的 `nft.sh`。

## 功能

- **白名单**：启用后只有白名单里的 IP / 网段（支持 IPv4、IPv6、CIDR）能访问本机和转发端口
- **端口转发**：单端口或端口段，TCP+UDP 同时转发；本地端口段和目标端口段可以不同，按顺序一一对应
- **规则生效与恢复**：nft 规则在单个事务中加载。跨族转发还涉及 Jool、namespace 和路由，切换时先封闭转换路径，失败时恢复配置；重建转换实例可能中断已有连接
- **防失联**
  - 应用规则前检查当前 SSH 来源 IP 是否在白名单内，不在会提示先加入
  - 修改白名单后需要在 60 秒内确认，超时（包括 SSH 断开）自动回滚
  - 加载前先启动独立的回滚保护；保护任务无法启动时取消应用
  - 拒绝把 SSH 端口转发出去，导入和重新应用配置也会检查
- **不影响其他规则**：只管理自己的 `inet unified` 表，不会删除系统或其他程序的 nftables 表；转发只对发往本机的流量生效，不会劫持本机或容器访问外网的流量
- 交互菜单和命令行两种用法

| 入站 → 目标 | 后端 | 额外条件 |
|---|---|---|
| IPv4 → IPv4 | nft DNAT / masquerade | IPv4 可达 |
| IPv6 → IPv6 | nft IPv6 DNAT / masquerade | IPv6 可达 |
| IPv6 → IPv4 | nft + Jool Stateful NAT64 | 匹配内核的 Jool 模块、两族网络 |
| IPv4 → IPv6 | nft + Jool 静态 BIB | 匹配内核的 Jool 模块、两族网络 |

四个方向均同时提供 TCP/UDP，支持单端口、同号和异号端口段的一一对应。跨族业务流量由内核处理，启动恢复使用执行完即退出的 systemd oneshot；不使用 GOST、NGINX、Realm 或其他常驻用户态中继。

## 系统要求

- Linux 内核 ≥ 5.2（inet 表的 NAT 需要）
- nftables：`apt install nftables`（Debian/Ubuntu）或 `dnf install nftables`（RHEL 系）
- bash ≥ 4、root 权限，`flock`（util-linux）；IPv6 需要 iproute2，跨族另需 util-linux 的 `nsenter`
- 使用跨族规则还需要 **版本匹配的 Jool 4.1.15 或更新的 4.1 系列工具和内核模块**、namespace/veth 和两族 forwarding 权限，开机恢复需要 systemd
- VPS 必须具备入口族可达地址及通往目标族的地址和路由；受限容器 VPS 可能无法加载模块。同族规则不需要安装 Jool

跨族转发首次使用前，在 VPS 上运行：

```bash
sudo bash nft.sh install-jool
bash nft.sh check-jool
```

也可在菜单选择 **13 安装跨族转发依赖**、**14 检查跨族转发依赖**。普通 `apply` 不会自动安装系统软件；缺少依赖时会打印这两个命令。安装成功后重新添加之前失败的转发，或重新应用已有配置；失败的添加操作已恢复原配置，需重新添加。

安装器支持 Debian/Ubuntu，以及提供 `dkms` 的 RHEL 系软件源（Rocky/AlmaLinux 等通常需先配置 EPEL）。它安装**当前运行内核**的 headers/devel 和构建依赖，下载 [Jool 4.1.15 官方源码](https://github.com/NICMx/Jool/releases/tag/v4.1.15)，核对固定 SHA256，编译工具到 `/usr/local`，通过 DKMS 安装并实际加载模块。不会升级/重启内核，也不启用通用 `jool.service` 或同步守护进程；安装操作不修改本项目防火墙和转发配置，已安装的构建依赖不随规则回滚卸载。源码构建使用本机架构，工具与模块均须编译成功。

已有版本匹配且符合要求的 Jool 时直接复用；已有其他版本的工具、磁盘模块或已加载模块时停止并提示维护升级，避免覆盖软件包或卸载正在使用的转换模块。发行版内置的旧版本可能不足要求；4.1.13 未通过本项目低 MTU UDP 验收，因此跨族预检会拒绝低于 4.1.15 的版本。手动安装也可使用官方匹配的 `jool-dkms` / `jool-tools` 包。

如安装失败，运行 `bash nft.sh check-jool` 获取具体缺项。缺少当前内核 headers/devel 时请修复软件源或自行安排更新内核后再试；受限容器、模块签名不被信任或内核不兼容时，DKMS 构建或模块加载仍会失败，安装器会保留实际错误并停止。其他发行版按 [Jool 官方安装说明](https://www.jool.mx/en/install.html)操作。

Debian **11 / 12 / 13** 使用同一安装入口，按 `uname -r` 匹配当前运行内核，不固定 ABI 尾号。已安装且版本匹配的 headers 即使不在镜像中，也可继续复用。安装器先刷新 APT 索引并检查精确包的候选版本；旧内核 headers 已从源中移除时，在安装构建依赖之前停止，打印同类型内核元包和重启步骤。

例如运行 `6.1.0-42-cloud-amd64` 而源中缺少对应 headers 时，由你自行安排：

```bash
sudo apt-get update
sudo apt-get install --no-install-recommends --no-remove linux-image-cloud-amd64 linux-headers-cloud-amd64
sudo reboot
# 重新连接后确认已经进入新内核，再安装 Jool
uname -r
sudo bash nft.sh install-jool
```

普通 `-amd64` 内核对应 `linux-image-amd64` / `linux-headers-amd64`；`cloud-amd64` 保持 cloud 类型。[Debian 内核元包](https://www.debian.org/releases/bookworm/amd64/release-notes/ch-upgrading.en.html#kernel-metapackage)跟踪本机软件源中的内核与模块。仅安装最新 headers 不能给仍在运行的旧内核构建模块；重启后内核若没变，需检查 VPS 面板或引导器的内核选择。脚本只打印建议，不自动升级内核、重启或修改软件源。

必须确认 DKMS 为**当前运行内核**成功构建，工具、磁盘模块和已加载模块版本一致；不需要启用发行版的通用 `jool.service`。本项目只创建自己的转换实例。其他发行版需按 [Jool 官方说明](https://www.jool.mx/en/documentation.html)准备适配模块，不能仅凭内核 ≥ 5.2 判断跨族功能可用。内核升级后也需确认模块重建成功。

## 安装与运行

测试本分支新增 IPv6 功能：

```bash
curl -fL https://raw.githubusercontent.com/mozziexwz/whitelist_forward_nft/codex/ipv6-kernel-forwarding/nft.sh -o nft.sh
sudo bash nft.sh
```

快速运行（main 分支，尚无本分支新增功能）：

```bash
curl -fsSLO https://raw.githubusercontent.com/mozziexwz/whitelist_forward_nft/main/nft.sh && bash nft.sh
```

推荐：下载 [v2.0.0 正式版](https://github.com/mozziexwz/whitelist_forward_nft/releases/tag/v2.0.0)，核对随版本发布的 SHA256 后再运行：

```bash
curl -fsSLO https://github.com/mozziexwz/whitelist_forward_nft/releases/download/v2.0.0/nft.sh
curl -fsSLO https://github.com/mozziexwz/whitelist_forward_nft/releases/download/v2.0.0/SHA256SUMS
sha256sum -c SHA256SUMS && sudo bash nft.sh
```

脚本修改规则时需要 root 身份；普通用户使用 `sudo bash nft.sh`（脚本能在 sudo 下正确识别你的 SSH 来源 IP）。下文的命令同理。
`help`、`version`、`check-jool`、`print-rules` 和 `print-plan` 不主动修改系统。预览不要求安装 nftables/Jool，但需要能够读取声明及部署配置；系统部署目录仅 root 可访问时，请用 `sudo` 预览。

首次运行会检测你的 SSH 来源 IP 并建议加入白名单。**白名单默认启用**，请务必先把自己的 IP 加进去。

## 命令行用法

```text
nft.sh                                     进入交互菜单
nft.sh status                              查看白名单、转发和系统状态
nft.sh apply                               按配置文件重新应用全部规则
nft.sh add-ip <IP/CIDR>                    添加白名单（如 1.2.3.4、1.2.3.0/24、2001:db8::/32）
nft.sh del-ip <IP/CIDR>                    删除白名单
nft.sh whitelist on|off                    启用 / 关闭白名单
nft.sh add-forward [--listen-family ipv4|ipv6] <本地端口> <目标IP> <目标端口>
                                           添加 TCP+UDP 转发，端口可写成段，如 10000-10010
nft.sh del-forward [--listen-family ipv4|ipv6] <本地端口>
nft.sh ip-forward                          开启 IPv4 转发
nft.sh install-jool                        安装并验证跨族依赖，不应用防火墙
nft.sh check-jool                          只读检查 Jool 工具、当前内核和模块
nft.sh print-rules                         只打印将要应用的 nftables 规则，不做任何修改
nft.sh print-plan                          预览 nft、Jool 配置及环境要求
```

例：把本机 10000-10010 转发到 `203.0.113.10` 的 20000-20010（10000→20000、10001→20001……）：

```bash
bash nft.sh add-forward 10000-10010 203.0.113.10 20000-20010
```

三个新增方向的示例（地址需替换为实际可达目标）：

```bash
# IPv6 → IPv6
bash nft.sh add-forward --listen-family ipv6 10000-10002 2001:db8:2::10 20000-20002
# IPv6 → IPv4
bash nft.sh add-forward --listen-family ipv6 11000 203.0.113.10 8080
# IPv4 → IPv6
bash nft.sh add-forward --listen-family ipv4 12000 2001:db8:2::10 8080
bash nft.sh del-forward --listen-family ipv6 11000
```

入口族默认 `ipv4`，`--listen-family` 表示匹配的报文地址族，不创建用户态监听进程。IPv6 目标使用不带方括号的全局单播或 ULA 字面量；不接受域名、回环、链路本地、组播、CIDR 和 IPv4-mapped 地址。跨族目标需位于其他可路由主机。

IPv4 与 IPv6 可以复用相同入口端口；同族范围不得重叠。两族都有相同端口时，删除必须指定地址族，或在菜单中按编号删除。

非交互运行（如 cron）时，可能导致失联的操作会被拒绝；确认无误可以设置 `NFT_SH_FORCE=1`。
该变量不能绕过 SSH 端口和转发端口重叠检查。

命令返回非零表示操作未完整成功。若提示“规则已在内存中生效，但持久化失败”，当前规则已经生效，请修复提示中的文件路径或权限后重新运行 `bash nft.sh apply`，以保证重启后仍然有效。

## 被锁在外面怎么办

通过服务商的 VNC / 网页控制台登录，执行：

```bash
echo 0 > /etc/nftables_whitelist_enabled
nft delete table inet unified
```

然后运行 `bash nft.sh`，把自己的 IP 加入白名单后再重新启用。

## 会改动的文件

| 文件 | 用途 |
|---|---|
| `/etc/nftables_whitelist.txt` | 白名单，每行一个 IP 或 CIDR |
| `/etc/port_forward_nft.conf` | 旧三字段或新增 `入口族\|本地端口\|目标IP\|目标端口` |
| `/etc/nftables_whitelist_enabled` | 白名单开关，`1` 启用 / `0` 关闭 |
| `/etc/nftables.d/unified.nft` | 生成的规则，开机时加载 |
| `/etc/nftables.conf`（RHEL 系为 `/etc/sysconfig/nftables.conf`） | 追加一行 `include "/etc/nftables.d/unified.nft"` |
| `/etc/sysctl.d/99-nft-sh-forward.conf` | 按需持久化 IPv4/IPv6 forwarding 和上联接口 RA 设置 |
| `/etc/nft-sh/deployment.conf` | 跨族内部地址池及资源标识，严格按数据读取 |
| `/etc/nft-sh/live.*` | 上次应用的转换声明、部署参数及映射检查记录 |
| `/etc/nft-sh/service.env` | oneshot 使用的配置路径 |
| `/usr/local/libexec/nft-sh/nft.sh` | 开机恢复用的脚本副本 |
| `/etc/systemd/system/nft-sh-translate.service` | 内核转换恢复单元，执行后退出 |

另外会执行 `systemctl enable nftables`，保证重启后自动加载规则。

旧三字段配置始终表示 IPv4→IPv4；新增规则使用 `入口族|本地端口|目标IP|目标端口`。导入导出兼容旧备份，并保存经过校验的部署参数；不包含模块、二进制或动态会话。退回 v2.0.0 前需要撤销跨族资源并恢复旧格式配置。

首次使用跨族功能时，可通过环境变量指定未冲突的内部资源，随后保存到部署文件：

```bash
sudo env NFT_SH_XLATE_ID=nftsh NFT_SH_XLATE_V4=198.18.241 \
  NFT_SH_XLATE_V6=fd73:6866:7400 bash nft.sh apply
```

IPv4 参数是内部 `/24` 的前三段，允许私网和 `198.18.0.0/15` 测试网段；IPv6 参数是 ULA `/48` 的前三组。默认值如上。已有部署文件时以文件为准；变更参数前先删除全部跨族规则，再修改该文件。脚本检查与本机、Docker、VPN 路由的冲突，不接管其他 Jool 实例。

目标默认看到 VPS 的出站地址，脚本不承诺保留客户端源 IP。白名单在宿主机进入转换器前按原始来源匹配；直接访问内部转换地址默认拒绝。Docker/firewalld 等已有转发策略仍然生效，若其阻止该路径，需由管理员按自己的策略允许受管接口/端点；脚本不会自动修改这些程序的规则。

## 卸载

```bash
bash nft.sh        # 菜单 10 → 3：删除本脚本的防火墙表、持久化文件和配置
rm -f /etc/nftables_whitelist.txt /etc/port_forward_nft.conf /etc/nftables_whitelist_enabled
rm -f /etc/sysctl.d/99-nft-sh-forward.conf   # 不再需要本脚本持久化转发设置时
```

菜单清除全部会撤销本项目 Jool 实例、veth、路由、oneshot 及生成文件；不会卸载共享 Jool 模块，也不会强行关闭其他程序使用的 forwarding。删除最后一条跨族规则时停止转换资源，其余同族规则继续工作。

## 常见问题

- **Docker 容器访问不了宿主机上的服务？** 白名单启用时，容器发往宿主机的连接同样要经过白名单，把容器网段加入白名单即可，例如 `bash nft.sh add-ip 172.16.0.0/12`。容器访问外网不受影响；Docker 映射出来的端口同样受白名单保护。
- **系统里还有其他 nftables 表？** `nft.sh status` 会列出它们。那些表里的规则会和本脚本同时生效，本脚本不会修改它们。
- **公网 IP 经常变化？** 可以把运营商的整个网段加入白名单，例如 `1.2.3.0/24`。
- **从旧版本升级？** 旧三字段规则继续有效，替换脚本后在菜单里选择 8 重新应用规则。新增 IPv6 条目使用四字段，降级前需撤销跨族资源并恢复旧配置。旧版可能删除 `inet filter` 表，本版本只清理项目自己的表。

## 开发与测试

- `bash tests/unit_test.sh`：纯 bash 单元测试，不需要 root，Windows 的 Git Bash 也能运行
- `sudo bash tests/jool_install_test.sh`：34 项隔离依赖测试；验证缺项、版本冲突、下载/校验/DKMS/加载失败、部分/重复安装，以及 Debian 旧 headers 退役、已安装 headers ABI 校验与复用和内核类型建议，不安装系统软件
- `tests/debian_build_test.sh`：仅用于一次性 CI 容器；Debian 11/12/13 原生依赖和工具、cloud/普通两类内核 headers + DKMS 模块编译与版本检查，并用各版 nftables 检查四方向规则；不加载模块，不证明容器宿主之外的实际内核数据路径
- `sudo bash tests/netns_test.sh`：在隔离的 network namespace 里真实加载规则，测试转发和白名单；不改动宿主机的防火墙、`/etc` 和 systemd 服务
- `sudo bash tests/kernel_netns_test.sh`：需已安装匹配的 Jool 工具/模块，在隔离 network/mount namespace 中验证四方向 TCP/UDP、端口段、重复目标、白名单、绕过路径、大包及实例故障恢复
- `sudo bash tests/kernel_netns_test.sh --same-ports`：额外验证四方向同号端口段保持端口
- `shellcheck -S warning nft.sh tests/*.sh scripts/*.sh`：与 CI 相同的静态检查
- `bash scripts/package_release.sh`：按脚本版本生成 `dist/v2.1.0/nft.sh` 和 `SHA256SUMS`，并校验版本号、LF 换行和产物哈希；不自动发布
- GitHub Actions 会对每次提交运行 ShellCheck 和上述测试

测试覆盖 TCP/UDP、不同端口段的一一映射、IPv4/IPv6 白名单、普通路由流量不被劫持、持久化失败、安全导入、确认/拒绝/超时回滚，以及终止前台进程后由后台恢复真实规则。每次集成测试使用独立名称的网络命名空间，创建失败会立即停止并清理已创建的资源。

以下验收只用于一次性测试机，会临时加载宿主机规则或改变真实服务状态，执行前会拒绝覆盖已有的本脚本防火墙表：

- `sudo bash tests/systemd_test.sh`：真实 systemd timer 的精度、前台退出后回滚、确认后保留和快照清理
- `sudo bash tests/kernel_systemd_test.sh`：需要 Jool；强制终止首次自定义部署，验证 systemd 在未继承 shell 环境时恢复正确的内核资源与文件
- `sudo bash tests/coexistence_test.sh`：需要 Docker 和 `wireguard-tools`；验证真实容器映射、容器出站和两个 WireGuard 对等端，退出时清理测试资源
- `tests/reboot_test.sh prepare|verify|cleanup <持久化状态目录>`：真实重启前后验收；操作方法和已经通过的环境见 [验收记录](docs/VALIDATION.md)
- `tests/kernel_reboot_test.sh prepare|verify|cleanup <持久化状态目录>`：四方向跨族启动恢复，配合独立 VPS 上的 `tests/kernel_public_client.py`；操作方法、版本和本分支实测结果见 [IPv6 验收记录](docs/IPV6_VALIDATION.md)

前台确认等待 60 秒；独立后台保护约在 65 秒后尝试恢复。systemd 定时器使用 1 秒精度，SELinux 开启时通过标准输入读取回滚规则，无需关闭 SELinux。

## 更新说明

### v2.1.0（功能分支，待合并发布）

- 新增 IPv6→IPv6、IPv6→IPv4、IPv4→IPv6 的 TCP/UDP 和端口段映射
- 同族使用 nft，跨族使用专用 namespace 中的 Jool 内核转换，无常驻用户态中继
- 新增入口族选择、完整计划预览、严格部署参数、实例/池/BIB/路由检查及 oneshot 启动恢复
- 扩展白名单隔离、并发锁、跨组件快照和断连回滚；IPv6 forwarding 保留上联 RA
- 新增固定 Jool CI、真实双栈公网和重启验收；重建实例会影响既有连接，未承诺容量或吞吐
- 补齐 `install-jool` / `check-jool` 和菜单依赖安装入口；CI 使用与用户相同的官方源码 + DKMS 安装流程

### v2.0.0（2026-11-14，首次正式发布）

- 修复 systemd 默认定时精度导致的回滚延迟，完成后自动回收临时单元
- 修复 RHEL / Rocky Linux 开启 SELinux 时 nft 无法读取临时回滚文件的问题
- 修复持久化写入失败仍报告成功的问题；使用临时文件替换规则，替换失败保留原文件
- 对导入和重新应用的转发统一检查 SSH 端口、重叠范围和目标地址；拒绝多余的配置字段
- 导入时只流式读取唯一的普通文件，不解压归档路径或链接；白名单开关无效时取消整次导入
- 开启 IPv4 转发失败时停止添加转发；保存快照失败时停止修改配置
- 应用前启动独立回滚任务，避免确认与后台回滚同时恢复；升级回滚也恢复旧版表，隔离网络中的回滚保留原命名空间
- `print-rules` 改为完全只读；补充故障路径、IPv6 和前台进程退出后的真实回滚测试

- 修复：转发规则会劫持本机发出的流量（如转发 443 后 VPS 上的 apt、curl 都被转走），以及容器 / VPN 客户端访问外网的流量
- 修复：本地端口段与目标端口段不同时，所有连接都被转到目标段的第一个端口
- 修复：每次应用规则都会删除 `inet filter` 表；“清除全部”会删除 `/etc/nftables.d/` 下所有文件和相关 include 行
- 修复：导入配置会把压缩包里的任意文件解压到 `/`
- 修复：白名单启用时 Docker 容器、WireGuard 等转发流量被全部丢弃
- 修复：“活动转发”数量显示错误；输入校验不严（无效 IP、端口越界、八进制端口、目标 IP 不校验等）
- 改进：规则原子加载；应用失败时配置自动恢复；防失联检查与超时自动回滚
- 改进：IPv4 转发写入 `/etc/sysctl.d/`（Debian 13 起不再读取 `/etc/sysctl.conf`），添加转发时自动开启
- 新增：命令行模式、`print-rules` 预览、单元测试与集成测试、CI

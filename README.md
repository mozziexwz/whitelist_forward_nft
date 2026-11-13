# whitelist_forward_nft

懒人一键脚本：基于 nftables 的 **IP 白名单防火墙 + 端口转发（TCP+UDP）**，适合用 VPS 做中转。

## 功能

- **白名单**：启用后只有白名单里的 IP / 网段（支持 IPv4、IPv6、CIDR）能访问本机和转发端口
- **端口转发**：单端口或端口段，TCP+UDP 同时转发；本地端口段和目标端口段可以不同，按顺序一一对应
- **原子生效**：所有规则一次性加载，失败时保持原样，不会出现“只生效一半”
- **防失联**
  - 应用规则前检查当前 SSH 来源 IP 是否在白名单内，不在会提示先加入
  - 修改白名单后需要在 60 秒内确认，超时（包括 SSH 断开）自动回滚
  - 拒绝把 SSH 端口转发出去
- **不影响其他规则**：只管理自己的 `inet unified` 表，不会删除系统或其他程序的 nftables 表；转发只对发往本机的流量生效，不会劫持本机或容器访问外网的流量
- 交互菜单和命令行两种用法

## 系统要求

- Linux 内核 ≥ 5.2（inet 表的 NAT 需要）
- nftables：`apt install nftables`（Debian/Ubuntu）或 `dnf install nftables`（RHEL 系）
- bash，root 权限
- 端口转发只支持 IPv4 目标

## 安装与运行

快速运行（main 分支最新版）：

```bash
curl -fsSLO https://raw.githubusercontent.com/mozziexwz/whitelist_forward_nft/main/nft.sh && bash nft.sh
```

推荐：下载固定版本，核对 SHA256 后再运行（把 `v2.0.0` 换成 Releases 页面上的版本）：

```bash
curl -fsSLO https://raw.githubusercontent.com/mozziexwz/whitelist_forward_nft/v2.0.0/nft.sh
sha256sum nft.sh   # 与 Releases 页面公布的值比对一致后再运行
bash nft.sh
```

以上命令需要 root 身份；普通用户请把 `bash nft.sh` 换成 `sudo bash nft.sh`（脚本能在 sudo 下正确识别你的 SSH 来源 IP）。下文的命令同理。

首次运行会检测你的 SSH 来源 IP 并建议加入白名单。**白名单默认启用**，请务必先把自己的 IP 加进去。

## 命令行用法

```text
nft.sh                                     进入交互菜单
nft.sh status                              查看白名单、转发和系统状态
nft.sh apply                               按配置文件重新应用全部规则
nft.sh add-ip <IP/CIDR>                    添加白名单（如 1.2.3.4、1.2.3.0/24、2001:db8::/32）
nft.sh del-ip <IP/CIDR>                    删除白名单
nft.sh whitelist on|off                    启用 / 关闭白名单
nft.sh add-forward <本地端口> <目标IP> <目标端口>
                                           添加 TCP+UDP 转发，端口可写成段，如 10000-10010
nft.sh del-forward <本地端口>              删除转发（按本地端口或端口段）
nft.sh ip-forward                          开启 IPv4 转发
nft.sh print-rules                         只打印将要应用的 nftables 规则，不做任何修改
```

例：把本机 10000-10010 转发到 `203.0.113.10` 的 20000-20010（10000→20000、10001→20001……）：

```bash
bash nft.sh add-forward 10000-10010 203.0.113.10 20000-20010
```

非交互运行（如 cron）时，可能导致失联的操作会被拒绝；确认无误可以设置 `NFT_SH_FORCE=1`。

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
| `/etc/port_forward_nft.conf` | 转发规则，每行 `本地端口\|目标IP\|目标端口` |
| `/etc/nftables_whitelist_enabled` | 白名单开关，`1` 启用 / `0` 关闭 |
| `/etc/nftables.d/unified.nft` | 生成的规则，开机时加载 |
| `/etc/nftables.conf`（RHEL 系为 `/etc/sysconfig/nftables.conf`） | 追加一行 `include "/etc/nftables.d/unified.nft"` |
| `/etc/sysctl.d/99-nft-sh-forward.conf` | 开启 IPv4 转发（重启后仍生效） |

另外会执行 `systemctl enable nftables`，保证重启后自动加载规则。

## 卸载

```bash
bash nft.sh        # 菜单 10 → 3：删除本脚本的防火墙表、持久化文件和配置
rm -f /etc/nftables_whitelist.txt /etc/port_forward_nft.conf /etc/nftables_whitelist_enabled
rm -f /etc/sysctl.d/99-nft-sh-forward.conf   # 不再需要 IPv4 转发时
```

## 常见问题

- **Docker 容器访问不了宿主机上的服务？** 白名单启用时，容器发往宿主机的连接同样要经过白名单，把容器网段加入白名单即可，例如 `bash nft.sh add-ip 172.16.0.0/12`。容器访问外网不受影响；Docker 映射出来的端口同样受白名单保护。
- **系统里还有其他 nftables 表？** `nft.sh status` 会列出它们。那些表里的规则会和本脚本同时生效，本脚本不会修改它们。
- **公网 IP 经常变化？** 可以把运营商的整个网段加入白名单，例如 `1.2.3.0/24`。
- **从旧版本升级？** 配置文件格式不变，替换脚本后在菜单里选择 8 重新应用规则即可，旧版本创建的表会被自动清理。注意：旧版本每次应用规则都会删除 `inet filter` 表，新版本不再这样做。

## 开发与测试

- `bash tests/unit_test.sh`：纯 bash 单元测试，不需要 root，Windows 的 Git Bash 也能运行
- `sudo bash tests/netns_test.sh`：在隔离的 network namespace 里真实加载规则，测试转发和白名单；不改动宿主机的防火墙、`/etc` 和 systemd 服务
- GitHub Actions 会对每次提交运行 ShellCheck 和上述测试

## 更新说明

### v2.0.0

- 修复：转发规则会劫持本机发出的流量（如转发 443 后 VPS 上的 apt、curl 都被转走），以及容器 / VPN 客户端访问外网的流量
- 修复：本地端口段与目标端口段不同时，所有连接都被转到目标段的第一个端口
- 修复：每次应用规则都会删除 `inet filter` 表；“清除全部”会删除 `/etc/nftables.d/` 下所有文件和相关 include 行
- 修复：导入配置会把压缩包里的任意文件解压到 `/`
- 修复：白名单启用时 Docker 容器、WireGuard 等转发流量被全部丢弃
- 修复：“活动转发”数量显示错误；输入校验不严（无效 IP、端口越界、八进制端口、目标 IP 不校验等）
- 改进：规则原子加载；应用失败时配置自动恢复；防失联检查与超时自动回滚
- 改进：IPv4 转发写入 `/etc/sysctl.d/`（Debian 13 起不再读取 `/etc/sysctl.conf`），添加转发时自动开启
- 新增：命令行模式、`print-rules` 预览、单元测试与集成测试、CI

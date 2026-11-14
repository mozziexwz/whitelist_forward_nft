# v2.0.0 验收记录

日期：2026-11-14。以下为实际执行结果，测试使用的 `nft.sh` SHA256：

```text
e72c4d89de785aa1b84918b42176cf8a5862a443fb8ce0db0ce07871b043aac3
```

| 环境 | 实际验证 |
|---|---|
| Windows / Git Bash | 240 项单元测试通过 |
| Debian 12，Linux 6.1，nftables 1.0.6，systemd 252 | 243 项单元测试、76 项 netns 集成测试、12 项真实 systemd 测试通过 |
| Debian 13，Linux 6.12，nftables 1.1.3 | 真实 systemd 12 项、Docker/WireGuard 联测 13 项及 VPS 真实重启验收通过 |
| Rocky Linux 9.8，Linux 5.14，nftables 1.0.9，SELinux Enforcing | 独立内核虚拟机中，243 项单元测试、76 项 netns 测试、12 项 systemd 测试及真实重启验收通过 |
| GitHub Actions / Ubuntu | 每次分支推送执行静态检查、单元、netns、systemd、Docker/WireGuard 测试，全部成功后校验发布包 |

Rocky 使用[官方固定版本云镜像](https://download.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud-Base-9.8-20260525.0.x86_64.qcow2)，下载后核对官方 SHA256；虚拟机有自己的内核、systemd 和 SELinux。此项结果不代表所有 RHEL 衍生发行版都已实测。

## 真实重启

Debian VPS 和 Rocky 虚拟机分别完成 `prepare -> reboot -> verify -> cleanup`：

- 重启前后 `boot_id` 不同，重启后成功建立新的 SSH 连接。
- nftables 服务开机启动并处于 active，生成规则的 SHA256 保持一致。
- Debian 读取 `/etc/nftables.conf`，Rocky 读取 `/etc/sysconfig/nftables.conf`；两者 include 均正常。
- `net.ipv4.ip_forward=1` 在重启后恢复。
- 经本机生成的 DNAT 规则访问另一台测试机：TCP HTTP 响应和 UDP 回显均正常。
- 验收后恢复原配置、nftables 服务状态及 IPv4 转发设置；Debian 原有 SSH、fail2ban 和应用服务正常。

可重复操作方式（只用于可重启、可通过控制台恢复的一次性测试机；将示例地址替换为回显机 IPv4）：

```bash
# 在另一台可达的测试机运行；TCP 46888、UDP 46889 需可达
python3 tests/echo_server.py --bind 0.0.0.0

# 待重启的测试机
sudo env NFT_TEST_TARGET_IP=203.0.113.10 bash tests/reboot_test.sh prepare /var/tmp/nft-reboot-state
sudo reboot

# 重新通过 SSH 登录后
sudo bash tests/reboot_test.sh verify /var/tmp/nft-reboot-state
sudo bash tests/reboot_test.sh cleanup /var/tmp/nft-reboot-state
```

状态目录包含恢复备份，请在 cleanup 成功后再删除。`prepare` 会拒绝覆盖已有的本脚本配置和表，测试期间放行现有访问，白名单拒绝行为由隔离网络和共存测试覆盖。

## systemd 和 SELinux

`tests/systemd_test.sh` 实际调用 systemd：终止等待确认的前台进程后，timer 恢复完整表和配置；确认 `y` 后，timer 不再恢复旧状态，并清理快照。

验收发现并修复了两个问题：

1. systemd 的 [AccuracySec 默认值为 1 分钟](https://www.freedesktop.org/software/systemd/man/latest/systemd.timer.html#AccuracySec=)，会延迟后台保护；现在显式设为 1 秒，并在完成后回收临时单元。
2. Rocky 的 SELinux 禁止 nft 进程直接读取 `user_tmp_t` 临时文件；改为 shell 读取并通过管道交给 `nft -f -`，同时使用 pipefail 检测读取失败。验证期间始终保持 SELinux Enforcing。

## Docker 和 WireGuard

`tests/coexistence_test.sh` 使用真实 Docker 网桥、容器 TCP/UDP 服务和两个真实 WireGuard 对等端：

实测版本：Docker 29.8.1、iptables 1.8.11（nf_tables 后端）、wireguard-tools 1.0.20210914。

- Docker 发布的 TCP/UDP 端口：白名单允许，非白名单拦截。
- 本脚本 TCP/UDP DNAT 到容器：正常。
- 容器访问外部同号端口：返回外部目标的响应，未被本机 DNAT 劫持。
- WireGuard 白名单客户端可使用容器映射和 UDP 转发；非白名单客户端被映射端口拦截。
- 非白名单 WireGuard 客户端的普通路由流量正常，两个对等端均有真实握手记录。

Docker 默认 FORWARD 策略可能拦截 VPN 路由，夹具只为自己的 WG 接口临时添加两条带唯一标记的 DOCKER-USER 规则，退出时删除。容器使用固定 Python 镜像 digest；测试结束删除容器、网桥、网络命名空间、WG 接口和测试密钥，并恢复本脚本规则。

## 发布包

`bash scripts/package_release.sh` 生成 `nft.sh` 和 `SHA256SUMS`，检查脚本语法、LF 换行、版本标签匹配及 SHA256。正式 Release 附带这两个文件，安装前执行 `sha256sum -c SHA256SUMS`。

当前端口转发目标支持 IPv4；IPv6 和域名作为转发目标未包含在此版本验收范围内。

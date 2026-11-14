# v2.1.0 分支 IPv6 验收记录

日期：2026-11-14。分支：`codex/ipv6-kernel-forwarding`。本次交付包含 IPv6→IPv6、IPv6→IPv4、IPv4→IPv6；旧 IPv4→IPv4 继续保留。版本为开发版，正式 v2.0.0 的标签和附件未替换。

## 实现前后

| 项目 | v2.0.0 | 本分支 |
|---|---|---|
| 地址族 | IPv4→IPv4 | 四个方向均支持 TCP/UDP 和等长端口段 |
| 同族后端 | nft IPv4 DNAT | nft IPv4/IPv6 DNAT，按项目目标限制 masquerade |
| 跨族后端 | 不支持 | 两个隔离 namespace 中的 Jool Stateful NAT64，动态池 / 静态 BIB 分开 |
| 重复 IPv6 目标 | 不支持 | 每条 IPv4 入口分配独立虚拟 IPv6 端点，避免 BIB 唯一性冲突 |
| 配置 | 三字段 | 兼容三字段；新四字段显式指定入口族 |
| 回滚 | nft 与声明配置 | 额外覆盖转换资源、映射、部署参数、持久化文件、受管 sysctl、oneshot 状态 |
| 并发 | 无跨组件事务保护 | 文件锁；断连后仍阻止新事务被旧回滚覆盖 |
| 启动恢复 | nftables 文件 | 增加 `Type=oneshot` 转换恢复，完成后 `MainPID=0` |

跨族数据路径只经过内核。测试确认命令结束后转换 namespace 没有业务进程，宿主没有新增业务监听 socket，四方向连接仍正常。目标看到 VPS 对应地址族的出站地址；不插入 PROXY protocol，不保留真实客户端源 IP。

## 已执行的核心验收

| 环境 / 工具 | 结果 |
|---|---|
| Debian 13.7，Linux `6.12.107+deb13-cloud-amd64`，Jool 4.1.15.0 | 84 项真实内核隔离测试通过；包括并发、故障、回滚和低 MTU |
| Debian 13 / Jool 4.1.15 | 285 项单元、76 项原 netns 回归通过；5 项版本校验新增用例随后由最终 CI 执行 |
| Debian 13 / 真实 systemd | 12 项 timer 测试通过 |
| Debian 13 / Docker、WireGuard | 原有 13 项真实共存测试通过 |
| 两台独立双栈公网 VPS | 重启前 8 项、真实重启后 8 项 TCP/UDP 全通过，分别核对入口族、目标族、响应内容及客户端收到的端点 |
| Windows / Git Bash | 最终 283 项单元通过 |

Debian 12 / Linux 6.1 和独立 Rocky 9.8 / SELinux Enforcing 的扩展验收正在执行，最终结果在交付前更新。本记录不把未运行的矩阵计为通过。

隔离测试在 `unshare --mount --net` 内运行，并用独立 `/run/netns` 挂载管理子空间；不会把测试 namespace 句柄或 nft 表留在宿主。后端不设置默认路由，只有正确的 SNAT 回程才能完成测试。

`tests/kernel_netns_test.sh` 覆盖：

- 四方向 TCP/UDP、半关闭、单端口、同号/异号端口段、两族同入口端口、多个入口指向同一 IPv6 目标。
- 四个并发 UDP 客户端使用相同源端口访问多个入口，按响应内容及原始入口端口检查不串会话；每轮保持 socket 连续收发。
- 8 KiB、60 KiB UDP；MTU 1280 下跨族 TCP/UDP 的 8 KiB 数据及分片回程。
- IPv4/IPv6 白名单允许与拒绝；关闭白名单后仍拒绝直接访问合成 IPv6、内部 IPv4 池。
- Jool 暂停、静态 BIB 删除、动态池缩减耗尽、转换路由删除均不能变成开放转换；`apply` 恢复实例、池、BIB 和路由。
- 第二个实例初始化失败后恢复旧声明及两方向流量；等待确认时终止前台进程，由独立任务恢复实际转换路径。
- 旧回滚完成前拒绝新事务；删除最后一条跨族规则后撤销转换器，同族规则继续工作。

## 版本选择及已发现的兼容问题

Jool **4.1.13.0** 在 Linux 6.12 的普通四方向 TCP/UDP、端口段和回滚用例通过，但 MTU 1280 下大 UDP 在两个跨族方向超时。在不使用本项目生成器的最小独立转换路径中也重现了失败。因此该版本不列为受支持后端；预检要求 **Jool 4.1.15 或更新的 4.1 系列**，同时核对工具、磁盘模块和已加载模块版本。不同版本组合不会自动降级到用户态中继。

Debian 12 的 nftables 1.0.6 对 `ct original proto-dst` 要求先建立协议类型；规则生成已将 TCP/UDP 匹配放在该表达式之前。

固定上游 4.1.15 文件及 SHA256：

| 文件 | SHA256 |
|---|---|
| `jool-dkms_4.1.15-1_all.deb` | `6a6f3bdc9c34c8b45f3404e5b926c1e2dfc2696afe3955aaed91c61c939d6294` |
| `jool-tools_4.1.15-1_amd64.deb` | `ad4707e00db184303693fb1ec8161137ba9c1d37b252a74fc805136a88750479` |
| `jool-4.1.15.tar.gz` | `51604bcf6a9f7fbb9080876102d05da01dc91d8c73cd5828fd73d5895643f8cd` |

下载来源：[Jool 官方发行页](https://github.com/NICMx/Jool/releases/tag/v4.1.15)。CI 在一次性 Ubuntu runner 上校验 DEB、构建当前内核模块并执行实际数据测试；不能加载模块时整个 job 失败，不以跳过计为成功。

4.1.15 的 pool4 重叠检查会警告完整端口池与内核临时端口范围相交。本项目只在新建、专用且没有 TCP/UDP socket 的 namespace 中使用 `--force` 装载池；池地址不绑定网卡，不在宿主 namespace 绕过该检查。

## 真实重启与恢复

已在独立双栈 VPS 执行 `prepare → 外部客户端 → reboot → verify → 外部客户端 → cleanup`。重启前后 `boot_id` 不同；持久化 nft 文件和恢复脚本 SHA256 保持一致；实例、BIB、路由和两族 forwarding 恢复。oneshot 为 `active (exited)`，`MainPID=0`。IPv6 默认路由、Docker 和 fail2ban 保持可用。

首次应用不会启动全局 `nftables.service`，避免其 `flush ruleset` 清除其他程序的活动规则。开机辅助程序仅加载本项目持久化文件；加载或初始化失败时保持受管 veth 关闭。测试为现有 Docker 策略添加的例外均仅限夹具接口和测试端点，清理时删除。

可重复操作方式（仅用于允许真实重启的一次性机器；替换所有示例地址）：

```bash
# 第二台双栈机器，TCP/UDP 使用同一个 46888 端口
python3 tests/echo_server.py --bind 0.0.0.0 --tcp 46888 --udp 46888 --body nft-kernel-v4 --udp-prefix v4: &
python3 tests/echo_server.py --bind :: --tcp 46888 --udp 46888 --body nft-kernel-v6 --udp-prefix v6: &

# 中转 VPS
sudo env NFT_TEST_TARGET4=203.0.113.20 NFT_TEST_TARGET6=2001:db8:2::20 \
  bash tests/kernel_reboot_test.sh prepare /var/tmp/nft-kernel-reboot-acceptance

# 第二台机器，重启前后各执行一次
python3 tests/kernel_public_client.py --relay4 203.0.113.10 --relay6 2001:db8:1::10 \
  --source4 203.0.113.20 --source6 2001:db8:2::20

# 中转 VPS 重启并重新连接后
sudo bash tests/kernel_reboot_test.sh verify /var/tmp/nft-kernel-reboot-acceptance
# 外部客户端再次通过后恢复原配置
sudo bash tests/kernel_reboot_test.sh cleanup /var/tmp/nft-kernel-reboot-acceptance
```

`prepare` 拒绝覆盖已有的受管表和 oneshot。状态目录含原始恢复备份，只有 `cleanup` 成功后才能删除。临时部署的表、实例、veth、路由、服务和监听器已在本次测试后清理；Jool 构建依赖与版本测试日志可保留在测试机。

## 边界与后续扩展验证

本次结果证明所列内核、固定模块和测试拓扑的功能，不构成所有 VPS 的兼容承诺。VPS 需要原生可达的入口族、目标族路由、加载模块和创建 namespace/veth 的权限；跨族目标须位于其他可路由主机。Secure Boot 签名、发行版内核变更、受限容器和其他 Jool 版本需要分别核验；脚本不关闭 SELinux、Secure Boot 或替换宿主内核。

已经覆盖小端口段、固定源端口并发、60 KiB UDP 和池耗尽。尚未把全端口范围、大规模会话、长时间空闲回收、故障注入的每一种 ICMP/扩展头、内核升级重建和持续吞吐/CPU/内存压测列为通过；没有发布容量或性能数值。动态会话保存在内存，重建转换器可能中断已有连接，回滚只恢复配置与新连接能力。

## 开发包

`bash scripts/package_release.sh` 生成 `dist/v2.1.0/nft.sh` 和 `SHA256SUMS`，检查 Bash 语法、版本号、LF 和 SHA256。CI 的打包 job 依赖 ShellCheck、单元、netns、systemd、Jool 和 Docker/WireGuard 六项检查；本分支不创建正式标签或替换 Release。

# 更新日志

本文件记录 opsbox 的所有重要变更。
格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循[语义化版本](https://semver.org/lang/zh-CN/)。

## [1.0.0] - 2025-01-01

首个正式版本：一个零第三方依赖的 Linux 巡检与故障排查工具箱。
单文件入口 + 纯 Bash，`scp` 到任意 Linux 上即可运行，不需要 root、不需要联网。

### 新增 —— 命令行与报告

- 子命令：`check`（默认）、`list`（列出本次全部检查项 id，便于精确静音）、
  `modules`、`version`、`help`。
- 六种输出格式：`text`、`md`、`json`（带 `schema` 版本号）、
  `prom`（node_exporter textfile collector 可直接采集）、`csv`、`oneline`。
- 选项：`-f/--format`、`-o/--output`、`-m/--modules`、`-c/--conf`、
  `-i/--interval`、`--fail-on ok|warn|crit|never`、`--color/--no-color`、
  `-q/--quiet`、`-d/--debug`。
- 退出码对外契约：`0`=全部通过、`1`=存在 WARN、`2`=存在 CRIT、
  `3`=用法错误、`4`=采集失败。
- 输出纪律：stdout 只承载报告本体，所有日志与提示走 stderr，
  因此 `opsbox check -f json > report.json` 永远得到干净的 JSON。
- 配置分层加载：内置默认值 → `/etc/opsbox/opsbox.conf` →
  `<安装目录>/conf/opsbox.conf` → `~/.config/opsbox/opsbox.conf` →
  `--conf` 指定的文件。
- `OB_CFG_DISABLE_CHECKS` 支持按检查项 id 精确静音（如 `disk.inode.root`）。

### 新增 —— 检查模块

一次全量巡检约产出 50~60 条结论，分为 8 个模块；
每条结论都包含**观测值、阈值与可执行的处置建议**。

**system（`sys.*`）—— 系统底座**

- `sys.identity` 主机标识、`sys.uptime` 运行时长（识别崩溃重启循环）、
  `sys.time_sync` 时间同步状态、`sys.reboot_required` 待重启标记。
- `sys.fd_usage` 文件句柄使用率、`sys.pid_usage` PID 用量、
  `sys.oom_events` 近期 OOM Killer 事件。
- `sys.kernel_swappiness`、`sys.kernel_overcommit` 内核内存参数体检。

**cpu（`cpu.*`）—— CPU 与负载**

- `cpu.usage` / `cpu.iowait` / `cpu.steal` 分开判定：算力不足、存储瓶颈、
  宿主机超卖三种根因的处置方向完全不同，不合并成一个数字。
- `cpu.load1` / `cpu.load15` 以「核数的倍数」判定负载，4 核与 64 核共用同一份阈值。
- `cpu.runqueue` 运行队列长度。

**memory（`mem.*`）—— 内存与 Swap**

- `mem.used` 使用率，口径为 `(MemTotal - MemAvailable) / MemTotal`，
  排除可回收 page cache 造成的误判；`mem.available` 可用内存绝对下限。
- `mem.swap` 换页压力、`mem.dirty` 脏页堆积、`mem.commit` 内存承诺比。
- `mem.zombie` 僵尸进程数、`mem.top` 内存占用 Top N。

**disk（`disk.*`）—— 磁盘与 inode**

- `disk.usage.<挂载点>` 容量水位、`disk.inode.<挂载点>` inode 水位：
  逐挂载点独立成项（id 带 slug 后缀），可以单独静音某一个挂载点。
- `disk.readonly` 意外只读挂载（文件系统级故障信号）、
  `disk.io_latency` 平均单次 IO 延迟、`disk.io_throughput` 采样窗口吞吐。
- `disk.big_log` 最大日志文件体积。

**network（`net.*`）—— 网络与连接**

- `net.tcp_total` / `net.timewait` / `net.closewait` / `net.syn_recv`
  连接状态分布，三者分开看：短连接过频、应用忘记 close、SYN 半连接耗尽。
- `net.err_rate.<网卡>` / `net.drop_rate.<网卡>` 以比率判定，
  长期运行的机器不会因累计值误报。
- `net.conntrack` 连接跟踪表使用率、`net.listen_ports` 监听端口清单、
  `net.sensitive_ports` 对全网暴露的敏感端口、`net.default_route` 默认路由缺失。

**service（`svc.*`）—— 服务与进程**

- `svc.systemd` systemd 可用性、`svc.failed.<单元>` 逐个列出失败的单元
  （而不是只给一个汇总数字）、`svc.required.<单元>` 与 `svc.optional.<单元>`
  检查期望服务是否存活。
- `svc.proc_total` 进程总数、`svc.run_queue` 可运行进程规模。

**log（`log.*`）—— 日志与崩溃**

- `log.source` 数据源（journald 或传统日志文件）、`log.errors` 窗口内错误日志量。
- `log.top1..N` 错误聚类：把消息中的数字与 ID 归一化后统计词频，
  直接指出「300 条错误里 287 条是同一个 message」。
- `log.crash_dumps` 崩溃转储数量、`log.biggest` 体积最大的日志文件。

**security（`sec.*`）—— 安全基线**

- `sec.uid0` 除 root 外的 UID 0 账户、`sec.empty_passwd` 空密码账户。
- `sec.ssh_permitroot` / `sec.ssh_passwordauth` / `sec.ssh_port` SSH 暴露面。
- `sec.firewall` 主机防火墙、`sec.mac` SELinux/AppArmor、
  `sec.ip_forward` 内核转发开关。
- `sec.suid` SUID/SGID 文件数（默认关闭：全盘扫描较慢且基线需人工维护）。

### 新增 —— 工程与测试

- `tests/run-tests.sh` 端到端测试套件，不需要 Linux 环境也不需要 root，
  覆盖：脚本语法检查、数值与判定原语的边界、两种场景的端到端结论、
  输出格式完整性、退出码契约、模块选择与检查项静音、
  以及「所有采集路径都指向空目录时不崩溃且仍输出合法 JSON」。
- `tests/fixtures/build.sh` 生成「假操作系统」夹具（`healthy` / `troubled` 两套场景），
  让「内存仅剩几百 MB」「根分区 92%」「根分区变只读」「存在 UID 0 账户」
  这类真实环境难以复现的场景可以在 CI 里稳定测试。
- 采集层全部路径（`OB_CFG_*_ROOT`）与外部命令（`OB_CMD_*`）均可注入。
- 兼容 Bash 3.2+：刻意不使用关联数组、`${var,,}`、`mapfile`，
  CI 中有对应的 grep 断言守住这条约定。
- 三层架构（采集 `lib/collect.sh` / 判定 `lib/checks.sh` / 展示 `lib/report.sh`），
  同一指标在所有输出格式下的判定结果一致。

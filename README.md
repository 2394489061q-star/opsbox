# opsbox

**Linux 服务器巡检与故障排查工具箱。** 一条命令给出结构化的健康报告，把「登录上去一条条敲命令」变成「看一份带处置建议的清单」。

纯 Bash，零第三方依赖，不需要 root，不需要联网，不需要装 Python。`scp` 到任意一台 Linux 上就能跑。

```console
$ opsbox
--------------------------------------------------------------------------
  opsbox v1.0.0  ·  Linux 服务器巡检报告
  主机 web-01  ·  Ubuntu 22.04.3 LTS  ·  内核 5.15.0-91-generic
  架构 x86_64  ·  虚拟化 kvm  ·  容器 no  ·  CPU 4 核
  运行模式 check  ·  耗时 2s  ·  生成于 2025-01-01 12:00:00 +0800
--------------------------------------------------------------------------

【系统信息】
  [OK]   sys.identity               主机标识  (web-01 / Ubuntu 22.04.3 LTS / 5.15.0-91)
  [OK]   sys.time_sync              时间同步状态  (已同步（NTP=yes）)
  ...

【磁盘与 inode】
  [CRIT] disk.usage.root            分区使用率：/  (92%)  [阈值 80% 警告 / 90% 严重]
        ↳ 先定位占用：du -x -h --max-depth=1 <挂载点> | sort -h，再查已删除但未释放的文件（lsof +L1）...
  [OK]   disk.usage.data            分区使用率：/data  (20%)

【日志与崩溃】
  [OK]   log.top1                  高频错误 #1  (40 次 · EXT4-fs error (device sda1): ext4_find_entry:N: inode #N: comm nginx)

--------------------------------------------------------------------------
  汇总：OK 38  ·  WARN 4  ·  CRIT 7  ·  UNKNOWN 1
  结论：存在严重问题，请立即介入   (退出码 2)
--------------------------------------------------------------------------
```

---

## 目录

- [它解决什么问题](#它解决什么问题)
- [设计取舍](#设计取舍)
- [快速开始](#快速开始)
- [输出格式](#输出格式)
- [退出码：可以直接接监控](#退出码可以直接接监控)
- [检查项清单](#检查项清单)
- [配置](#配置)
- [接入监控与定时巡检](#接入监控与定时巡检)
- [项目结构](#项目结构)
- [测试](#测试)
- [兼容性](#兼容性)
- [许可](#许可)

---

## 它解决什么问题

接手一台陌生服务器、或者线上报警说「这台机器不对劲」的时候，运维的实际动作是固定的：敲十几条命令，扫一眼输出，凭经验判断哪一项不对，然后再往下钻。这个过程有三个问题：

1. **慢且不可重复。** 同样的十几条命令每次都要重敲，漏掉一条就可能漏掉根因。
2. **口径不统一。** `free` 的 `used` 列包含了可回收的 page cache，在读过大量文件的机器上会显示 90%+，让人误判内存不足；负载高不高要看核数，但很多人只看绝对值。
3. **没有留下证据。** 排查完就过去了，下次同类问题还得从零开始，也没法做趋势对比。

opsbox 把这三件事变成一次执行：**采集 → 判定 → 出报告**，并且：

- 每个结论都附带**观测值、阈值、可执行的处置建议**，而不是只有一个红色数字；
- 所有阈值集中在一份配置文件里，口径写死在代码中并注明理由；
- 支持 JSON / Markdown / Prometheus 输出，报告可以归档、可以对比、可以直接被监控系统消费。

它不是 `top`/`iostat` 的替代品，也不是漏洞扫描器。它负责**几秒钟内定位到「这是哪一类问题」**，把排查范围从「整台机器」缩小到「两三个具体的下钻方向」，深挖仍然要靠那些经典工具。`docs/故障排查手册.md` 里每个现象都给了后续的手工命令。

## 设计取舍

这些是刻意的选择，不是偷懒：

**为什么用 Bash 而不是 Python/Go。**
目标环境是「一台可能连 Python 都没有、且不允许随便装东西的生产服务器」。Bash + coreutils 是唯一在所有 Linux 上都存在的运行时。代价是没有类型检查和更好的数据结构，所以代码里用严格的三层划分来补偿。

**为什么优先直读 `/proc` 而不是调用外部命令。**
`ss`、`iostat`、`free`、`lsof` 都可能没装，输出格式还会随版本变化，而且都需要 fork 进程。`/proc/stat`、`/proc/meminfo`、`/proc/net/tcp`、`/proc/diskstats` 是内核稳定接口。只有 `df`、`systemctl`、`journalctl` 这几个确实没有 `/proc` 替代的才调外部命令，并且都留了降级路径（例如没有 `ss` 时自己解析 `/proc/net/tcp` 的十六进制地址）。

**为什么分采集 / 判定 / 展示三层。**
「多少算超标」是团队共识，应当只有一个定义处。三层分开之后，同一个指标在终端报告、JSON、Prometheus 里的判定结果必然一致；换输出格式不会改变结论。

**为什么所有根路径都可注入。**
`lib/collect.sh` 里所有路径都来自 `OB_CFG_PROC_ROOT` 之类的变量。这不只是为了测试——它让 opsbox 可以指向一个容器挂载的宿主 `/proc`，也让「构造一台内存只剩 200MB 的机器」这种在真实环境无法复现的场景可以在 CI 里稳定测试。

**为什么阈值判定必须区分「测不到」和「没问题」。**
`UNKNOWN` 是一等公民。采集失败时输出 `UNKNOWN` 并说明缺什么，而不是默默按 `OK` 处理——否则一次权限不足就会让整份报告变成虚假的安心。

## 快速开始

```bash
# 方式一：直接跑，不需要安装
git clone https://github.com/<your-name>/opsbox.git
cd opsbox
chmod +x opsbox
sudo ./opsbox              # 需要读 /etc/shadow 的检查项要求 root，其他项普通用户即可

# 方式二：安装到系统（含 systemd 定时巡检）
sudo bash packaging/install.sh
sudo opsbox                # 之后可以在任意目录直接调用
```

命令行接口：

```console
opsbox [命令] [选项]

命令：
  check              执行巡检（默认命令）
  list               列出本次采集到的所有检查项，便于精确静音
  modules            列出可用模块
  version / help

选项：
  -f, --format FMT   text（默认）| md | json | prom | csv | oneline
  -o, --output FILE  把报告写入文件
  -m, --modules LIST 只运行指定模块
  -c, --conf FILE    额外加载配置文件
  -i, --interval SEC 采样间隔（CPU 使用率 / 磁盘 IO 延迟）
      --fail-on LVL  ok|warn|crit|never（默认 warn）
      --no-color / --color / -q / -d
```

常见用法：

```bash
opsbox                                              # 全量巡检，终端报告
opsbox check -m disk,memory --fail-on crit          # 只看磁盘和内存，仅严重时非零退出
opsbox check -f json -o /var/log/opsbox/report.json # 归档成 JSON
opsbox check -f md -o report.md                     # 生成可提交的 Markdown 报告
opsbox list                                         # 看看有哪些检查项可以静音
opsbox check -d                                     # 打开调试日志
```

## 输出格式

| 格式 | 用途 |
| --- | --- |
| `text` | 人在终端看，带颜色与分组 |
| `md` | 归档、贴进工单、当周报附件 |
| `json` | 被其它系统消费；带 schema 版本号，便于长期兼容 |
| `prom` | node_exporter textfile collector 直接采集 |
| `csv` | 导入表格做趋势分析 |
| `oneline` | 塞进 cron 邮件主题，或喂给只认单行的老监控 |

`stdout` 只承载报告本体，所有提示信息走 `stderr`。所以 `opsbox check -f json > report.json` 永远得到干净的 JSON。

## 退出码：可以直接接监控

| 码 | 含义 |
| --- | --- |
| 0 | 全部通过 |
| 1 | 存在 WARN |
| 2 | 存在 CRIT |
| 3 | 用法错误 |
| 4 | 采集失败 / 环境不支持 |

这个退出码是**对外契约**，可以直接被 cron、CI、Nagios、Zabbix 消费。配合 `--fail-on` 可以控制严格程度：

```bash
# CI 里只关心严重问题，WARN 不阻塞发布
opsbox check --fail-on crit -f oneline

# 日常巡检：有 WARN 就发通知
opsbox check --fail-on warn -f md -o /var/log/opsbox/$(hostname)-$(date +%F).md
```

## 检查项清单

一次全量巡检约产出 50~60 条结论，分 8 个模块。核心项目：

| 模块 | 检查项 | 说明 |
| --- | --- | --- |
| **system** | `sys.time_sync` | 时间同步。漂移会导致日志时间线错乱、TLS 校验失败、集群选主异常 |
| | `sys.fd_usage` | 文件句柄使用率。耗尽会全服务报 `Too many open files` |
| | `sys.pid_usage` | PID 用量 |
| | `sys.oom_events` | 近期 OOM Killer 记录 |
| | `sys.reboot_required` | 内核已升级但未重启 |
| **cpu** | `cpu.usage` / `cpu.iowait` / `cpu.steal` | 三者分开看：算力不足 / 存储瓶颈 / 宿主机超卖，处置方向完全不同 |
| | `cpu.load1` / `cpu.load15` | 负载以**核数倍数**判定，而不是绝对值 |
| | `cpu.runqueue` | 就绪队列长度 |
| **memory** | `mem.used` | 口径为 `MemTotal - MemAvailable`，排除 page cache 误判 |
| | `mem.available` | 可用内存绝对下限 |
| | `mem.swap` / `mem.dirty` / `mem.commit` | 换页压力、脏页堆积、内存超售 |
| | `mem.zombie` / `mem.top` | 僵尸进程、内存 Top N |
| **disk** | `disk.usage.<挂载点>` | 逐挂载点容量水位 |
| | `disk.inode.<挂载点>` | inode 水位（`df -h` 有空间却写不进去的元凶） |
| | `disk.readonly` | 意外只读挂载——文件系统级故障信号 |
| | `disk.io_latency` | 平均单次 IO 延迟 = `ms_io` 增量 / 完成 IO 次数增量 |
| | `disk.big_log` | 最大日志文件 |
| **network** | `net.tcp_total` / `net.timewait` / `net.closewait` | 连接状态分布。`CLOSE_WAIT` 堆积是应用没 `close()` 的指纹 |
| | `net.err_rate.<网卡>` / `net.drop_rate.<网卡>` | 用**比率**而非累计计数，长期运行的机器不会误报 |
| | `net.conntrack` | 连接跟踪表使用率。K8s 节点/NAT 网关的高频故障点 |
| | `net.sensitive_ports` | 数据库/缓存端口暴露到 `0.0.0.0` |
| **service** | `svc.failed.<单元>` | 逐个列出失败的 systemd 单元，而不是只给一个数字 |
| | `svc.required.<单元>` | 配置中声明为「必需」的服务 |
| **log** | `log.errors` | 错误日志量 |
| | `log.top1..3` | **错误聚类**：把消息里的数字/ID 归一化后统计词频，直接指出最高频的那一类 |
| | `log.crash_dumps` | core dump / crash 记录 |
| **security** | `sec.uid0` | 除 root 外的 UID 0 账户 |
| | `sec.empty_passwd` | 空密码账户 |
| | `sec.ssh_permitroot` / `sec.ssh_passwordauth` | SSH 暴露面 |
| | `sec.firewall` / `sec.mac` / `sec.ip_forward` | 防火墙、SELinux/AppArmor、内核转发 |

用 `opsbox list` 可以看到当前机器上实际产生的完整清单（含 id），再用 `OB_CFG_DISABLE_CHECKS` 精确静音。

## 配置

配置就是普通的 shell 变量赋值，优先级从低到高：

```
内置默认值 → <安装目录>/conf/opsbox.conf → /etc/opsbox/opsbox.conf
          → ~/.config/opsbox/opsbox.conf → --conf 指定的文件
```

随项目分发的 `conf/opsbox.conf` 优先级**最低**（它只提供带注释的默认值），所以运维在 `/etc` 里的调优不会被它覆盖。

**建议不要直接改仓库里的 `conf/opsbox.conf`**，而是把要覆盖的项写进 `/etc/opsbox/opsbox.conf`，这样升级 opsbox 时你的调优不会丢，也能一眼看出这台机器偏离了哪些默认值。

```bash
# /etc/opsbox/opsbox.conf
OB_CFG_DISK_WARN="85"                 # 这台机器磁盘长期偏高，阈值放宽
OB_CFG_DISK_CRIT="93"
OB_CFG_REQUIRED_UNITS="sshd.service,nginx.service"
OB_CFG_DISABLE_CHECKS="sec.ip_forward"   # 这是 K8s 节点，转发是正常的
```

每个阈值的含义、口径和调优建议见 **[docs/阈值说明.md](docs/阈值说明.md)**。

## 接入监控与定时巡检

- Prometheus（textfile collector + 告警规则）：见 [docs/监控接入.md](docs/监控接入.md)
- Zabbix / Nagios / Icinga：同上
- cron 定时巡检：`examples/cron/opsbox-daily`
- systemd timer：`systemd/opsbox.timer`（安装脚本会一并部署）
- Webhook 通知：`examples/alert/webhook.sh`

## 项目结构

```
opsbox
├── opsbox                 # 主入口：参数解析、模块调度、退出码
├── lib/
│   ├── core.sh            # 常量、退出码语义、日志、结果记录、数值工具、配置
│   ├── collect.sh         # 采集层：只读事实，优先直读 /proc
│   ├── checks.sh          # 判定层：阈值 → 状态 → 处置建议
│   └── report.sh          # 展示层：text / md / json / prom / csv
├── modules/               # 8 个巡检模块，各自独立
├── conf/opsbox.conf       # 带注释的完整配置模板
├── systemd/               # 定时巡检与告警单元
├── packaging/             # 安装 / 卸载脚本
├── examples/              # cron、Prometheus、Webhook 落地示例
├── docs/                  # 快速开始 / 阈值说明 / 监控接入 / 故障排查手册
└── tests/
    ├── run-tests.sh       # 端到端测试套件
    └── fixtures/build.sh  # 生成「假操作系统」，可在非 Linux 上完整测试
```

## 测试

测试套件不依赖 Linux 环境，也不需要 root：`tests/fixtures/build.sh` 会生成两套模拟系统（`healthy` 与 `troubled`），覆盖正常路径与「内存仅剩 600MB + 根分区 92% + 根分区变只读 + 存在 UID 0 后门账户 + 61 条错误日志」这类真实环境难以复现的场景。

```bash
bash tests/run-tests.sh            # 跑完整套件
bash tests/run-tests.sh --keep     # 保留中间产物（报告、JSON）便于翻看

# 手动体验一下「故障机器」长什么样
bash tests/fixtures/build.sh /tmp/fix troubled
cat > /tmp/fix.conf <<EOF
OB_CFG_PROC_ROOT="/tmp/fix/proc"
OB_CFG_ETC_ROOT="/tmp/fix/etc"
OB_CFG_VAR_ROOT="/tmp/fix/var"
OB_CFG_RUN_ROOT="/tmp/fix/run"
OB_CMD_DF="/tmp/fix/bin/df"
OB_CMD_SYSTEMCTL="/tmp/fix/bin/systemctl"
OB_CMD_JOURNALCTL="/tmp/fix/bin/journalctl"
OB_CFG_SAMPLE_INTERVAL="0"
OB_CFG_LOG_FILES="/tmp/fix/var/log/syslog"
EOF
OPSBOX_FIXTURE_MARKER=/tmp/fix/run/troubled.marker bash opsbox check -c /tmp/fix.conf
```

测试套件覆盖：语法检查、数值/判定原语的边界、两种场景的端到端结论、四种输出格式的完整性、退出码契约、模块选择与检查项静音、以及「所有采集路径都指向空目录时不崩溃且输出合法 JSON」。

## 兼容性

- **Bash 3.2+**（macOS 自带的 bash 也能跑）。刻意不使用关联数组、`${var,,}`、`mapfile` 等 bash 4 专有语法。CI 里有一条断言在守这个约定。
- 面向 Linux。在 Windows 上通过 Git Bash 可以运行代码逻辑（测试套件就是这么跑的），但部分检查项依赖 Linux 专有的 `/proc` 结构。
- 只读设计：opsbox 不修改任何系统状态，不做自动清理，不重启服务。它只报告和建议。

## 许可

[MIT](LICENSE)

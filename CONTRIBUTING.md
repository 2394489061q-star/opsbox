# 参与 opsbox 开发

感谢你愿意贡献一份力量。opsbox 是刻意保持「小而能跑」的项目：纯 Bash、零第三方依赖、
只读不改系统。下面所有约定都是为了守住这一点。

> 先读 `README.md` 的「设计取舍」一节，本文件里的规则都能在那里找到出处。

## 1. 开始之前

- 需要：Linux / macOS，或 Windows 上的 Git Bash（测试套件不需要 Linux，也不需要 root）。
- 不需要：root 权限、任何依赖包、联网（只有测试套件用 Python 解析 JSON，且仅测试需要）。

先确认基线是绿的：

```bash
bash tests/run-tests.sh          # 跑完整测试套件
bash tests/run-tests.sh --keep   # 保留中间产物（报告、JSON）便于事后翻看
bash scripts/shellcheck.sh       # 静态检查（未装 shellcheck 时会降级为 bash -n）
```

## 2. 代码地图

```
opsbox                   主入口：参数解析、配置分层加载、模块调度、退出码
lib/core.sh              常量、退出码语义、日志、结果记录（ob_emit）、数值工具、配置默认值
lib/collect.sh           采集层：只读地获取系统事实，优先直读 /proc，外部命令可注入
lib/checks.sh            判定层：ob_check_* 原语，把观测值折叠成 OK/WARN/CRIT/UNKNOWN
lib/report.sh            展示层：text / md / json / prom / csv / oneline
modules/NN-name.sh       巡检模块，一个文件一个模块
conf/opsbox.conf         带完整中文注释的配置模板（所有阈值都写在这里）
tests/run-tests.sh       端到端测试套件
tests/fixtures/build.sh  生成「假操作系统」夹具（healthy / troubled 两套场景）
scripts/shellcheck.sh    静态检查入口
```

三层各管一件事：**采集层不判定，判定层不输出，展示层不算数**。
新增检查项时，把「怎么取数」留在 `lib/collect.sh` 或模块里，
把「多少算超标」交给 `lib/checks.sh` 的判定原语——这样同一个指标在终端报告、JSON、
Prometheus 里的结论必然一致。

## 3. 新增一个检查模块

### 3.1 文件命名约定

新文件放在 `modules/NN-name.sh`：

- `NN` 是两位序号，**决定执行顺序**（现有 `10-system` … `80-security`），
  报告里也是按这个顺序分组的。请挑一个语义合适的位置，不要一律用 `99` 抢最后。
- `name` 必须与函数名、report 标签一一对应，**只用小写字母**，函数名是 `ob_module_<name>`。
- 文件第一行 `#!/usr/bin/env bash`，接着用一个注释块写清「这个模块回答什么问题、
  为什么这样拆分」（现有 8 个模块都是这个风格，照着写就行）。

### 3.2 必须实现的函数

```bash
ob_module_<name>() {
    OB_MODULE="<name>"     # 必须第一件事就设置：ob_ok / ob_warn / ob_crit / ob_unknown 靠它填模块名
    # …… 采集 + 判定 ……
    return 0               # 模块函数不要 exit，退出码由主程序按最严重状态统一决定
}
```

`OB_MODULE` 是结果归属的唯一来源，忘了设置会把检查项挂到上一个模块名下。

### 3.3 如何产出结果：emit

最底层是 `ob_emit`，签名是：

```bash
ob_emit <status> <module> <id> <title> <observed> <threshold> <advice>
#        OK|WARN|CRIT|UNKNOWN
```

日常几乎不用直接写它，用四个便捷封装即可（模块名自动取 `$OB_MODULE`）：

```bash
ob_ok      "net.tcp_total" "TCP 连接总数" "120 条" "低于 5000 条" "-"
ob_warn    "<id>" "<标题>" "<观测值>" "<阈值>" "<处置建议>"
ob_crit    "<id>" "<标题>" "<观测值>" "<阈值>" "<处置建议>"
ob_unknown "<id>" "<标题>" "无法读取 /proc/net/tcp" "<阈值>" "<怎么排查>"
```

更推荐用 `lib/checks.sh` 里的判定原语，让阈值口径只有一处定义：

| 原语 | 用途 |
| --- | --- |
| `ob_check_threshold <id> <title> <value> <warn> <crit> <direction> <unit> <advice>` | 单值阈值比较；`direction` 为 `high`（越大越糟，默认）或 `low`（越小越糟） |
| `ob_check_ratio <id> <title> <num> <den> <warn_mult> <crit_mult> <advice>` | 比值型，例如负载 / 核数 |
| `ob_check_bool <id> <title> <ok_display> <bad_display> <condition_exit_code> <bad_status> <advice>` | 布尔断言 |
| `ob_check_required <id> <title> <target> <file\|dir\|cmd> <bad_status> <advice>` | 文件 / 目录 / 命令存在性断言 |
| `ob_check_series <id_prefix> <title_prefix> <lines> <warn> <crit> <unit> <advice>` | 多实例批量判定（挂载点、网卡），每行格式 `<slug> <value> [显示名]` |

写模块时必须遵守的几条硬约定：

1. **检查项 id 是用户的静音键，必须稳定。** 形如 `<前缀>.<指标>[.<slug>]`，
   前缀沿用既有惯例：`sys.` `cpu.` `mem.` `disk.` `net.` `svc.` `log.` `sec.`。
   多实例用 `ob_slug` 生成后缀（如 `disk.usage.root`）。**一旦发布就不要改名。**
2. **「测不到」不等于「没问题」。** 采集失败一律 `ob_unknown`，并写清缺什么；
   阈值原语已经内置这个行为（值非数字时直接产出 UNKNOWN）。
3. **非 OK 结论必须给处置建议。** 测试会断言所有 CRIT 项的 `advice` 非空；
   建议要能直接粘到终端里执行，不要写「重启试试」这类空话。
4. **不要在管道里调用 `ob_emit`。** 管道会开子 shell，写在子 shell 里的结果
   不会回到全局数组，行会凭空消失；需要遍历数据时用 here-string
   （`ob_check_series` 就是这么写的）。
5. **优先直读 `/proc`、`/sys`。** 路径通过 `$OB_CFG_PROC_ROOT` / `$OB_CFG_ETC_ROOT`
   这类变量拼接，不要硬编码 `/proc`（否则夹具测试与「指向容器挂载的宿主 /proc」都会失效）。
   确实没有 `/proc` 替代品时才调用外部命令，并且要留注入点与降级路径：

   ```bash
   local bin="${OB_CMD_JOURNALCTL:-journalctl}"
   if [ -n "${OB_CMD_JOURNALCTL:-}" ] || ob_have journalctl; then
       # 有 journald 的路径
   else
       # 降级：扫描传统日志文件（见 lib/collect.sh 的 ob_logfile_error_count）
   fi
   ```

### 3.4 注册模块与阈值（缺一处就会出现「不带配置文件跑结果不一样」）

| 位置 | 要改什么 |
| --- | --- |
| `conf/opsbox.conf` | 把模块名加进 `OB_CFG_ENABLED_MODULES` |
| `lib/core.sh` 的 `ob_conf_defaults()` | 同一份内置默认值（必须与上面保持一致） |
| `lib/report.sh` 的 `ob_module_label()` | 加一行中文标签，否则报告里显示的是英文 key |

新增阈值同样要改两处：`conf/opsbox.conf`（带中文注释，说明口径与调优建议）
和 `lib/core.sh` 的 `ob_conf_defaults()`（默认值）。

### 3.5 补测试夹具与断言（必做）

1. **夹具**：在 `tests/fixtures/build.sh` 里把它需要的系统事实造出来。
   - 场景差异写在 `healthy` / `troubled` 两个分支里（同一个文件，两套数值）；
   - 新增目录要加进开头那串 `mkdir -p`；写文件用既有的 `w <路径> <内容>` 或
     `cat > "$FIX_ROOT/..." <<EOF`；
   - 需要外部命令时，照 `bin/df`、`bin/systemctl` 的样子写一个 stub，
     **别忘了 `chmod +x`**（`tests/run-tests.sh` 会把 `bin/` 加进 `PATH`）。
     stub 里可以用 `$OPSBOX_FIXTURE_MARKER` 区分当前场景：
     `tests/run-tests.sh` 只在 troubled 场景 export 这个变量，指向
     `<夹具>/run/troubled.marker`。
2. **断言**：在 `tests/run-tests.sh` 里补。
   - 症状类：在第 5 节（故障主机）加
     `assert_contains "命中 XXX 检查" "$TROUBLED_TEXT" "<标题片段>"`；
   - 状态类：在同一节的 Python 断言里把 `('<新 id>', 'CRIT')` 加进 `checks` 列表；
   - 多实例检查顺便断言 slug 后缀（例如 `disk.usage.root`）。
3. **跑一遍**：`bash tests/run-tests.sh`。如果健康场景报出 CRIT、或故障场景没报出来，
   测试会直接失败——这是刻意的，请改代码，不要改断言迁就代码。

## 4. 代码风格

- **缩进 4 空格**，不用 Tab（`Makefile` 是唯一例外，那里必须 Tab）。
- **注释写中文，并且解释「为什么」而不是「做了什么」。** 现有代码里最有价值的部分
  就是这些注释——例如 `ob_count_lines` 为什么要先捕获再校验、
  `ob_check_series` 为什么必须用 here-string。请保持这个习惯。
- 函数命名 `ob_xxx`，模块函数固定 `ob_module_<name>`，函数内变量一律 `local`。
- 入口与测试都开着 `set -u` 和 `set -o pipefail`，新代码不要依赖未定义变量，
  也不要写 `... | while read` 之后指望循环里的变量在外面还能用。
- **守住零 fork 的热点**：`ob_cmp`、`ob_flatten`、`ob_slug` 在一次巡检里会被调用成百上千次。
  能用 Bash 参数展开或内建 `test` 完成的，就不要 `fork` 出 `awk` / `sed` / `tr`；
  真的需要浮点运算时才交给 `awk`。
- **兼容 Bash 3.2+**：不使用关联数组（`declare -A` / `typeset -A` / `local -A`）、
  不使用大小写转换（`${var,,}` / `${var^^}`）、不使用 `mapfile` / `readarray`。
  CI 的「shell 兼容性」job 会递归扫描仓库里的**所有** `*.sh` 与主入口 `opsbox`，
  用 grep 直接断言这三点（以 `#` 开头的整行注释会被忽略，
  所以像 `lib/core.sh` 顶部那样在注释里讨论这些语法是允许的）。本地可以这样自查：

  ```bash
  files="$(printf '%s\n' opsbox; find . -path './.git' -prune -o -path './tests/.work' -prune -o -type f -name '*.sh' -print)"
  grep -nE '(declare|typeset|local)[[:space:]]+-A' $files
  grep -nE '\$\{[A-Za-z_][A-Za-z0-9_]*(,,|\^\^)' $files
  grep -nE '(^|[^A-Za-z_])(mapfile|readarray)([^A-Za-z_]|$)' $files
  ```

- **stdout 只承载报告本体**，任何诊断信息都走 `ob_debug` / `ob_info` / `ob_warn` /
  `ob_error`（它们写 stderr）。这条约定被测试守着：`-o` 落盘时 stdout 必须是空的。
- **shellcheck 告警优先改代码。** 如果确实是 Bash 3.2 下不可避免的写法，
  在紧邻的上一行写 `# shellcheck disable=SCxxxx` 并把原因写清楚
  （源码里已有 `SC1090` 的先例）；不要往 `scripts/shellcheck.sh` 的排除清单里加——
  那份清单只放「全项目普遍存在且逐条确认过」的规则。

## 5. 提交 PR 前的自检清单

- [ ] `bash tests/run-tests.sh` 全绿（不允许通过修改断言来变绿）。
- [ ] `bash scripts/shellcheck.sh` 没有新增告警，且所有脚本 `bash -n` 通过。
- [ ] 新模块/新检查项在真实机器上跑过：`bash opsbox check -m <模块> -f text`，
      确认没有明显误报；若有预期内的告警，在 PR 描述里说明原因。
- [ ] 新检查项出现在 `bash opsbox list` 中，且能用
      `OB_CFG_DISABLE_CHECKS="<id>"` 精确静音。
- [ ] 至少验证三种输出：`-f text`、`-f json`、`-f prom`。
- [ ] `CHANGELOG.md` 顶部新增 `[Unreleased]` 小节并补一条中文条目
      （或在当前未发布版本小节下补充）。
- [ ] 没有提交生成物：`tests/.work/`、`reports/`、`*.report.md`（`.gitignore` 已覆盖）。
- [ ] 换行符没有被改成 CRLF（`.gitattributes` 已把脚本固定为 LF；
      可用 `git diff --check` 与 `git status` 自查，Windows 上尤其注意）。
- [ ] 新阈值同时写进了 `conf/opsbox.conf` **和** `lib/core.sh` 的 `ob_conf_defaults()`。

## 6. 提交信息与 PR 描述

- 提交信息用中文，第一行格式为 `<类型>: <一句话描述>`，类型沿用
  `feat` / `fix` / `docs` / `test` / `refactor` / `chore`。
  例：`feat: 新增 disk.io_latency 磁盘 IO 延迟检查`。
- PR 描述请写清四件事：**现象 → 判定依据（阈值从哪来）→ 处置建议 → 如何验证**。
  新增阈值时必须说明数字出处（内核文档、厂商建议、线上事故复盘等），不要拍脑袋给数。
- 一个 PR 只做一件事，不要把「全仓库格式化」和功能改动混在一起。

## 7. 不要做的事

- **不要引入运行时依赖**（Python、jq、bc、GNU 专有选项等）。目标环境是
  「可能连 Python 都没有、且不允许随便装东西」的生产服务器。
- **不要让 opsbox 修改系统状态**：不删文件、不重启服务、不改内核参数。
  它只报告和建议。
- **不要在模块里 `exit`**，也不要自己拼退出码；退出码由主程序按最严重状态统一决定。
- **不要绕过三层架构**：在展示层做判定、在采集层直接输出结论，都会被 review 打回。

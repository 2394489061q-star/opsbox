#!/usr/bin/env bash
# ==============================================================================
# opsbox :: tests/run-tests.sh
# 端到端测试套件。不需要 Linux 环境，也不需要 root：
# 采集层的根路径全部可注入，配合 fixtures/build.sh 生成的假系统即可完整覆盖。
#
# 用法： bash tests/run-tests.sh [--keep]
#   --keep  保留测试用的临时目录，便于事后翻看生成的报告
# ==============================================================================

set -u
set -o pipefail

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$TESTS_DIR/.." && pwd)"
OPSBOX="$ROOT_DIR/opsbox"

KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1

# ---------------------------------------------------------------- Python ----
# JSON 结构校验交给 Python（比 grep 可靠得多）。
#
# 探测方式刻意不是「command -v 找得到就算」：Windows 上 python3 常常是
# Microsoft Store 的 App Execution Alias，command -v 能找到它，但执行后
# 既不输出也不报错（只在 GUI 里弹商店）。那种情况下测试会得到一个空字符串，
# 然后以「期望 OK 实际空」的形式失败，排查起来完全指不到真正的原因。
# 所以这里要求解释器能真的执行一段代码：
detect_python() {
    local c
    for c in python3 python; do
        command -v "$c" >/dev/null 2>&1 || continue
        if "$c" -c 'print(1)' >/dev/null 2>&1; then
            printf '%s' "$c"
            return 0
        fi
    done
    printf ''
}
PYTHON="$(detect_python)"

WORK="$TESTS_DIR/.work"
rm -rf "$WORK"
mkdir -p "$WORK"

PASS=0
FAIL=0
SKIP=0
FAIL_LIST=""

C_GREEN=""; C_RED=""; C_YELLOW=""; C_BOLD=""; C_RESET=""
if [ -t 1 ]; then
    C_GREEN="$(printf '\033[32m')"
    C_RED="$(printf '\033[31m')"
    C_YELLOW="$(printf '\033[33m')"
    C_BOLD="$(printf '\033[1m')"
    C_RESET="$(printf '\033[0m')"
fi

ok() {
    PASS=$((PASS + 1))
    printf '  %sPASS%s %s\n' "$C_GREEN" "$C_RESET" "$1"
}

skip() {
    SKIP=$((SKIP + 1))
    printf '  %sSKIP%s %s\n' "$C_YELLOW" "$C_RESET" "$1"
}

# 把 JSON 喂给 Python 断言脚本，并把结论转成一个可断言的字符串
assert_json() { # <desc> <json> <python_script>
    local desc="$1" json="$2" script="$3" out
    if [ -z "$PYTHON" ]; then
        skip "$desc（未找到 python3/python，已跳过）"
        return 0
    fi
    out="$(printf '%s' "$json" | "$PYTHON" "$script" 2>&1)"
    assert_eq "$desc" "OK" "$out"
}

bad() {
    FAIL=$((FAIL + 1))
    FAIL_LIST="${FAIL_LIST}  - $1
"
    printf '  %sFAIL%s %s\n' "$C_RED" "$C_RESET" "$1"
    [ -n "${2:-}" ] && printf '       %s\n' "$2"
    return 0
}

assert_eq() { # <desc> <expected> <actual>
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "期望 [$2]，实际 [$3]"; fi
}

assert_contains() { # <desc> <haystack> <needle>
    case "$2" in
        *"$3"*) ok "$1" ;;
        *)      bad "$1" "输出中未找到 [$3]" ;;
    esac
}

assert_not_contains() { # <desc> <haystack> <needle>
    case "$2" in
        *"$3"*) bad "$1" "输出中不应出现 [$3]" ;;
        *)      ok "$1" ;;
    esac
}

section() { printf '\n%s== %s ==%s\n' "$C_BOLD" "$1" "$C_RESET"; }

# ==============================================================================
section "1. 脚本语法检查"
# ==============================================================================
# 用 find 全仓库收集，而不是写死几个目录：这样 examples/、packaging/、
# scripts/ 下新增的脚本会自动纳入检查，不会出现「测试通过但新脚本是坏的」。
syntax_fail=""
syntax_n=0
SYNTAX_LIST="$(LC_ALL=C find "$ROOT_DIR" -type f \( -name '*.sh' -o -name 'opsbox' \) \
    -not -path '*/.git/*' -not -path '*/.work/*' 2>/dev/null | LC_ALL=C sort)"
while IFS= read -r f; do
    [ -n "$f" ] || continue
    syntax_n=$((syntax_n + 1))
    if ! bash -n "$f" 2>"$WORK/syntax.err"; then
        syntax_fail="$syntax_fail ${f#$ROOT_DIR/}"
        printf '       %s: %s\n' "${f##*/}" "$(head -n2 "$WORK/syntax.err" | tr '\n' ' ')"
    fi
done <<<"$SYNTAX_LIST"
if [ -z "$syntax_fail" ]; then
    ok "全部 $syntax_n 个脚本通过 bash -n 语法检查"
else
    bad "语法检查失败：$syntax_fail"
fi

# ==============================================================================
section "2. 数值与判定原语（单元测试）"
# ==============================================================================
unit() { # <表达式> —— 在子 shell 中加载 core.sh 后求值
    bash -c '. "$1/lib/core.sh"; shift; eval "$@"' _ "$ROOT_DIR" "$1"
}

assert_eq "ob_cmp 90 >= 90 为真"          "0" "$(unit 'ob_cmp 90 ">=" 90; printf "%s" $?')"
assert_eq "ob_cmp 89 >= 90 为假"          "1" "$(unit 'ob_cmp 89 ">=" 90; printf "%s" $?')"
assert_eq "ob_cmp 1.5 > 1.49 为真"        "0" "$(unit 'ob_cmp 1.5 ">" 1.49; printf "%s" $?')"
assert_eq "ob_grade 大值方向 CRIT"        "CRIT" "$(unit 'ob_grade 95 80 90 high')"
assert_eq "ob_grade 大值方向 WARN"        "WARN" "$(unit 'ob_grade 85 80 90 high')"
assert_eq "ob_grade 大值方向 OK"          "OK" "$(unit 'ob_grade 50 80 90 high')"
assert_eq "ob_grade 小值方向 OK"          "OK" "$(unit 'ob_grade 300 256 64 low')"
assert_eq "ob_grade 小值方向 WARN"        "WARN" "$(unit 'ob_grade 100 256 64 low')"
assert_eq "ob_grade 小值方向 CRIT"        "CRIT" "$(unit 'ob_grade 50 256 64 low')"
assert_eq "ob_div 保留两位"               "0.33" "$(unit 'ob_div 1 3 2')"
assert_eq "ob_div 除零保护"               "0" "$(unit 'ob_div 5 0 2')"
assert_eq "ob_human_bytes GB"             "1.0 GB" "$(unit 'ob_human_bytes 1073741824')"
assert_eq "ob_human_bytes B"              "512 B" "$(unit 'ob_human_bytes 512')"
assert_eq "ob_trim 去首尾空白"            "x y" "$(unit 'ob_trim "  x y  "')"
assert_eq "ob_slug 路径转标识"            "var_lib_docker" "$(unit 'ob_slug "/var/lib/docker"')"
assert_eq "ob_slug 根路径兜底"            "root" "$(unit 'ob_slug "/"')"
assert_eq "ob_json_escape 转义引号"       'a\"b' "$(unit 'ob_json_escape "a\"b"')"
assert_eq "ob_is_num 接受小数"            "0" "$(unit 'ob_is_num 3.14; printf "%s" $?')"
assert_eq "ob_is_num 拒绝空串"            "1" "$(unit 'ob_is_num ""; printf "%s" $?')"
assert_eq "ob_flatten 压缩竖线"           "a b c" "$(unit 'ob_flatten "a|b
c"')"

# ==============================================================================
section "3. 夹具生成"
# ==============================================================================
if bash "$TESTS_DIR/fixtures/build.sh" "$WORK/healthy" healthy >"$WORK/build-healthy.log" 2>&1; then
    ok "healthy 夹具生成成功"
else
    bad "healthy 夹具生成失败" "$(cat "$WORK/build-healthy.log")"
fi

if bash "$TESTS_DIR/fixtures/build.sh" "$WORK/troubled" troubled >"$WORK/build-troubled.log" 2>&1; then
    ok "troubled 夹具生成成功"
else
    bad "troubled 夹具生成失败" "$(cat "$WORK/build-troubled.log")"
fi

make_conf() { # <fixture_dir> <conf_path> <marker_file>
    cat > "$2" <<EOF
# opsbox 测试配置（由 run-tests.sh 生成）
OB_CFG_PROC_ROOT="$1/proc"
OB_CFG_SYS_ROOT="$1/sys"
OB_CFG_ETC_ROOT="$1/etc"
OB_CFG_VAR_ROOT="$1/var"
OB_CFG_RUN_ROOT="$1/run"
OB_CMD_DF="$1/bin/df"
OB_CMD_SYSTEMCTL="$1/bin/systemctl"
OB_CMD_JOURNALCTL="$1/bin/journalctl"
OB_CMD_TIMEDATECTL="$1/bin/timedatectl"
OB_CFG_SAMPLE_INTERVAL="0"
OB_CFG_LOG_FILES="$1/var/log/syslog"
OB_CFG_CRASH_DUMP_DIRS="$1/var/crash"
OB_CFG_REQUIRED_UNITS="sshd.service,nginx.service"

# mock 命令靠这个文件是否存在来决定扮演「正常机器」还是「故障机器」。
# 刻意放在配置里而不是测试脚本里 export：配置文件是每次调用独立加载的，
# 两个场景因此彻底隔离。否则测试中途一旦 export 了 marker，
# 后面所有 healthy 用例都会跟着一起"生病"，产生假失败。
export OPSBOX_FIXTURE_MARKER="$3"
EOF
}

# healthy 指向一个不存在的 marker，troubled 指向 build.sh 真正创建的那个
make_conf "$WORK/healthy"  "$WORK/healthy.conf"  "$WORK/healthy/run/troubled.marker"
make_conf "$WORK/troubled" "$WORK/troubled.conf" "$WORK/troubled/run/troubled.marker"

ORIG_PATH="$PATH"
export PATH="$WORK/healthy/bin:$WORK/troubled/bin:$PATH"

# ==============================================================================
section "4. 健康主机：应全部通过"
# ==============================================================================
unset OPSBOX_FIXTURE_MARKER 2>/dev/null || true
HEALTHY_JSON="$(bash "$OPSBOX" check -c "$WORK/healthy.conf" -f json 2>"$WORK/healthy.err")"
HEALTHY_CODE=$?
printf '%s' "$HEALTHY_JSON" > "$WORK/healthy.json"

assert_eq "healthy 退出码为 0" "0" "$HEALTHY_CODE"
if [ "$HEALTHY_CODE" != "0" ]; then
    printf '       stderr: %s\n' "$(head -n5 "$WORK/healthy.err" | tr '\n' ' ')"
    bash "$OPSBOX" check -c "$WORK/healthy.conf" 2>/dev/null \
        | LC_ALL=C grep -E '\[(WARN|CRIT|UNKN)\]' | head -n 10 | sed 's/^/       /'
fi

# JSON 断言用的 Python 脚本一律写成独立文件再执行，而不是内联在
# `python -c "..."` 里。原因是双引号字符串中的反引号会被 shell 当成命令替换、
# `${` 会被当成参数展开、`$1` 会被展开成位置参数——写成内联极易踩坑，
# 而且排查时看到的报错会是 Python 语法错误，完全指不到真正的元凶。
cat > "$WORK/assert_healthy.py" <<'PY'
import json
import sys

try:
    d = json.load(sys.stdin)
except Exception as exc:                      # noqa: BLE001 - 要把原因回显给测试
    print('PARSE_ERROR: %s' % exc)
    sys.exit(1)

problems = []
if not d.get('schema', '').startswith('opsbox.report/'):
    problems.append('schema 缺失')
if d.get('tool', {}).get('name') != 'opsbox':
    problems.append('tool.name 不正确')
for key in ('summary', 'results', 'host'):
    if key not in d:
        problems.append('缺少字段 %s' % key)
if not d.get('host', {}).get('hostname'):
    problems.append('hostname 为空')
if d.get('summary', {}).get('crit') != 0:
    problems.append('healthy 场景不应出现 CRIT，实际 %s' % d.get('summary', {}).get('crit'))
if len(d.get('results', [])) <= 20:
    problems.append('检查项过少：%d' % len(d.get('results', [])))
print('OK' if not problems else '; '.join(problems))
PY

assert_json "healthy JSON 结构正确且无 CRIT" "$HEALTHY_JSON" "$WORK/assert_healthy.py"

# ==============================================================================
section "5. 故障主机：应报出 CRIT 并返回 2"
# ==============================================================================
# 场景切换完全由 troubled.conf 里的 OPSBOX_FIXTURE_MARKER 决定，
# 测试脚本自身不再 export 任何 marker，避免污染后面的 healthy 用例。
TROUBLED_TEXT="$(bash "$OPSBOX" check -c "$WORK/troubled.conf" -f text 2>"$WORK/troubled.err")"
TROUBLED_CODE=$?
printf '%s' "$TROUBLED_TEXT" > "$WORK/troubled.txt"

assert_eq "troubled 退出码为 2（CRIT）" "2" "$TROUBLED_CODE"

TROUBLED_JSON="$(bash "$OPSBOX" check -c "$WORK/troubled.conf" -f json 2>/dev/null)"
printf '%s' "$TROUBLED_JSON" > "$WORK/troubled.json"

assert_contains "命中只读文件系统检查" "$TROUBLED_TEXT" "只读挂载的文件系统"
assert_contains "命中内存使用率检查"   "$TROUBLED_TEXT" "内存使用率"
assert_contains "命中磁盘使用率检查"   "$TROUBLED_TEXT" "分区使用率"
assert_contains "命中 inode 检查"      "$TROUBLED_TEXT" "inode 使用率"
assert_contains "命中 UID 0 账户检查"  "$TROUBLED_TEXT" "UID 为 0 的特权账户"
assert_contains "命中空密码检查"       "$TROUBLED_TEXT" "空密码账户"
assert_contains "命中 SSH root 登录"   "$TROUBLED_TEXT" "SSH 允许 root 登录"
assert_contains "命中失败单元检查"     "$TROUBLED_TEXT" "失败单元 nginx.service"
assert_contains "命中日志聚类"         "$TROUBLED_TEXT" "高频错误 #1"

cat > "$WORK/assert_troubled.py" <<'PY'
import json
import re
import sys

d = json.load(sys.stdin)
ids = {r['id']: r['status'] for r in d['results']}

# 每一项都是「这一场景必须有」的断言：既验证判定方向正确，
# 也验证阈值确实生效（CRIT/OK 都要对）。
checks = [
    ('disk.readonly', 'CRIT'),
    ('mem.used', 'CRIT'),
    ('sec.uid0', 'CRIT'),
    ('sec.empty_passwd', 'CRIT'),
    ('sec.ssh_permitroot', 'CRIT'),
    ('cpu.load1', 'CRIT'),
    ('net.timewait', 'OK'),
]

problems = []
for cid, want in checks:
    got = ids.get(cid)
    if got is None:
        problems.append('%s 缺失' % cid)
    elif got != want:
        problems.append('%s 期望 %s 实际 %s' % (cid, want, got))

# 挂载点级检查项应带 slug 后缀，否则无法用 OB_CFG_DISABLE_CHECKS 精确静音单个挂载点
if 'disk.usage.root' not in ids:
    problems.append('disk.usage.root 缺失（挂载点 slug 未生效）')
if 'disk.inode.root' not in ids:
    problems.append('disk.inode.root 缺失')

# CRIT 必须给出可执行的处置建议，只报数字不给出路的巡检没有价值
empty_advice = [r['id'] for r in d['results']
                if r['status'] == 'CRIT' and r['advice'] in ('', '-')]
if empty_advice:
    problems.append('CRIT 项缺少处置建议：%s' % ','.join(empty_advice[:3]))

# 不允许未展开的 shell 变量泄漏到报告里。
# 判定用的是正则 `\$[A-Za-z_{]`，而不是简单的「包含 OB_CFG_」：
#   未展开的变量一定带 $（形如 ${OB_CFG_X} 或 $OB_CFG_X）；
#   而建议文案里「让用户去改哪个配置项」是合法且必要的，
#   那种写法是裸词 OB_CFG_DISABLE_CHECKS，不带 $。
# 同时这个正则刻意不匹配 $1 —— 建议里给出 `awk '{print $1}'` 这类
# 让用户照抄的命令是合理的，$1 是 awk 的位置参数，不是 shell 变量。
bare_var = re.compile(r'\$[A-Za-z_{]')
bad_fields = [r['id'] for r in d['results']
              if bare_var.search(r['title'] + r['observed'] + r['advice'])]
if bad_fields:
    problems.append('字段中存在未展开变量：%s' % ','.join(bad_fields[:3]))

print('OK' if not problems else '; '.join(problems))
PY

assert_json "troubled JSON 关键检查项状态正确" "$TROUBLED_JSON" "$WORK/assert_troubled.py"

# ==============================================================================
section "6. 输出格式完整性"
# ==============================================================================
MD="$(bash "$OPSBOX" check -c "$WORK/troubled.conf" -f md 2>/dev/null)"
assert_contains "Markdown 含标题"       "$MD" "# Linux 服务器巡检报告"
assert_contains "Markdown 含结论表"     "$MD" "| 状态 | 数量 |"
assert_contains "Markdown 含问题章节"   "$MD" "## 三、需要处理的问题"

PROM="$(bash "$OPSBOX" check -c "$WORK/troubled.conf" -f prom 2>/dev/null)"
assert_contains "Prometheus 含整体状态" "$PROM" "opsbox_overall_status 2"
# check label 用的是完整检查项 id（与 `opsbox list` 显示的一致），便于直接对照静音配置
assert_contains "Prometheus 含检查项"   "$PROM" 'opsbox_check_status{module="disk",check="disk.readonly"} 2'
assert_contains "Prometheus 含 info"    "$PROM" "opsbox_info{"

CSV="$(bash "$OPSBOX" check -c "$WORK/troubled.conf" -f csv 2>/dev/null)"
CSV_LINES="$(printf '%s\n' "$CSV" | LC_ALL=C wc -l | tr -d ' ')"
CSV_RESULTS="$(printf '%s' "$TROUBLED_JSON" | python -c "import json,sys; print(len(json.load(sys.stdin)['results']))")"
assert_eq "CSV 行数 = 表头 + 检查项数" "$((CSV_RESULTS + 1))" "$CSV_LINES"
assert_contains "CSV 表头正确" "$CSV" "status,module,id,title,observed,threshold,advice"

ONELINE="$(bash "$OPSBOX" check -c "$WORK/troubled.conf" -f oneline 2>/dev/null)"
assert_contains "单行模式含状态" "$ONELINE" "CRIT"

# ==============================================================================
section "7. 退出码与命令行契约"
# ==============================================================================
bash "$OPSBOX" check -c "$WORK/troubled.conf" --fail-on never -f oneline >/dev/null 2>&1
assert_eq "--fail-on never 返回 0" "0" "$?"

bash "$OPSBOX" check -c "$WORK/troubled.conf" --fail-on crit -f oneline >/dev/null 2>&1
assert_eq "--fail-on crit（有 CRIT）返回 2" "2" "$?"

bash "$OPSBOX" check -c "$WORK/healthy.conf" --fail-on crit -f oneline >/dev/null 2>&1
assert_eq "--fail-on crit（无 CRIT）返回 0" "0" "$?"

bash "$OPSBOX" check -m not_a_module -c "$WORK/healthy.conf" >/dev/null 2>&1
assert_eq "未知模块返回用法错误 3" "3" "$?"

bash "$OPSBOX" check -f not_a_format -c "$WORK/healthy.conf" >/dev/null 2>&1
assert_eq "未知格式返回用法错误 3" "3" "$?"

bash "$OPSBOX" check -c "$WORK/does-not-exist.conf" >/dev/null 2>&1
assert_eq "配置文件不存在返回 3" "3" "$?"

assert_contains "help 输出用法" "$(bash "$OPSBOX" help 2>&1)" "用法："
assert_eq "version 输出" "opsbox 1.0.0" "$(bash "$OPSBOX" version 2>&1 | tr -d '\r')"

LIST_OUT="$(bash "$OPSBOX" list -c "$WORK/troubled.conf" 2>/dev/null)"
assert_contains "list 输出检查项 ID" "$LIST_OUT" "disk.readonly"
assert_contains "list 提示如何静音"  "$LIST_OUT" "OB_CFG_DISABLE_CHECKS"

# ==============================================================================
section "8. 模块选择与检查项静音"
# ==============================================================================
DISK_ONLY="$(bash "$OPSBOX" check -c "$WORK/troubled.conf" -m disk -f csv 2>/dev/null)"
assert_contains "只跑 disk 模块含 disk 项"  "$DISK_ONLY" "disk.readonly"
assert_not_contains "只跑 disk 模块不含 sec 项" "$DISK_ONLY" "sec.uid0"

cat > "$WORK/mute.conf" <<EOF
$(cat "$WORK/troubled.conf")
OB_CFG_DISABLE_CHECKS="disk.readonly,net.conntrack"
EOF
MUTED="$(bash "$OPSBOX" check -c "$WORK/mute.conf" -f csv 2>/dev/null)"
assert_not_contains "静音 disk.readonly 生效" "$MUTED" "disk.readonly"
assert_not_contains "静音 net.conntrack 生效" "$MUTED" "net.conntrack"
assert_contains "未静音的项仍然存在"          "$MUTED" "mem.used"

# ==============================================================================
section "9. 模块级开关"
# ==============================================================================
cat > "$WORK/modules.conf" <<EOF
$(cat "$WORK/healthy.conf")
OB_CFG_ENABLED_MODULES="system disk"
EOF
SMALL="$(bash "$OPSBOX" check -c "$WORK/modules.conf" -f csv 2>/dev/null)"
assert_contains "限定模块后含 disk"     "$SMALL" "disk.usage.root"
assert_not_contains "限定模块后不含网络" "$SMALL" "net.tcp_total"

# ==============================================================================
section "10. 采集层健壮性：路径全部指向空目录时不应崩溃"
# ==============================================================================
mkdir -p "$WORK/empty"
cat > "$WORK/empty.conf" <<EOF
OB_CFG_PROC_ROOT="$WORK/empty/proc"
OB_CFG_SYS_ROOT="$WORK/empty/sys"
OB_CFG_ETC_ROOT="$WORK/empty/etc"
OB_CFG_VAR_ROOT="$WORK/empty/var"
OB_CFG_RUN_ROOT="$WORK/empty/run"
OB_CFG_SAMPLE_INTERVAL="0"
OB_CMD_DF="$WORK/empty/nonexistent-df"
OB_CMD_SYSTEMCTL="$WORK/empty/nonexistent-systemctl"
OB_CMD_JOURNALCTL="$WORK/empty/nonexistent-journalctl"
EOF
# 用干净的 PATH 跑，避免前面阶段注入 PATH 的 mock 命令（ufw/systemctl）干扰判断
EMPTY_OUT="$(PATH="$ORIG_PATH" bash "$OPSBOX" check -c "$WORK/empty.conf" -f json 2>"$WORK/empty.err")"
EMPTY_CODE=$?

# 本节的真实意图不是「退出码必须是 4」，而是两条安全属性：
#   1. 采集全线失败时不能崩溃；
#   2. 更不能误报 CRIT —— 虚假的严重告警比漏报更消耗信任。
if [ "$EMPTY_CODE" -le 1 ]; then
    ok "空环境下不崩溃且不误报 CRIT（退出码 $EMPTY_CODE）"
else
    bad "空环境下退出码异常" "期望 0 或 1，实际 $EMPTY_CODE"
fi

cat > "$WORK/assert_empty_env.py" <<'PY'
import json
import sys

d = json.load(sys.stdin)
problems = []
if not d['results']:
    problems.append('应仍产出结果项（即使是 UNKNOWN）')
if d['summary']['crit'] != 0:
    problems.append('读不到任何数据时不应误报 CRIT，实际 %s' % d['summary']['crit'])

unknowns = [r for r in d['results'] if r['status'] == 'UNKNOWN']
if len(unknowns) <= 5:
    problems.append('大部分检查项应为 UNKNOWN，实际只有 %d 个' % len(unknowns))

missing = [r['id'] for r in d['results'] if not r['advice'] or not r['threshold']]
if missing:
    problems.append('字段不应为空：%s' % ','.join(missing[:3]))

print('OK' if not problems else '; '.join(problems))
PY

assert_json "空环境下输出合法 JSON 且大量项为 UNKNOWN" "$EMPTY_OUT" "$WORK/assert_empty_env.py"

# ==============================================================================
section "11. 报告落盘"
# ==============================================================================
bash "$OPSBOX" check -c "$WORK/troubled.conf" -f md -o "$WORK/report.md" >/dev/null 2>&1
if [ -s "$WORK/report.md" ]; then ok "报告可写入指定文件"; else bad "报告写入失败"; fi
assert_eq "写入文件时 stdout 保持干净" "" "$(bash "$OPSBOX" check -c "$WORK/healthy.conf" -f json -o "$WORK/r2.json" 2>/dev/null)"
assert_contains "落盘 JSON 内容正确" "$(cat "$WORK/r2.json")" '"tool": {"name": "opsbox"'

# ==============================================================================
# 汇总
# ==============================================================================
printf '\n%s================ 测试结果 ================%s\n' "$C_BOLD" "$C_RESET"
printf '  通过：%s%d%s\n' "$C_GREEN" "$PASS" "$C_RESET"
if [ "$SKIP" -gt 0 ]; then
    printf '  跳过：%s%d%s（缺少 Python，JSON 结构校验未执行）\n' "$C_YELLOW" "$SKIP" "$C_RESET"
fi
if [ "$FAIL" -gt 0 ]; then
    printf '  失败：%s%d%s\n' "$C_RED" "$FAIL" "$C_RESET"
    printf '%s' "$FAIL_LIST"
    printf '\n  中间产物保留在：%s\n' "$WORK"
    exit 1
fi
printf '  失败：0\n'
printf '\n  全部测试通过。\n'

if [ "$KEEP" -eq 1 ]; then
    printf '  中间产物保留在：%s\n' "$WORK"
else
    rm -rf "$WORK"
fi
exit 0

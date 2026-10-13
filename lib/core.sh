#!/usr/bin/env bash
# ==============================================================================
# opsbox :: lib/core.sh
# 核心运行时：版本常量、退出码语义、日志、颜色、结果记录、数值工具、配置加载
#
# 本文件由 opsbox 主程序 source，不单独执行。
# 兼容 Bash 3.2+（不使用关联数组与 ${var,,} 等 4.x 语法）。
# ==============================================================================

# ------------------------------------------------------------------ 元信息 ----
OB_PROG="opsbox"
OB_VERSION="1.0.0"
OB_SCHEMA_VERSION="1"

# ------------------------------------------------------- 退出码语义（对外契约）----
# 这些数字是监控系统的接口，不要随意改动。
OB_EXIT_OK=0        # 全部检查通过
OB_EXIT_WARN=1      # 存在 WARN
OB_EXIT_CRIT=2      # 存在 CRIT
OB_EXIT_USAGE=3     # 参数用法错误
OB_EXIT_UNKNOWN=4   # 采集失败 / 环境不支持，无法判定

# ---------------------------------------------------------------- 结果存储 ----
# 每条结果格式： status|module|id|title|observed|threshold|advice
# 字段内的 | 与 TAB 在写入前已被替换，因此切分是安全的。
OB_RESULTS=()
OB_N_OK=0
OB_N_WARN=0
OB_N_CRIT=0
OB_N_UNKNOWN=0
OB_MODULE="general"

# 运行期状态
OB_START_EPOCH=0
OB_DEBUG="${OB_DEBUG:-0}"
OB_QUIET=0
OB_COLOR_MODE="auto"   # auto | always | never

# ---------------------------------------------------------------- 颜色 ----
C_RESET=""
C_BOLD=""
C_DIM=""
C_RED=""
C_GREEN=""
C_YELLOW=""
C_BLUE=""
C_CYAN=""
C_MAGENTA=""

ob_init_colors() {
    local want=0
    case "$OB_COLOR_MODE" in
        always) want=1 ;;
        never)  want=0 ;;
        *)      if [ -n "${NO_COLOR:-}" ]; then want=0
                elif [ -t 1 ]; then want=1
                else want=0; fi ;;
    esac
    if [ "$want" -eq 1 ]; then
        C_RESET="$(printf '\033[0m')"
        C_BOLD="$(printf '\033[1m')"
        C_DIM="$(printf '\033[2m')"
        C_RED="$(printf '\033[31m')"
        C_GREEN="$(printf '\033[32m')"
        C_YELLOW="$(printf '\033[33m')"
        C_BLUE="$(printf '\033[34m')"
        C_CYAN="$(printf '\033[36m')"
        C_MAGENTA="$(printf '\033[35m')"
    fi
    return 0
}

# ---------------------------------------------------------------- 日志 ----
# 日志一律走 stderr，保证 stdout 只承载报告本体（可安全重定向成文件）。
ob_log() {
    local level="$1"; shift
    [ "$OB_QUIET" -eq 1 ] && [ "$level" != "ERROR" ] && return 0
    local color=""
    case "$level" in
        DEBUG) [ "$OB_DEBUG" = "1" ] || return 0; color="$C_DIM" ;;
        INFO)  color="$C_CYAN" ;;
        WARN)  color="$C_YELLOW" ;;
        ERROR) color="$C_RED" ;;
    esac
    printf '%s[%s]%s %s\n' "$color" "$level" "$C_RESET" "$*" >&2
}

ob_debug() { ob_log DEBUG "$@"; }
ob_info()  { ob_log INFO  "$@"; }
ob_warn()  { ob_log WARN  "$@"; }
ob_error() { ob_log ERROR "$@"; }

ob_die() { # ob_die <message> [exit_code]
    local msg="$1" code="${2:-$OB_EXIT_USAGE}"
    ob_log ERROR "$msg"
    exit "$code"
}

# ---------------------------------------------------------------- 小工具 ----
ob_have() { command -v "$1" >/dev/null 2>&1; }

ob_trim() { # 去掉首尾空白
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

ob_is_num() { # 是否为非负数字（整数或小数）
    case "$1" in
        ''|*[!0-9.]*) return 1 ;;
        *.*.*) return 1 ;;
        .*) return 1 ;;
        *.) return 1 ;;
        *) return 0 ;;
    esac
}

ob_is_int() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

# 浮点/整数通用比较： ob_cmp A OP B  （OP ∈ -gt -ge -lt -le -eq -ne 或 >= <= > < == !=）
# 返回 0 表示条件成立。
#
# 性能约定：这是整个项目调用最频繁的函数（每个检查项至少调用一次，
# 部分检查项会调用两次）。因此整数比较一律走 bash 内建 test，不 fork；
# 只有真的出现小数点时才交给 awk 做浮点比较。
ob_cmp() {
    local a="$1" op="$2" b="$3"
    ob_is_num "$a" || return 1
    ob_is_num "$b" || return 1

    case "${a}${b}" in
        *.*) ;;   # 含小数点，落到函数末尾用 awk 比较
        *)
            case "$op" in
                ">="|-ge) [ "$a" -ge "$b" ] 2>/dev/null && return 0 || return 1 ;;
                "<="|-le) [ "$a" -le "$b" ] 2>/dev/null && return 0 || return 1 ;;
                ">"|-gt)  [ "$a" -gt "$b" ] 2>/dev/null && return 0 || return 1 ;;
                "<"|-lt)  [ "$a" -lt "$b" ] 2>/dev/null && return 0 || return 1 ;;
                "=="|-eq|=) [ "$a" -eq "$b" ] 2>/dev/null && return 0 || return 1 ;;
                "!="|-ne) [ "$a" -ne "$b" ] 2>/dev/null && return 0 || return 1 ;;
                *) return 1 ;;
            esac
            ;;
    esac

    LC_ALL=C awk -v a="$a" -v b="$b" -v op="$op" 'BEGIN {
        if      (op == ">="  || op == "-ge") r = (a >= b)
        else if (op == "<="  || op == "-le") r = (a <= b)
        else if (op == ">"   || op == "-gt") r = (a >  b)
        else if (op == "<"   || op == "-lt") r = (a <  b)
        else if (op == "=="  || op == "-eq" || op == "=") r = (a == b)
        else if (op == "!="  || op == "-ne") r = (a != b)
        else exit 2
        exit (r ? 0 : 1)
    }'
}

# 保留 digits 位小数的除法： ob_div A B [digits]
ob_div() {
    local a="$1" b="$2" d="${3:-2}"
    ob_is_num "$a" || { printf '0'; return 0; }
    ob_is_num "$b" || { printf '0'; return 0; }
    awk -v a="$a" -v b="$b" -v d="$d" 'BEGIN {
        if (b + 0 == 0) { printf "0"; exit }
        printf "%.*f", d, a / b
    }'
}

# 字节数 -> 人类可读
ob_human_bytes() {
    local n="$1"
    ob_is_num "$n" || { printf '%s' "${n:--}"; return 0; }
    awk -v n="$n" 'BEGIN {
        split("B KB MB GB TB PB", u, " ")
        i = 1
        while (n >= 1024 && i < 6) { n /= 1024; i++ }
        if (i == 1) printf "%d %s", n, u[i]
        else        printf "%.1f %s", n, u[i]
    }'
}

# 秒 -> 人类可读时长
ob_human_duration() {
    local s="$1"
    ob_is_int "$s" || { printf '%s' "${s:--}"; return 0; }
    local d=$((s / 86400)) h=$(( (s % 86400) / 3600 )) m=$(( (s % 3600) / 60 ))
    if   [ "$d" -gt 0 ]; then printf '%d天%d小时' "$d" "$h"
    elif [ "$h" -gt 0 ]; then printf '%d小时%d分' "$h" "$m"
    elif [ "$m" -gt 0 ]; then printf '%d分' "$m"
    else printf '%d秒' "$s"; fi
}

# 从 "Key: value" 形式的文件（如 /proc/meminfo）取第一个数值
# 用法： ob_kv_get <file> <Key>
ob_kv_get() {
    local file="$1" key="$2"
    [ -r "$file" ] || return 1
    LC_ALL=C awk -v k="$key" '
        $1 == k ":" || $1 == k { print $2; found = 1; exit }
        END { exit(found ? 0 : 1) }
    ' "$file" 2>/dev/null
}

# 计数： ob_count_lines <file> [pattern]
# 注意：grep -c 在「零匹配」时会输出 0 并以 1 退出。若写成 `... || printf '0'`
# 就会输出两个 0，后续数值判断全部落空。所以这里一律先捕获再校验。
ob_count_lines() {
    local file="$1" pat="${2:-}" n=""
    [ -r "$file" ] || { printf '0'; return 0; }
    if [ -n "$pat" ]; then
        n="$(LC_ALL=C grep -c -- "$pat" "$file" 2>/dev/null)"
    else
        n="$(LC_ALL=C wc -l < "$file" 2>/dev/null | tr -d ' ')"
    fi
    ob_is_int "$n" || n=0
    printf '%s' "$n"
}

# 报告用：把任意文本安全化为单行字段
# 这是另一个绝对热点：每产出一条检查结果就要调用 3 次（观测值/阈值/建议）。
# 早期版本用 tr+tr+sed 实现，单次巡检会产生上千次进程创建；
# 现在改为纯 bash 参数展开，零 fork。
ob_flatten() {
    local s="$1"
    s="${s//$'\n'/ }"
    s="${s//$'\t'/ }"
    s="${s//|/ }"
    while [ "${s//  / }" != "$s" ]; do
        s="${s//  / }"
    done
    s="${s# }"
    s="${s% }"
    printf '%s' "$s"
}

# 把挂载点 / 端口等变成稳定的短标识（用作检查项 id 后缀与静音键）
ob_slug() {
    local s="$1"
    s="${s//\//_}"
    s="${s// /_}"
    s="${s//:/_}"
    s="${s//./_}"
    s="${s#_}"
    s="${s%_}"
    [ -n "$s" ] || s="root"
    printf '%s' "$s"
}

# ---------------------------------------------------------------- 结果记录 ----
# ob_emit <status> <module> <id> <title> <observed> <threshold> <advice>
ob_emit() {
    local st="$1" mod="$2" id="$3" title="$4"
    local obs="${5:--}" thr="${6:--}" adv="${7:--}"

    case "$st" in
        OK|WARN|CRIT|UNKNOWN) : ;;
        *) st="UNKNOWN" ;;
    esac

    # 允许运维按需静音某些检查项（OB_CFG_DISABLE_CHECKS="disk.inode,security.suid"）
    if [ -n "${OB_CFG_DISABLE_CHECKS:-}" ]; then
        case ",${OB_CFG_DISABLE_CHECKS// /}," in
            *",${mod}.${id},"*|*",${id},"*) return 0 ;;
        esac
    fi

    obs="$(ob_flatten "$obs")"; [ -n "$obs" ] || obs="-"
    thr="$(ob_flatten "$thr")"; [ -n "$thr" ] || thr="-"
    adv="$(ob_flatten "$adv")"; [ -n "$adv" ] || adv="-"
    title="$(ob_flatten "$title")"
    id="$(ob_flatten "$id")"
    mod="$(ob_flatten "$mod")"

    OB_RESULTS+=("${st}|${mod}|${id}|${title}|${obs}|${thr}|${adv}")

    case "$st" in
        OK)      OB_N_OK=$((OB_N_OK + 1)) ;;
        WARN)    OB_N_WARN=$((OB_N_WARN + 1)) ;;
        CRIT)    OB_N_CRIT=$((OB_N_CRIT + 1)) ;;
        UNKNOWN) OB_N_UNKNOWN=$((OB_N_UNKNOWN + 1)) ;;
    esac

    if [ "$OB_DEBUG" = "1" ]; then
        printf '%s[%s]%s %s/%s %s (%s)\n' "$C_DIM" "$st" "$C_RESET" "$mod" "$id" "$title" "$obs" >&2
    fi
    return 0
}

# 便捷封装：模块上下文由 $OB_MODULE 提供
ob_ok()      { ob_emit OK      "$OB_MODULE" "$@"; }
ob_warn()    { ob_emit WARN    "$OB_MODULE" "$@"; }
ob_crit()    { ob_emit CRIT    "$OB_MODULE" "$@"; }
ob_unknown() { ob_emit UNKNOWN "$OB_MODULE" "$@"; }

# 阈值判定助手：把 观测值/警告线/严重线 折叠成一个状态
# ob_grade <value> <warn> <crit> <direction>
#   direction = high 表示越大越糟（默认），low 表示越小越糟
ob_grade() {
    local v="$1" w="$2" c="$3" dir="${4:-high}"
    if [ "$dir" = "low" ]; then
        if ob_cmp "$v" "<=" "$c"; then printf 'CRIT'
        elif ob_cmp "$v" "<=" "$w"; then printf 'WARN'
        else printf 'OK'; fi
    else
        if ob_cmp "$v" ">=" "$c"; then printf 'CRIT'
        elif ob_cmp "$v" ">=" "$w"; then printf 'WARN'
        else printf 'OK'; fi
    fi
}

# 当前最严重状态
ob_worst_status() {
    if   [ "$OB_N_CRIT" -gt 0 ];    then printf 'CRIT'
    elif [ "$OB_N_WARN" -gt 0 ];    then printf 'WARN'
    elif [ "$OB_N_UNKNOWN" -gt 0 ] && [ "$OB_N_OK" -eq 0 ]; then printf 'UNKNOWN'
    else printf 'OK'; fi
}

ob_exit_code_for_status() {
    case "$1" in
        OK)      printf '%s' "$OB_EXIT_OK" ;;
        WARN)    printf '%s' "$OB_EXIT_WARN" ;;
        CRIT)    printf '%s' "$OB_EXIT_CRIT" ;;
        *)       printf '%s' "$OB_EXIT_UNKNOWN" ;;
    esac
}

# 结果行拆分：把一条 "status|module|id|title|observed|threshold|advice"
# 拆进全局 OB_F1..OB_F7，避免为每一行 fork 一个 awk。
OB_F1=""; OB_F2=""; OB_F3=""; OB_F4=""; OB_F5=""; OB_F6=""; OB_F7=""
ob_result_split() {
    local rest="$1"
    OB_F1="${rest%%|*}"; rest="${rest#*|}"
    OB_F2="${rest%%|*}"; rest="${rest#*|}"
    OB_F3="${rest%%|*}"; rest="${rest#*|}"
    OB_F4="${rest%%|*}"; rest="${rest#*|}"
    OB_F5="${rest%%|*}"; rest="${rest#*|}"
    OB_F6="${rest%%|*}"; rest="${rest#*|}"
    OB_F7="$rest"
    return 0
}

# ---------------------------------------------------------------- 默认配置 ----
ob_conf_defaults() {
    # 根路径：允许指向 fixture，便于在容器/测试中模拟真实系统
    OB_CFG_PROC_ROOT="${OPSBOX_PROC_ROOT:-/proc}"
    OB_CFG_SYS_ROOT="${OPSBOX_SYS_ROOT:-/sys}"
    OB_CFG_ETC_ROOT="${OPSBOX_ETC_ROOT:-/etc}"
    OB_CFG_VAR_ROOT="${OPSBOX_VAR_ROOT:-/var}"
    OB_CFG_RUN_ROOT="${OPSBOX_RUN_ROOT:-/run}"

    # 通用
    OB_CFG_SAMPLE_INTERVAL="${OPSBOX_SAMPLE_INTERVAL:-1}"
    OB_CFG_TOP_N="${OPSBOX_TOP_N:-5}"
    OB_CFG_ENABLED_MODULES="system cpu memory disk network service log security"
    OB_CFG_DISABLE_CHECKS=""       # 逗号分隔，可写 "disk.inode" 或 "inode"
    OB_CFG_REPORT_TITLE="Linux 服务器巡检报告"

    # CPU
    OB_CFG_LOAD_WARN_MULT="1.0"
    OB_CFG_LOAD_CRIT_MULT="2.0"
    OB_CFG_CPU_WARN="85"
    OB_CFG_CPU_CRIT="95"
    OB_CFG_IOWAIT_WARN="10"
    OB_CFG_IOWAIT_CRIT="25"
    OB_CFG_CPU_STEAL_WARN="5"
    OB_CFG_CPU_STEAL_CRIT="15"

    # 内存
    OB_CFG_MEM_WARN="85"
    OB_CFG_MEM_CRIT="95"
    OB_CFG_SWAP_WARN="50"
    OB_CFG_SWAP_CRIT="80"
    OB_CFG_MEMAVAIL_MIN_MB="256"
    OB_CFG_MEMAVAIL_CRIT_MB="64"
    OB_CFG_DIRTY_WARN_MB="512"
    OB_CFG_DIRTY_CRIT_MB="2048"
    OB_CFG_COMMIT_WARN="90"
    OB_CFG_COMMIT_CRIT="100"
    OB_CFG_ZOMBIE_WARN="10"
    OB_CFG_ZOMBIE_CRIT="50"

    # 磁盘
    OB_CFG_DISK_WARN="80"
    OB_CFG_DISK_CRIT="90"
    OB_CFG_INODE_WARN="80"
    OB_CFG_INODE_CRIT="90"
    OB_CFG_DISK_LAT_WARN="20"
    OB_CFG_DISK_LAT_CRIT="100"
    OB_CFG_DISK_MIN_SIZE_MB="100"
    OB_CFG_DISK_EXCLUDE_FS="tmpfs|devtmpfs|squashfs|overlay|proc|sysfs|cgroup|cgroup2|autofs|debugfs|tracefs|ramfs|fusectl|mqueue|hugetlbfs|securityfs|pstore|configfs|bpf|binfmt_misc|nsfs"
    OB_CFG_DISK_EXCLUDE_MNT="/run|/dev|/sys|/proc|/snap"
    # 只读挂载检查专用的排除列表：只读介质本来就是 ro，不该告警
    OB_CFG_DISK_READONLY_EXCLUDE_FS="iso9660|udf|squashfs|erofs|romfs|vfat|msdos|exfat|ntfs"

    # 网络
    OB_CFG_TCP_WARN="5000"
    OB_CFG_TCP_CRIT="10000"
    OB_CFG_TIMEWAIT_WARN="3000"
    OB_CFG_TIMEWAIT_CRIT="8000"
    OB_CFG_CLOSEWAIT_WARN="500"
    OB_CFG_CLOSEWAIT_CRIT="2000"
    OB_CFG_CONNTRACK_WARN="80"
    OB_CFG_CONNTRACK_CRIT="95"
    OB_CFG_IFACE_ERR_RATE_WARN="0.01"
    OB_CFG_IFACE_ERR_RATE_CRIT="0.1"
    OB_CFG_IFACE_DROP_RATE_WARN="0.01"
    OB_CFG_IFACE_DROP_RATE_CRIT="0.1"

    # 服务
    OB_CFG_FAILED_UNIT_WARN="1"
    OB_CFG_FAILED_UNIT_CRIT="3"
    OB_CFG_REQUIRED_UNITS=""        # 形如 "sshd,nginx,docker"
    OB_CFG_OPTIONAL_UNITS=""        # 形如 "chronyd,crond"

    # 日志
    OB_CFG_LOG_SINCE="1 hour ago"
    OB_CFG_LOG_ERR_WARN="50"
    OB_CFG_LOG_ERR_CRIT="500"
    OB_CFG_LOG_SCAN_BYTES="2097152"   # 无 journalctl 时，每个日志文件扫描的尾部字节数
    OB_CFG_LOG_FILES="/var/log/syslog /var/log/messages /var/log/kern.log"
    OB_CFG_LOG_BIG_MB_WARN="512"
    OB_CFG_LOG_BIG_MB_CRIT="2048"
    OB_CFG_CRASH_DUMP_DIRS="/var/crash /var/spool/abrt"
    OB_CFG_CRASH_WARN="1"
    OB_CFG_CRASH_CRIT="5"

    # 安全
    OB_CFG_SEC_SUID_ENABLE="0"
    OB_CFG_SEC_SUID_ROOT="/usr/bin"
    OB_CFG_SEC_SUID_MAX="500"
    OB_CFG_SSHD_WEAK_PERMITROOT="1"   # 1 = PermitRootLogin yes 视为问题

    # 系统
    OB_CFG_UPTIME_MIN_WARN="600"
    OB_CFG_FD_WARN="80"
    OB_CFG_FD_CRIT="90"
    OB_CFG_PID_WARN="80"
    OB_CFG_PID_CRIT="95"
    OB_CFG_OOM_WARN="1"
    OB_CFG_OOM_CRIT="5"
    return 0
}

# 加载配置：内置默认 <- 系统级 <- 用户级 <- 命令行指定
# 传入的路径若不存在或不可读，视为致命错误（调用方负责只传确实存在的默认路径）。
ob_load_conf() {
    local f
    for f in "$@"; do
        [ -n "$f" ] || continue
        if [ -r "$f" ]; then
            # shellcheck disable=SC1090
            . "$f" || ob_die "配置加载失败：$f"
            ob_debug "已加载配置：$f"
        else
            ob_die "配置文件不存在或不可读：$f"
        fi
    done
    return 0
}

# ---------------------------------------------------------------- 环境探测 ----
OB_ENV_OS=""
OB_ENV_OS_PRETTY=""
OB_ENV_KERNEL=""
OB_ENV_ARCH=""
OB_ENV_HOSTNAME=""
OB_ENV_VIRT=""
OB_ENV_CONTAINER=""

ob_detect_env() {
    OB_ENV_HOSTNAME="$(hostname 2>/dev/null || cat "${OB_CFG_PROC_ROOT}/sys/kernel/hostname" 2>/dev/null || printf 'unknown')"
    OB_ENV_KERNEL="$(uname -r 2>/dev/null || printf 'unknown')"
    OB_ENV_ARCH="$(uname -m 2>/dev/null || printf 'unknown')"

    if [ -r "${OB_CFG_ETC_ROOT}/os-release" ]; then
        OB_ENV_OS_PRETTY="$(LC_ALL=C sed -n 's/^PRETTY_NAME="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "${OB_CFG_ETC_ROOT}/os-release" | head -n1)"
        OB_ENV_OS="$(LC_ALL=C sed -n 's/^ID="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "${OB_CFG_ETC_ROOT}/os-release" | head -n1)"
    fi
    [ -n "$OB_ENV_OS_PRETTY" ] || OB_ENV_OS_PRETTY="$(uname -s 2>/dev/null || printf 'unknown')"
    [ -n "$OB_ENV_OS" ] || OB_ENV_OS="unknown"

    # 虚拟化类型
    if ob_have systemd-detect-virt; then
        OB_ENV_VIRT="$(systemd-detect-virt 2>/dev/null || printf 'none')"
    elif [ -r "${OB_CFG_PROC_ROOT}/1/environ" ] && LC_ALL=C tr '\0' '\n' < "${OB_CFG_PROC_ROOT}/1/environ" 2>/dev/null | grep -q '^container='; then
        OB_ENV_VIRT="container"
    else
        OB_ENV_VIRT="unknown"
    fi

    # 容器判定（用于跳过部分无意义的检查）
    OB_ENV_CONTAINER="no"
    if [ -f "${OB_CFG_RUN_ROOT}/.dockerenv" ] || [ -f "${OB_CFG_RUN_ROOT}/.containerenv" ]; then
        OB_ENV_CONTAINER="yes"
    elif [ -r "${OB_CFG_PROC_ROOT}/1/cgroup" ] && LC_ALL=C grep -qE '(docker|kubepods|lxc|containerd)' "${OB_CFG_PROC_ROOT}/1/cgroup" 2>/dev/null; then
        OB_ENV_CONTAINER="yes"
    elif [ -r "${OB_CFG_PROC_ROOT}/1/environ" ] && LC_ALL=C tr '\0' '\n' < "${OB_CFG_PROC_ROOT}/1/environ" 2>/dev/null | grep -q '^container='; then
        OB_ENV_CONTAINER="yes"
    fi
    return 0
}

ob_uptime_seconds() {
    local f="${OB_CFG_PROC_ROOT}/uptime" v=""
    if [ -r "$f" ]; then
        v="$(LC_ALL=C awk '{printf "%d", $1}' "$f" 2>/dev/null)"
    fi
    ob_is_int "$v" || v="0"
    printf '%s' "$v"
}

ob_now_epoch() { date +%s 2>/dev/null || printf '0'; }

# 单引号安全的 JSON 字符串转义（不依赖 jq / python）
# 输出 JSON 时每个字段都要转义一次，几十条结果就是几百次调用，
# 因此同样用纯 bash 实现。注意反斜杠必须最先替换，否则会把后面
# 引入的转义反斜杠又转义一遍。
ob_json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\t'/\\t}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\n'/\\n}"
    printf '%s' "$s"
}

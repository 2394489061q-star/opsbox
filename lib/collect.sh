#!/usr/bin/env bash
# ==============================================================================
# opsbox :: lib/collect.sh
# 采集层：只读地获取系统事实。
#
# 设计原则
#   1. 优先直读 /proc、/sys，其次才调用外部命令——外部命令缺失不会让检查崩掉。
#   2. 所有根路径来自 $OB_CFG_*_ROOT，可用 fixture 目录模拟真实系统（便于测试/CI）。
#   3. 所有外部命令都可通过 $OB_CMD_<NAME> 覆盖，便于注入假数据。
#   4. 本层不判定、不输出，只返回原始数值；判定归 lib/checks.sh。
# ==============================================================================

# ------------------------------------------------------------------ CPU ----
# 输出： total idle iowait steal   （单位：jiffies 累计值）
ob_cpu_snapshot() {
    local f="${OB_CFG_PROC_ROOT}/stat"
    [ -r "$f" ] || return 1
    LC_ALL=C awk '
        $1 == "cpu" {
            total = 0
            for (i = 2; i <= NF; i++) total += $i
            printf "%s %s %s %s", total, $5 + $6, $6, ($9 == "" ? 0 : $9)
            found = 1
            exit
        }
        END { exit(found ? 0 : 1) }
    ' "$f" 2>/dev/null
}

# 采样 interval 秒，输出： cpu使用率 iowait使用率 steal使用率
# 采样失败（无 /proc/stat）时返回非零。
ob_cpu_usage_triple() {
    local iv="${1:-1}"
    local s1 s2 t1 i1 w1 st1 t2 i2 w2 st2
    s1="$(ob_cpu_snapshot)" || return 1
    [ -n "$s1" ] || return 1

    if ob_is_num "$iv" && [ "$iv" != "0" ]; then
        sleep "$iv"
    fi

    s2="$(ob_cpu_snapshot)" || return 1
    [ -n "$s2" ] || return 1

    set -- $s1; t1="$1"; i1="$2"; w1="$3"; st1="$4"
    set -- $s2; t2="$1"; i2="$2"; w2="$3"; st2="$4"

    LC_ALL=C awk -v t1="$t1" -v i1="$i1" -v w1="$w1" -v s1="$st1" \
                 -v t2="$t2" -v i2="$i2" -v w2="$w2" -v s2="$st2" 'BEGIN {
        dt = t2 - t1
        if (dt <= 0) { print "0.00 0.00 0.00"; exit }
        busy = dt - (i2 - i1); if (busy < 0) busy = 0
        iow  = (w2 - w1);     if (iow  < 0) iow  = 0
        stl  = (s2 - s1);     if (stl  < 0) stl  = 0
        printf "%.2f %.2f %.2f", busy * 100 / dt, iow * 100 / dt, stl * 100 / dt
    }'
}

# 输出： load1 load5 load15 running_procs total_procs
ob_loadavg() {
    local f="${OB_CFG_PROC_ROOT}/loadavg"
    [ -r "$f" ] || return 1
    LC_ALL=C awk '{
        split($4, p, "/")
        printf "%s %s %s %s %s", $1, $2, $3, p[1], p[2]
    }' "$f" 2>/dev/null
}

# 逻辑 CPU 数：优先 /proc/cpuinfo，其次 nproc，最后按 /sys 设备目录数
ob_cpu_count() {
    local f="${OB_CFG_PROC_ROOT}/cpuinfo" n=0
    if [ -r "$f" ]; then
        n="$(LC_ALL=C grep -c '^processor' "$f" 2>/dev/null)"
    fi
    if ! ob_is_int "$n" || [ "$n" -eq 0 ]; then
        if [ -r "${OB_CFG_PROC_ROOT}/stat" ]; then
            n="$(LC_ALL=C awk '/^cpu[0-9]+/ { c++ } END { print c + 0 }' "${OB_CFG_PROC_ROOT}/stat" 2>/dev/null)"
        fi
    fi
    if ! ob_is_int "$n" || [ "$n" -eq 0 ]; then
        if ob_have nproc; then
            n="$(nproc 2>/dev/null)"
        fi
    fi
    if ! ob_is_int "$n" || [ "$n" -eq 0 ]; then
        n=1
    fi
    printf '%s' "$n"
}

# 物理 CPU 插槽数（拿不到时为 0）
ob_cpu_sockets() {
    local f="${OB_CFG_PROC_ROOT}/cpuinfo"
    [ -r "$f" ] || { printf '0'; return 0; }
    LC_ALL=C awk -F: '
        /^physical id/ { gsub(/ /, "", $2); seen[$2] = 1 }
        END { n = 0; for (k in seen) n++; print n }
    ' "$f" 2>/dev/null
}

# 型号名
ob_cpu_model() {
    local f="${OB_CFG_PROC_ROOT}/cpuinfo"
    [ -r "$f" ] || { printf 'unknown'; return 0; }
    LC_ALL=C awk -F: '
        /^(model name|Model|Hardware|cpu model)/ {
            gsub(/^[ \t]+/, "", $2); print $2; found = 1; exit
        }
        END { if (!found) print "unknown" }
    ' "$f" 2>/dev/null
}

# 上下文切换与中断（用于判断系统抖动）
ob_cpu_events() {
    local f="${OB_CFG_PROC_ROOT}/stat"
    [ -r "$f" ] || return 1
    LC_ALL=C awk '
        /^ctxt/ { c = $2 } /^intr/ { i = $2 } /^procs_running/ { r = $2 }
        END { printf "%s %s %s", (c == "" ? 0 : c), (i == "" ? 0 : i), (r == "" ? 0 : r) }
    ' "$f" 2>/dev/null
}

# ------------------------------------------------------------------ 内存 ----
# 输出： total_kb available_kb free_kb buffers_kb cached_kb
ob_mem_basic() {
    local f="${OB_CFG_PROC_ROOT}/meminfo"
    [ -r "$f" ] || return 1
    LC_ALL=C awk '
        /^MemTotal:/     { t = $2 }
        /^MemFree:/      { f = $2 }
        /^MemAvailable:/ { a = $2 }
        /^Buffers:/      { b = $2 }
        /^Cached:/       { c = $2 }
        END {
            if (a == "") a = f + b + c
            printf "%s %s %s %s %s", t + 0, a + 0, f + 0, b + 0, c + 0
        }
    ' "$f" 2>/dev/null
}

# 输出： swaptotal_kb swapfree_kb dirty_kb writeback_kb commitlimit_kb committed_kb
ob_mem_extra() {
    local f="${OB_CFG_PROC_ROOT}/meminfo"
    [ -r "$f" ] || return 1
    LC_ALL=C awk '
        /^SwapTotal:/    { st = $2 }
        /^SwapFree:/     { sf = $2 }
        /^Dirty:/        { d  = $2 }
        /^Writeback:/    { w  = $2 }
        /^CommitLimit:/  { cl = $2 }
        /^Committed_AS:/ { ca = $2 }
        END { printf "%s %s %s %s %s %s", st + 0, sf + 0, d + 0, w + 0, cl + 0, ca + 0 }
    ' "$f" 2>/dev/null
}

# 内存使用率（业界口径）： used = MemTotal - MemAvailable
ob_mem_used_pct() {
    local line t a
    line="$(ob_mem_basic)" || return 1
    [ -n "$line" ] || return 1
    set -- $line; t="$1"; a="$2"
    ob_cmp "$t" ">" "0" || { printf '0.00'; return 0; }
    ob_div "$((t - a))" "$t" 2
}

# 内存占用最高的 N 个进程：输出 "pid rss_kb comm" 每行一条
# 直读 /proc，不依赖 ps；每进程零 fork，百级进程数下耗时可忽略。
ob_top_mem_procs() {
    local n="${1:-5}"
    [ -d "${OB_CFG_PROC_ROOT}" ] || return 1
    ob_proc_rss_list | LC_ALL=C sort -k2,2 -rn | head -n "$n"
}

# 内部：枚举所有进程的 "pid rss_kb comm"
ob_proc_rss_list() {
    local procdir="${OB_CFG_PROC_ROOT}"
    local d pid line comm rss
    for d in "$procdir"/[0-9]*; do
        [ -r "$d/status" ] || continue
        pid="${d##*/}"
        comm="?"; rss=""
        while IFS= read -r line; do
            case "$line" in
                Name:*)  comm="${line#Name:}"; comm="$(ob_trim "$comm")" ;;
                VmRSS:*) rss="${line#VmRSS:}"; rss="${rss%%kB*}"; rss="$(ob_trim "$rss")"; break ;;
            esac
        done < "$d/status"
        [ -n "$rss" ] || continue
        ob_is_int "$rss" || continue
        printf '%s %s %s\n' "$pid" "$rss" "$comm"
    done
    return 0
}

# 僵尸进程数量（零 fork）
ob_zombie_count() {
    local procdir="${OB_CFG_PROC_ROOT}" d stat_line state n=0
    [ -d "$procdir" ] || { printf '0'; return 0; }
    for d in "$procdir"/[0-9]*; do
        [ -r "$d/stat" ] || continue
        IFS= read -r stat_line < "$d/stat" 2>/dev/null || continue
        # 进程名可能含空格与括号，取最后一个 ") " 之后的第一个字段即为状态
        state="${stat_line##*) }"
        state="${state%% *}"
        [ "$state" = "Z" ] && n=$((n + 1))
    done
    printf '%s' "$n"
}

# 进程总数
ob_proc_count() {
    local procdir="${OB_CFG_PROC_ROOT}" d n=0
    [ -d "$procdir" ] || { printf '0'; return 0; }
    for d in "$procdir"/[0-9]*; do
        [ -d "$d" ] && n=$((n + 1))
    done
    printf '%s' "$n"
}

# ------------------------------------------------------------------ 磁盘 ----
# 输出每行： use_pct total_kb used_kb avail_kb mountpoint
# 挂载点中的空格按 /proc/mounts 惯例转义成 \040，保证每行字段数固定。
ob_collect_df() {
    local bin="${OB_CMD_DF:-df}"
    "$bin" -P -k "$@" 2>/dev/null | LC_ALL=C awk '
        NR == 1 { next }
        NF >= 6 {
            mount = $6
            for (i = 7; i <= NF; i++) mount = mount "\\040" $i
            pct = $5; sub(/%$/, "", pct)
            printf "%s %s %s %s %s\n", pct, $2, $3, $4, mount
        }
    '
}

# inode： 输出每行 " iuse_pct iused ifree mountpoint "
ob_collect_df_inode() {
    local bin="${OB_CMD_DF:-df}"
    "$bin" -P -k -i "$@" 2>/dev/null | LC_ALL=C awk '
        NR == 1 { next }
        NF >= 6 {
            mount = $6
            for (i = 7; i <= NF; i++) mount = mount "\\040" $i
            pct = $5; sub(/%$/, "", pct)
            printf "%s %s %s %s\n", pct, $3, $4, mount
        }
    '
}

# 文件系统类型表： 输出 " mountpoint fstype "
# 来源优先级： findmnt > /proc/mounts > /etc/mtab
ob_mount_fstypes() {
    if [ -r "${OB_CFG_PROC_ROOT}/mounts" ]; then
        LC_ALL=C awk '{ print $2, $3 }' "${OB_CFG_PROC_ROOT}/mounts" 2>/dev/null
    elif [ -r "${OB_CFG_ETC_ROOT}/mtab" ]; then
        LC_ALL=C awk '{ print $2, $3 }' "${OB_CFG_ETC_ROOT}/mtab" 2>/dev/null
    fi
}

# 文件句柄用量： 输出 " allocated max used_pct "
ob_file_handles() {
    local f="${OB_CFG_PROC_ROOT}/sys/fs/file-nr"
    [ -r "$f" ] || return 1
    LC_ALL=C awk '{
        alloc = $1; unused = $2; max = $3
        used = alloc - unused
        pct = (max > 0) ? (used * 100 / max) : 0
        printf "%s %s %.2f", used, max, pct
    }' "$f" 2>/dev/null
}

# 磁盘 IO 累计值（/proc/diskstats）： 输出 " read_sectors write_sectors io_ms "
ob_diskstats_totals() {
    local f="${OB_CFG_PROC_ROOT}/diskstats"
    [ -r "$f" ] || return 1
    LC_ALL=C awk '
        {
            # 只统计整盘（跳过分区：名字以数字结尾且父设备存在的常见情况由调用方过滤）
            rs += $6; ws += $10; ms += $13
        }
        END { printf "%s %s %s", rs + 0, ws + 0, ms + 0 }
    ' "$f" 2>/dev/null
}

# ------------------------------------------------------------------ 网络 ----
# 输出每行： " iface rx_bytes tx_bytes rx_errs tx_errs rx_drop tx_drop rx_pkts tx_pkts "
ob_netdev_stats() {
    local f="${OB_CFG_PROC_ROOT}/net/dev"
    [ -r "$f" ] || return 1
    LC_ALL=C awk '
        NR <= 2 { next }
        {
            split($0, a, ":")
            if (a[1] == "") next
            iface = a[1]; gsub(/ /, "", iface)
            n = split(a[2], v, " ")
            c = 0
            for (i = 1; i <= n; i++) if (v[i] != "") { c++; f[c] = v[i] }
            # 字段： rx_bytes rx_packets rx_errs rx_drop ... tx_bytes tx_packets tx_errs tx_drop
            printf "%s %s %s %s %s %s %s %s %s\n", \
                iface, f[1], f[9], f[3], f[11], f[4], f[12], f[2], f[10]
        }
    ' "$f" 2>/dev/null
}

# 输出每行： " iface ipv4_addr "
# 只依赖 iproute2；拿不到就返回空（不猜）。
ob_iface_addrs() {
    if ob_have ip; then
        ip -o -4 addr show 2>/dev/null | LC_ALL=C awk '{ print $2, $4 }'
        return 0
    fi
    return 1
}

# TCP 状态计数： 输出每行 " STATE count "
# 直读 /proc/net/tcp 与 tcp6，state 是十六进制。
ob_tcp_state_counts() {
    local f
    {
        [ -r "${OB_CFG_PROC_ROOT}/net/tcp" ]  && LC_ALL=C awk 'NR > 1 { print $4 }' "${OB_CFG_PROC_ROOT}/net/tcp"
        [ -r "${OB_CFG_PROC_ROOT}/net/tcp6" ] && LC_ALL=C awk 'NR > 1 { print $4 }' "${OB_CFG_PROC_ROOT}/net/tcp6"
    } 2>/dev/null | LC_ALL=C awk '
        {
            s = toupper($1)
            name = "OTHER"
            if      (s == "01") name = "ESTABLISHED"
            else if (s == "02") name = "SYN_SENT"
            else if (s == "03") name = "SYN_RECV"
            else if (s == "04") name = "FIN_WAIT1"
            else if (s == "05") name = "FIN_WAIT2"
            else if (s == "06") name = "TIME_WAIT"
            else if (s == "07") name = "CLOSE"
            else if (s == "08") name = "CLOSE_WAIT"
            else if (s == "09") name = "LAST_ACK"
            else if (s == "0A") name = "LISTEN"
            else if (s == "0B") name = "CLOSING"
            count[name]++
            total++
        }
        END {
            for (k in count) printf "%s %d\n", k, count[k]
            printf "TOTAL %d\n", total + 0
        }
    '
}

ob_tcp_state_get() { # <state> [counts_string]
    local want="$1" counts="${2:-}"
    [ -n "$counts" ] || counts="$(ob_tcp_state_counts)"
    printf '%s\n' "$counts" | LC_ALL=C awk -v w="$want" '$1 == w { print $2; found = 1; exit } END { if (!found) print 0 }'
}

# 监听端口： 输出每行 " proto addr:port "
# 优先 ss（能显示进程），否则解析 /proc/net/tcp。
ob_listen_ports() {
    if [ -z "${OB_CMD_SS:-}" ] && ob_have ss; then
        ss -H -lntu 2>/dev/null | LC_ALL=C awk '{
            proto = $1
            local = $5
            if (local == "") next
            printf "%s %s\n", proto, local
        }' | sort -u
        return 0
    fi
    if [ -n "${OB_CMD_SS:-}" ]; then
        "${OB_CMD_SS}" -H -lntu 2>/dev/null | LC_ALL=C awk '{ printf "%s %s\n", $1, $5 }' | sort -u
        return 0
    fi
    ob_listen_ports_from_proc
}

ob_listen_ports_from_proc() {
    local f proto
    for f in "${OB_CFG_PROC_ROOT}/net/tcp" "${OB_CFG_PROC_ROOT}/net/tcp6" \
             "${OB_CFG_PROC_ROOT}/net/udp" "${OB_CFG_PROC_ROOT}/net/udp6"; do
        [ -r "$f" ] || continue
        case "$f" in
            *tcp6) proto="tcp6" ;; *tcp) proto="tcp" ;;
            *udp6) proto="udp6" ;; *udp) proto="udp" ;;
        esac
        # 注意：不使用 gawk 专有的 strtonum，手写 hex 解析以兼容 mawk/busybox awk。
        LC_ALL=C awk -v proto="$proto" '
            function h2d(h,   i, c, d, n) {
                n = 0
                for (i = 1; i <= length(h); i++) {
                    c = toupper(substr(h, i, 1))
                    d = index("0123456789ABCDEF", c) - 1
                    if (d < 0) return -1
                    n = n * 16 + d
                }
                return n
            }
            NR > 1 {
                state = toupper($4)
                if (proto ~ /^tcp/ && state != "0A") next
                split($2, a, ":")
                port = h2d(a[2])
                if (port < 0) next
                printf "%s *:%d\n", proto, port
            }
        ' "$f" 2>/dev/null
    done | sort -u
}

# 默认路由信息（best effort）
ob_default_routes() {
    if ob_have ip; then
        ip -4 route show default 2>/dev/null
    elif [ -r "${OB_CFG_PROC_ROOT}/net/route" ]; then
        LC_ALL=C awk '$2 == "00000000" { print "default via", $3, "dev", $1 }' "${OB_CFG_PROC_ROOT}/net/route" 2>/dev/null
    fi
}

# 内核 TCP 内存压力
ob_tcp_mem_pressure() {
    local f="${OB_CFG_PROC_ROOT}/net/sockstat"
    [ -r "$f" ] || return 1
    LC_ALL=C awk '
        /^TCP:/ {
            for (i = 2; i <= NF; i += 2) m[$i] = $(i + 1)
            inuse = m["inuse"] + 0
            printf "%s %s", inuse, m["tw"] + 0
        }
    ' "$f" 2>/dev/null
}

# ------------------------------------------------------------------ 服务 ----
ob_systemd_available() {
    [ -d "${OB_CFG_RUN_ROOT}/systemd/system" ] || ob_have systemctl
}

# 输出每行： " unit load active sub description "
ob_systemd_failed_units() {
    local bin="${OB_CMD_SYSTEMCTL:-systemctl}"
    "$bin" --no-legend --no-pager --plain list-units --state=failed 2>/dev/null | LC_ALL=C awk '
        NF >= 4 && $1 ~ /\./ {
            desc = ""
            for (i = 5; i <= NF; i++) desc = desc (i > 5 ? " " : "") $i
            printf "%s %s %s %s %s\n", $1, $2, $3, $4, desc
        }
    '
}

ob_systemd_unit_state() { # <unit>
    local bin="${OB_CMD_SYSTEMCTL:-systemctl}" unit="$1"
    "$bin" is-active "$unit" 2>/dev/null | head -n1
}

ob_systemd_unit_enabled() { # <unit>
    local bin="${OB_CMD_SYSTEMCTL:-systemctl}" unit="$1"
    "$bin" is-enabled "$unit" 2>/dev/null | head -n1
}

# ------------------------------------------------------------------ 系统 ----
ob_time_sync_status() {
    local bin="${OB_CMD_TIMEDATECTL:-timedatectl}"
    if ob_have "$bin" || [ -n "${OB_CMD_TIMEDATECTL:-}" ]; then
        "$bin" show 2>/dev/null | LC_ALL=C awk -F= '
            /^NTPSynchronized=/ { sync = $2 }
            /^NTP=/ { ntp = $2 }
            END { printf "%s %s", (sync == "" ? "unknown" : sync), (ntp == "" ? "unknown" : ntp) }
        '
        return 0
    fi
    if ob_have chronyc; then
        if chronyc tracking >/dev/null 2>&1; then printf 'yes yes'; else printf 'no no'; fi
        return 0
    fi
    printf 'unknown unknown'
}

ob_kernel_param() { # <path-relative-to-/proc/sys>
    local f="${OB_CFG_PROC_ROOT}/sys/$1"
    [ -r "$f" ] || return 1
    LC_ALL=C head -n1 "$f" 2>/dev/null | tr -d '\n'
    return 0
}

# Swap 是否使用（用于容器内跳过）
ob_swap_enabled() {
    local line st
    line="$(ob_mem_extra 2>/dev/null)" || return 1
    set -- $line
    st="${1:-0}"
    ob_is_int "$st" || st=0
    [ "$st" -gt 0 ]
}

# 内核是否有 OOM 记录
ob_oom_events() {
    local bin="${OB_CMD_JOURNALCTL:-journalctl}" n=""
    if [ -n "${OB_CMD_JOURNALCTL:-}" ] || ob_have journalctl; then
        n="$("$bin" --no-pager -k --since "${OB_CFG_LOG_SINCE}" 2>/dev/null \
            | LC_ALL=C grep -ciE 'out of memory|oom-killer|killed process' 2>/dev/null)"
        ob_is_int "$n" || n=0
        printf '%s' "$n"
        return 0
    fi
    if [ -r "${OB_CFG_VAR_ROOT}/log/messages" ]; then
        n="$(LC_ALL=C tail -c "${OB_CFG_LOG_SCAN_BYTES}" "${OB_CFG_VAR_ROOT}/log/messages" 2>/dev/null \
            | LC_ALL=C grep -ciE 'out of memory|oom-killer|killed process' 2>/dev/null)"
        ob_is_int "$n" || n=0
        printf '%s' "$n"
        return 0
    fi
    printf '0'
}

# ------------------------------------------------------------------ 日志 ----
# 统计 journal 中指定优先级以上的条目数
ob_journal_error_count() {
    local bin="${OB_CMD_JOURNALCTL:-journalctl}" n=""
    if ob_have "$bin"; then
        n="$("$bin" --no-pager -p err --since "${OB_CFG_LOG_SINCE}" 2>/dev/null \
            | LC_ALL=C grep -c '^[A-Z][a-z][a-z] [0-9]' 2>/dev/null)"
        ob_is_int "$n" || n=0
        printf '%s' "$n"
        return 0
    fi
    printf 'unknown'
}

# 扫描传统日志文件尾部，统计 ERROR/PANIC 级别关键字
ob_logfile_error_count() {
    local f total=0 scanned=0
    for f in $OB_CFG_LOG_FILES; do
        [ -r "$f" ] || continue
        scanned=$((scanned + 1))
        local n
        n="$(LC_ALL=C tail -c "${OB_CFG_LOG_SCAN_BYTES}" "$f" 2>/dev/null \
             | LC_ALL=C grep -ciE '(error|crit|alert|emerg|panic|failed)' 2>/dev/null)"
        ob_is_int "$n" || n=0
        total=$((total + n))
    done
    [ "$scanned" -gt 0 ] || return 1
    printf '%s' "$total"
}

# 日志目录下最大的 N 个日志文件： 输出 " size_kb path "
ob_big_log_files() {
    local n="${1:-5}" dir="${OB_CFG_VAR_ROOT}/log"
    [ -d "$dir" ] || return 1
    LC_ALL=C find "$dir" -xdev -type f \
        \( -name '*.log' -o -name '*.log.*' -o -name 'messages' -o -name 'syslog' -o -name '*.err' \) \
        2>/dev/null \
        | head -n 500 \
        | while IFS= read -r f; do
            [ -r "$f" ] || continue
            sz="$(LC_ALL=C wc -c < "$f" 2>/dev/null | tr -d ' ')"
            ob_is_int "$sz" || sz=0
            printf '%s %s\n' "$((sz / 1024))" "$f"
        done | sort -rn | head -n "$n"
}

# crash dump 目录中的条目数
# 返回非零表示「一个配置的目录都不存在」，调用方据此区分「没有崩溃」与「查不到」。
ob_crash_dumps() {
    local d n total=0 found=0
    for d in $OB_CFG_CRASH_DUMP_DIRS; do
        [ -d "$d" ] || continue
        found=1
        n="$(LC_ALL=C ls -1 "$d" 2>/dev/null | LC_ALL=C wc -l | tr -d ' ')"
        ob_is_int "$n" || n=0
        total=$((total + n))
    done
    [ "$found" -eq 1 ] || return 1
    printf '%s' "$total"
}

# ------------------------------------------------------------------ 安全 ----
# UID 为 0 的账户（除 root 外的都值得警惕）
ob_uid0_accounts() {
    local f="${OB_CFG_ETC_ROOT}/passwd"
    [ -r "$f" ] || return 1
    LC_ALL=C awk -F: '$3 == 0 { print $1 }' "$f" 2>/dev/null
}

# 空密码账户（需要 root 才能读 /etc/shadow）
ob_empty_password_accounts() {
    local f="${OB_CFG_ETC_ROOT}/shadow"
    [ -r "$f" ] || return 1
    LC_ALL=C awk -F: '$2 == "" { print $1 }' "$f" 2>/dev/null
    return 0
}

# 可登录账户（shell 不是 nologin/false）
ob_login_shell_accounts() {
    local f="${OB_CFG_ETC_ROOT}/passwd"
    [ -r "$f" ] || return 1
    LC_ALL=C awk -F: '
        $7 !~ /(nologin|false|sync|shutdown|halt)$/ && $2 != "*" && $2 != "!" {
            printf "%s:%s\n", $1, $7
        }
    ' "$f" 2>/dev/null
}

# sshd 关键配置项
# 语义注意：真实 sshd 是「首次出现的值生效」（first match wins），
# sshd_config 里同一键写多次时，后面的会被忽略。因此这里必须取第一次匹配，
# 而不是逐行覆盖成最后一次——取错方向会让判断结果与实际行为完全相反。
ob_sshd_config_get() { # <Key>
    local key="$1" f found=""
    for f in "${OB_CFG_ETC_ROOT}/ssh/sshd_config" "${OB_CFG_ETC_ROOT}/sshd_config"; do
        [ -r "$f" ] || continue
        found="$(LC_ALL=C awk -v k="$key" '
            /^[ \t]*#/ { next }
            {
                line = $0
                sub(/^[ \t]+/, "", line)
                n = split(line, a, /[ \t]+/)
                if (tolower(a[1]) == tolower(k) && v == "") {
                    v = a[2]
                    gsub(/\r/, "", v)
                }
            }
            END { if (v != "") print v }
        ' "$f" 2>/dev/null)"
        [ -n "$found" ] && break
    done
    printf '%s' "$found"
}

# 防火墙状态：输出 " 机制 状态 "
ob_firewall_status() {
    if ob_have ufw; then
        local s
        s="$(ufw status 2>/dev/null | head -n1)"
        case "$s" in *active*) printf 'ufw active' ;; *inactive*) printf 'ufw inactive' ;; *) printf 'ufw unknown' ;; esac
        return 0
    fi
    if ob_have firewall-cmd; then
        if firewall-cmd --state >/dev/null 2>&1; then printf 'firewalld running'; else printf 'firewalld stopped'; fi
        return 0
    fi
    if ob_have nft; then
        local c
        c="$(nft list ruleset 2>/dev/null | LC_ALL=C wc -l | tr -d ' ')"
        ob_is_int "$c" || c=0
        if [ "$c" -gt 0 ]; then printf 'nftables active'; else printf 'nftables empty'; fi
        return 0
    fi
    if ob_have iptables; then
        local c
        c="$(iptables -S 2>/dev/null | LC_ALL=C wc -l | tr -d ' ')"
        ob_is_int "$c" || c=0
        if [ "$c" -gt 1 ]; then printf 'iptables active'; else printf 'iptables empty'; fi
        return 0
    fi
    printf 'none unknown'
}

# 强制访问控制状态
ob_mac_status() {
    if [ -r "${OB_CFG_SYS_ROOT}/fs/selinux/enforce" ]; then
        local v
        v="$(LC_ALL=C head -n1 "${OB_CFG_SYS_ROOT}/fs/selinux/enforce" 2>/dev/null | tr -d '\n')"
        if [ "$v" = "1" ]; then printf 'SELinux enforcing'; else printf 'SELinux permissive'; fi
        return 0
    fi
    if [ -d "${OB_CFG_SYS_ROOT}/kernel/security/apparmor" ]; then
        printf 'AppArmor present'
        return 0
    fi
    if ob_have getenforce; then
        getenforce 2>/dev/null | tr 'A-Z' 'a-z'
        return 0
    fi
    printf 'none'
}

# SUID/SGID 文件（可选、较慢）
ob_suid_files() {
    local root="${1:-/usr/bin}"
    [ -d "$root" ] || return 1
    LC_ALL=C find "$root" -xdev -type f \( -perm -4000 -o -perm -2000 \) 2>/dev/null
}

# 待重启标记（内核更新后未重启）
ob_reboot_required() {
    if [ -f "${OB_CFG_RUN_ROOT}/reboot-required" ]; then
        printf 'yes'
        return 0
    fi
    if [ -f "${OB_CFG_VAR_ROOT}/run/reboot-required" ]; then
        printf 'yes'
        return 0
    fi
    printf 'no'
}

# 是否有可用的包管理器（决定能否给升级建议）
ob_pkg_manager() {
    local m
    for m in apt-get dnf yum zypper apk pacman; do
        if ob_have "$m"; then printf '%s' "$m"; return 0; fi
    done
    printf 'unknown'
}

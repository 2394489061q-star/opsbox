#!/usr/bin/env bash
# ==============================================================================
# opsbox :: modules/10-system.sh
# 系统底座：标识、时间同步、待重启、句柄、PID、OOM、运行时长
#
# 这一模块回答的是"这台机器本身是否健康"。它很少直接报 CRIT，
# 但一旦报出来，通常都是别人查半天查不出的那种根因（时间漂移、
# 句柄耗尽、内核更新未生效）。
# ==============================================================================

ob_module_system() {
    OB_MODULE="system"

    # ---------------------------------------------------------- 主机标识 ----
    ob_ok "sys.identity" "主机标识" \
        "${OB_ENV_HOSTNAME} / ${OB_ENV_OS_PRETTY} / ${OB_ENV_KERNEL}" \
        "—" "-"

    # ---------------------------------------------------------- 运行时长 ----
    local up up_human
    up="$(ob_uptime_seconds)"
    up_human="$(ob_human_duration "$up")"
    if ob_is_int "$up" && [ "$up" -gt 0 ] && [ "$up" -lt "${OB_CFG_UPTIME_MIN_WARN:-600}" ]; then
        ob_warn "sys.uptime" "系统运行时长" "$up_human" "至少 ${OB_CFG_UPTIME_MIN_WARN:-600} 秒" \
            "机器刚重启过。若非计划内重启，请用 journalctl -b -1 查看上一次启动结束前的日志"
    else
        ob_ok "sys.uptime" "系统运行时长" "$up_human" "—" "-"
    fi

    # ---------------------------------------------------------- 时间同步 ----
    local sync ntp
    set -- $(ob_time_sync_status)
    sync="${1:-unknown}"; ntp="${2:-unknown}"
    case "$sync" in
        yes)
            ob_ok "sys.time_sync" "时间同步状态" "已同步（NTP=${ntp}）" "已同步" "-"
            ;;
        no)
            ob_warn "sys.time_sync" "时间同步状态" "未同步（NTP=${ntp}）" "已同步" \
                "时间漂移会导致日志时间线错乱、TLS 证书校验失败、集群选主异常。请启用 chronyd/systemd-timesyncd 并确认可达上游 NTP"
            ;;
        *)
            ob_unknown "sys.time_sync" "时间同步状态" "无法判定（缺少 timedatectl/chronyc）" "已同步" \
                "安装 systemd 或 chrony 后重试；也可手动对比 date 与上游时间源"
            ;;
    esac

    # ---------------------------------------------------------- 待重启 ----
    if [ "$OB_ENV_CONTAINER" = "yes" ]; then
        ob_unknown "sys.reboot_required" "待重启标记" "容器环境不适用" "无待重启标记" \
            "容器内没有重启语义，请在宿主机上执行本检查"
    else
        local rr
        rr="$(ob_reboot_required)"
        if [ "$rr" = "yes" ]; then
            ob_warn "sys.reboot_required" "待重启标记" "存在 /run/reboot-required" "无待重启标记" \
                "内核或关键库已升级但仍在运行旧版本，存在安全与兼容风险。请安排维护窗口重启"
        else
            ob_ok "sys.reboot_required" "待重启标记" "无待重启标记" "无待重启标记" "-"
        fi
    fi

    # ---------------------------------------------------------- 文件句柄 ----
    local fh used max pct
    fh="$(ob_file_handles 2>/dev/null || true)"
    if [ -n "$fh" ]; then
        set -- $fh; used="$1"; max="$2"; pct="$3"
        ob_check_threshold "sys.fd_usage" "文件句柄使用率" "$pct" \
            "${OB_CFG_FD_WARN:-80}" "${OB_CFG_FD_CRIT:-90}" high "%" \
            "已用 ${used}/${max}。句柄耗尽会直接表现为「Too many open files」并波及所有服务。先定位泄漏进程：lsof -nP | awk '{print \$1}' | sort | uniq -c | sort -rn | head，再上调 fs.file-max 与 limits.conf"
    else
        ob_unknown "sys.fd_usage" "文件句柄使用率" "无法读取 /proc/sys/fs/file-nr" "低于 ${OB_CFG_FD_WARN:-80}%" \
            "确认内核开启了 fs.file-nr 接口，或改用 /proc/<pid>/limits 汇总统计"
    fi

    # ---------------------------------------------------------- PID 用量 ----
    local pid_max procs pid_pct
    pid_max="$(ob_kernel_param "kernel/pid_max" 2>/dev/null || true)"
    procs="$(ob_proc_count)"
    if ob_is_int "$pid_max" && [ "$pid_max" -gt 0 ]; then
        pid_pct="$(ob_div "$procs" "$pid_max" 2)"
        # 换算成百分比
        pid_pct="$(LC_ALL=C awk -v p="$pid_pct" 'BEGIN { printf "%.2f", p * 100 }')"
        ob_check_threshold "sys.pid_usage" "PID 用量" "$pid_pct" \
            "${OB_CFG_PID_WARN:-80}" "${OB_CFG_PID_CRIT:-95}" high "%" \
            "当前进程数 ${procs}，pid_max=${pid_max}。PID 耗尽时 fork 会失败（Cannot allocate memory）。检查是否有进程风暴或 fork 炸弹"
    else
        ob_unknown "sys.pid_usage" "PID 用量" "无法读取 kernel.pid_max" "低于 ${OB_CFG_PID_WARN:-80}%" \
            "确认可以读取 /proc/sys/kernel/pid_max"
    fi

    # ---------------------------------------------------------- OOM 事件 ----
    local oom
    oom="$(ob_oom_events 2>/dev/null || printf 'unknown')"
    if ob_is_int "$oom"; then
        ob_check_threshold "sys.oom_events" "近期 OOM 事件" "$oom" \
            "${OB_CFG_OOM_WARN:-1}" "${OB_CFG_OOM_CRIT:-5}" high " 次" \
            "内核曾因内存不足杀进程。被杀的往往是数据库或缓存这类「看起来没崩但变慢了」的组件。请结合 dmesg -T | grep -i oom 定位被杀进程，并调整 limit 或加内存"
    else
        ob_unknown "sys.oom_events" "近期 OOM 事件" "无法采集" "0 次" \
            "需要 journalctl 或 /var/log/messages 可读；也可直接执行 dmesg -T | grep -i oom 人工确认"
    fi

    # ---------------------------------------------------------- 内核参数 ----
    local swappiness
    swappiness="$(ob_kernel_param "vm/swappiness" 2>/dev/null || true)"
    if ob_is_int "$swappiness"; then
        if [ "$swappiness" -gt 60 ]; then
            ob_warn "sys.kernel_swappiness" "内核 swappiness" "$swappiness" "建议 1~10（数据库场景）" \
                "swappiness 偏高会让内核更激进地把匿名页换出，导致数据库类服务出现不可预期的延迟抖动。数据库/缓存型服务建议设为 1~10"
        else
            ob_ok "sys.kernel_swappiness" "内核 swappiness" "$swappiness" "1~60" "-"
        fi
    fi

    local overcommit
    overcommit="$(ob_kernel_param "vm/overcommit_memory" 2>/dev/null || true)"
    if [ -n "$overcommit" ]; then
        case "$overcommit" in
            0|1)
                ob_ok "sys.kernel_overcommit" "内存超售策略" "overcommit_memory=${overcommit}" "0 或 1" "-"
                ;;
            2)
                ob_warn "sys.kernel_overcommit" "内存超售策略" "overcommit_memory=2（禁止超售）" "0 或 1" \
                    "禁止超售虽然能避免 OOM Killer，但会让 fork/mmap 在内存紧张时直接失败。若曾出现「Cannot allocate memory」而 free 显示还有内存，就是这个参数导致的"
                ;;
        esac
    fi

    return 0
}

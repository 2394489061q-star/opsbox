#!/usr/bin/env bash
# ==============================================================================
# opsbox :: modules/20-cpu.sh
# CPU 与负载：使用率、IO 等待、被抢占、负载比率、运行队列
#
# 判定思路：
#   CPU 使用率高本身不是故障——真正要区分的是「谁在等」。
#   用户态高 → 计算密集；iowait 高 → 磁盘或网络存储是瓶颈；
#   steal 高 → 宿主机超卖，你做什么优化都没用。
#   这三者的处置方式完全不同，所以必须拆成独立检查项。
# ==============================================================================

ob_module_cpu() {
    OB_MODULE="cpu"

    local ncpu
    ncpu="$(ob_cpu_count)"

    ob_ok "cpu.info" "CPU 概况" "${ncpu} 核 · $(ob_cpu_model)" "—" "-"

    # ---------------------------------------------------------- 使用率 ----
    local triple usage iowait steal
    triple="$(ob_cpu_usage_triple "${OB_CFG_SAMPLE_INTERVAL:-1}" 2>/dev/null || true)"

    if [ -n "$triple" ]; then
        set -- $triple
        usage="${1:-}"; iowait="${2:-}"; steal="${3:-}"
    fi

    if ob_is_num "${usage:-}"; then
        ob_check_threshold "cpu.usage" "CPU 使用率（采样 ${OB_CFG_SAMPLE_INTERVAL:-1}s）" "$usage" \
            "$OB_CFG_CPU_WARN" "$OB_CFG_CPU_CRIT" high "%" \
            "先确认是持续高位还是瞬时尖峰：top -o %CPU 看进程，pidstat -u 1 看趋势。若为持续高位，再判断是扩容还是优化"
    else
        ob_unknown "cpu.usage" "CPU 使用率" "无法采样 /proc/stat" "低于 ${OB_CFG_CPU_WARN}%" \
            "确认 /proc/stat 可读；容器内需挂载宿主 /proc 才能看到真实值"
    fi

    # ---------------------------------------------------------- iowait ----
    if ob_is_num "${iowait:-}"; then
        ob_check_threshold "cpu.iowait" "IO 等待占比" "$iowait" \
            "$OB_CFG_IOWAIT_WARN" "$OB_CFG_IOWAIT_CRIT" high "%" \
            "iowait 高说明 CPU 在等磁盘/网络存储，加 CPU 没用。用 iostat -x 1 看 %util 与 await，再用 iotop -o 定位进程；云盘场景优先怀疑 IOPS 被打满或突发额度耗尽"
    else
        ob_unknown "cpu.iowait" "IO 等待占比" "无法采样" "低于 ${OB_CFG_IOWAIT_WARN}%" \
            "确认 /proc/stat 可读"
    fi

    # ---------------------------------------------------------- steal ----
    if ob_is_num "${steal:-}"; then
        if ob_cmp "$steal" ">" "0.01"; then
            ob_check_threshold "cpu.steal" "CPU 被宿主机抢占" "$steal" \
                "$OB_CFG_CPU_STEAL_WARN" "$OB_CFG_CPU_STEAL_CRIT" high "%" \
                "steal 高意味着你的虚拟机被同宿主机的邻居抢了 CPU 时间，属于云厂商侧超卖。优化应用无效，应采集证据后向云厂商提工单或更换实例规格"
        else
            ob_ok "cpu.steal" "CPU 被宿主机抢占" "$steal%" "低于 ${OB_CFG_CPU_STEAL_WARN}%" "-"
        fi
    else
        ob_unknown "cpu.steal" "CPU 被宿主机抢占" "无法采样" "低于 ${OB_CFG_CPU_STEAL_WARN}%" \
            "确认 /proc/stat 可读；裸金属通常无此指标"
    fi

    # ---------------------------------------------------------- 负载 ----
    local load_line l1 l5 l15 running total
    load_line="$(ob_loadavg 2>/dev/null || true)"
    if [ -n "$load_line" ]; then
        set -- $load_line
        l1="${1:-}"; l5="${2:-}"; l15="${3:-}"; running="${4:-0}"; total="${5:-0}"
    fi

    if ob_is_num "${l1:-}"; then
        ob_check_ratio "cpu.load1" "1 分钟负载 / 核数" "$l1" "$ncpu" \
            "$OB_CFG_LOAD_WARN_MULT" "$OB_CFG_LOAD_CRIT_MULT" \
            "负载高于核数说明有任务在排队。结合 cpu.usage 与 cpu.iowait 判断是算力不足还是 IO 阻塞。注意运行队列包含不可中断睡眠（D 状态）进程，磁盘卡住同样会推高负载"
    else
        ob_unknown "cpu.load1" "1 分钟负载" "无法读取 /proc/loadavg" "低于 ${OB_CFG_LOAD_WARN_MULT}x" \
            "确认 /proc/loadavg 可读"
    fi

    if ob_is_num "${l15:-}"; then
        ob_check_ratio "cpu.load15" "15 分钟负载 / 核数" "$l15" "$ncpu" \
            "$OB_CFG_LOAD_WARN_MULT" "$OB_CFG_LOAD_CRIT_MULT" \
            "15 分钟负载持续偏高说明是长期趋势而非瞬时抖动，适合作为扩容决策依据"
    fi

    # ---------------------------------------------------------- 运行队列 ----
    if ob_is_int "${running:-}"; then
        local runq_warn runq_crit
        runq_warn="$(LC_ALL=C awk -v n="$ncpu" 'BEGIN { printf "%d", n * 2 }')"
        runq_crit="$(LC_ALL=C awk -v n="$ncpu" 'BEGIN { printf "%d", n * 4 }')"
        ob_check_threshold "cpu.runqueue" "运行队列长度" "$running" "$runq_warn" "$runq_crit" high " 个" \
            "就绪队列长度超过核数的 2 倍，说明 CPU 资源已明显不足。当前负载 ${l1:-?}/${l5:-?}/${l15:-?}，进程总数 ${total:-?}"
    else
        ob_unknown "cpu.runqueue" "运行队列长度" "无法采集" "低于 $((ncpu * 2)) 个" \
            "确认 /proc/stat 中 procs_running 字段可读"
    fi

    return 0
}

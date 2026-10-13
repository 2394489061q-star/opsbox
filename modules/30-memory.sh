#!/usr/bin/env bash
# ==============================================================================
# opsbox :: modules/30-memory.sh
# 内存与 Swap：使用率、可用余量、Swap 压力、脏页、超售、僵尸进程、Top 进程
#
# 关于口径：这里用 MemTotal - MemAvailable 计算已用内存。
# 不要用 free 的 "used" 列——它把可回收的 page cache 也算进去了，
# 在读了大量文件的机器上会误报 90%+，是最常见的误判来源。
# ==============================================================================

ob_module_memory() {
    OB_MODULE="memory"

    local mem t a f b c
    mem="$(ob_mem_basic 2>/dev/null || true)"
    if [ -z "$mem" ]; then
        ob_unknown "mem.used" "内存使用率" "无法读取 /proc/meminfo" "低于 ${OB_CFG_MEM_WARN}%" \
            "确认 /proc/meminfo 可读"
        return 0
    fi
    set -- $mem
    t="${1:-0}"; a="${2:-0}"; f="${3:-0}"; b="${4:-0}"; c="${5:-0}"

    ob_ok "mem.capacity" "内存容量" "总计 $(ob_human_bytes "$((t * 1024))") · 可回收缓存 $(ob_human_bytes "$(((b + c) * 1024))")" "—" "-"

    # ---------------------------------------------------------- 使用率 ----
    local used_kb used_pct
    used_kb=$((t - a))
    used_pct="$(ob_div "$used_kb" "$t" 2)"
    used_pct="$(LC_ALL=C awk -v p="$used_pct" 'BEGIN { printf "%.2f", p * 100 }')"

    ob_check_threshold "mem.used" "内存使用率" "$used_pct" \
        "$OB_CFG_MEM_WARN" "$OB_CFG_MEM_CRIT" high "%" \
        "口径为 (MemTotal - MemAvailable) / MemTotal，已排除可回收的 page cache。已用 $(ob_human_bytes "$((used_kb * 1024))")。请用 top -o %MEM 或 smem 定位占用方，注意区分常驻增长（泄漏）与缓存（正常）"

    # ---------------------------------------------------------- 绝对余量 ----
    local avail_mb
    avail_mb=$((a / 1024))
    ob_check_threshold "mem.available" "可用内存余量" "$avail_mb" \
        "${OB_CFG_MEMAVAIL_MIN_MB:-256}" "${OB_CFG_MEMAVAIL_CRIT_MB:-64}" low " MB" \
        "可用内存已接近枯竭，随时可能触发 OOM Killer。免费内存（MemFree）当前仅 $(ob_human_bytes "$((f * 1024))")，请立即确认是否有进程异常膨胀"

    # ---------------------------------------------------------- Swap ----
    local st sf dirty wb cl ca
    local extra
    extra="$(ob_mem_extra 2>/dev/null || true)"
    if [ -n "$extra" ]; then
        set -- $extra
        st="${1:-0}"; sf="${2:-0}"; dirty="${3:-0}"; wb="${4:-0}"; cl="${5:-0}"; ca="${6:-0}"

        if [ "$st" -le 0 ]; then
            ob_warn "mem.swap" "Swap 配置" "未启用 Swap" "建议配置少量 Swap" \
                "完全禁用 Swap 会在内存瞬时峰值时直接触发 OOM Killer。即使内存充足，也建议留 1~4GB Swap 作为缓冲（数据库场景可设 vm.swappiness=1）"
        else
            local swap_used_pct
            swap_used_pct="$(LC_ALL=C awk -v st="$st" -v sf="$sf" 'BEGIN {
                if (st <= 0) { printf "0.00"; exit }
                printf "%.2f", (st - sf) * 100 / st
            }')"
            ob_check_threshold "mem.swap" "Swap 使用率" "$swap_used_pct" \
                "$OB_CFG_SWAP_WARN" "$OB_CFG_SWAP_CRIT" high "%" \
                "Swap 已用 $(ob_human_bytes "$(((st - sf) * 1024))") / $(ob_human_bytes "$((st * 1024))")。持续换入换出会让服务延迟出现数量级抖动（swap thrashing）。用 vmstat 1 观察 si/so 列，非零即说明正在换页"
        fi

        # ------------------------------------------------------ 脏页 ----
        local dirty_mb wb_mb
        dirty_mb=$((dirty / 1024))
        wb_mb=$((wb / 1024))
        ob_check_threshold "mem.dirty" "脏页堆积" "$dirty_mb" \
            "${OB_CFG_DIRTY_WARN_MB:-512}" "${OB_CFG_DIRTY_CRIT_MB:-2048}" high " MB" \
            "脏页（待写回磁盘的数据）堆积到 ${dirty_mb}MB，正在回写 ${wb_mb}MB。这通常意味着后端存储写入跟不上，紧接着就是全系统卡顿。检查磁盘 IO 与 vm.dirty_ratio/vm.dirty_background_ratio"

        # ------------------------------------------------------ 超售 ----
        if ob_is_int "$cl" && [ "$cl" -gt 0 ]; then
            local commit_pct
            commit_pct="$(LC_ALL=C awk -v ca="$ca" -v cl="$cl" 'BEGIN { printf "%.2f", ca * 100 / cl }')"
            ob_check_threshold "mem.commit" "内存承诺比" "$commit_pct" \
                "${OB_CFG_COMMIT_WARN:-90}" "${OB_CFG_COMMIT_CRIT:-100}" high "%" \
                "Committed_AS 已超过 CommitLimit 的 ${commit_pct}%。一旦申请超出，即使物理内存还有空余，malloc 也会失败（Cannot allocate memory）"
        fi
    fi

    # ---------------------------------------------------------- 僵尸 ----
    local zombies
    zombies="$(ob_zombie_count)"
    ob_check_threshold "mem.zombie" "僵尸进程数" "$zombies" \
        "${OB_CFG_ZOMBIE_WARN:-10}" "${OB_CFG_ZOMBIE_CRIT:-50}" high " 个" \
        "僵尸进程本身不占资源，但它说明父进程没有正确 wait()。数量持续增长会耗尽 PID。定位父进程：ps -eo stat,ppid,pid,comm | awk '\$1 ~ /Z/ {print}'"

    # ---------------------------------------------------------- Top 进程 ----
    local top procs
    top="$(ob_top_mem_procs "${OB_CFG_TOP_N:-5}" 2>/dev/null || true)"
    if [ -n "$top" ]; then
        procs="$(printf '%s\n' "$top" | LC_ALL=C awk '{
            printf "%s(%s %s) ", $3, $1, $2
        }')"
        ob_ok "mem.top" "内存占用 Top ${OB_CFG_TOP_N:-5}" "$(ob_flatten "$procs")" "—" "-"
    fi

    return 0
}

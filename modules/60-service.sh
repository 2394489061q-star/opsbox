#!/usr/bin/env bash
# ==============================================================================
# opsbox :: modules/60-service.sh
# 服务与进程：systemd 失败单元、期望服务存活、进程规模
#
# 为什么把「失败单元」单列成一项而不是汇总成一个数字：
#   因为排查时必须知道**是哪几个**单元挂了。汇总数字只能告诉你「出事了」，
#   而运维真正需要的是「nginx.service failed」这一行。
# ==============================================================================

# 进程总数检查：抽出来单独一个函数，因为它在两个分支里都要用。
# 进程数为 0 在真实 Linux 上是不可能的，因此那意味着 /proc 读不到，
# 必须报 UNKNOWN 而不是 OK——这正是本项目最重要的一致性约定。
ob_check_proc_total() {
    local procs
    procs="$(ob_proc_count)"
    if ob_is_int "$procs" && [ "$procs" -gt 0 ]; then
        ob_ok "svc.proc_total" "进程总数" "${procs} 个" "—" "-"
    else
        ob_unknown "svc.proc_total" "进程总数" "无法枚举进程" "大于 0" \
            "确认 OB_CFG_PROC_ROOT 指向真实的 /proc；容器内通常需要额外挂载宿主的 /proc 才能看到全部进程"
    fi
    return 0
}

ob_module_service() {
    OB_MODULE="service"

    # ---------------------------------------------------------- systemd ----
    local has_systemd=1
    if [ -n "${OB_CMD_SYSTEMCTL:-}" ] || ob_have systemctl; then
        has_systemd=0
    fi

    if [ "$has_systemd" -ne 0 ]; then
        ob_unknown "svc.systemd" "systemd 可用性" "未找到 systemctl" "可用" \
            "本机可能使用 SysV init、OpenRC 或运行在精简容器内。可跳过服务模块：opsbox check --modules system,cpu,memory,disk,network"
        ob_check_proc_total
        return 0
    fi

    if [ "$OB_ENV_CONTAINER" = "yes" ]; then
        ob_unknown "svc.systemd" "systemd 可用性" "容器环境通常无 systemd" "可用" \
            "容器内应通过编排平台（Kubernetes / Compose）观察服务状态，而非 systemctl"
    else
        ob_ok "svc.systemd" "systemd 可用性" "systemctl 可用" "可用" "-"
    fi

    # ---------------------------------------------------------- 失败单元 ----
    # 产出两条信息，缺一不可：
    #   1. 一条汇总，数量按阈值定级 —— 回答「严重到什么程度」；
    #   2. 每个单元一条明细 —— 回答「到底是哪几个」，这才是能直接动手的地方。
    local failed
    failed="$(ob_systemd_failed_units 2>/dev/null || true)"
    if [ -n "$failed" ]; then
        local n unit_name unit_desc st
        n="$(printf '%s\n' "$failed" | LC_ALL=C grep -c . 2>/dev/null)"
        ob_is_int "$n" || n=0
        st="$(ob_grade "$n" "${OB_CFG_FAILED_UNIT_WARN:-1}" "${OB_CFG_FAILED_UNIT_CRIT:-3}" high)"

        if [ "$n" -eq 0 ]; then
            ob_ok "svc.failed" "systemd 失败单元" "无" "无" "-"
        else
            ob_emit "$st" "$OB_MODULE" "svc.failed" "systemd 失败单元数量" "${n} 个" \
                "$(ob_fmt_threshold "${OB_CFG_FAILED_UNIT_WARN:-1}" "${OB_CFG_FAILED_UNIT_CRIT:-3}" " 个" high)" \
                "用 systemctl --failed 查看完整列表，再逐个 journalctl -u <unit> -n 100 --no-pager 定位原因。注意区分「启动失败」与「启动后被 OOM/依赖拉挂」"

            while IFS=' ' read -r unit_name _load _active _sub unit_desc; do
                [ -n "$unit_name" ] || continue
                ob_emit "$st" "$OB_MODULE" "svc.failed.$(ob_slug "$unit_name")" "失败单元 ${unit_name}" \
                    "$(ob_flatten "${unit_desc:-$unit_name}")" "应为 active" \
                    "查看失败原因：systemctl status ${unit_name} 与 journalctl -u ${unit_name} -n 100 --no-pager。修复后执行 systemctl reset-failed ${unit_name}"
            done <<<"$failed"
        fi
    else
        ob_ok "svc.failed" "systemd 失败单元" "无" "无" "-"
    fi

    # ---------------------------------------------------------- 必需服务 ----
    local unit
    if [ -n "$OB_CFG_REQUIRED_UNITS" ]; then
        for unit in $(printf '%s' "$OB_CFG_REQUIRED_UNITS" | tr ',' ' '); do
            [ -n "$unit" ] || continue
            local state
            state="$(ob_systemd_unit_state "$unit" 2>/dev/null || true)"
            [ -n "$state" ] || state="unknown"
            if [ "$state" = "active" ]; then
                ob_ok "svc.required.$(ob_slug "$unit")" "必需服务 ${unit}" "active" "active" "-"
            else
                ob_crit "svc.required.$(ob_slug "$unit")" "必需服务 ${unit}" "$state" "active" \
                    "这是在配置中显式声明为「必需」的服务。请立刻拉起并查清停止原因：systemctl status ${unit}; journalctl -u ${unit} -n 100 --no-pager。若它是被 OOM Killer 杀掉，需同时处理内存问题"
            fi
        done
    fi

    # ---------------------------------------------------------- 可选服务 ----
    if [ -n "$OB_CFG_OPTIONAL_UNITS" ]; then
        for unit in $(printf '%s' "$OB_CFG_OPTIONAL_UNITS" | tr ',' ' '); do
            [ -n "$unit" ] || continue
            local state2
            state2="$(ob_systemd_unit_state "$unit" 2>/dev/null || true)"
            [ -n "$state2" ] || state2="unknown"
            if [ "$state2" = "active" ]; then
                ob_ok "svc.optional.$(ob_slug "$unit")" "可选服务 ${unit}" "active" "active" "-"
            else
                ob_warn "svc.optional.$(ob_slug "$unit")" "可选服务 ${unit}" "$state2" "建议 active" \
                    "该服务被标记为可选，停止不一定是故障（例如容器环境下不需要）。若确实需要，请检查 ${unit} 的启动依赖与端口占用：systemctl status ${unit}"
            fi
        done
    fi

    # ---------------------------------------------------------- 进程规模 ----
    ob_check_proc_total

    # 线程数（若是内核 2.6+ 均有 /proc/loadavg 的第四字段）
    local thread_hint
    thread_hint="$(ob_loadavg 2>/dev/null | LC_ALL=C awk '{ print $4 "/" $5 }')"
    if [ -n "$thread_hint" ]; then
        ob_ok "svc.run_queue" "可运行/总进程（内核口径）" "$thread_hint" "—" "-"
    fi

    return 0
}

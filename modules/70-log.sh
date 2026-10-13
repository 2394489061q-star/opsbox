#!/usr/bin/env bash
# ==============================================================================
# opsbox :: modules/70-log.sh
# 日志与崩溃：journal 错误量、错误聚类、传统日志文件、crash dump
#
# 这里做了一件大多数巡检脚本不做的事：**错误聚类**。
# 只报「有 300 条错误」没有意义，运维需要知道的是
# 「300 条里 287 条都是同一个 message」——那才是要修的根因。
# 做法是把日志消息里的数字与 ID 归一化后再统计词频。
# ==============================================================================

# 把日志消息归一化为可聚类的模板：
#   "connection refused to 10.1.2.3:5432 (attempt 7)"
#   -> "connection refused to N:N:N:N:N (attempt N)"
ob_log_normalize() {
    LC_ALL=C sed -e 's/[0-9a-fA-F]\{8,\}/HEX/g' \
                    -e 's/[0-9][0-9.]*/N/g' \
                    -e 's/^[ \t]*//' \
                    -e 's/[ \t]*$//'
}

# 从 journal 拿错误消息（纯消息体），失败时返回非零
ob_journal_error_messages() {
    local bin="${OB_CMD_JOURNALCTL:-journalctl}"
    ob_have "$bin" || return 1
    "$bin" --no-pager -p err --since "${OB_CFG_LOG_SINCE}" -o cat 2>/dev/null
}

# 在没有 journald 的系统上，从传统日志文件尾部抽样
ob_logfile_error_messages() {
    local f got=0
    for f in $OB_CFG_LOG_FILES; do
        [ -r "$f" ] || continue
        got=1
        LC_ALL=C tail -c "${OB_CFG_LOG_SCAN_BYTES}" "$f" 2>/dev/null \
            | LC_ALL=C grep -iE '(error|crit|alert|emerg|panic|failed)' 2>/dev/null
    done
    [ "$got" -eq 1 ] || return 1
    return 0
}

ob_module_log() {
    OB_MODULE="log"

    local msgs have_source=1
    msgs="$(ob_journal_error_messages 2>/dev/null || true)"
    if [ -n "$msgs" ]; then
        have_source=0
        ob_ok "log.source" "日志数据源" "journald（--since '${OB_CFG_LOG_SINCE}'）" "—" "-"
    else
        msgs="$(ob_logfile_error_messages 2>/dev/null || true)"
        if [ -n "$msgs" ]; then
            have_source=0
            ob_ok "log.source" "日志数据源" "传统日志文件（尾部 ${OB_CFG_LOG_SCAN_BYTES} 字节）" "—" "-"
        fi
    fi

    if [ "$have_source" -ne 0 ]; then
        ob_unknown "log.errors" "近期错误日志量" "没有可读的日志源" "低于 ${OB_CFG_LOG_ERR_WARN} 条" \
            "未找到 journalctl，也未在 OB_CFG_LOG_FILES 指定的路径下找到可读日志。请确认日志采集组件正常，或调整 OB_CFG_LOG_FILES"
    else
        local err_count
        err_count="$(printf '%s\n' "$msgs" | LC_ALL=C grep -c . 2>/dev/null)"
        ob_is_int "$err_count" || err_count=0

        ob_check_threshold "log.errors" "近期错误日志量（${OB_CFG_LOG_SINCE}）" "$err_count" \
            "$OB_CFG_LOG_ERR_WARN" "$OB_CFG_LOG_ERR_CRIT" high " 条" \
            "错误量上升本身不是根因，请直接看下面的聚类结果定位最高频的那一类。注意区分「新增错误」与「长期噪音」（如固定时间的证书检查）"

        # ------------------------------------------------------ 错误聚类 ----
        local clusters
        clusters="$(printf '%s\n' "$msgs" | LC_ALL=C grep . | ob_log_normalize \
            | LC_ALL=C sort | LC_ALL=C uniq -c | LC_ALL=C sort -rn | head -n 3 2>/dev/null || true)"

        if [ -n "$clusters" ]; then
            local rank=0 cnt text
            while read -r cnt text; do
                [ -n "$cnt" ] || continue
                rank=$((rank + 1))
                ob_ok "log.top${rank}" "高频错误 #${rank}" "$(ob_flatten "${cnt} 次 · ${text}")" "—" "-"
            done <<<"$clusters"
        fi
    fi

    # ---------------------------------------------------------- crash dump ----
    # 同样区分「确实没有崩溃」与「目录都查不到」
    local dumps dumps_rc=0
    dumps="$(ob_crash_dumps 2>/dev/null)" || dumps_rc=$?
    if [ "$dumps_rc" -ne 0 ]; then
        ob_unknown "log.crash_dumps" "崩溃转储数量" "配置的转储目录均不存在" "0 个" \
            "OB_CFG_CRASH_DUMP_DIRS 当前值：${OB_CFG_CRASH_DUMP_DIRS}。若不使用 core dump，可把此项静音：OB_CFG_DISABLE_CHECKS=log.crash_dumps"
    elif [ "$dumps" -gt 0 ]; then
        ob_check_threshold "log.crash_dumps" "崩溃转储数量" "$dumps" \
            "${OB_CFG_CRASH_WARN:-1}" "${OB_CFG_CRASH_CRIT:-5}" high " 个" \
            "存在 core dump / crash 记录，说明有进程异常终止。用 coredumpctl list 或 ls /var/crash 查看，并配合 gdb 分析；同时确认内核参数 kernel.core_pattern 是否符合预期"
    else
        ob_ok "log.crash_dumps" "崩溃转储数量" "0 个" "0 个" "-"
    fi

    # ---------------------------------------------------------- 日志文件明细 ----
    local biglogs
    biglogs="$(ob_big_log_files "${OB_CFG_TOP_N:-5}" 2>/dev/null || true)"
    if [ -n "$biglogs" ]; then
        local sz path items=""
        while IFS=' ' read -r sz path; do
            [ -n "$path" ] || continue
            items="${items}${path}($(ob_human_bytes "$((sz * 1024))")); "
        done <<<"$biglogs"
        ob_ok "log.biggest" "体积最大的日志文件" "$(ob_flatten "$items")" "—" "-"
    fi

    return 0
}

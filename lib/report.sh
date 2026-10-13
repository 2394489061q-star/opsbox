#!/usr/bin/env bash
# ==============================================================================
# opsbox :: lib/report.sh
# 展示层：把结果数组渲染成终端报告 / Markdown / JSON / Prometheus / CSV。
#
# 约定：stdout 只输出报告本体，任何提示信息走 stderr。
# 因此 `opsbox check --format json > report.json` 永远得到干净的 JSON。
# ==============================================================================

OB_DURATION="${OB_DURATION:-0}"
OB_RUN_MODE="${OB_RUN_MODE:-full}"
OB_SEP=""

ob_module_label() {
    case "$1" in
        system)   printf '系统信息' ;;
        cpu)      printf 'CPU 与负载' ;;
        memory)   printf '内存与 Swap' ;;
        disk)     printf '磁盘与 inode' ;;
        network)  printf '网络与连接' ;;
        service)  printf '服务与进程' ;;
        log)      printf '日志与崩溃' ;;
        security) printf '安全基线' ;;
        *)        printf '%s' "$1" ;;
    esac
}

ob_status_color() {
    case "$1" in
        OK)   printf '%s' "$C_GREEN" ;;
        WARN) printf '%s' "$C_YELLOW" ;;
        CRIT) printf '%s' "$C_RED" ;;
        *)    printf '%s' "$C_MAGENTA" ;;
    esac
}

ob_status_tag() {
    case "$1" in
        OK)   printf 'OK' ;;
        WARN) printf 'WARN' ;;
        CRIT) printf 'CRIT' ;;
        *)    printf 'UNKN' ;;
    esac
}

ob_status_emoji() {
    case "$1" in
        OK)   printf 'OK' ;;
        WARN) printf 'WARN' ;;
        CRIT) printf 'CRIT' ;;
        *)    printf 'UNKNOWN' ;;
    esac
}

ob_now_local() { date '+%Y-%m-%d %H:%M:%S %z' 2>/dev/null || printf 'unknown'; }
ob_now_utc()   { date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || printf 'unknown'; }

ob_have_results() { [ "${#OB_RESULTS[@]}" -gt 0 ]; }

# 生成一条分隔线（懒加载，只算一次）
ob_sep_line() {
    if [ -z "$OB_SEP" ]; then
        OB_SEP="$(LC_ALL=C awk 'BEGIN { for (i = 0; i < 76; i++) printf "-" }')"
    fi
    printf '%s' "$OB_SEP"
}

# ---------------------------------------------------------------- 顶部信息 ----
ob_report_header_lines() { # 输出 "key|value" 每行一条
    printf 'hostname|%s\n' "$OB_ENV_HOSTNAME"
    printf 'os|%s\n' "$OB_ENV_OS_PRETTY"
    printf 'os_id|%s\n' "$OB_ENV_OS"
    printf 'kernel|%s\n' "$OB_ENV_KERNEL"
    printf 'arch|%s\n' "$OB_ENV_ARCH"
    printf 'virt|%s\n' "$OB_ENV_VIRT"
    printf 'container|%s\n' "$OB_ENV_CONTAINER"
    printf 'uptime|%s\n' "$(ob_human_duration "$(ob_uptime_seconds)")"
    printf 'uptime_seconds|%s\n' "$(ob_uptime_seconds)"
    printf 'cpu_count|%s\n' "$(ob_cpu_count)"
    printf 'cpu_model|%s\n' "$(ob_cpu_model)"
    printf 'generated_at|%s\n' "$(ob_now_local)"
    printf 'generated_at_utc|%s\n' "$(ob_now_utc)"
    printf 'duration_seconds|%s\n' "$OB_DURATION"
    printf 'tool|%s %s\n' "$OB_PROG" "$OB_VERSION"
    printf 'run_mode|%s\n' "$OB_RUN_MODE"
    return 0
}

# ---------------------------------------------------------------- 终端报告 ----
ob_render_text() {
    local sep
    sep="$(ob_sep_line)"

    printf '%s%s%s\n' "$C_BOLD" "$sep" "$C_RESET"
    printf '  %s%s v%s%s  ·  %s%s%s\n' \
        "$C_BOLD" "$OB_PROG" "$OB_VERSION" "$C_RESET" \
        "$C_BOLD" "$OB_CFG_REPORT_TITLE" "$C_RESET"
    printf '  主机 %s%s%s  ·  %s  ·  内核 %s\n' \
        "$C_BOLD" "$OB_ENV_HOSTNAME" "$C_RESET" "$OB_ENV_OS_PRETTY" "$OB_ENV_KERNEL"
    printf '  架构 %s  ·  虚拟化 %s  ·  容器 %s  ·  CPU %s 核\n' \
        "$OB_ENV_ARCH" "$OB_ENV_VIRT" "$OB_ENV_CONTAINER" "$(ob_cpu_count)"
    printf '  运行模式 %s  ·  耗时 %ss  ·  生成于 %s\n' \
        "$OB_RUN_MODE" "$OB_DURATION" "$(ob_now_local)"
    printf '%s%s%s\n\n' "$C_BOLD" "$sep" "$C_RESET"

    if ! ob_have_results; then
        printf '  （没有任何检查项产生结果，请检查配置与模块加载）\n\n'
    else
        local line curmod=""
        for line in "${OB_RESULTS[@]}"; do
            ob_result_split "$line"
            if [ "$OB_F2" != "$curmod" ]; then
                if [ -n "$curmod" ]; then printf '\n'; fi
                printf '%s【%s】%s\n' "$C_BOLD" "$(ob_module_label "$OB_F2")" "$C_RESET"
                curmod="$OB_F2"
            fi
            ob_render_text_row "$OB_F1" "$OB_F3" "$OB_F4" "$OB_F5" "$OB_F6" "$OB_F7"
        done
        printf '\n'
    fi

    printf '%s%s%s\n' "$C_BOLD" "$sep" "$C_RESET"
    ob_render_summary_line
    printf '%s%s%s\n' "$C_BOLD" "$sep" "$C_RESET"
    return 0
}

ob_render_text_row() {
    local st="$1" id="$2" title="$3" obs="$4" thr="$5" adv="$6"
    local color
    color="$(ob_status_color "$st")"

    printf '  %s[%s]%s %s%-26s%s %s  %s(%s)%s\n' \
        "$color" "$(ob_status_tag "$st")" "$C_RESET" \
        "$C_DIM" "$id" "$C_RESET" "$title" \
        "$C_DIM" "$obs" "$C_RESET"

    if [ "$adv" != "-" ] && [ "$st" != "OK" ]; then
        printf '        %s↳ %s%s  %s[阈值 %s]%s\n' \
            "$color" "$adv" "$C_RESET" "$C_DIM" "$thr" "$C_RESET"
    fi
    return 0
}

ob_render_summary_line() {
    printf '  汇总：%sOK %d%s  ·  %sWARN %d%s  ·  %sCRIT %d%s  ·  %sUNKNOWN %d%s\n' \
        "$C_GREEN" "$OB_N_OK" "$C_RESET" \
        "$C_YELLOW" "$OB_N_WARN" "$C_RESET" \
        "$C_RED" "$OB_N_CRIT" "$C_RESET" \
        "$C_MAGENTA" "$OB_N_UNKNOWN" "$C_RESET"

    local worst
    worst="$(ob_worst_status)"
    printf '  结论：%s%s%s   %s(退出码 %s)%s\n' \
        "$C_BOLD" "$(ob_verdict_text "$worst")" "$C_RESET" \
        "$C_DIM" "$(ob_exit_code_for_status "$worst")" "$C_RESET"
}

ob_verdict_text() {
    case "$1" in
        OK)   printf '一切正常，未发现需要处理的问题' ;;
        WARN) printf '存在需要关注的项目，建议近期处理' ;;
        CRIT) printf '存在严重问题，请立即介入' ;;
        *)    printf '数据不足，无法给出结论' ;;
    esac
}

# ---------------------------------------------------------------- 单行模式 ----
# 适合塞进 cron 邮件主题，或给只认单行的监控系统抓取
ob_render_oneline() {
    local worst
    worst="$(ob_worst_status)"
    printf '%s %s: %s | OK=%d WARN=%d CRIT=%d UNKNOWN=%d | %s\n' \
        "$(ob_status_tag "$worst")" "$OB_ENV_HOSTNAME" "$(ob_verdict_text "$worst")" \
        "$OB_N_OK" "$OB_N_WARN" "$OB_N_CRIT" "$OB_N_UNKNOWN" "$(ob_now_local)"
    return 0
}

# ---------------------------------------------------------------- Markdown ----
ob_render_markdown() {
    local line worst

    printf '# %s\n\n' "$OB_CFG_REPORT_TITLE"
    printf '> 由 `%s v%s` 生成于 %s（运行模式：%s，耗时 %ss）\n\n' \
        "$OB_PROG" "$OB_VERSION" "$(ob_now_local)" "$OB_RUN_MODE" "$OB_DURATION"

    worst="$(ob_worst_status)"

    printf '## 一、结论\n\n'
    printf '**%s** —— %s\n\n' "$worst" "$(ob_verdict_text "$worst")"
    printf '| 状态 | 数量 |\n| --- | ---: |\n'
    printf '| OK | %d |\n' "$OB_N_OK"
    printf '| WARN | %d |\n' "$OB_N_WARN"
    printf '| CRIT | %d |\n' "$OB_N_CRIT"
    printf '| UNKNOWN | %d |\n\n' "$OB_N_UNKNOWN"

    printf '## 二、环境概览\n\n| 项目 | 值 |\n| --- | --- |\n'
    ob_report_header_lines | LC_ALL=C awk -F'|' '
        $1 == "hostname"  { printf "| 主机名 | `%s` |\n", $2 }
        $1 == "os"        { printf "| 操作系统 | %s |\n", $2 }
        $1 == "kernel"    { printf "| 内核 | `%s` |\n", $2 }
        $1 == "arch"      { printf "| 架构 | %s |\n", $2 }
        $1 == "virt"      { printf "| 虚拟化 | %s |\n", $2 }
        $1 == "container" { printf "| 容器环境 | %s |\n", $2 }
        $1 == "uptime"    { printf "| 运行时长 | %s |\n", $2 }
        $1 == "cpu_count" { printf "| CPU 核数 | %s |\n", $2 }
        $1 == "cpu_model" { printf "| CPU 型号 | %s |\n", $2 }
    '
    printf '\n'

    printf '## 三、需要处理的问题\n\n'
    local found_bad=0
    if ob_have_results; then
        for line in "${OB_RESULTS[@]}"; do
            ob_result_split "$line"
            case "$OB_F1" in OK|UNKNOWN) continue ;; esac
            found_bad=$((found_bad + 1))
            printf '### %s `%s` %s\n\n' "$OB_F1" "$OB_F3" "$OB_F4"
            printf -- '- **所属模块**：%s\n' "$(ob_module_label "$OB_F2")"
            printf -- '- **观测值**：%s\n' "$OB_F5"
            printf -- '- **阈值**：%s\n' "$OB_F6"
            printf -- '- **处置建议**：%s\n\n' "$OB_F7"
        done
    fi
    [ "$found_bad" -eq 0 ] && printf '本次巡检未发现问题。\n\n'

    printf '## 四、完整检查明细\n\n'
    if ob_have_results; then
        local curmod=""
        for line in "${OB_RESULTS[@]}"; do
            ob_result_split "$line"
            if [ "$OB_F2" != "$curmod" ]; then
                if [ -n "$curmod" ]; then printf '\n'; fi
                printf '### %s\n\n' "$(ob_module_label "$OB_F2")"
                printf '| 状态 | 检查项 ID | 观测值 | 阈值 |\n| --- | --- | --- | --- |\n'
                curmod="$OB_F2"
            fi
            printf '| %s | `%s` | %s | %s |\n' "$OB_F1" "$OB_F3" "$OB_F5" "$OB_F6"
        done
        printf '\n'
    fi

    printf -- '---\n\n'
    printf '阈值可按需覆盖：编辑 `/etc/opsbox/opsbox.conf` 后重新执行 `opsbox check` 即可。\n'
    return 0
}

# ---------------------------------------------------------------- JSON ----
ob_render_json() {
    local line first=1 worst
    worst="$(ob_worst_status)"

    printf '{\n'
    printf '  "schema": "opsbox.report/%s",\n' "$OB_SCHEMA_VERSION"
    printf '  "tool": {"name": "%s", "version": "%s"},\n' \
        "$(ob_json_escape "$OB_PROG")" "$(ob_json_escape "$OB_VERSION")"
    printf '  "generated_at": "%s",\n' "$(ob_json_escape "$(ob_now_utc)")"
    printf '  "generated_at_local": "%s",\n' "$(ob_json_escape "$(ob_now_local)")"
    printf '  "duration_seconds": %s,\n' "$OB_DURATION"
    printf '  "run_mode": "%s",\n' "$(ob_json_escape "$OB_RUN_MODE")"

    printf '  "host": {\n'
    printf '    "hostname": "%s",\n' "$(ob_json_escape "$OB_ENV_HOSTNAME")"
    printf '    "os": "%s",\n' "$(ob_json_escape "$OB_ENV_OS_PRETTY")"
    printf '    "os_id": "%s",\n' "$(ob_json_escape "$OB_ENV_OS")"
    printf '    "kernel": "%s",\n' "$(ob_json_escape "$OB_ENV_KERNEL")"
    printf '    "arch": "%s",\n' "$(ob_json_escape "$OB_ENV_ARCH")"
    printf '    "virt": "%s",\n' "$(ob_json_escape "$OB_ENV_VIRT")"
    printf '    "container": "%s",\n' "$(ob_json_escape "$OB_ENV_CONTAINER")"
    printf '    "uptime_seconds": %s,\n' "$(ob_uptime_seconds)"
    printf '    "cpu_count": %s\n' "$(ob_cpu_count)"
    printf '  },\n'

    printf '  "summary": {"ok": %d, "warn": %d, "crit": %d, "unknown": %d, "status": "%s", "exit_code": %s},\n' \
        "$OB_N_OK" "$OB_N_WARN" "$OB_N_CRIT" "$OB_N_UNKNOWN" "$worst" "$(ob_exit_code_for_status "$worst")"

    printf '  "results": ['
    if ob_have_results; then
        printf '\n'
        for line in "${OB_RESULTS[@]}"; do
            ob_result_split "$line"
            [ "$first" -eq 0 ] && printf ',\n'
            first=0
            printf '    {"status": "%s", "module": "%s", "id": "%s", "title": "%s", "observed": "%s", "threshold": "%s", "advice": "%s"}' \
                "$(ob_json_escape "$OB_F1")" "$(ob_json_escape "$OB_F2")" "$(ob_json_escape "$OB_F3")" \
                "$(ob_json_escape "$OB_F4")" "$(ob_json_escape "$OB_F5")" "$(ob_json_escape "$OB_F6")" \
                "$(ob_json_escape "$OB_F7")"
        done
        printf '\n  ]\n'
    else
        printf ']\n'
    fi
    printf '}\n'
    return 0
}

# ---------------------------------------------------------------- Prometheus ----
# 输出 node_exporter textfile collector 可直接吃下的格式。
ob_render_prom() {
    local line v worst ov
    worst="$(ob_worst_status)"

    printf '# HELP opsbox_check_status 巡检项状态：0=OK 1=WARN 2=CRIT 3=UNKNOWN\n'
    printf '# TYPE opsbox_check_status gauge\n'
    if ob_have_results; then
        for line in "${OB_RESULTS[@]}"; do
            ob_result_split "$line"
            case "$OB_F1" in
                OK) v=0 ;; WARN) v=1 ;; CRIT) v=2 ;; *) v=3 ;;
            esac
            printf 'opsbox_check_status{module="%s",check="%s"} %s\n' \
                "$(ob_prom_escape "$OB_F2")" "$(ob_prom_escape "$OB_F3")" "$v"
        done
    fi

    printf '# HELP opsbox_check_total 本次巡检各状态检查项数量\n'
    printf '# TYPE opsbox_check_total gauge\n'
    printf 'opsbox_check_total{status="ok"} %d\n' "$OB_N_OK"
    printf 'opsbox_check_total{status="warn"} %d\n' "$OB_N_WARN"
    printf 'opsbox_check_total{status="crit"} %d\n' "$OB_N_CRIT"
    printf 'opsbox_check_total{status="unknown"} %d\n' "$OB_N_UNKNOWN"

    printf '# HELP opsbox_overall_status 本次巡检整体状态：0=OK 1=WARN 2=CRIT 3=UNKNOWN\n'
    printf '# TYPE opsbox_overall_status gauge\n'
    case "$worst" in OK) ov=0 ;; WARN) ov=1 ;; CRIT) ov=2 ;; *) ov=3 ;; esac
    printf 'opsbox_overall_status %s\n' "$ov"

    printf '# HELP opsbox_last_run_timestamp_seconds 本次巡检完成时间（Unix 时间戳）\n'
    printf '# TYPE opsbox_last_run_timestamp_seconds gauge\n'
    printf 'opsbox_last_run_timestamp_seconds %s\n' "$(ob_now_epoch)"

    printf '# HELP opsbox_run_duration_seconds 本次巡检耗时\n'
    printf '# TYPE opsbox_run_duration_seconds gauge\n'
    printf 'opsbox_run_duration_seconds %s\n' "$OB_DURATION"

    printf '# HELP opsbox_info 巡检目标信息，值恒为 1\n'
    printf '# TYPE opsbox_info gauge\n'
    printf 'opsbox_info{hostname="%s",os="%s",kernel="%s",version="%s"} 1\n' \
        "$(ob_prom_escape "$OB_ENV_HOSTNAME")" "$(ob_prom_escape "$OB_ENV_OS")" \
        "$(ob_prom_escape "$OB_ENV_KERNEL")" "$(ob_prom_escape "$OB_VERSION")"
    return 0
}

# Prometheus label 值只需转义反斜杠、双引号，并把换行压平
ob_prom_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/ }"
    printf '%s' "$s"
}

# ---------------------------------------------------------------- CSV ----
ob_render_csv() {
    local line
    printf 'status,module,id,title,observed,threshold,advice\n'
    if ob_have_results; then
        for line in "${OB_RESULTS[@]}"; do
            ob_result_split "$line"
            printf '%s,%s,%s,%s,%s,%s,%s\n' \
                "$(ob_csv_cell "$OB_F1")" "$(ob_csv_cell "$OB_F2")" "$(ob_csv_cell "$OB_F3")" \
                "$(ob_csv_cell "$OB_F4")" "$(ob_csv_cell "$OB_F5")" "$(ob_csv_cell "$OB_F6")" \
                "$(ob_csv_cell "$OB_F7")"
        done
    fi
    return 0
}

ob_csv_cell() {
    local s="$1"
    case "$s" in
        *,*|*\"*)
            s="${s//\"/\"\"}"
            s="\"${s}\""
            ;;
    esac
    printf '%s' "$s"
}

# ---------------------------------------------------------------- 调度 ----
ob_render() { # <format>
    case "$1" in
        text)             ob_render_text ;;
        md|markdown)      ob_render_markdown ;;
        json)             ob_render_json ;;
        prom|prometheus)  ob_render_prom ;;
        csv)              ob_render_csv ;;
        oneline)          ob_render_oneline ;;
        *)                return 1 ;;
    esac
}

ob_render_supported_formats() { printf 'text md json prom csv oneline'; }

#!/usr/bin/env bash
# ==============================================================================
# opsbox :: lib/checks.sh
# 判定层：把观测值折叠成 OK / WARN / CRIT / UNKNOWN，并附上可执行的处置建议。
#
# 为什么单独一层？
#   采集（collect）与展示（report）都会演进，但"多少算超标"是运维团队的
#   共识，应当只有一个定义处。所有模块都必须通过这里的原语产出结论，
#   保证同一指标在不同模块/不同输出格式下判定完全一致。
# ==============================================================================

# ---------------------------------------------------------------- 阈值原语 ----
# ob_check_threshold <id> <title> <value> <warn> <crit> <direction> <unit> <advice>
#   direction: high = 越大越糟（默认）  low = 越小越糟
#   unit:      展示单位，可空
#   advice:    触发非 OK 时给出的处置建议
#
# 一个约定：value 为空或非数字时，产出 UNKNOWN 而不是 OK——
# 「测不到」和「没问题」在运维上是两件事，绝不能混。
ob_check_threshold() {
    local id="$1" title="$2" value="$3" warn="$4" crit="$5"
    local dir="${6:-high}" unit="${7:-}" advice="${8:-}"

    if ! ob_is_num "$value"; then
        ob_unknown "$id" "$title" "${value:-无法采集}" "warn=${warn}${unit} crit=${crit}${unit}" \
            "该指标不可读，请确认采集路径与权限是否正常"
        return 0
    fi

    local status
    status="$(ob_grade "$value" "$warn" "$crit" "$dir")"

    local observed threshold
    observed="$(ob_fmt_value "$value" "$unit")"
    threshold="$(ob_fmt_threshold "$warn" "$crit" "$unit" "$dir")"

    case "$status" in
        OK)   ob_ok      "$id" "$title" "$observed" "$threshold" "-" ;;
        WARN) ob_warn    "$id" "$title" "$observed" "$threshold" "$advice" ;;
        CRIT) ob_crit    "$id" "$title" "$observed" "$threshold" "$advice" ;;
    esac
    return 0
}

# 比率型：value/count 与 warn/crit 比较（例如 load1 相对 CPU 核数）
# ob_check_ratio <id> <title> <numerator> <denominator> <warn_mult> <crit_mult> <advice>
ob_check_ratio() {
    local id="$1" title="$2" num="$3" den="$4" warn="$5" crit="$6" advice="${7:-}"

    if ! ob_is_num "$num" || ! ob_is_num "$den"; then
        ob_unknown "$id" "$title" "无法采集" "比值 warn=${warn} crit=${crit}" \
            "缺少分子或分母数据，请检查采集路径"
        return 0
    fi
    if ob_cmp "$den" "<=" "0"; then
        ob_unknown "$id" "$title" "分母为 0" "比值 warn=${warn} crit=${crit}" \
            "无法计算比值"
        return 0
    fi

    local ratio status
    ratio="$(ob_div "$num" "$den" 2)"
    status="$(ob_grade "$ratio" "$warn" "$crit" high)"

    local observed="比值 ${ratio} (${num}/${den})"
    local threshold="warn=${warn}x crit=${crit}x"
    case "$status" in
        OK)   ob_ok   "$id" "$title" "$observed" "$threshold" "-" ;;
        WARN) ob_warn "$id" "$title" "$observed" "$threshold" "$advice" ;;
        CRIT) ob_crit "$id" "$title" "$observed" "$threshold" "$advice" ;;
    esac
    return 0
}

# 布尔断言： condition 为 0（真）时 OK，否则按 bad_status 定性
# ob_check_bool <id> <title> <ok_display> <bad_display> <condition_exit_code> <bad_status> <advice>
ob_check_bool() {
    local id="$1" title="$2" ok_display="$3" bad_display="$4"
    local cond="$5" bad_status="${6:-WARN}" advice="${7:-}"

    if [ "$cond" -eq 0 ]; then
        ob_ok "$id" "$title" "$ok_display" "期望：${ok_display}" "-"
    else
        ob_emit "$bad_status" "$OB_MODULE" "$id" "$title" "$bad_display" "期望：${ok_display}" "$advice"
    fi
    return 0
}

# 存在性断言：要求某文件/目录/命令必须存在
# ob_check_required <id> <title> <path_or_cmd> <kind: file|dir|cmd> <bad_status> <advice>
ob_check_required() {
    local id="$1" title="$2" target="$3" kind="${4:-file}"
    local bad_status="${5:-WARN}" advice="${6:-}"
    local ok=1

    case "$kind" in
        file) [ -e "$target" ] && ok=0 ;;
        dir)  [ -d "$target" ] && ok=0 ;;
        cmd)  ob_have "$target" && ok=0 ;;
    esac

    if [ "$ok" -eq 0 ]; then
        ob_ok "$id" "$title" "存在：${target}" "要求存在" "-"
    else
        ob_emit "$bad_status" "$OB_MODULE" "$id" "$title" "缺失：${target}" "要求存在" "$advice"
    fi
    return 0
}

# ---------------------------------------------------------------- 展示格式 ----
ob_fmt_value() { # <value> <unit>
    local v="$1" u="$2"
    if [ -n "$u" ]; then printf '%s%s' "$v" "$u"; else printf '%s' "$v"; fi
}

ob_fmt_threshold() { # <warn> <crit> <unit> <direction>
    local w="$1" c="$2" u="$3" dir="${4:-high}"
    if [ "$dir" = "low" ]; then
        printf '低于 %s%s 警告 / 低于 %s%s 严重' "$w" "$u" "$c" "$u"
    else
        printf '%s%s 警告 / %s%s 严重' "$w" "$u" "$c" "$u"
    fi
}

# ---------------------------------------------------------------- 聚合助手 ----
# 对一批 "key value [display]" 行按阈值逐条判定，用于挂载点这类多实例指标。
# ob_check_series <id_prefix> <title_prefix> <lines> <warn> <crit> <unit> <advice>
#   每行格式： "<slug> <value> [显示名]"
#   显示名省略时用 slug。slug 会成为检查项 id 的一部分，因此必须是稳定的短标识，
#   这样运维才能用 OB_CFG_DISABLE_CHECKS 精确静音某一个挂载点。
#
# 注意：这里必须用 here-string 而不是管道。管道会开子 shell，
# 而 ob_emit 写的是全局结果数组，子 shell 里的写入会全部丢失。
ob_check_series() {
    local id_prefix="$1" title_prefix="$2" lines="$3"
    local warn="$4" crit="$5" unit="${6:-}" advice="${7:-}"
    local name value display st n=0

    while IFS=' ' read -r name value display; do
        [ -n "$name" ] || continue
        [ -n "$value" ] || continue
        [ -n "$display" ] || display="$name"
        n=$((n + 1))
        st="$(ob_grade "$value" "$warn" "$crit" high)"
        if [ "$st" = "OK" ]; then
            ob_emit "$st" "$OB_MODULE" "${id_prefix}.${name}" "${title_prefix}：${display}" \
                "$(ob_fmt_value "$value" "$unit")" \
                "$(ob_fmt_threshold "$warn" "$crit" "$unit" high)" "-"
        else
            ob_emit "$st" "$OB_MODULE" "${id_prefix}.${name}" "${title_prefix}：${display}" \
                "$(ob_fmt_value "$value" "$unit")" \
                "$(ob_fmt_threshold "$warn" "$crit" "$unit" high)" "$advice"
        fi
    done <<<"$lines"

    if [ "$n" -eq 0 ]; then
        ob_unknown "${id_prefix}" "${title_prefix}" "无数据" "warn=${warn}${unit}" \
            "未采集到任何实例，请确认数据源可读"
    fi
    return 0
}

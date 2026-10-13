#!/usr/bin/env bash
# ==============================================================================
# opsbox :: modules/50-network.sh
# 网络与连接：接口错误率、连接状态分布、监听端口、conntrack、路由
#
# 判定思路：
#   网络问题的第一现场永远在「连接状态分布」里，而不是在流量曲线里。
#   TIME_WAIT 暴涨 = 短连接过频（程序没复用连接）
#   CLOSE_WAIT 堆积 = 对端很正常，是本端应用忘了 close()
#   SYN_RECV 堆积   = 正在被 SYN Flood 或半连接耗尽
#   这三者的处置方向完全不同，所以要分开看。
# ==============================================================================

ob_module_network() {
    OB_MODULE="network"

    # ---------------------------------------------------------- 接口错误率 ----
    # 用「错误数 / 包数」而不是累计错误数：累计值会随运行时长自然增长，
    # 用它做阈值必然误报。比率与运行时长无关，可以直接设固定阈值。
    local stats
    stats="$(ob_netdev_stats 2>/dev/null || true)"
    if [ -n "$stats" ]; then
        local iface rx_b tx_b rx_e tx_e rx_d tx_d rx_p tx_p
        local err_lines="" drop_lines="" info_lines=""
        while IFS=' ' read -r iface rx_b tx_b rx_e tx_e rx_d tx_d rx_p tx_p; do
            [ -n "$iface" ] || continue
            [ "$iface" = "lo" ] && continue

            local pkts errs drops err_rate drop_rate
            pkts=$((rx_p + tx_p))
            errs=$((rx_e + tx_e))
            drops=$((rx_d + tx_d))

            if [ "$pkts" -gt 0 ]; then
                err_rate="$(LC_ALL=C awk -v e="$errs" -v p="$pkts" 'BEGIN { printf "%.4f", e * 100 / p }')"
                drop_rate="$(LC_ALL=C awk -v d="$drops" -v p="$pkts" 'BEGIN { printf "%.4f", d * 100 / p }')"
                err_lines="${err_lines}${iface} ${err_rate} ${iface}
"
                drop_lines="${drop_lines}${iface} ${drop_rate} ${iface}
"
            fi

            info_lines="${info_lines}${iface}: ↓$(ob_human_bytes "$rx_b") ↑$(ob_human_bytes "$tx_b") 错${errs} 丢${drops}; "
        done <<<"$stats"

        if [ -n "$err_lines" ]; then
            ob_check_series "net.err_rate" "接口错误率" "$err_lines" \
                "${OB_CFG_IFACE_ERR_RATE_WARN:-0.01}" "${OB_CFG_IFACE_ERR_RATE_CRIT:-0.1}" "%" \
                "接口出现收发错误，常见原因是网线/光模块劣化、双工不匹配、MTU 不一致或交换机端口 CRC 错误。请到交换机侧查看端口计数，并检查 ip -s link 的 errors 列增速"
        fi
        if [ -n "$drop_lines" ]; then
            ob_check_series "net.drop_rate" "接口丢包率" "$drop_lines" \
                "${OB_CFG_IFACE_DROP_RATE_WARN:-0.01}" "${OB_CFG_IFACE_DROP_RATE_CRIT:-0.1}" "%" \
                "丢包通常来自网卡队列溢出（流量突发超过队列深度）或上层限速/整形。可检查 ethtool -S <网卡> 的 rx_missed/drop 计数，并考虑调大 ring buffer 或中断合并参数"
        fi

        ob_ok "net.traffic" "接口流量累计" "$(ob_flatten "$info_lines")" "—" "-"
    else
        ob_unknown "net.err_rate" "接口错误率" "无法读取 /proc/net/dev" "低于 ${OB_CFG_IFACE_ERR_RATE_WARN:-0.01}%" \
            "确认 /proc/net/dev 可读"
    fi

    # ---------------------------------------------------------- 连接状态 ----
    local counts
    counts="$(ob_tcp_state_counts 2>/dev/null || true)"

    if [ -n "$counts" ]; then
        local established timewait closewait listen synrecv total
        established="$(ob_tcp_state_get ESTABLISHED "$counts")"
        timewait="$(ob_tcp_state_get TIME_WAIT "$counts")"
        closewait="$(ob_tcp_state_get CLOSE_WAIT "$counts")"
        listen="$(ob_tcp_state_get LISTEN "$counts")"
        synrecv="$(ob_tcp_state_get SYN_RECV "$counts")"
        total="$(ob_tcp_state_get TOTAL "$counts")"

        ob_check_threshold "net.tcp_total" "TCP 连接总数" "$total" \
            "$OB_CFG_TCP_WARN" "$OB_CFG_TCP_CRIT" high " 条" \
            "连接数偏高。分布：ESTABLISHED=${established} TIME_WAIT=${timewait} CLOSE_WAIT=${closewait}。请先判断是正常业务量增长还是连接未复用/未释放"

        ob_check_threshold "net.timewait" "TIME_WAIT 连接数" "$timewait" \
            "$OB_CFG_TIMEWAIT_WARN" "$OB_CFG_TIMEWAIT_CRIT" high " 条" \
            "TIME_WAIT 是主动关闭方必然产生的状态，量大说明短连接过频。正确解法是在应用侧启用连接池/Keep-Alive，而不是调小 tcp_fin_timeout 或开启 tcp_tw_reuse（后者在 NAT 环境下有踩坑风险）"

        ob_check_threshold "net.closewait" "CLOSE_WAIT 连接数" "$closewait" \
            "${OB_CFG_CLOSEWAIT_WARN:-500}" "${OB_CFG_CLOSEWAIT_CRIT:-2000}" high " 条" \
            "CLOSE_WAIT 堆积是应用层 bug 的典型指纹：对端已发 FIN，本端代码没有调用 close()。定位持有连接的文件描述符：ss -tnp state close-wait，再去查对应进程的连接管理逻辑"

        if ob_is_num "$synrecv" && ob_cmp "$synrecv" ">" "50"; then
            ob_warn "net.syn_recv" "SYN_RECV 半连接数" "$synrecv" "低于 50 条" \
                "半连接队列堆积可能是 SYN Flood 攻击，也可能是 accept 队列溢出（应用处理连接太慢）。检查 net.ipv4.tcp_max_syn_backlog 与应用的 listen backlog，并用 ss -lnt 查看 Send-Q"
        else
            ob_ok "net.syn_recv" "SYN_RECV 半连接数" "$synrecv" "低于 50 条" "-"
        fi

        ob_ok "net.listen_count" "监听端口数" "$listen 个" "—" "-"
    else
        ob_unknown "net.tcp_total" "TCP 连接总数" "无法读取 /proc/net/tcp" "低于 ${OB_CFG_TCP_WARN} 条" \
            "确认 /proc/net/tcp 可读"
    fi

    # ---------------------------------------------------------- 监听端口 ----
    local ports port_count
    ports="$(ob_listen_ports 2>/dev/null || true)"
    if [ -n "$ports" ]; then
        port_count="$(printf '%s\n' "$ports" | LC_ALL=C wc -l | tr -d ' ')"
        ob_ok "net.listen_ports" "监听端口清单" \
            "$(ob_flatten "$(printf '%s' "$ports" | LC_ALL=C awk '{ printf "%s ", $2 }')")" \
            "共 ${port_count} 个端口" "-"

        # 暴露到 0.0.0.0 的敏感端口值得单独提醒（安全模块也会覆盖，这里给出运行视角）
        local wide
        wide="$(printf '%s\n' "$ports" | LC_ALL=C grep -E '\*:(3306|5432|6379|27017|9200|11211|2375|2379)$' 2>/dev/null || true)"
        if [ -n "$wide" ]; then
            ob_warn "net.sensitive_ports" "对全网暴露的敏感端口" "$(ob_flatten "$wide")" "应仅监听内网地址" \
                "数据库/缓存类端口监听了所有地址。请改为 bind 内网网卡或在防火墙层限制来源 IP"
        fi
    else
        ob_unknown "net.listen_ports" "监听端口清单" "无法获取（缺少 ss 且无 /proc/net/tcp）" "可列出" \
            "安装 iproute2 以获得 ss 命令，或确认 /proc/net/tcp 可读"
    fi

    # ---------------------------------------------------------- conntrack ----
    local ct_count ct_max ct_pct
    ct_count="$(ob_kernel_param "net/netfilter/nf_conntrack_count" 2>/dev/null || true)"
    ct_max="$(ob_kernel_param "net/netfilter/nf_conntrack_max" 2>/dev/null || true)"
    if ob_is_int "$ct_count" && ob_is_int "$ct_max" && [ "$ct_max" -gt 0 ]; then
        ct_pct="$(LC_ALL=C awk -v c="$ct_count" -v m="$ct_max" 'BEGIN { printf "%.2f", c * 100 / m }')"
        ob_check_threshold "net.conntrack" "conntrack 表使用率" "$ct_pct" \
            "${OB_CFG_CONNTRACK_WARN:-80}" "${OB_CFG_CONNTRACK_CRIT:-95}" high "%" \
            "已用 ${ct_count}/${ct_max}。连接跟踪表满时新连接会被直接丢弃，现象是「主机能 ping 通但服务连不上」，且 dmesg 会出现 nf_conntrack: table full, dropping packet。请调大 nf_conntrack_max 与 hashsize，或缩短 tcp_timeout_established"
    else
        ob_unknown "net.conntrack" "conntrack 表使用率" "内核未加载 nf_conntrack 或不可读" "低于 ${OB_CFG_CONNTRACK_WARN:-80}%" \
            "若机器不承担 NAT/防火墙转发，此项可以忽略；可在配置中用 OB_CFG_DISABLE_CHECKS=net.conntrack 静音"
    fi

    # ---------------------------------------------------------- 路由 ----
    local routes
    routes="$(ob_default_routes 2>/dev/null || true)"
    if ob_have ip; then
        if [ -n "$routes" ]; then
            ob_ok "net.default_route" "默认路由" "$(ob_flatten "$routes")" "存在默认路由" "-"
        else
            ob_crit "net.default_route" "默认路由" "没有默认路由" "存在默认路由" \
                "缺少默认路由会导致只能访问同网段地址，所有外网/跨网段请求失败。检查 ip route 与网卡配置文件（NetworkManager / systemd-networkd / netplan 是否互相覆盖）"
        fi
    else
        ob_unknown "net.default_route" "默认路由" "缺少 ip 命令" "存在默认路由" \
            "安装 iproute2 后重试"
    fi

    return 0
}

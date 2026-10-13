#!/usr/bin/env bash
# ==============================================================================
# opsbox :: modules/80-security.sh
# 安全基线：特权账户、空密码、SSH 暴露面、防火墙、强制访问控制、内核转发
#
# 定位说明：
#   这不是一个漏洞扫描器，也不替代 CIS Benchmark 工具。
#   它只覆盖「日常运维中真正会出事、且一条命令就能查出来」的那几项——
#   多一个 UID 0 账户、SSH 允许 root 密码登录、防火墙没开，
#   这三件事造成的真实入侵事件远多于任何 0day。
# ==============================================================================

ob_module_security() {
    OB_MODULE="security"

    # ---------------------------------------------------------- UID 0 账户 ----
    local uid0 extra
    uid0="$(ob_uid0_accounts 2>/dev/null || true)"
    if [ -n "$uid0" ]; then
        extra="$(printf '%s\n' "$uid0" | LC_ALL=C grep -vx 'root' 2>/dev/null || true)"
        if [ -n "$extra" ]; then
            ob_crit "sec.uid0" "UID 为 0 的特权账户" "$(ob_flatten "$extra")" "仅允许 root" \
                "存在除 root 之外的 UID 0 账户。这是典型的权限维持后门手法，也可能是一个错误的系统集成。请核对 /etc/passwd 并确认是否为业务需要；若为异常账户，按应急流程处理（禁用账户、审计登录历史、排查同批变更）"
        else
            ob_ok "sec.uid0" "UID 为 0 的特权账户" "仅 root" "仅允许 root" "-"
        fi
    else
        ob_unknown "sec.uid0" "UID 为 0 的特权账户" "无法读取 /etc/passwd" "仅允许 root" \
            "确认 OB_CFG_ETC_ROOT 指向正确的 /etc 目录"
    fi

    # ---------------------------------------------------------- 空密码 ----
    local empty
    empty="$(ob_empty_password_accounts 2>/dev/null || true)"
    if [ -r "${OB_CFG_ETC_ROOT}/shadow" ]; then
        if [ -n "$empty" ]; then
            ob_crit "sec.empty_passwd" "空密码账户" "$(ob_flatten "$empty")" "无空密码账户" \
                "存在可无密码登录的账户。请立即用 passwd -l <账户> 锁定，并确认 /etc/shadow 权限为 000 或 640 root:shadow"
        else
            ob_ok "sec.empty_passwd" "空密码账户" "无" "无空密码账户" "-"
        fi
    else
        ob_unknown "sec.empty_passwd" "空密码账户" "无法读取 /etc/shadow（需要 root）" "无空密码账户" \
            "以 root 身份运行本工具即可完成此项检查；普通用户无法读取 shadow 文件属于正常现象"
    fi

    # ---------------------------------------------------------- SSH ----
    local sshd_conf_found=1
    if [ -r "${OB_CFG_ETC_ROOT}/ssh/sshd_config" ] || [ -r "${OB_CFG_ETC_ROOT}/sshd_config" ]; then
        sshd_conf_found=0
    fi

    if [ "$sshd_conf_found" -ne 0 ]; then
        ob_unknown "sec.ssh_permitroot" "SSH 允许 root 登录" "未找到 sshd_config" "已禁止" \
            "该主机可能未安装 OpenSSH Server，或配置文件位于非标准路径"
    else
        local permitroot passwd_auth port
        permitroot="$(ob_sshd_config_get "PermitRootLogin" 2>/dev/null || true)"
        passwd_auth="$(ob_sshd_config_get "PasswordAuthentication" 2>/dev/null || true)"
        port="$(ob_sshd_config_get "Port" 2>/dev/null || true)"

        case "$permitroot" in
            ""|no|prohibit-password|without-password|forced-commands-only)
                ob_ok "sec.ssh_permitroot" "SSH 允许 root 登录" "${permitroot:-未显式配置（默认 prohibit-password）}" "已禁止或仅密钥" "-"
                ;;
            yes)
                if [ "${OB_CFG_SSHD_WEAK_PERMITROOT:-1}" = "1" ]; then
                    ob_crit "sec.ssh_permitroot" "SSH 允许 root 登录" "PermitRootLogin yes" "no 或 prohibit-password" \
                        "允许 root 直接登录会把暴力破解的目标收敛到最高权限账户上。建议改为 prohibit-password 并使用普通用户 + sudo，同时配合 fail2ban 或密钥登录"
                else
                    ob_warn "sec.ssh_permitroot" "SSH 允许 root 登录" "PermitRootLogin yes" "no 或 prohibit-password" \
                        "按当前配置此项被判为警告。若已用密钥+来源限制做补偿控制，可在 opsbox.conf 中把 OB_CFG_SSHD_WEAK_PERMITROOT 设为 0 降级为忽略"
                fi
                ;;
            *)
                ob_warn "sec.ssh_permitroot" "SSH 允许 root 登录" "PermitRootLogin ${permitroot}" "no 或 prohibit-password" \
                    "非标准取值，请确认 sshd_config 中是否有多处配置互相覆盖（sshd 以首次出现的值为准）"
                ;;
        esac

        case "$passwd_auth" in
            no)
                ob_ok "sec.ssh_passwordauth" "SSH 密码登录" "已禁用（仅密钥）" "建议禁用" "-"
                ;;
            yes)
                ob_warn "sec.ssh_passwordauth" "SSH 密码登录" "PasswordAuthentication yes" "建议禁用" \
                    "密码登录会暴露在持续性的暴力破解之下（看日志里的 Failed password 数量就知道了）。建议切换为密钥登录；若必须保留密码，请务必配合 fail2ban/denyhosts 与强密码策略"
                ;;
            *)
                ob_ok "sec.ssh_passwordauth" "SSH 密码登录" "${passwd_auth:-未显式配置（默认 yes）}" "—" "-"
                ;;
        esac

        ob_ok "sec.ssh_port" "SSH 监听端口" "${port:-22}（默认）" "—" "-"
    fi

    # ---------------------------------------------------------- 防火墙 ----
    local fw mech state
    fw="$(ob_firewall_status 2>/dev/null || printf 'none unknown')"
    set -- $fw
    mech="${1:-none}"; state="${2:-unknown}"

    if [ "$OB_ENV_CONTAINER" = "yes" ]; then
        ob_unknown "sec.firewall" "主机防火墙" "容器环境不适用（${mech} ${state}）" "active" \
            "容器共享宿主内核，防火墙策略应在宿主机或编排层（NetworkPolicy/SecurityGroup）统一管理"
    else
        case "$state" in
            active|running)
                ob_ok "sec.firewall" "主机防火墙" "${mech} ${state}" "active" "-"
                ;;
            inactive|stopped|empty)
                ob_warn "sec.firewall" "主机防火墙" "${mech} ${state}" "active" \
                    "本机未启用任何生效的防火墙规则。若依赖云安全组做边界防护，可在 opsbox.conf 中把本项静音（OB_CFG_DISABLE_CHECKS=sec.firewall）；否则请启用 ufw/firewalld 并只放行必要端口"
                ;;
            *)
                ob_unknown "sec.firewall" "主机防火墙" "${mech} ${state}" "active" \
                    "未检测到 ufw/firewalld/nftables/iptables，无法判定。安装其中任一后重试"
                ;;
        esac
    fi

    # ---------------------------------------------------------- MAC ----
    local mac
    mac="$(ob_mac_status 2>/dev/null || printf 'none')"
    case "$mac" in
        none|unknown)
            ob_warn "sec.mac" "强制访问控制" "未启用 SELinux/AppArmor" "建议启用" \
                "缺少 MAC 层保护意味着即使服务被拿下，攻击者也能直接读取任意文件。Debian/Ubuntu 建议启用 AppArmor，RHEL 系建议保持 SELinux enforcing"
            ;;
        *permissive*)
            ob_warn "sec.mac" "强制访问控制" "$mac" "enforcing" \
                "SELinux 处于宽容模式，只记录不拦截，实际防护为零。确认无阻碍后执行 setenforce 1 并写入 /etc/selinux/config"
            ;;
        *)
            ob_ok "sec.mac" "强制访问控制" "$mac" "已启用" "-"
            ;;
    esac

    # ---------------------------------------------------------- 内核转发 ----
    local ipfwd
    ipfwd="$(ob_kernel_param "net/ipv4/ip_forward" 2>/dev/null || true)"
    if [ -n "$ipfwd" ]; then
        if [ "$ipfwd" = "1" ]; then
            ob_warn "sec.ip_forward" "IPv4 转发" "已开启（ip_forward=1）" "按需开启" \
                "本机开启了 IP 转发。若它是 Kubernetes 节点 / NAT 网关 / Docker 宿主机，这是正常的，可用 OB_CFG_DISABLE_CHECKS=sec.ip_forward 静音；否则请确认是否被意外开启"
        else
            ob_ok "sec.ip_forward" "IPv4 转发" "已关闭" "已关闭" "-"
        fi
    fi

    # ---------------------------------------------------------- SUID（可选）----
    if [ "${OB_CFG_SEC_SUID_ENABLE:-0}" = "1" ]; then
        local suid_list suid_count
        suid_list="$(ob_suid_files "${OB_CFG_SEC_SUID_ROOT:-/usr/bin}" 2>/dev/null || true)"
        suid_count="$(printf '%s\n' "$suid_list" | LC_ALL=C grep -c . 2>/dev/null)"
        ob_is_int "$suid_count" || suid_count=0
        ob_check_threshold "sec.suid" "SUID/SGID 文件数" "$suid_count" \
            "${OB_CFG_SEC_SUID_MAX:-500}" "$(( ${OB_CFG_SEC_SUID_MAX:-500} * 2 ))" high " 个" \
            "SUID 文件数量异常增多，可能意味着有提权后门被植入。请与基线快照对比：find / -xdev -perm -4000 -type f 2>/dev/null | sort"
    fi

    return 0
}

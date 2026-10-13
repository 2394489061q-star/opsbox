#!/usr/bin/env bash
# ==============================================================================
# opsbox :: packaging/uninstall.sh
#
# 卸载 opsbox。设计原则是「删掉安装脚本自己放的东西，绝不碰数据与人的东西」。
#
# ------------------------------------------------------------------ 会删除 ----
#   1. /etc/systemd/system/opsbox.service
#      /etc/systemd/system/opsbox.timer
#      /etc/systemd/system/opsbox-alert.service
#      并先 systemctl disable --now opsbox.timer，然后 daemon-reload。
#   2. /etc/cron.d/opsbox-daily —— 仅当文件里带 "opsbox-managed" 标记
#      （即由 install.sh --with-cron 安装的）。你自己写的 cron 文件同名也保留。
#   3. /usr/local/bin/opsbox —— 仅当它是符号链接。若那里是一个真实文件
#      （别人装的程序、或你手写的包装脚本），本脚本只提示、不删。
#   4. /usr/local/lib/opsbox —— 程序目录本身（主程序 + lib/ + modules/）。
#      删除前会确认该目录里确实有 opsbox 或 lib/，避免路径写错误删无关目录。
#
# ---------------------------------------------------------------- 不会删除 ----
#   1. /etc/opsbox/opsbox.conf —— 你的阈值调优全在这里，升级/重装都不该丢。
#      想彻底清掉请手工执行：rm -rf /etc/opsbox
#   2. /var/log/opsbox/ —— 历史巡检报告（latest.md、report-*.md、cron.log）。
#      想彻底清掉请手工执行：rm -rf /var/log/opsbox
#   3. /etc/opsbox/alert.env 与任何你放在别处的通知脚本。
#   4. 任何不是本安装脚本放的文件：其它包管理器装的 opsbox、你自己加的
#      额外模块或单元覆盖（/etc/systemd/system/opsbox.service.d/ 也保留，
#      但请注意它引用的程序已经被删掉了，需要你自己决定去留）。
#
# 参数必须与安装时一致（尤其是 --prefix/--bin-dir）。用 install.sh 安装的话，
# 直接 `packaging/install.sh --uninstall [同样的参数]` 即可，它会转交到这里。
# ==============================================================================

set -eu

SRC_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"

LIB_DIR="/usr/local/lib/opsbox"
BIN_DIR="/usr/local/bin"
CONF_DIR="/etc/opsbox"
UNIT_DIR="/etc/systemd/system"
REPORT_DIR="/var/log/opsbox"
CRON_FILE="/etc/cron.d/opsbox-daily"

SYSTEMD="auto"

log()  { printf '[opsbox] %s\n' "$*"; }
warn() { printf '[opsbox] 警告：%s\n' "$*" >&2; }
die()  { printf '[opsbox] 错误：%s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
用法： packaging/uninstall.sh [选项]

选项（应与安装时保持一致）：
  --prefix DIR      程序安装目录，默认 /usr/local/lib/opsbox
  --bin-dir DIR     命令入口所在目录，默认 /usr/local/bin
  --conf-dir DIR    配置目录（仅用于提示，脚本不会删它），默认 /etc/opsbox
  --unit-dir DIR    systemd 单元目录，默认 /etc/systemd/system
  --report-dir DIR  报告目录（仅用于提示，脚本不会删它），默认 /var/log/opsbox
  --no-systemd      不触碰 systemd（例如单元由配置管理工具维护）
  -h, --help        显示本帮助

本脚本会删除什么、不会删除什么，见文件头部注释（也会在运行时打印一遍）。
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --prefix)        [ "$#" -ge 2 ] || die "--prefix 缺少参数"; LIB_DIR="$2"; shift 2 ;;
        --prefix=*)      LIB_DIR="${1#*=}"; shift ;;
        --bin-dir)       [ "$#" -ge 2 ] || die "--bin-dir 缺少参数"; BIN_DIR="$2"; shift 2 ;;
        --bin-dir=*)     BIN_DIR="${1#*=}"; shift ;;
        --conf-dir)      [ "$#" -ge 2 ] || die "--conf-dir 缺少参数"; CONF_DIR="$2"; shift 2 ;;
        --conf-dir=*)    CONF_DIR="${1#*=}"; shift ;;
        --unit-dir)      [ "$#" -ge 2 ] || die "--unit-dir 缺少参数"; UNIT_DIR="$2"; shift 2 ;;
        --unit-dir=*)    UNIT_DIR="${1#*=}"; shift ;;
        --report-dir)    [ "$#" -ge 2 ] || die "--report-dir 缺少参数"; REPORT_DIR="$2"; shift 2 ;;
        --report-dir=*)  REPORT_DIR="${1#*=}"; shift ;;
        --no-systemd)    SYSTEMD="no"; shift ;;
        -h|--help)       usage; exit 0 ;;
        *)               die "未知参数：$1（用 --help 查看用法）" ;;
    esac
done

# ------------------------------------------------------------ 危险路径护栏 ----
# rm -rf 的目标必须是一个「看起来就是 opsbox 安装目录」的绝对路径。
# 少了这层检查，一个手误的 --prefix / 就足够毁掉整台机器。
guard_lib_dir() {
    case "$LIB_DIR" in
        ""|"/"|"/usr"|"/usr/local"|"/usr/lib"|"/lib"|"/opt"|"/etc"|"/var"|"/home"|"/root")
            die "拒绝操作可疑路径：$LIB_DIR（这不在 opsbox 的正常安装位置里）" ;;
        /*) ;;
        *)  die "程序目录必须是绝对路径：$LIB_DIR" ;;
    esac
    if [ ! -d "$LIB_DIR" ]; then
        log "程序目录不存在，无需删除：$LIB_DIR"
        return 1
    fi
    if [ ! -f "$LIB_DIR/opsbox" ] && [ ! -d "$LIB_DIR/lib" ]; then
        warn "$LIB_DIR 里既没有 opsbox 也没有 lib/，看起来不是 opsbox 的安装目录，跳过删除"
        return 1
    fi
    return 0
}

systemd_available() {
    command -v systemctl >/dev/null 2>&1 || return 1
    [ -d /run/systemd/system ] || return 1
    return 0
}

# ---------------------------------------------------------------- 步骤 ----
remove_systemd() {
    local name f removed=0
    if [ "$SYSTEMD" = "no" ]; then
        log "已指定 --no-systemd，跳过 systemd 相关操作"
        return 0
    fi
    if ! systemd_available; then
        log "未检测到正在运行的 systemd，只清理单元文件"
    else
        # 先停定时器：否则删掉单元文件后它还可能被触发一次
        if systemctl disable --now opsbox.timer >/dev/null 2>&1; then
            log "已停止并禁用 opsbox.timer"
        else
            log "opsbox.timer 未在运行或未启用，无需停止"
        fi
    fi
    for name in opsbox.service opsbox.timer opsbox-alert.service; do
        f="$UNIT_DIR/$name"
        if [ -e "$f" ]; then
            rm -f -- "$f"
            log "已删除单元：$f"
            removed=1
        fi
    done
    if [ "$removed" -eq 1 ] && systemd_available; then
        if systemctl daemon-reload; then
            log "已执行 systemctl daemon-reload"
        else
            warn "systemctl daemon-reload 失败，请手工执行"
        fi
    fi
    # 不删 $UNIT_DIR/opsbox.service.d/：那是运维自己写的覆盖片段，
    # 我们无法判断内容是否还有用，交给人决定。
    if [ -d "$UNIT_DIR/opsbox.service.d" ]; then
        warn "$UNIT_DIR/opsbox.service.d/ 存在（你自己写的单元覆盖），已保留；程序删除后它可能失效，请自行确认"
    fi
    return 0
}

remove_cron() {
    if [ ! -e "$CRON_FILE" ]; then
        return 0
    fi
    if grep -q 'opsbox-managed' -- "$CRON_FILE" 2>/dev/null; then
        rm -f -- "$CRON_FILE"
        log "已删除 cron 任务：$CRON_FILE"
    else
        log "保留非本脚本安装的 cron 文件：$CRON_FILE"
    fi
    return 0
}

remove_entrypoint() {
    local link="$BIN_DIR/opsbox"
    if [ -L "$link" ]; then
        rm -f -- "$link"
        log "已删除符号链接：$link"
    elif [ -e "$link" ]; then
        warn "$link 是真实文件（不是本脚本创建的符号链接），已保留。请自行确认它是什么"
    fi
    return 0
}

remove_program() {
    if guard_lib_dir; then
        rm -rf -- "$LIB_DIR"
        log "已删除程序目录：$LIB_DIR"
    fi
    return 0
}

# ---------------------------------------------------------------- 主流程 ----
log "本次将会处理："
log "  程序目录：$LIB_DIR"
log "  命令入口：$BIN_DIR/opsbox（仅当是符号链接）"
log "  单元目录：$UNIT_DIR/opsbox.{service,timer}、opsbox-alert.service"
log "  cron 文件：$CRON_FILE（仅当带 opsbox-managed 标记）"

remove_systemd
remove_cron
remove_entrypoint
remove_program

cat <<EOF

[opsbox] 卸载完成。以下内容被有意保留（需要时请自行删除）：
  配置文件：$CONF_DIR/opsbox.conf        —— 你的阈值调优，重装时会自动沿用
  配置目录：$CONF_DIR/                   —— 以及 alert.env 等你自己放进去的文件
  报告目录：$REPORT_DIR/                 —— 历史巡检报告，一键清理：rm -rf $REPORT_DIR
  单元覆盖：$UNIT_DIR/opsbox.service.d/  —— 如果存在的话

[opsbox] 提示：若安装时用了 --prefix/--bin-dir 等参数，请确认本次卸载带了同样的参数。
EOF

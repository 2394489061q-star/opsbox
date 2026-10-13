#!/usr/bin/env bash
# ==============================================================================
# opsbox :: packaging/install.sh
#
# 把仓库里的 opsbox 安装成系统级的「可执行命令 + 配置 + 定时任务」。
#
# 安装后的布局（默认值，全部可用参数改写）：
#   /usr/local/lib/opsbox/opsbox       主程序（0755）
#   /usr/local/lib/opsbox/lib/*.sh     库（0644）
#   /usr/local/lib/opsbox/modules/*.sh 模块（0644）
#   /usr/local/bin/opsbox              -> 指向 /usr/local/lib/opsbox/opsbox 的符号链接
#   /etc/opsbox/opsbox.conf            配置（已存在则保留，绝不覆盖）
#   /etc/systemd/system/opsbox.{service,timer} + opsbox-alert.service
#   /etc/cron.d/opsbox-daily           仅 --with-cron 时安装
#   /var/log/opsbox/                   报告落盘目录（0750）
#
# ------------------------------------------------------------------------------
# 两个决定安装形态的关键事实（都来自阅读主程序源码，不是约定俗成）：
#
# 1) 命令入口必须是「符号链接」，不能是包装脚本。
#    主程序 opsbox 启动第一件事就是定位自己的安装目录：
#        ob_resolve_self_dir() { while [ -L "$src" ]; do ... readlink ...; done; cd -P ...; }
#    它显式跟踪 BASH_SOURCE[0] 的符号链接链，直到真实文件，然后
#        OB_ROOT_DIR=<真实文件所在目录>   OB_LIB_DIR=$OB_ROOT_DIR/lib   OB_MODULE_DIR=$OB_ROOT_DIR/modules
#    再从这两个目录 source lib/*.sh 与 modules/*.sh（见 opsbox 第 16-51 行）。
#    所以：
#      - 符号链接方案可行：调用 /usr/local/bin/opsbox 时 BASH_SOURCE[0] 是链接路径，
#        主程序自己把链接解析回 /usr/local/lib/opsbox，lib/ 与 modules/ 都能找到。
#      -「source 型」包装脚本一定失败：例如 `. /usr/local/lib/opsbox/opsbox "$@"`，
#        被 source 时 BASH_SOURCE[0] 是包装脚本自身的路径，OB_ROOT_DIR 会变成
#        /usr/local/bin，于是 $OB_LIB_DIR/core.sh 不存在，主程序以退出码 4 结束。
#      - `exec /usr/local/lib/opsbox/opsbox "$@"` 型包装脚本能工作（exec 之后是新进程，
#        脚本路径是真实路径），但多一层文件、还容易被后来的人编辑坏，
#        所以这里选符号链接。
#
# 2) 配置分两份装，各司其职：
#      $LIB_DIR/conf/opsbox.conf  —— 随本版本分发的「默认值」，升级时会被替换；
#      /etc/opsbox/opsbox.conf    —— 运维的「覆盖项」，已存在则永不覆盖。
#    主程序的配置加载顺序（后者覆盖前者，即优先级由低到高）：
#        内置默认值 → <安装目录>/conf/opsbox.conf → /etc/opsbox/opsbox.conf
#        → ~/.config/opsbox/opsbox.conf → --conf 指定文件
#    安装目录里的默认值排在 /etc 之前，所以它不会压掉运维在 /etc 里的调优；
#    而升级时它随程序一起更新，没被 /etc 覆盖过的项会自动跟进新默认值。
#
# 幂等：重复执行不会产生副作用——内容相同的文件不改 mtime，软链已正确就重建为同值，
#       已存在的配置永不覆盖，systemd 的 enable/daemon-reload 本身是幂等的。
# ==============================================================================

set -eu

PROG="opsbox"
SRC_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"

# 默认安装位置，与 systemd/ 下的单元文件里写死的路径保持一致
LIB_DIR="/usr/local/lib/opsbox"
BIN_DIR="/usr/local/bin"
CONF_DIR="/etc/opsbox"
UNIT_DIR="/etc/systemd/system"
REPORT_DIR="/var/log/opsbox"
CRON_FILE="/etc/cron.d/opsbox-daily"

SYSTEMD="auto"   # auto | yes | no
WITH_CRON=0
ACTION="install"

TMP_FILES=()

cleanup() {
    local f
    for f in "${TMP_FILES[@]:-}"; do
        [ -n "$f" ] && rm -f -- "$f"
    done
    return 0
}
trap cleanup EXIT

# ---------------------------------------------------------------- 输出 ----
log()  { printf '[opsbox] %s\n' "$*"; }
warn() { printf '[opsbox] 警告：%s\n' "$*" >&2; }
die()  { printf '[opsbox] 错误：%s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
用法： packaging/install.sh [选项]

选项：
  --prefix DIR      程序安装目录（主程序 + lib/ + modules/），默认 /usr/local/lib/opsbox
  --bin-dir DIR     命令入口所在目录，默认 /usr/local/bin
  --conf-dir DIR    配置文件所在目录，默认 /etc/opsbox
  --unit-dir DIR    systemd 单元目录，默认 /etc/systemd/system
  --report-dir DIR  报告落盘目录，默认 /var/log/opsbox
  --no-systemd      即使检测到 systemd 也不安装单元（例如由配置管理工具自己管单元）
  --with-cron       额外安装 /etc/cron.d/opsbox-daily（与 systemd timer 二选一，别都开）
  --uninstall       转交给 packaging/uninstall.sh（其余选项原样传递，保证前缀一致）
  -h, --help        显示本帮助

说明：
  * 本脚本不会覆盖已存在的 /etc/opsbox/opsbox.conf。
  * 卸载时执行 packaging/uninstall.sh 或本脚本加 --uninstall；
    卸载会保留配置与你自己的报告文件，详见 uninstall.sh 的说明。
EOF
}

# ---------------------------------------------------------------- 参数 ----
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
        --with-cron)     WITH_CRON=1; shift ;;
        --uninstall)     ACTION="uninstall"; shift ;;
        -h|--help)       usage; exit 0 ;;
        *)               die "未知参数：$1（用 --help 查看用法）" ;;
    esac
done

# 路径会被塞进 sed 的替换串，含 | & \ 或空白会破坏替换或改写结果，直接拒绝
check_path() { # <选项名> <值>
    case "$2" in
        /*) ;;
        *) die "$1 必须是绝对路径：$2" ;;
    esac
    case "$2" in
        *'|'*|*'&'*|*'\'*) die "$1 不能包含 | & \\ 这些字符：$2" ;;
    esac
    case "$2" in
        *' '*|*$'\t'*) die "$1 不能包含空白字符：$2" ;;
    esac
    return 0
}

check_path "--prefix"     "$LIB_DIR"
check_path "--bin-dir"    "$BIN_DIR"
check_path "--conf-dir"   "$CONF_DIR"
check_path "--unit-dir"   "$UNIT_DIR"
check_path "--report-dir" "$REPORT_DIR"

# ---------------------------------------------------------------- 卸载转交 ----
# 卸载逻辑只写在 uninstall.sh 里，避免两处实现随时间漂移。
# 这里把已解析出的路径原样传回去，保证「用 --prefix 装的就用同一个前缀卸」。
if [ "$ACTION" = "uninstall" ]; then
    set -- --prefix "$LIB_DIR" --bin-dir "$BIN_DIR" --conf-dir "$CONF_DIR" \
        --unit-dir "$UNIT_DIR" --report-dir "$REPORT_DIR"
    if [ "$SYSTEMD" = "no" ]; then
        set -- "$@" --no-systemd
    fi
    exec "$SRC_DIR/packaging/uninstall.sh" "$@"
fi

# ---------------------------------------------------------------- 工具 ----
require_sources() {
    [ -f "$SRC_DIR/opsbox" ] || die "找不到主程序：$SRC_DIR/opsbox（请从项目仓库内的 packaging/ 目录运行本脚本）"
    [ -d "$SRC_DIR/lib" ] || die "找不到库目录：$SRC_DIR/lib"
    [ -d "$SRC_DIR/modules" ] || die "找不到模块目录：$SRC_DIR/modules"
    [ -f "$SRC_DIR/conf/opsbox.conf" ] || die "找不到配置模板：$SRC_DIR/conf/opsbox.conf"
    return 0
}

install_file() { # <源文件> <目标文件> <权限>
    local src="$1" dst="$2" mode="$3"
    if [ -f "$dst" ] && cmp -s -- "$src" "$dst"; then
        # 内容一致就不再写一次：避免无意义的 mtime 变化（幂等的关键）
        chmod "$mode" -- "$dst" 2>/dev/null || true
        log "内容一致，跳过：$dst"
        return 0
    fi
    mkdir -p -- "$(dirname -- "$dst")"
    install -m "$mode" -- "$src" "$dst"
    log "已安装：$dst"
    return 0
}

render_to() { # <源文件> <目标文件> <权限> —— 把单元/示例里的默认路径改写成实际安装路径
    local src="$1" dst="$2" mode="$3" tmp
    [ -f "$src" ] || { warn "源文件不存在，跳过：$src"; return 0; }
    mkdir -p -- "$(dirname -- "$dst")"
    tmp="$(dirname -- "$dst")/.$(basename -- "$dst").install.$$.tmp"
    TMP_FILES+=("$tmp")
    sed -e "s|/usr/local/lib/opsbox|$LIB_DIR|g" \
        -e "s|/usr/local/bin/opsbox|$BIN_DIR/opsbox|g" \
        -e "s|/etc/opsbox|$CONF_DIR|g" \
        -e "s|/var/log/opsbox|$REPORT_DIR|g" \
        -- "$src" > "$tmp"
    if [ -f "$dst" ] && cmp -s -- "$tmp" "$dst"; then
        rm -f -- "$tmp"
        chmod "$mode" -- "$dst" 2>/dev/null || true
        log "内容一致，跳过：$dst"
        return 0
    fi
    chmod "$mode" -- "$tmp"
    mv -f -- "$tmp" "$dst"
    log "已安装：$dst"
    return 0
}

systemd_available() {
    command -v systemctl >/dev/null 2>&1 || return 1
    # 关键判据是「systemd 是否作为 init 在跑」：容器里常常有 systemctl 命令，
    # 但 PID 1 不是 systemd，此时 enable 会静默失败或写坏 /etc/systemd/system。
    [ -d /run/systemd/system ] || return 1
    return 0
}

# ---------------------------------------------------------------- 安装步骤 ----
install_program() {
    local f
    mkdir -p -- "$LIB_DIR/lib" "$LIB_DIR/modules"
    install_file "$SRC_DIR/opsbox" "$LIB_DIR/opsbox" 0755
    for f in "$SRC_DIR"/lib/*.sh; do
        [ -f "$f" ] || continue
        install_file "$f" "$LIB_DIR/lib/$(basename -- "$f")" 0644
    done
    for f in "$SRC_DIR"/modules/*.sh; do
        [ -f "$f" ] || continue
        install_file "$f" "$LIB_DIR/modules/$(basename -- "$f")" 0644
    done
    # 把 conf/opsbox.conf 作为「本版本的默认值」一并装到 $LIB_DIR/conf/。
    # 它在主程序的加载顺序里排在 /etc/opsbox/opsbox.conf 之前（优先级更低），
    # 所以不会覆盖运维的调优；而升级时它会随程序一起更新，
    # 没在 /etc 里覆盖过的配置项会自动跟进新默认值。
    if [ -f "$SRC_DIR/conf/opsbox.conf" ]; then
        mkdir -p -- "$LIB_DIR/conf"
        install_file "$SRC_DIR/conf/opsbox.conf" "$LIB_DIR/conf/opsbox.conf" 0644
    fi
    return 0
}

install_entrypoint() {
    local target="$LIB_DIR/opsbox" link="$BIN_DIR/opsbox"
    mkdir -p -- "$BIN_DIR"
    if [ -L "$link" ]; then
        if [ "$(readlink -- "$link")" = "$target" ]; then
            log "符号链接已正确，跳过：$link -> $target"
        else
            ln -sfn -- "$target" "$link"
            log "已更新符号链接：$link -> $target"
        fi
    elif [ -e "$link" ]; then
        # 绝不覆盖真实文件：那可能是别人装的另一个 opsbox，或者运维自己的包装脚本
        die "$link 已存在且不是符号链接。本脚本不覆盖真实文件，请先自行确认并移除它，再重试"
    else
        ln -s -- "$target" "$link"
        log "已创建符号链接：$link -> $target"
    fi
    return 0
}

install_config() {
    local dst="$CONF_DIR/opsbox.conf"
    mkdir -p -- "$CONF_DIR"
    if [ -e "$dst" ]; then
        log "配置已存在，保留不覆盖：$dst"
        log "  （升级后想同步模板里的新配置项，请自行对照 $SRC_DIR/conf/opsbox.conf 合并）"
        return 0
    fi
    install -m 0644 -- "$SRC_DIR/conf/opsbox.conf" "$dst"
    log "已安装默认配置：$dst"
    return 0
}

install_report_dir() {
    mkdir -p -- "$REPORT_DIR"
    # 报告里含主机名、内核版本、失败单元、日志摘录，没有必要让所有本地用户都读到
    chmod 0750 -- "$REPORT_DIR" 2>/dev/null || true
    log "报告目录就绪：$REPORT_DIR"
    return 0
}

install_systemd() {
    local name
    if [ "$SYSTEMD" = "no" ]; then
        log "已指定 --no-systemd，跳过 systemd 单元安装"
        return 0
    fi
    if ! systemd_available; then
        log "未检测到正在运行的 systemd，跳过 systemd 单元安装"
        log "  如果这台机器本来就该用 systemd，请确认 PID 1 是 systemd 后重跑本脚本；"
        log "  否则可以改用 cron 方案： packaging/install.sh --with-cron"
        return 0
    fi
    for name in opsbox.service opsbox.timer opsbox-alert.service; do
        render_to "$SRC_DIR/systemd/$name" "$UNIT_DIR/$name" 0644
    done
    if ! systemctl daemon-reload; then
        warn "systemctl daemon-reload 失败，请手工执行后再启用定时器"
    fi
    # 只启用 timer：opsbox.service 是 oneshot 且刻意没有 [Install] 段，
    # 对它执行 enable 会报「单元没有安装配置(no installation config)」。
    if systemctl enable --now opsbox.timer; then
        log "已启用定时器：opsbox.timer（用 systemctl list-timers opsbox.timer 查看下次触发时间）"
    else
        warn "systemctl enable --now opsbox.timer 失败，请手工检查单元与权限"
    fi
    log "提醒：systemd timer 与 cron 任务同时存在会让巡检跑两遍，请只保留一种"
    return 0
}

install_cron() {
    local src="$SRC_DIR/examples/cron/opsbox-daily"
    if [ ! -d /etc/cron.d ]; then
        warn "/etc/cron.d 不存在（这台机器可能没装 cron），跳过 cron 任务安装"
        return 0
    fi
    render_to "$src" "$CRON_FILE" 0644
    # cron 对 /etc/cron.d 下的文件有硬性要求：属主 root:root，且对组/其他不可写，
    # 否则整份文件被静默忽略，表现为「装好了但永远不跑」。
    chown root:root -- "$CRON_FILE" 2>/dev/null || true
    chmod 0644 -- "$CRON_FILE" 2>/dev/null || true
    log "已安装 cron 任务：$CRON_FILE"
    return 0
}

# ---------------------------------------------------------------- 主流程 ----
require_sources

if [ "$(id -u)" -ne 0 ]; then
    warn "当前用户不是 root：写入 $LIB_DIR 等系统路径很可能因权限不足而失败"
    warn "如需用户级安装，请把 --prefix/--bin-dir/--conf-dir/--unit-dir/--report-dir 都指到可写目录"
fi

log "源目录：  $SRC_DIR"
log "程序目录：$LIB_DIR"
log "命令入口：$BIN_DIR/$PROG"
log "配置目录：$CONF_DIR"
log "报告目录：$REPORT_DIR"

install_program
install_entrypoint
install_config
install_report_dir
install_systemd

if [ "$WITH_CRON" -eq 1 ]; then
    install_cron
elif [ -f "$CRON_FILE" ]; then
    # 幂等：不因为这次没带 --with-cron 就去动别人已经装好的 cron
    if grep -q 'opsbox-managed' -- "$CRON_FILE" 2>/dev/null; then
        log "已存在受管的 cron 任务，本次未改动：$CRON_FILE"
        log "  若不再需要它，请执行 packaging/uninstall.sh（会一并回收该文件）"
    else
        warn "$CRON_FILE 已存在但不是本脚本安装的，保持原样不动"
    fi
fi

cat <<EOF

[opsbox] 安装完成。下一步：
  1) 按需编辑配置：$CONF_DIR/opsbox.conf（本脚本永不覆盖它）
  2) 手工试跑一次：$BIN_DIR/$PROG check
  3) 查看定时器：systemctl list-timers $PROG.timer
  4) 查看报告：  $REPORT_DIR/latest.md
  卸载：packaging/uninstall.sh（安装时用了 --prefix 等参数的话，卸载要带同样的参数）
EOF

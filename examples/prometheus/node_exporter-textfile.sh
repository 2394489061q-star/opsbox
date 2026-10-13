#!/bin/sh
# ==============================================================================
# opsbox :: examples/prometheus/node_exporter-textfile.sh
#
# 用途：把 `opsbox check -f prom` 的输出（Prometheus 文本格式）写进
#       node_exporter 的 textfile collector 目录，让 Prometheus 通过
#       node_exporter 就能采集到 opsbox 的巡检指标，不需要额外 exporter。
#
#       textfile 目录位置随发行版/部署方式不同，可用环境变量覆盖：
#         Debian/Ubuntu 官方包： /var/lib/node_exporter/textfile
#         RHEL 系部分安装方式： /var/lib/node_exporter/textfile_collector
#       本脚本默认 Debian 路径，覆盖方式见下面 OPSBOX_TEXTFILE_DIR。
#
# ------------------------------------------------------ 为什么必须原子替换 ----
# 绝对不要直接 `opsbox check -f prom -o <目标文件>`！
#   主程序的 -o 实现是 `exec >"$OB_OUTPUT"`：它先把目标文件截断成 0 字节，
#   再一条条往里写。node_exporter 与 Prometheus 的采集是完全异步的，
#   只要采集刚好落在这个窗口里，就会读到空文件或半个文件——表现为指标突然消失，
#   或者 HELP/TYPE 与样本不匹配的解析错误。
# 正确做法是「先写同目录下的临时文件，再 rename」：
#   同一文件系统内的 rename(2) 是原子的，读方要么看到完整的旧文件，
#   要么看到完整的新文件，永远看不到中间态。
# 关键细节：临时文件必须与目标文件在同一个目录（同一文件系统），
#   否则 mv 会退化成「跨设备复制+删除」，原子性立刻消失。
#   所以这里绝不把临时文件放 /tmp。
# 另外临时文件名以点号开头、且不以 .prom 结尾：node_exporter 只收集 *.prom，
#   双保险确保采集器永远不会把我们的半成品当成指标文件。
#
# 退出码处理：opsbox 有 WARN/CRIT 时返回 1/2，这是「巡检成功完成」的正常结果，
#   此时指标文件是完整有效的（状态本身就在 opsbox_overall_status 里），
#   所以脚本必须继续落盘，并且自己以 0 结束——否则 cron 每隔几分钟就发一封失败邮件。
#   只有 3（用法错误）/4（采集失败）才说明这次输出不可信，此时保留上一份指标文件不动。
#
# 调度：交给 cron 或 systemd timer 即可（例如每分钟一次），本脚本不自己循环。
# ==============================================================================

set -u

OPSBOX_BIN="${OPSBOX_BIN:-/usr/local/bin/opsbox}"
TEXTFILE_DIR="${OPSBOX_TEXTFILE_DIR:-/var/lib/node_exporter/textfile}"
PROM_NAME="${OPSBOX_PROM_NAME:-opsbox.prom}"

# 覆盖写之前先算好路径。$$ 是当前进程号，保证并发执行时互不干扰。
TMP_FILE="$TEXTFILE_DIR/.$PROM_NAME.$$"
OUT_FILE="$TEXTFILE_DIR/$PROM_NAME"

# 任何异常退出路径都要清掉临时文件，避免 textfile 目录里堆积垃圾
trap 'rm -f "$TMP_FILE"' EXIT INT TERM HUP

if [ ! -x "$OPSBOX_BIN" ]; then
    printf 'opsbox 可执行文件不存在或不可执行：%s（用 OPSBOX_BIN 指定正确路径）\n' "$OPSBOX_BIN" >&2
    exit 1
fi

if ! mkdir -p "$TEXTFILE_DIR"; then
    printf '无法创建 textfile 目录：%s\n' "$TEXTFILE_DIR" >&2
    exit 1
fi

# 不要写 set -e：opsbox 返回 1/2 属于预期结果，必须自己接住退出码
rc=0
"$OPSBOX_BIN" check -f prom >"$TMP_FILE" 2>/dev/null || rc=$?

case "$rc" in
    0|1|2)
        # 0=全部通过 1=存在 WARN 2=存在 CRIT：巡检本身跑完了，输出可信
        ;;
    3|4)
        # 3=用法错误 4=采集失败：这次的输出不可信，宁可不更新，也不要污染已有指标
        printf 'opsbox 退出码 %s（3=用法错误 4=采集失败），本次保留上一份指标文件不更新\n' "$rc" >&2
        exit "$rc"
        ;;
    *)
        printf 'opsbox 返回了未知退出码 %s，本次不更新指标文件\n' "$rc" >&2
        exit "$rc"
        ;;
esac

if [ ! -s "$TMP_FILE" ]; then
    # 空文件一旦 rename 到目标位置，Prometheus 侧就是「指标全部消失」
    printf 'opsbox 输出为空，拒绝用空文件覆盖已有指标\n' >&2
    exit 4
fi

chmod 0644 "$TMP_FILE" 2>/dev/null || true

# 原子替换：这一步之后读方才可能看到新内容，且一定看到的是完整内容
if ! mv -f "$TMP_FILE" "$OUT_FILE"; then
    printf '原子替换失败：%s -> %s\n' "$TMP_FILE" "$OUT_FILE" >&2
    exit 1
fi

# 成功后撤销 trap，免得把已经改名走的目标路径又删一次
trap - EXIT INT TERM HUP

# 以 0 退出：巡检结论已经体现在 opsbox_overall_status / opsbox_check_status 指标里，
# 由 Prometheus 规则负责告警，不需要 cron 再报一次「命令失败」。
printf 'opsbox 指标已更新：%s（opsbox 退出码 %s）\n' "$OUT_FILE" "$rc"
exit 0

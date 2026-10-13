#!/bin/sh
# ==============================================================================
# opsbox :: examples/alert/webhook.sh
#
# 用途：从标准输入读入 opsbox 的一行摘要（`opsbox check -f oneline` 的输出），
#       用 curl POST 到一个 HTTP webhook——钉钉/飞书/企业微信/Slack 的机器人网关、
#       自建告警中转、或任何能收文本的端点。
#
# 用法一（手工验证；注意本脚本只认 stdin，不接受命令行参数）：
#     opsbox check -f oneline --fail-on never | ./webhook.sh
# 用法二（接给 systemd 告警单元，见 systemd/opsbox-alert.service）：
#     在 /etc/opsbox/alert.env 里写：
#         OPSBOX_ALERT_CMD=/usr/local/lib/opsbox/examples/alert/webhook.sh
#         OPSBOX_WEBHOOK_URL=https://example.invalid/hooks/xxxx
#     单元通过 EnvironmentFile 注入环境变量，单元文件里没有任何密钥。
#
# ------------------------------------------------- 为什么地址必须来自环境变量 ----
# webhook 地址里的那段随机串就是凭证：谁拿到它，谁就能往那个群里发消息。
# 一旦把真实地址写进脚本并提交进 Git，等于把推送权限公开发布。
# 所以本脚本不提供任何默认地址；没设置 OPSBOX_WEBHOOK_URL 就直接失败退出，
# 而不是「悄悄发出去」或「悄悄不发了」。
#
# 可选环境变量：
#   OPSBOX_WEBHOOK_URL           必填，目标地址
#   OPSBOX_WEBHOOK_CONTENT_TYPE  默认 text/plain; charset=utf-8
#                                （发 JSON 的机器人网关可改成 application/json，
#                                  但那样正文需要自己再包一层 JSON，本示例不代做）
#   OPSBOX_WEBHOOK_AUTH_HEADER   额外的请求头，例如 "Authorization: Bearer xxx"
#   OPSBOX_WEBHOOK_TIMEOUT       curl 超时秒数，默认 10
#
# 退出码：0=发送成功（HTTP 2xx）；非 0=未配置、参数为空或 curl 失败。
#         非 0 会让 systemd 把 opsbox-alert.service 记为 failed，
#         从而在 journal 里留下「通知失败了」的痕迹——通知失败本身也必须可见。
# ==============================================================================

set -eu

WEBHOOK_URL="${OPSBOX_WEBHOOK_URL:-}"
CONTENT_TYPE="${OPSBOX_WEBHOOK_CONTENT_TYPE:-text/plain; charset=utf-8}"
AUTH_HEADER="${OPSBOX_WEBHOOK_AUTH_HEADER:-}"
TIMEOUT="${OPSBOX_WEBHOOK_TIMEOUT:-10}"

die() {
    printf '[opsbox-webhook] 错误：%s\n' "$*" >&2
    exit 1
}

# stdin 是终端说明是误运行（例如忘了管道），此时直接读会挂住等人输入，
# 不如立刻给出用法提示。
if [ -t 0 ]; then
    die "本脚本从标准输入读取告警内容。示例：opsbox check -f oneline --fail-on never | $0"
fi

[ -n "$WEBHOOK_URL" ] || die "未设置 OPSBOX_WEBHOOK_URL。请通过环境变量提供地址（见脚本头部说明），不要把它硬编码进脚本"

command -v curl >/dev/null 2>&1 || die "找不到 curl，无法发送通知"

payload="$(cat)"
[ -n "$payload" ] || die "标准输入为空，没有内容可发送"

# 只把发送结果与 HTTP 状态码写到 stderr，正文不打印，避免告警里含主机信息被反复铺到终端上
printf '[opsbox-webhook] 正在发送到 %s\n' "$WEBHOOK_URL" >&2

# 用位置参数拼 curl 的选项，而不是把一条超长命令拆成多行续行：
# 续行会让引号跨行（合法但难读，也容易在别人改动时出错），
# 而且 "$@" 天然保证了含空格的值不会在传递过程中被拆开。
# --data-binary @- 原样发送正文（-d 会吃掉换行）；
# -f 让 4xx/5xx 变成非零退出码，配合 set -e 就会被 systemd 记成失败；
# -o /dev/null 丢弃响应体，只保留 -w 打印的 HTTP 状态码。
set -- -fsS -m "$TIMEOUT" -X POST -H "Content-Type: $CONTENT_TYPE"
if [ -n "$AUTH_HEADER" ]; then
    set -- "$@" -H "$AUTH_HEADER"
fi
set -- "$@" --data-binary @- -o /dev/null -w '%{http_code}' "$WEBHOOK_URL"

http_code="$(printf '%s\n' "$payload" | curl "$@")"

printf '[opsbox-webhook] 发送成功，HTTP %s\n' "$http_code" >&2
exit 0

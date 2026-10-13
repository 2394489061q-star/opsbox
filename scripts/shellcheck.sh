#!/usr/bin/env bash
# ==============================================================================
# opsbox :: scripts/shellcheck.sh
# 静态检查入口：优先跑 shellcheck，未安装时给出各平台安装提示并降级为 bash -n。
#
# 用法：
#   bash scripts/shellcheck.sh                       # 默认 severity=warning
#   bash scripts/shellcheck.sh --severity=error      # 只挡真正的错误（CI 阻断用）
#   bash scripts/shellcheck.sh opsbox lib/core.sh    # 只检查指定文件
#
# 为什么要有 severity 这个开关：
#   本项目的阈值变量（OB_CFG_*）是在运行时 source 配置文件后才存在的，
#   shellcheck 无法静态看到，因此必然产生一批 SC2154/SC2034 之类的噪音。
#   这类噪音无法靠改代码消除（改了就不再是「配置与代码分离」了）。
#   于是 CI 的策略是分两层：
#     1. severity=error —— 阻断，只挡真正的错误，几乎不会误报；
#     2. severity=warning —— 完整报告，continue-on-error，供人工参考。
#   这样既不会因为历史噪音让 CI 常年变红（变红就会被无视），
#   又不会把静态检查整个关掉。
#
# 退出码：0 = 通过（或降级后 bash -n 通过），1 = 发现问题，2 = 用法错误
# 兼容 Bash 3.2+（不使用关联数组、${var,,}、mapfile）。
# ==============================================================================

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR" || exit 2

# ------------------------------------------------------------ 排除规则说明 ----
# 下面是「有意保留、逐条确认过」的规则，不是全量关闭 shellcheck：
#
#   SC1090 / SC1091  动态 source。被加载文件的路径由 $OB_LIB_DIR / $OB_MODULE_DIR
#                    在运行时决定，shellcheck 无法静态跟随。源码对应行已经用
#                    `# shellcheck disable=SC1090` 就地写明了原因。
#   SC2046 / SC2086  未加引号的展开。本项目刻意依赖 shell 分词来切分字段
#                    （如 `set -- $fh`、`for m in $wanted`），这是 Bash 3.2 下
#                    最轻量、零 fork 的切分方式，加上引号反而会破坏逻辑。
#   SC2154           引用了「未赋值」的变量。OB_CFG_* / OB_ENV_* 全部来自运行时
#                    source 的配置文件，静态分析看不到它们。这恰恰是「配置与
#                    代码分离」的代价，不是缺陷。
#   SC2034           变量「定义了但没人用」。core.sh 与 conf 模板里成组声明的
#                    配置项就是给别的文件用的，单文件分析必然报未使用。
#   SC2155           `local x="$(cmd)"` 是本项目统一的紧凑写法，每个调用点后面
#                    都有 ob_is_num / 空值分支兜底；屏蔽的是噪音而非错误。
#   SC2181           tests/run-tests.sh 刻意先取 `$?` 再交给 assert_eq 断言，
#                    改写成 if 会丢掉「被测命令的退出码」这个断言对象本身。
#
# 新增规则前请先确认：能在源码处用行内 disable + 原因说明解决的，就不要加到这里。
SHELLCHECK_EXCLUDES="SC1090,SC1091,SC2034,SC2046,SC2086,SC2154,SC2155,SC2181"

# ---------------------------------------------------------------- 参数解析 ----
SEVERITY="warning"
FILES_ARG=()

while [ "$#" -gt 0 ]; do
    case "$1" in
        --severity=*)
            SEVERITY="${1#*=}"
            shift
            ;;
        -S|--severity)
            [ "$#" -ge 2 ] || { printf '选项 %s 缺少参数\n' "$1" >&2; exit 2; }
            SEVERITY="$2"
            shift 2
            ;;
        -h|--help)
            LC_ALL=C sed -n '2,20p' "$0" | LC_ALL=C sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            FILES_ARG+=("$1")
            shift
            ;;
    esac
done

case "$SEVERITY" in
    error|warning|info|style) ;;
    *) printf '无效的 severity：%s（可用：error warning info style）\n' "$SEVERITY" >&2; exit 2 ;;
esac

# ---------------------------------------------------------------- 收集文件 ----
# 刻意用 for 遍历而不是管道 + while：管道会开子 shell，循环里累积的状态传不回来
# （本项目的其他脚本也遵循同样的原则，见 lib/checks.sh 中 ob_check_series 的注释）。
collect_files() {
    if [ "$#" -gt 0 ]; then
        printf '%s\n' "$@"
        return 0
    fi
    printf '%s\n' opsbox
    find . -path './.git' -prune -o -path './tests/.work' -prune -o -type f -name '*.sh' -print \
        | LC_ALL=C sort
    return 0
}

if [ "${#FILES_ARG[@]}" -gt 0 ]; then
    FILES="$(collect_files "${FILES_ARG[@]}")"
else
    FILES="$(collect_files)"
fi

if [ -z "$FILES" ]; then
    printf '没有找到任何待检查的脚本（用法：bash scripts/shellcheck.sh [文件...]）\n' >&2
    exit 2
fi

N=0
for f in $FILES; do
    N=$((N + 1))
done

RC=0

if command -v shellcheck >/dev/null 2>&1; then
    printf '== shellcheck (severity=%s) ==\n' "$SEVERITY"
    printf '   版本：%s\n' "$(shellcheck --version | LC_ALL=C awk '/^version:/ {print $2}')"
    printf '   文件：%s 个\n' "$N"
    printf '   排除：%s（原因见本脚本顶部注释）\n\n' "$SHELLCHECK_EXCLUDES"
    for f in $FILES; do
        if shellcheck --shell=bash --severity="$SEVERITY" \
                      --exclude="$SHELLCHECK_EXCLUDES" "$f"; then
            printf '  OK   %s\n' "$f"
        else
            printf '  FAIL %s\n' "$f"
            RC=1
        fi
    done
    if [ "$RC" -eq 0 ]; then
        printf '\nshellcheck 全部通过（%s 个文件，severity=%s）\n' "$N" "$SEVERITY"
    else
        printf '\nshellcheck 发现问题：请按上面的 file:line:col 定位修正。\n' >&2
        if [ "$SEVERITY" != "error" ]; then
            printf '提示：用 --severity=error 可以只看真正的错误。\n' >&2
        fi
    fi
else
    printf '未找到 shellcheck，降级为 bash -n 语法检查（只能查语法，查不出常见陷阱）。\n' >&2
    cat >&2 <<'HINT'

安装 shellcheck：
  Debian / Ubuntu : sudo apt-get install -y shellcheck
  RHEL / CentOS   : sudo dnf install -y ShellCheck        （老系统：yum install ShellCheck）
  Alpine          : apk add shellcheck
  macOS           : brew install shellcheck
  Windows         : scoop install shellcheck   或   winget install koalaman.shellcheck
  GitHub Actions  : sudo apt-get install -y shellcheck

HINT
    printf '== bash -n ==\n'
    for f in $FILES; do
        if err="$(bash -n "$f" 2>&1)"; then
            printf '  OK   %s\n' "$f"
            continue
        fi
        printf '  FAIL %s\n' "$f"
        printf '%s\n' "$err" | LC_ALL=C sed 's/^/       /' >&2
        RC=1
    done
    if [ "$RC" -eq 0 ]; then
        printf '\nbash -n 全部通过（%s 个文件）。建议装上 shellcheck 后再跑一次。\n' "$N"
    fi
fi

exit "$RC"
